function task_metro(cfg)
% task_metro  Run the metronomic-speech task (non-PsychToolbox).
%
% Trial structure
%  1. ITI — fixation cross, jittered duration (cfg.iti)
%  2. Stimulus epoch  (cfg.metro_dur s, begins at visual onset)
%       metro_speech trial : audio metronome at cfg.metro_rate Hz
%       speech-only trial  : identical timing, silence, no metro log events
%  3. Jittered silent delay (trials.go_latency s, pre-computed per trial)
%  4. GO beep  (if cfg.play_go_cue)
%  5. Speech window  (cfg.speech_window_dur s)
%  6. Visual off
%
% Speech Rate Assessment Mode (cfg.assess_syllable_rate = true)
%  - Runs non-metronomic trials only.
%  - Displays docked GUI waveform figure with mic input.
%  - Displays trial number, stimulus text, and syllable count.
%  - Includes Up/Down arrow buttons to adjust RMS thresh amp & dur on the fly.
%  - Parameters carry over from trial to trial within the run.
%  - Computes RMS speech onset and offset over an extended speech window.
%  - Allows user to click and drag onset/offset markers.
%  - Interactive "Accept trial", "Reject trial", and "Quit task (Esc)" GUI buttons.
%  - Outputs speech duration metrics and syllable rate (Hz) summary.
%  - Copies speed-ratio-adjusted speech rate to system clipboard.

%% ---- Default optional fields ----------------------------------------
if ~isfield(cfg,'play_go_cue'),                    cfg.play_go_cue                    = true;  end
if ~isfield(cfg,'STOP_BETWEEN_TRIALS'),            cfg.STOP_BETWEEN_TRIALS            = false; end
if ~isfield(cfg,'pause_every_n_trials'),           cfg.pause_every_n_trials           = inf;   end
if ~isfield(cfg,'speech_window_dur'),              cfg.speech_window_dur              = 5;     end

% Syllable rate assessment & display options
if ~isfield(cfg,'assess_syllable_rate'),           cfg.assess_syllable_rate           = false; end
if ~isfield(cfg,'speech_rms_thresh_amp'),          cfg.speech_rms_thresh_amp          = 0.03;  end
if ~isfield(cfg,'speech_rms_thresh_dur'),          cfg.speech_rms_thresh_dur          = 0.01;  end
if ~isfield(cfg,'intraop_to_preop_to_speed_ratio'),cfg.intraop_to_preop_to_speed_ratio = 0.9;   end
if ~isfield(cfg,'alternate_syl_colors_during_nonmetro')
    cfg.alternate_syl_colors_during_nonmetro = true;
end
if ~isfield(cfg,'text_colors') || isempty(cfg.text_colors)
    cfg.text_colors = {[1 1 1], [0.7 0.7 0.7]};
end

%% ---- Validate -------------------------------------------------------
if ~isfield(cfg,'PATH_TASK') || ~isfolder(cfg.PATH_TASK)
    error('cfg.PATH_TASK missing or invalid.');
end
if ~isfield(cfg,'EVENT_FILENAME') || ~isfield(cfg,'TRIAL_FILENAME')
    error('cfg.EVENT_FILENAME and cfg.TRIAL_FILENAME are required.');
end

%% ---- .NET keyboard --------------------------------------------------
NET.addAssembly('PresentationCore');

%% ---- Shared GUI state variables -------------------------------------
speech_wave  = [];
speechWinDur = cfg.speech_window_dur;
hLineOn      = [];
hLineOff     = [];
hTextOn      = [];
hTextOff     = [];

%% ---- Timing helpers -------------------------------------------------
ticH  = tic;
t0abs = seconds(timeofday(datetime('now')));  % s-since-midnight at task start
T.now   = @()  t0abs + toc(ticH);
T.wait  = @(s) pause(max(0, s));
T.until = @(t) pause(max(0, t - T.now()));

%% ---- Build trial table ----------------------------------------------
addpath(cfg.PATH_TASK);
[cfg, trials, text_wrapped_all] = create_trials_table_metro(cfg);

% Extract syllable count 'n_syl' from stim table if present
stimtablePath = fullfile(cfg.PATH_STIMDIR, cfg.stim_file);
if isfile(stimtablePath)
    stimtable = readtable(stimtablePath, 'FileType', 'text', 'Delimiter', 'tab');
    if ismember('n_syl', stimtable.Properties.VariableNames)
        trials.n_syl = stimtable.n_syl(trials.stim_idx);
    end
end

