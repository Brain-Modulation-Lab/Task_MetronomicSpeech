%% this version uses pyphen and linearly divides up the word into syllables - future approaches attempt to actually align to phonemes at the start of syllables

function runs_out = find_syllable_rate(runs, op)
% FIND_SYLLABLE_RATE Segment run audio into trials, generate Praat TextGrids, 
% and compute syllable/word timing metrics via G2P + Pyphen forced alignment.
%
% SPEECH REGULARITY METRICS (Computed per trial in trials table)
% =========================================================================
% 1. trials.isi_coef_var (Coefficient of Variation, CV_ISI):
%    - Formula: CV_ISI = std(ISI) / mean(ISI)
%    - Concept: Measures overall global dispersion of inter-syllable intervals 
%      normalized by average trial tempo. Prevents rate-scaling effects where 
%      slower speech naturally exhibits higher absolute millisecond variance.
%
% 2. trials.isi_coef_var_rob (Robust Coefficient of Variation, rCV_ISI):
%    - Formula: rCV_ISI = MAD_median(ISI) / median(ISI)
%      where MAD_median = median(|ISI - median(ISI)|)
%    - Concept: Replaces mean and standard deviation with median and median 
%      absolute deviation. Retains rate-normalized variability while remaining 
%      immune to distortion from single pauses, glottal hesitations, or 
%      boundary alignment artifacts.
%
% 3. trials.npvi (Normalized Pairwise Variability Index):
%    - Formula: nPVI = (100 / (N - 1)) * sum( | 2 * (ISI_k - ISI_{k+1}) / (ISI_k + ISI_{k+1}) | )
%    - Concept: Evaluates local step-to-step duration contrast between adjacent 
%      syllable pairs. Approaches zero as speech becomes strictly periodic and 
%      remains insensitive to slow, intentional tempo drift across a trial.
% =========================================================================
%
% Syntax:
%   runs_out = find_syllable_rate(runs, op)
%
% Inputs:
%   runs - MATLAB Table or Struct Array (1 row/element per run) containing a
%          'paths' field (cell array of structs or struct array).
%   op   - (Optional) Options struct:
%          .model           - Whisper model size ('tiny', 'base', 'small', 'medium', 'large')
%                             [Default: 'base']
%          .segment_max_dur - Maximum continuous silence gap threshold (seconds or ms).
%                             Used during alignment-leak recovery to trim boundary 
%                             overflow caused by laughter or experimental beeps.
%                             [Default: 0.200 (200 ms)]
%          .trial_dur_fixed - Fixed duration in seconds for each trial epoch, 
%                             starting at Go_Beep_Onset. [Default: 10.0]

    if nargin < 2, op = struct(); end
    if ~isfield(op, 'model'), op.model = 'base'; end
    
    % Fixed trial duration parameter (default = 10.0 s)
    if ~isfield(op, 'trial_dur_fixed') || isempty(op.trial_dur_fixed)
        op.trial_dur_fixed = 10.0;
    else
        op.trial_dur_fixed = double(op.trial_dur_fixed);
    end
    
    % Configure segment max silence gap duration. Default = 0.200 s (200 ms)
    if isfield(op, 'segment_max_dur')
        seg_dur_val = op.segment_max_dur;
    elseif isfield(op, 'vad_min_silence')
        seg_dur_val = op.vad_min_silence;
    else
        seg_dur_val = 0.200;
    end
    
    % Normalize to seconds
    if seg_dur_val >= 10
        max_gap_sec = double(seg_dur_val) / 1000.0;
    else
        max_gap_sec = double(seg_dur_val);
    end

    is_tbl = istable(runs);
    if is_tbl
        num_runs = height(runs);
    else
        num_runs = length(runs);
    end
    runs_out = runs;

    % Python Code String: VAD + WhisperX + Two-Tier RMS Refinement + G2P/Pyphen Syllabification
    py_code = join([ ...
        "import json, re, warnings", ...
        "warnings.filterwarnings('ignore')", ...
        "import numpy as np", ...
        "import nltk", ...
        "for res in ['averaged_perceptron_tagger_eng', 'averaged_perceptron_tagger', 'cmudict', 'punkt', 'punkt_tab']:", ...
        "    try:", ...
        "        nltk.download(res, quiet=True)", ...
        "    except Exception:", ...
        "        pass", ...
        "import whisperx", ...
        "from g2p_en import G2p", ...
        "import pyphen", ...
        "g2p = G2p()", ...
        "dic = pyphen.Pyphen(lang='en_US')", ...
        "device = 'cpu'", ...
        "compute_type = 'int8'", ...
        "model = whisperx.load_model(model_name, device, compute_type=compute_type)", ...
        "audio = whisperx.load_audio(audio_path)", ...
        "sr = 16000", ...
        "result = model.transcribe(audio, batch_size=4, language='en')", ...
        "model_a, metadata = whisperx.load_align_model(language_code='en', device=device)", ...
        "aligned_result = whisperx.align(result['segments'], model_a, metadata, audio, device, return_char_alignments=False)", ...
        "def refine_word_boundary(audio_arr, start_t, raw_end_t, n_phon=1, sr=16000, max_gap_sec=0.200):", ...
        "    raw_dur = raw_end_t - start_t", ...
        "    max_allowed_dur = max(1.2, n_phon * 0.75 + 0.4)", ...
        "    if raw_dur <= max_allowed_dur:", ...
        "        s_idx = int(max(0, start_t * sr))", ...
        "        e_idx = int(min(len(audio_arr), raw_end_t * sr))", ...
        "        if e_idx - s_idx < 320: return raw_end_t", ...
        "        segment = audio_arr[s_idx:e_idx]", ...
        "        frame_len = 160", ...
        "        n_frames = len(segment) // frame_len", ...
        "        if n_frames < 2: return raw_end_t", ...
        "        rms = [float(np.sqrt(np.mean(segment[i*frame_len:(i+1)*frame_len]**2))) for i in range(n_frames)]", ...
        "        max_rms = max(rms) if max(rms) > 0 else 1e-5", ...
        "        thresh = max(0.005, 0.08 * max_rms)", ...
        "        last_active = n_frames - 1", ...
        "        for idx in range(n_frames - 1, -1, -1):", ...
        "            if rms[idx] >= thresh:", ...
        "                last_active = idx", ...
        "                break", ...
        "        trimmed_end = start_t + ((last_active + 1) * frame_len) / float(sr)", ...
        "        return max(start_t + 0.08, trimmed_end)", ...
        "    capped_end_t = start_t + max_allowed_dur", ...
        "    s_idx = int(max(0, start_t * sr))", ...
        "    e_idx = int(min(len(audio_arr), capped_end_t * sr))", ...
        "    if e_idx - s_idx < 320: return capped_end_t", ...
        "    segment = audio_arr[s_idx:e_idx]", ...
        "    frame_len = 160", ...
        "    n_frames = len(segment) // frame_len", ...
        "    if n_frames < 2: return capped_end_t", ...
        "    rms = [float(np.sqrt(np.mean(segment[i*frame_len:(i+1)*frame_len]**2))) for i in range(n_frames)]", ...
        "    max_rms = max(rms) if max(rms) > 0 else 1e-5", ...
        "    thresh = max(0.005, 0.08 * max_rms)", ...
        "    max_silent_frames = max(1, int(max_gap_sec / 0.010))", ...
        "    last_active = 0", ...
        "    silent_count = 0", ...
        "    has_speech_started = False", ...
        "    for idx in range(n_frames):", ...
        "        if rms[idx] >= thresh:", ...
        "            last_active = idx", ...
        "            silent_count = 0", ...
        "            has_speech_started = True", ...
        "        else:", ...
        "            if has_speech_started:", ...
        "                silent_count += 1", ...
        "                if silent_count >= max_silent_frames:", ...
        "                    break", ...
        "    trimmed_end = start_t + ((last_active + 1) * frame_len) / float(sr)", ...
        "    return max(start_t + 0.10, min(trimmed_end, capped_end_t))", ...
        "def split_word_to_syllables(word, w_start, w_end):", ...
        "    clean_word = re.sub(r'[^a-zA-Z]', '', word)", ...
        "    if not clean_word:", ...
        "        return [{'word': word, 'start': round(float(w_start), 3), 'end': round(float(w_end), 3)}]", ...
        "    phonemes = g2p(clean_word)", ...
        "    vowel_phonemes = [p for p in phonemes if any(c.isdigit() for c in p)]", ...
        "    n_phon = len(vowel_phonemes)", ...
        "    if n_phon <= 1:", ...
        "        return [{'word': word, 'start': round(float(w_start), 3), 'end': round(float(w_end), 3)}]", ...
        "    pyphen_chunks = [c for c in dic.inserted(clean_word).split('-') if c]", ...
        "    if len(pyphen_chunks) == n_phon:", ...
        "        syl_texts = pyphen_chunks", ...
        "    else:", ...
        "        vowel_idxs = [i for i, ch in enumerate(clean_word.lower()) if ch in 'aeiouy']", ...
        "        if len(vowel_idxs) < n_phon:", ...
        "            chunk_len = max(1, len(clean_word) // n_phon)", ...
        "            bounds = [(i * chunk_len, (i + 1) * chunk_len if i < n_phon - 1 else len(clean_word)) for i in range(n_phon)]", ...
        "        else:", ...
        "            step = (len(vowel_idxs) - 1) / max(1, n_phon - 1)", ...
        "            anchors = [vowel_idxs[int(round(i * step))] for i in range(n_phon)]", ...
        "            cuts = [0]", ...
        "            for k in range(len(anchors) - 1):", ...
        "                mid = (anchors[k] + anchors[k+1]) // 2 + 1", ...
        "                cuts.append(mid)", ...
        "            cuts.append(len(clean_word))", ...
        "            for i in range(1, len(cuts)):", ...
        "                if cuts[i] <= cuts[i-1]:", ...
        "                    cuts[i] = min(len(clean_word), cuts[i-1] + 1)", ...
        "            bounds = [(cuts[i], cuts[i+1]) for i in range(n_phon)]", ...
        "        syl_texts = [clean_word[c_start:c_end] for c_start, c_end in bounds]", ...
        "    dur = float(w_end) - float(w_start)", ...
        "    total_chars = sum(len(s) for s in syl_texts)", ...
        "    syls = []", ...
        "    cur_t = float(w_start)", ...
        "    for idx, syl_str in enumerate(syl_texts):", ...
        "        syl_dur = dur * (len(syl_str) / float(total_chars))", ...
        "        t_start = round(cur_t, 3)", ...
        "        t_end = round(cur_t + syl_dur, 3) if idx < len(syl_texts) - 1 else round(float(w_end), 3)", ...
        "        cur_t = t_end", ...
        "        syls.append({'word': syl_str, 'start': t_start, 'end': t_end})", ...
        "    return syls", ...
        "timestamps = []", ...
        "for segment in aligned_result.get('segments', []):", ...
        "    for word_info in segment.get('words', []):", ...
        "        if 'start' not in word_info or 'end' not in word_info: continue", ...
        "        raw_word = word_info['word'].strip()", ...
        "        if not raw_word: continue", ...
        "        w_start = float(word_info['start'])", ...
        "        raw_w_end = float(word_info['end'])", ...
        "        clean_w = re.sub(r'[^a-zA-Z]', '', raw_word)", ...
        "        phons = g2p(clean_w) if clean_w else []", ...
        "        n_p = max(1, len([p for p in phons if any(c.isdigit() for c in p)]))", ...
        "        refined_end = refine_word_boundary(audio, w_start, raw_w_end, n_phon=n_p, sr=sr, max_gap_sec=max_gap_sec)", ...
        "        syl_units = split_word_to_syllables(raw_word, w_start, refined_end)", ...
        "        timestamps.extend(syl_units)", ...
        "json_out = json.dumps(timestamps)" ...
    ], newline);

    syl_table_cell = cell(num_runs, 1);
    trials_cell    = cell(num_runs, 1);
    mean_isi_vec   = nan(num_runs, 1);
    std_isi_vec    = nan(num_runs, 1);

    for k = 1:num_runs
        % 1. Extract path struct from runs.paths{k}
        if is_tbl
            path_struct = runs.paths{k};
        else
            path_struct = runs(k).paths;
            if iscell(path_struct), path_struct = path_struct{1}; end
        end

        % Validate field presence, input file existence, and build missing output directories
        validate_and_prepare_paths(path_struct, k);

        % 2. Read Source Audio File
        src_audio_path = char(path_struct.src_run_audiofile);
        [audio_sig, fs] = audioread(src_audio_path);
        run_duration = length(audio_sig) / fs;

        % 3. Load Trial Metadata Table, Events Table, and Sync Landmarks
        trials_tbl = load_generic_table(path_struct.src_trials);
        events_tbl = load_generic_table(path_struct.src_events);
        num_trials = height(trials_tbl);

        % 4. Compute Synchronization Clock Offset & Extract Go_Beep_Onset Audio Timestamps
        clock_offset   = compute_clock_offset(path_struct.landmarks_file, k, path_struct);
        go_beep_raw    = extract_go_beep_onsets(trials_tbl, events_tbl, num_trials, run_duration);

        trial_file_paths = cell(num_trials, 1);
        trial_onsets     = zeros(num_trials, 1);
        trial_offsets    = zeros(num_trials, 1);

        for t = 1:num_trials
            t_raw = go_beep_raw(t);
            
            % Convert from event-log clock domain to audio-recording clock domain
            if t_raw > run_duration
                t_start = t_raw - clock_offset;
            else
                t_start = t_raw; % Already in audio clock domain
            end
            t_end = t_start + op.trial_dur_fixed;

            % Boundary clamping
            t_start = max(0, t_start);
            t_end   = min(run_duration, t_end);

            start_idx = max(1, round(t_start * fs) + 1);
            end_idx   = min(length(audio_sig), round(t_end * fs));

            if end_idx >= start_idx
                trial_audio_sig = audio_sig(start_idx:end_idx, :);
            else
                trial_audio_sig = zeros(0, size(audio_sig, 2));
            end

            % Construct trial filename using path_struct.filestr
            trial_filename  = sprintf('%s_trial_%03d.wav', path_struct.filestr, t);
            full_trial_path = fullfile(path_struct.trial_audio_run, trial_filename);
            audiowrite(full_trial_path, trial_audio_sig, fs);

            trial_file_paths{t} = full_trial_path;
            trial_onsets(t)     = t_start;
            trial_offsets(t)    = t_end;
        end

        % 5. Create and Save trials_audiofiles Manifest Table
        trials_audio_table = table((1:num_trials)', trial_file_paths, trial_onsets, trial_offsets, ...
            'VariableNames', {'TrialNum', 'FilePath', 'OnsetSec', 'OffsetSec'});
        save_generic_table(trials_audio_table, path_struct.trials_audiofiles);

        % 6. Execute WhisperX ASR & G2P/Pyphen Phoneme-Aligned Syllabification
        try
            json_out = pyrun(py_code, "json_out", ...
                audio_path = src_audio_path, ...
                model_name = op.model, ...
                max_gap_sec = max_gap_sec);
            word_data = jsondecode(char(json_out));
        catch ME
            warning('Run %d (%s): Python WhisperX failed:\n%s', k, src_audio_path, ME.message);
            word_data = [];
        end

        if isempty(word_data)
            syl_table_cell{k}            = table();
            trials_tbl.mean_isi          = nan(num_trials, 1);
            trials_tbl.std_isi           = nan(num_trials, 1);
            trials_tbl.isi_coef_var      = nan(num_trials, 1);
            trials_tbl.isi_coef_var_rob  = nan(num_trials, 1);
            trials_tbl.npvi              = nan(num_trials, 1);
            trials_cell{k}               = trials_tbl;
            continue;
        end

        % 7. Format Token Data
        num_units = length(word_data);
        Syllable  = cell(num_units, 1);
        OnsetSec  = zeros(num_units, 1);
        OffsetSec = zeros(num_units, 1);

        for i = 1:num_units
            Syllable{i}  = word_data(i).word;
            OnsetSec(i)  = word_data(i).start;
            OffsetSec(i) = word_data(i).end;
        end

        isi = diff(OnsetSec);
        InterSyllableInterval_Sec = [isi; NaN];
        syl_table_cell{k} = table(Syllable, OnsetSec, OffsetSec, InterSyllableInterval_Sec);

        mean_isi_vec(k)   = mean(isi, 'omitnan');
        std_isi_vec(k)    = std(isi, 'omitnan');

        % 8. Compute Per-Trial Rhythm Metrics & Export Praat .TextGrid Files
        trial_mean_isi  = nan(num_trials, 1);
        trial_std_isi   = nan(num_trials, 1);
        trial_cv        = nan(num_trials, 1);
        trial_rcv       = nan(num_trials, 1);
        trial_npvi      = nan(num_trials, 1);

        [~, src_name]     = fileparts(src_audio_path);
        textgrid_run_path = fullfile(path_struct.trial_audio, [src_name '.TextGrid']);
        write_praat_textgrid(textgrid_run_path, Syllable, OnsetSec, OffsetSec, run_duration);

        for t = 1:num_trials
            t_start = trial_onsets(t);  % In audio clock domain (e.g., ~31.07 s)
            t_end   = trial_offsets(t); % In audio clock domain (e.g., ~41.07 s)

            mask = (OnsetSec >= t_start) & (OnsetSec < t_end);
            if any(mask)
                t_words   = Syllable(mask);
                t_onsets  = max(0, OnsetSec(mask) - t_start);
                t_offsets = min(t_end - t_start, OffsetSec(mask) - t_start);

                % Compute trial-level ISI metrics if trial has >= 2 syllables (>= 1 ISI)
                if sum(mask) >= 2
                    t_isi   = diff(OnsetSec(mask));
                    m_isi   = mean(t_isi, 'omitnan');
                    s_isi   = std(t_isi, 'omitnan');
                    med_isi = median(t_isi, 'omitnan');
                    mad_isi = median(abs(t_isi - med_isi), 'omitnan');

                    trial_mean_isi(t) = m_isi;
                    trial_std_isi(t)  = s_isi;

                    % 1. Coefficient of Variation (CV_ISI)
                    if m_isi > 0 && length(t_isi) >= 2
                        trial_cv(t) = s_isi / m_isi;
                    end

                    % 2. Robust Coefficient of Variation (rCV_ISI)
                    if med_isi > 0
                        trial_rcv(t) = mad_isi / med_isi;
                    end

                    % 3. Normalized Pairwise Variability Index (nPVI)
                    if length(t_isi) >= 2
                        diffs = abs(diff(t_isi));
                        sums  = (t_isi(1:end-1) + t_isi(2:end)) / 2.0;
                        valid_pairs = (sums > 0);
                        if any(valid_pairs)
                            trial_npvi(t) = 100 * mean(diffs(valid_pairs) ./ sums(valid_pairs), 'omitnan');
                        end
                    end
                end
            else
                t_words   = {};
                t_onsets  = [];
                t_offsets = [];
            end

            [t_dir, t_name] = fileparts(trial_file_paths{t});
            textgrid_trial_path = fullfile(t_dir, [t_name '.TextGrid']);
            write_praat_textgrid(textgrid_trial_path, t_words, t_onsets, t_offsets, t_end - t_start);
        end

        % 9. Update Trial Table with Trial-Level Rhythm Metrics
        trials_tbl.mean_isi         = trial_mean_isi;
        trials_tbl.std_isi          = trial_std_isi;
        trials_tbl.isi_coef_var     = trial_cv;
        trials_tbl.isi_coef_var_rob = trial_rcv;
        trials_tbl.npvi             = trial_npvi;
        trials_cell{k}              = trials_tbl;
    end

    % 10. Assign Final Run Outputs
    if is_tbl
        runs_out.syl_table = syl_table_cell;
        runs_out.mean_isi  = mean_isi_vec;
        runs_out.std_isi   = std_isi_vec;
        runs_out.trials    = trials_cell;
    else
        for k = 1:num_runs
            runs_out(k).syl_table = syl_table_cell{k};
            runs_out(k).mean_isi  = mean_isi_vec(k);
            runs_out(k).std_isi   = std_isi_vec(k);
            runs_out(k).trials    = trials_cell{k};
        end
    end
