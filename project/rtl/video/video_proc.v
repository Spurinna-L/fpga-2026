//=============================================================================
// video_proc.v  —  实时视频参数处理（亮度 / 对比度 / 饱和度）
//-----------------------------------------------------------------------------
// 对应扩展要求 ④。寄存器（由控制层写入，见 regs.v）：
//   brightness : signed[7:0]  亮度偏移，0 为不变
//   contrast   : [7:0]         对比度增益，128 = 1.0x
//   saturation : [7:0]         饱和度增益，128 = 1.0x（第二阶段实现）
//
// 处理：RGB565 先无损扩为 8bit/通道 → 对比度(乘增益) + 亮度(加偏置) →
//       饱和截断 → 截回 RGB565。与 hs/vs/de 同步打一拍，避免图像错位。
//
// 【当前状态】亮度/对比度已实现；饱和度留 TODO（需 YCbCr 转换）。
//=============================================================================
`timescale 1ns / 1ps

module video_proc (
    input  wire               clk_pix,
    input  wire               rst_n,
    input  wire        [15:0] rgb_in,
    input  wire               de_in,
    input  wire               hs_in,
    input  wire               vs_in,
    input  wire signed [7:0]  brightness,   // 亮度偏移
    input  wire        [7:0]  contrast,     // 对比度增益 128=1.0
    input  wire        [7:0]  saturation,   // 饱和度增益 128=1.0（TODO）
    output reg         [15:0] rgb_out,
    output reg                de_out,
    output reg                hs_out,
    output reg                vs_out
);

    // RGB565 -> 8bit 扩张
    wire [7:0] r8 = {rgb_in[15:11], rgb_in[15:13]};
    wire [7:0] g8 = {rgb_in[10:5],  rgb_in[10:9]};
    wire [7:0] b8 = {rgb_in[4:0],   rgb_in[4:2]};

    // 饱和截断函数
    function [7:0] clamp8;
        input signed [15:0] v;
        begin
            if (v < 16'sd0)         clamp8 = 8'd0;
            else if (v > 16'sd255)  clamp8 = 8'd255;
            else                    clamp8 = v[7:0];
        end
    endfunction

    // 对比度：(v-128)*gain/128 + 128 ；亮度：+ brightness
    function [7:0] proc_ch;
        input [7:0]       ch;
        input signed [7:0] bright;
        input [7:0]       gain;
        reg signed [15:0] t;
        begin
            t = (($signed({8'b0, ch}) - 16'sd128) * $signed({8'b0, gain})) >>> 7;
            proc_ch = clamp8(t + 16'sd128 + $signed({{8{bright[7]}}, bright}));
        end
    endfunction

    // TODO(第二阶段): 饱和度 —— 将 RGB 转 YCbCr，对 Cb/Cr 乘 gain 再转回。
    //   本版 saturation 暂不参与运算，待 ④ 增强时补齐。

    reg [7:0] ro, go, bo;
    always @(posedge clk_pix or negedge rst_n) begin
        if (!rst_n) begin
            ro <= 8'd0; go <= 8'd0; bo <= 8'd0;
        end else begin
            ro <= proc_ch(r8, brightness, contrast);
            go <= proc_ch(g8, brightness, contrast);
            bo <= proc_ch(b8, brightness, contrast);
        end
    end

    always @(posedge clk_pix or negedge rst_n) begin
        if (!rst_n) begin
            rgb_out <= 16'd0;
            de_out  <= 1'b0;
            hs_out  <= 1'b0;
            vs_out  <= 1'b0;
        end else begin
            rgb_out <= de_in ? {ro[7:3], go[7:2], bo[7:3]} : 16'd0;
            de_out  <= de_in;
            hs_out  <= hs_in;
            vs_out  <= vs_in;
        end
    end

endmodule
