//=============================================================================
// wav_player.v  —  WAV / PCM 音频播放（自研）
//-----------------------------------------------------------------------------
// 输入：来自 fat32_reader 的 WAV 文件字节流。
// 输出：定速 PCM 采样流（48kHz）+ valid，供 pwm_audio 调制与 audio_viz 分析。
//
// 支持范围（按赛题素材规范）：
//   - 未压缩 PCM：8/16bit，单/双声道，48kHz（双声道下混单声道或按 L/R 交替）；
//   - 跳过 fmt/data chunk 之间的非 data 块。
// 与画面同步：采样节拍由像素时钟（74.25MHz）分频派生，天然同源。
//
// 【当前状态】接口骨架；chunk 解析与 48kHz 定速输出在第 2 周实现（见 TODO）。
//=============================================================================
`timescale 1ns / 1ps

module wav_player (
    input  wire        clk,          // 系统 50MHz（或像素域，按集成方案）
    input  wire        rst_n,

    // 文件字节流（来自 fat32_reader）
    output wire        file_pop,
    input  wire        file_valid,
    input  wire [7:0]  file_data,

    // 音频信息
    output reg  [31:0] sample_rate,
    output reg  [2:0]  channels,
    output reg  [5:0]  bits,
    output reg         header_ok,

    // PCM 输出（16bit 有符号，左对齐）
    output reg  [15:0] pcm_l,
    output reg  [15:0] pcm_r,
    output reg         pcm_valid,
    output reg         eof
);

    // TODO(第 2 周):
    //   1) 解析 "RIFF"/"WAVE"/"fmt "/"data" chunk，取声道数、采样率、位宽；
    //   2) 48kHz 采样节拍由 clk 分频（或像素域分频）产生 sample_tick；
    //   3) sample_tick 到来时取下一组采样（8bit 无符号→16bit；16bit 直接）；
    //   4) 双声道分别输出或按需下混。

    assign file_pop = 1'b0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sample_rate <= 32'd48000;
            channels    <= 3'd2;
            bits        <= 6'd16;
            header_ok   <= 1'b0;
            pcm_l       <= 16'd0;
            pcm_r       <= 16'd0;
            pcm_valid   <= 1'b0;
            eof         <= 1'b0;
        end else begin
            pcm_valid <= 1'b0;
        end
    end

    // synthesis translate_off
    wire _unused = &{1'b0, file_valid, file_data};
    // synthesis translate_on

endmodule
