function task_daf_MIDI(cfg)
% Runs the Delayed Auditory Feedback (DAF) task, controlling visuals, timing, logging,
% and MIDI control of Eventide H90
%
% Supports optional Psychtoolbox timing backend for high precision.
%
% Logs three TSV files:
%  - Events (cfg.EVENT_FILENAME): time-stamped experiment events
%  - Trials (cfg.TRIAL_FILENAME): trial metadata
%  - Commands (derived from cfg.EVENT_FILENAME): command send/ack tracking

%% Validate configuration and set defaults
% Check required folder presence
if ~isfield(cfg,'PATH_TASK') || ~isfolder(cfg.PATH_TASK)
    error('cfg.PATH_TASK missing or invalid.');
end

% Check that essential output file names are provided
if ~isfield(cfg,'EVENT_FILENAME') || ~isfield(cfg,'TRIAL_FILENAME')
    error('cfg EVENT/TRIAL filenames missing.');
end

% make sure .NET assembly is available for KeyPoll subfunction 
NET.addAssembly('PresentationCore');

%% Setup timing function backend: Psychtoolbox (PTB) or MATLAB native timer

% Configure timing functions for experiment
t0 = tic;                                  % Start baseline time
T.now   = @() toc(t0);                     % Relative current time in sec
T.wait  = @(s) pause(max(0,s));            % Wait via pause
T.until = @(t) pause(max(0, t - T.now())); % Wait until absolute time
T.backend = 'MATLAB';

fprintf('[Timing] Backend: %s\n', T.backend);

%% Open command log file to record serial command sends/ack
[cmdPath, cmdBase] = fileparts(cfg.EVENT_FILENAME);
cmdBase = strrep(cmdBase,'_events','_commands');
cmdFile = fullfile(cmdPath,[cmdBase '.tsv']);
cmdFH = fopen(cmdFile,'w');
fprintf(cmdFH, 't_send_getsecs\tcommand\targ1\targ2\tretries\tmessage\n'); % Write tab-separated header line to the commands log

%% Load and prepare trial table (double check files)
addpath(cfg.PATH_TASK);
if ~(exist('create_trials_table','file')==2)
    error('create_trials_table.m not found on path %s', cfg.PATH_TASK);
end
[cfg, trials, text_wrapped_all] = create_trials_table(cfg); % Create and load trial parameters table and wrapped text for display
cfg.ntrials = height(trials);

% Ensure a 'block' column exists for break handling
if cfg.n_blocks < 1, cfg.n_blocks = 1; end
if ~ismember('block', trials.Properties.VariableNames)
    if cfg.n_blocks == 1
        trials.block = ones(cfg.ntrials,1,'uint16');
    else
        edges = round(linspace(0, cfg.ntrials, cfg.n_blocks+1));
        blockVec = zeros(cfg.ntrials,1,'uint16');
        for b = 1:cfg.n_blocks
            if edges(b) < edges(b+1)
                blockVec(edges(b)+1 : edges(b+1)) = b;
            end
        end
        % In rare rounding cases, fill any zeros with last nonzero
        if any(blockVec==0)
            last = 1;
            for j = 1:cfg.ntrials
                if blockVec(j)==0, blockVec(j)=last; else, last=blockVec(j); end
            end
        end
        trials.block = blockVec;
    end
end

%% Open event log file and write header line
eventFH = fopen(cfg.EVENT_FILENAME, 'w');
fprintf(eventFH,'onset\tduration\tsample\ttrial_type\tstim\tvalue\tevent_code\n');


%% Setup graphics (visuals, stimulus text, photodiode square, keyboard callbacks)
cfg.text_color = [1 1 1];
cfg.background_color = [0 0 0];
screenSize = get(0,'ScreenSize');
hfig = figure('Name','DAF','Color',cfg.background_color,'MenuBar','none','ToolBar','none', 'Position',[0 0 screenSize(3) screenSize(4)], 'NumberTitle','off');

% Create full-figure invisible axes for holding text
ax = axes('Parent',hfig,'Position',[0 0 1 1],'Visible','off');