% In assessment mode: restrict to non-metronomic trials only
if cfg.assess_syllable_rate
    trials = trials(~trials.metro_speech, :);
    trials.trialnum = (1:height(trials))';
    
    % Add assessment tracking columns
    trials.include_trial_for_assess = false(height(trials), 1);
    trials.speech_on_for_assess     = nan(height(trials), 1);
    trials.speech_off_for_assess    = nan(height(trials), 1);
    trials.speech_dur_for_assess    = nan(height(trials), 1);
end

cfg.ntrials = height(trials);

%% ---- Ensure output directories exist --------------------------------
for fn = {'EVENT_FILENAME','TRIAL_FILENAME'}
    d = fileparts(cfg.(fn{1}));
    if ~isempty(d) && ~isfolder(d), mkdir(d); end
end

%% ---- Event log (BIDS TSV header) ------------------------------------
eventFH = fopen(cfg.EVENT_FILENAME,'w');
fprintf(eventFH,'onset\tduration\tsample\ttrial_type\tstim\tvalue\tevent_code\n');

%% ---- Display setup --------------------------------------------------
cfg.text_color       = [1 1 1];
cfg.background_color = [0 0 0];
ss   = get(0,'ScreenSize');
hfig = figure('Name','Metro Task','Color',cfg.background_color, ...
    'MenuBar','none','ToolBar','none','NumberTitle','off', ...
    'Position',[0 0 ss(3) ss(4)]);
ax    = axes('Parent',hfig,'Position',[0 0 1 1],'Visible','off');
hText = text(0.5,0.5,'','Parent',ax,'Color',cfg.text_color, ...
    'FontSize',cfg.stim_font_size,'FontWeight','bold', ...
    'HorizontalAlignment','center','VerticalAlignment','middle', ...
    'Units','normalized','Interpreter','tex');
pdLen   = 0.05;
hSquare = annotation('rectangle','FaceColor',[1 1 1],'EdgeColor','none', ...
    'Position',[0, 1-pdLen, pdLen, pdLen]);

%% ---- Assessment GUI Setup -------------------------------------------
hGui = [];
if cfg.assess_syllable_rate
    hGui = figure('Name', 'Speech Rate Assessment GUI', 'NumberTitle', 'off', ...
        'WindowStyle', 'docked');
    
    % Header text: Trial number, stimulus, and syllable count
    txtInfo = uicontrol('Parent', hGui, 'Style', 'text', 'Units', 'normalized', ...
        'Position', [0.05, 0.88, 0.90, 0.10], 'FontSize', 12, 'FontWeight', 'bold', ...
        'HorizontalAlignment', 'center', 'BackgroundColor', get(hGui, 'Color'));

    % Waveform axes
    axGui = axes('Parent', hGui, 'Position', [0.08, 0.28, 0.88, 0.58]);
    xlabel(axGui, 'Time (s)');
    ylabel(axGui, 'Amplitude');
    title(axGui, 'Trial Speech Waveform');
    grid(axGui, 'on');

    % RMS Threshold Amp controls (Label + Up/Down buttons)
    txtAmp = uicontrol('Parent', hGui, 'Style', 'text', 'Units', 'normalized', ...
        'Position', [0.05, 0.18, 0.20, 0.05], 'FontSize', 11, ...
        'HorizontalAlignment', 'right', 'BackgroundColor', get(hGui, 'Color'), ...
        'String', sprintf('RMS Amp: %.3f', cfg.speech_rms_thresh_amp));
    btnAmpDown = uicontrol('Parent', hGui, 'Style', 'pushbutton', 'String', '?', ...
        'Units', 'normalized', 'Position', [0.26, 0.18, 0.05, 0.05], 'FontSize', 11, ...
        'Callback', @(~,~) adjust_amp(-0.005));
    btnAmpUp   = uicontrol('Parent', hGui, 'Style', 'pushbutton', 'String', '?', ...
        'Units', 'normalized', 'Position', [0.32, 0.18, 0.05, 0.05], 'FontSize', 11, ...
        'Callback', @(~,~) adjust_amp(+0.005));

    % RMS Threshold Dur controls (Label + Up/Down buttons)
    txtDur = uicontrol('Parent', hGui, 'Style', 'text', 'Units', 'normalized', ...
        'Position', [0.45, 0.18, 0.20, 0.05], 'FontSize', 11, ...
        'HorizontalAlignment', 'right', 'BackgroundColor', get(hGui, 'Color'), ...
        'String', sprintf('RMS Dur: %.3f s', cfg.speech_rms_thresh_dur));
    btnDurDown = uicontrol('Parent', hGui, 'Style', 'pushbutton', 'String', '?', ...
        'Units', 'normalized', 'Position', [0.66, 0.18, 0.05, 0.05], 'FontSize', 11, ...
        'Callback', @(~,~) adjust_dur(-0.002));
    btnDurUp   = uicontrol('Parent', hGui, 'Style', 'pushbutton', 'String', '?', ...
        'Units', 'normalized', 'Position', [0.72, 0.18, 0.05, 0.05], 'FontSize', 11, ...
        'Callback', @(~,~) adjust_dur(+0.002));

    % Accept / Reject / Quit task buttons
    btnAccept = uicontrol('Parent', hGui, 'Style', 'pushbutton', 'String', 'Accept trial', ...
        'Units', 'normalized', 'Position', [0.05, 0.03, 0.25, 0.10], ...
        'FontSize', 12, 'FontWeight', 'bold', 'Enable', 'off');
    btnReject = uicontrol('Parent', hGui, 'Style', 'pushbutton', 'String', 'Reject trial', ...
        'Units', 'normalized', 'Position', [0.37, 0.03, 0.25, 0.10], ...
        'FontSize', 12, 'FontWeight', 'bold', 'Enable', 'on');
    btnQuit   = uicontrol('Parent', hGui, 'Style', 'pushbutton', 'String', 'Quit task (Esc)', ...
        'Units', 'normalized', 'Position', [0.69, 0.03, 0.25, 0.10], ...
        'FontSize', 12, 'FontWeight', 'bold', 'Enable', 'on');
