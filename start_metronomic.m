function START_DAF_MIDI
% start_daf_intraop_MIDI - Intraoperative launcher for the Delayed Auditory Feedback (DAF) task
%
% This function configures and launches task_daf_midi, which controls
% the experiment presentation, timing, and communication with the H90 Eventide.
% It sets default parameters, prepares paths and logging filenames, initializes
% optional audio recording and hardware interfaces, and launches the task script.
%
% No input arguments; all configuration is inside the function.
%
% The configuration is stored in the 'cfg' struct, passed to the task function.

cfg = struct();


%% Setup experiment configuration      % -------------------------------------------------------------------------

cfg.SUBJECT       = 'DM1060';   % Subject identifier
% cfg.SUBJECT       = 'daftest';   % Subject identifier

% cfg.SESSION_LABEL = 'preop';      % Label for session type (e.g., intraop, preop)
cfg.SESSION_LABEL = 'intraop'; 

preop_delay_values_ms =  [0 50 110 170 230 280]; 
intraop_delay_values_ms = [0 50 255]; % intended to be be [0, low-delay, high-delay]

% --------------------------------------------------------------------------------------------------- 


%%
cfg.DATA_TYPE     = 'task';         % Data type for folder structure
cfg.RECORD_AUDIO  = 1;          % Whether to record microphone audio during the task
cfg.PTB           = false;          % Use Psychtoolbox for timing and display (false disables it)
cfg.STOP_BETWEEN_TRIALS = 1;     % Require space to proceed between all trials (after ITI plays)
    cfg.iti = [0.75, 1.25]; % Inter-trial interval range in seconds - 1sec seems appropriate for when there is pause for spacebar press between trials
%     cfg.iti = [1.75, 2.25]; % Inter-trial interval range in seconds - 2sec seems appropriate for when there's no pause for spacebar press between trials
% ----------------------------------
cfg.midi_dev_name = 'H90 Pedal';      % name of Stepp Lab usb-  to-midi adapter from mididevinfo.m
cfg.midi_chan  = 1;              % Set to MIDI channel as per hardware... should have been pre-set on the midi device
cfg.midi_cc_num = 1;        % MIDI control change number .... should have been pre-set on the midi device

% Task metadata
cfg.TASK          = 'daf';              % Task name
cfg.TASK_VERSION  = 5;                  % Version number
cfg.TASK_FUNCTION = 'task_daf_midi.m';  % Task main function filename

% trial number, condition, and timing params
cfg.max_trials             = inf;     % Maximum number of trials (inf = unlimited)
cfg.stim_font_size         = 60;      % Font size of stimulus text
cfg.stim_max_char_per_line = 30;      % Maximum characters per line in stimulus text
cfg.catchRatio             = 0;       % Probability of catch trials (no auditory feedback)... not tested recently
cfg.same_trials_across_blocks = 0; % Use same trials repeated across blocks
cfg.DAF_START_OFFSET_S = 0.000;       % Optional time offset between fixation and DAF start

% beep params - played at beginning of run, and optionally as go cue
cfg.go_beep_dur = 0.05;         % go beep duration in sec
cfg.go_beep_amp = 0.5; % go beep amplitude (zero to one)

%% go cue options
cfg.play_go_cue = true;                     % make subject wait for go beep following stim onset before speaking; if false, don't play go beep  
    cfg.go_latency = [1.5 2.5];         % if play_go_cue==true, this is the jittered time in sec between visual stim onset and go cue onset

%% block-design and stimulus repetition options
cfg.delay_block_design = 1;             % if true, then organize trials into consecutive trials of 'miniblocks' which all have the same delay
    cfg.randomize_miniblock_order = 1;     % if false, then order of delay miniblocks within a block will be repeated
    cfg.max_delay_repeats      = inf;       % Max repeats per delay condition... not used if we are using delay block design
    cfg.max_stim_repeats       = inf;       % Max number of repeats per stimulus... not used if we are using delay block design
    
