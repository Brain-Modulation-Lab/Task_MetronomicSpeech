% Create a function for audio recording
function out = record_audio(filename, qConstant)
q = qConstant.Value;
out = 'test'; % Placeholder for recorded audio data

cfg = setup_audio_devices(); 

% set up device reader (for recording)
deviceReader = audioDeviceReader('SampleRate',cfg.aud_player_fs, ...
    'Device',cfg.aud_dev_in, ...
    'BitDepth','24-bit integer', ...
    'Driver',cfg.driver, ...
    'NumChannels', cfg.n_chans_in);

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