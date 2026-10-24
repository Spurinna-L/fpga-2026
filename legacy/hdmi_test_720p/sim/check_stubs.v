//=============================================================================
// check_stubs.v — 仅用于 iverilog 语法/连接检查的"桩"（不参与综合！）
//   把 TD 生成的 IP / 厂商硬核替换成空模块，让顶层能被 iverilog 解析。
//=============================================================================
`timescale 1ns / 1ps

module tx_pll(input refclk, input reset, output extlock,
              output clk0_out, output clk1_out, output clk2_out);
endmodule

module sdram_pll(input refclk, input reset,
                 output clk0_out, output clk1_out, output clk2_out,
                 output clk3_out, output clk4_out, output extlock);
endmodule

module Sdram_Control_4Port(
    input CTRL_CLK, input SDRAM_CLK, input RESET_N,
    input [15:0] WR1_DATA, input WR1, input [20:0] WR1_ADDR, input [20:0] WR1_MAX_ADDR,
    input [9:0] WR1_LENGTH, input WR1_LOAD, input WR1_CLK, output WR1_FULL, output [15:0] WR1_USE,
    input [15:0] WR2_DATA, input WR2, input [20:0] WR2_ADDR, input [20:0] WR2_MAX_ADDR,
    input [8:0] WR2_LENGTH, input WR2_LOAD, input WR2_CLK, output WR2_FULL, output [15:0] WR2_USE,
    output [15:0] RD1_DATA, input RD1, input [20:0] RD1_ADDR, input [20:0] RD1_MAX_ADDR,
    input [9:0] RD1_LENGTH, input RD1_LOAD, input RD1_CLK, output RD1_EMPTY, output [15:0] RD1_USE,
    output [15:0] RD2_DATA, input RD2, input [20:0] RD2_ADDR, input [20:0] RD2_MAX_ADDR,
    input [8:0] RD2_LENGTH, input RD2_LOAD, input RD2_CLK, output RD2_EMPTY, output [15:0] RD2_USE
);
endmodule

module hdmi_tx #(parameter FAMILY = "EG4")(
    input PXLCLK_I, input PXLCLK_5X_I, input RST_N,
    input VGA_HS, input VGA_VS, input VGA_DE, input [23:0] VGA_RGB,
    output HDMI_CLK_P, output HDMI_D2_P, output HDMI_D1_P, output HDMI_D0_P
);
endmodule
