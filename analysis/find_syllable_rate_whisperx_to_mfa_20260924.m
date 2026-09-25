%% this version feeds the output of whisperx plus syllabification rules to MFA



function runs_out = find_syllable_rate(runs, op)
% FIND_SYLLABLE_RATE  Segment audio, force-align phonemes via MFA, syllabify
%                     using English phonotactics, and compute speech regularity metrics.
%
% ── Pipeline ─────────────────────────────────────────────────────────────
%  1. WhisperX  → word-level transcript + timing (whole-run audio)
%  2. CMU dict + g2p_en → Arpabet pronunciation dict written to file
%  3. MFA 'align'  → phone-level forced alignment for all trial WAVs at once
%  4. Syllabification (Approach C):
%       a. Sonority Sequencing Principle → locate vowel nuclei
%       b. Maximal Onset Principle → assign consonants to following syllable
%       c. English onset-legality constraint → prevent illegal onset clusters
%  5. Syllable timing  → onset of first phone, offset of last phone per syllable
%  6. TextGrid output  → 2-tier (syllables + phones) per trial and per run
%  7. Metrics  → CV_ISI, rCV_ISI, nPVI on inter-syllable-onset intervals
%
% ── Requirements ─────────────────────────────────────────────────────────
%  Python env (used by MATLAB pyrun):
%    pip install whisperx g2p_en
%    python -m nltk.downloader cmudict    (or auto-downloaded on first run)
%
%  Conda 'mfa' environment:
%    conda create -n mfa -c conda-forge montreal-forced-aligner
%    conda run -n mfa mfa model download acoustic english_us_arpa
%
% ── Metrics (per trial, stored in trials table) ──────────────────────────
%  isi_coef_var     CV   = std(IOI) / mean(IOI)
%  isi_coef_var_rob rCV  = MAD(IOI) / median(IOI)
%  npvi             nPVI = (100/(N-1))·Σ|2(IOI_k−IOI_{k+1})/(IOI_k+IOI_{k+1})|
%  where IOI = inter-syllable-onset intervals within a trial
%
% ── Options (op struct fields) ────────────────────────────────────────────
%  .model           Whisper model: 'tiny'|'base'|'small'|'medium'|'large'  [base]
%  .trial_dur_fixed Trial epoch duration in seconds                         [10.0]
%  .conda_path      Full path to conda.bat
%                   [C:\ProgramData\miniconda3\condabin\conda.bat]
%  .mfa_env         Conda env name containing MFA                          [mfa]
%  .mfa_model       MFA acoustic model name                   [english_us_arpa]
%
% NOTE: If MFA hangs on first run, it may be waiting for its database server.
%       Run 'conda run -n mfa mfa align --help' to check available flags,
%       and consider adding '--num_jobs 1' in mfa_align_corpus() below.

    %% ── Options ─────────────────────────────────────────────────────────────
    if nargin < 2, op = struct(); end
    if ~isfield(op,'model'),           op.model           = 'base';   end
    if ~isfield(op,'trial_dur_fixed'), op.trial_dur_fixed = 10.0;     end
    if ~isfield(op,'conda_path')
        op.conda_path = 'C:\ProgramData\miniconda3\condabin\conda.bat';
    end
    if ~isfield(op,'mfa_env'),   op.mfa_env   = 'mfa';             end
    if ~isfield(op,'mfa_model'), op.mfa_model = 'english_us_arpa'; end
    op.trial_dur_fixed = double(op.trial_dur_fixed);

    % All MFA system() calls are prefixed with this
    mfa_prefix = sprintf('"%s" run -n %s mfa', op.conda_path, op.mfa_env);

    %% ── Initialise ───────────────────────────────────────────────────────────
    is_tbl   = istable(runs);
    num_runs = is_tbl * height(runs) + ~is_tbl * numel(runs);
    runs_out = runs;

    %% ── Python code: WhisperX word-level alignment + G2P + dict file ─────────
    %
    % Returned via json_out:
    %   words     – [{word, onset, offset}, ...]  (absolute times in run audio)
    %   oov_words – words not found in CMU dict
    %
    % Side effect: writes MFA-format pronunciation dict to <dict_file_path>
    %   format: word<TAB>P1 P2 P3 ...
    %
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
        "                         return_char_alignments=False)", ...
        "words = []", ...
        "for seg in aligned.get('segments', []):", ...
        "    for w in seg.get('words', []):", ...
        "        if 'word' not in w or 'start' not in w or 'end' not in w:", ...
        "            continue", ...
        "        wstr = re.sub(r" + char(34) + "[^a-zA-Z']" + char(34) + ", '', w['word']).strip().lower()", ...
        "        if wstr:", ...
        "            words.append({'word': wstr,", ...
        "                          'onset':  round(float(w['start']), 3),", ...
        "                          'offset': round(float(w['end']),   3)})", ...
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

        % 7 ── MFA work directories ────────────────────────────────────────────
        mfa_work  = fullfile(ps.trial_audio, 'mfa_work');
        dict_path = fullfile(mfa_work, 'pronunciation.dict');
        mfa_out   = fullfile(mfa_work, 'mfa_output');
        for d = {mfa_work, mfa_out}
            if ~exist(d{1}, 'dir'), mkdir(d{1}); end
        end

        % 8 ── WhisperX word-level ASR + G2P ──────────────────────────────────
        try
            json_str = pyrun(py_code, 'json_out', ...
                audio_path     = src_path,    ...
                model_name     = op.model,    ...
                dict_file_path = dict_path);
            asr = jsondecode(char(json_str));
        catch ME
            warning('find_syllable_rate: Run %d – WhisperX/G2P error: %s', k, ME.message);
            asr = struct('words', [], 'oov_words', {{}});
        end

        if isstruct(asr) && isfield(asr, 'words') && isstruct(asr.words)
            words_data = asr.words;
        else
            words_data = struct('word', {}, 'onset', {}, 'offset', {});
        end

        if isfield(asr, 'oov_words') && ~isempty(asr.oov_words)
            warning(['find_syllable_rate: Run %d – %d OOV word(s) have no pronunciation. ' ...
                     'Install g2p_en for automatic G2P: pip install g2p_en'], ...
                k, numel(asr.oov_words));
        end

        % 9 ── Load pronunciation dictionary ──────────────────────────────────
        pron_map = read_pron_dict(dict_path);

        % 10 ── Write .lab transcript files for each trial ─────────────────────
        % Lab files go into trial_audio_run alongside the WAVs so MFA can find them.
        has_lab = false(num_trials, 1);
        for t = 1:num_trials
            tw = get_trial_words(words_data, trial_onsets(t), trial_offsets(t));
            if isempty(tw), continue; end
            [td, tn] = fileparts(trial_paths{t});
            lab_path = fullfile(td, [tn '.lab']);
            fid = fopen(lab_path, 'w', 'native', 'UTF-8');
            if fid == -1, continue; end
            fprintf(fid, '%s', strjoin(tw, ' '));
            fclose(fid);
            has_lab(t) = true;
        end

        % 11 ── MFA forced alignment (all trials at once) ──────────────────────
        % Aligns every WAV+LAB pair in trial_audio_run, outputs TextGrids to mfa_out.
        if any(has_lab) && exist(dict_path, 'file')
            mfa_align_corpus(ps.trial_audio_run, dict_path, op.mfa_model, ...
                mfa_out, mfa_prefix);
        end

        % 12 ── Per-trial: parse MFA output, syllabify, metrics, TextGrids ─────
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
            tg_mfa   = fullfile(mfa_out, [tn '.TextGrid']);

            if ~exist(tg_mfa, 'file')
                write_syllable_textgrid(tg_out, {}, [], [], {}, [], [], t_dur);
                continue;
            end

            [phone_tbl, word_tbl] = parse_mfa_textgrid(tg_mfa);

            if isempty(phone_tbl)
                write_syllable_textgrid(tg_out, {}, [], [], {}, [], [], t_dur);
                continue;
            end

            [sl, so, sof] = extract_syllable_timings(phone_tbl, word_tbl, pron_map);

            write_syllable_textgrid(tg_out, sl, so, sof, ...
                phone_tbl.Phone, phone_tbl.OnsetSec, phone_tbl.OffsetSec, t_dur);

            if numel(so) >= 2
                [trial_mean_isi(t), trial_std_isi(t), ...
                 trial_cv(t), trial_rcv(t), trial_npvi_out(t)] = ...
                    compute_rhythm_metrics(so);
            end

            % Accumulate run-level data (convert to absolute timestamps)
            t0   = trial_onsets(t);
            n_s  = numel(so);
            n_ph = height(phone_tbl);

            if n_s > 0
                run_syl_lbl = [run_syl_lbl; sl(:)];
                run_syl_on  = [run_syl_on;  so(:)  + t0];
                run_syl_off = [run_syl_off; sof(:) + t0];
                run_syl_tr  = [run_syl_tr;  repmat(t, n_s, 1)];
            end
            if n_ph > 0
                run_ph_lbl = [run_ph_lbl; phone_tbl.Phone(:)];
                run_ph_on  = [run_ph_on;  phone_tbl.OnsetSec(:)  + t0];
                run_ph_off = [run_ph_off; phone_tbl.OffsetSec(:) + t0];
                run_ph_tr  = [run_ph_tr;  repmat(t, n_ph, 1)];
            end
        end % trial loop

        % 13 ── Compile run-level tables ───────────────────────────────────────
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

        % 14 ── Run-level TextGrid ─────────────────────────────────────────────
        if ~isempty(run_syl_lbl)
            write_syllable_textgrid( ...
                fullfile(ps.trial_audio, [src_name '.TextGrid']), ...
                run_syl_lbl,  run_syl_on, run_syl_off, ...
                run_ph_lbl,   run_ph_on,  run_ph_off, ...
                run_dur);
        end

        % 15 ── Update trial table ─────────────────────────────────────────────
        trials_tbl.mean_isi         = trial_mean_isi;
        trials_tbl.std_isi          = trial_std_isi;
        trials_tbl.isi_coef_var     = trial_cv;
        trials_tbl.isi_coef_var_rob = trial_rcv;
        trials_tbl.npvi             = trial_npvi_out;
        trials_cell{k}              = trials_tbl;

        % 16 ── Clean up .lab files ────────────────────────────────────────────
        for t = 1:num_trials
            [td, tn] = fileparts(trial_paths{t});
            lab = fullfile(td, [tn '.lab']);
            if exist(lab, 'file'), delete(lab); end
        end

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
% HELPER: MFA corpus alignment
% =========================================================================
function mfa_align_corpus(corpus_dir, dict_path, mfa_model, output_dir, mfa_prefix)
% MFA_ALIGN_CORPUS  Run MFA forced alignment on a corpus directory.
%
% MFA 3.x syntax:
%   mfa align CORPUS_DIR DICT_PATH ACOUSTIC_MODEL OUTPUT_DIR [--clean]
%
% Processes every WAV+LAB pair in corpus_dir; writes TextGrids to output_dir.
% --clean removes temporary data from any previous run at this location.
% If MFA hangs, verify syntax with: conda run -n mfa mfa align --help

    cmd = sprintf('%s align "%s" "%s" %s "%s" --clean 2>&1', ...
        mfa_prefix, corpus_dir, dict_path, mfa_model, output_dir);
    [status, result] = system(cmd);
    if status ~= 0
        warning('find_syllable_rate: MFA align returned non-zero status.\n  CMD: %s\n  OUT: %s', ...
            cmd, strtrim(result));
    end
