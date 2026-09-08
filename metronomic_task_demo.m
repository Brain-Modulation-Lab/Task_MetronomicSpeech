function metronomic_task_demo
% METRONOMIC_TASK_DEMO  Self-contained demo of the metronomic paced-reading task.
%
% AUDIO metronome version. The sentence is shown as a static visual stimulus;
% the metronome is now auditory and plays BEFORE the GO beep, not during speech.
%
%   Trial timeline:
%     +                fixation
%     sentence ON  ----------------------------------------------------
%     | epoch 1: auditory metronome  (metronome_duration s, rate = beat_dur)
%     | epoch 2: silent period       (jittered pre_speech_delay s, sentence still up)
%     GO beep
%     | speech window                (speech_window_dur s, sentence still up)
%     sentence OFF -> blank
%     jittered ITI
%
% No external files, no hardware, no extra toolboxes (plain figure + sound()).
%
% Just run:  >> metronomic_task_demo
% remove black screen between cross
% make that start script to run this one
%% ---------------- CONFIG (edit these freely) ----------------
% --- the delays / timing that define the task ---
metronome_duration = 1.5;         % sec the auditory metronome plays (epoch 1 of pre-go period)
beat_dur           = 0.33;        % sec between metronome beats = metronome rate
pre_speech_delay   = [0.75 1.24]; % jittered silent period (sec) after metronome offset, before GO beep (epoch 2)
speech_window_dur  = 5;           % sec between GO beep onset and visual stimulus disappearing
iti_range          = [0.75 1.25]; % jittered inter-trial interval (sec)

n_blocks           = 2;           % how many times to run through the sentence set
randomize_order    = true;        % shuffle sentence order within each block
wait_for_space     = true;        % require spacebar to start each trial

% --- visual stimulus appearance ---
max_char_per_line  = 26;          % wrap the sentence to this many characters per line
stim_font_size     = 34;

% --- sounds ---
go_freq = 1000; go_dur = 0.05; go_amp = 0.5;   % GO beep
play_metronome      = true;                     % whether to play the auditory metronome in epoch 1
metronome_amplitude = 0.30;                     % 0..1 loudness of the metronome
tick_freq = 1600; tick_dur = 0.02;              % tone/character of each metronome click

% --- stimuli (plain sentences; no markup needed anymore) ---
sentences = { ...
    'Whistling winds whipped through weathered shutters during stormy nights.'
    'The mountain river flowed swiftly past the quiet village.'
    'Golden sunlight spilled across the open meadow at dawn.'
    'She carefully folded each letter before sealing the envelope.'
    };

%% ---------------- Build trial list ----------------
sent_seq = [];
for b = 1:n_blocks
    order = 1:numel(sentences);
    if randomize_order, order = order(randperm(numel(order))); end
    sent_seq = [sent_seq, order]; %#ok<AGROW>
end
n_trials = numel(sent_seq);

%% ---------------- Precompute sounds ----------------
fs       = 44100;
goBeep   = makeTone(go_freq, go_dur, go_amp, fs);
tickWave = makeTone(tick_freq, tick_dur, 1.0, fs);   % unit-amplitude click
metroWave= makeMetronome(beat_dur, metronome_duration, tickWave, metronome_amplitude, fs);

%% ---------------- Set up the display ----------------
fig = figure('Color','k','MenuBar','none','ToolBar','none', ...
             'Name','Metronomic task demo','NumberTitle','off', ...
             'Units','normalized','Position',[0.15 0.15 0.7 0.7]);
ax = axes('Parent',fig,'Position',[0 0 1 1],'Color','k', ...
          'XColor','none','YColor','none','XLim',[0 1],'YLim',[0 1]);
txt = text(ax,0.5,0.5,'','Color','w','FontSize',stim_font_size, ...
           'HorizontalAlignment','center','VerticalAlignment','middle', ...
           'FontName','Helvetica','Interpreter','none');
