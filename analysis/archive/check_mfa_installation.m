function mfa_info = check_mfa_installation()
% CHECK_MFA_INSTALLATION Diagnose MFA accessibility from MATLAB (with full path)

mfa_info = struct();
conda_path = 'C:\ProgramData\miniconda3\condabin\conda.bat';

% 1. Try conda run -n mfa mfa version
fprintf('=== Checking MFA via conda environment ===\n');
cmd = sprintf('"%s" run -n mfa mfa version', conda_path);
[status, result] = system(cmd);
if status == 0
    mfa_info.conda_mfa_env = true;
    mfa_info.version = strtrim(result);
    fprintf('✓ MFA accessible via conda: %s\n', mfa_info.version);
else
    mfa_info.conda_mfa_env = false;
    fprintf('✗ MFA not found via conda run -n mfa\n');
    fprintf('  Error: %s\n', result);
    return;
end

% 2. Check for acoustic model
fprintf('\n=== Checking MFA Acoustic Model ===\n');
cmd = sprintf('"%s" run -n mfa mfa model list acoustic', conda_path);
[status, result] = system(cmd);
if status == 0
    fprintf('Available acoustic models:\n%s\n', result);
    if contains(result, 'english_us_arpa')
        mfa_info.english_acoustic_model = true;
        fprintf('✓ English acoustic model (english_us_arpa) found\n');
    end
else
    fprintf('✗ Could not list acoustic models\n');
end

% 3. Summary
fprintf('\n=== SUMMARY ===\n');
if mfa_info.conda_mfa_env
    fprintf('✓ MFA ready to use\n');
    fprintf('  Call from MATLAB via:\n');
    fprintf('    system(sprintf(''"%s" run -n mfa mfa ...'', conda_path))\n', conda_path);
else
    fprintf('✗ MFA not accessible\n');
end

end