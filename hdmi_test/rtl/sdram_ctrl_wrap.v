//=============================================================================
// sdram_ctrl_wrap.v  —  片内 SDRAM 帧缓存控制器封装
//-----------------------------------------------------------------------------
// 复用：rtl/reuse/sdram/ 下的
//   · Sdram_Control_4Port  —— 经典 4 端口 FIFO 控制器（**内部已例化 sdram 硬核**）
//   · sdram.v              —— EG_PHY_SDRAM_2M_32 硬核（2M x 32bit = 8MB）
//   · sdram_pll.v          —— 100MHz 控制时钟 + 100MHz@90° DRAM 时钟
//
// 数据宽度 DSIZE=16（1 字 = 1 个 RGB565 像素）；地址宽度 ASIZE=21。
// 端口分配（见 doc/接口对接表.md §I2）：
//   WR1/RD1 = 帧缓冲 A ； WR2/RD2 = 帧缓冲 B
//=============================================================================
`timescale 1ns / 1ps

module sdram_ctrl_wrap #(
    parameter ASIZE = 21,
    parameter DSIZE = 16
)(
    input  wire              clk_50m,
    input  wire              rst_n,

    // ---- FIFO Write Side 1（帧A写）----
    input  wire [DSIZE-1:0]  wr1_data,
    input  wire              wr1_req,
    input  wire [ASIZE-1:0]  wr1_addr,
    input  wire [ASIZE-1:0]  wr1_max_addr,
    input  wire [9:0]        wr1_length,
    input  wire              wr1_load,
    input  wire              wr1_clk,
    output wire              wr1_full,
    output wire [15:0]       wr1_use,

    // ---- FIFO Write Side 2（帧B写）----
    input  wire [DSIZE-1:0]  wr2_data,
    input  wire              wr2_req,
    input  wire [ASIZE-1:0]  wr2_addr,
    input  wire [ASIZE-1:0]  wr2_max_addr,
    input  wire [9:0]        wr2_length,
    input  wire              wr2_load,
    input  wire              wr2_clk,
    output wire              wr2_full,
    output wire [15:0]       wr2_use,

    // ---- FIFO Read Side 1（帧A读）----
    output wire [DSIZE-1:0]  rd1_data,
    input  wire              rd1_req,
    input  wire [ASIZE-1:0]  rd1_addr,
    input  wire [ASIZE-1:0]  rd1_max_addr,
    input  wire [9:0]        rd1_length,
    input  wire              rd1_load,
    input  wire              rd1_clk,
    output wire              rd1_empty,
    output wire [15:0]       rd1_use,

    // ---- FIFO Read Side 2（帧B读）----
    output wire [DSIZE-1:0]  rd2_data,
    input  wire              rd2_req,
    input  wire [ASIZE-1:0]  rd2_addr,
    input  wire [ASIZE-1:0]  rd2_max_addr,
    input  wire [9:0]        rd2_length,
    input  wire              rd2_load,
    input  wire              rd2_clk,
    output wire              rd2_empty,
    output wire [15:0]       rd2_use,

    // ---- 状态 ----
    output wire              clk_sdr_ctrl,   // 100MHz 控制器时钟
    output wire              clk_sdram,      // 100MHz@90° SDRAM 时钟
    output wire              pll_locked
);

    // SDRAM 时钟：100MHz + 100MHz@90°
    wire pll_locked_i;
    sdram_pll u_sdram_pll (
        .refclk   (clk_50m),
        .reset    (~rst_n),
        .clk0_out (clk_sdr_ctrl),
        .clk1_out (clk_sdram),
        .clk2_out (),
        .clk3_out (),
        .clk4_out (),
        .extlock  (pll_locked_i)
    );
    assign pll_locked = pll_locked_i;

    Sdram_Control_4Port u_sdram_ctrl (
        .CTRL_CLK   (clk_sdr_ctrl),
        .SDRAM_CLK  (clk_sdram),
        .RESET_N    (rst_n & pll_locked_i),  // 等 SDRAM PLL 锁定后再放行控制器

        .WR1_DATA   (wr1_data),
        .WR1        (wr1_req),
        .WR1_ADDR   (wr1_addr),
        .WR1_MAX_ADDR(wr1_max_addr),
        .WR1_LENGTH (wr1_length),
        .WR1_LOAD   (wr1_load),
        .WR1_CLK    (wr1_clk),
        .WR1_FULL   (wr1_full),
        .WR1_USE    (wr1_use),

        .WR2_DATA   (wr2_data),
        .WR2        (wr2_req),
        .WR2_ADDR   (wr2_addr),
        .WR2_MAX_ADDR(wr2_max_addr),
        .WR2_LENGTH (wr2_length[8:0]),
        .WR2_LOAD   (wr2_load),
        .WR2_CLK    (wr2_clk),
        .WR2_FULL   (wr2_full),
        .WR2_USE    (wr2_use),

        .RD1_DATA   (rd1_data),
        .RD1        (rd1_req),
        .RD1_ADDR   (rd1_addr),
        .RD1_MAX_ADDR(rd1_max_addr),
        .RD1_LENGTH (rd1_length),
        .RD1_LOAD   (rd1_load),
        .RD1_CLK    (rd1_clk),
        .RD1_EMPTY  (rd1_empty),
        .RD1_USE    (rd1_use),

        .RD2_DATA   (rd2_data),
        .RD2        (rd2_req),
        .RD2_ADDR   (rd2_addr),
        .RD2_MAX_ADDR(rd2_max_addr),
        .RD2_LENGTH (rd2_length[8:0]),
        .RD2_LOAD   (rd2_load),
        .RD2_CLK    (rd2_clk),
        .RD2_EMPTY  (rd2_empty),
        .RD2_USE    (rd2_use)
    );

endmodule