end

% =========================================================================
% HELPER FUNCTIONS
% =========================================================================

function clock_offset = compute_clock_offset(landmarks_filepath, k, path_struct)
% Compute difference between event-log timestamp and audio-recording timestamp:
%   clock_offset = t1_events - t1_audio
    clock_offset = 0;
    if isempty(landmarks_filepath) || ~exist(landmarks_filepath, 'file')
        return;
    end
    try
        lm_tbl = load_generic_table(landmarks_filepath);
        if isempty(lm_tbl) || ~istable(lm_tbl), return; end

        % Remove empty rows
        if ismember('run', lm_tbl.Properties.VariableNames)
            lm_tbl = lm_tbl(~isnan(lm_tbl.run), :);

            % Identify target run index
            target_run = k;
            if isfield(path_struct, 'filestr')
                r_tokens = regexp(char(path_struct.filestr), 'run-(\d+)', 'tokens');
                if ~isempty(r_tokens)
                    target_run = str2double(r_tokens{1}{1});
                end
            end

            run_mask = (lm_tbl.run == target_run);
            if any(run_mask)
                lm_tbl = lm_tbl(run_mask, :);
            end
        end

        if ismember('filetype', lm_tbl.Properties.VariableNames) && ismember('t1', lm_tbl.Properties.VariableNames)
            ft = string(lm_tbl.filetype);
            evt_mask = contains(ft, 'trials', 'IgnoreCase', true) | contains(ft, 'events', 'IgnoreCase', true);
            aud_mask = contains(ft, 'audio', 'IgnoreCase', true)  | contains(ft, 'wav', 'IgnoreCase', true);

            if any(evt_mask) && any(aud_mask)
                t1_evt = lm_tbl.t1(find(evt_mask, 1));
                t1_aud = lm_tbl.t1(find(aud_mask, 1));
                clock_offset = double(t1_evt - t1_aud);
            end
        end
    catch
        clock_offset = 0;
    end
