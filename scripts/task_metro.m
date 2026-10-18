function task_metro(cfg)
% task_metro  Run the metronomic-speech task (non-PsychToolbox).

%% ---- Default optional fields ----------------------------------------
if ~isfield(cfg,'play_go_cue'),                    cfg.play_go_cue                    = true;  end
if ~isfield(cfg,'STOP_BETWEEN_TRIALS'),            cfg.STOP_BETWEEN_TRIALS            = false; end
if ~isfield(cfg,'pause_every_n_trials'),           cfg.pause_every_n_trials           = inf;   end
if ~isfield(cfg,'speech_window_dur'),              cfg.speech_window_dur              = 5;     end

% Syllable rate assessment & display options
if ~isfield(cfg,'assess_syllable_rate'),           cfg.assess_syllable_rate           = false; end
if ~isfield(cfg,'speech_rms_thresh_amp'),          cfg.speech_rms_thresh_amp          = 0.005; end
if ~isfield(cfg,'speech_rms_thresh_dur'),          cfg.speech_rms_thresh_dur          = 0.01;  end
if ~isfield(cfg,'assess_wait_after_go'),           cfg.assess_wait_after_go           = 0.25;  end
if ~isfield(cfg,'intraop_to_preop_to_speed_ratio'),cfg.intraop_to_preop_to_speed_ratio = 0.9;   end
if ~isfield(cfg,'alternate_syl_colors_during_nonmetro')
    cfg.alternate_syl_colors_during_nonmetro = true;
end
if ~isfield(cfg,'text_colors') || isempty(cfg.text_colors)
    cfg.text_colors = {[1 1 1], [0.7 0.7 0.7]};
end

% Overrides for Assess mode
if cfg.assess_syllable_rate
    cfg.randomize_order = false; % Never randomize stimulus order in assess mode
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
speech_wave          = [];
speechWinDur         = cfg.speech_window_dur;
hLineOn              = [];
hLineOff             = [];
hTextOn              = [];
hTextOff             = [];
user_choice          = '';

btnAccept            = [];
btnReject            = [];
btnQuit              = [];
txtAmp               = [];
txtDur               = [];
txtGlobalAmp         = [];
txtGlobalDur         = [];
axGui                = [];
txtInfo              = [];
hGui                 = [];
hFinalGui            = [];

recorded_audio_all   = {};
is_manually_adjusted = [];

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

% In assessment mode: strictly force non-metronomic trials only
if cfg.assess_syllable_rate
    if iscell(trials.metro_speech) || ischar(trials.metro_speech) || isstring(trials.metro_speech)
        trials.metro_speech = false(height(trials), 1);
    else
        trials.metro_speech(:) = false;
    end
    
    trials.trialnum = (1:height(trials))';
    
    % Add assessment tracking columns
    trials.include_trial_for_assess = false(height(trials), 1);
    trials.speech_on_for_assess     = nan(height(trials), 1);
    trials.speech_off_for_assess    = nan(height(trials), 1);
    trials.speech_dur_for_assess    = nan(height(trials), 1);
    
    recorded_audio_all   = cell(height(trials), 1);
    is_manually_adjusted = false(height(trials), 1);
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
    'Position',[0 0 ss(3) ss(4)], 'KeyPressFcn', @keyPressCallback);

% Ensure the main stimulus window pops up on top and receives focus
figure(hfig);
drawnow;

ax    = axes('Parent',hfig,'Position',[0 0 1 1],'Visible','off');
hText = text(0.5,0.5,'','Parent',ax,'Color',cfg.text_color, ...
    'FontSize',cfg.stim_font_size,'FontWeight','bold', ...
    'HorizontalAlignment','center','VerticalAlignment','middle', ...
    'Units','normalized','Interpreter','tex');
pdLen   = 0.05;
hSquare = annotation('rectangle','FaceColor',[1 1 1],'EdgeColor','none', ...
    'Position',[0, 1-pdLen, pdLen, pdLen]);

% Top-Right feedback square for Assess Mode (Green = Accept, Red = Reject)
hAssessStatusSquare = annotation('rectangle', 'FaceColor', [0 0 0], 'EdgeColor', 'none', ...
    'Position', [0.93, 1-pdLen, pdLen, pdLen], 'Visible', 'off');

