% Intraop Launcher for DAF
%%%% audio will NOT be recorded by the computer, to avoid interfering with DAF's usage of audio inputs
%%%% this could be changed by using parallel pool (see START_DAF_MIDI)

figure;

% --- Centralized configuration structure ---
cfg = [];

% cfg.SESSION_LABEL = 'intraop';
cfg.SESSION_LABEL = 'preop'; 

% % % Subject metadata
% cfg.SUBJECT = 'DM1056'
cfg.SUBJECT = 'daftest'

cfg.DATA_TYPE     = 'task';
cfg.RECORD_AUDIO = 1;
cfg.STOP_BETWEEN_TRIALS = 2;     % Require space to proceed between all trials (after ITI plays)

% Task metadata (match preop naming so Task_*.m runs unchanged)
cfg.TASK          = 'daf';
cfg.TASK_VERSION  = 1;
cfg.TASK_FUNCTION = 'task_daf_nomidi.m';

% Core DAF parameters REQUIRED by Task_DelayedAuditoryFeedback
cfg.max_trials            = inf;         % optional cap (same default as preop)
 cfg.audio_sample_rate    = 44100; 
cfg.audio_frame_size      = 128;        % block size Task_* uses for streaming; Sam's default = 128; can go down to ~60 without problem with intraop
cfg.fix_cross_dur         = 0.0;        % pre-sentence fix (Task_* uses its own ITI_S but we keep parity)
cfg.text_stim_dur         = 10;       % sentence display/speaking time in sec; ok to make this shorter than expected response, because it's also keypress-controlled
cfg.iti                   = [1.75, 2.25]; % Inter-trial interval range in seconds
cfg.stim_font_size        = 50;         % use 50 on intraop rig
cfg.stim_max_char_per_line= 30;         % maximum number of chars per line in ortho stim figure, for text wrapping
cfg.catchRatio            = 0;          % proportion of trials which are no-speech catch trials
cfg.max_stim_repeats      = 2;          % max consecutive repeats of same stimulus within a block
cfg.max_delay_repeats     = 4;          % max consecutive repeats of same delays within a block
cfg.same_trials_across_blocks = true;   % if true: trials randomized in first block only, same order repeated across blocks

% DAF delay conditions (ms)
cfg.maxAllowedDelay_ms    = 1000;       % delay_values_ms must be below this value

% beep params - played at beginning of run, and optionally as go cue
cfg.go_beep_dur = 0.05;         % go beep duration in sec
cfg.go_beep_amp = 0.5; % go beep amplitude (zero to one)

%% go cue options
cfg.play_go_cue = true;                     % make subject wait for go beep following stim onset before speaking; if false, don't play go beep  
    cfg.go_latency = [1.5 2.5];         % if play_go_cue==true, this is the jittered time in sec between visual stim onset and go cue onset

% cfg.play_go_cue = false;                     % make subject wait for go beep following stim onset before speaking; if false, don't play go beep  

%% block-design and stimulus repetition options
cfg.delay_block_design = 1; 
    cfg.max_delay_repeats      = inf;       % Max repeats per delay condition... not used if we are using delay block design
    cfg.max_stim_repeats       = inf;       % Max number of repeats per stimulus... not used if we are using delay block design
    
% cfg.delay_block_design = 0; 
%     cfg.max_delay_repeats      = 4;       % Max repeats per delay condition
% cfg.max_stim_repeats       = 2;       % Max number of repeats per stimulus

% determine filename of stim list
switch cfg.SESSION_LABEL
    case 'preop'
 
        cfg.delay_values_ms = [0 50 100 150 200 250]; % 
        cfg.n_blocks = 1;

        cfg.daf_stim_file = 'daf_3word_preop.tsv';
        cfg.response_window          = 5;      % time subject has to speak; either text duration (if no go beep), or text duration after go beep
         cfg.trials_per_mini_block = 5;  % number of trials within a 'mini block' of repeated delay values


        % cfg.daf_stim_file = 'daf_sentences_preop_single.tsv';        
        %     cfg.response_window          = 6;      % time subject has to speak; either text duration (if no go beep), or text duration after go beep
        % cfg.trials_per_mini_block = 5;  % number of trials within a 'mini block' of repeated delay values


        % cfg.daf_stim_file = 'daf_sentences_preop_double.tsv';
        % cfg.response_window          = 10;      % time subject has to speak; either text duration (if no go beep), or text duration after go beep


    case 'intraop'
        cfg.delay_values_ms = [0 50 150]; % zero condition, low delay (fluency-enhancing) condition, high delay (disfluency-inducing) condition
        %cfg.delay_values_ms = [0 100 150 200];
        cfg.n_blocks = 3;

        
         cfg.daf_stim_file = 'daf_3word_intraop.tsv';
        cfg.response_window          = 5;      % time subject has to speak; either text duration (if no go beep), or text duration after go beep
        cfg.trials_per_mini_block = 5;  % number of trials within a 'mini block' of repeated delay values

        
        % cfg.daf_stim_file = 'daf_sentences_intraop_single.tsv';
        % cfg.response_window          = 6;      % time subject has to speak; either text duration (if no go beep), or text duration after go beep
        % cfg.trials_per_mini_block = 6;  % number of trials within a 'mini block' of repeated delay values


%         cfg.daf_stim_file = 'daf_sentences_intraop_double.tsv';
%          cfg.response_window          = 10;      % time subject has to speak; either text duration (if no go beep), or text duration after go beep    
        % cfg.trials_per_mini_block = 6;  % number of trials within a 'mini block' of repeated delay values




