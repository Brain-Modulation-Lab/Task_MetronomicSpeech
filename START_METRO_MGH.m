function START_METRO_MGH
% START_METRO - Launcher for the metronomic paced-speech task.
%
% Mirrors the DAF launcher's structure: build the cfg struct -> prepare paths,
% output folders and filenames -> (optionally) start audio recording and
% hardware -> launch the task function (task_metronomic.m), passing cfg.
%
% All configuration lives in the cfg struct below. The task function reads its
% parameters straight out of cfg, so this file is the single place to edit.

cfg = struct();

%% ---------------- Subject / session ----------------
% cfg.SUBJECT       = 'DM1060';     % Subject identifier
cfg.SUBJECT     = 'metrotest';  % <- use this for a test run
cfg.SESSION_LABEL = 'intraop';    % 'preop' or 'intraop' (drives folder naming + n_blocks)

%% ---------------- Run / session options ----------------
cfg.DATA_TYPE       = 'task';        % data-type subfolder name
% cfg.RECORD_AUDIO is machine-specific -> set per host in the paths switch below
cfg.PTB             = false;         % Psychtoolbox 
cfg.wait_for_space  = true;          % require SPACE to start each trial
cfg.iti             = [0.75 1.25];   % jittered inter-trial interval (s)   [was iti_range in the demo]
cfg.max_trials      = inf;           % cap on total trials (inf = run them all)
cfg.randomize_order = true;          % shuffle sentence order within each block

%% ---------------- Metronomic task parameters (ported from metronomic_task_demo) ----------------
cfg.metronome_duration = 1.5;          % s the auditory metronome plays (pre-go epoch 1)
cfg.beat_dur           = 0.33;         % s between metronome beats = metronome rate
cfg.pre_speech_delay   = [0.75 1.24];  % jittered silent period (s) after metronome, before GO beep (epoch 2)
cfg.speech_window_dur  = 5;            % s between GO beep onset and visual stimulus disappearing
cfg.stim_font_size     = 34;           % stimulus font size
cfg.stim_max_char_per_line = 26;       % wrap width for the sentence (chars per line)

%% ---------------- Sounds ----------------
cfg.go_beep_freq        = 1000;   % GO beep tone (Hz)
cfg.go_beep_dur         = 0.05;   % GO beep duration (s)
cfg.go_beep_amp         = 0.5;    % GO beep amplitude (0..1)
cfg.play_metronome      = true;   % play the auditory metronome in epoch 1
cfg.metronome_amplitude = 0.30;   % metronome loudness (0..1)
cfg.tick_freq           = 1600;   % metronome click tone (Hz)
cfg.tick_dur            = 0.02;   % metronome click duration (s)

% % % % % % % % % % % % % % % % % % % % % %% ---------------- Stimuli ----------------
% % % % % % % % % % % % % % % % % % % % % % Self-contained sentence set (no external .tsv required). Edit/extend freely,
% % % % % % % % % % % % % % % % % % % % % % or read a file into cfg.sentences (a cell array of char rows) if you prefer.
% % % % % % % % % % % % % % % % % % % % % cfg.sentences = { ...
% % % % % % % % % % % % % % % % % % % % %     'Whistling winds whipped through weathered shutters during stormy nights.'
% % % % % % % % % % % % % % % % % % % % %     'The mountain river flowed swiftly past the quiet village.'
% % % % % % % % % % % % % % % % % % % % %     'Golden sunlight spilled across the open meadow at dawn.'
% % % % % % % % % % % % % % % % % % % % %     'She carefully folded each letter before sealing the envelope.'
% % % % % % % % % % % % % % % % % % % % %     };

%% ---------------- Task metadata ----------------
cfg.TASK          = 'metro';               % task name (used in output filenames)
cfg.TASK_VERSION  = 1;
cfg.TASK_FUNCTION = 'task_metronomic.m';   % main task file; must live in <PATH_TASK>/scripts

