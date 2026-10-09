//=============================================================================
// pwm_audio.v  —  音频输出（数字音量 + 一阶 Sigma-Delta PWM）
//-----------------------------------------------------------------------------
// 对应基础要求③"基础音频输出"。音频不经过 HDMI（官方 IP 为 DVI 无数据岛），
// 而是走板载通路：PWM(F3) → 低通滤波 → FM8002A 功放 → 3.5mm/喇叭。
//
// 原理：把 16bit 有符号 PCM 送入一阶 Σ-Δ 调制器，1bit 高过采样输出，
//       再经板载 RC 低通还原模拟波形，音质优于普通 8bit PWM。
//   - 数字音量：sample = pcm * volume / 256（volume=256 为原音量，此处 8bit 近似）
//   - 载波与采样节拍均由像素/系统时钟派生，与画面天然同源。
//
// 复用参考：5_PWM_DAC_DDS 的 PWM 型 DAC 思路（本模块自研为 Σ-Δ 版）。
//=============================================================================
`timescale 1ns / 1ps

module pwm_audio (
    input  wire        clk,          // 高过采样时钟（建议 ≥50MHz，最好用像素时钟）
    input  wire        rst_n,
    input  wire [15:0] pcm,          // 有符号 16bit PCM
    input  wire        pcm_valid,    // 采样节拍（48kHz）
    input  wire [7:0]  volume,       // 数字音量 0..255（128≈0.5x）

    output reg         audio_pwm     // F3 → 板载低通 + 功放
);

    // 数字音量：当前保持的采样 × volume >> 8
    reg signed [15:0] sample;         // 保持最近一次采样
    wire signed [15:0] ps = {{8{pcm[15]}}, pcm[15:8]};  // 占位参考（未使用）

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            sample <= 16'sd0;
        else if (pcm_valid) begin
            // (pcm[15:0] * volume) >> 8，保留符号
            sample <= ($signed(pcm) * $signed({1'b0, volume})) >>> 8;
        end
    end

    // 一阶 Σ-Δ：累加器取符号位输出，反馈由二补码回绕隐式完成
    reg signed [16:0] acc;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc       <= 17'sd0;
            audio_pwm <= 1'b0;
        end else begin
            acc       <= acc + {{1{sample[15]}}, sample};
            audio_pwm <= acc[16];
        end
    end

    // synthesis translate_off
    wire _unused = &{1'b0, ps};
    // synthesis translate_on

endmodule