end

%% ---- Trigger codes --------------------------------------------------
TRIG_FIX_CROSS  = 1;
TRIG_VIS        = 2;
TRIG_METRONOME  = 4;
TRIG_METRO_TICK = 8;
TRIG_GO         = 16;
TRIG_KEY        = 32;
TRIG_ESC        = 64;
TRIG_BREAK      = 128;

doDigOut  = isfield(cfg,'DIGOUT') && logical(cfg.DIGOUT);
flipState = 0;

%% ---- Audio setup ----------------------------------------------------
cfg = setup_audio_devices(cfg);

audWriter        = audioDeviceWriter('SampleRate', cfg.aud_player_fs);
aud_dev_list     = getAudioDevices(audWriter);
idx              = find(contains(aud_dev_list, cfg.aud_dev_out), 1);
audWriter.Device = aud_dev_list{idx};
audWriter.SupportVariableSizeInput = true;

CHUNK_SIZE = 512;

% GO beep waveform
N_go         = round(cfg.go_beep_dur * cfg.aud_player_fs);
t_go         = (0:N_go-1)' / cfg.aud_player_fs;
go_beep_wave = cfg.go_beep_amp * sin(2*pi * cfg.go_beep_freq * t_go);

% Single metronome tick waveform
N_tick           = round(cfg.tick_dur * cfg.aud_player_fs);
t_tick_v         = (0:N_tick-1)' / cfg.aud_player_fs;
tick_wave_single = cfg.metronome_amplitude * sin(2*pi * cfg.tick_freq * t_tick_v);

% Tick schedule
tick_rel_times = (0 : floor(cfg.metro_dur * cfg.metro_rate))' / cfg.metro_rate;
tick_rel_times = tick_rel_times(tick_rel_times < cfg.metro_dur + 1e-9);
n_ticks        = numel(tick_rel_times);

metro_total_samples = round(cfg.metro_dur * cfg.aud_player_fs);
metro_wave          = zeros(metro_total_samples, 1);
for itick_pre = 1:n_ticks
    s1 = round(tick_rel_times(itick_pre) * cfg.aud_player_fs) + 1;
    s2 = min(s1 + N_tick - 1, metro_total_samples);
    metro_wave(s1:s2) = tick_wave_single(1:(s2-s1+1));
end

% Set up microphone input device for speech rate assessment
micReader = [];
if cfg.assess_syllable_rate
    nChansIn = 1;
    if isfield(cfg, 'n_chans_in') && ~isempty(cfg.n_chans_in)
        nChansIn = cfg.n_chans_in;
    end
    try
        micReader = audioDeviceReader('SampleRate', cfg.aud_player_fs, ...
            'Device', cfg.aud_dev_in, 'NumChannels', nChansIn);
        setup(micReader);
    catch err
        warning('Failed to open microphone input device "%s": %s', cfg.aud_dev_in, err.message);
        micReader = [];
    end
end

%% ---- Instructions screen --------------------------------------------
set(hText,'String',{ ...
    'When text appears on the screen,', ...
    'wait until you hear the beep,', ...
    'then read it at your normal speaking speed.', ...
    '', 'Use a natural speaking voice.'}, ...
    'FontSize',45,'Color',cfg.text_color);