end


% =========================================================================
% HELPER: Parse MFA TextGrid output
% =========================================================================
function [phone_tbl, word_tbl] = parse_mfa_textgrid(tg_path)
% PARSE_MFA_TEXTGRID  Extract phone and word tiers from an MFA TextGrid file.
%
% MFA produces two IntervalTiers named "words" and "phones".
% Silence intervals (text = "", "sp", "sil", "spn") are excluded.
% Returns tables with columns: Phone|Word, OnsetSec, OffsetSec.

    phone_tbl = table();
    word_tbl  = table();

    fid = fopen(tg_path, 'r', 'native', 'UTF-8');
    if fid == -1
        warning('parse_mfa_textgrid: cannot open %s', tg_path);
        return;
    end
    raw = fread(fid, '*char')';
    fclose(fid);

    silence_set = {'', 'sp', 'sil', 'spn', '<eps>', '{sl}', '<sil>'};

    % Split by numbered tier blocks: "item [1]:  item [2]:  ..."
    % \d+ avoids matching the outer container "item []:"
    tier_blocks = regexp(raw, 'item\s*\[\d+\]\s*:', 'split');
    if numel(tier_blocks) < 2, return; end

    for ti = 2:numel(tier_blocks)
        blk = tier_blocks{ti};

        % Tier name
        name_tok = regexp(blk, 'name\s*=\s*"([^"]*)"', 'tokens', 'once');
        if isempty(name_tok), continue; end
        tier_name = lower(strtrim(name_tok{1}));

        % Split into individual interval blocks
        int_blocks = regexp(blk, 'intervals\s*\[\d+\]\s*:', 'split');
        if numel(int_blocks) < 2, continue; end

        Label     = {};
        OnsetSec  = [];
        OffsetSec = [];

        for ib = 2:numel(int_blocks)
            ib_txt   = int_blocks{ib};
            xmin_tok = regexp(ib_txt, 'xmin\s*=\s*([\d.eE+\-]+)', 'tokens', 'once');
            xmax_tok = regexp(ib_txt, 'xmax\s*=\s*([\d.eE+\-]+)', 'tokens', 'once');
            text_tok = regexp(ib_txt, 'text\s*=\s*"([^"]*)"',      'tokens', 'once');

            if isempty(xmin_tok) || isempty(xmax_tok) || isempty(text_tok), continue; end

            xmin = str2double(xmin_tok{1});
            xmax = str2double(xmax_tok{1});
            txt  = strtrim(text_tok{1});

            if xmin >= xmax,                           continue; end
            if ismember(lower(txt), silence_set),      continue; end

            Label{end+1}     = txt;
            OnsetSec(end+1)  = xmin;
            OffsetSec(end+1) = xmax;
        end

        if isempty(Label), continue; end

        Label     = Label(:);
        OnsetSec  = OnsetSec(:);
        OffsetSec = OffsetSec(:);
        tbl = table(Label, OnsetSec, OffsetSec);

        if contains(tier_name, 'phone')
            tbl.Properties.VariableNames{1} = 'Phone';
            phone_tbl = tbl;
        elseif contains(tier_name, 'word')
            tbl.Properties.VariableNames{1} = 'Word';
            word_tbl = tbl;
        end
    end