end

function go_onsets = extract_go_beep_onsets(trials_tbl, events_tbl, num_trials, run_duration)
% Extract Go_Beep_Onset timestamps across trials and events tables
    go_onsets = nan(num_trials, 1);

    % 1. Check if trials_tbl directly contains Go_Beep_Onset column
    go_col = find_matching_col(trials_tbl, {'go_beep_onset', 'go_beep', 'go_beep_time', 'go_onset', 'beep_onset', 'go_beep_sec'});
    if ~isempty(go_col)
        vals = double(trials_tbl.(go_col));
        n_copy = min(num_trials, length(vals));
        go_onsets(1:n_copy) = vals(1:n_copy);
        if ~all(isnan(go_onsets)), return; end
    end

    % 2. Search inside events_tbl for 'Go_Beep_Onset'
    if ~isempty(events_tbl) && istable(events_tbl)
        type_col = find_matching_col(events_tbl, {'event_code', 'event_type', 'trial_type', 'event_name', 'name', 'event', 'value', 'type', 'label'});
        onset_col = find_matching_col(events_tbl, {'onset', 'start', 'start_time', 'onset_sec', 'timestamp', 'time'});

        if ~isempty(type_col) && ~isempty(onset_col)
            evt_names  = string(events_tbl.(type_col));
            evt_onsets = double(events_tbl.(onset_col));

            % Case-insensitive search for Go_Beep_Onset
            is_go_beep = contains(evt_names, 'go_beep', 'IgnoreCase', true);
            matched_onsets = evt_onsets(is_go_beep);

            % If events table specifies trial indices
            trial_col = find_matching_col(events_tbl, {'trial', 'trial_num', 'trial_number', 'trial_idx'});
            if ~isempty(trial_col)
                matched_trials = events_tbl.(trial_col)(is_go_beep);
                for t = 1:num_trials
                    idx = find(matched_trials == t, 1);
                    if ~isempty(idx)
                        go_onsets(t) = matched_onsets(idx);
                    end
                end
            else
                n_copy = min(num_trials, length(matched_onsets));
                go_onsets(1:n_copy) = matched_onsets(1:n_copy);
            end
            if ~all(isnan(go_onsets)), return; end
        end
    end

    % 3. Fallback: Standard onset column in trials_tbl
    onset_col = find_matching_col(trials_tbl, {'onset', 'start', 'start_time', 'onset_sec'});
    if ~isempty(onset_col)
        vals = double(trials_tbl.(onset_col));
        n_copy = min(num_trials, length(vals));
        go_onsets(1:n_copy) = vals(1:n_copy);
        if ~all(isnan(go_onsets)), return; end
    end

    % 4. Ultimate Fallback: Equal partitions across the run duration
    for t = 1:num_trials
        go_onsets(t) = (t - 1) * (run_duration / num_trials);
    end
