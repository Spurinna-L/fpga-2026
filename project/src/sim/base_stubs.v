//=============================================================================
// base_stubs.v — 仅用于 iverilog / ModelSim 语法检查与仿真
// 为 PLL / SDRAM IP / HDMI 加密核 / FIFO IP / ODDR 原语提供空壳
//
// !!! 重要 !!!
// 本文件里的 module 名与真实 IP 生成的文件完全相同（sys_pll / video_pll /
// PLL_HDMI_AUDIO / wfifo_32_32_512 / rfifo_32_32_512 ...）。如果它被 TD 当作
// 普通源文件一起综合，且 CompileOrder 排在真实 IP 之后，TD 会报：
//     HDL-7201 CRITICAL-WARNING: overwrite current module 'sys_pll'
// 结果真实 PLL 被空壳替换 → 一个时钟都不产生 → HDMI 全黑屏。
//
// 因此本文件必须定义 `SIM_STUBS 宏才生效：
//   iverilog :  -D SIM_STUBS
//   ModelSim :  +define+SIM_STUBS
// TD 综合时不定义该宏，本文件内容自动为空，不会产生同名模块。
//=============================================================================

`ifdef SIM_STUBS
`timescale 1ns / 1ps

// ---- PLL ----
module sys_pll(input refclk, input reset, output clk0_out, output clk1_out, output clk2_out);
    assign clk0_out = refclk;
    assign clk1_out = refclk;
    assign clk2_out = refclk;
endmodule

module video_pll(input refclk, input reset, output clk0_out, output clk1_out);
    assign clk0_out = refclk;
    assign clk1_out = refclk;
endmodule

module PLL_HDMI_AUDIO(input refclk, input reset, output extlock,
                      output clk0_out, output clk1_out, output clk2_out);
    assign extlock = 1'b1;
    assign clk0_out = refclk;
    assign clk1_out = refclk;
    assign clk2_out = refclk;
endmodule

// ---- 片内 SDRAM 用户接口 ----
module sdram(
    input  wire        Clk,
    input  wire        Clk_sft,
    input  wire        Rst,
    output wire        Sdr_init_done,
    output wire        Sdr_init_ref_vld,
    output wire        Sdr_busy,
    input  wire        App_wr_en,
    input  wire [20:0] App_wr_addr,
    input  wire [3:0]  App_wr_dm,
    input  wire [31:0] App_wr_din,
    input  wire        App_rd_en,
    input  wire [20:0] App_rd_addr,
    output wire        Sdr_rd_en,
    output wire [31:0] Sdr_rd_dout
);
    assign Sdr_init_done    = 1'b1;
    assign Sdr_init_ref_vld = 1'b0;
    assign Sdr_busy         = 1'b0;
    assign Sdr_rd_en        = App_rd_en;
    assign Sdr_rd_dout      = 32'd0;
endmodule

// ---- HDMI 1.4b 加密核 ----
module hdmi_1_4b_transmitter_core_wrapper #(
    parameter DEVICE = "EG",
    parameter HTOTAL = 800,
    parameter HSA = 96,
    parameter HFP = 16,
    parameter HBP = 48,
    parameter HACTIVE = 640,
    parameter VTOTAL = 525,
    parameter VSA = 2,
    parameter VFP = 10,
    parameter VBP = 33,
    parameter VACTIVE = 480,
    parameter VIDEO_VIC = 1,
    parameter VIDEO_TPG = "Disable",
    parameter VIDEO_FORMAT = "RGB",
    parameter AUDIO_SAMPLE_RATE = "48K",
    parameter IIC_SCL_DIV = 250
)(
    input  wire        I_pixel_clk,
    input  wire        I_rst,
    input  wire        I_edid_read_trig,
    output wire        O_edid_read_valid,
    output wire [7:0]  O_edid_read_data,
    input  wire        I_axis_s_user,
    input  wire        I_axis_s_valid,
    input  wire        I_axis_s_last,
    input  wire [23:0] I_axis_s_data,
    output wire        O_axis_s_ready,
    input  wire        I_audio_valid,
    input  wire [23:0] I_audio_left_data,
    input  wire [23:0] I_audio_right_data,
    input  wire        I_acr_valid,
    input  wire [19:0] I_acr_cts,
    input  wire [19:0] I_acr_n,
    output wire        O_video_locked,
    output wire        O_ddc_scl,
    inout  wire        IO_ddc_sda,
    output wire [9:0]  O_ch0_tmds_data,
    output wire [9:0]  O_ch1_tmds_data,
    output wire [9:0]  O_ch2_tmds_data,
    output wire [9:0]  O_clk_tmds_data
);
    assign O_edid_read_valid = 1'b0;
    assign O_edid_read_data  = 8'd0;
    assign O_axis_s_ready    = 1'b1;
    assign O_video_locked    = 1'b1;
    assign O_ddc_scl         = 1'b1;
    assign O_ch0_tmds_data   = 10'd0;
    assign O_ch1_tmds_data   = 10'd0;
    assign O_ch2_tmds_data   = 10'd0;
    assign O_clk_tmds_data   = 10'd0;
