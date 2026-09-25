function runs_out = find_syllable_rate(runs, op)
% FIND_SYLLABLE_RATE  Segment audio, transcribe/align via WhisperX, apply
%                     English phonotactic syllabification (Approach C), refine 
%                     consonant/vowel onsets, and launch run TextGrids in Praat.

    %% ── Options ─────────────────────────────────────────────────────────────
    if nargin < 2, op = struct(); end
    if ~isfield(op,'model'),           op.model           = 'base';   end
    if ~isfield(op,'trial_dur_fixed'), op.trial_dur_fixed = 10.0;     end
    op.trial_dur_fixed = double(op.trial_dur_fixed);

    %% ── Initialise ───────────────────────────────────────────────────────────
    is_tbl   = istable(runs);
    num_runs = is_tbl * height(runs) + ~is_tbl * numel(runs);
    runs_out = runs;

    %% ── Python code: WhisperX transcript + character alignments + G2P ────────
    py_code = join(string([ ...
        "import json, warnings, re, os", ...
        "warnings.filterwarnings('ignore')", ...
        "import whisperx", ...
        "device       = 'cpu'", ...
        "compute_type = 'int8'", ...
        "wh_model = whisperx.load_model(model_name, device, compute_type=compute_type)", ...
        "audio    = whisperx.load_audio(audio_path)", ...
        "result   = wh_model.transcribe(audio, batch_size=4, language='en')", ...
        "model_a, metadata = whisperx.load_align_model(language_code='en', device=device)", ...
        "aligned = whisperx.align(result['segments'], model_a, metadata, audio, device,", ...
        "                         return_char_alignments=True)", ...
        "words = []", ...
        "for seg in aligned.get('segments', []):", ...
        "    seg_chars = seg.get('chars', [])", ...
        "    for w in seg.get('words', []):", ...
        "        if 'word' not in w or 'start' not in w or 'end' not in w:", ...
        "            continue", ...
        "        wstr = re.sub(r" + char(34) + "[^a-zA-Z']" + char(34) + ", '', w['word']).strip().lower()", ...
        "        if wstr:", ...
        "            w_st = float(w['start'])", ...
        "            w_en = float(w['end'])", ...
        "            chars_list = []", ...
        "            if 'chars' in w and isinstance(w['chars'], list) and len(w['chars']) > 0:", ...
        "                chars_list = w['chars']", ...
        "            elif seg_chars:", ...
        "                for ch in seg_chars:", ...
        "                    if 'start' in ch and 'end' in ch:", ...
        "                        c_st = float(ch['start'])", ...
        "                        c_en = float(ch['end'])", ...
        "                        if c_st >= w_st - 0.08 and c_en <= w_en + 0.08:", ...
        "                            chars_list.append(ch)", ...
        "            formatted_chars = []", ...
        "            for ch in chars_list:", ...
        "                if 'char' in ch and 'start' in ch and 'end' in ch:", ...
        "                    formatted_chars.append({'char': ch['char'].lower(),", ...
        "                                           'start': round(float(ch['start']), 3),", ...
        "                                           'end':   round(float(ch['end']),   3)})", ...
        "            words.append({'word':   wstr,", ...
        "                          'onset':  round(w_st, 3),", ...
        "                          'offset': round(w_en, 3),", ...
        "                          'chars':  formatted_chars})", ...
        "pron_dict = {}", ...
        "oov_set   = set()", ...
        "u_words   = list(set(ww['word'] for ww in words))", ...
        "try:", ...
        "    import nltk", ...
        "    try:", ...
        "        from nltk.corpus import cmudict; cmu = cmudict.dict()", ...
        "    except LookupError:", ...
        "        nltk.download('cmudict', quiet=True)", ...
        "        from nltk.corpus import cmudict; cmu = cmudict.dict()", ...
        "    for word in u_words:", ...
        "        if word in cmu:", ...
        "            pron_dict[word] = cmu[word][0]", ...
        "        else:", ...
        "            oov_set.add(word)", ...
        "except Exception:", ...
        "    oov_set = set(u_words)", ...
        "if oov_set:", ...
        "    try:", ...
        "        from g2p_en import G2p; g2p = G2p()", ...
        "        for word in list(oov_set):", ...
        "            ph = g2p(word)", ...
        "            pron_dict[word] = [p for p in ph if p.strip() and p != ' ']", ...
        "    except ImportError:", ...
        "        pass", ...
        "ddir = os.path.dirname(dict_file_path)", ...
        "if ddir: os.makedirs(ddir, exist_ok=True)", ...
        "with open(dict_file_path, 'w', encoding='utf-8') as fh:", ...
        "    for wd, ph in pron_dict.items():", ...
        "        fh.write('{}\t{}\n'.format(wd, ' '.join(ph)))", ...
        "json_out = json.dumps({'words': words, 'oov_words': list(oov_set)})" ...
    ]), newline);

    %% ── Output accumulators ──────────────────────────────────────────────────
    syl_table_cell   = cell(num_runs, 1);
    phone_table_cell = cell(num_runs, 1);
    trials_cell      = cell(num_runs, 1);
    mean_isi_vec     = nan(num_runs, 1);
    std_isi_vec      = nan(num_runs, 1);

    %% ── Main run loop ────────────────────────────────────────────────────────
    for k = 1:num_runs

        % 1 ── Path struct ─────────────────────────────────────────────────────
        if is_tbl
            ps = runs.paths{k};
        else
            ps = runs(k).paths;
            if iscell(ps), ps = ps{1}; end
        end
        validate_and_prepare_paths(ps, k);

        % 2 ── Source audio ────────────────────────────────────────────────────
        src_path = char(ps.src_run_audiofile);
        [audio_sig, fs] = audioread(src_path);
        run_dur = size(audio_sig, 1) / fs;
        [~, src_name] = fileparts(src_path);

        % 3 ── Load tables ─────────────────────────────────────────────────────
        trials_tbl = load_generic_table(ps.src_trials);
        events_tbl = load_generic_table(ps.src_events);
        num_trials = height(trials_tbl);

        % 4 ── Clock offset + go-beep onsets ──────────────────────────────────
        clock_off = compute_clock_offset(ps.landmarks_file, k, ps);
        go_raw    = extract_go_beep_onsets(trials_tbl, events_tbl, num_trials, run_dur);

        % 5 ── Extract trial WAV files ─────────────────────────────────────────
        trial_paths   = cell(num_trials, 1);
        trial_onsets  = zeros(num_trials, 1);
        trial_offsets = zeros(num_trials, 1);

        for t = 1:num_trials
            t_raw = go_raw(t);
            t0    = t_raw;
            if t_raw > run_dur, t0 = t_raw - clock_off; end
            t0 = max(0, t0);
            t1 = min(run_dur, t0 + op.trial_dur_fixed);

            i0   = max(1, round(t0 * fs) + 1);
            i1   = min(size(audio_sig, 1), round(t1 * fs));
            tsig = audio_sig(i0:i1, :);
            if i1 < i0, tsig = zeros(0, size(audio_sig, 2)); end

            fname = sprintf('%s_trial_%03d.wav', ps.filestr, t);
            fpath = fullfile(ps.trial_audio_run, fname);
            audiowrite(fpath, tsig, fs);

            trial_paths{t}   = fpath;
            trial_onsets(t)  = t0;
            trial_offsets(t) = t1;
        end

        % 6 ── Trial manifest ──────────────────────────────────────────────────
        save_generic_table( ...
            table((1:num_trials)', trial_paths, trial_onsets, trial_offsets, ...
                  'VariableNames', {'TrialNum','FilePath','OnsetSec','OffsetSec'}), ...
            ps.trials_audiofiles);

        % 7 ── Work directories & dict path ────────────────────────────────────
        work_dir  = fullfile(ps.trial_audio, 'whisperx_work');
        dict_path = fullfile(work_dir, 'pronunciation.dict');
        if ~exist(work_dir, 'dir'), mkdir(work_dir); end

        % 8 ── WhisperX ASR + G2P ──────────────────────────────────────────────
        try
            json_str = pyrun(py_code, 'json_out', ...
                audio_path     = src_path,    ...
                model_name     = op.model,    ...
                dict_file_path = dict_path);
            asr = jsondecode(char(json_str));
        catch ME
            warning('find_syllable_rate: Run %d – WhisperX error: %s', k, ME.message);
            asr = struct('words', [], 'oov_words', {{}});
        end

        if isstruct(asr) && isfield(asr, 'words') && ~isempty(asr.words)
            words_data = asr.words;
        else
            words_data = [];
        end

        % 9 ── Load pronunciation dictionary ──────────────────────────────────
        pron_map = read_pron_dict(dict_path);

        % 10 ── Per-trial processing: Syllabify & Refine Onsets ────────────────
        trial_mean_isi = nan(num_trials, 1);
        trial_std_isi  = nan(num_trials, 1);
        trial_cv       = nan(num_trials, 1);
        trial_rcv      = nan(num_trials, 1);
        trial_npvi_out = nan(num_trials, 1);

        run_syl_lbl = {};  run_syl_on = [];  run_syl_off = [];  run_syl_tr = [];
        run_ph_lbl  = {};  run_ph_on  = [];  run_ph_off  = [];  run_ph_tr  = [];

        for t = 1:num_trials
            [td, tn] = fileparts(trial_paths{t});
            t_dur    = trial_offsets(t) - trial_onsets(t);
            tg_out   = fullfile(td, [tn '.TextGrid']);

            [tsig_trial, fs_trial] = audioread(trial_paths{t});
            tw = get_trial_words_struct(words_data, trial_onsets(t), trial_offsets(t));

            if isempty(tw)
                write_syllable_textgrid(tg_out, {}, [], [], {}, [], [], t_dur);
                continue;
            end

            % Syllabify & refine onsets
            [sl, so, sof, pl, po, pof] = extract_refined_syllables( ...
                tw, pron_map, tsig_trial, fs_trial, trial_onsets(t));

            write_syllable_textgrid(tg_out, sl, so, sof, pl, po, pof, t_dur);

            if numel(so) >= 2
                [trial_mean_isi(t), trial_std_isi(t), ...
                 trial_cv(t), trial_rcv(t), trial_npvi_out(t)] = ...
                    compute_rhythm_metrics(so);
            end

            % Accumulate run-level data
            t0   = trial_onsets(t);
            n_s  = numel(so);
            n_ph = numel(po);

            if n_s > 0
                run_syl_lbl = [run_syl_lbl; sl(:)];
                run_syl_on  = [run_syl_on;  so(:)  + t0];
                run_syl_off = [run_syl_off; sof(:) + t0];
                run_syl_tr  = [run_syl_tr;  repmat(t, n_s, 1)];
            end
            if n_ph > 0
                run_ph_lbl = [run_ph_lbl; pl(:)];
                run_ph_on  = [run_ph_on;  po(:)  + t0];
                run_ph_off = [run_ph_off; pof(:) + t0];
                run_ph_tr  = [run_ph_tr;  repmat(t, n_ph, 1)];
            end
        end % trial loop

        % 11 ── Compile run-level tables ───────────────────────────────────────
        if ~isempty(run_syl_lbl)
            syl_table_cell{k} = table(run_syl_lbl, run_syl_on, run_syl_off, run_syl_tr, ...
                'VariableNames', {'SylLabel','OnsetSec','OffsetSec','Trial'});
            all_ioi = diff(run_syl_on);
            mean_isi_vec(k) = mean(all_ioi, 'omitnan');
            std_isi_vec(k)  = std(all_ioi,  'omitnan');
        else
            syl_table_cell{k} = table();
        end

        if ~isempty(run_ph_lbl)
            phone_table_cell{k} = table(run_ph_lbl, run_ph_on, run_ph_off, run_ph_tr, ...
                'VariableNames', {'Phone','OnsetSec','OffsetSec','Trial'});
        else
            phone_table_cell{k} = table();
        end

        % 12 ── Save Run-level TextGrid & Open in Praat ─────────────────────────
        run_tg_path = fullfile(ps.trial_audio, [src_name '.TextGrid']);
        if ~isempty(run_syl_lbl)
            write_syllable_textgrid( ...
                run_tg_path, ...
                run_syl_lbl,  run_syl_on, run_syl_off, ...
                run_ph_lbl,   run_ph_on,  run_ph_off, ...
                run_dur);

            % Launch Praat using ps.praat if specified
            praat_exe = '';
            if isfield(ps, 'praat') && ~isempty(ps.praat)
                praat_exe = char(ps.praat);
            end
            open_in_praat(src_path, run_tg_path, praat_exe);
        end

        % 13 ── Update trial table ─────────────────────────────────────────────
        trials_tbl.mean_isi         = trial_mean_isi;
        trials_tbl.std_isi          = trial_std_isi;
        trials_tbl.isi_coef_var     = trial_cv;
        trials_tbl.isi_coef_var_rob = trial_rcv;
        trials_tbl.npvi             = trial_npvi_out;
        trials_cell{k}              = trials_tbl;

    end % run loop

    %% ── Assign outputs ───────────────────────────────────────────────────────
    if is_tbl
        runs_out.syl_table   = syl_table_cell;
        runs_out.phone_table = phone_table_cell;
        runs_out.mean_isi    = mean_isi_vec;
        runs_out.std_isi     = std_isi_vec;
        runs_out.trials      = trials_cell;
    else
        for k = 1:num_runs
            runs_out(k).syl_table   = syl_table_cell{k};
            runs_out(k).phone_table = phone_table_cell{k};
            runs_out(k).mean_isi    = mean_isi_vec(k);
            runs_out(k).std_isi     = std_isi_vec(k);
            runs_out(k).trials      = trials_cell{k};
        end
    end