% Create text object centered on figure for stimuli
hText = text(0.5,0.5,'','Parent',ax,'Color',cfg.text_color,... % white text
    'FontSize',cfg.stim_font_size,'FontWeight','bold',...
    'HorizontalAlignment','center','VerticalAlignment','middle',...
    'Units','normalized','Interpreter','none');

% Small white square for photodiode timing marker (upper-left corner)
pdiode_square_length = 0.05;
hSquare = annotation('rectangle','FaceColor',[1 1 1],'EdgeColor','none', 'Position',[0, 1-pdiode_square_length, pdiode_square_length, pdiode_square_length]);

%% devices setup
% Define trigger code constants for event types
TRIG_FIX_CROSS = 1; % Fixation cross display
TRIG_VIS = 2; % Visual stimulus onset
TRIG_DAF = 4; % DAF delay change
TRIG_KEY = 8; % Key press event (space)
TRIG_ESC = 16; % Escape pressed
TRIG_BREAK = 64; % add break
TRIG_GO = 128; % GO beep

% Check if digital out is present
doDigOut = isfield(cfg,'DIGOUT') && logical(cfg.DIGOUT);

% Turn constant audio playback on
flipState = 0;

% find cc_val for 0ms delay
zero_delay_cc = delay_to_midi_ccval(0);

%% audio setup
cfg = setup_audio_devices(cfg); 
audWriter = audioDeviceWriter('SampleRate', cfg.aud_player_fs);
aud_dev_list = getAudioDevices(audWriter); 
aud_dev_out_ind = find(contains(aud_dev_list,cfg.aud_dev_out)); 
audWriter.Device = aud_dev_list{aud_dev_out_ind}; 

% create go beep
N  = round(cfg.go_beep_dur * cfg.aud_player_fs);
t  = (0:N-1)'/cfg.aud_player_fs;
go_beep_wave  = cfg.go_beep_amp*sin(2*pi*1000*t);


%% Show instructions screen and wait for space keypress or escape abort
if cfg.play_go_cue
    instructions = {
        'When text appears on the screen,',...
        'wait until you hear the beep,',...
        'then read it at your normal speaking speed.' ...
        '',...
        'Use a natural speaking voice.'
    };
elseif ~cfg.play_go_cue
    instructions = {
        'When text appears on the screen,',...
        'read it out loud',...
        'at your normal speaking speed.' ...
        '',...
        'Use a natural speaking voice.'
    };
end
set(hText,'String',instructions,'FontSize',45,'Color',cfg.text_color); drawnow;

% Wait for SPACE (ESC abort)
while true
    [space, esc] = KeyPoll();
    if esc
        flipState = ~flipState;
        log_event(eventFH, doDigOut, T.now(), [], [], 'control', [], TRIG_ESC, 'Key_Esc_At_Instructions', flipState);
        safeQuit(); fclose(eventFH); fclose(cmdFH); close(hfig); return;
    end
    if space
        flipState = ~flipState;
        log_event(eventFH, doDigOut, T.now(), [], [], 'control', [], TRIG_KEY, 'Key_Space', flipState);
        break;
    end
    T.wait(0.01);
end

set(hText,'String','');
drawnow;
t0 = T.now(); % Task start time anchor

% Send sync beep command to play sync tone on audio output
audWriter(go_beep_wave);
flipState = ~flipState;
log_event(eventFH, 0, t0, [], [], 'control', [], 0, 'Instructions_End', flipState);