end

function validate_and_prepare_paths(ps, k)
    req = {'landmarks_file', 'trials_audiofiles', 'trial_audio', ...
           'trial_audio_run', 'src_run_audiofile', 'src_trials', ...
           'src_events', 'filestr'};
    for f = 1:length(req)
        if ~isfield(ps, req{f})
            error('Run %d: Required field "%s" missing in runs.paths struct.', k, req{f});
        end
    end

    input_files = {'src_run_audiofile', 'src_trials', 'src_events', 'landmarks_file'};
    for f = 1:length(input_files)
        filepath = ps.(input_files{f});
        if ~exist(filepath, 'file')
            error('Run %d: Input file for "%s" not found at:\n  %s', k, input_files{f}, filepath);
        end
    end

    dirs_to_create = {ps.trial_audio, ps.trial_audio_run};
    [manifest_dir, ~, ~] = fileparts(ps.trials_audiofiles);
    if ~isempty(manifest_dir)
        dirs_to_create{end+1} = manifest_dir;
    end

    for d = 1:length(dirs_to_create)
        dir_path = dirs_to_create{d};
        if ~isempty(dir_path) && ~exist(dir_path, 'dir')
            mkdir(dir_path);
        end
    end
end

function tbl = load_generic_table(filepath)
    [~, ~, ext] = fileparts(filepath);
    switch lower(ext)
        case '.mat'
            d = load(filepath);
            f = fieldnames(d);
            tbl = d.(f{1});
            if ~istable(tbl), tbl = struct2table(tbl); end
        case {'.tsv', '.txt', '.csv'}
            tbl = readtable(filepath, 'FileType', 'text', 'Delimiter', '\t');
        case {'.xlsx', '.xls'}
            tbl = readtable(filepath);
        otherwise
            error('Unsupported file format: %s', ext);
    end