end


% =========================================================================
% HELPER: Syllabify & Refine Onsets
% =========================================================================
function [syl_labels, syl_onsets, syl_offsets, phone_labels, phone_onsets, phone_offsets] = ...
        extract_refined_syllables(trial_words, pron_map, tsig, fs, t_onset_trial)

    syl_labels   = {}; syl_onsets   = []; syl_offsets   = [];
    phone_labels = {}; phone_onsets = []; phone_offsets = [];

    if isempty(trial_words), return; end

    if size(tsig, 2) > 1, mono_sig = mean(tsig, 2); else, mono_sig = tsig; end
    trial_env  = abs(hilbert(mono_sig));
    sorted_env = sort(trial_env);
    N_global   = sorted_env(max(1, round(0.10 * length(sorted_env))));

    prev_phone_off = 0;
    prev_syl_off   = 0;

    for w = 1:numel(trial_words)
        witem = trial_words(w);
        wstr  = lower(strtrim(witem.word));
        
        w_on  = witem.onset  - t_onset_trial;
        w_off = witem.offset - t_onset_trial;

        if isempty(wstr) || w_on < 0, continue; end

        % 1. Dict phonemes
        if isKey(pron_map, wstr)
            dict_ph = pron_map(wstr);
        else
            dict_ph = {upper(wstr)};
        end
        n_dict = numel(dict_ph);

        % 2. Extract phoneme timestamps aligned to WhisperX character timings
        has_chars = isfield(witem, 'chars') && ~isempty(witem.chars);
        if has_chars
            [u_onsets, u_offsets] = align_phonemes_to_chars(dict_ph, witem.chars, w_on, w_off, t_onset_trial);
        else
            % Weighted heuristic (Vowels get 2x weight over consonants)
            u_onsets  = zeros(n_dict, 1);
            u_offsets = zeros(n_dict, 1);
            weights   = ones(n_dict, 1);
            for p = 1:n_dict
                p_clean = upper(regexprep(dict_ph{p}, '\d', ''));
                if ismember(p_clean, {'AA','AE','AH','AO','AW','AY','EH','ER','EY','IH','IY','OW','OY','UH','UW'})
                    weights(p) = 2.0;
                end
            end
            w_norm = weights / sum(weights);
            dur = w_off - w_on;
            curr = w_on;
            for p = 1:n_dict
                u_onsets(p)  = curr;
                u_offsets(p) = curr + dur * w_norm(p);
                curr = u_offsets(p);
            end
        end

        % 3. Syllabification (Approach C)
        syl_bounds = syllabify_phoneme_sequence(dict_ph);
        n_syls     = numel(syl_bounds);

        % 4. Process Phones Tier
        word_ph_onsets  = zeros(n_dict, 1);
        word_ph_offsets = zeros(n_dict, 1);

        for p = 1:n_dict
            coarse_on  = u_onsets(p);
            coarse_off = u_offsets(p);
            ph_curr    = dict_ph{p};

            [ref_on, ref_off] = refine_onset_phoneme_aware( ...
                tsig, fs, coarse_on, coarse_off, prev_phone_off, N_global, ph_curr);

            phone_labels{end+1}  = ph_curr;
            phone_onsets(end+1)  = ref_on;
            phone_offsets(end+1) = ref_off;

            word_ph_onsets(p)  = ref_on;
            word_ph_offsets(p) = ref_off;
            prev_phone_off     = ref_off;
        end

        % 5. Process Syllables Tier
        for s = 1:n_syls
            idx_start = syl_bounds(s);
            if s < n_syls
                idx_end = syl_bounds(s+1) - 1;
            else
                idx_end = n_dict;
            end

            syl_label = strjoin(dict_ph(idx_start:idx_end), '.');

            s_on  = max(prev_syl_off, word_ph_onsets(idx_start));
            s_off = max(s_on + 0.020, word_ph_offsets(idx_end));

            syl_labels{end+1}  = syl_label;
            syl_onsets(end+1)  = s_on;
            syl_offsets(end+1) = s_off;
            prev_syl_off       = s_off;
        end
    end

    syl_labels   = syl_labels(:);
    syl_onsets   = syl_onsets(:);
    syl_offsets  = syl_offsets(:);
    phone_labels = phone_labels(:);
    phone_onsets = phone_onsets(:);
    phone_offsets = phone_offsets(:);
