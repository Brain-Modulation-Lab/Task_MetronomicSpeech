### Score delayed auditory feedback (DAF) disfluencies

clearinfo

## GUI (Subject, file type)
form Select subject, file type
    integer starting_file_index 1
    sentence file_name_or_initial_substring sub-
    sentence file_extension wav
endform

## Folder Selection
wd$ = chooseDirectory$: "Select the folder containing your sound files"
if wd$ = ""
    exitScript: "No folder selected."
endif
if right$(wd$, 1) <> "/"
    wd$ = wd$ + "/"
endif
outDir$ = wd$

## Normalize inputs
if starting_file_index < 1
    starting_file_index = 1
endif
if file_extension$ = ""
    file_extension$ = "wav"
endif

## Enforced tier names and log file path
expectedTiers$ = "sld_repetition sld_prolongation typical_disfluency disfluency_resolution slowing distortion error speech_epoch comments unusable_trial difficult_to_score"
logFile$ = wd$ + "daf_log.txt"

## Build file list
pattern$ = wd$ + file_name_or_initial_substring$ + "*." + file_extension$
strings = Create Strings as file list: "fileList", pattern$
select Strings fileList
numFiles = Get number of strings
if numFiles = 0
    exitScript: "No files found matching: " + pattern$
endif

## Extract trial numbers and store filenames
## Expects "trial-N" anywhere in the filename, where N ends at the next "."
for i to numFiles
    filename'i'$ = Get string... i
    name$ = filename'i'$
    trialPos = index(name$, "trial-")
    if trialPos = 0
        trialNum'i' = i
    else
        afterTrial$ = mid$(name$, trialPos + 6, length(name$))
        dotPos = index(afterTrial$, ".")
        if dotPos = 0
            trialNum'i' = i
        else
            trialNum'i' = number(left$(afterTrial$, dotPos - 1))
        endif
    endif
endfor

## Bubble sort indices by trial number
for i to numFiles
    sortIndex'i' = i
endfor

for i to numFiles - 1
    for j to numFiles - i
        a = sortIndex'j'
        jplus = j + 1
        b = sortIndex'jplus'
        if trialNum'a' > trialNum'b'
            sortIndex'j' = b
            sortIndex'jplus' = a
        endif
    endfor
endfor

## Build sorted filename array
for i to numFiles
    idx = sortIndex'i'
    sortedFilename'i'$ = filename'idx'$
endfor

## Main Loop
ifile = starting_file_index

while ifile >= 1 and ifile <= numFiles
    filename$ = sortedFilename'ifile'$
    Read from file... 'wd$''filename$'
    soundname$ = selected$ ("Sound", 1)

    ## Look for existing TextGrid or create a new one
    full$ = "'wd$''soundname$'.TextGrid"
    recreate = 0
    if fileReadable (full$)
        Read from file... 'full$'
        select TextGrid 'soundname$'
        nTiers = Get number of tiers
        if nTiers <> 11
            recreate = 1
        else
            ## Define expected tier names
            name1$  = "sld_repetition"
            name2$  = "sld_prolongation"
            name3$  = "typical_disfluency"
            name4$  = "disfluency_resolution"
            name5$  = "slowing"
            name6$  = "distortion"
            name7$  = "error"
            name8$  = "speech_epoch"
            name9$  = "comments"
            name10$ = "unusable_trial"
            name11$ = "difficult_to_score"

            ## Query current tier names
            tier1$  = Get tier name... 1
            tier2$  = Get tier name... 2
            tier3$  = Get tier name... 3
            tier4$  = Get tier name... 4
            tier5$  = Get tier name... 5
            tier6$  = Get tier name... 6
            tier7$  = Get tier name... 7
            tier8$  = Get tier name... 8
            tier9$  = Get tier name... 9
            tier10$ = Get tier name... 10
            tier11$ = Get tier name... 11

            ## Compare tier names; recreate if any mismatch
            if tier1$ <> name1$ or tier2$ <> name2$ or tier3$ <> name3$ or tier4$ <> name4$ or tier5$ <> name5$ or tier6$ <> name6$ or tier7$ <> name7$ or tier8$ <> name8$ or tier9$ <> name9$ or tier10$ <> name10$ or tier11$ <> name11$
                recreate = 1
            endif
        endif
        if recreate = 1
            Remove
            select Sound 'soundname$'
            To TextGrid... "'expectedTiers$'" ""
        endif
    else
        select Sound 'soundname$'
        To TextGrid... "'expectedTiers$'" ""
    endif

    ## Open editor
    select Sound 'soundname$'
    plus TextGrid 'soundname$'
    View & Edit

    ## Pause for scoring, with navigation options
    beginPause: "Scoring file 'ifile' of 'numFiles': 'filename$'"
        comment: "Current file: 'filename$'"
        optionMenu: "Navigation", 1
            option: "Continue to next file"
            option: "Jump to specific file"
            option: "Skip ahead"
        optionMenu: "Select file", 1
            for i to numFiles
                option: sortedFilename'i'$
            endfor
        optionMenu: "Skip amount", 1
            option: "1"
            option: "10"
            option: "25"
    clicked = endPause: "Continue", "Quit", 1

    ## Save TextGrid before extracting labels
    select TextGrid 'soundname$'
    Save as text file: wd$ + soundname$ + ".TextGrid"

    ## Extract labels from the first interval of each tier
    sld_repetition$        = Get label of interval... 1 1
    sld_prolongation$      = Get label of interval... 2 1
    typical_disfluency$    = Get label of interval... 3 1
    disfluency_resolution$ = Get label of interval... 4 1
    slowing$               = Get label of interval... 5 1
    distortion$            = Get label of interval... 6 1
    error$                 = Get label of interval... 7 1
    speech_epoch$          = Get label of interval... 8 1
    comments$              = Get label of interval... 9 1
    unusable_trial$        = Get label of interval... 10 1
    difficult_to_score$    = Get label of interval... 11 1

    ## Append scored values to log file (tab-delimited, one row per trial)
    fileappend 'logFile$' 'filename$' \t 'sld_repetition$' \t 'sld_prolongation$' \t 'typical_disfluency$' \t 'disfluency_resolution$' \t 'slowing$' \t 'distortion$' \t 'error$' \t 'speech_epoch$' \t 'comments$' \t 'unusable_trial$' \t 'difficult_to_score$' \n

    ## Cleanup objects
    select TextGrid 'soundname$'
    plus Sound 'soundname$'
    Remove
    clearinfo
    select Strings fileList

    ## Handle quit
    if clicked = 2
        select Strings fileList
        Remove
        exitScript: "Stopped by user."
    endif

    ## Navigation logic
    if navigation = 1
        ifile = ifile + 1
    elsif navigation = 2
        ifile = select_file
    elsif navigation = 3
        if skip_amount = 1
            skip = 1
        elsif skip_amount = 2
            skip = 10
        else
            skip = 25
        endif
        ifile = ifile + skip
    endif
endwhile

## Cleanup and final message
select Strings fileList
Remove
printline All done! Scored 'numFiles' files. Log saved to 'logFile$'.