end


% =========================================================================
% HELPER: Read MFA pronunciation dictionary
% =========================================================================
function pron_map = read_pron_dict(dict_path)
% READ_PRON_DICT  Load an MFA-format pronunciation dictionary.
%
% File format:  word<TAB>P1 P2 P3 ...
% Returns: containers.Map  (word string → cell array of Arpabet phone strings)

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


% =========================================================================
% HELPER: Get word strings falling within a trial window
% =========================================================================
function tw = get_trial_words(words_data, t_start, t_end)
% GET_TRIAL_WORDS  Return word strings for words with onset in [t_start, t_end).

    tw = {};
    if isempty(words_data), return; end
    for i = 1:numel(words_data)
        if words_data(i).onset >= t_start && words_data(i).onset < t_end
            tw{end+1} = words_data(i).word;
        end
    end
end


% =========================================================================
% HELPER: Map syllable boundaries to MFA phone timings
% =========================================================================
function [syl_labels, syl_onsets, syl_offsets] = extract_syllable_timings( ...
        phone_tbl, word_tbl, pron_map)
% EXTRACT_SYLLABLE_TIMINGS  Produce syllable timing from MFA phone alignment.
%
% For each word in word_tbl:
%   1. Identify MFA phones within that word's time interval
%   2. Look up Arpabet pronunciation in pron_map
%   3. Syllabify using syllabify_phoneme_sequence (Approach C)
%   4. Map syllable phone-index boundaries to MFA phone onset/offset times
%
% Fallbacks:
%   - Word not in pron_map  → treat entire word as one syllable
%   - MFA phone count ≠ dict phone count → linearly scale phone indices

    syl_labels  = {};
    syl_onsets  = [];
    syl_offsets = [];

    if isempty(phone_tbl) || isempty(word_tbl), return; end

    tol = 1e-3;   % 1 ms boundary tolerance

    for w = 1:height(word_tbl)
        wstr  = lower(strtrim(word_tbl.Word{w}));
        w_on  = word_tbl.OnsetSec(w);
        w_off = word_tbl.OffsetSec(w);
        if isempty(wstr), continue; end

        % Find phones within this word's interval
        mask = (phone_tbl.OnsetSec  >= w_on  - tol) & ...
               (phone_tbl.OffsetSec <= w_off + tol);
        if ~any(mask), continue; end

        ph_lbl = phone_tbl.Phone(mask);
        ph_on  = phone_tbl.OnsetSec(mask);
        ph_off = phone_tbl.OffsetSec(mask);
        n_mfa  = sum(mask);

        % Pronunciation lookup
        if isKey(pron_map, wstr)
            dict_ph = pron_map(wstr);
            n_dict  = numel(dict_ph);
        else
            % No pronunciation: whole word = one syllable
            syl_labels{end+1}  = strjoin(ph_lbl, '.');
            syl_onsets(end+1)  = ph_on(1);
            syl_offsets(end+1) = ph_off(end);
            continue;
        end

        % Syllabify the dictionary phone sequence
        bounds = syllabify_phoneme_sequence(dict_ph);
        n_syls = numel(bounds);

        for s = 1:n_syls
            d_start = bounds(s);
            if s < n_syls
                d_end = bounds(s+1) - 1;
            else
                d_end = n_dict;
            end

            % Map dict phone indices to MFA phone indices
            if n_mfa == n_dict
                m_start = d_start;
                m_end   = d_end;
            else
                % Linear scaling when counts diverge
                scale   = (n_mfa - 1) / max(n_dict - 1, 1);
                m_start = max(1,     round((d_start - 1) * scale + 1));
                m_end   = min(n_mfa, round((d_end   - 1) * scale + 1));
            end
            m_start = max(1,      min(m_start, n_mfa));
            m_end   = max(m_start, min(m_end,   n_mfa));

            syl_labels{end+1}  = strjoin(dict_ph(d_start:d_end), '.');
            syl_onsets(end+1)  = ph_on(m_start);
            syl_offsets(end+1) = ph_off(m_end);
        end
    end

    syl_labels  = syl_labels(:);
    syl_onsets  = syl_onsets(:);
    syl_offsets = syl_offsets(:);