end


% =========================================================================
% HELPER: Sequence Alignment for Characters -> Phonemes
% =========================================================================
function [u_onsets, u_offsets] = align_phonemes_to_chars(dict_ph, chars_struct, w_on, w_off, t_onset_trial)
    n_dict  = numel(dict_ph);
    n_chars = numel(chars_struct);

    if n_dict == 0
        u_onsets = []; u_offsets = []; return;
    end

    if n_chars == 0
        u_onsets  = zeros(n_dict, 1);
        u_offsets = zeros(n_dict, 1);
        for p = 1:n_dict
            u_onsets(p)  = w_on + (p - 1) * (w_off - w_on) / n_dict;
            u_offsets(p) = w_on + p * (w_off - w_on) / n_dict;
        end
        return;
    end

    c_on  = zeros(n_chars, 1);
    c_off = zeros(n_chars, 1);
    c_str = cell(n_chars, 1);
    for c = 1:n_chars
        c_on(c)  = chars_struct(c).start - t_onset_trial;
        c_off(c) = chars_struct(c).end   - t_onset_trial;
        c_str{c} = chars_struct(c).char;
    end

    % Dynamic Programming Sequence Alignment
    D = -inf(n_dict, n_chars);
    P = zeros(n_dict, n_chars);

    for c = 1:n_chars
        D(1, c) = char_phone_score(c_str{c}, dict_ph{1});
    end

    for p = 2:n_dict
        for c = 1:n_chars
            s = char_phone_score(c_str{c}, dict_ph{p});
            [max_prev, best_c_prev] = max(D(p-1, 1:c));
            if ~isinf(max_prev)
                D(p, c) = s + max_prev;
                P(p, c) = best_c_prev;
            end
        end
    end

    [~, best_c_last] = max(D(n_dict, :));
    c_map = zeros(n_dict, 1);
    curr_c = best_c_last;
    if isempty(curr_c) || curr_c < 1, curr_c = n_chars; end

    for p = n_dict:-1:1
        c_map(p) = curr_c;
        if p > 1
            curr_c = P(p, curr_c);
            if curr_c == 0, curr_c = max(1, p - 1); end
        end
    end

    u_onsets  = zeros(n_dict, 1);
    u_offsets = zeros(n_dict, 1);

    for p = 1:n_dict
        c_start = c_map(p);
        if p < n_dict && c_map(p+1) > c_map(p)
            c_end = c_map(p+1) - 1;
        elseif p == n_dict
            c_end = n_chars;
        else
            c_end = c_start;
        end

        if p == 1
            u_onsets(p) = c_on(c_start);
        else
            u_onsets(p) = u_offsets(p-1);
        end
        
        if p == n_dict
            u_offsets(p) = max(c_off(c_end), w_off);
        else
            u_offsets(p) = max(u_onsets(p) + 0.020, c_off(c_end));
        end
    end