%%

%%%%%% Stimulus sentences file per session
% Set delay values and number of blocks according to session type
switch cfg.SESSION_LABEL
    case 'preop'

        cfg.delay_values_ms = preop_delay_values_ms; % 
%         cfg.delay_values_ms = [150]; % 
        cfg.n_blocks = 2;

        cfg.daf_stim_file = 'daf_sentences_preop_single.tsv';        
        cfg.response_window          = 6;      % time subject has to speak; either text duration (if no go beep), or text duration after go beep
        cfg.trials_per_mini_block = 5;  % number of trials within a 'mini block' of repeated delay values


    case 'intraop'
        cfg.delay_values_ms = intraop_delay_values_ms; % zero condition, low delay (fluency-enhancing) condition, high delay (disfluency-inducing) condition
        cfg.n_blocks = 3;


        cfg.daf_stim_file = 'daf_sentences_intraop_single.tsv';
        cfg.response_window          = 6;      % time subject has to speak; either text duration (if no go beep), or text duration after go beep
        cfg.trials_per_mini_block = 5;  % number of trials within a 'mini block' of repeated delay values

    otherwise
        error('Unknown session label: %s', cfg.SESSION_LABEL);
end 

clc
close all force

%% MIDI setup
devs = mididevinfo; %%% must have audio toolbox; this function not available before Matlab R2018a
outNames = string({devs.output.Name});
ix = find(contains(lower(outNames), lower(cfg.midi_dev_name), 'IgnoreCase', true), 1);

if isempty(ix)
    warning('MIDI out "%s" not found. Available: %s', cfg.midi_dev_name, strjoin(outNames, ', '));
    cfg.midi_dev_idx = []; % allow visuals only fallback
else
    cfg.midi_dev_idx = mididevice('Output', outNames(ix));
end

% Log a quick probe for audit
fprintf('[MIDI] Outputs available:\n');
for i = 1:numel(outNames)
    sel = "";
    if i == ix
        sel = "  [SELECTED]";
    end
    fprintf('  - %s%s\n', outNames(i), sel);
end
if isempty(cfg.midi_dev_idx)
    warning('Running WITHOUT DAF (no MIDI device). Visuals/logging only.');
end


%% Paths & output folders
if strcmpi(getenv('COMPUTERNAME'), 'BML-ALIENWARE2') % intraop rig laptop
    cfg.PATH_TASK       = 'D:\Task\Task_DelayedAuditoryFeedback';
    cfg.PATH_SOURCEDATA = 'D:\DBS\sourcedata';

elseif any(strcmpi(getenv('COMPUTERNAME'), {'677-GUE-WL-0010','677-GUE-WL-0012','AMSMEIER'} )) % AM Thinkpad X1 laptops, strix laptop
    cfg.PATH_TASK       = 'C:\docs\code\Task_DelayedAuditoryFeedback';
    cfg.PATH_SOURCEDATA = 'C:\sourcedata'; 

elseif ismac
    cfg.PATH_TASK       = '/Users/samhansen/Documents/MATLAB/Guenther/Task_DelayedAuditoryFeedback/';
    cfg.PATH_SOURCEDATA = '/Users/samhansen/Documents/MATLAB/Guenther/Task_DelayedAuditoryFeedback/stimuli';
else
    cfg.PATH_TASK       = '~/git/Task_DelayedAuditoryFeedback';
    cfg.PATH_SOURCEDATA = '~/Data/DBS/sourcedata';
end
cfg.PATH_STIMDIR = [cfg.PATH_TASK, filesep, 'stimuli']; 

% Build subject/session level folders for data storage
pathSub = fullfile(cfg.PATH_SOURCEDATA, ['sub-' cfg.SUBJECT]);
pathSubSes = fullfile(pathSub, ['ses-' cfg.SESSION_LABEL]);
pathSubSesDataType = fullfile(pathSubSes, cfg.DATA_TYPE);
pathSubSesAudio = fullfile(pathSubSes, 'audio');