drawnow;

while true
    [space,esc] = KeyPoll();
    if esc
        flipState = ~flipState;
        log_event(eventFH,doDigOut,T.now(),[],[],'control',[],TRIG_ESC,'Key_Esc_At_Instructions',flipState);
        fclose(eventFH); close(hfig); 
        if ishandle(hGui), close(hGui); end
        return;
    end
    if space
        flipState = ~flipState;
        log_event(eventFH,doDigOut,T.now(),[],[],'control',[],TRIG_KEY,'Key_Space_Instructions',flipState);
        break;
    end
    T.wait(0.01);
end
set(hText,'String',''); drawnow;

% Sync beep + task-start marker
audWriter(go_beep_wave);
t_task_start = T.now();
flipState    = ~flipState;
log_event(eventFH,doDigOut,t_task_start,[],[],'control',[],0,'Task_Start',flipState);

%% =====================================================================
%%  Main trial loop
%% =====================================================================
escaped = false;

for itrial = 1:cfg.ntrials

    if trials.metro_speech(itrial)
        ttype = 'metro_speech';
    else
        ttype = 'speech';
    end

    % Reset GUI buttons, info text, and state for assessment mode
    user_choice = '';
    if cfg.assess_syllable_rate && ishandle(hGui)
        set(btnAccept, 'Enable', 'off', 'Callback', @(~,~) set_choice('accept'));
        set(btnReject, 'Enable', 'on',  'Callback', @(~,~) set_choice('reject'));
        set(btnQuit,   'Enable', 'on',  'Callback', @(~,~) set_choice('quit'));

        % Display trial info: Trial Number, Stimulus, and Number of Syllables
        if ismember('n_syl', trials.Properties.VariableNames) && ~isnan(trials.n_syl(itrial))
            syl_str = num2str(trials.n_syl(itrial));
        else
            syl_str = num2str(sum(trials.stim{itrial} == '.'));
            if strcmp(syl_str, '0'), syl_str = 'N/A'; end
        end

        info_text = sprintf('Trial %d / %d   |   Syllables: %s\nStimulus: %s', ...
            itrial, cfg.ntrials, syl_str, trials.stim{itrial});
        set(txtInfo, 'String', info_text);
    end

    % ==================================================================
    % 1.  ITI — fixation cross
    % ==================================================================
    set(hText,'String','*','Color',[0.7 0.7 0.7],'FontSize',cfg.stim_font_size);
    set(hSquare,'FaceColor',[0.3 0.3 0.3]); drawnow;
    tFixOn    = T.now();
    flipState = ~flipState;
    log_event(eventFH,doDigOut,tFixOn,[],[],ttype,[],TRIG_FIX_CROSS,'Fixation_Cross_Onset',flipState);

    itiDur  = cfg.iti(1) + rand*(cfg.iti(2) - cfg.iti(1));
    tItiEnd = tFixOn + itiDur;
    while T.now() < tItiEnd - CHUNK_SIZE/cfg.aud_player_fs
        [~,esc] = KeyPoll();
        if esc && ~escaped
            escaped   = true;
            flipState = ~flipState;
            log_event(eventFH,doDigOut,T.now(),[],[],ttype,[],TRIG_ESC,'Key_Esc_Detected',flipState);
        end
        audWriter(zeros(CHUNK_SIZE, 1));
    end
    T.until(tItiEnd);

    if escaped, break; end

    % ==================================================================
    % 2a. Visual stimulus ON (Formatted with alternating syllable colors)
    % ==================================================================
    set(hSquare,'FaceColor',[0 0 0]);
    
    raw_stim_text = text_wrapped_all{trials.stim_idx(itrial)};
    
    if cfg.alternate_syl_colors_during_nonmetro || trials.metro_speech(itrial)
        formatted_stim = format_syllables_tex(raw_stim_text, cfg.text_colors);
    else
        formatted_stim = strrep(raw_stim_text, '.', '');
    end
    
    set(hText, 'Interpreter', 'tex', 'String', formatted_stim, ...
        'Color', cfg.text_color, 'FontSize', cfg.stim_font_size);
    drawnow;
    
    tVisOn    = T.now();
    flipState = ~flipState;
    log_event(eventFH,doDigOut,tVisOn,[],[],ttype,trials.stim{itrial},TRIG_VIS,'Visual_Onset',flipState);
    fprintf('\n[%d/%d]  metro=%d  |  %s\n', ...
        itrial, cfg.ntrials, trials.metro_speech(itrial), trials.stim{itrial});

    % ==================================================================
    % 2b. Metronome epoch
    % ==================================================================
    tMetroEpochEnd = tVisOn + cfg.metro_dur;

    if trials.metro_speech(itrial)
        tMetroStart = T.now();
        flipState   = ~flipState;
        log_event(eventFH,doDigOut,tMetroStart,cfg.tick_dur,[],ttype,[],TRIG_METRONOME,'Metronome_Onset',flipState);
        flipState   = ~flipState;
        log_event(eventFH,doDigOut,tMetroStart,cfg.tick_dur,[],ttype,[],TRIG_METRO_TICK,'Tick_1',flipState);

        pos            = 1;
        tick_logged    = false(n_ticks, 1);
        tick_logged(1) = true;
        tick_log_times = tMetroStart + tick_rel_times;

        while pos <= metro_total_samples
            chunk_end = min(pos + CHUNK_SIZE - 1, metro_total_samples);
            audWriter(metro_wave(pos:chunk_end));
            pos  = chunk_end + 1;
            tNow = T.now();

            for it = 2:n_ticks
                if ~tick_logged(it) && tNow >= tick_log_times(it)
                    flipState = ~flipState;
                    log_event(eventFH,doDigOut,tNow,cfg.tick_dur,[],ttype,[], ...
                        TRIG_METRO_TICK,sprintf('Tick_%d',it),flipState);
                    tick_logged(it) = true;
                end
            end

            [~,esc] = KeyPoll();
            if esc && ~escaped
                escaped   = true;
                flipState = ~flipState;
                log_event(eventFH,doDigOut,T.now(),[],[],ttype,[],TRIG_ESC,'Key_Esc_Detected',flipState);
            end
        end

        T.until(tMetroEpochEnd);
        flipState = ~flipState;
        log_event(eventFH,doDigOut,T.now(),0,[],ttype,[],TRIG_METRONOME,'Metronome_Offset',flipState);

    else
        while T.now() < tMetroEpochEnd - CHUNK_SIZE/cfg.aud_player_fs
            [~,esc] = KeyPoll();
            if esc && ~escaped
                escaped   = true;
                flipState = ~flipState;
                log_event(eventFH,doDigOut,T.now(),[],[],ttype,[],TRIG_ESC,'Key_Esc_Detected',flipState);
            end
            audWriter(zeros(CHUNK_SIZE, 1));
        end
        T.until(tMetroEpochEnd);
    end

    if escaped, break; end

    % ==================================================================
    % 3.  Jittered silent delay
    % ==================================================================
    tDelayEnd = T.now() + trials.go_latency(itrial);
    while T.now() < tDelayEnd - CHUNK_SIZE/cfg.aud_player_fs
        [~,esc] = KeyPoll();
        if esc && ~escaped
            escaped   = true;
            flipState = ~flipState;
            log_event(eventFH,doDigOut,T.now(),[],[],ttype,[],TRIG_ESC,'Key_Esc_Detected',flipState);
        end
        audWriter(zeros(CHUNK_SIZE, 1));
    end
    T.until(tDelayEnd);

    if escaped, break; end

    % ==================================================================
    % 4.  GO beep
    % ==================================================================
    if cfg.play_go_cue
        audWriter(go_beep_wave);
        tGoOn     = T.now();
        flipState = ~flipState;
        log_event(eventFH,doDigOut,tGoOn,cfg.go_beep_dur,[],ttype,[],TRIG_GO,'Go_Beep_Onset',flipState);
        tSpeechStart = tGoOn;
    else
        tSpeechStart = T.now();
    end

    % ==================================================================
    % 5.  Speech window (Extended window if assess_syllable_rate is true)
    % ==================================================================
    if cfg.assess_syllable_rate
        speechWinDur = cfg.speech_window_dur + min(cfg.iti);
    else
        speechWinDur = cfg.speech_window_dur;
    end
    
    tSpeechEnd = tSpeechStart + speechWinDur;
    recorded_audio_chunks = {};

    while T.now() < tSpeechEnd - CHUNK_SIZE/cfg.aud_player_fs
        if ~isempty(user_choice) && (strcmp(user_choice, 'reject') || strcmp(user_choice, 'quit'))
            break; % Proceed immediately if user clicks reject/quit during speech
        end

        [~,esc] = KeyPoll();
        if esc && ~escaped
            escaped   = true;
            flipState = ~flipState;
            log_event(eventFH,doDigOut,T.now(),[],[],ttype,[],TRIG_ESC,'Key_Esc_Detected',flipState);
            break;
        end

        audWriter(zeros(CHUNK_SIZE, 1));

        % Record microphone audio for assessment
        if cfg.assess_syllable_rate && ~isempty(micReader)
            inChunk = micReader();
            recorded_audio_chunks{end+1} = inChunk(:, 1); %#ok<AGROW>
        end
    end
    T.until(tSpeechEnd);

    % ==================================================================
    % 6.  Visual OFF
    % ==================================================================
    set(hText,'String','');
    set(hSquare,'FaceColor',[1 1 1]); drawnow;
    tVisOff   = T.now();
    flipState = ~flipState;
    log_event(eventFH,doDigOut,tVisOff,[],[],ttype,[],TRIG_VIS,'Visual_Off',flipState);

    if escaped, break; end

    % ==================================================================
    % 7.  Syllable Rate Assessment GUI & Interactive Parameters
    % ==================================================================
    if cfg.assess_syllable_rate && ishandle(hGui)
        if ~isempty(recorded_audio_chunks)
            speech_wave = cat(1, recorded_audio_chunks{:});
        else
            speech_wave = zeros(round(speechWinDur * cfg.aud_player_fs), 1);
        end

        fs = cfg.aud_player_fs;
        t_vec = (0:length(speech_wave)-1)' / fs;

        % Plot speech waveform
        cla(axGui);
        plot(axGui, t_vec, speech_wave, 'Color', [0.2 0.2 0.2]); hold(axGui, 'on');
        xlabel(axGui, 'Time (s)'); ylabel(axGui, 'Amplitude');
        grid(axGui, 'on');

        % Create line handles and text labels
        yl = ylim(axGui);
        hLineOn  = line(axGui, [0 0], yl, 'Color', 'r', 'LineWidth', 2);
        hLineOff = line(axGui, [speechWinDur speechWinDur], yl, 'Color', 'r', 'LineWidth', 2);
        
        hTextOn  = text(axGui, 0,            yl(2)*0.85, ' Onset',  'Color', 'r', 'FontWeight', 'bold');
        hTextOff = text(axGui, speechWinDur, yl(2)*0.85, ' Offset', 'Color', 'r', 'FontWeight', 'bold');
        hold(axGui, 'off');

        % Calculate initial RMS detection using current carried-over parameters
        update_rms_detection();

        % Enable click-and-drag line movement
        set(hLineOn,  'ButtonDownFcn', @(src, ~) startLineDrag(src, axGui));
        set(hLineOff, 'ButtonDownFcn', @(src, ~) startLineDrag(src, axGui));

        % Enable 'Accept trial' button now that trial ended
        set(btnAccept, 'Enable', 'on');

        % Pause and wait for user interaction (or Esc key)
        while isempty(user_choice) && ishandle(hGui)
            [~, esc] = KeyPoll();
            if esc
                user_choice = 'quit';
                escaped = true;
                flipState = ~flipState;
                log_event(eventFH,doDigOut,T.now(),[],[],ttype,[],TRIG_ESC,'Key_Esc_At_Assess_GUI',flipState);
                break;
            end
            drawnow;
            pause(0.05);
        end

        if strcmp(user_choice, 'quit')
            escaped = true;
            break;
        end

        % Extract final onset/offset coordinates from draggable lines
        if ishandle(hLineOn) && ishandle(hLineOff)
            final_onset  = hLineOn.XData(1);
            final_offset = hLineOff.XData(1);
        else
            final_onset  = 0;
            final_offset = speechWinDur;
        end

        % Record assessment results into trial table
        is_accepted = strcmp(user_choice, 'accept');
        trials.include_trial_for_assess(itrial) = is_accepted;
        trials.speech_on_for_assess(itrial)     = final_onset;
        trials.speech_off_for_assess(itrial)    = final_offset;
        trials.speech_dur_for_assess(itrial)    = final_offset - final_onset;
    end

    % ---- Save trial table up to current trial to TSV ----
    writetable(trials(1:itrial,:), cfg.TRIAL_FILENAME, ...
        'Delimiter','\t','FileType','text','WriteVariableNames',true);

    % ---- Exit cleanly if ESC was pressed during this trial ----
    if escaped
        fprintf('ESC detected — exiting after trial %d/%d.\n', itrial, cfg.ntrials);
        break;
    end

    % ==================================================================
    % Between-trial pauses (Skipped in assessment mode)
    % ==================================================================
    if ~cfg.assess_syllable_rate
        doPause = isfinite(cfg.pause_every_n_trials) && ...
                  mod(itrial, cfg.pause_every_n_trials) == 0 && ...
                  itrial < cfg.ntrials;

        if doPause
            flipState = ~flipState;
            log_event(eventFH,doDigOut,T.now(),[],[],'control',[],TRIG_BREAK, ...
                sprintf('Break_Start_After_Trial_%d',itrial),flipState);

            set(hText,'String',{'Rest break','','Press SPACE to continue.'}, ...
                'FontSize',40,'Color',cfg.text_color);
            set(hSquare,'FaceColor',[0 0 0]); drawnow;
            fprintf('=== Break after trial %d/%d — press SPACE to resume ===\n', itrial, cfg.ntrials);

            while true
                [space,esc] = KeyPoll();
                if esc
                    escaped   = true;
                    flipState = ~flipState;
                    log_event(eventFH,doDigOut,T.now(),[],[],'control',[],TRIG_ESC,'Key_Esc_At_Break',flipState);
                    break;
                end
                if space, break; end
                T.wait(0.01);
            end
            set(hText,'String',''); drawnow;

            flipState = ~flipState;
            log_event(eventFH,doDigOut,T.now(),[],[],'control',[],TRIG_BREAK, ...
                sprintf('Break_End_After_Trial_%d',itrial),flipState);

            if escaped, break; end

        elseif cfg.STOP_BETWEEN_TRIALS && itrial < cfg.ntrials
            fprintf('Trial %d/%d complete. Press SPACE for next trial...\n', itrial, cfg.ntrials);
            while true
                [space,esc] = KeyPoll();
                if esc
                    escaped   = true;
                    flipState = ~flipState;
                    log_event(eventFH,doDigOut,T.now(),[],[],'control',[],TRIG_ESC,'Key_Esc_Between_Trials',flipState);
                    break;
                end
                if space, break; end
                T.wait(0.01);
            end
            if escaped, break; end
        end
    end