end

function score = char_phone_score(ch, ph)
    ch = lower(ch);
    ph = upper(regexprep(ph, '\d', ''));
    
    is_vowel_ph = ismember(ph, {'AA','AE','AH','AO','AW','AY','EH','ER','EY','IH','IY','OW','OY','UH','UW'});
    is_vowel_ch = ismember(ch, {'a','e','i','o','u','y','w'});
    
    if is_vowel_ph && is_vowel_ch
        score = 2.0;
    elseif ~is_vowel_ph && ~is_vowel_ch
        if (strcmp(ph,'D') && ch=='d') || (strcmp(ph,'T') && ch=='t') || ...
           (strcmp(ph,'B') && ch=='b') || (strcmp(ph,'P') && ch=='p') || ...
           (strcmp(ph,'G') && ch=='g') || (strcmp(ph,'K') && (ch=='k'||ch=='c'||ch=='q')) || ...
           (strcmp(ph,'M') && ch=='m') || (strcmp(ph,'N') && ch=='n') || ...
           (strcmp(ph,'L') && ch=='l') || (strcmp(ph,'R') && ch=='r') || ...
           (strcmp(ph,'S') && (ch=='s'||ch=='c')) || (strcmp(ph,'Z') && (ch=='z'||ch=='s')) || ...
           (strcmp(ph,'F') && (ch=='f'||ch=='v')) || (strcmp(ph,'HH') && ch=='h') || ...
           (strcmp(ph,'W') && ch=='w') || (strcmp(ph,'Y') && ch=='y') || ...
           (strcmp(ph,'NG') && (ch=='n'||ch=='g')) || ...
           (strcmp(ph,'CH') && (ch=='c'||ch=='h')) || ...
           (strcmp(ph,'SH') && (ch=='s'||ch=='h')) || ...
           (strcmp(ph,'TH') && (ch=='t'||ch=='h')) || ...
           (strcmp(ph,'DH') && (ch=='t'||ch=='h')) || ...
           (strcmp(ph,'JH') && (ch=='j'||ch=='g'))
            score = 3.0;
        else
            score = 1.0;
        end
    else
        score = -1.0;
    end