% Create output directories if they do not exist
for p = {cfg.PATH_SOURCEDATA, pathSub, pathSubSes, pathSubSesDataType, pathSubSesAudio}
    if ~isfolder(p{1}), mkdir(p{1}); end
end
cfg.PATH_AUDIO = pathSubSesAudio;



%% Run basename, filenames
fileBaseName  = ['sub-' cfg.SUBJECT '_ses-' cfg.SESSION_LABEL '_task-' cfg.TASK '_run-'];

% Check existing event files to increment run ID for this session
allEventFiles = dir(fullfile(pathSubSesDataType, [fileBaseName '*_events.tsv']));
if ~isempty(allEventFiles)
    prevRunIds = regexp({allEventFiles.name}, '_run-(\d+)_', 'tokens', 'ignorecase');
    prevRunIds = cellfun(@(x) str2double(x{1,1}), prevRunIds, 'UniformOutput', true);
    runId = max(prevRunIds) + 1;
else
    runId = 1;
end

% Assign run ID and generate file paths for logs and audio
cfg.RUN_ID = runId;
cfg.PATH_LOG = pathSubSesDataType;
cfg.BASE_NAME = [fileBaseName, sprintf('%02d_', runId)];
cfg.LOG_FILENAME = fullfile(cfg.PATH_LOG, [cfg.BASE_NAME 'log.txt']);
cfg.EVENT_FILENAME = fullfile(cfg.PATH_LOG, [cfg.BASE_NAME 'events.tsv']);
cfg.TRIAL_FILENAME = fullfile(cfg.PATH_LOG, [cfg.BASE_NAME 'trials.tsv']);
cfg.AUDIO_FILENAME = fullfile(cfg.PATH_AUDIO, [cfg.BASE_NAME(1:end-1) '.wav']);

%% Start MATLAB diary for logging console output to log file
diary(cfg.LOG_FILENAME);
oc = onCleanup(@() diary('off')); % Ensure diary is turned off when function exits
disp(cfg);  % Display config for verification


%% Change to scripts folder
scriptPath = fullfile(cfg.PATH_TASK, 'scripts');
if ~isfolder(scriptPath)
    error('Scripts folder not found: %s', scriptPath);
end
cd(scriptPath);

%% Start audio recording (optional)
% parallel worker for external audio recording 
if cfg.RECORD_AUDIO
    if isempty(gcp())
        parpool('local',1);
    end
    workerQueueConstant = parallel.pool.Constant(@parallel.pool.PollableDataQueue);
    workerQueueClient   = fetchOutputs(parfeval(@(x) x.Value, 1, workerQueueConstant));

    %%% record audio via parallel pool function
    % we could add an option to call 'record_audio_laptop_only' instead of 'record_audio' if focusrite is not detected
    future = parfeval(@record_audio, 1, cfg.AUDIO_FILENAME, workerQueueConstant);
    future.Diary;
    onCleanupTasks{6} = onCleanup(@() send(workerQueueClient, 'stop'));

end



%% Ripple neurophysiology hardware communication setup (optional)
cfg.DIGOUT = 0;
if exist('xippmex','file')==3
    try
        digout = xippmex();  % Initialize hardware interface
        cfg.DIGOUT = digout ~=0;
        xippmexCleanup = onCleanup(@() xippmex('close'));
    catch err
        warning('xippmex init failed: %s', err.MESSAGE);
    end
end

%% Launch task
fprintf('Launching task\n');
task_function = [pwd filesep cfg.TASK_FUNCTION];
if ~isfile(task_function)
    error('%s not found in current folder', cfg.TASK_FUNCTION);
end
copyfile(task_function, [cfg.PATH_LOG filesep cfg.BASE_NAME 'script.m']); % Copy the task function file to the log folder for reproducibility
feval(strrep(cfg.TASK_FUNCTION,'.m',''), cfg); % Execute the task function, passing full config struct

close all;
end