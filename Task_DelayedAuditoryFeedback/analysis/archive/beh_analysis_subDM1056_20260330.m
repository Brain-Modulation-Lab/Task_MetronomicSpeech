% op.sub = 'DM1056'; 
% op.task = 'daf'; 
% op.run = 1; 
% op.ses = 'intraop';
% op.datavars = {'slds','slurring','slowing'};

op.sub = 'DM1056'; 
op.task = 'daf'; 
op.run = 1; 
op.ses = 'preop';
op.datavars = {'slds'};


%%

op.runstr = sprintf('%02d', op.run); 



filestr = ['sub-',op.sub, '_ses-',op.ses, '_task-',op.task, '_run-',op.runstr, '_'];

paths.data = 'Y:\DBS';
paths.der_sub = [paths.data, filesep, 'derivatives',filesep, 'sub-',op.sub]; 
paths.annot = [paths.der_sub, filesep, 'annot'];

% trialspath = [paths.annot, filesep, filestr,'trials-scoring - updated.tsv'];
trialspath = [paths.annot, filesep, filestr,'trials-scoring.tsv'];


trials = readtable(trialspath,'FileType','text','Delimiter','tab'); 

if strcmp(op.ses,'preop')
    trials.delay = trials.delay+120;
end
    

for ivar = 1:length(op.datavars)
    thisvar = op.datavars{ivar};
    trials{isnan(trials{:,thisvar}),thisvar} = 0; 
end

grp = grpstats(trials,'delay',{'mean','std','sem'},'DataVars',op.datavars)

close all
hfig = figure('Color','w'); 

for ivar = 1:length(op.datavars)
    subplot(1, length(op.datavars), ivar)
    thisvar = op.datavars{ivar};    
    hbar(ivar) = bar(grp{:,['mean_',thisvar]});
    hax(ivar) = gca; 
    hax(ivar).XTickLabels = grp.Properties.RowNames;
    hax(ivar).Color = [1 1 1];
    hax(ivar).XColor = 'k';
    hax(ivar).YColor = 'k';
    ylabel('mean per trial')
    subt = strrep(thisvar,'slds', 'stuttering');
    title(subt,'Color','k')
    hax(ivar).XLabel.String = 'delay (ms)'; 
    hold on
    errorbar(grp{:,['mean_',thisvar]},grp{:,['sem_',thisvar]},'LineStyle', 'none','LineWidth',2,'Color','k')
    box off
end

sgtitle([op.sub, '  ', op.task, '  ', op.ses],'Color','k')

