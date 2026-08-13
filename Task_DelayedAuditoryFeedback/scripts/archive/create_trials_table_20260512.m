function [cfg, trials, text_wrapped_all] = create_trials_table(cfg)
% create_trials_table  Build DAF trial table with max-repeat constraints, balanced per block.
% Usage (inside Task_DelayedAuditoryFeedback.m):
%   [cfg, trials, text_wrapped_all] = create_trials_table(cfg);
%   % cfg.TRIAL_TABLE is also populated.




%% Load stimuli
stimtable = readtable(fullfile(cfg.PATH_STIMDIR,cfg.daf_stim_file), ...
    'FileType','text', 'Delimiter','tab');
unique_stim_list = stimtable.stim;

% Counts and delay vector
cfg.n_unique_stim = numel(unique_stim_list);
delay_vals = cfg.delay_values_ms(:); % ensure column vector
nDelays   = numel(delay_vals);

%% Build ONE block's full (stim, delay) cross
cfg.trials_per_block = cfg.n_unique_stim * nDelays;


if cfg.delay_block_design

    % check that if condition blocks are called for, cfg.max_stim_repeats is not use
    if ~(cfg.max_delay_repeats==inf)
        error('if cfg.delay_block_design==1, then cfg.max_delay_repeats and cfg.max_stim_repeats must be set to inf')
    end 

    if cfg.trials_per_mini_block < 2 || round(cfg.trials_per_mini_block) ~= cfg.trials_per_mini_block
        error(['cfg.trials_per_block (', num2str(cfg.trials_per_block),') must be an integer greater than 1'])
    end

    % check that mini blocks (blocks of delay trials) are a factor of the number of unique stim
    if mod(cfg.n_unique_stim,cfg.trials_per_mini_block) ~= 0
        error( ['cfg.trials_per_mini_block (', num2str(cfg.trials_per_mini_block), ') ',...
            'must be a factor of the number of unique stim (', num2str(cfg.n_unique_stim), ')'] ) 
    end

    cfg.mini_blocks_per_block =  cfg.trials_per_block / cfg.trials_per_mini_block; 

end


% Cross with ndgrid for exact 1:1 coverage
[sIdx, dIdx]   = ndgrid(1:cfg.n_unique_stim, 1:nDelays);
pairStim_block = sIdx(:);
pairDelay_block = delay_vals(dIdx(:));

% Helper: constrained permutation (inline, no external functions)
% Returns a permutation of indices 1:cfg.trials_per_block such that consecutive
% repeats for stim/delay do not exceed cfg.max_*_repeats.
    function [stim_order, delay_order] = constrained_block_shuffle(cfg)
        max_attempts = 2000;
        for attempt = 1:max_attempts
            % Available indices without replacement
            avail = 1:cfg.trials_per_block;
            stim_order = zeros(cfg.trials_per_block,1);
            delay_order = zeros(cfg.trials_per_block,1);

            curStim = NaN; stimRun = 0;
            curDelay = NaN; delayRun = 0;

            ok = true;
            for k = 1:cfg.trials_per_block
                % Try a random order of the currently available pool
                try_order = avail(randperm(numel(avail)));

                picked_idx = NaN;
                for cand = try_order
                    s = pairStim_block(cand);
                    d = pairDelay_block(cand);

                    nextStimRun  = (isnan(curStim)  || s ~= curStim)  * 1 + (s == curStim)  * (stimRun + 1);
                    nextDelayRun = (isnan(curDelay) || d ~= curDelay) * 1 + (d == curDelay) * (delayRun + 1);

                    if nextStimRun <= cfg.max_stim_repeats && nextDelayRun <= cfg.max_delay_repeats
                        picked_idx = cand;
                        break;
                    end
                end

                if isnan(picked_idx)
                    ok = false; break; % try whole attempt again
                end

                % Assign and update runs
                stim_order(k) = pairStim_block(picked_idx);
                delay_order(k) = pairDelay_block(picked_idx);

                if stim_order(k) == curStim, stimRun = stimRun + 1; else, curStim = stim_order(k); stimRun = 1; end
                if delay_order(k) == curDelay, delayRun = delayRun + 1; else, curDelay = delay_order(k); delayRun = 1; end

                % Remove the used element from availability (no replacement)
                avail(avail == picked_idx) = [];
            end

            if ok

                % if delay block design, group trials by delay after the initial randomization
                if cfg.delay_block_design
                    ds_trials = [delay_order, stim_order];
                    movetotop = @(x,row)[x(row,:);x(1:row-1,:);x(row+1:end,:)]; 
    
                    % if there's a zero-delay trial, make sure that there's a zero-delay block first
                    first_zero_row = find(ds_trials(:,1)==0, 1);
                    if ~isempty(first_zero_row)
                        ds_trials = movetotop(ds_trials,first_zero_row);
                    end
    
                    % get an order for the mini-blocks within this block then repeat that order
                    cfg.delay_order = unique(ds_trials(:,1),'stable'); 
                    delays_to_conform_to = repelem(cfg.delay_order,cfg.trials_per_mini_block); 
                    n_instances_of_each_mini_block = size(ds_trials,1) / size(delays_to_conform_to,1); % repeat the mini-block order sequence to fill out the block
                    delays_to_conform_to = repmat(delays_to_conform_to, n_instances_of_each_mini_block, 1);  
                    
                    for itrial = 1:size(ds_trials,1)
                        thisdelay = delays_to_conform_to(itrial);
    
                        % find the next trial that matches the required delay
                        trial_to_move_up = itrial - 1 + find(ds_trials(itrial:size(ds_trials,1), 1) == thisdelay, 1); 
    
                        % switch the matching trial with the current trial in this slot
                        ds_trials([itrial, trial_to_move_up], :) = ds_trials([trial_to_move_up, itrial], :);
                    end
    
                    delay_order = ds_trials(:,1);
                    stim_order = ds_trials(:,2);
                end

                return; % success
            end
            % otherwise loop and try a fresh attempt
        end
        error('Could not satisfy max repeats (stim=%d, delay=%d) after %d attempts.', ...
            cfg.max_stim_repeats, cfg.max_delay_repeats, max_attempts);
    end

