//=============================================================================
// video_proc.v — 24bit 实时亮度 / 对比度处理（扩展要求 ④）
//-----------------------------------------------------------------------------
// 功能：
//   对 RGB888 像素做「对比度缩放 + 亮度偏移」，并保持 de / x / y 与像素同拍。
//
//   逐通道公式（以 128 为中点，无符号 0..255）：
//       s = c - 128                     有符号，-128..+127
//       p = s * contrast                有符号乘法，contrast 为 128 时 p = s*128
//       g = p >>> 7                     = s * (contrast/128)，算术右移
//       t = g + 128 + brightness        加回中点，再叠加亮度偏移
//       out = clamp(t, 0, 255)          饱和截断，不环绕
//
//   对比度：64..192（128 = 1.0x，步进 16）
//   亮度  ：-64..+64（0 = 不变，步进 8）
//
// 时钟/复位：I_clk = video_clk 25MHz；I_rst 高有效。
//
// 接口：
//   in  I_de                    数据有效
//   in  I_x / I_y[9:0]          像素坐标（与 I_rgb 同拍）
//   in  I_rgb[23:0]             RGB888
//   in  I_brightness signed[7:0] 亮度偏移 -64..+64
//   in  I_contrast[7:0]         对比度增益 64..192
//   out O_de / O_x / O_y        延迟 2 拍后的同拍信号
//   out O_rgb[23:0]             处理后的 RGB888
//
// 参数：无
//
// 内部例化：无
//
// 备注：
//   1) 固定 2 级流水：第 1 级做乘法，第 2 级做加法 + 饱和。
//      de/x/y 用同样的 2 级寄存器跟随，因此输出端三者仍然严格同拍，
//      下游 OSD 可以直接用 O_x/O_y 做定位，不需要额外补偿。
//   2) 位宽要点：亮度加法必须扩到 11bit signed 再判上下界。
//      如果直接 8bit 相加后截断，-1 会变成 255（环绕），画面会出现反相噪点。
//   3) 非 I_de 期间 O_rgb 仍然输出结果（值为 0 输入的计算结果），
//      但下游只在 O_de=1 时使用，不影响消隐区。
//=============================================================================
`timescale 1ns / 1ps

module video_proc(
    input  wire               I_clk,
    input  wire               I_rst,          // 高有效

    input  wire               I_de,
    input  wire [9:0]         I_x,
    input  wire [9:0]         I_y,
    input  wire [23:0]        I_rgb,

    input  wire signed [7:0]  I_brightness,   // -64..+64
    input  wire [7:0]         I_contrast,     // 64..192，128 = 1.0x

    output reg                O_de,
    output reg  [9:0]         O_x,
    output reg  [9:0]         O_y,
    output reg  [23:0]        O_rgb
);

    //-------------------------------------------------------------------------
    // 组合函数：单通道 对比度乘法（第 1 级用）
    //   p = (c - 128) * contrast
    //-------------------------------------------------------------------------
    function signed [16:0] mul_center;
        input [7:0] c;
        input [7:0] k;
        reg   signed [8:0] s;
        begin
            s          = $signed({1'b0, c}) - 9'sd128;   // -128..+127
            mul_center = s * $signed({1'b0, k});         // -24576..+24384
        end
    endfunction

    //-------------------------------------------------------------------------
    // 组合函数：单通道 亮度加法 + 饱和（第 2 级用）
    //   g = p >>> 7 ；t = g + 128 + brightness ；clamp 到 0..255
    //-------------------------------------------------------------------------
    function [7:0] clamp_ch;
        input signed [16:0] p;
        input signed [7:0]  br;
        reg   signed [10:0] g;
        reg   signed [10:0] t;
        begin
            g = p >>> 7;                                  // -192..+190
            t = g + 11'sd128 + {{3{br[7]}}, br};          // -128..+382
            if (t < 11'sd0)
                clamp_ch = 8'd0;
            else if (t > 11'sd255)
                clamp_ch = 8'd255;
            else
                clamp_ch = t[7:0];
        end
    endfunction

    //-------------------------------------------------------------------------
    // 2 级流水线
    //-------------------------------------------------------------------------
    reg               d1_de;
    reg [9:0]         d1_x;
    reg [9:0]         d1_y;
    reg signed [16:0] m_r;
    reg signed [16:0] m_g;
    reg signed [16:0] m_b;

    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) begin
            d1_de <= 1'b0;
            d1_x  <= 10'd0;
            d1_y  <= 10'd0;
            m_r   <= 17'sd0;
            m_g   <= 17'sd0;
            m_b   <= 17'sd0;

            O_de  <= 1'b0;
            O_x   <= 10'd0;
            O_y   <= 10'd0;
            O_rgb <= 24'd0;
        end else begin
            // ---- 第 1 级：对比度乘法 + 坐标打拍 ----
            d1_de <= I_de;
            d1_x  <= I_x;
            d1_y  <= I_y;

            m_r   <= mul_center(I_rgb[23:16], I_contrast);
            m_g   <= mul_center(I_rgb[15:8],  I_contrast);
            m_b   <= mul_center(I_rgb[7:0],   I_contrast);

            // ---- 第 2 级：亮度加法 + 饱和输出 ----
            O_de  <= d1_de;
            O_x   <= d1_x;
            O_y   <= d1_y;
            O_rgb <= { clamp_ch(m_r, I_brightness),
                      clamp_ch(m_g, I_brightness),
                      clamp_ch(m_b, I_brightness) };
        end
    end

endmodule