end


% =========================================================================
% HELPER: Approach-C syllabification
% =========================================================================
function syl_bounds = syllabify_phoneme_sequence(phoneme_seq)
% SYLLABIFY_PHONEME_SEQUENCE  Syllabify an Arpabet phoneme sequence.
%
% Algorithm (Approach C):
%   1. Strip stress digits; look up sonority for each phoneme.
%   2. Find vowel positions (sonority ≥ 8) as syllable nuclei.
%   3. For consonants between adjacent vowels, apply Maximal Onset Principle:
%        try the largest possible onset cluster first, then shrink.
%   4. Accept the first (largest) cluster that is a legal English onset.
%      If none found, assign all consonants to the coda (empty onset).
%
% Input:  cell array of Arpabet phones, stress digits optional
%         e.g.  {'N','AE1','P','K','IH0','N'}
% Output: 1-indexed syllable-start positions (always includes 1)
%
% Examples:
%   {'N','AE1','P','K','IH0','N'}  →  [1, 4]   nap-kin
%   {'AH0','P','N','IH1','D'}      →  [1, 3]   op-nid  (PN is illegal onset)
%   {'S','P','R','IH1','NG'}       →  [1]       spring  (SPR is legal)

    syl_bounds = [1];
    if isempty(phoneme_seq) || numel(phoneme_seq) == 1, return; end

    n = numel(phoneme_seq);

    % Strip stress digits, uppercase for lookup
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
    if isempty(v_idx), return; end   % no vowels → single syllable

    % For each pair of adjacent vowels, find the syllable break
    for vi = 1:(numel(v_idx) - 1)
        v1 = v_idx(vi);
        v2 = v_idx(vi + 1);

        if v2 - v1 == 1
            % Adjacent vowels → new syllable at v2
            syl_bounds(end+1) = v2;
            continue;
        end

        % Try onset clusters from maximal (v1+1..v2-1) down to minimal (v2-1)
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
            % No legal onset found: all consonants go to coda, next syllable
            % starts at v2 (zero-onset)
            syl_bounds(end+1) = v2;
        end
    end

    syl_bounds = unique(sort(syl_bounds));
