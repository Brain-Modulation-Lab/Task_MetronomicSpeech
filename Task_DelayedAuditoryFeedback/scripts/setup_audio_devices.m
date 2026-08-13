%%%% modify this function based on the task computer and audio devices you are using
% some computers have specifications for input devices; however we might not end up doing audio recording in the caller script

function cfg = setup_audio_devices(cfg)

aud = struct; 

computername = getenv('COMPUTERNAME'); % might not work on non-windows machines
    computername = deblank(computername); 
auddevs = audiodevinfo; 
    devs_in = {auddevs.input.Name};
    devs_out = {auddevs.output.Name};

    switch computername
        case 'BML-ALIENWARE2'
             cfg.aud_dev_out = 'Playback 3 + 4 (5- Focusrite USB Audio)'; 
             cfg.aud_player_fs     = 44100;      % Audio sample rate in Hz
        case {'677-GUE-WL-0010','677-GUE-WL-0012'}  % AM Thinkpad X1 laptops
            if any(contains(devs_out,'Focusrite'))
                cfg.aud_dev_out = 'Speakers (Focusrite USB Audio)'; 
            elseif any(contains(devs_out,'Headphones (WF-C500)') ) % if using bluetooth headphones
                cfg.aud_dev_out = 'Headphones (WF-C500)'; 
                    % cfg.aud_dev_out = 'Headset (WF-C500)'; 
            elseif  any(contains(devs_out,'Realtek HD Audio 2nd output (Realtek(R) Audio)')); 
                 cfg.aud_dev_out = 'Realtek HD Audio 2nd output (Realtek(R) Audio)'; % 3.5mm headphone jack 
            else % Thinkpad X1 without headphones
                cfg.aud_dev_out = 'Speakers (Realtek(R) Audio)'; 
                    % cfg.aud_dev_out = 'ARZOPA'; % portable screen speakers
            end
            cfg.aud_player_fs     = 44100;      % Audio sample rate in Hz
        case 'AMSMEIER' % AM strix laptop
            if any(contains(devs_out,'Speakers (Realtek(R) Audio) (Windows DirectSound)')) 
                cfg.aud_dev_out = 'Speakers (Realtek(R) Audio)'; 
            end
            cfg.aud_player_fs     = 44100;      % Audio sample rate in Hz
        
        otherwise 
            error('unknown computer')
    end
% % % end