end


% =========================================================================
% HELPER: Phoneme-Class-Aware Acoustic Onset Snapper
% =========================================================================
function [clean_onset, clean_offset] = refine_onset_phoneme_aware(audio_sig, fs, coarse_on, coarse_off, prev_off, N_global, ph_label)

    if size(audio_sig, 2) > 1, audio_sig = mean(audio_sig, 2); end
    if nargin < 5 || isempty(prev_off),  prev_off = 0; end
    if nargin < 6 || isempty(N_global), N_global = 1e-4; end
    if nargin < 7 || isempty(ph_label), ph_label = ''; end

    ph_clean     = upper(regexprep(ph_label, '\d', ''));
    is_plosive   = ismember(ph_clean, {'P','B','T','D','K','G','CH','JH'});
    is_fricative = ismember(ph_clean, {'HH','F','V','TH','DH','S','Z','SH','ZH'});

    % ── CASE 1: PLOSIVE / STOP (Direct WhisperX Alignment Pass-through) ──
    if is_plosive
        clean_onset  = max(prev_off, coarse_on);
        clean_offset = max(clean_onset + 0.020, coarse_off);
        return;
    end

    % ── CASE 2: FRICATIVE (High-Frequency Breath Edge) ──
    if is_fricative
        sig_hp = audio_sig - smoothdata(audio_sig, 'movmean', max(3, round(fs / 600)));
        env_hp = abs(hilbert(sig_hp));
        env_hp = smoothdata(env_hp, 'gaussian', max(3, round(fs * 0.006)));

        sorted_hp = sort(env_hp);
        N_hp = sorted_hp(max(1, round(0.10 * length(sorted_hp))));

        t_min = max(prev_off, coarse_on - 0.350);
        t_max = min(length(audio_sig)/fs, coarse_off);

        i_s = max(1, round(t_min * fs));
        i_e = min(length(audio_sig), round(t_max * fs));
        i_coarse = round(coarse_on * fs) - i_s + 1;

        if (i_e - i_s) > 16 && i_coarse >= 1 && i_coarse <= (i_e - i_s + 1)
            seg_env = env_hp(i_s:i_e);
            S_hp    = max(seg_env);
            T_hp    = N_hp + 0.12 * (S_hp - N_hp);

            idx = min(length(seg_env), max(1, i_coarse));
            while idx > 1 && seg_env(idx) >= T_hp
                idx = idx - 1;
            end
            snapped_on  = (i_s + idx - 1) / fs;
            clean_onset = max(prev_off, snapped_on);
        else
            clean_onset = max(prev_off, coarse_on);
        end
        clean_offset = max(clean_onset + 0.020, coarse_off);
        return;
    end

    % ── CASE 3: VOWELS / SONORANTS (Standard Broadband Snapper) ───────────
    t_min = max(prev_off, coarse_on - 0.250);
    t_max = min(length(audio_sig)/fs, coarse_off);

    i_s = max(1, round(t_min * fs));
    i_e = min(length(audio_sig), round(t_max * fs));
    i_coarse = round(coarse_on * fs) - i_s + 1;

    if (i_e - i_s) < 16 || i_coarse < 1 || i_coarse > (i_e - i_s + 1)
        clean_onset  = max(prev_off, coarse_on);
        clean_offset = max(clean_onset + 0.020, coarse_off);
        return;
    end

    seg = audio_sig(i_s:i_e);
    env = abs(hilbert(seg));
    env = smoothdata(env, 'gaussian', max(3, round(fs * 0.005)));

    S = max(env);
    if (S / max(N_global, 1e-6)) < 1.3
        clean_onset  = max(prev_off, coarse_on);
        clean_offset = max(clean_onset + 0.020, coarse_off);
        return;
    end

    T = N_global + 0.15 * (S - N_global);

    if env(i_coarse) >= T
        idx = i_coarse;
        while idx > 1 && env(idx) >= T
            idx = idx - 1;
        end
        snapped_idx = idx;
    else
        idx = i_coarse;
        while idx < length(env) && env(idx) < T
            idx = idx + 1;
        end
        snapped_idx = idx;
    end

    snapped_on   = (i_s + snapped_idx - 1) / fs;
    clean_onset  = max(prev_off, snapped_on);
    clean_offset = max(clean_onset + 0.020, coarse_off);