end


% =========================================================================
% HELPER: Arpabet sonority values
% =========================================================================
function m = get_arpabet_sonority()
% Sonority scale (after stripping stress digits):
%   Vowels (8) > Glides (6) > Liquids (5) > Nasals (4) >
%   Fricatives (3) > Affricates (2) > Stops (1)

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
% HELPER: Legal English onset clusters
% =========================================================================
function s = get_legal_english_onsets()
% GET_LEGAL_ENGLISH_ONSETS  Return a containers.Map of legal English syllable
% onsets at the Arpabet level (stress digits stripped, phonemes joined by '-').
%
% Covers: all single consonants, standard 2-phoneme clusters,
%         standard 3-phoneme clusters.
% Intentionally absent: PN, BN, TN, etc. (illegal English onsets).

    s = containers.Map('KeyType', 'char', 'ValueType', 'logical');

    legal = [ ...
        {'P','B','T','D','K','G'}, ...  % Single consonants: stops
        {'F','V','TH','DH','S','Z','SH','ZH','HH'}, ...  % Single consonants: fricatives
        {'CH','JH','M','N','L','R','W','Y'}, ...  % Single consonants: affricates, nasals, liquids, glides
        {'P-L','P-R','B-L','B-R','T-R','D-R'}, ...  % Stop + Liquid
        {'K-L','K-R','G-L','G-R'}, ...  % Stop + Liquid (continued)
        {'T-W','D-W','K-W','G-W'}, ...  % Stop + Glide (w)
        {'P-Y','B-Y','T-Y','D-Y','K-Y','G-Y','M-Y','N-Y'}, ...  % Consonant + Glide (y)
        {'F-Y','V-Y','TH-Y','S-Y','Z-Y','L-Y'}, ...  % Consonant + Glide (y, continued)
        {'F-L','F-R','TH-R','SH-R'}, ...  % Fricative + Liquid
        {'S-P','S-T','S-K','S-M','S-N','S-L','S-F','S-TH','S-W'}, ...  % S + consonant (2-phoneme)
        {'S-P-L','S-P-R','S-T-R','S-K-L','S-K-R','S-K-W'} ...  % S + Stop + Liquid/Glide (3-phoneme)
    ];

    for i = 1:numel(legal)
        s(legal{i}) = true;
    end
