function metronomic_task_demo
% METRONOMIC_TASK_DEMO  Self-contained demo of the metronomic paced-reading task.
%
% Same structure as the DAF demo (jittered GO latency -> GO beep -> response
% window -> jittered ITI), but the response window is a METRONOME-PACED reading:
% the sentence stays on screen and its syllables highlight one at a time, one per
% beat (default 0.33 s), starting at the GO beep. This paces the subject's speech.
%
% No external files, no hardware, no extra toolboxes (plain figure + sound()).
%
%   Trial timeline (matches the diagram):
%     +           fixation
%     sentence    shown plain (white) during the jittered GO latency
%     GO beep     ---------------------------------------------------
%     |  syllable 1 green | syllable 2 green | ... |   <- 0.33 s each  = response window
%     blank       jittered ITI
%
% Just run:  >> metronomic_task_demo

%% ---------------- CONFIG (edit these freely) ----------------
% --- the delays that define the task ---
go_latency_range = [1.5 2.5];   % jittered sec between sentence onset and GO beep
beat_dur         = 0.33;        % sec per metronome beat = time each syllable stays highlighted
iti_range        = [0.75 1.25]; % jittered inter-trial interval (sec)
% NOTE: the response window is NOT set directly. It equals
%       (number of syllables) x beat_dur, so it paces itself (~5 s here, "x15" in the diagram).

n_blocks         = 2;           % how many times to run through the sentence set
randomize_order  = true;        % shuffle sentence order within each block
wait_for_space   = true;        % require spacebar to start each trial

% --- highlighting appearance ---
highlight_color  = [0 0.75 0];  % RGB of the highlighted syllable (green)
max_char_per_line= 26;          % wrap the sentence to this many characters per line
stim_font_size   = 34;

% --- sounds ---
go_freq = 1000; go_dur = 0.05; go_amp = 0.5;   % GO beep
play_metronome = true;                          % soft tick on every beat
tick_freq = 1600; tick_dur = 0.02; tick_amp = 0.25;

% --- stimuli ---
% Mark syllable boundaries WITHIN a word using hyphens '-'. Words are separated
% by spaces. The hyphens are NOT displayed; they only tell the code where each
% highlight step lands. This is how you control "how the words highlight":
%   'Whis-tling'  -> highlights "Whis" then "ling"
%   'winds'       -> highlights the whole word in one beat
sentences = { ...
    'Whis-tling winds whipped through wea-thered shut-ters du-ring stor-my nights.'
    'The moun-tain riv-er flowed swift-ly past the qui-et vil-lage.'
    'Gold-en sun-light spilled a-cross the o-pen mead-ow at dawn.'
    'She care-ful-ly folded each let-ter be-fore seal-ing the en-ve-lope.'
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
fs      = 44100;
goBeep  = makeTone(go_freq,  go_dur,  go_amp,  fs);
tick    = makeTone(tick_freq,tick_dur,tick_amp,fs);

%% ---------------- Set up the display ----------------
fig = figure('Color','k','MenuBar','none','ToolBar','none', ...
             'Name','Metronomic task demo','NumberTitle','off', ...
             'Units','normalized','Position',[0.15 0.15 0.7 0.7]);
ax = axes('Parent',fig,'Position',[0 0 1 1],'Color','k', ...
          'XColor','none','YColor','none','XLim',[0 1],'YLim',[0 1]);
txt = text(ax,0.5,0.5,'','Color','w','FontSize',stim_font_size, ...
           'HorizontalAlignment','center','VerticalAlignment','middle', ...
           'FontName','Helvetica','Interpreter','tex');   % tex interpreter enables inline \color
info = text(ax,0.5,0.06,'','Color',[0.5 0.5 0.5],'FontSize',14, ...
            'HorizontalAlignment','center','VerticalAlignment','middle');
cleanupFig = onCleanup(@() closeIfOpen(fig));

%% ---------------- Instructions ----------------
set(txt,'String',{'Read the sentence aloud, keeping pace';'with the highlighted syllables.';'';'Press SPACE to begin.'});
drawnow; waitForSpace(fig);

%% ---------------- Trial loop ----------------
for k = 1:n_trials
    if ~ishandle(fig), break; end
    tokens = tokenizeSentence(sentences{sent_seq(k)});   % syllable tokens

    % per-trial start gate
    if wait_for_space
        set(txt,'String','+'); set(info,'String',sprintf('Trial %d of %d  |  press SPACE',k,n_trials)); drawnow;
        waitForSpace(fig);
    else
        set(txt,'String','+'); set(info,'String',''); drawnow; pause(0.5);
    end

    % show sentence plain (no highlight) during the jittered GO latency
    set(txt,'String', buildLines(tokens, 0, max_char_per_line, highlight_color)); set(info,'String',''); drawnow;
    pause(jitter(go_latency_range));

    % GO beep, then metronomic highlighting (this IS the response window)
    if ishandle(fig), sound(goBeep, fs); end
    for h = 1:numel(tokens)
        if ~ishandle(fig), break; end
        set(txt,'String', buildLines(tokens, h, max_char_per_line, highlight_color)); drawnow;
        if play_metronome && ishandle(fig), sound(tick, fs); end
        pause(beat_dur);
    end

    % blank ITI
    if ishandle(fig), set(txt,'String',''); set(info,'String',''); drawnow; end
    pause(jitter(iti_range));
end

%% ---------------- End ----------------
if ishandle(fig)
    set(txt,'String','Done. Thank you!'); set(info,'String',''); drawnow; pause(1.5);
end
end  % metronomic_task_demo


%% ================= local helper functions =================
function tokens = tokenizeSentence(marked)
% Split a hyphen-marked sentence into syllable tokens.
% Each token: .text (clean syllable), .len (visible chars), .isWordStart (bool)
tokens = struct('text',{},'len',{},'isWordStart',{});
words = strsplit(strtrim(marked), ' ');
for w = 1:numel(words)
    syl = strsplit(words{w}, '-');
    for s = 1:numel(syl)
        tokens(end+1) = struct('text',syl{s},'len',numel(syl{s}),'isWordStart',(s==1)); %#ok<AGROW>
    end
end
end

function lines = buildLines(tokens, activeIdx, maxChars, hlColor)
% Build a cell array of TeX strings (one per display line). The token at
% activeIdx is coloured/bold; activeIdx==0 means nothing highlighted.
% Wrapping only happens at word starts so a highlighted syllable never splits.
lines = {};
cur = ''; curLen = 0;
for i = 1:numel(tokens)
    t = tokens(i);
    if t.isWordStart && curLen > 0
        if curLen + 1 + t.len > maxChars      % would overflow -> new line
            lines{end+1} = cur; cur = ''; curLen = 0; %#ok<AGROW>
        else                                  % same line -> add a space
            cur = [cur ' ']; curLen = curLen + 1;
        end
    end
    if i == activeIdx
        piece = sprintf('{\\color[rgb]{%.3g,%.3g,%.3g}\\bf %s}', hlColor(1),hlColor(2),hlColor(3), texEscape(t.text));
    else
        piece = texEscape(t.text);
    end
    cur = [cur piece]; curLen = curLen + t.len;
end
if ~isempty(cur), lines{end+1} = cur; end
if isempty(lines), lines = {''}; end
end

function s = texEscape(s)
% escape the few characters the tex interpreter would otherwise treat specially
s = strrep(s,'\','\\');
s = strrep(s,'_','\_');
s = strrep(s,'^','\^');
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