end


% =========================================================================
% HELPER: External Praat Launcher
% =========================================================================
function open_in_praat(audio_path, tg_path, praat_exe_path)
    if nargin < 3 || isempty(praat_exe_path)
        praat_exe_path = 'praat';
    end

    try
        cmd = sprintf('"%s" --open "%s" "%s" &', praat_exe_path, audio_path, tg_path);
        status = system(cmd);
        if status ~= 0 && ispc
            winopen(tg_path);
        end
    catch ME
        warning('find_syllable_rate: Failed to launch Praat automatically: %s', ME.message);
    end
end


% =========================================================================
% HELPER: Approach-C Syllabification (Sonority + Maximal Onset + Legal Onsets)
% =========================================================================
function syl_bounds = syllabify_phoneme_sequence(phoneme_seq)
    syl_bounds = [1];
    if isempty(phoneme_seq) || numel(phoneme_seq) == 1, return; end

    n = numel(phoneme_seq);
    clean = cell(n, 1);
    for i = 1:n
        clean{i} = upper(regexprep(phoneme_seq{i}, '\d', ''));
    end

    son_map   = get_arpabet_sonority();
    onset_set = get_legal_english_onsets();

    son = zeros(n, 1);
    for i = 1:n
        if son_map.isKey(clean{i})
            son(i) = son_map(clean{i});
        end
    end

    v_idx = find(son >= 8);
    if isempty(v_idx), return; end 

    for vi = 1:(numel(v_idx) - 1)
        v1 = v_idx(vi);
        v2 = v_idx(vi + 1);

        if v2 - v1 == 1
            syl_bounds(end+1) = v2;
            continue;
        end

        placed = false;
        for ons = (v1 + 1):(v2 - 1)
            onset_key = strjoin(clean(ons:(v2 - 1)), '-');
            if onset_set.isKey(onset_key)
                syl_bounds(end+1) = ons;
                placed = true;
                break;
            end
        end

        if ~placed
            syl_bounds(end+1) = v2;
        end
    end

    syl_bounds = unique(sort(syl_bounds));
end


% =========================================================================
% HELPER: Arpabet Sonority Map
% =========================================================================
function m = get_arpabet_sonority()
    m = containers.Map('KeyType', 'char', 'ValueType', 'double');
    for c = {'AA','AE','AH','AO','AW','AY','EH','ER','EY','IH','IY','OW','OY','UH','UW'}
        m(c{1}) = 8;
    end
    for c = {'W','Y'},                                     m(c{1}) = 6; end
    for c = {'L','R'},                                     m(c{1}) = 5; end
    for c = {'M','N','NG'},                                m(c{1}) = 4; end
    for c = {'F','V','TH','DH','S','Z','SH','ZH','HH'},   m(c{1}) = 3; end
    for c = {'CH','JH'},                                   m(c{1}) = 2; end
    for c = {'P','B','T','D','K','G'},                     m(c{1}) = 1; end
end


% =========================================================================
% HELPER: Legal English Onset Clusters
% =========================================================================
function s = get_legal_english_onsets()
    s = containers.Map('KeyType', 'char', 'ValueType', 'logical');
    legal = [ ...
        {'P','B','T','D','K','G'}, ...
        {'F','V','TH','DH','S','Z','SH','ZH','HH'}, ...
        {'CH','JH','M','N','L','R','W','Y'}, ...
        {'P-L','P-R','B-L','B-R','T-R','D-R'}, ...
        {'K-L','K-R','G-L','G-R'}, ...
        {'T-W','D-W','K-W','G-W'}, ...
        {'P-Y','B-Y','T-Y','D-Y','K-Y','G-Y','M-Y','N-Y'}, ...
        {'F-Y','V-Y','TH-Y','S-Y','Z-Y','L-Y'}, ...
        {'F-L','F-R','TH-R','SH-R'}, ...
        {'S-P','S-T','S-K','S-M','S-N','S-L','S-F','S-TH','S-W'}, ...
        {'S-P-L','S-P-R','S-T-R','S-K-L','S-K-R','S-K-W'} ...
    ];
    for i = 1:numel(legal)
        s(legal{i}) = true;
    end
end


% =========================================================================
% HELPER: Rhythm Metrics
% =========================================================================
function [m_isi, s_isi, cv, rcv, npvi_val] = compute_rhythm_metrics(syl_onsets)
    m_isi = NaN; s_isi = NaN; cv = NaN; rcv = NaN; npvi_val = NaN;
    if numel(syl_onsets) < 2, return; end

    ioi = diff(syl_onsets(:));
    ioi = ioi(~isnan(ioi) & ioi > 0);
    if isempty(ioi), return; end

    m_isi   = mean(ioi);
    s_isi   = std(ioi);
    med_ioi = median(ioi);
    mad_ioi = median(abs(ioi - med_ioi));

    if m_isi > 0 && numel(ioi) >= 2
        cv = s_isi / m_isi;
    end
    if med_ioi > 0
        rcv = mad_ioi / med_ioi;
    end
    if numel(ioi) >= 2
        d     = abs(diff(ioi));
        sums  = (ioi(1:end-1) + ioi(2:end)) / 2;
        valid = sums > 0;
        if any(valid)
            npvi_val = 100 * mean(d(valid) ./ sums(valid));
        end
    end
