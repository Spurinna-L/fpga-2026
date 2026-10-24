//=============================================================================
// sdram_ctrl_wrap.v  —  片内 SDRAM 帧缓存控制器封装
//-----------------------------------------------------------------------------
// 复用：rtl/reuse/sdram/ 下的 Sdram_Control_4Port（经典 4 端口 FIFO 控制器）
//       + sdram.v（EG_PHY_SDRAM_2M_32 硬核）+ sdram_pll.v（100M / 100M@90°）。
// 数据宽度：DSIZE=16（1 word = 16bit，可容纳 1 个 RGB565 像素）。
// 地址宽度：ASIZE=21，地址组成 {bank[1:0], row[10:0], col[8:0]}（由 Sdram_Params.h 定义）。
//
// 端口分配建议（见 doc/框架说明.md §存储映射）：
//   WR1 / RD1 : 前台帧缓冲 A（解码器写入 / 扫描读出）
//   WR2 / RD2 : 后台帧缓冲 B（转场 / 预解码）
//   音频环形缓冲、媒体索引用独立小容量区，可复用 RD2 时分或扩展端口。
//
// 【后续】SDRAM 时钟 PLL（sdram_pll）为 100MHz；如后续升级 133/166/200MHz，
//   需在 TD 中重建 PLL 并同步更新 Sdram_Params.h 的 SC_* 参数。
//=============================================================================
`timescale 1ns / 1ps

module sdram_ctrl_wrap #(
    parameter ASIZE = 21,
    parameter DSIZE = 16
)(
    input  wire              clk_50m,       // 板载 50MHz
    input  wire              rst_n,         // 低有效复位

    // ---- FIFO Write Side 1（前台帧缓冲写） ----
    input  wire [DSIZE-1:0]  wr1_data,
    input  wire              wr1_req,
    input  wire [ASIZE-1:0]  wr1_addr,
    input  wire [ASIZE-1:0]  wr1_max_addr,
    input  wire [9:0]        wr1_length,
    input  wire              wr1_load,
    input  wire              wr1_clk,
    output wire              wr1_full,
    output wire [15:0]       wr1_use,

    // ---- FIFO Write Side 2（后台帧缓冲写） ----
    input  wire [DSIZE-1:0]  wr2_data,
    input  wire              wr2_req,
    input  wire [ASIZE-1:0]  wr2_addr,
    input  wire [ASIZE-1:0]  wr2_max_addr,
    input  wire [9:0]        wr2_length,
    input  wire              wr2_load,
    input  wire              wr2_clk,
    output wire              wr2_full,
    output wire [15:0]       wr2_use,

    // ---- FIFO Read Side 1（前台帧缓冲读 / 扫描输出） ----
    output wire [DSIZE-1:0]  rd1_data,
    input  wire              rd1_req,
    input  wire [ASIZE-1:0]  rd1_addr,
    input  wire [ASIZE-1:0]  rd1_max_addr,
    input  wire [9:0]        rd1_length,
    input  wire              rd1_load,
    input  wire              rd1_clk,
    output wire              rd1_empty,
    output wire [15:0]       rd1_use,

    // ---- FIFO Read Side 2（后台帧缓冲读 / 转场） ----
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
    output wire              clk_sdr_ctrl,  // 100MHz 控制器时钟
    output wire              clk_sdram,     // 100MHz@90° SDRAM 时钟
    output wire              pll_locked
);

    // SDRAM 时钟：100MHz 控制时钟 + 100MHz 90°相移 DRAM 时钟
    sdram_pll u_sdram_pll (
        .refclk   (clk_50m),
        .reset    (~rst_n),
        .clk0_out (clk_sdr_ctrl),
        .clk1_out (clk_sdram),
        .clk2_out (),
        .clk3_out (),
        .clk4_out ()
    );

    // 锁定信号：ip_pll 未引出 extlock，此处预留（如需可重建 PLL 引出）
    assign pll_locked = 1'b1;

    Sdram_Control_4Port u_sdram_ctrl (
        .CTRL_CLK   (clk_sdr_ctrl),
        .SDRAM_CLK  (clk_sdram),
        .RESET_N    (rst_n),

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
        .WR2_LENGTH (wr2_length),
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
        .RD2_LENGTH (rd2_length),
        .RD2_LOAD   (rd2_load),
        .RD2_CLK    (rd2_clk),
        .RD2_EMPTY  (rd2_empty),
        .RD2_USE    (rd2_use)
    );

endmodule
