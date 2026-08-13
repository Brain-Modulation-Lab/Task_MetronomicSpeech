%% this version of the function resulted in the events file having timepoints from hours earlier in sub DM1057 (and probably earlier ones)
%     probably due to incorrect use of persistent variabes
%
%   in future subjects (starting 2026 May), we reverted to the version of this script used in SMSL 
%       that version cannot run without psychtoolbox, but seems to cause less problems

function log_event(file, is_digout, onset, dur, samp, trial_type, stim_file, val, event_name, flip_sync)

% log_events in BIDS compatible events.tsv format
% file:         open connection to events file
% is_digout:    bool, is the ripple system connected through xippmex ready to send digital events out?
% onset:        float, onset time of event in seconds from time origin
% dur:          float, duration of the event in seconds. 
% samp:         uint, sample index on ripple system
% trial_type:   Primary categorisation of each trial to identify them as instances of the experimental conditions.
% stim_file:    Represents the location of the stimulus file presented at the given onset time.
% value:        Marker value associated with the event (e.g., the value of a TTL trigger that was recorded at the onset of the event).
% event_name:   Short name for the event
% flip_sync:     bool, screen flip sync signal level. 

%getting global time coordinate origin on first call
persistent t0
if isempty(t0)
    t0 = localGetSecs() - seconds(timeofday(datetime('now')));
end

if isempty(onset)
    onset = localGetSecs();
end
if isempty(dur), dur = 0; end
if isempty(val), val = 0; end

if isempty(flip_sync)
    flip_sync = double(0);
else
    flip_sync = double(logical(flip_sync));
end

if ~isempty(is_digout) && is_digout && exist('xippmex','file') == 3
    if isempty(samp), samp = xippmex('time'); end
    xippmex('digout', [1,2,3,4,5], [flip_sync,flip_sync,flip_sync,flip_sync, val + 32768 * flip_sync]);
else
    if isempty(samp), samp = 0; end
end

if isempty(trial_type), trial_type = 'n/a'; end
if isempty(stim_file),  stim_file  = 'n/a'; end
if isempty(event_name), event_name = 'n/a'; end

fprintf(file,'%10.6f\t%6.6f\t%i\t"%s"\t"%s"\t%i\t"%s"\n', onset - t0, dur, samp, trial_type, stim_file, val + 32768 * flip_sync, event_name);
% fflush(file); % optional but recommended

end

function t = localGetSecs()
    persistent tStart
    if exist('GetSecs','file') == 3 || exist('GetSecs','file') == 2
        t = GetSecs();
    else
        if isempty(tStart), tStart = tic; end
        t = toc(tStart);
    end
end