%% Main trial loop
for itrial = 1:cfg.ntrials
    isCatch = trials.catch_trial(itrial);
    trials.delay(itrial) = trials.delay(itrial);

    % ITI + fixation
    set(hText,'String','*','Color', tern(~isCatch,[0.7 0.7 0.7],'red'));
    set(hSquare,'FaceColor',[0.3 0.3 0.3]);
    drawnow;
    tFixOn = T.now();
    flipState = ~flipState;
    log_event(eventFH, 0, GetSecs(), [], [], tern(isCatch,'catch','speech'), [], TRIG_FIX_CROSS, 'Fixation_Cross_Onset', flipState);

    % Keep fixation cross on for the jittered ITI duration
    itiDur = cfg.iti(1) + rand*(cfg.iti(2)-cfg.iti(1));
    T.wait(itiDur);

    % Send DAF ON command relative to fixation onset (if not catch trial)
    if ~isCatch
        if cfg.DAF_START_OFFSET_S ~= 0
            T.until(tFixOn + cfg.DAF_START_OFFSET_S);
        end

        % send midi command to device to set DAF delay value to the one specified for this trial
        midisend(cfg.midi_dev_idx, 'ControlChange', cfg.midi_chan, cfg.midi_cc_num, trials.midi_cc_val(itrial))

        flipState = ~flipState;
        log_event(eventFH, doDigOut, T.now(), [], [], 'speech', [], TRIG_DAF, sprintf('DAF_On_cmd(ms=%d)', trials.delay(itrial)), flipState);
        fprintf(['\n trial ',num2str(itrial), ' / ', num2str(cfg.ntrials), ',   delay = ', num2str(trials.delay(itrial)),'\n'])
    end

    % Visual on, fixation cross off
    set(hSquare,'FaceColor',[0 0 0]);
    set(hText,'String', text_wrapped_all{trials.stim_idx(itrial)}, 'Color',cfg.text_color,'FontSize',cfg.stim_font_size);
    drawnow;
    tVisOn = T.now();
    flipState = ~flipState;
    log_event(eventFH, doDigOut, tVisOn, [], [], tern(isCatch,'catch','speech'), trials.stim{itrial}, TRIG_VIS, 'Visual_Onset', flipState);

    
    % GO cue and reponse window
    if cfg.play_go_cue
        % preparatory window
        tPrepStart = T.now();
        while T.now() - tPrepStart < trials.go_latency(itrial) 
            [~, esc] = KeyPoll();
            if esc
                 % send midi command to device to set DAF delay value to zero
                 midisend(cfg.midi_dev_idx, 'ControlChange', cfg.midi_chan, cfg.midi_cc_num, zero_delay_cc)
    
                flipState = ~flipState;
                log_event(eventFH, doDigOut, T.now(), [], [], tern(isCatch,'catch','speech'), [], TRIG_ESC, 'Key_Esc', flipState);
                safeQuit(); fclose(eventFH); fclose(cmdFH); close(hfig); return
            end
            T.wait(0.005); % wait 5ms before running the loop again
        end

        % play go cue
        %%%% running sound.m usually takes about 25ms (regardless of the duration of the sounds)
        %%%% .... so getting tGoOn before starting playback will be this much earlier than getting it afterward
        audWriter(go_beep_wave);
        tGoOn = T.now();
        flipState = ~flipState;
        log_event(eventFH, doDigOut, tGoOn, [], [], tern(isCatch,'catch','speech'), [], TRIG_GO, 'Go_Beep_Onset', flipState);
        tSpeakStart = tGoOn; % speech window starts when go cue was played
    elseif ~cfg.play_go_cue % no go cue
        tSpeakStart = tVisOn; % speech window starts immeidately after visual cue
    end
    % % % % 
    % % % % elseif ~cfg.play_go_cue % no go cue - subject start speaking immediately after text appears

        % Speaking window
        %%%% this window starts either after the go beep (if cfg.play_go_cue==true, see above) or immediately after stim text appears
    while T.now() - tSpeakStart < cfg.response_window
        [~, esc] = KeyPoll();
        if esc
             % send midi command to device to set DAF delay value to zero
             midisend(cfg.midi_dev_idx, 'ControlChange', cfg.midi_chan, cfg.midi_cc_num, zero_delay_cc)

            flipState = ~flipState;
            log_event(eventFH, doDigOut, T.now(), [], [], tern(isCatch,'catch','speech'), [], TRIG_ESC, 'Key_Esc', flipState);
            safeQuit(); fclose(eventFH); fclose(cmdFH); close(hfig); return
        end
        T.wait(0.005); % wait 5ms before running the loop again
    end

    % % % % end

    % DAF ZERO
    if ~isCatch
         % send midi command to device to set DAF delay value to zero
         midisend(cfg.midi_dev_idx, 'ControlChange', cfg.midi_chan, cfg.midi_cc_num, zero_delay_cc)
    
        flipState = ~flipState;
        log_event(eventFH, doDigOut, T.now(), [], [], 'speech', [], TRIG_DAF, 'DAF_zero_cmd', flipState);
    end

    % Visual OFF, reset photodiode square
    set(hText,'String','');
    set(hSquare,'FaceColor',[1 1 1]);
    drawnow;
    tVisOff = T.now();
    flipState = ~flipState;
    log_event(eventFH, doDigOut, tVisOff, [], [], tern(isCatch,'catch','speech'), [], TRIG_VIS, 'Visual_Off', flipState);

    % Optional pause between trials (message in command window)
    if cfg.STOP_BETWEEN_TRIALS
        fprintf('Trial %d/%d complete. Press SPACE to continue...\n', itrial, cfg.ntrials);
        while true
            [space, esc] = KeyPoll();
            if esc
                 % send midi command to device to set DAF delay value to zero
                 midisend(cfg.midi_dev_idx, 'ControlChange', cfg.midi_chan, cfg.midi_cc_num, zero_delay_cc)
                flipState = ~flipState;
                log_event(eventFH, doDigOut, T.now(), [], [], tern(isCatch,'catch','speech'), [], TRIG_ESC, 'Key_Esc', flipState);
                safeQuit(); fclose(eventFH); fclose(cmdFH); close(hfig); return
            end
            if space
                break;
            end
            T.wait(0.01);
        end
    end

    % Append current trial row to trial results file
    if itrial == 1
        writetable(trials(itrial,:), cfg.TRIAL_FILENAME, 'Delimiter','\t','FileType','text', 'WriteVariableNames', true);
    else
        writetable(trials(itrial,:), cfg.TRIAL_FILENAME, 'Delimiter','\t','FileType','text', 'WriteMode','append', 'WriteVariableNames', false);
    end

    if cfg.n_blocks > 1
        currentBlock = trials.block(itrial);  % Current trial's block number
        blockTrials = find(trials.block == currentBlock);  % Trial indices in this block
        
        % If this is the last trial in the block and not the last overall trial
        if itrial == blockTrials(end) && itrial < cfg.ntrials
            flipState = ~flipState;
            log_event(eventFH, doDigOut, T.now(), [], [], 'control', [], TRIG_BREAK, sprintf('Block_%d_Break_Start', currentBlock), flipState);

            % Display break message on screen and console
            drawnow;
            fprintf('Block %d/%d finished; press spacebar to continue...\n', currentBlock, cfg.n_blocks);
            commandwindow %%% AM note: probably could replace this and next line using the KeyPoll function
            pause()

            if ~ishandle(hfig), break; end                 % window closed during break
            figure(hfig) % re-focus on stim window

            flipState = ~flipState;
            log_event(eventFH, doDigOut, T.now(), [], [], 'control', [], TRIG_BREAK, sprintf('Block_%d_Break_End', currentBlock), flipState);
            set(hText,'String',''); drawnow;
        end
    end
end

%% Cleanup
 % send midi command to device to set DAF delay value to zero
midisend(cfg.midi_dev_idx, 'ControlChange', cfg.midi_chan, cfg.midi_cc_num, zero_delay_cc)
if isfield(cfg, 'DAF_MIDI') && ~isempty(cfg.midi_dev_idx)
    release(cfg.midi_dev_idx)
end


fclose(eventFH);
fclose(cmdFH);
close(hfig);
fprintf('Task complete.\n');



%% SUBFUNCTIONS

function out = tern(cond, a, b)
    if cond, out=a; else, out=b; end
end

%%% function for getting Esc and Space keypress state
function [space, esc] = KeyPoll()
    space = System.Windows.Input.Keyboard.IsKeyDown(System.Windows.Input.Key.Space);
    esc   = System.Windows.Input.Keyboard.IsKeyDown(System.Windows.Input.Key.Escape);
end

function safeQuit()
    fprintf('ESC pressed → quitting task\n');
    if isfield(cfg, 'DAF_MIDI') && ~isempty(cfg.midi_dev_idx)
        cfg.midi_dev_idx = [];
    end
end

end