function START_METRO
% START_METRO - Launcher for the metronomic paced-speech task.
%
% build the cfg struct -> prepare paths,
% output folders and filenames -> (optionally) start audio recording and
% hardware -> launch the task function (task_metronomic.m), passing cfg.
%
% All configuration lives in the cfg struct below. The task function reads its
% parameters straight out of cfg, so this file is the single place to edit.

cfg = struct();

%% ---------------- Subject / session ----------------
cfg.SUBJECT     = 'qqq';  % <- use this for a test run
% cfg.SUBJECT     = 'metro-pilot003';  % <- use this for a test run

SUBJECT_METRO_RATE          = 3.6; % % set this rate for the subject after running assess

% cfg.SESSION = 'assess';   % run first during preop to measure sub's natural syllable rate
% cfg.SESSION = 'famil';      % run after assess (during preop) to familiarize sub w/ task at slow rate
cfg.SESSION = 'preop';    % run after 'famil' (during preop) to train sub on intraop task at full metro rate
% cfg.SESSION = 'intraop';    % 


%% ---------------- Run / session options ----------------
cfg.STOP_BETWEEN_TRIALS        = 1;          % require SPACE to start each trial - this value is ignored in assessment mode
cfg.iti                   = [0.5 1];   % jittered inter-trial interval (s)   [was iti_range in the demo]
cfg.max_trials            = inf;           % cap on total trials (inf = run them all)
cfg.randomize_order       = true;          % shuffle sentence order within each block; ignored in assess mode
cfg.trials_per_mini_block = 5;       % there will be at least this many trials of a condition in a row (ignored in assess mode)
cfg.pause_every_n_trials = 30;       % pause for a break at this interval (regardless of block length)
cfg.first_trial_is_metro = 1;       % force first trial to be metro (ignored in assess mode) 
cfg.intraop_to_preop_to_speed_ratio = 0.9; 
cfg.alternate_syl_colors_during_nonmetro = 1; % if true, alternate syl colors on all trials; if false, only do so on metro trials

%% ---------------- Metronomic task parameters ----------------
cfg.metro_dur      = 2;          % s the auditory metronome plays (pre-go epoch 1)
cfg.go_latency        = [0.5 1];  % jittered silent period (s) after metronome, before GO beep (epoch 2)
cfg.stim_font_size          = 80;           % stimulus font size
cfg.stim_max_char_per_line  = 26;       % wrap width for       the sentence (chars per line)

% cfg.text_colors = {[1 1 1], 0.3*[1 1 1]};
cfg.text_colors = {[1 1 1], [255, 199, 44]./255}; 

%% ---------------- Sounds ----------------
cfg.go_beep_freq        = 1000;   % GO beep tone (Hz)
cfg.go_beep_dur         = 0.05;   % GO beep duration (s)
cfg.go_beep_amp         = 0.5;    % GO beep amplitude (0..1)
cfg.play_metronome      = true;   % play the auditory metronome in epoch 1
cfg.metronome_amplitude = 0.30;   % metronome loudness (0..1)
cfg.tick_freq           = 1600;   % metronome click tone (Hz)
cfg.tick_dur            = 0.02;   % metronome click duration (s)

%% ---------------- Task metadata ----------------
cfg.TASK          = 'metro';               % task name (used in output filenames)
cfg.TASK_VERSION  = 1;
cfg.TASK_FUNCTION = 'task_metro.m';   % main task file; must live in <PATH_TASK>/scripts

%% ---------------- Session-specific settings ----------------
switch cfg.SESSION
    case 'assess' 
        cfg.metro_rate = nan;         % no metro trials in this phase
        cfg.speech_window_dur       = 7;            % s between GO beep onset and visual stimulus disappearing
        cfg.n_blocks = 1;
        cfg.stim_file = 'stim_test.tsv'; 
%         cfg.stim_file = 'stim_test_2stim.tsv'; 
        cfg.DIGOUT = 0;
        cfg.assess_syllable_rate = 1; 
            cfg.speech_rms_thresh_amp = 0.005; %%% assess mode: amplitute thresh for speech detection
            cfg.speech_rms_thresh_dur = 0.01; %%% assess mode: min above-thresh time required for speech detection
            cfg.assess_wait_after_go  = 0.25; % asses mode: don't start looking for speech until this long after beep
    case 'famil' 
        cfg.metro_rate = 2;         % rate in Hz of audio metronome
        cfg.speech_window_dur       = 8;            % s between GO beep onset and visual stimulus disappearing

        cfg.n_blocks = 1;
        cfg.stim_file = 'stim_test.tsv'; 
        cfg.DIGOUT = 0;
        cfg.assess_syllable_rate = 0; 
    case 'preop'
        cfg.metro_rate = SUBJECT_METRO_RATE;    % use the rate that was determined during assess
        cfg.speech_window_dur       = 7;            % s between GO beep onset and visual stimulus disappearing
        cfg.n_blocks = 2;
        cfg.stim_file = 'metro_15syl_10sent'