%% ---- Assessment GUI Setup -------------------------------------------
if cfg.assess_syllable_rate
    hGui = figure('Name', 'Speech Rate Assessment GUI', 'NumberTitle', 'off', ...
        'WindowStyle', 'docked', 'KeyPressFcn', @keyPressCallback);
    
    txtInfo = uicontrol('Parent', hGui, 'Style', 'text', 'Units', 'normalized', ...
        'Position', [0.05, 0.88, 0.90, 0.10], 'FontSize', 12, 'FontWeight', 'bold', ...
        'HorizontalAlignment', 'center', 'BackgroundColor', get(hGui, 'Color'));

    axGui = axes('Parent', hGui, 'Position', [0.08, 0.28, 0.88, 0.58]);
    xlabel(axGui, 'Time (s)');
    ylabel(axGui, 'Amplitude');
    title(axGui, 'Trial Speech Waveform');
    grid(axGui, 'on');

    txtAmp = uicontrol('Parent', hGui, 'Style', 'text', 'Units', 'normalized', ...
        'Position', [0.02, 0.18, 0.18, 0.05], 'FontSize', 11, ...
        'HorizontalAlignment', 'right', 'BackgroundColor', get(hGui, 'Color'), ...
        'String', sprintf('RMS Amp: %.3f', cfg.speech_rms_thresh_amp));
    btnAmpDown = uicontrol('Parent', hGui, 'Style', 'pushbutton', 'String', '▼', ...
        'Units', 'normalized', 'Position', [0.21, 0.18, 0.04, 0.05], 'FontSize', 11, ...
        'Callback', @(~,~) adjust_amp(-0.005));
    btnAmpUp   = uicontrol('Parent', hGui, 'Style', 'pushbutton', 'String', '▲', ...
        'Units', 'normalized', 'Position', [0.26, 0.18, 0.04, 0.05], 'FontSize', 11, ...
        'Callback', @(~,~) adjust_amp(+0.005));

    txtDur = uicontrol('Parent', hGui, 'Style', 'text', 'Units', 'normalized', ...
        'Position', [0.38, 0.18, 0.18, 0.05], 'FontSize', 11, ...
        'HorizontalAlignment', 'right', 'BackgroundColor', get(hGui, 'Color'), ...
        'String', sprintf('RMS Dur: %.3f s', cfg.speech_rms_thresh_dur));
    btnDurDown = uicontrol('Parent', hGui, 'Style', 'pushbutton', 'String', '▼', ...
        'Units', 'normalized', 'Position', [0.57, 0.18, 0.04, 0.05], 'FontSize', 11, ...
        'Callback', @(~,~) adjust_dur(-0.002));
    btnDurUp   = uicontrol('Parent', hGui, 'Style', 'pushbutton', 'String', '▲', ...
        'Units', 'normalized', 'Position', [0.62, 0.18, 0.04, 0.05], 'FontSize', 11, ...
        'Callback', @(~,~) adjust_dur(+0.002));

    btnPlayCurrent = uicontrol('Parent', hGui, 'Style', 'pushbutton', 'String', '▶ Play audio', ...
        'Units', 'normalized', 'Position', [0.75, 0.18, 0.18, 0.05], 'FontSize', 11, ...
        'Callback', @(~,~) play_current_trial_audio());

    btnAccept = uicontrol('Parent', hGui, 'Style', 'pushbutton', 'String', 'Accept trial (Space)', ...
        'Units', 'normalized', 'Position', [0.05, 0.03, 0.28, 0.10], ...
        'FontSize', 12, 'FontWeight', 'bold', 'Enable', 'off');
    btnReject = uicontrol('Parent', hGui, 'Style', 'pushbutton', 'String', 'Reject trial (Backspace)', ...
        'Units', 'normalized', 'Position', [0.36, 0.03, 0.28, 0.10], ...
        'FontSize', 12, 'FontWeight', 'bold', 'Enable', 'on');
    btnQuit   = uicontrol('Parent', hGui, 'Style', 'pushbutton', 'String', 'Quit task (Esc)', ...
        'Units', 'normalized', 'Position', [0.67, 0.03, 0.28, 0.10], ...
        'FontSize', 12, 'FontWeight', 'bold', 'Enable', 'on');
        
    figure(hfig);
end

%% ---- Trigger codes --------------------------------------------------
TRIG_VIS_INSTRUCTIONS = 1;
TRIG_FIX_CROSS        = 2;
TRIG_VIS_STIM         = 4;
TRIG_METRO_TICK       = 8;
TRIG_GO               = 16;
TRIG_KEY              = 32;
TRIG_ESC              = 64;
TRIG_BREAK            = 128;

doDigOut  = isfield(cfg,'DIGOUT') && logical(cfg.DIGOUT);
flipState = 0;

%% ---- Audio setup ----------------------------------------------------
cfg = setup_audio_devices(cfg);

audWriter        = audioDeviceWriter('SampleRate', cfg.aud_player_fs, 'BufferSize', 512);
aud_dev_list     = getAudioDevices(audWriter);
idx              = find(contains(aud_dev_list, cfg.aud_dev_out), 1);
audWriter.Device = aud_dev_list{idx};
audWriter.SupportVariableSizeInput = true;

CHUNK_SIZE = 512;
zero_chunk = zeros(CHUNK_SIZE, 1);

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
figure(hfig);
drawnow;

tInstOn   = T.now();
flipState = ~flipState;
log_event(eventFH, doDigOut, tInstOn, [], [], 'control', [], TRIG_VIS_INSTRUCTIONS, 'Instructions_Onset', flipState);

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
    audWriter(zero_chunk); % keep device warm
end
set(hText,'String',''); drawnow;

t_task_start = T.now();
flipState    = ~flipState;
log_event(eventFH,doDigOut,t_task_start,[],[],'control',[],0,'Task_Start',flipState);

%% =====================================================================
%%  Main trial loop
%% =====================================================================
escaped = false;

