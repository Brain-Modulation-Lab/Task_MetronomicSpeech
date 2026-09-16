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
% Logging
%  First tick   → TRIG_METRONOME (Metronome_Onset) written first, then TRIG_METRO_TICK
%  Every tick   → TRIG_METRO_TICK (Tick_N)
%  Last tick end→ TRIG_METRONOME (Metronome_Offset)
%
% ESC handling
%  During a trial  : escaped flag set; current trial completes normally, then exit.
%  During a pause  : immediate clean exit.

%% ---- Default optional fields ----------------------------------------
if ~isfield(cfg,'play_go_cue'),           cfg.play_go_cue           = true;  end
if ~isfield(cfg,'STOP_BETWEEN_TRIALS'),   cfg.STOP_BETWEEN_TRIALS   = false; end
if ~isfield(cfg,'pause_every_n_trials'),  cfg.pause_every_n_trials  = inf;   end
if ~isfield(cfg,'speech_window_dur'),     cfg.speech_window_dur     = 5;     end

%% ---- Validate -------------------------------------------------------
if ~isfield(cfg,'PATH_TASK') || ~isfolder(cfg.PATH_TASK)
    error('cfg.PATH_TASK missing or invalid.');
end
if ~isfield(cfg,'EVENT_FILENAME') || ~isfield(cfg,'TRIAL_FILENAME')
    error('cfg.EVENT_FILENAME and cfg.TRIAL_FILENAME are required.');
end

%% ---- .NET keyboard --------------------------------------------------
NET.addAssembly('PresentationCore');

%% ---- Timing helpers -------------------------------------------------
ticH  = tic;
t0abs = seconds(timeofday(datetime('now')));  % s-since-midnight at task start
T.now   = @()  t0abs + toc(ticH);            % current absolute time
T.wait  = @(s) pause(max(0, s));
T.until = @(t) pause(max(0, t - T.now()));

%% ---- Build trial table ----------------------------------------------
addpath(cfg.PATH_TASK);
[cfg, trials, text_wrapped_all] = create_trials_table_metro(cfg);
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
    'Units','normalized','Interpreter','none');
pdLen   = 0.05;
hSquare = annotation('rectangle','FaceColor',[1 1 1],'EdgeColor','none', ...
    'Position',[0, 1-pdLen, pdLen, pdLen]);

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

% GO beep waveform
N_go         = round(cfg.go_beep_dur * cfg.aud_player_fs);
t_go         = (0:N_go-1)' / cfg.aud_player_fs;
go_beep_wave = cfg.go_beep_amp * sin(2*pi * cfg.go_beep_freq * t_go);

% Single metronome tick waveform
N_tick           = round(cfg.tick_dur * cfg.aud_player_fs);
t_tick_v         = (0:N_tick-1)' / cfg.aud_player_fs;
tick_wave_single = cfg.metronome_amplitude * sin(2*pi * cfg.tick_freq * t_tick_v);

