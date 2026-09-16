function [cfg, trials, text_wrapped_all] = create_trials_table(cfg)
% create_trials_table  Build metronomic-speech trial table, balanced per block.
%
% Usage:
%   [cfg, trials, text_wrapped_all] = create_trials_table(cfg);
%   % cfg.TRIAL_TABLE is also populated.
%
% Trial structure:
%   - Two conditions only:
%       metro_speech = true   % metronomic speech
%       metro_speech = false  % non-metronomic speech
%   - Each block contains exactly one trial of each unique stimulus in each
%     condition.
%   - Therefore:
%       cfg.trials_per_block = cfg.n_unique_stim * 2
%   - Each block is organized into mini-blocks of a single condition.
%   - cfg.trials_per_mini_block must evenly divide cfg.n_unique_stim.
%   - The first mini-block of the experiment is always non-metronomic.
%   - No delay, MIDI, or catch-trial variables are included.

%% Load stimuli
stimtable = readtable(fullfile(cfg.PATH_STIMDIR, cfg.stim_file), ...
    'FileType', 'text', 'Delimiter', 'tab');

unique_stim_list = stimtable.stim;
cfg.n_unique_stim = numel(unique_stim_list);

%% Basic counts/checks
nConds = 2; % nonmetro + metro

cfg.trials_per_block = cfg.n_unique_stim * nConds;

if cfg.trials_per_mini_block < 1 || round(cfg.trials_per_mini_block) ~= cfg.trials_per_mini_block
    error('cfg.trials_per_mini_block must be a positive integer.')
end

% Mini-blocks are condition-pure, and each condition has exactly one
% instance of each stimulus per block. Therefore the number of unique stimuli
% must be divisible by the mini-block size.
if mod(cfg.n_unique_stim, cfg.trials_per_mini_block) ~= 0
    error(['cfg.trials_per_mini_block (', num2str(cfg.trials_per_mini_block), ') ', ...
        'must evenly divide the number of unique stimuli (', ...
        num2str(cfg.n_unique_stim), ').'])
end

cfg.mini_blocks_per_condition = cfg.n_unique_stim / cfg.trials_per_mini_block;
cfg.mini_blocks_per_block = cfg.mini_blocks_per_condition * nConds;

%% Helper: build one balanced block
% forced_first_condition: false = nonmetro first, true = metro first
    function [stim_order, metro_order] = build_one_block(forced_first_condition)

        % Randomize stimulus order separately for each condition.
        nonmetro_stim = randperm(cfg.n_unique_stim).';
        metro_stim    = randperm(cfg.n_unique_stim).';

        % Split each condition's randomized stimulus list into mini-blocks.
        nonmetro_mbs = cell(cfg.mini_blocks_per_condition, 1);
        metro_mbs    = cell(cfg.mini_blocks_per_condition, 1);

        for imb = 1:cfg.mini_blocks_per_condition
            idx1 = (imb - 1) * cfg.trials_per_mini_block + 1;
            idx2 = imb * cfg.trials_per_mini_block;

            nonmetro_mbs{imb} = nonmetro_stim(idx1:idx2);
            metro_mbs{imb}    = metro_stim(idx1:idx2);
        end

        % Make a list of all mini-blocks in this block.
        %
        % condition:
        %   false = nonmetro
        %   true  = metro
        %
        mb_condition = [ ...
            false(cfg.mini_blocks_per_condition, 1); ...
            true(cfg.mini_blocks_per_condition, 1) ...
        ];

        mb_index_within_condition = [ ...
            (1:cfg.mini_blocks_per_condition).'; ...
            (1:cfg.mini_blocks_per_condition).' ...
        ];

        nMiniBlocks = numel(mb_condition);

        % Randomize mini-block order unless explicitly disabled.
        if ~isfield(cfg, 'randomize_miniblock_order') || cfg.randomize_miniblock_order
            mb_order = randperm(nMiniBlocks).';
        else
            mb_order = (1:nMiniBlocks).';
        end

        % Force the first mini-block to the required condition.
        if forced_first_condition
            target_positions = find( mb_condition(mb_order));   % metro positions
        else
            target_positions = find(~mb_condition(mb_order));   % nonmetro positions
        end
        if isempty(target_positions)
            error('Internal error: no mini-blocks found for the forced first condition.')
        end
        chosen_pos = target_positions(randi(numel(target_positions)));
        mb_order = [mb_order(chosen_pos); mb_order([1:chosen_pos-1, chosen_pos+1:end])];

        % Expand mini-blocks into trial-level vectors.
        stim_order  = zeros(cfg.trials_per_block, 1);
        metro_order = false(cfg.trials_per_block, 1);

        % Inside build_one_block — rename to avoid colliding with outer writeIdx
        mb_row = 1;                          
        
        for iorder = 1:nMiniBlocks
            this_mb        = mb_order(iorder);
            this_condition = mb_condition(this_mb);
            this_mb_idx    = mb_index_within_condition(this_mb);
        
            if this_condition
                this_stim = metro_mbs{this_mb_idx};
            else
                this_stim = nonmetro_mbs{this_mb_idx};
            end
        
            rows = mb_row:(mb_row + cfg.trials_per_mini_block - 1); 
        
            stim_order(rows)  = this_stim;
            metro_order(rows) = this_condition;
        
            mb_row = mb_row + cfg.trials_per_mini_block;          
        end
    end

