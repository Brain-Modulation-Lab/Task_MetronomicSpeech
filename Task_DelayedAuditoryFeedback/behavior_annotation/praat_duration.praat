###Description of this script
##  This script allows for scoring of duration on trials for the DBS-SEQ experiment. The script will create 
##  and open a TextGrid accompanying each sound file in a directory. 
##  
##  This script does not contain accuracy or stop-response-type tiers, and is useful for when you are only scoring speech epoch. 

##  Tier 1: SpeechEpoch - indicate speech onset, vowel offset, and (if present) coda consonant offset
##	-if the offset is released, mark 4 timepoints: speech onset, voicing onset, voicing offset, and final-consonant offset
##	-if the offset is not released, mark 3 timepoints: speech onset, voicing onset, and voicing/syllable offset
##	...	
##	... click the 'SpeechEpoch' tier (it should turn yellow)
##	... select the onset or offset individually and press Enter
##  Tier 2: Comments - use this Tier to add comments about the trial, e.g. if background noise makes it hard to hear a possible utterance. 
##  Tier 3: UnusableTrial - fill this in with a 1 if something makes the trial unusable... 
##	...e.g. the experimenter and subject are talking to each other rather than subject doing the task
##  Tier 4: DifficultToScore -  fill this in with 1 if the StopResponse is ambiguous (e.g. you can almost hear a response initiation)... 
##	...note in Comments why it's difficult to score

##  To run this script, you will need to have all sound files (one per trial) in a single directory. 
##
##  Script currently works only for .wav files but code can be edited to instead flexibly accept any file extension, as specified in the "file_extension" variable
##  Edit the names or number of Tiers in the "sentence Tier(s)" line below, or in the GUI that opens when you run the script. 
##  To start at a file other than the first one listed in the directory, use the Starting_file_index field
#
###End of description



clearinfo

## GUI (Subject, file type, tiers)
form Select subject, file type, and tiers
    sentence subName 1044
    integer starting_file_index 1
    sentence file_name_or_initial_substring trial
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

## Enforced 4 tiers
expectedTiers$ = "SpeechEpoch Comments UnusableTrial DifficultToScore"
logFile$ = wd$ + "stopresponse-log.txt"

## Build file list
pattern$ = wd$ + file_name_or_initial_substring$ + "*." + file_extension$
strings = Create Strings as file list: "fileList", pattern$
select Strings fileList
numFiles = Get number of strings
if numFiles = 0
    exitScript: "No files found: " + pattern$
endif

## Preload file names for jump menu
for i to numFiles
    filename'i'$ = Get string... i
endfor

## Main Loop 
ifile = starting_file_index

while ifile >= 1 and ifile <= numFiles
    filename$ = Get string... ifile
    Read from file... 'wd$''filename$'
    soundname$ = selected$ ("Sound", 1)

    # Look for TextGrid or enforce 4-tier
    full$ = "'wd$''soundname$'.TextGrid"
    recreate = 0
    if fileReadable (full$)
        Read from file... 'full$'
        select TextGrid 'soundname$'
        nTiers = Get number of tiers
        if nTiers <> 4
            recreate = 1
        else
			# Define expected names
			name1$ = "SpeechEpoch"
			name2$ = "Comments"
			name3$ = "UnusableTrial"
			name4$ = "DifficultToScore"

			# Query current tier names as variables
			tier1$ = Get tier name... 1
			tier2$ = Get tier name... 2
			tier3$ = Get tier name... 3
			tier4$ = Get tier name... 4

			# Now, do the comparison:
			if tier1$ <> name1$ or tier2$ <> name2$ or tier3$ <> name3$ or tier4$ <> name4$
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

    # Open editor
    select Sound 'soundname$'
    plus TextGrid 'soundname$'
    View & Edit

    # Pause for scoring, with navigation
    beginPause: "Scoring file 'ifile' of 'numFiles': 'filename$'"
        comment: "Current file: 'filename$'"
        optionMenu: "Navigation", 1
            option: "Continue to next file"
            option: "Jump to specific file"
            option: "Skip ahead"
        optionMenu: "Select file", 1
            for i to numFiles
                option: filename'i'$
            endfor
        optionMenu: "Skip amount", 1
            option: "1"
            option: "10"
            option: "25"
    clicked = endPause: "Continue", "Quit", 1

    # Save TextGrid
    select TextGrid 'soundname$'
    Save as text file: wd$ + soundname$ + ".TextGrid"

    # Extract labels
    speechEpoch$      = Get label of interval... 1 1
    comments$         = Get label of interval... 2 1
    unusableTrial$    = Get label of interval... 3 1
    difficultToScore$ = Get label of interval... 4 1

    # Append log line
    fileappend 'logFile$' 'subName$' \t 'filename$' \t 'speechEpoch$' \t 'comments$' \t 'unusableTrial$' \t 'difficultToScore$' \n

    # Cleanup objects
    select TextGrid 'soundname$'
    plus Sound 'soundname$'
    Remove
    clearinfo
    select Strings fileList

    # Quit
    if clicked = 2
        select Strings fileList
        Remove
        exitScript: "Stopped by user."
    endif

    # Navigation logic
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

## Cleanup
select Strings fileList
Remove
printline All done! Scored 'numFiles' files. Log saved to 'logFile$'.