//=============================================================================
// hdmi_tx_wrap.v  —  软 TMDS HDMI 发送（黑盒例化官方加密 IP）
//-----------------------------------------------------------------------------
// 【红线】DVITransmitter / TMDSEncoder / SerializerN_1_lvds 为 Anlogic 加密
//   VHDL，只能黑盒例化、不可修改。它们在 ip/hdmi/ 下。
//   该 IP 为 DVI 视频发送（无音频数据岛）——因此音频必须走板载 PWM 通路。
//
// 输入：RGB565（来自视频流水线）→ 无损扩展为 RGB888 后送入 IP。
// 输出：HDMI 差分对（CLK/D0/D1/D2，_P/_N 成对，_N 为相邻引脚，自动生成）。
//
// 引脚：CLK_P=P1, D0_P=N1, D1_P=P4, D2_P=J3（IOSTANDARD=LVDS33）。
//=============================================================================
`timescale 1ns / 1ps

module hdmi_tx_wrap (
    input  wire        clk_pix,
    input  wire        clk_pix5x,
    input  wire        rst_n,
    input  wire        hs_i,
    input  wire        vs_i,
    input  wire        de_i,
    input  wire [15:0] rgb565,

    output wire        hdmi_clk_p,
    output wire        hdmi_d0_p,
    output wire        hdmi_d1_p,
    output wire        hdmi_d2_p
);

    // RGB565 -> RGB888（低位用高位补齐，减少色阶损失）
    wire [23:0] rgb888 = {
        rgb565[15:11], rgb565[15:13],   // R5 -> R8
        rgb565[10:5],  rgb565[10:9],    // G6 -> G8
        rgb565[4:0],   rgb565[4:2]      // B5 -> B8
    };

    hdmi_tx #(.FAMILY("EG4")) u_hdmi_tx (
        .PXLCLK_I    (clk_pix),
        .PXLCLK_5X_I (clk_pix5x),
        .RST_N       (rst_n),

        .VGA_HS      (hs_i),
        .VGA_VS      (vs_i),
        .VGA_DE      (de_i),
        .VGA_RGB     (rgb888),

        .HDMI_CLK_P  (hdmi_clk_p),
        .HDMI_D2_P   (hdmi_d2_p),
        .HDMI_D1_P   (hdmi_d1_p),
        .HDMI_D0_P   (hdmi_d0_p)
    );

endmodule