%          cfg.daf_stim_file = 'daf_sentences_short.tsv'; % use for quick testing of full runs
    otherwise
        error('Unknown session label: %s', cfg.SESSION_LABEL);
end 
% cfg.audio_playback_gain   = 1.3;          % DAF output gain
cfg.audio_playback_gain   = 0.3;          % DAF output gain

if any(cfg.delay_values_ms > cfg.maxAllowedDelay_ms)
    error('One or more delayOptions exceed the maximum allowed delay of %d ms.', cfg.maxAllowedDelay_ms);
end

% check protocol
cfg.protocol = 'udp';

% Diagnostics / flags (used by Task_* optionally)
cfg.no_audio_debug_mode   = true;
cfg.LAG_DIAGNOSTICS       = true;

% Audio / PTB preferences
cfg.SKIP_SYNC_TEST        = 1;          % safe for bench/windowed testing; set 0 in OR if fully synced desired
cfg.CONSERVE_VRAM_MODE    = 4096;

% Choose LOCAL_TEST mode explicitly (Task_* branches on this)
% Set to false on the OR rig; set true on a laptop for quick dry-runs.
cfg.LOCAL_TEST            = 0;

% Paths and device configuration (point at DAF task)
addpath('scripts'); cfg = set_paths_daf(cfg); 

cfg.AUDIO_DEVICE_IN = 'Microphone Array (Intel® Smart Sound Technology for Digital Microphones)'; % laptop onboard mic
cfg.AUDIO_DEVICE_OUT = 'Default'; % 3.5mm audio jack for headphones
cfg.audio_reader_driver = 'DirectSound'; 
cfg.audio_writer_driver = 'DirectSound'; 
cfg.PATH_STIMDIR = [cfg.PATH_TASK, filesep, 'stimuli']; 

% Misc parity with preop
cfg.CALIBRATION_BEEPS_N = 5;
cfg.KEYBOARD_ID         = [];

% --- Warnings/PTB setup (apply prefs so toggles take effect) ---
warning('on','all'); %beep off;
PsychDefaultSetup(2);
Screen('Preference','SkipSyncTests', cfg.SKIP_SYNC_TEST);
Screen('Preference','ConserveVRAM', cfg.CONSERVE_VRAM_MODE);
Screen('Preference','VisualDebugLevel', 1);
Screen('Preference','Verbosity', 3);
PsychDebugWindowConfiguration;   % windowed + alpha for bench testing (comment out on OR if undesired)

close all force; Screen('CloseAll'); % close all normal matlab figures and PTB windows

%% Warnings
warning('on','all'); %enabling warnings
% beep off

% --- Paths & output folders (match preop structure) ---
pathSub            = fullfile(cfg.PATH_SOURCEDATA, ['sub-' cfg.SUBJECT]);
pathSubSes         = fullfile(pathSub, ['ses-' cfg.SESSION_LABEL]);
pathSubSesDataType = fullfile(pathSubSes, cfg.DATA_TYPE);
pathSubSesAudio    = fullfile(pathSubSes, 'audio');

for p = {cfg.PATH_SOURCEDATA, pathSub, pathSubSes, pathSubSesDataType, pathSubSesAudio}
    if ~isfolder(p{1}), mkdir(p{1}); end
end
cfg.PATH_AUDIO = pathSubSesAudio;   % needed for AUDIO_FILENAME

% --- Run basename / filenames (integer-safe %02d) ---
fileBaseName  = ['sub-' cfg.SUBJECT '_ses-' cfg.SESSION_LABEL '_task-' cfg.TASK '_run-'];
allEventFiles = dir(fullfile(pathSubSesDataType, [fileBaseName '*_events.tsv']));
if ~isempty(allEventFiles)
    prevRunIds = regexp({allEventFiles.name}, '_run-(\d+)_', 'tokens', 'ignorecase');
    prevRunIds = cellfun(@(x) str2double(x{1,1}), prevRunIds, 'UniformOutput', true);
    runId = max(prevRunIds) + 1;
else
    runId = 1;
end

cfg.RUN_ID        = runId;
cfg.PATH_LOG      = pathSubSesDataType;
cfg.BASE_NAME     = [fileBaseName, sprintf('%02d_', runId)];
cfg.LOG_FILENAME  = fullfile(cfg.PATH_LOG, [cfg.BASE_NAME 'log.txt']);
cfg.EVENT_FILENAME= fullfile(cfg.PATH_LOG, [cfg.BASE_NAME 'events.tsv']);
cfg.TRIAL_FILENAME= fullfile(cfg.PATH_LOG, [cfg.BASE_NAME 'trials.tsv']);
cfg.AUDIO_FILENAME= fullfile(cfg.PATH_AUDIO, [cfg.BASE_NAME(1:end-1) '.wav']);

% --- Start diary ---
diary(cfg.LOG_FILENAME);
onCleanupTasks = cell(10,1);
onCleanupTasks{10} = onCleanup(@() diary('off'));
disp(cfg);

% No triggers during training session
cfg.DIGOUT = 0;

%% Change folder 
% change to main scripts folder, like we do in Speech Motor Sequence Learning (SMSL) scripts
cd('./scripts'); 

% --- Launch task (same as preop flow) ---
fprintf('Launching task\n');

task_function = [pwd filesep cfg.TASK_FUNCTION];
if ~isfile(task_function)
    clear onCleanupTasks
    error('%s should be in current working directory', cfg.TASK_FUNCTION);
end
copyfile(task_function, [cfg.PATH_LOG filesep cfg.BASE_NAME 'script.m']);

task_daf_nomidi(cfg);

% --- Cleanup ---
clear onCleanupTasks;
close all;