%         cfg.stim_file = 'metro_15syl_9sent.tsv'; 
        cfg.DIGOUT = 0;
        cfg.assess_syllable_rate = 0; 
    case 'intraop'
        cfg.metro_rate = SUBJECT_METRO_RATE;    % use the rate that was determined during assess
        cfg.speech_window_dur       = 7;            % s between GO beep onset and visual stimulus disappearing
        cfg.n_blocks = 3;
        cfg.stim_file = 'stim_test.tsv'; 
%         cfg.stim_file = 'daf_sentences_intraop_single.tsv'; 
        cfg.DIGOUT = 1;
        cfg.assess_syllable_rate = 0; 
    otherwise
        error('Unknown session label: %s', cfg.SESSION);
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


    case 'BML-ALIENWARE2'                                    % intraop rig laptop
        cfg.PATH_TASK       = 'D:\Task\Task_MetronomicSpeech';
        cfg.PATH_SOURCEDATA = 'D:\DBS\sourcedata';
        cfg.RECORD_AUDIO    = 1;   % rig has record_audio.m + interface

    case {'677-GUE-WL-0010','677-GUE-WL-0012','amsmeier'}    % AM Thinkpad X1 / strix laptops
        cfg.PATH_TASK       = 'C:\docs\code\Task_MetronomicSpeech';
        cfg.PATH_SOURCEDATA = 'C:\sourcedata';
        cfg.RECORD_AUDIO    = 1;

    case '677-GUE-WD-0013' % Guenther lab soundbooth computer
        cfg.PATH_TASK       = 'C:\Task_MetronomicSpeech';
        cfg.PATH_SOURCEDATA = 'C:\Task_MetronomicSpeech_sourcedata';
        cfg.RECORD_AUDIO    = 1;   %
        
    case 'crc-dot1x-nat-10-239-35-5.bu.edu'   % Kien Dang's mac (made early script version)
        cfg.PATH_TASK       = '/Users/kiendang/Documents/GitHub/Task_MetronomicSpeech';
        cfg.PATH_SOURCEDATA = '/Users/kiendang/Documents/Guenther_Lab_Data';
        cfg.RECORD_AUDIO    = 0;   %

    otherwise
        warning('Unrecognized host "%s" - using fallback paths.', computer_name);
        cfg.PATH_TASK       = '~/git/Task_MetronomicSpeech';
        cfg.PATH_SOURCEDATA = '~/Data/DBS/sourcedata';
        cfg.RECORD_AUDIO    = 0;   % safe default for unknown machines
end
cfg.PATH_STIMDIR = fullfile(cfg.PATH_TASK, 'stimuli');

% Build subject/session-level folders for data storage
cfg.PATH_SUB            = fullfile(cfg.PATH_SOURCEDATA, ['sub-' cfg.SUBJECT]);
cfg.PATH_SES         = fullfile(cfg.PATH_SUB, ['ses-' cfg.SESSION]);
cfg.PATH_AUDIO    = fullfile(cfg.PATH_SES, 'audio');
cfg.PATH_SRC_TASK    = fullfile(cfg.PATH_SES, 'task');

%% ---------------- Run basename, filenames ----------------
fileBaseName = ['sub-' cfg.SUBJECT '_ses-' cfg.SESSION '_task-' cfg.TASK '_run-'];

% Increment run ID based on existing event files for this session
allEventFiles = dir(fullfile(cfg.PATH_SRC_TASK, [fileBaseName '*_events.tsv']));
if ~isempty(allEventFiles)
    prevRunIds = regexp({allEventFiles.name}, '_run-(\d+)_', 'tokens', 'ignorecase');
    prevRunIds = cellfun(@(x) str2double(x{1,1}), prevRunIds, 'UniformOutput', true);
    runId = max(prevRunIds) + 1;
else
    runId = 1;
end

cfg.RUN_ID       = runId;
cfg.BASE_NAME    = [fileBaseName, sprintf('%02d_', runId)];
cfg.LOG_FILENAME   = fullfile(cfg.PATH_SRC_TASK, [cfg.BASE_NAME 'log.txt']);
cfg.EVENT_FILENAME = fullfile(cfg.PATH_SRC_TASK, [cfg.BASE_NAME 'events.tsv']);
cfg.TRIAL_FILENAME = fullfile(cfg.PATH_SRC_TASK, [cfg.BASE_NAME 'trials.tsv']);
cfg.AUDIO_FILENAME = fullfile(cfg.PATH_AUDIO, [cfg.BASE_NAME(1:end-1) '.wav']);

%% ---------------- Create output directories ----------------
% Must exist before diary / fopen calls that write into them.
dirs_to_make = {cfg.PATH_SUB, cfg.PATH_SES, cfg.PATH_AUDIO, cfg.PATH_SRC_TASK};
for i = 1:numel(dirs_to_make)
    if ~isfolder(dirs_to_make{i})
        mkdir(dirs_to_make{i});
    end
end

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
copyfile(task_function, [cfg.PATH_SRC_TASK filesep cfg.BASE_NAME 'script.m']); % copy for reproducibility
feval(strrep(cfg.TASK_FUNCTION,'.m',''), cfg);                            % run task_metronomic(cfg)

close all;
end