%% Build across blocks
% Create full schedule for all blocks, then truncate to max_trials if needed
allStim = zeros(cfg.trials_per_block * cfg.n_blocks, 1);
allDelay = zeros(cfg.trials_per_block * cfg.n_blocks, 1);

writeIdx = 1;
for iblock = 1:cfg.n_blocks

    % if it's the first block, or if we're not repeating trials across blocks, generate a new within-block trial order
    %%%% otherwise the following conditional is skipped, and we reuse the previously constructed block
    if iblock == 1 || ~cfg.same_trials_across_blocks
        clear stim_order delay_order
        [stim_order, delay_order] = constrained_block_shuffle(cfg);
    end

    allStim(writeIdx:writeIdx + cfg.trials_per_block - 1)  = stim_order;
    allDelay(writeIdx:writeIdx + cfg.trials_per_block - 1) = delay_order;
    writeIdx = writeIdx + cfg.trials_per_block;
end

%% Apply optional cap
ntrialsPlanned = numel(allStim);
if isfield(cfg,'max_trials') && ~isempty(cfg.max_trials)
    ntrials = min(ntrialsPlanned, cfg.max_trials);
else
    ntrials = ntrialsPlanned;
end
cfg.ntrials = ntrials;

% Truncate if needed (note: truncating mid-block will unbalance counts by tail)
trialStimIdx = allStim(1:ntrials);
trialDelays  = allDelay(1:ntrials);
trialBlock   = ceil((1:ntrials)' / cfg.trials_per_block);

%% Catch trials
if ~isfield(cfg,'catchRatio') || isempty(cfg.catchRatio), cfg.catchRatio = 0; end
nCatch = round(ntrials * cfg.catchRatio);
catchVec = false(ntrials,1);
if nCatch > 0
    catchVec(randperm(ntrials, nCatch)) = true;
end

%% Pre-wrap Stim (for display)
text_wrapped_all = cell(cfg.n_unique_stim,1);
nl = sprintf('\n');
for si = 1:cfg.n_unique_stim
    text_stim = regexprep(unique_stim_list{si}, '\r', '');
    if isfield(cfg,'stim_max_char_per_line') && ~isempty(cfg.stim_max_char_per_line) && cfg.stim_max_char_per_line>0
        w = split(string(text_stim));
        cur = ""; lines = strings(0,1);
        for ii = 1:numel(w)
            nxt = strtrim(cur + " " + w(ii));
            if strlength(nxt) <= cfg.stim_max_char_per_line
                cur = nxt;
            else
                if strlength(cur)>0, lines(end+1) = cur; end %#ok<AGROW>
                cur = w(ii);
            end
        end
        if strlength(cur)>0, lines(end+1) = cur; end %#ok<AGROW>
        text_wrapped_all{si} = char(strjoin(lines, nl));
    else
        text_wrapped_all{si} = char(text_stim);
    end
end

%% add go latencies if applicable
if cfg.play_go_cue 
    go_latecy_vec = cfg.go_latency(1) + [diff(cfg.go_latency) * rand(ntrials,1)];
elseif ~cfg.play_go_cue 
    go_latecy_vec = nan(ntrials,1); 
end

%% Build table
trials = table( ...
    (1:ntrials).', ...
    trialBlock(:), ...
    unique_stim_list(trialStimIdx), ...
    trialStimIdx(:), ...
    trialDelays(:), ...
    catchVec(:), ...
    go_latecy_vec, ...
    'VariableNames', {'trialnum','block_id','stim','stim_idx','delay','catch_trial','go_latency'} ...
);

%%%%% Initialize columns that will be filled during runtime
% trials.start_time         = nan(ntrials,1); % not currently being filled by midi or nonmidi versions
% trials.visual_onset_time  = nan(ntrials,1); % not currently being filled by midi or nonmidi versions
% trials.visual_off_time    = nan(ntrials,1); % not currently being filled by midi or nonmidi versions
% trials.lag_mean           = nan(ntrials,1); % not currently being filled by midi or nonmidi versions
trials.midi_cc_val        = nan(ntrials,1);

% get midi cc vals for each delay and the corresponding actual delays
if cfg.TASK_FUNCTION == "task_daf_midi.m"
    trials.midi_cc_val        = nan(ntrials,1);
    for itrial = 1:height(trials)
        [trials.midi_cc_val(itrial), actual_delay_ms] = delay_to_midi_ccval(trials.delay(itrial));
        trials.delay(itrial) = actual_delay_ms; % overwrite with the actual delay that will be used
    end
end

% Return in cfg (and as output)
cfg.TRIAL_TABLE = trials;
end