%% ---------------- Session-specific settings ----------------
switch cfg.SESSION_LABEL
    case 'preop'
        cfg.n_blocks = 2;
    case 'intraop'
        cfg.n_blocks = 3;
    otherwise
        error('Unknown session label: %s', cfg.SESSION_LABEL);
end

clc
close all force

%% ---------------- Paths & output folders ----------------
% Machine detection by hostname (cross-platform). To find a machine's hostname,
% run this one-liner on it:  char(java.net.InetAddress.getLocalHost.getHostName)
% NOTE: 'switch' is CASE-SENSITIVE, so each case must match the exact string that
%       machine returns. The Windows names below came from the old COMPUTERNAME
%       values and may differ from what getHostName returns - verify on each rig.
% Each case sets everything machine-specific: task/data paths AND whether to
% record audio (RECORD_AUDIO=1 only on rigs that have record_audio.m + interface).
computer_name = char(java.net.InetAddress.getLocalHost.getHostName);
switch computer_name
    case 'crc-dot1x-nat-10-239-35-5.bu.edu'                 % Kien's Mac
        cfg.PATH_TASK       = '/Users/kiendang/Documents/GitHub/Task_MetronomicSpeech';
        cfg.PATH_SOURCEDATA = '/Users/kiendang/Documents/Guenther_Lab_Data';
        cfg.RECORD_AUDIO    = 0;   % no lab recording setup on this machine

    case 'BML-ALIENWARE2'                                    % intraop rig laptop
        cfg.PATH_TASK       = 'D:\Task\Task_MetronomicSpeech';
        cfg.PATH_SOURCEDATA = 'D:\DBS\sourcedata';
        cfg.RECORD_AUDIO    = 1;   % rig has record_audio.m + interface

    case {'677-GUE-WL-0010','677-GUE-WL-0012','AMSMEIER'}    % AM Thinkpad X1 / strix laptops
        cfg.PATH_TASK       = 'C:\docs\code\Task_MetronomicSpeech';
        cfg.PATH_SOURCEDATA = 'C:\sourcedata';
        cfg.RECORD_AUDIO    = 1;

    otherwise
        warning('Unrecognized host "%s" - using fallback paths.', computer_name);
        cfg.PATH_TASK       = '~/git/Task_MetronomicSpeech';
        cfg.PATH_SOURCEDATA = '~/Data/DBS/sourcedata';
        cfg.RECORD_AUDIO    = 0;   % safe default for unknown machines
end
cfg.PATH_STIMDIR = fullfile(cfg.PATH_TASK, 'stimuli');

% Build subject/session-level folders for data storage
pathSub            = fullfile(cfg.PATH_SOURCEDATA, ['sub-' cfg.SUBJECT]);
pathSubSes         = fullfile(pathSub, ['ses-' cfg.SESSION_LABEL]);
pathSubSesDataType = fullfile(pathSubSes, cfg.DATA_TYPE);
pathSubSesAudio    = fullfile(pathSubSes, 'audio');

% Create output directories if they do not exist
for p = {cfg.PATH_SOURCEDATA, pathSub, pathSubSes, pathSubSesDataType, pathSubSesAudio}
    if ~isfolder(p{1}), mkdir(p{1}); end
end
cfg.PATH_AUDIO = pathSubSesAudio;

%% ---------------- Run basename, filenames ----------------
fileBaseName = ['sub-' cfg.SUBJECT '_ses-' cfg.SESSION_LABEL '_task-' cfg.TASK '_run-'];

% Increment run ID based on existing event files for this session
allEventFiles = dir(fullfile(pathSubSesDataType, [fileBaseName '*_events.tsv']));
if ~isempty(allEventFiles)
    prevRunIds = regexp({allEventFiles.name}, '_run-(\d+)_', 'tokens', 'ignorecase');
    prevRunIds = cellfun(@(x) str2double(x{1,1}), prevRunIds, 'UniformOutput', true);
    runId = max(prevRunIds) + 1;
else
    runId = 1;
end

