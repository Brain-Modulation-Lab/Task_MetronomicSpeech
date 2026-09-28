% Get a list of all files ending in .mp3 or .m4a in the current working directory, then make .wav conversions of them 

clc

audioFiles = [dir('*.mp3'); dir('*.m4a')];
for k = 1:length(audioFiles)
    fileName = audioFiles(k).name;
    [~, baseName, ~] = fileparts(fileName);
    wavName = [baseName, '.wav'];
    fprintf('Processing: "%s"...\n', fileName);
    try
        % Simply pass the filename. MATLAB natively sniffs the file bytes
        % to determine the format, ignoring the extension name mismatch.
        [audioData, sampleRate] = audioread(fileName);
        % Write out to a pristine WAV file
        audiowrite(wavName, audioData, sampleRate);
        fprintf('   Successfully saved to "%s" (%d Hz)\n', wavName, sampleRate);
    catch ME
        fprintf('   Failed to convert "%s". Error: %s\n', fileName, ME.message);
    end
end
disp('Conversion complete!');