for itrial = 1:cfg.ntrials

    m_val = trials.metro_speech(itrial);
    if iscell(m_val), m_val = m_val{1}; end
    if ischar(m_val) || isstring(m_val)
        is_metro_trial = ~cfg.assess_syllable_rate && strcmpi(string(m_val), "true");
    else
        is_metro_trial = ~cfg.assess_syllable_rate && logical(m_val);
    end

    if is_metro_trial
        ttype = 'metro_speech';
    else
        ttype = 'speech';
    end

    user_choice = '';
    if cfg.assess_syllable_rate
        if ishandle(hAssessStatusSquare)
            set(hAssessStatusSquare, 'Visible', 'off');
        end
        if ishandle(hGui)
            set(btnAccept, 'Enable', 'off', 'Callback', @(~,~) set_choice('accept'));
            set(btnReject, 'Enable', 'on',  'Callback', @(~,~) set_choice('reject'));
            set(btnQuit,   'Enable', 'on',  'Callback', @(~,~) set_choice('quit'));

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
    end

    if ishandle(hfig), figure(hfig); end

    % ==================================================================
    % 1.  ITI -- fixation cross
    % ==================================================================
    set(hText,'String','*','Color',[0.7 0.7 0.7],'FontSize',cfg.stim_font_size);
    set(hSquare,'FaceColor',[0.3 0.3 0.3]); drawnow;
    tFixOn    = T.now();
    flipState = ~flipState;
    log_event(eventFH,doDigOut,tFixOn,[],[],ttype,[],TRIG_FIX_CROSS,'Fixation_Cross_Onset',flipState);

    itiDur  = cfg.iti(1) + rand*(cfg.iti(2) - cfg.iti(1));
    tItiEnd = tFixOn + itiDur;
    while T.now() < tItiEnd - (CHUNK_SIZE/cfg.aud_player_fs)
        [~,esc, backspace] = KeyPoll();
        if (esc || backspace) && cfg.assess_syllable_rate
            if esc, user_choice = 'quit'; escaped = true; end
            if backspace, user_choice = 'reject'; end
        end
        if esc && ~escaped
            escaped   = true;
            flipState = ~flipState;
            log_event(eventFH,doDigOut,T.now(),[],[],ttype,[],TRIG_ESC,'Key_Esc_Detected',flipState);
        end
        audWriter(zero_chunk); % Keep audio device warm to prevent double-hits/clicks
    end
    T.until(tItiEnd);

    if escaped, break; end

    % ==================================================================
    % 2a. Visual stimulus ON
    % ==================================================================
    set(hSquare,'FaceColor',[0 0 0]);
    
    raw_stim_text = text_wrapped_all{trials.stim_idx(itrial)};
    
    if cfg.alternate_syl_colors_during_nonmetro || is_metro_trial
        formatted_stim = format_syllables_tex(raw_stim_text, cfg.text_colors);
    else
        formatted_stim = strrep(raw_stim_text, '.', '');
    end
    
    set(hText, 'Interpreter', 'tex', 'String', formatted_stim, ...
        'Color', cfg.text_color, 'FontSize', cfg.stim_font_size);
    drawnow;
    
    tVisOn    = T.now();
    flipState = ~flipState;
    log_event(eventFH,doDigOut,tVisOn,[],[],ttype,trials.stim{itrial},TRIG_VIS_STIM,'Visual_Onset',flipState);
    fprintf('\n[%d/%d]  metro=%d  |  %s\n', ...
        itrial, cfg.ntrials, is_metro_trial, trials.stim{itrial});

    % ==================================================================
    % 2b. Metronome epoch
    % ==================================================================
    tMetroEpochEnd = tVisOn + cfg.metro_dur;

    if is_metro_trial && cfg.metro_dur > 0
        tMetroStart = T.now();

        pos            = 1;
        tick_logged    = false(n_ticks, 1);
        tick_log_times = tMetroStart + tick_rel_times;

        while pos <= metro_total_samples
            chunk_end = min(pos + CHUNK_SIZE - 1, metro_total_samples);
            % Push audio chunk FIRST
            audWriter(metro_wave(pos:chunk_end));
            pos  = chunk_end + 1;
            tNow = T.now();

            % Send trigger IMMEDIATELY AFTER audio chunk is pushed
            for it = 1:n_ticks
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
    elseif cfg.metro_dur > 0
        % Non-metro trials: wait out the metro_dur interval playing purely zeros (no clicks)
        while T.now() < tMetroEpochEnd - (CHUNK_SIZE/cfg.aud_player_fs)
            [~,esc] = KeyPoll();
            if esc && ~escaped
                escaped   = true;
                flipState = ~flipState;
                log_event(eventFH,doDigOut,T.now(),[],[],ttype,[],TRIG_ESC,'Key_Esc_Detected',flipState);
            end
            audWriter(zero_chunk); % Keep audio device warm strictly with zeros
        end
        T.until(tMetroEpochEnd);
    end

    if escaped, break; end

    % ==================================================================
    % 3.  Jittered silent delay
    % ==================================================================
    tDelayEnd = T.now() + trials.go_latency(itrial);
    while T.now() < tDelayEnd - (CHUNK_SIZE/cfg.aud_player_fs)
        [~,esc] = KeyPoll();
        if esc && ~escaped
            escaped   = true;
            flipState = ~flipState;
            log_event(eventFH,doDigOut,T.now(),[],[],ttype,[],TRIG_ESC,'Key_Esc_Detected',flipState);
        end
        audWriter(zero_chunk); % Keep audio device warm
    end
    T.until(tDelayEnd);
    
    if escaped, break; end

    % ==================================================================
    % 4.  GO beep
    % ==================================================================
    if cfg.play_go_cue
        % Push audio waveform to device FIRST so hardware buffering/DAC output begins
        audWriter(go_beep_wave);
        
        tGoOn     = T.now();
        flipState = ~flipState;
        log_event(eventFH,doDigOut,tGoOn,cfg.go_beep_dur,[],ttype,[],TRIG_GO,'Go_Beep_Onset',flipState);
        
        % Stream audio output while actively draining micReader during and after the beep
        % to discard speaker sound feedback and driver buffer overhang completely
        tGoFinish = tGoOn + cfg.go_beep_dur + cfg.assess_wait_after_go;
        while T.now() < tGoFinish
            audWriter(zero_chunk);
            if cfg.assess_syllable_rate && ~isempty(micReader)
                try micReader(); catch; end % Discard beep sound chunks
            end
        end
    end

    % Thoroughly flush mic System object after draining hardware buffer
    if cfg.assess_syllable_rate && ~isempty(micReader)
        for iFlush = 1:10
            try micReader(); catch; end
            pause(0.005);
        end
        reset(micReader);
    end

    tSpeechStart = T.now();

    % ==================================================================
    % 5.  Speech window
    % ==================================================================
    if cfg.assess_syllable_rate
        speechWinDur = cfg.speech_window_dur + min(cfg.iti);
    else
        speechWinDur = cfg.speech_window_dur;
    end
    
    tSpeechEnd = tSpeechStart + speechWinDur;
    recorded_audio_chunks = {};

    while T.now() < tSpeechEnd
        if ~isempty(user_choice) && (strcmp(user_choice, 'reject') || strcmp(user_choice, 'quit'))
            break;
        end

        [~, esc, backspace] = KeyPoll();
        if backspace && cfg.assess_syllable_rate
            user_choice = 'reject';
            if ishandle(hAssessStatusSquare)
                set(hAssessStatusSquare, 'FaceColor', [0.9 0.1 0.1], 'Visible', 'on');
                drawnow;
                pause(0.3);
                set(hAssessStatusSquare, 'Visible', 'off'); drawnow;
            end
            break;
        end
        if esc && ~escaped
            escaped   = true;
            flipState = ~flipState;
            log_event(eventFH,doDigOut,T.now(),[],[],ttype,[],TRIG_ESC,'Key_Esc_Detected',flipState);
            break;
        end

        if cfg.assess_syllable_rate && ~isempty(micReader)
            inChunk = micReader();
            recorded_audio_chunks{end+1} = inChunk(:, 1); %#ok<AGROW>
        end
        
        % We don't stream zeros here in assess mode to prevent interfering with mic loop timing
        if ~cfg.assess_syllable_rate
            audWriter(zero_chunk); 
        else
            T.wait(0.002);
        end
    end

    % ==================================================================
    % 6.  Visual OFF
    % ==================================================================
    set(hText,'String','');
    set(hSquare,'FaceColor',[1 1 1]); drawnow;
    tVisOff   = T.now();
    flipState = ~flipState;
    log_event(eventFH,doDigOut,tVisOff,[],[],ttype,[],TRIG_VIS_STIM,'Visual_Off',flipState);

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
        recorded_audio_all{itrial} = speech_wave;

        fs = cfg.aud_player_fs;
        t_vec = (0:length(speech_wave)-1)' / fs;

        cla(axGui);
        plot(axGui, t_vec, speech_wave, 'Color', [0.2 0.2 0.2]); hold(axGui, 'on');
        xlabel(axGui, 'Time (s)'); ylabel(axGui, 'Amplitude');
        grid(axGui, 'on');

        yl = ylim(axGui);
        hLineOn  = line(axGui, [0 0], yl, 'Color', 'r', 'LineWidth', 2);
        hLineOff = line(axGui, [speechWinDur speechWinDur], yl, 'Color', 'r', 'LineWidth', 2);
        
        hTextOn  = text(axGui, 0,            yl(2)*0.85, ' Onset',  'Color', 'r', 'FontWeight', 'bold');
        hTextOff = text(axGui, speechWinDur, yl(2)*0.85, ' Offset', 'Color', 'r', 'FontWeight', 'bold');
        hold(axGui, 'off');

        update_rms_detection(itrial);

        set(hLineOn,  'ButtonDownFcn', @(src, ~) startLineDrag(src, axGui, itrial));
        set(hLineOff, 'ButtonDownFcn', @(src, ~) startLineDrag(src, axGui, itrial));

        set(btnAccept, 'Enable', 'on');

        while isempty(user_choice) && ishandle(hGui)
            [space, esc, backspace] = KeyPoll();
            if space && strcmp(get(btnAccept, 'Enable'), 'on')
                user_choice = 'accept';
                if ishandle(hAssessStatusSquare)
                    set(hAssessStatusSquare, 'FaceColor', [0 0.8 0.2], 'Visible', 'on');
                    drawnow; pause(0.3);
                    set(hAssessStatusSquare, 'Visible', 'off'); drawnow;
                end
                break;
            elseif backspace
                user_choice = 'reject';
                if ishandle(hAssessStatusSquare)
                    set(hAssessStatusSquare, 'FaceColor', [0.9 0.1 0.1], 'Visible', 'on');
                    drawnow; pause(0.3);
                    set(hAssessStatusSquare, 'Visible', 'off'); drawnow;
                end
                break;
            elseif esc
                user_choice = 'quit';
                escaped = true;
                flipState = ~flipState;
                log_event(eventFH,doDigOut,T.now(),[],[],ttype,[],TRIG_ESC,'Key_Esc_At_Assess_GUI',flipState);
                break;
            end
            audWriter(zero_chunk); % keep device warm while waiting for GUI
        end

        if ishandle(hAssessStatusSquare) && ~isempty(user_choice)
            if strcmp(user_choice, 'accept')
                set(hAssessStatusSquare, 'FaceColor', [0 0.8 0.2], 'Visible', 'on');
                drawnow; pause(0.3); set(hAssessStatusSquare, 'Visible', 'off'); drawnow;
            elseif strcmp(user_choice, 'reject')
                set(hAssessStatusSquare, 'FaceColor', [0.9 0.1 0.1], 'Visible', 'on');
                drawnow; pause(0.3); set(hAssessStatusSquare, 'Visible', 'off'); drawnow;
            end
        end

        if strcmp(user_choice, 'quit'), escaped = true; break; end

        if ishandle(hLineOn) && ishandle(hLineOff)
            final_onset  = hLineOn.XData(1);
            final_offset = hLineOff.XData(1);
        else
            final_onset  = 0;
            final_offset = speechWinDur;
        end

        is_accepted = strcmp(user_choice, 'accept');
        trials.include_trial_for_assess(itrial) = is_accepted;
        trials.speech_on_for_assess(itrial)     = final_onset;
        trials.speech_off_for_assess(itrial)    = final_offset;
        trials.speech_dur_for_assess(itrial)    = final_offset - final_onset;
    end

    writetable(trials(1:itrial,:), cfg.TRIAL_FILENAME, ...
        'Delimiter','\t','FileType','text','WriteVariableNames',true);

    if escaped
        fprintf('ESC detected -- exiting after trial %d/%d.\n', itrial, cfg.ntrials);
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
            fprintf('=== Break after trial %d/%d -- press SPACE to resume ===\n', itrial, cfg.ntrials);

            while true
                [space,esc] = KeyPoll();
                if esc
                    escaped   = true;
                    flipState = ~flipState;
                    log_event(eventFH,doDigOut,T.now(),[],[],'control',[],TRIG_ESC,'Key_Esc_At_Break',flipState);
                    break;
                end
                if space, break; end
                audWriter(zero_chunk);
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
                audWriter(zero_chunk);
            end
            if escaped, break; end
        end
    end
