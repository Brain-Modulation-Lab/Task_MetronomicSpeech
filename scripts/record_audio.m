% Create a function for audio recording
function out = record_audio(filename, qConstant)
q = qConstant.Value;
out = 'test'; % Placeholder for recorded audio data

device = 'Focusrite USB ASIO';
driver = 'ASIO';
Fs = 44100; % sampling frequency
% set up device reader (for recording)
deviceReader = audioDeviceReader('SampleRate',Fs, ...
    'Device',device, ...
    'BitDepth','24-bit integer', ...
    'Driver',driver, ...
    'NumChannels', 6);

setup(deviceReader);


fileWriter = dsp.AudioFileWriter(filename, 'FileFormat','WAV');
disp('Speak into microphone now.')

while true
    % Wait for a message
    data = poll(q);
    acquiredAudio = deviceReader();
    fileWriter(acquiredAudio);

    if ischar(data) && strcmp(data, 'stop')
        % Stop recording when 'stop' message is received
        disp('Recording complete.')
        release(deviceReader);
        release(fileWriter);
        return
    end

end


end