end   % for itrial

%% ---- Post-Assessment Display & Summary ------------------------------
if cfg.assess_syllable_rate
    acc_idx = trials.include_trial_for_assess;
    acc_trials = trials(acc_idx, :);

    if ~isempty(acc_trials)
        % Scatter plot of trial number vs speech duration
        figure('Name', 'Assessment Results', 'NumberTitle', 'off');
        scatter(acc_trials.trialnum, acc_trials.speech_dur_for_assess, 80, 'b', 'filled');
        xlabel('Trial Number');
        ylabel('Speech Duration (s)');
        title('Trial Number vs. Speech Duration (Accepted Trials)');
        grid on;

        mean_speech_dur = mean(acc_trials.speech_dur_for_assess);

        if ismember('n_syl', acc_trials.Properties.VariableNames) && ~any(isnan(acc_trials.n_syl))
            mean_syl_per_trial = mean(acc_trials.n_syl);
            syl_rate_hz        = acc_trials.n_syl ./ acc_trials.speech_dur_for_assess;
            sec_per_syl         = acc_trials.speech_dur_for_assess ./ acc_trials.n_syl;

            mean_syl_rate      = mean(syl_rate_hz);
            mean_sec_syl        = mean(sec_per_syl);

            % Intraop speed ratio adjustment
            adj_ratio          = cfg.intraop_to_preop_to_speed_ratio;
            adj_syl_rate       = mean_syl_rate * adj_ratio;

            % Copy adjusted speech rate (rounded to 3rd decimal place) to clipboard
            clipboard('copy', sprintf('%.3f', adj_syl_rate));

            fprintf('\n================ ASSESSMENT SUMMARY ================\n');
            fprintf('Total trials assessed     : %d\n', height(trials));
            fprintf('Accepted trials           : %d\n', sum(acc_idx));
            fprintf('Mean speech duration      : %.3f s\n', mean_speech_dur);
            fprintf('Mean syllables per trial  : %.2f\n', mean_syl_per_trial);
            fprintf('Mean time per syllable    : %.3f s/syllable\n', mean_sec_syl);
            fprintf('Mean speech rate          : %.3f Hz (syllables/sec)\n', mean_syl_rate);
            fprintf('Adjusted speech rate      : %.3f Hz (ratio = %.2f, copied to clipboard)\n', ...
                adj_syl_rate, adj_ratio);
            fprintf('====================================================\n\n');
        else
            fprintf('\n================ ASSESSMENT SUMMARY ================\n');
            fprintf('Total trials assessed     : %d\n', height(trials));
            fprintf('Accepted trials           : %d\n', sum(acc_idx));
            fprintf('Mean speech duration      : %.3f s\n', mean_speech_dur);
            fprintf('====================================================\n\n');
        end
    else
        fprintf('\nNo trials accepted during assessment.\n');
    end