end


% =========================================================================
% HELPER: Write 2-tier Praat TextGrid
% =========================================================================
function write_syllable_textgrid(filepath, syl_labels, syl_on, syl_off, ph_labels, ph_on, ph_off, total_dur)
    fid = fopen(filepath, 'w', 'native', 'UTF-8');
    if fid == -1
        warning('write_syllable_textgrid: cannot open %s', filepath);
        return;
    end

    tiers = cell(2, 1);
    tiers{1}.name   = 'syllables';
    tiers{1}.labels = syl_labels;
    tiers{1}.on     = syl_on;
    tiers{1}.off    = syl_off;
    tiers{2}.name   = 'phones';
    tiers{2}.labels = ph_labels;
    tiers{2}.on     = ph_on;
    tiers{2}.off    = ph_off;

    fprintf(fid, 'File type = "ooTextFile"\n');
    fprintf(fid, 'Object class = "TextGrid"\n\n');
    fprintf(fid, 'xmin = 0\nxmax = %.6f\n', total_dur);
    fprintf(fid, 'tiers? <exists>\nsize = %d\nitem []:\n', numel(tiers));

    for ti = 1:numel(tiers)
        t  = tiers{ti};
        iv = build_intervals(t.labels, t.on, t.off, total_dur);

        fprintf(fid, '    item [%d]:\n',              ti);
        fprintf(fid, '        class = "IntervalTier"\n');
        fprintf(fid, '        name = "%s"\n',          t.name);
        fprintf(fid, '        xmin = 0\n');
        fprintf(fid, '        xmax = %.6f\n',          total_dur);
        fprintf(fid, '        intervals: size = %d\n', numel(iv));

        for ii = 1:numel(iv)
            fprintf(fid, '        intervals [%d]:\n',  ii);
            fprintf(fid, '            xmin = %.6f\n',   iv{ii}.xmin);
            fprintf(fid, '            xmax = %.6f\n',   iv{ii}.xmax);
            fprintf(fid, '            text = "%s"\n',   iv{ii}.text);
        end
    end
    fclose(fid);
end


% =========================================================================
% HELPER: Fill Interval Gaps (Praat Silence Rendering)
% =========================================================================
function iv = build_intervals(labels, onsets, offsets, total_dur)
    iv    = {};
    cur_t = 0;

    for i = 1:numel(labels)
        if onsets(i) > cur_t + 1e-6
            iv{end+1} = struct('xmin', cur_t, 'xmax', onsets(i), 'text', '');
        end
        safe = strrep(labels{i}, '"', "'");
        iv{end+1} = struct('xmin', onsets(i), 'xmax', offsets(i), 'text', safe);
        cur_t = offsets(i);
    end

    if cur_t < total_dur - 1e-6
        iv{end+1} = struct('xmin', cur_t, 'xmax', total_dur, 'text', '');
    end

    if isempty(iv)
        iv{1} = struct('xmin', 0, 'xmax', total_dur, 'text', '');
    end
end


% =========================================================================
% UTILITY HELPERS
% =========================================================================
function tw = get_trial_words_struct(words_data, t_start, t_end)
    tw = [];
    if isempty(words_data), return; end
    for i = 1:numel(words_data)
        if words_data(i).onset >= t_start && words_data(i).onset < t_end
            if isempty(tw)
                tw = words_data(i);
            else
                tw(end+1) = words_data(i);
            end
        end
    end
end

function pron_map = read_pron_dict(dict_path)
    pron_map = containers.Map('KeyType', 'char', 'ValueType', 'any');
    if ~exist(dict_path, 'file'), return; end
    fid = fopen(dict_path, 'r', 'native', 'UTF-8');
    if fid == -1, return; end
    while ~feof(fid)
        line = fgetl(fid);
        if ~ischar(line), break; end
        line = strtrim(line);
        if isempty(line), continue; end
        parts = strsplit(line, '\t');
        if numel(parts) < 2, continue; end
        word   = strtrim(parts{1});
        phones = strsplit(strtrim(parts{2}), ' ');
        phones = phones(~cellfun(@isempty, phones));
        if ~isempty(word) && ~isempty(phones)
            pron_map(word) = phones;
        end
    end
    fclose(fid);
end