end


% =========================================================================
% HELPER: Inter-syllable rhythm metrics
% =========================================================================
function [m_isi, s_isi, cv, rcv, npvi_val] = compute_rhythm_metrics(syl_onsets)
% COMPUTE_RHYTHM_METRICS  Compute regularity metrics on inter-syllable-onset
% intervals (IOIs).
%
%   CV   = std(IOI) / mean(IOI)
%   rCV  = MAD(IOI) / median(IOI)        MAD = median absolute deviation
%   nPVI = (100/(N-1)) · Σ |2(IOI_k − IOI_{k+1}) / (IOI_k + IOI_{k+1})|

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
% HELPER: Write 2-tier Praat TextGrid (syllables + phones)
% =========================================================================
function write_syllable_textgrid(filepath, ...
        syl_labels, syl_on, syl_off, ...
        ph_labels,  ph_on,  ph_off, ...
        total_dur)
% WRITE_SYLLABLE_TEXTGRID  Write a Praat TextGrid with two IntervalTiers:
%   Tier 1 "syllables" – syllable intervals labelled with dot-joined Arpabet
%   Tier 2 "phones"    – individual phone intervals from MFA
%
% Gaps between labelled intervals are filled with unlabelled empty intervals.
% Any double-quote in a label is replaced with a single-quote for safety.

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
% HELPER: Build complete interval list with gap-filling
% =========================================================================
function iv = build_intervals(labels, onsets, offsets, total_dur)
% Fill gaps between labelled intervals with empty unlabelled intervals,
% ensuring the tier spans exactly [0, total_dur].

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
% HELPERS (unchanged from original): clock sync, go-beep extraction,
%          path validation, table I/O, column lookup
% =========================================================================

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
                if ~isempty(r_tokens)
                    target_run = str2double(r_tokens{1}{1});
                end
            end
            run_mask = (lm_tbl.run == target_run);
            if any(run_mask), lm_tbl = lm_tbl(run_mask, :); end
        end
        if ismember('filetype', lm_tbl.Properties.VariableNames) && ...
           ismember('t1', lm_tbl.Properties.VariableNames)
            ft       = string(lm_tbl.filetype);
            evt_mask = contains(ft, 'trials', 'IgnoreCase', true) | ...
                       contains(ft, 'events', 'IgnoreCase', true);
            aud_mask = contains(ft, 'audio',  'IgnoreCase', true) | ...
                       contains(ft, 'wav',    'IgnoreCase', true);
            if any(evt_mask) && any(aud_mask)
                clock_offset = double( lm_tbl.t1(find(evt_mask,1)) - ...
                                       lm_tbl.t1(find(aud_mask,1)) );
            end
        end
    catch
        clock_offset = 0;
    end