end   % for itrial

%% =====================================================================
%%  Final Tiled Review GUI (Multi-trial assessment review)
%% =====================================================================
if cfg.assess_syllable_rate
    if ishandle(hGui), close(hGui); end
    
    if ~escaped && height(trials) > 0
        hFinalGui = figure('Name', 'Final Speech Assessment Review', 'NumberTitle', 'off', ...
            'Units', 'normalized', 'Position', [0.02, 0.05, 0.96, 0.88]);

        pnlHeader = uipanel('Parent', hFinalGui, 'Units', 'normalized', ...
            'Position', [0.01, 0.91, 0.98, 0.08], 'BorderType', 'none');

        finalized_clicked = false;
        uicontrol('Parent', pnlHeader, 'Style', 'pushbutton', 'String', 'Finalize trials', ...
            'Units', 'normalized', 'Position', [0.01, 0.15, 0.18, 0.70], ...
            'FontSize', 12, 'FontWeight', 'bold', 'BackgroundColor', [0.2 0.7 0.3], ...
            'ForegroundColor', [1 1 1], 'Callback', @(~,~) finalize_review());

        uicontrol('Parent', pnlHeader, 'Style', 'text', 'String', 'All Trials Review', ...
            'Units', 'normalized', 'Position', [0.22, 0.20, 0.25, 0.60], ...
            'FontSize', 14, 'FontWeight', 'bold', 'HorizontalAlignment', 'left');

        txtGlobalAmp = uicontrol('Parent', pnlHeader, 'Style', 'text', 'Units', 'normalized', ...
            'Position', [0.50, 0.20, 0.14, 0.60], 'FontSize', 10, ...
            'HorizontalAlignment', 'right', 'String', sprintf('RMS Amp: %.3f', cfg.speech_rms_thresh_amp));
        uicontrol('Parent', pnlHeader, 'Style', 'pushbutton', 'String', '▼', ...
            'Units', 'normalized', 'Position', [0.65, 0.20, 0.03, 0.60], 'FontSize', 11, ...
            'Callback', @(~,~) adjust_global_amp(-0.005));
        uicontrol('Parent', pnlHeader, 'Style', 'pushbutton', 'String', '▲', ...
            'Units', 'normalized', 'Position', [0.68, 0.20, 0.03, 0.60], 'FontSize', 11, ...
            'Callback', @(~,~) adjust_global_amp(+0.005));

        txtGlobalDur = uicontrol('Parent', pnlHeader, 'Style', 'text', 'Units', 'normalized', ...
            'Position', [0.73, 0.20, 0.14, 0.60], 'FontSize', 10, ...
            'HorizontalAlignment', 'right', 'String', sprintf('RMS Dur: %.3f s', cfg.speech_rms_thresh_dur));
        uicontrol('Parent', pnlHeader, 'Style', 'pushbutton', 'String', '▼', ...
            'Units', 'normalized', 'Position', [0.88, 0.20, 0.03, 0.60], 'FontSize', 11, ...
            'Callback', @(~,~) adjust_global_dur(-0.002));
        uicontrol('Parent', pnlHeader, 'Style', 'pushbutton', 'String', '▲', ...
            'Units', 'normalized', 'Position', [0.91, 0.20, 0.03, 0.60], 'FontSize', 11, ...
            'Callback', @(~,~) adjust_global_dur(+0.002));

        nTrialsAll = height(trials);
        nCols      = min(3, nTrialsAll);
        nRows      = ceil(nTrialsAll / nCols);

        tileAxes      = cell(nTrialsAll, 1);
        tileLinesOn   = cell(nTrialsAll, 1);
        tileLinesOff  = cell(nTrialsAll, 1);
        tileTextsOn   = cell(nTrialsAll, 1);
        tileTextsOff  = cell(nTrialsAll, 1);
        tileRadioGrp  = cell(nTrialsAll, 1);

        top_margin = 0.10;
        bottom_margin = 0.02;
        left_margin = 0.01;
        right_margin = 0.01;

        avail_w = 1.0 - left_margin - right_margin;
        avail_h = 1.0 - top_margin - bottom_margin;
        tile_w  = avail_w / nCols;
        tile_h  = avail_h / nRows;

        for idxTr = 1:nTrialsAll
            row = floor((idxTr-1) / nCols);
            col = mod(idxTr-1, nCols);

            x_pos = left_margin + col * tile_w;
            y_pos = 1.0 - top_margin - (row + 1) * tile_h;

            hPanel = uipanel('Parent', hFinalGui, 'Units', 'normalized', ...
                'Position', [x_pos+0.005, y_pos+0.005, tile_w-0.01, tile_h-0.01]);

            if ismember('n_syl', trials.Properties.VariableNames) && ~isnan(trials.n_syl(idxTr))
                syl_str_t = num2str(trials.n_syl(idxTr));
            else
                syl_str_t = num2str(sum(trials.stim{idxTr} == '.'));
            end

            title_str = sprintf('Tr %d | Syl: %s | %s', idxTr, syl_str_t, trials.stim{idxTr});
            uicontrol('Parent', hPanel, 'Style', 'text', 'String', title_str, ...
                'Units', 'normalized', 'Position', [0.02, 0.85, 0.96, 0.14], ...
                'FontSize', 9, 'FontWeight', 'bold', 'HorizontalAlignment', 'left');

            axTile = axes('Parent', hPanel, 'Position', [0.10, 0.32, 0.86, 0.52]);
            tileAxes{idxTr} = axTile;

            sigTr = recorded_audio_all{idxTr};
            if isempty(sigTr)
                sigTr = zeros(round(speechWinDur * cfg.aud_player_fs), 1);
            end
            fs_aud = cfg.aud_player_fs;
            t_vec_tr = (0:length(sigTr)-1)' / fs_aud;

            plot(axTile, t_vec_tr, sigTr, 'Color', [0.3 0.3 0.3]); hold(axTile, 'on');
            grid(axTile, 'on'); set(axTile, 'FontSize', 8);

            on_val  = trials.speech_on_for_assess(idxTr);
            off_val = trials.speech_off_for_assess(idxTr);
            if isnan(on_val),  on_val = 0; end
            if isnan(off_val), off_val = speechWinDur; end

            yl_t = ylim(axTile);
            hLOn  = line(axTile, [on_val on_val],   yl_t, 'Color', 'r', 'LineWidth', 1.5);
            hLOff = line(axTile, [off_val off_val], yl_t, 'Color', 'r', 'LineWidth', 1.5);
            
            hTOn  = text(axTile, on_val,  yl_t(2)*0.8, ' On',  'Color', 'r', 'FontSize', 8, 'FontWeight', 'bold');
            hTOff = text(axTile, off_val, yl_t(2)*0.8, ' Off', 'Color', 'r', 'FontSize', 8, 'FontWeight', 'bold');
            hold(axTile, 'off');

            tileLinesOn{idxTr}  = hLOn;
            tileLinesOff{idxTr} = hLOff;
            tileTextsOn{idxTr}  = hTOn;
            tileTextsOff{idxTr} = hTOff;

            set(hLOn,  'ButtonDownFcn', @(src, ~) startLineDrag(src, axTile, idxTr));
            set(hLOff, 'ButtonDownFcn', @(src, ~) startLineDrag(src, axTile, idxTr));

            uicontrol('Parent', hPanel, 'Style', 'pushbutton', 'String', '▶ Play', ...
                'Units', 'normalized', 'Position', [0.02, 0.04, 0.22, 0.22], ...
                'FontSize', 9, 'Callback', @(~,~) play_trial_audio(idxTr, axTile));

            bgRadio = uibuttongroup('Parent', hPanel, 'Units', 'normalized', ...
                'Position', [0.28, 0.02, 0.70, 0.26], 'BorderType', 'none');
            tileRadioGrp{idxTr} = bgRadio;

            rbAcc = uicontrol('Parent', bgRadio, 'Style', 'radiobutton', 'String', 'Accept', ...
                'Units', 'normalized', 'Position', [0.05, 0.10, 0.45, 0.80], 'FontSize', 9);
            rbRej = uicontrol('Parent', bgRadio, 'Style', 'radiobutton', 'String', 'Reject', ...
                'Units', 'normalized', 'Position', [0.52, 0.10, 0.45, 0.80], 'FontSize', 9);

            if trials.include_trial_for_assess(idxTr)
                set(bgRadio, 'SelectedObject', rbAcc);
            else
                set(bgRadio, 'SelectedObject', rbRej);
            end
        end

        while ~finalized_clicked && ishandle(hFinalGui)
            drawnow;
            pause(0.05);
        end

        if ishandle(hFinalGui)
            for idxTr = 1:nTrialsAll
                if ishandle(tileRadioGrp{idxTr})
                    selObj = get(tileRadioGrp{idxTr}, 'SelectedObject');
                    strSel = get(selObj, 'String');
                    trials.include_trial_for_assess(idxTr) = strcmp(strSel, 'Accept');
                end
            end
            close(hFinalGui);
        end
    end