end

%% ---- Cleanup --------------------------------------------------------
fprintf('Task complete.\n');
fclose(eventFH);
if ishandle(hfig), close(hfig); end
if ishandle(hGui), close(hGui); end


%% =================== Nested & Local functions ========================

    function adjust_amp(delta)
        cfg.speech_rms_thresh_amp = max(0.001, cfg.speech_rms_thresh_amp + delta);
        update_rms_detection();
    end

    function adjust_dur(delta)
        cfg.speech_rms_thresh_dur = max(0.001, cfg.speech_rms_thresh_dur + delta);
        update_rms_detection();
    end

    function update_rms_detection()
        if isempty(speech_wave)
            return;
        end
        fs = cfg.aud_player_fs;
        t_vec = (0:length(speech_wave)-1)' / fs;

        % RMS Moving Window calculation
        N_win = max(1, round(cfg.speech_rms_thresh_dur * fs));
        rms_sig = sqrt(movmean(speech_wave.^2, [0, N_win-1]));

        above_thresh_idx = find(rms_sig >= cfg.speech_rms_thresh_amp);

        if ~isempty(above_thresh_idx)
            onset_idx  = above_thresh_idx(1);
            offset_idx = min(above_thresh_idx(end) + N_win - 1, length(speech_wave));
            t_onset    = t_vec(onset_idx);
            t_offset   = t_vec(offset_idx);
        else
            t_onset  = 0;
            t_offset = speechWinDur;
        end

        % Update vertical line markers
        if ishandle(hLineOn) && ishandle(hLineOff)
            set(hLineOn,  'XData', [t_onset t_onset]);
            set(hLineOff, 'XData', [t_offset t_offset]);
        end

        % Update text annotations on plot
        if ishandle(hTextOn) && ishandle(hTextOff)
            yl = ylim(axGui);
            set(hTextOn,  'Position', [t_onset,  yl(2)*0.85, 0]);
            set(hTextOff, 'Position', [t_offset, yl(2)*0.85, 0]);
        end

        % Update threshold display labels
        if ishandle(txtAmp)
            set(txtAmp, 'String', sprintf('RMS Amp: %.3f', cfg.speech_rms_thresh_amp));
        end
        if ishandle(txtDur)
            set(txtDur, 'String', sprintf('RMS Dur: %.3f s', cfg.speech_rms_thresh_dur));
        end
        drawnow;
    end

    function set_choice(choice_str)
        user_choice = choice_str;
    end

    function [space, esc] = KeyPoll()
        space = System.Windows.Input.Keyboard.IsKeyDown(System.Windows.Input.Key.Space);
        esc   = System.Windows.Input.Keyboard.IsKeyDown(System.Windows.Input.Key.Escape);
    end