%% Build across blocks
allStim  = zeros(cfg.trials_per_block * cfg.n_blocks, 1);
allMetro = false(cfg.trials_per_block * cfg.n_blocks, 1);

writeIdx = 1;

for iblock = 1:cfg.n_blocks

    % If this is the first block, or if trials should vary across blocks,
    % generate a new within-block order. Otherwise reuse the previous one.
    if iblock == 1
        [stim_order, metro_order] = build_one_block(cfg.first_trial_is_metro);
    end

    rows = writeIdx:(writeIdx + cfg.trials_per_block - 1);

    allStim(rows)  = stim_order;
    allMetro(rows) = metro_order;

    writeIdx = writeIdx + cfg.trials_per_block;
end

%% Apply optional cap
ntrialsPlanned = numel(allStim);

if isfield(cfg, 'max_trials') && ~isempty(cfg.max_trials)
    ntrials = min(ntrialsPlanned, cfg.max_trials);
else
    ntrials = ntrialsPlanned;
end

cfg.ntrials = ntrials;

trialStimIdx = allStim(1:ntrials);
trialMetro   = allMetro(1:ntrials);
trialBlock   = ceil((1:ntrials).' / cfg.trials_per_block);

%% Pre-wrap stimuli for display
text_wrapped_all = cell(cfg.n_unique_stim, 1);
nl = sprintf('\n');

for si = 1:cfg.n_unique_stim
    text_stim = regexprep(unique_stim_list{si}, '\r', '');

    if isfield(cfg, 'stim_max_char_per_line') && ...
            ~isempty(cfg.stim_max_char_per_line) && ...
            cfg.stim_max_char_per_line > 0

        w = split(string(text_stim));
        cur = "";
        lines = strings(0, 1);

        for ii = 1:numel(w)
            nxt = strtrim(cur + " " + w(ii));

            if strlength(nxt) <= cfg.stim_max_char_per_line
                cur = nxt;
            else
                if strlength(cur) > 0
                    lines(end + 1) = cur; %#ok<AGROW>
                end
                cur = w(ii);
            end
        end

        if strlength(cur) > 0
            lines(end + 1) = cur; %#ok<AGROW>
        end

        text_wrapped_all{si} = char(strjoin(lines, nl));
    else
        text_wrapped_all{si} = char(text_stim);
    end
end

%% Compute jittered go latencies
go_latency_vec = cfg.go_latency(1) + diff(cfg.go_latency) * rand(ntrials, 1);


%% Build trial table
trials = table( ...
    (1:ntrials).', ...
    trialBlock(:), ...
    unique_stim_list(trialStimIdx), ...
    trialStimIdx(:), ...
    trialMetro(:), ...
    go_latency_vec(:), ...
    'VariableNames', { ...
        'trialnum', ...
        'block_id', ...
        'stim', ...
        'stim_idx', ...
        'metro_speech', ...
        'go_latency' ...
    } ...
);

%% Return in cfg
cfg.TRIAL_TABLE = trials;

end