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
% pairs_per_block = nStim * nDelays
pairs_per_block = cfg.n_unique_stim * nDelays;

% Cross with ndgrid for exact 1:1 coverage
[sIdx, dIdx]   = ndgrid(1:cfg.n_unique_stim, 1:nDelays);
pairStim_block = sIdx(:);
pairDelay_block = delay_vals(dIdx(:));

% Helper: constrained permutation (inline, no external functions)
% Returns a permutation of indices 1:pairs_per_block such that consecutive
% repeats for stim/delay do not exceed cfg.max_*_repeats.
    function [fs, fd] = constrained_block_shuffle()
        max_attempts = 2000;
        for attempt = 1:max_attempts
            % Available indices without replacement
            avail = 1:pairs_per_block;
            fs = zeros(pairs_per_block,1);
            fd = zeros(pairs_per_block,1);

            curStim = NaN; stimRun = 0;
            curDelay = NaN; delayRun = 0;

            ok = true;
            for k = 1:pairs_per_block
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
                fs(k) = pairStim_block(picked_idx);
                fd(k) = pairDelay_block(picked_idx);

                if fs(k) == curStim, stimRun = stimRun + 1; else, curStim = fs(k); stimRun = 1; end
                if fd(k) == curDelay, delayRun = delayRun + 1; else, curDelay = fd(k); delayRun = 1; end

                % Remove the used element from availability (no replacement)
                avail(avail == picked_idx) = [];
            end

            if ok
                return; % success
            end
            % otherwise loop and try a fresh attempt
        end
        error('Could not satisfy max repeats (stim=%d, delay=%d) after %d attempts.', ...
            cfg.max_stim_repeats, cfg.max_delay_repeats, max_attempts);
    end

%% Build across blocks
% Create full schedule for all blocks, then truncate to max_trials if needed
allStim = zeros(pairs_per_block * cfg.n_blocks, 1);
allDelay = zeros(pairs_per_block * cfg.n_blocks, 1);

writeIdx = 1;
for b = 1:cfg.n_blocks
    if isfield(cfg,'same_trials_across_blocks') && cfg.same_trials_across_blocks && b > 1
        % Reuse same (stim, delay) set but reshuffle
        [~, order] = sort(rand(size(allStim(1:pairs_per_block))));
        fs = allStim(order(1:pairs_per_block));  % reuse Block 1 pool but new order
        fd = allDelay(order(1:pairs_per_block));
    else
        [fs, fd] = constrained_block_shuffle();
    end
    allStim(writeIdx:writeIdx + pairs_per_block - 1)  = fs;
    allDelay(writeIdx:writeIdx + pairs_per_block - 1) = fd;
    writeIdx = writeIdx + pairs_per_block;
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
trialSentIdx = allStim(1:ntrials);
trialDelays  = allDelay(1:ntrials);
trialBlock   = ceil((1:ntrials)' / pairs_per_block);

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

%% Build table
trials = table( ...
    (1:ntrials).', ...
    trialBlock(:), ...
    unique_stim_list(trialSentIdx), ...
    trialSentIdx(:), ...
    trialDelays(:), ...
    catchVec(:), ...
    'VariableNames', {'trialnum','block_id','stim','stim_idx','delay','catch_trial'} ...
);

% Initialize columns that will be filled during runtime
trials.start_time         = nan(ntrials,1);
trials.visual_onset_time  = nan(ntrials,1);
trials.visual_off_time    = nan(ntrials,1);
trials.lag_mean           = nan(ntrials,1);

% Return in cfg (and as output)
cfg.TRIAL_TABLE = trials;
end