info = text(ax,0.5,0.06,'','Color',[0.5 0.5 0.5],'FontSize',14, ...
            'HorizontalAlignment','center','VerticalAlignment','middle');
cleanupFig = onCleanup(@() closeIfOpen(fig));

%% ---------------- Instructions ----------------
set(txt,'String',{'Listen to the metronome while the sentence appears.';'When you hear the beep, read it aloud.';'';'Press SPACE to begin.'});
drawnow; waitForSpace(fig);

%% ---------------- Trial loop ----------------
for k = 1:n_trials
    if ~ishandle(fig), break; end
    lines = wrapText(sentences{sent_seq(k)}, max_char_per_line);

    % per-trial start gate
    if wait_for_space
        set(txt,'String','+'); set(info,'String',sprintf('Trial %d of %d  |  press SPACE',k,n_trials)); drawnow;
        waitForSpace(fig);
    else
        set(txt,'String','+'); set(info,'String',''); drawnow; pause(0.5);
    end

    % ---- visual stimulus onset (sentence stays up through both epochs + speech) ----
    set(txt,'String', lines); set(info,'String',''); drawnow;

    % ---- pre-go epoch 1: auditory metronome ----
    if play_metronome && ishandle(fig), sound(metroWave, fs); end
    pause(metronome_duration);

    % ---- pre-go epoch 2: silent period (visual still shown) ----
    pause(jitter(pre_speech_delay));

    % ---- GO beep ----
    if ishandle(fig), sound(goBeep, fs); end

    % ---- speech window: sentence stays up ----
    pause(speech_window_dur);

    % ---- visual offset -> blank, then jittered ITI ----
    if ishandle(fig), set(txt,'String',''); set(info,'String',''); drawnow; end
    pause(jitter(iti_range));
end

%% ---------------- End ----------------
if ishandle(fig)
    set(txt,'String','Done. Thank you!'); set(info,'String',''); drawnow; pause(1.5);
end
end  % metronomic_task_demo


%% ================= local helper functions =================
function lines = wrapText(str, maxChars)
% Word-wrap a plain sentence into a cell array of lines <= maxChars.
words = strsplit(strtrim(str), ' ');
lines = {}; cur = '';
for i = 1:numel(words)
    w = words{i};
    if isempty(cur)
        cur = w;
    elseif numel(cur) + 1 + numel(w) <= maxChars
        cur = [cur ' ' w];
    else
        lines{end+1} = cur; cur = w; %#ok<AGROW>
    end
end
if ~isempty(cur), lines{end+1} = cur; end
if isempty(lines), lines = {''}; end
end

function y = makeMetronome(beat_dur, total_dur, tick, amp, fs)
% Build one metronome waveform: unit-amplitude 'tick' placed every beat_dur
% seconds across total_dur seconds, scaled by amp (0..1).
N = round(total_dur * fs);
y = zeros(1, N);
tickN = numel(tick);
for ot = 0 : beat_dur : (total_dur - 1e-9)   % beat onsets: 0, beat_dur, 2*beat_dur, ...
    s0 = round(ot*fs) + 1;
    s1 = min(N, s0 + tickN - 1);
    y(s0:s1) = y(s0:s1) + amp * tick(1:(s1 - s0 + 1));
end
end

function y = makeTone(freq, dur, amp, fs)
tt = 0:1/fs:dur;
y = amp * sin(2*pi*freq*tt);
n = max(1, round(0.005*fs));               % 5 ms fade in/out to avoid clicks
env = ones(size(y));
env(1:n) = linspace(0,1,n);
env(end-n+1:end) = linspace(1,0,n);
y = y .* env;
end

function v = jitter(range2)
v = range2(1) + diff(range2)*rand;
end

function waitForSpace(fig)
if ~ishandle(fig), return; end
set(fig,'CurrentCharacter','0');
while ishandle(fig) && double(get(fig,'CurrentCharacter')) ~= 32
    pause(0.02);
end
end

function closeIfOpen(fig)
if ishandle(fig), close(fig); end
end