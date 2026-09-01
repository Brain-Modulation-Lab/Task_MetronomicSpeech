function daf_task_demo
% DAF_TASK_DEMO  Minimal, self-contained demo of the Delayed Auditory Feedback task.
%
 %
% Each trial:  fixation  ->  sentence on screen  ->  jittered wait  ->  GO beep
%              ->  response window (subject reads aloud)  ->  short break (ITI)
%
% The "delay" condition is shown on screen to convey the manipulation. In the
% real experiment that number is the millisecond delay applied to the subject's
% own voice fed back through headphones (true DAF); doing that live needs
% dedicated audio hardware, so here it's just displayed, not applied.
%
% Just run:  >> daf_task_demo

%% ---------------- CONFIG (edit these freely) ----------------
delay_values_ms      = [0 50 255];   % 0 = no delay, low delay, high delay
n_blocks             = 2;            % how many times to cycle through all delays
trials_per_miniblock = 2;            % consecutive trials at the same delay
randomize_order      = true;         % shuffle delay order within each block

go_latency_range = [1.5 2.5];   % jittered sec between sentence onset and beep
response_window  = 4;           % sec the subject has to speak after the beep
iti_range        = [0.75 1.25]; % inter-trial interval (sec)
wait_for_space   = true;        % require spacebar to start each trial

beep_freq = 1000;   % Hz
beep_dur  = 0.05;   % sec
beep_amp  = 0.5;    % 0..1

sentences = { ...
    'The quick brown fox jumps over the lazy dog.'
    'She sells seashells by the seashore.'
    'Bright blue birds fly above the green hills.'
    'My grandmother baked bread every Sunday morning.'
    'The train arrived exactly on time today.'
    'Please pass the salt and pepper across the table.'
    };

%% ---------------- Build trial list ----------------
delay_seq = [];
for b = 1:n_blocks
    order = delay_values_ms;
    if randomize_order, order = order(randperm(numel(order))); end
    for d = order
        delay_seq = [delay_seq, repmat(d, 1, trials_per_miniblock)]; %#ok<AGROW>
    end
end
n_trials = numel(delay_seq);

% pick a sentence for each trial (cycle through the list)
sent_idx = mod(0:n_trials-1, numel(sentences)) + 1;

%% ---------------- Precompute the beep ----------------
fs = 44100;
tt = 0:1/fs:beep_dur;
beep = beep_amp * sin(2*pi*beep_freq*tt);

%% ---------------- Set up the display ----------------
fig = figure('Color','k','MenuBar','none','ToolBar','none', ...
             'Name','DAF task demo','NumberTitle','off', ...
             'Units','normalized','Position',[0.15 0.15 0.7 0.7]);
ax = axes('Parent',fig,'Position',[0 0 1 1],'Color','k', ...
          'XColor','none','YColor','none','XLim',[0 1],'YLim',[0 1]);
txt = text(ax,0.5,0.5,'','Color','w','FontSize',36, ...
           'HorizontalAlignment','center','VerticalAlignment','middle', ...
           'FontName','Helvetica');
info = text(ax,0.5,0.06,'','Color',[0.5 0.5 0.5],'FontSize',14, ...
            'HorizontalAlignment','center','VerticalAlignment','middle');
cleanupFig = onCleanup(@() closeIfOpen(fig));

%% ---------------- Instructions ----------------
show(txt, sprintf('Read each sentence aloud when you hear the beep.\n\nPress SPACE to begin.'));
set(info,'String','');
waitForSpace(fig);

%% ---------------- Trial loop ----------------
for k = 1:n_trials
    if ~ishandle(fig), break; end
    delay = delay_seq(k);
    sentence = sentences{sent_idx(k)};

    % per-trial start gate
    if wait_for_space
        show(txt, '+');                                  % fixation cross
        set(info,'String',sprintf('Trial %d of %d  |  press SPACE', k, n_trials));
        waitForSpace(fig);
    else
        show(txt, '+');
        pause(0.5);
    end

    % show the sentence
    show(txt, sentence);
    set(info,'String',sprintf('delay: %d ms', delay));

    % jittered wait, then GO beep
    pause(jitter(go_latency_range));
    if ishandle(fig), sound(beep, fs); end

    % response window (subject speaks)
    pause(response_window);

    % inter-trial interval (blank)
    show(txt, '');
    set(info,'String','');
    pause(jitter(iti_range));
end

%% ---------------- End ----------------
if ishandle(fig)
    show(txt, 'Done. Thank you!');
    set(info,'String','');
    pause(1.5);
end
end  % daf_task_demo


%% ================= local helper functions =================
function v = jitter(range2)
% random value uniformly in [range2(1), range2(2)]
v = range2(1) + diff(range2)*rand;
end

function show(hTxt, str)
% update the on-screen text and force a redraw
if ishandle(hTxt)
    set(hTxt,'String',str);
    drawnow;
end
end

function waitForSpace(fig)
% block until the user presses the spacebar (figure must have focus)
if ~ishandle(fig), return; end
set(fig,'CurrentCharacter','0');
while ishandle(fig) && double(get(fig,'CurrentCharacter')) ~= 32
    pause(0.02);
end
end

function closeIfOpen(fig)
if ishandle(fig), close(fig); end
end 