% get the approximate ControlChange parameter value to send to Eventide H90 for a desired ms delay
%
% H90 only has 127 delay values mapped, so find the closest value
%
%   IN:
%      target_delay_ms is a delay in ms from 0 to 500ms
%
%    OUT:
%     cc_val is the midi Control Change value to send in order to achieve that delay
%     actual_delay_ms is the delay which will be produced, which may not 
%
% assume the parameter range is 0-500ms (or else this function can't be used)
%   [do not change the parameter range on the H90, or this 127-value map will have to be manually recreated] 
% ..... double check this on Eventide:
%     PARAMETERS  [press unilt Delay A appears]
%     press and hold black knob under Delay A ... we're not using Delay B
%     scroll through parameters with SELECT until you see "Control Range"
%     turn the knobs under Start and End to check the min/max values
%
%   The cc_map and delay_map values were determined empirically
%
% AM 2026

function [cc_val, actual_delay_ms, target_delay_ms, target_minus_actual_ms]  = delay_to_midi_ccval(target_delay_ms)

    min_delay_ms = 0; 
    max_delay_ms = 500; 

    assert(target_delay_ms >= min_delay_ms && target_delay_ms <= max_delay_ms)

    % Empirical Data Points
    mapvals = fn_cc_delay_map();
    map = table(mapvals(:,1),mapvals(:,2),'VariableNames',{'cc','del'});
    
    % find closest mapped delay
    [target_minus_actual_ms, closest_ind] = min(abs(map.del-target_delay_ms));
    cc_val = map.cc(closest_ind); 
    actual_delay_ms = map.del(closest_ind); 
    
   
end


%% empirical map of ccvals and corresponding delays
function cc_delay_map = fn_cc_delay_map()

    % H90 0-500ms CC Value to Delay Mapping
    % Column 1: cc_val | Column 2: delay_ms
    
    cc_delay_map = [ ...
        0,   0; 
        1,   1;
        2,   2;
        3,   4;
        4,   6;
        5,   7;
        6,   9;
        7,  10;
        8,  12;
        9,  14;
        10, 15;
        11, 17;
        12, 19;
        13, 20;
        14, 22;
        15, 24;
        16, 25;
        17, 27;
        18, 29;
        19, 30;
        20, 32;
        21, 33;
        22, 35;
        23, 37;
        24, 38;
        25, 40;
        26, 42;
        27, 43;
        28, 45;
        29, 47;
        30, 48;
        31, 50;
        32, 52;
        33, 53;
        34, 55;
        35, 57;
        36, 58;
        37, 60;
        38, 62;
        39, 63;
        40, 65;
        41, 67;
        42, 68;
        43, 70;
        44, 72;
        45, 73;
        46, 75;
        47, 77;
        48, 78;
        49, 80;
        50, 82;
        51, 83;
        52, 85;
        53, 87;
        54, 88;
        55, 90;
        56, 92;
        57, 94;
        58, 95;
        59, 97;
        60, 99;
        61, 102;
        62, 106;
        63, 109;
        64, 112;
        65, 116;
        66, 119;
        67, 123;
        68, 126;
        69, 129;
        70, 133;
        71, 136;
        72, 139;
        73, 143;
        74, 146;
        75, 149;
        76, 153;
        77, 156;
        78, 159;
        79, 163;
        80, 166;
        81, 169;
        82, 173;
        83, 176;
        84, 179;
        85, 183;
        86, 186;
        87, 190;
        88, 193;
        89, 196;
        90, 201;
        91, 208;
        92, 215;
        93, 221;
        94, 228;
        95, 235;
        96, 241;
        97, 248;
        98, 255;
        99, 262;
        100, 268;
        101, 275;
        102, 282;
        103, 288;
        104, 295;
        105, 302;
        106, 308;
        107, 315;
        108, 322;
        109, 329;
        110, 335;
        111, 342;
        112, 349;
        113, 355;
        114, 362;
        115, 369;
        116, 375;
        117, 382;
        118, 389;
        119, 396;
        120, 407;
        121, 420;
        122, 433;
        123, 447;
        124, 460;
        125, 474;
        126, 487;
        127, 500];
end