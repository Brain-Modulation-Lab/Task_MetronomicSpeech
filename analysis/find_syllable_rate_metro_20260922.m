 %%% create runs table then run find_syllable_rate.m to get syllable production rate
 .... for comparison across metro- and non-metro conditions

 clear

%% create runs table

sub = {'metro-pilot001';'metro-pilot001'};
run = [8                ;  9]; 
metro_hz = [2           ; 3.5]; 

op.task = 'metro';
op.ses = 'intraop'; 

runs = table(sub,run,metro_hz); clear sub run metro_hz

src_audio_suffix = 'recording-phone2.wav'; 

 nruns = height(runs);
 for irun = 1:nruns
     op.sub = runs.sub{irun}; 
     op.run = runs.run(irun); 
     runs.paths{irun} = set_paths_metro(op);
     runs.paths{irun}.src_run_audiofile = [runs.paths{irun}.src_audio, filesep, runs.paths{irun}.filestr, src_audio_suffix]; 
 end

 %% run syllable finder

 % need to use this setting because we are running python within matlab, which can cause memory-related crashes
pyenv('Version', 'python', 'ExecutionMode', 'OutOfProcess'); 

runs_out = find_syllable_rate(runs, op)

%% compare metro vs nonmetro trials
% runrow = [1 2];  
runrows = 1:height(runs); 

% compvar = 'isi_coef_var'; ylab = {'Inter-syllable coefficient of variation','(higher = more variable)'}; 
% compvar = 'isi_coef_var_rob'; ylab = {'Inter-syllable coefficient of variation (robust)','(higher = more variable)'}; 
% compvar = 'npvi'; ylab = {'Normalized Pairwise Variability Index','(higher = less periodic)'}; 
% compvar = 'std'; ylab = {'Inter-syllable standard deviation','(higher = more variable)'}; %%%% nb: bad metric because it doesn't account for syl rate
compvar = 'mean_isi'; ylab = {'Inter-syllable mean (sec)'}

% close all
hfig = figure; box off
set(gcf, 'defaultTextInterpreter', 'none');

for irow = 1:length(runrows)
    thisrow = runrows(irow); 
    subplot(1,2,irow)
    hold on

    tbl = runs_out.trials{thisrow};

    % Run ANOVA without creating its own figure
    [anova_p, tbl_anova, anova_stats] = anova1(tbl{:,compvar}, tbl.metro_speech, 'off');

    % Draw the boxplot manually into the current axes
    boxplot(tbl{:,compvar}, tbl.metro_speech, 'Labels', ...
        {'Non-metro speech', 'Metro speech'});

    ylabel(ylab)
    title({[num2str(runs_out.metro_hz(thisrow)), ' Hz metronome rate'],...
        ['p = ',num2str(anova_p,3)]})
end