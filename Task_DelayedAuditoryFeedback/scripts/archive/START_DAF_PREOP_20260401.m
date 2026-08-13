% Intraop Launcher for DAF

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
cfg.audio_sample_rate     = 44100;      % Audio sample rate in Hz
cfg.audio_frame_size      = 128;        % block size Task_* uses for streaming; Sam's default = 128; can go down to ~60 without problem with intraop
cfg.fix_cross_dur         = 0.0;        % pre-sentence fix (Task_* uses its own ITI_S but we keep parity)
cfg.text_stim_dur         = 10;       % sentence display/speaking time in sec; ok to make this shorter than expected response, because it's also keypress-controlled
cfg.iti                   = [1.75, 2.25]; % Inter-trial interval range in seconds
cfg.stim_font_size        = 75;         % use 50 on intraop rig
cfg.stim_max_char_per_line= 30;         % maximum number of chars per line in ortho stim figure, for text wrapping
cfg.catchRatio            = 0;          % proportion of trials which are no-speech catch trials
cfg.max_stim_repeats      = 2;          % max consecutive repeats of same stimulus within a block
cfg.max_delay_repeats     = 4;          % max consecutive repeats of same delays within a block
cfg.same_trials_across_blocks = true;   % if true: trials randomized in first block only, same order repeated across blocks

% DAF delay conditions (ms)
cfg.maxAllowedDelay_ms    = 1000;       % delay_values_ms must be below this value

% determine filename of stim list
cfg.daf_stim_file = 'daf_sentences_short.tsv'; % version with only 2 sentences 
cfg.daf_stim_file = ['daf_sentences_', cfg.SESSION_LABEL, '.tsv']; % Stim text file depending on which session

cfg.delay_values_ms = [0 40 80 120]
cfg.n_blocks        = 2;          % number of blocks
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
cfg.PATH_TASK       = 'D:\Task\Task_DelayedAuditoryFeedback';
cfg.PATH_SOURCEDATA = 'D:\DBS\sourcedata';
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