end

%% ---- Post-Assessment Display & Summary ------------------------------
if cfg.assess_syllable_rate
    acc_idx = trials.include_trial_for_assess;
    acc_trials = trials(acc_idx, :);

    if ~isempty(acc_trials)
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

            adj_ratio          = cfg.intraop_to_preop_to_speed_ratio;
            adj_syl_rate       = mean_syl_rate * adj_ratio;

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


%% =================== Nested & Local functions ========================

    function keyPressCallback(~, eventData)
        if strcmp(eventData.Key, 'space')
            if ~isempty(btnAccept) && ishandle(btnAccept) && strcmp(get(btnAccept, 'Enable'), 'on')
                user_choice = 'accept';
                if ishandle(hAssessStatusSquare)
                    set(hAssessStatusSquare, 'FaceColor', [0 0.8 0.2], 'Visible', 'on');
                    drawnow;
                    pause(0.3);
                    set(hAssessStatusSquare, 'Visible', 'off'); drawnow;
                end
            end
        elseif strcmp(eventData.Key, 'backspace')
            if cfg.assess_syllable_rate
                user_choice = 'reject';
                if ishandle(hAssessStatusSquare)
                    set(hAssessStatusSquare, 'FaceColor', [0.9 0.1 0.1], 'Visible', 'on');
                    drawnow;
                    pause(0.3);
                    set(hAssessStatusSquare, 'Visible', 'off'); drawnow;
                end
            end
        elseif strcmp(eventData.Key, 'escape')
            if cfg.assess_syllable_rate
                user_choice = 'quit';
            end
            escaped = true;
        end
    end

    function set_choice(choice)
        user_choice = choice;
    end

    function finalize_review()
        finalized_clicked = true;
    end

    function adjust_amp(delta)
        cfg.speech_rms_thresh_amp = max(0.001, cfg.speech_rms_thresh_amp + delta);
        if exist('itrial', 'var') && itrial <= cfg.ntrials
            update_rms_detection(itrial);
        end
    end

    function adjust_dur(delta)
        cfg.speech_rms_thresh_dur = max(0.001, cfg.speech_rms_thresh_dur + delta);
        if exist('itrial', 'var') && itrial <= cfg.ntrials
            update_rms_detection(itrial);
        end
    end

    function adjust_global_amp(delta)
        cfg.speech_rms_thresh_amp = max(0.001, cfg.speech_rms_thresh_amp + delta);
        if ~isempty(txtGlobalAmp) && ishandle(txtGlobalAmp)
            set(txtGlobalAmp, 'String', sprintf('RMS Amp: %.3f', cfg.speech_rms_thresh_amp));
        end
        recompute_unadjusted_trials();
    end

    function adjust_global_dur(delta)
        cfg.speech_rms_thresh_dur = max(0.001, cfg.speech_rms_thresh_dur + delta);
        if ~isempty(txtGlobalDur) && ishandle(txtGlobalDur)
            set(txtGlobalDur, 'String', sprintf('RMS Dur: %.3f s', cfg.speech_rms_thresh_dur));
        end
        recompute_unadjusted_trials();
    end

    function recompute_unadjusted_trials()
        for idxT = 1:height(trials)
            if ~is_manually_adjusted(idxT)
                update_rms_detection(idxT);
            end
        end
    end

    function update_rms_detection(trIdx)
        if trIdx > numel(recorded_audio_all) || isempty(recorded_audio_all{trIdx})
            return;
        end
        sig_tr = recorded_audio_all{trIdx};
        fs = cfg.aud_player_fs;
        t_vec = (0:length(sig_tr)-1)' / fs;

        N_win = max(1, round(cfg.speech_rms_thresh_dur * fs));
        rms_sig = sqrt(movmean(sig_tr.^2, [0, N_win-1]));

        % Minimum reaction time / post-GO wait guard interval.
        % Ignore transient noise/beep residue occurring within cfg.assess_wait_after_go of GO cue.
        min_onset_sec = cfg.assess_wait_after_go;
        valid_mask = t_vec >= min_onset_sec;

        above_thresh_idx = find((rms_sig >= cfg.speech_rms_thresh_amp) & valid_mask);

        if ~isempty(above_thresh_idx)
            onset_idx  = above_thresh_idx(1);
            offset_idx = min(above_thresh_idx(end) + N_win - 1, length(sig_tr));
            t_onset    = t_vec(onset_idx);
            t_offset   = t_vec(offset_idx);
        else
            t_onset  = 0;
            t_offset = speechWinDur;
        end

        trials.speech_on_for_assess(trIdx)  = t_onset;
        trials.speech_off_for_assess(trIdx) = t_offset;
        trials.speech_dur_for_assess(trIdx) = t_offset - t_onset;

        if exist('itrial', 'var') && trIdx == itrial && ~isempty(axGui) && ishandle(axGui)
            if ishandle(hLineOn) && ishandle(hLineOff)
                set(hLineOn,  'XData', [t_onset t_onset]);
                set(hLineOff, 'XData', [t_offset t_offset]);
            end
            if ishandle(hTextOn) && ishandle(hTextOff)
                yl = ylim(axGui);
                set(hTextOn,  'Position', [t_onset,  yl(2)*0.85, 0]);
                set(hTextOff, 'Position', [t_offset, yl(2)*0.85, 0]);
            end
            if ~isempty(txtAmp) && ishandle(txtAmp), set(txtAmp, 'String', sprintf('RMS Amp: %.3f', cfg.speech_rms_thresh_amp)); end
            if ~isempty(txtDur) && ishandle(txtDur), set(txtDur, 'String', sprintf('RMS Dur: %.3f s', cfg.speech_rms_thresh_dur)); end
        end

        if exist('tileLinesOn', 'var') && trIdx <= numel(tileLinesOn)
            if ishandle(tileLinesOn{trIdx}) && ishandle(tileLinesOff{trIdx})
                set(tileLinesOn{trIdx},  'XData', [t_onset t_onset]);
                set(tileLinesOff{trIdx}, 'XData', [t_offset t_offset]);
            end
            if ishandle(tileTextsOn{trIdx}) && ishandle(tileTextsOff{trIdx})
                yl_tile = ylim(tileAxes{trIdx});
                set(tileTextsOn{trIdx},  'Position', [t_onset,  yl_tile(2)*0.8, 0]);
                set(tileTextsOff{trIdx}, 'Position', [t_offset, yl_tile(2)*0.8, 0]);
            end
        end
        drawnow;
    end

    function play_current_trial_audio()
        if exist('itrial', 'var')
            play_trial_audio(itrial, axGui);
        end
    end

    function play_trial_audio(trIdx, axTarget)
        if trIdx > numel(recorded_audio_all) || isempty(recorded_audio_all{trIdx})
            return;
        end
        sig = recorded_audio_all{trIdx};
        if all(sig == 0), return; end

        fs_aud = cfg.aud_player_fs;
        player = audioplayer(sig, fs_aud);

        yl = ylim(axTarget);
        hold(axTarget, 'on');
        hCursor = line(axTarget, [0 0], yl, 'Color', [0 0.5 1], 'LineWidth', 1.5, 'LineStyle', '--');
        hold(axTarget, 'off');

        play(player);
        while isplaying(player) && ishandle(axTarget)
            currSample = get(player, 'CurrentSample');
            if currSample > 0 && ishandle(hCursor)
                currTime = currSample / fs_aud;
                set(hCursor, 'XData', [currTime currTime]);
            end
            drawnow limitrate;
            pause(0.01);
        end
        if ishandle(hCursor), delete(hCursor); end
    end

    function startLineDrag(hLine, ax, trIdx)
        fig = ancestor(ax, 'figure');
        set(fig, 'WindowButtonMotionFcn', @(~,~) dragLine(hLine, ax, trIdx));
        set(fig, 'WindowButtonUpFcn',     @(~,~) stopLineDrag(fig));
    end

    function dragLine(hLine, ax, trIdx)
        cp = get(ax, 'CurrentPoint');
        newX = cp(1, 1);
        xl = xlim(ax);
        newX = max(xl(1), min(xl(2), newX));
        set(hLine, 'XData', [newX, newX]);
        is_manually_adjusted(trIdx) = true;
    end

    function stopLineDrag(fig)
        set(fig, 'WindowButtonMotionFcn', '');
        set(fig, 'WindowButtonUpFcn', '');
    end

    function [space, esc, backspace] = KeyPoll()
        space     = System.Windows.Input.Keyboard.IsKeyDown(System.Windows.Input.Key.Space);
        esc       = System.Windows.Input.Keyboard.IsKeyDown(System.Windows.Input.Key.Escape);
        backspace = System.Windows.Input.Keyboard.IsKeyDown(System.Windows.Input.Key.Back);
    end

end   % task_metro

function formatted = format_syllables_tex(str_text, colors)
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