end

function go_onsets = extract_go_beep_onsets(trials_tbl, events_tbl, num_trials, run_duration)
    go_onsets = nan(num_trials, 1);

    go_col = find_matching_col(trials_tbl, ...
        {'go_beep_onset','go_beep','go_beep_time','go_onset','beep_onset','go_beep_sec'});
    if ~isempty(go_col)
        vals  = double(trials_tbl.(go_col));
        n_copy = min(num_trials, numel(vals));
        go_onsets(1:n_copy) = vals(1:n_copy);
        if ~all(isnan(go_onsets)), return; end
    end

    if ~isempty(events_tbl) && istable(events_tbl)
        type_col  = find_matching_col(events_tbl, ...
            {'event_code','event_type','trial_type','event_name','name','event','value','type','label'});
        onset_col = find_matching_col(events_tbl, ...
            {'onset','start','start_time','onset_sec','timestamp','time'});
        if ~isempty(type_col) && ~isempty(onset_col)
            evt_names  = string(events_tbl.(type_col));
            evt_onsets = double(events_tbl.(onset_col));
            is_go      = contains(evt_names, 'go_beep', 'IgnoreCase', true);
            matched    = evt_onsets(is_go);
            trial_col  = find_matching_col(events_tbl, ...
                {'trial','trial_num','trial_number','trial_idx'});
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
        if ~exist(fp, 'file')
            error('Run %d: Input file for "%s" not found:\n  %s', k, fn{1}, fp);
        end
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
        otherwise
            error('Unsupported file format: %s', ext);
    end
end

function save_generic_table(tbl, filepath)
    [~, ~, ext] = fileparts(filepath);
    switch lower(ext)
        case '.mat'
            save(filepath, 'tbl');
        case {'.tsv','.txt'}
            writetable(tbl, filepath, 'FileType', 'text', 'Delimiter', '\t');
        case {'.xlsx','.xls'}
            writetable(tbl, filepath);
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