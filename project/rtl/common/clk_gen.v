//=============================================================================
// clk_gen.v  —  时钟生成（像素时钟 / 5x 位时钟 / 25M 辅助时钟 / 控制时钟）
//-----------------------------------------------------------------------------
// 【重要】本工程当前例化的 tx_pll 是从官方 1280x1024 例程拷来的：
//          C0=25MHz, C1=107.5MHz, C2=537.5MHz。
//   720p@60 需要：C0=25MHz, C1=74.25MHz（0°）, C2=371.25MHz（0°）。
//   => 必须用 TD 的 IP 生成器重建 PLL（FIN=50MHz，保持 FEEDBK_PATH=CLKC0_EXT），
//      并用导出的 ip/hdmi/tx_pll.v 覆盖本目录同名文件。这是第 1 周的首要任务。
//
// 参考 HDMI：pixel clk = 74.25MHz；TMDS 位时钟 = 5x = 371.25MHz（DDR 串行化）。
// ---------------------------------------------------------------------------
// 【SDRAM 时钟尚未并入本模块】：SDRAM 控制器时钟需与片内 SDRAM 相位对齐，
//   将随 `sdram_ctrl_wrap` 一并在后续接入独立的 SDRAM_PLL。
//=============================================================================
`timescale 1ns / 1ps

module clk_gen (
    input  wire clk_50m,        // 板载 50MHz（R7）
    input  wire areset,         // 高有效异步复位（PLL 复位用）
    output wire clk_pix,        // 像素时钟 74.25MHz（目标）
    output wire clk_pix5x,      // TMDS 位时钟 371.25MHz（目标）
    output wire clk_25m,        // 辅助时钟（闪灯 / 慢速逻辑）
    output wire pll_locked
);

    // 官方结构：clk0->C0, clk1->C1, clk2->C2，PLL 锁定输出 extlock
    tx_pll u_tx_pll (
        .refclk   (clk_50m),
        .reset    (areset),
        .extlock  (pll_locked),
        .clk0_out (clk_25m),
        .clk1_out (clk_pix),
        .clk2_out (clk_pix5x)
    );

endmodule