function clock_offset = compute_clock_offset(landmarks_filepath, k, path_struct)
    clock_offset = 0;
    if isempty(landmarks_filepath) || ~exist(landmarks_filepath, 'file'), return; end
    try
        lm_tbl = load_generic_table(landmarks_filepath);
        if isempty(lm_tbl) || ~istable(lm_tbl), return; end
        if ismember('run', lm_tbl.Properties.VariableNames)
            lm_tbl = lm_tbl(~isnan(lm_tbl.run), :);
            target_run = k;
            if isfield(path_struct, 'filestr')
                r_tokens = regexp(char(path_struct.filestr), 'run-(\d+)', 'tokens');
                if ~isempty(r_tokens), target_run = str2double(r_tokens{1}{1}); end
            end
            run_mask = (lm_tbl.run == target_run);
            if any(run_mask), lm_tbl = lm_tbl(run_mask, :); end
        end
        if ismember('filetype', lm_tbl.Properties.VariableNames) && ismember('t1', lm_tbl.Properties.VariableNames)
            ft       = string(lm_tbl.filetype);
            evt_mask = contains(ft, 'trials', 'IgnoreCase', true) | contains(ft, 'events', 'IgnoreCase', true);
            aud_mask = contains(ft, 'audio',  'IgnoreCase', true) | contains(ft, 'wav',    'IgnoreCase', true);
            if any(evt_mask) && any(aud_mask)
                clock_offset = double( lm_tbl.t1(find(evt_mask,1)) - lm_tbl.t1(find(aud_mask,1)) );
            end
        end
    catch
        clock_offset = 0;
    end
end

function go_onsets = extract_go_beep_onsets(trials_tbl, events_tbl, num_trials, run_duration)
    go_onsets = nan(num_trials, 1);
    go_col = find_matching_col(trials_tbl, {'go_beep_onset','go_beep','go_beep_time','go_onset','beep_onset','go_beep_sec'});
    if ~isempty(go_col)
        vals  = double(trials_tbl.(go_col));
        n_copy = min(num_trials, numel(vals));
        go_onsets(1:n_copy) = vals(1:n_copy);
        if ~all(isnan(go_onsets)), return; end
    end
    if ~isempty(events_tbl) && istable(events_tbl)
        type_col  = find_matching_col(events_tbl, {'event_code','event_type','trial_type','event_name','name','event','value','type','label'});
        onset_col = find_matching_col(events_tbl, {'onset','start','start_time','onset_sec','timestamp','time'});
        if ~isempty(type_col) && ~isempty(onset_col)
            evt_names  = string(events_tbl.(type_col));
            evt_onsets = double(events_tbl.(onset_col));
            is_go      = contains(evt_names, 'go_beep', 'IgnoreCase', true);
            matched    = evt_onsets(is_go);
            trial_col  = find_matching_col(events_tbl, {'trial','trial_num','trial_number','trial_idx'});
            if ~isempty(trial_col)
                mt = events_tbl.(trial_col)(is_go);
                for t = 1:num_trials
                    idx = find(mt == t, 1);
                    if ~isempty(idx), go_onsets(t) = matched(idx); end
                end
            else
                n_copy = min(num_trials, numel(matched));
                go_onsets(1:n_copy) = matched(1:n_copy);
            end
            if ~all(isnan(go_onsets)), return; end
        end
    end
    onset_col = find_matching_col(trials_tbl, {'onset','start','start_time','onset_sec'});
    if ~isempty(onset_col)
        vals  = double(trials_tbl.(onset_col));
        n_copy = min(num_trials, numel(vals));
        go_onsets(1:n_copy) = vals(1:n_copy);
        if ~all(isnan(go_onsets)), return; end
    end
    for t = 1:num_trials
        go_onsets(t) = (t - 1) * (run_duration / num_trials);
    end
end

function validate_and_prepare_paths(ps, k)
    req = {'landmarks_file','trials_audiofiles','trial_audio', ...
           'trial_audio_run','src_run_audiofile','src_trials', ...
           'src_events','filestr'};
    for f = 1:numel(req)
        if ~isfield(ps, req{f})
            error('Run %d: Required field "%s" missing in runs.paths struct.', k, req{f});
        end
    end
    for fn = {'src_run_audiofile','src_trials','src_events','landmarks_file'}
        fp = ps.(fn{1});
        if ~exist(fp, 'file'), error('Run %d: Input file missing: %s', k, fp); end
    end
    dirs = {ps.trial_audio, ps.trial_audio_run};
    [mdir, ~, ~] = fileparts(ps.trials_audiofiles);
    if ~isempty(mdir), dirs{end+1} = mdir; end
    for d = dirs
        if ~isempty(d{1}) && ~exist(d{1}, 'dir'), mkdir(d{1}); end
    end
end

function tbl = load_generic_table(filepath)
    [~, ~, ext] = fileparts(filepath);
    switch lower(ext)
        case '.mat'
            d = load(filepath); f = fieldnames(d); tbl = d.(f{1});
            if ~istable(tbl), tbl = struct2table(tbl); end
        case {'.tsv','.txt','.csv'}
            tbl = readtable(filepath, 'FileType', 'text', 'Delimiter', '\t');
        case {'.xlsx','.xls'}
            tbl = readtable(filepath);
    end
end

function save_generic_table(tbl, filepath)
    [~, ~, ext] = fileparts(filepath);
    switch lower(ext)
        case '.mat'
            save(filepath, 'tbl');
        case {'.tsv','.txt'}
            writetable(tbl, filepath, 'FileType', 'text', 'Delimiter', '\t');
        otherwise
            writetable(tbl, [filepath '.tsv'], 'FileType', 'text', 'Delimiter', '\t');
    end
end

function col_name = find_matching_col(tbl, targets)
    vars     = lower(tbl.Properties.VariableNames);
    col_name = '';
    for i = 1:numel(targets)
        idx = find(strcmp(vars, targets{i}), 1);
        if ~isempty(idx)
            col_name = tbl.Properties.VariableNames{idx};
            return;
        end
    end
end