cfg.RUN_ID       = runId;
cfg.PATH_LOG     = pathSubSesDataType;
cfg.BASE_NAME    = [fileBaseName, sprintf('%02d_', runId)];
cfg.LOG_FILENAME   = fullfile(cfg.PATH_LOG, [cfg.BASE_NAME 'log.txt']);
cfg.EVENT_FILENAME = fullfile(cfg.PATH_LOG, [cfg.BASE_NAME 'events.tsv']);
cfg.TRIAL_FILENAME = fullfile(cfg.PATH_LOG, [cfg.BASE_NAME 'trials.tsv']);
cfg.AUDIO_FILENAME = fullfile(cfg.PATH_AUDIO, [cfg.BASE_NAME(1:end-1) '.wav']);

%% ---------------- Diary (console logging) ----------------
diary(cfg.LOG_FILENAME);
oc = onCleanup(@() diary('off'));   % ensure diary closes when the function exits
disp(cfg);                          % echo config for the record

%% ---------------- Change to scripts folder ----------------
scriptPath = fullfile(cfg.PATH_TASK, 'scripts');
if ~isfolder(scriptPath)
    error('Scripts folder not found: %s', scriptPath);
end
cd(scriptPath);

%% ---------------- Start audio recording (optional) ----------------
% Runs only if cfg.RECORD_AUDIO == 1. Picks the recorder automatically:
%   - Rig path:     external record_audio.m on a parallel worker (needs the
%                   Parallel Computing Toolbox + interface).
%   - Laptop path:  built-in audiorecorder fallback (no toolbox, no interface).
% Either way the WAV lands at cfg.AUDIO_FILENAME.
if cfg.RECORD_AUDIO
    have_pct = exist('parpool','file') > 0 && exist('parfeval','file') > 0; % Parallel Computing Toolbox usable?
    have_lab = exist('record_audio','file') == 2;                           % lab worker recorder present?

    if have_pct && have_lab
        % --- Rig path: external recorder on a parallel worker ---
        if isempty(gcp())
            parpool('local',1);
        end
        workerQueueConstant = parallel.pool.Constant(@parallel.pool.PollableDataQueue);
        workerQueueClient   = fetchOutputs(parfeval(@(x) x.Value, 1, workerQueueConstant));

        future = parfeval(@record_audio, 1, cfg.AUDIO_FILENAME, workerQueueConstant);
        future.Diary; %#ok<NASGU>
        audioCleanup = onCleanup(@() send(workerQueueClient, 'stop')); %#ok<NASGU>
    else
        % --- Laptop fallback: built-in audiorecorder (no PCT / interface needed) ---
        if ~have_lab
            warning('record_audio.m not found - using laptop audiorecorder fallback.');
        elseif ~have_pct
            warning('Parallel Computing Toolbox unavailable - using laptop audiorecorder fallback.');
        end
        audioCleanup = record_audio_laptop_only(cfg.AUDIO_FILENAME); %#ok<NASGU>
    end
end

%% ---------------- Ripple neurophysiology hardware (optional) ----------------
% Self-skipping: only runs if the xippmex mex file is present on this machine.
cfg.DIGOUT = 0;
if exist('xippmex','file')==3
    try
        digout = xippmex();
        cfg.DIGOUT = digout ~= 0;
        xippmexCleanup = onCleanup(@() xippmex('close')); %#ok<NASGU>
    catch err
        warning('xippmex init failed: %s', err.message);
    end
end

%% ---------------- Launch task ----------------
fprintf('Launching task\n');
task_function = [pwd filesep cfg.TASK_FUNCTION];
if ~isfile(task_function)
    error('%s not found in current folder', cfg.TASK_FUNCTION);
end
copyfile(task_function, [cfg.PATH_LOG filesep cfg.BASE_NAME 'script.m']); % copy for reproducibility
feval(strrep(cfg.TASK_FUNCTION,'.m',''), cfg);                            % run task_metronomic(cfg)

close all;
end