% Tick schedule: ticks at 0, 1/R, 2/R, ... (all onsets within metro_dur)
tick_rel_times = (0 : floor(cfg.metro_dur * cfg.metro_rate))' / cfg.metro_rate;
tick_rel_times = tick_rel_times(tick_rel_times < cfg.metro_dur + 1e-9);
n_ticks        = numel(tick_rel_times);

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
        fclose(eventFH); close(hfig); return;
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

    % ==================================================================
    % 1.  ITI — fixation cross
    % ==================================================================
    set(hText,'String','*','Color',[0.7 0.7 0.7],'FontSize',cfg.stim_font_size);
    set(hSquare,'FaceColor',[0.3 0.3 0.3]); drawnow;
    tFixOn = T.now();
    flipState = ~flipState;
    log_event(eventFH,doDigOut,tFixOn,[],[],ttype,[],TRIG_FIX_CROSS,'Fixation_Cross_Onset',flipState);

    itiDur  = cfg.iti(1) + rand*(cfg.iti(2) - cfg.iti(1));
    tItiEnd = tFixOn + itiDur;
    while T.now() < tItiEnd - 0.001
        [~,esc] = KeyPoll();
        if esc && ~escaped
            escaped = true;
            flipState = ~flipState;
            log_event(eventFH,doDigOut,T.now(),[],[],ttype,[],TRIG_ESC,'Key_Esc_Detected',flipState);
        end
        T.wait(0.005);
    end
    T.until(tItiEnd);

    % ==================================================================
    % 2a.  Visual stimulus ON
    % ==================================================================
    set(hSquare,'FaceColor',[0 0 0]);
    set(hText,'String',text_wrapped_all{trials.stim_idx(itrial)}, ...
        'Color',cfg.text_color,'FontSize',cfg.stim_font_size);
    drawnow;
    tVisOn    = T.now();
    flipState = ~flipState;
    log_event(eventFH,doDigOut,tVisOn,[],[],ttype,trials.stim{itrial},TRIG_VIS,'Visual_Onset',flipState);
    fprintf('\n[%d/%d]  metro=%d  |  %s\n', ...
        itrial, cfg.ntrials, trials.metro_speech(itrial), trials.stim{itrial});

    % ==================================================================
    % 2b.  Metronome epoch  (always cfg.metro_dur s referenced from tVisOn)
    % ==================================================================
    tMetroEpochEnd = tVisOn + cfg.metro_dur;

    if trials.metro_speech(itrial)
        % ---- metro_speech trial: play ticks, log each one ----

        tMetroStart = T.now();   % ≈ tVisOn; reference for tick scheduling
        tLastTick   = tMetroStart;

        for itick = 1:n_ticks

            tTick = tMetroStart + tick_rel_times(itick);

            % Wait until 2 ms before tick, polling ESC in the gap
            while T.now() < tTick - 0.002
                [~,esc] = KeyPoll();
                if esc && ~escaped
                    escaped = true;
                    flipState = ~flipState;
                    log_event(eventFH,doDigOut,T.now(),[],[],ttype,[],TRIG_ESC,'Key_Esc_Detected',flipState);
                end
                T.wait(0.001);
            end
            T.until(tTick);                  % precision spin for final ≤ 2 ms

            audWriter(tick_wave_single);     % play tick
            tActual   = T.now();
            tLastTick = tActual;

            % First tick: TRIG_METRONOME (onset) BEFORE TRIG_METRO_TICK
            if itick == 1
                flipState = ~flipState;
                log_event(eventFH,doDigOut,tActual,cfg.tick_dur,[],ttype,[],TRIG_METRONOME,'Metronome_Onset',flipState);
            end
            flipState = ~flipState;
            log_event(eventFH,doDigOut,tActual,cfg.tick_dur,[],ttype,[],TRIG_METRO_TICK,sprintf('Tick_%d',itick),flipState);
        end

        % Metronome offset = end of last tick
        T.until(tLastTick + cfg.tick_dur);
        flipState = ~flipState;
        log_event(eventFH,doDigOut,T.now(),0,[],ttype,[],TRIG_METRONOME,'Metronome_Offset',flipState);

        % Wait out any remaining metro epoch time
        while T.now() < tMetroEpochEnd - 0.001
            [~,esc] = KeyPoll();
            if esc && ~escaped
                escaped = true;
                flipState = ~flipState;
                log_event(eventFH,doDigOut,T.now(),[],[],ttype,[],TRIG_ESC,'Key_Esc_Detected',flipState);
            end
            T.wait(0.005);
        end
        T.until(tMetroEpochEnd);

    else
        % ---- speech-only trial: identical timing, silence ----
        while T.now() < tMetroEpochEnd - 0.001
            [~,esc] = KeyPoll();
            if esc && ~escaped
                escaped = true;
                flipState = ~flipState;
                log_event(eventFH,doDigOut,T.now(),[],[],ttype,[],TRIG_ESC,'Key_Esc_Detected',flipState);
            end
            T.wait(0.005);
        end
        T.until(tMetroEpochEnd);
    end

    % ==================================================================
    % 3.  Jittered silent delay  (pre-computed per trial)
    % ==================================================================
    tDelayEnd = T.now() + trials.go_latency(itrial);
    while T.now() < tDelayEnd - 0.001
        [~,esc] = KeyPoll();
        if esc && ~escaped
            escaped = true;
            flipState = ~flipState;
            log_event(eventFH,doDigOut,T.now(),[],[],ttype,[],TRIG_ESC,'Key_Esc_Detected',flipState);
        end
        T.wait(0.005);
    end
    T.until(tDelayEnd);

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
    % 5.  Speech window
    % ==================================================================
    tSpeechEnd = tSpeechStart + cfg.speech_window_dur;
    while T.now() < tSpeechEnd - 0.001
        [~,esc] = KeyPoll();
        if esc && ~escaped
            escaped = true;
            flipState = ~flipState;
            log_event(eventFH,doDigOut,T.now(),[],[],ttype,[],TRIG_ESC,'Key_Esc_Detected',flipState);
        end
        T.wait(0.005);
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

    % ---- Append trial row to TSV ----
    if itrial == 1
        writetable(trials(itrial,:), cfg.TRIAL_FILENAME, ...
            'Delimiter','\t','FileType','text','WriteVariableNames',true);
    else
        writetable(trials(itrial,:), cfg.TRIAL_FILENAME, ...
            'Delimiter','\t','FileType','text','WriteMode','append','WriteVariableNames',false);
    end

    % ---- Exit cleanly if ESC was pressed during this trial ----
    if escaped
        fprintf('ESC detected — exiting after trial %d/%d.\n', itrial, cfg.ntrials);
        break;
    end

    % ==================================================================
    % Between-trial pauses
    % ==================================================================
    doPause = isfinite(cfg.pause_every_n_trials) && ...
              mod(itrial, cfg.pause_every_n_trials) == 0 && ...
              itrial < cfg.ntrials;

    if doPause
        %---- Scheduled rest break ----
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
                escaped = true;
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
        %---- Per-trial manual advance ----
        fprintf('Trial %d/%d complete. Press SPACE for next trial...\n', itrial, cfg.ntrials);
        while true
            [space,esc] = KeyPoll();
            if esc
                escaped = true;
                flipState = ~flipState;
                log_event(eventFH,doDigOut,T.now(),[],[],'control',[],TRIG_ESC,'Key_Esc_Between_Trials',flipState);
                break;
            end
            if space, break; end
            T.wait(0.01);
        end
        if escaped, break; end
    end

end   % for itrial

%% ---- Cleanup -------------------------------------------------------
fprintf('Task complete.\n');
fclose(eventFH);
if ishandle(hfig), close(hfig); end


%% =================== Local functions ================================
    function [space, esc] = KeyPoll()
        space = System.Windows.Input.Keyboard.IsKeyDown(System.Windows.Input.Key.Space);
        esc   = System.Windows.Input.Keyboard.IsKeyDown(System.Windows.Input.Key.Escape);
    end

end   % task_metro