end

function save_generic_table(tbl, filepath)
    [~, ~, ext] = fileparts(filepath);
    switch lower(ext)
        case '.mat'
            save(filepath, 'tbl');
        case {'.tsv', '.txt'}
            writetable(tbl, 'FileType', 'text', 'Delimiter', '\t');
        case {'.xlsx', '.xls'}
            writetable(tbl, filepath);
        otherwise
            writetable(tbl, [filepath '.tsv'], 'FileType', 'text', 'Delimiter', '\t');
    end
end

function col_name = find_matching_col(tbl, targets)
    vars = lower(tbl.Properties.VariableNames);
    col_name = '';
    for i = 1:length(targets)
        idx = find(strcmp(vars, targets{i}), 1);
        if ~isempty(idx)
            col_name = tbl.Properties.VariableNames{idx};
            return;
        end
    end
end

function write_praat_textgrid(filepath, words, onsets, offsets, total_duration)
    fid = fopen(filepath, 'w', 'native', 'UTF-8');
    if fid == -1, return; end

    intervals = {};
    curr_t = 0;
    for i = 1:length(words)
        if onsets(i) > curr_t
            intervals{end+1} = struct('xmin', curr_t, 'xmax', onsets(i), 'text', '');
        end
        intervals{end+1} = struct('xmin', onsets(i), 'xmax', offsets(i), 'text', words{i});
        curr_t = offsets(i);
    end

    if curr_t < total_duration
        intervals{end+1} = struct('xmin', curr_t, 'xmax', total_duration, 'text', '');
    end

    num_int = length(intervals);

    fprintf(fid, 'File type = "ooTextFile"\n');
    fprintf(fid, 'Object class = "TextGrid"\n\n');
    fprintf(fid, 'xmin = 0\n');
    fprintf(fid, 'xmax = %.6f\n', total_duration);
    fprintf(fid, 'tiers? <exists>\n');
    fprintf(fid, 'size = 1\n');
    fprintf(fid, 'item []:\n');
    fprintf(fid, '    item [1]:\n');
    fprintf(fid, '        class = "IntervalTier"\n');
    fprintf(fid, '        name = "words"\n');
    fprintf(fid, '        xmin = 0\n');
    fprintf(fid, '        xmax = %.6f\n', total_duration);
    fprintf(fid, '        intervals: size = %d\n', num_int);

    for idx = 1:num_int
        fprintf(fid, '        intervals [%d]:\n', idx);
        fprintf(fid, '            xmin = %.6f\n', intervals{idx}.xmin);
        fprintf(fid, '            xmax = %.6f\n', intervals{idx}.xmax);
        fprintf(fid, '            text = "%s"\n', intervals{idx}.text);
    end

    fclose(fid);
end