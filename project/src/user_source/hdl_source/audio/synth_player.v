//=============================================================================
// synth_player.v — 双声部音乐合成器（M3 扩展⑤ L2 音源）
//-----------------------------------------------------------------------------
// 功能：
//   在 audio_mclk 12.288MHz 下每 256 拍产生一个 48kHz 的 24bit 并行样本，
//   供 hdmi_audio_tone_i2s_64fs 的 I2S 主机（I_use_ext=1）直接发送。
//   同时这个样本也是"音频可视化"的物理来源（解串后即为同一路信号）。
//
//   两个声部：
//     旋律声部（melody）— 32 音循环的小乐句，泛音叠加以改变音色；
//     贝斯声部（bass）  — 与旋律同拍，低八度根音，音量约 1/4。
//   音色（I_timbre）：
//     0 = 电钢琴   基波 + 2 次(1/4) + 3 次(1/8)
//     1 = 柔和长音 基波 + 2 次(1/4)
//     2 = 方波     方波 + 3 次(1/8)   （芯片音乐风格）
//   包络（ADSR 退化版）：每个音符 1ms 淡入 + 1ms 淡出，避免换音爆点。
//
// 时钟/复位：I_clk = audio_mclk 12.288MHz；I_rst 高有效。
//
// 接口：
//   in  I_timbre[1:0]      音色（必须已在 I_clk 域同步）
//   out O_sample signed[23:0] 48kHz 并行音频样本（每 256 拍更新一次）
//
// 参数：
//   NOTE_SAMPLES = 12000   每个音符持续 0.25s（48kHz）
//
// 内部例化：无（纯查找表 + 相位累加器，不需要乘法器以外的大块资源）
//
// 备注：
//   正弦表只有 1/4 周期 64 项 8bit（其余象限用相位镜像 + 取负得到），
//   量化台阶约 -48dB，接电视喇叭听不出来，但比 16bit 表省约一半 LUT。
//   相位累加器 32bit，音符相位增量按 48kHz 采样率、A4=440Hz 计算。
//=============================================================================
`timescale 1ns / 1ps

module synth_player #(
    parameter [13:0] NOTE_SAMPLES = 14'd12000    // 0.25s @ 48kHz
)(
    input  wire               I_clk,        // 12.288MHz
    input  wire               I_rst,
    input  wire [1:0]         I_timbre,
    output reg  signed [23:0] O_sample
);

    //-------------------------------------------------------------------------
    // 48kHz 采样节拍：12.288MHz / 256 = 48kHz
    //-------------------------------------------------------------------------
    reg  [7:0] div_cnt;
    wire       tick = (div_cnt == 8'd255);

    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) div_cnt <= 8'd0;
        else       div_cnt <= div_cnt + 8'd1;
    end

    //-------------------------------------------------------------------------
    // 1/4 周期正弦表：qs8(k) = round(127.5*sin(2*pi*k/256))，k = 0..63
    //-------------------------------------------------------------------------
    function signed [7:0] qs8;
        input [5:0] i;
        begin
            case (i)
                6'd0:  qs8 = 8'd0;   6'd1:  qs8 = 8'd3;   6'd2:  qs8 = 8'd6;
                6'd3:  qs8 = 8'd9;   6'd4:  qs8 = 8'd12;  6'd5:  qs8 = 8'd16;
                6'd6:  qs8 = 8'd19;  6'd7:  qs8 = 8'd22;  6'd8:  qs8 = 8'd25;
                6'd9:  qs8 = 8'd28;  6'd10: qs8 = 8'd31;  6'd11: qs8 = 8'd34;
                6'd12: qs8 = 8'd37;  6'd13: qs8 = 8'd40;  6'd14: qs8 = 8'd43;
                6'd15: qs8 = 8'd46;  6'd16: qs8 = 8'd49;  6'd17: qs8 = 8'd52;
                6'd18: qs8 = 8'd55;  6'd19: qs8 = 8'd57;  6'd20: qs8 = 8'd60;
                6'd21: qs8 = 8'd63;  6'd22: qs8 = 8'd66;  6'd23: qs8 = 8'd68;
                6'd24: qs8 = 8'd71;  6'd25: qs8 = 8'd73;  6'd26: qs8 = 8'd76;
                6'd27: qs8 = 8'd78;  6'd28: qs8 = 8'd81;  6'd29: qs8 = 8'd83;
                6'd30: qs8 = 8'd86;  6'd31: qs8 = 8'd88;  6'd32: qs8 = 8'd90;
                6'd33: qs8 = 8'd92;  6'd34: qs8 = 8'd94;  6'd35: qs8 = 8'd97;
                6'd36: qs8 = 8'd99;  6'd37: qs8 = 8'd101; 6'd38: qs8 = 8'd102;
                6'd39: qs8 = 8'd104; 6'd40: qs8 = 8'd106; 6'd41: qs8 = 8'd108;
                6'd42: qs8 = 8'd109; 6'd43: qs8 = 8'd111; 6'd44: qs8 = 8'd112;
                6'd45: qs8 = 8'd114; 6'd46: qs8 = 8'd115; 6'd47: qs8 = 8'd117;
                6'd48: qs8 = 8'd118; 6'd49: qs8 = 8'd119; 6'd50: qs8 = 8'd120;
                6'd51: qs8 = 8'd121; 6'd52: qs8 = 8'd122; 6'd53: qs8 = 8'd123;
                6'd54: qs8 = 8'd124; 6'd55: qs8 = 8'd124; 6'd56: qs8 = 8'd125;
                6'd57: qs8 = 8'd126; 6'd58: qs8 = 8'd126; 6'd59: qs8 = 8'd127;
                6'd60: qs8 = 8'd127; 6'd61: qs8 = 8'd127; 6'd62: qs8 = 8'd127;
                default: qs8 = 8'd127;
            endcase
        end
    endfunction

    // 32bit 相位 → 有符号正弦（象限镜像 + 半周取负）
    function signed [8:0] sine_of;
        input [31:0] ph;
        reg   [5:0]  idx;
        begin
            idx = ph[30] ? (6'd63 - ph[29:24]) : ph[29:24];
            if (ph[31]) sine_of = -qs8(idx);
            else        sine_of =  qs8(idx);
        end
    endfunction

    //-------------------------------------------------------------------------
    // 十二平均律相位增量（32bit 相位 / 48kHz 采样率），C4..B4
    //-------------------------------------------------------------------------
    function [31:0] semi_inc;
        input [3:0] s;
        begin
            case (s)
                4'd0:  semi_inc = 32'd23409859;  // C4  261.63Hz
                4'd1:  semi_inc = 32'd24801882;  // C#4 277.18Hz
                4'd2:  semi_inc = 32'd26276679;  // D4  293.66Hz
                4'd3:  semi_inc = 32'd27839171;  // D#4 311.13Hz
                4'd4:  semi_inc = 32'd29494575;  // E4  329.63Hz
                4'd5:  semi_inc = 32'd31248413;  // F4  349.23Hz
                4'd6:  semi_inc = 32'd33106541;  // F#4 369.99Hz
                4'd7:  semi_inc = 32'd35075158;  // G4  392.00Hz
                4'd8:  semi_inc = 32'd37160835;  // G#4 415.30Hz
                4'd9:  semi_inc = 32'd39370534;  // A4  440.00Hz
                4'd10: semi_inc = 32'd41711627;  // A#4 466.16Hz
                default: semi_inc = 32'd44149430; // B4  493.88Hz
            endcase
        end
    endfunction

    // 音符码 = {八度码[1:0], 半音[3:0]}
    //   八度码 0 = C4 基准，1 = 高八度(×2)，2 = 低八度(÷2)，3 = 低两个八度(÷4)
    function [31:0] note_inc;
        input [5:0] code;
        reg  [31:0] base;
        begin
            base = semi_inc(code[3:0]);
            case (code[5:4])
                2'd0:    note_inc = base;
                2'd1:    note_inc = base << 1;
                2'd2:    note_inc = base >> 1;
                default: note_inc = base >> 2;
            endcase
        end
    endfunction

    //-------------------------------------------------------------------------
    // 乐句：旋律（C 大调五声化小乐句）+ 贝斯（I-V 根音）
    //-------------------------------------------------------------------------
    function [5:0] mel_code;
        input [4:0] i;
        begin
            case (i)
                5'd0,  5'd1:  mel_code = 6'd4;   // E4
                5'd2:         mel_code = 6'd5;   // F4
                5'd3,  5'd4:  mel_code = 6'd7;   // G4
                5'd5:         mel_code = 6'd5;   // F4
                5'd6:         mel_code = 6'd4;   // E4
                5'd7,  5'd13, 5'd14, 5'd15:
                              mel_code = 6'd2;   // D4
                5'd8:         mel_code = 6'd0;   // C4
                5'd9:         mel_code = 6'd0;   // C4
                5'd10, 5'd11: mel_code = 6'd2;   // D4
                5'd12:        mel_code = 6'd4;   // E4
                5'd16, 5'd17: mel_code = 6'd4;   // E4
                5'd18:        mel_code = 6'd5;   // F4
                5'd19, 5'd20: mel_code = 6'd7;   // G4
                5'd21:        mel_code = 6'd5;   // F4
                5'd22:        mel_code = 6'd4;   // E4
                5'd23:        mel_code = 6'd2;   // D4
                5'd24:        mel_code = 6'd0;   // C4
                5'd25:        mel_code = 6'd0;   // C4
                5'd26, 5'd27: mel_code = 6'd2;   // D4
                5'd28:        mel_code = 6'd4;   // E4
                5'd29:        mel_code = 6'd2;   // D4
                5'd30, 5'd31: mel_code = 6'd0;   // C4
                default:      mel_code = 6'd0;
            endcase
        end
    endfunction

    function [5:0] bass_code;
        input [4:0] i;
        begin
            case (i)
                //  C3 = 6'b10_0000 = 32, F3 = 37, G3 = 39
                5'd0,  5'd1,  5'd2,  5'd3:   bass_code = 6'd32;
                5'd4,  5'd5,  5'd6,  5'd7:   bass_code = 6'd32;
                5'd8,  5'd9:                 bass_code = 6'd37;
                5'd10, 5'd11:                bass_code = 6'd39;
                5'd12, 5'd13, 5'd14, 5'd15:  bass_code = 6'd32;
                5'd16, 5'd17, 5'd18, 5'd19:  bass_code = 6'd32;
                5'd20, 5'd21, 5'd22, 5'd23:  bass_code = 6'd32;
                5'd24, 5'd25:                bass_code = 6'd37;
                5'd26, 5'd27:                bass_code = 6'd39;
                default:                     bass_code = 6'd32;
            endcase
        end
    endfunction

    //-------------------------------------------------------------------------
    // 相位累加器 + 音符节奏
    //-------------------------------------------------------------------------
    reg  [31:0] ph_m;        // 旋律相位
    reg  [31:0] ph_b;        // 贝斯相位
    reg  [13:0] note_cnt;    // 当前音符已播放的样本数
    reg  [4:0]  note_idx;    // 乐句位置 0..31

    wire [13:0] NOTE_LAST = NOTE_SAMPLES - 14'd1;
    wire [31:0] inc_m = note_inc(mel_code(note_idx));
    wire [31:0] inc_b = note_inc(bass_code(note_idx));

    wire [31:0] ph_m2 = ph_m + ph_m;          // 2 次谐波相位
    wire [31:0] ph_m3 = ph_m + ph_m2;         // 3 次谐波相位

    wire signed [8:0] s1 = sine_of(ph_m);
    wire signed [8:0] s2 = sine_of(ph_m2);
    wire signed [8:0] s3 = sine_of(ph_m3);
    wire signed [8:0] sb = sine_of(ph_b);

    //-------------------------------------------------------------------------
    // 音色混合（统一扩到 11bit 有符号，避免位宽/符号推断出错）
    //-------------------------------------------------------------------------
    wire signed [10:0] h1 = {{2{s1[8]}}, s1};            // 基波
    wire signed [10:0] h2 = {{4{s2[8]}}, s2[8:2]};       // 2 次谐波 /4
    wire signed [10:0] h3 = {{5{s3[8]}}, s3[8:3]};       // 3 次谐波 /8
    wire signed [10:0] sq = ph_m[31] ? -11'sd110 : 11'sd110;  // 方波

    wire signed [10:0] mix_m = (I_timbre == 2'd0) ? (h1 + h2 + h3) :
                               (I_timbre == 2'd1) ? (h1 + h2)      :
                                                    (sq + h3);

    wire signed [10:0] b1 = {{2{sb[8]}}, sb};            // 9bit 有符号扩展到 11bit
    wire signed [10:0] mix_b = (I_timbre == 2'd2) ? (b1 >>> 3) : (b1 >>> 2);

    wire signed [10:0] mix = mix_m + mix_b;

    //-------------------------------------------------------------------------
    // 包络：48 个样本（1ms）淡入 / 淡出，换音处包络为 0，无爆音
    //-------------------------------------------------------------------------
    wire [13:0] remain  = NOTE_LAST - note_cnt;
    wire [5:0]  fade_in = (note_cnt >= 14'd48) ? 6'd63 : note_cnt[5:0];
    wire [5:0]  fade_out= (remain   >= 14'd48) ? 6'd63 : remain[5:0];
    wire [5:0]  env6    = (fade_in < fade_out) ? fade_in : fade_out;
    wire [7:0]  env     = {env6, 2'b00};                 // 0..252

    wire signed [19:0] prod     = mix * $signed({1'b0, env});
    wire signed [19:0] prod_env = prod >>> 8;
    wire        [10:0] mix_e    = prod_env[10:0];         // 幅值 ±204，左移 13 位≈±1.67M

    //-------------------------------------------------------------------------
    // 样本寄存器（每 256 拍更新一次 → 48kHz）
    //-------------------------------------------------------------------------
    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) begin
            ph_m     <= 32'd0;
            ph_b     <= 32'd0;
            note_cnt <= 14'd0;
            note_idx <= 5'd0;
            O_sample <= 24'sd0;
        end
        else if (tick) begin
            ph_m <= ph_m + inc_m;
            ph_b <= ph_b + inc_b;

            O_sample <= {mix_e, 13'b0};

            if (note_cnt == NOTE_LAST) begin
                note_cnt <= 14'd0;
                note_idx <= note_idx + 5'd1;              // 31 → 0 自然回绕
            end
            else begin
                note_cnt <= note_cnt + 14'd1;
            end
        end
    end

endmodule