endmodule

// ---- FIFO IP ----
module wfifo_32_32_512 #(
    parameter DATA_WIDTH_W = 32,
    parameter DATA_WIDTH_R = 32,
    parameter ADDR_WIDTH_W = 9,
    parameter ADDR_WIDTH_R = 9
)(
    input  wire        clkr,
    input  wire        clkw,
    input  wire        rst,
    input  wire        we,
    input  wire        re,
    input  wire [31:0] di,
    output wire        empty_flag,
    output wire        full_flag,
    output wire [ADDR_WIDTH_W-1:0]  wrusedw,
    output wire [ADDR_WIDTH_R-1:0]  rdusedw,
    output wire [31:0] dout
);
    assign empty_flag = 1'b0;
    assign full_flag  = 1'b0;
    assign wrusedw    = {ADDR_WIDTH_W{1'b0}};
    assign rdusedw    = {ADDR_WIDTH_R{1'b0}};
    assign dout       = 32'd0;
endmodule

module rfifo_32_32_512 #(
    parameter DATA_WIDTH_W = 32,
    parameter DATA_WIDTH_R = 32,
    parameter ADDR_WIDTH_W = 9,
    parameter ADDR_WIDTH_R = 9
)(
    input  wire        clkr,
    input  wire        clkw,
    input  wire        rst,
    input  wire        we,
    input  wire        re,
    input  wire [31:0] di,
    output wire        empty_flag,
    output wire        full_flag,
    output wire [ADDR_WIDTH_W-1:0]  wrusedw,
    output wire [ADDR_WIDTH_R-1:0]  rdusedw,
    output wire [31:0] dout
);
    assign empty_flag = 1'b0;
    assign full_flag  = 1'b0;
    assign wrusedw    = {ADDR_WIDTH_W{1'b0}};
    assign rdusedw    = {ADDR_WIDTH_R{1'b0}};
    assign dout       = 32'd0;
endmodule

// ---- ODDR 原语 ----
module EG_LOGIC_ODDR(
    input  wire clk,
    input  wire rst,
    input  wire d1,
    input  wire d0,
    output wire q
);
    assign q = clk ? d1 : d0;
endmodule

// ---- EG_LOGIC_BRAM 行为模型（仅仿真；PDPW: A 写 / B 读）----
module EG_LOGIC_BRAM #(
    parameter DATA_WIDTH_A = 18,
    parameter DATA_WIDTH_B = 18,
    parameter ADDR_WIDTH_A = 10,
    parameter ADDR_WIDTH_B = 10,
    parameter DATA_DEPTH_A = 1024,
    parameter DATA_DEPTH_B = 1024,
    parameter MODE         = "SP",
    parameter REGMODE_A    = "NOREG",
    parameter REGMODE_B    = "NOREG",
    parameter WRITEMODE_A  = "NORMAL",
    parameter WRITEMODE_B  = "NORMAL",
    parameter RESETMODE    = "SYNC",
    parameter IMPLEMENT    = "9K",
    parameter INIT_FILE    = "NONE",
    parameter FILL_ALL     = "NONE"
)(
    input  wire [DATA_WIDTH_A-1:0] dia,
    input  wire [DATA_WIDTH_B-1:0] dib,
    input  wire [ADDR_WIDTH_A-1:0] addra,
    input  wire [ADDR_WIDTH_B-1:0] addrb,
    input  wire cea,
    input  wire ceb,
    input  wire ocea,
    input  wire oceb,
    input  wire clka,
    input  wire clkb,
    input  wire wea,
    input  wire web,
    input  wire bea,
    input  wire beb,
    input  wire rsta,
    input  wire rstb,
    output wire [DATA_WIDTH_A-1:0] doa,
    output wire [DATA_WIDTH_B-1:0] dob
);
    reg [DATA_WIDTH_A-1:0] mem [0:DATA_DEPTH_A-1];
    reg [DATA_WIDTH_B-1:0] dob_r;

    always @(posedge clka) begin
        if (cea && wea)
            mem[addra] <= dia;
    end

    always @(posedge clkb) begin
        if (ceb)
            dob_r <= mem[addrb];
    end

    assign doa = {DATA_WIDTH_A{1'b0}};
    assign dob = dob_r;
endmodule

`endif // SIM_STUBS