end   % task_metro


%% ================= Outer Helper Functions ============================

function formatted = format_syllables_tex(str_text, colors)
% Format strings with periods (.) before syllables into TeX colored text
    if ~contains(str_text, '.')
        formatted = str_text;
        return;
    end
    parts = strsplit(str_text, '.');
    formatted_parts = {};
    syl_count = 0;
    for ip = 1:numel(parts)
        part = parts{ip};
        if ip == 1 && isempty(part)
            continue;
        end
        if isempty(part)
            continue;
        end
        syl_count = syl_count + 1;
        if mod(syl_count, 2) == 1
            col = colors{1};
        else
            col = colors{2};
        end
        col_str = sprintf('\\color[rgb]{%.3f,%.3f,%.3f}', col(1), col(2), col(3));
        formatted_parts{end+1} = [col_str, part]; %#ok<AGROW>
    end
    formatted = strjoin(formatted_parts, '');
end

function startLineDrag(hLine, ax)
% Click and drag helper for interactive vertical lines on GUI figure
    fig = ancestor(ax, 'figure');
    set(fig, 'WindowButtonMotionFcn', @(~,~) dragLine(hLine, ax));
    set(fig, 'WindowButtonUpFcn',     @(~,~) stopLineDrag(fig));
end

function dragLine(hLine, ax)
    cp = get(ax, 'CurrentPoint');
    newX = cp(1, 1);
    xl = xlim(ax);
    newX = max(xl(1), min(xl(2), newX));
    set(hLine, 'XData', [newX, newX]);
end

function stopLineDrag(fig)
    set(fig, 'WindowButtonMotionFcn', '');
    set(fig, 'WindowButtonUpFcn', '');
end