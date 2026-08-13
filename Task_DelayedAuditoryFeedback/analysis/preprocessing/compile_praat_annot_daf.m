
%% nb: we are curently using the 'timing' class wrong for everything except speech onset
.... the compiling script needs to have an option added that looks for pairs of onsets/offset timepoints, which is how most timing classes in DAF are being scored
    ..... maybe add 'timing-pair' class - save as X * 2 double array within each trial

%%%% import manual annotations from praaat textgrids into the trial table
clear

op.sub = 'DM1057';
op.ses = 'intraop'; 
op.task = 'daf'; 


%% construct praat tier table

praat_tiers_names = {'speech_epoch', 'sld_repetition', 'sld_prolongation',  'typical_disfluency', 'disfluency_resolution',...
    'slowing', 'distortion', 'error',  'comments', 'unusable_trial', 'difficult_to_score'};

n_tiers = length(praat_tiers_names); 
celcol = cell(n_tiers,1); 
nancol = nan(n_tiers,1); 

praat_tiers = table(praat_tiers_names', celcol,   celcol,               celcol, 'VariableNames', ...
                    {'name',           'class','n_times_min_max','timepoint_names'},...
                    'RowNames',praat_tiers_names'); 

praat_tiers.class{'speech_epoch'} = 'timing';
praat_tiers.n_times_min_max{'speech_epoch'} = [2 2]; 
praat_tiers.timepoint_names{'speech_epoch'} = {'sp_on','sp_off'}; 

praat_tiers.class{'sld_repetition'} = 'timing';
praat_tiers.class{'sld_prolongation'} = 'timing';
praat_tiers.class{'typical_disfluency'} = 'timing';
praat_tiers.class{'disfluency_resolution'} = 'timing';
praat_tiers.class{'slowing'} = 'timing';
praat_tiers.class{'distortion'} = 'timing';
praat_tiers.class{'error'} = 'timing';

praat_tiers.class{'unusable_trial'} = 'logical'; 
praat_tiers.class{'difficult_to_score'} = 'logical'; 


%% load trial table
% load table listing file start times of praat textgrid for each trial
paths = set_paths_daf(op); 
trials_audiofiles = readtable(paths.trials_audiofiles, 'FileType','text', 'Delimiter','tab'); 
trials_audiofiles.praat_file_start = trials_audiofiles.starts; 

%% compile textgrids 
direc_mic_audiofiles = [paths.trial_audio, filesep, 'ses-',op.ses,'_task-',op.task,'_recording-directionalmic_physio'];

cfg = [];
cfg.praat_tiers = praat_tiers; 
trials_beh = compile_praat_trial_annotation(trials_audiofiles, direc_mic_audiofiles, cfg);

%% save trial table with behavioral annotations
save(paths.trials_beh,'trials_beh', '-v7.3');

