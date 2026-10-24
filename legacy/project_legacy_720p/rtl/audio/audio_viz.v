//=============================================================================
// audio_viz.v  —  音频可视化（分频段能量 / 频谱柱）
//-----------------------------------------------------------------------------
// 对应扩展要求 ⑤。优先级：分频段能量/Goertzel（8~16 段）> 256 点 FFT（冲刺）。
//
// 两种声源：
//   src_sel=0：播放中的 PCM（WAV），实现"随乐起伏"的频谱柱；
//   src_sel=1：麦克风现场采集（mic_adc），实现"现场声源"互动（差异化亮点）。
// 输出：BARS 根柱子（每根 8bit 高度），交给 osd_layer 叠加。
//
// 【当前状态】接口骨架；带通滤波/能量统计在第 4 周实现（见 TODO）。
//=============================================================================
`timescale 1ns / 1ps

module audio_viz #(
    parameter BARS = 16
)(
    input  wire              clk,
    input  wire              rst_n,

    input  wire [15:0]       pcm,          // 16bit 有符号采样
    input  wire              pcm_valid,    // 采样节拍（48kHz）
    input  wire [1:0]        src_sel,      // 0=播放PCM, 1=麦克风

    output reg  [BARS*8-1:0] bars,         // 每 8bit 一根柱
    output reg               bars_valid
);

    // TODO(第 4 周):
    //   1) 对每个频段做带通滤波（或滑动 Goertzel），统计窗口能量；
    //   2) 取对数/开方映射到 0..255 柱高，做峰值保持与缓降（视觉友好）；
    //   3) 打包到 bars，bars_valid 以约 30~60Hz 刷新。

    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bars       <= {(BARS*8){1'b0}};
            bars_valid <= 1'b0;
        end else begin
            bars_valid <= 1'b0;
        end
    end

    // synthesis translate_off
    wire _unused = &{1'b0, pcm, pcm_valid, src_sel};
    // synthesis translate_on

endmodule
