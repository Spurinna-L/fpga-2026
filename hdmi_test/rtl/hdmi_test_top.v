//=============================================================================
// hdmi_test_top.v  —  HDMI 输出极简 bring-up 顶层（里程碑 M1）
//-----------------------------------------------------------------------------
// 目的：最小化链路，把自研 720p 时序 + 测试图，经软 TMDS 送上 HDMI 显示器。
//   只包含： 时钟(PLL) → 复位同步 → 720p 时序 → 测试图 → HDMI 编码。
//   不包含： SD / FAT32 / 解码 / SDRAM / OSD / 转场 / 音频（后续再并入完整 top）。
//
// 数据流：
//   clk_50m(R7) ─► clk_gen(tx_pll) ─┬─ clk_pix  75MHz  ─► video_timing_720p ─┐
//                                   └─ clk_pix5x 375MHz ───────────────┐      │
//                                                                     ▼      ▼
//                                            (de,x,y) ─► test_pattern ─► rgb565
//                                                                    │
//                                                    hdmi_tx_wrap ───┘──► 4 对 LVDS
//
// 引脚（与 constraints/hdmi_test.adc 对应）：
//   clk_50m=R7  rst_n_in=A9  led=B14
//   HDMI: CLK_P=P1  D0_P=N1  D1_P=P4  D2_P=J3 （LVDS33）
//=============================================================================
`timescale 1ns / 1ps

module hdmi_test_top (
    input  wire clk_50m,        // R7  板载 50MHz 有源晶振
    input  wire rst_n_in,       // A9  SW0，低有效复位

    output wire hdmi_clk_p,     // P1
    output wire hdmi_d0_p,      // N1
    output wire hdmi_d1_p,      // P4
    output wire hdmi_d2_p,      // J3

    output wire led             // B14  状态指示：PLL 锁定
);

    //-------------------------------------------------------------------------
    // 时钟：像素 75MHz / TMDS 位时钟 375MHz / 辅助 25MHz
    //   tx_pll: C0=25MHz, C1=75MHz, C2=375MHz
    //-------------------------------------------------------------------------
    wire clk_pix, clk_pix5x, clk_25m, pll_locked;

    clk_gen u_clk_gen (
        .clk_50m    (clk_50m),
        .areset     (~rst_n_in),    // PLL 复位为高有效
        .clk_pix    (clk_pix),      // 75MHz
        .clk_pix5x  (clk_pix5x),    // 375MHz
        .clk_25m    (clk_25m),      // 25MHz（本工程未使用）
        .pll_locked (pll_locked)
    );

    //-------------------------------------------------------------------------
    // 像素域复位：异步拉低、同步释放；并等待 PLL 锁定后才放行
    //-------------------------------------------------------------------------
    wire rst_pix_sync_n;
    reset_sync u_rst_pix (
        .clk    (clk_pix),
        .arst_n (rst_n_in),
        .rst_n  (rst_pix_sync_n)
    );

    wire rst_pix_n = rst_pix_sync_n & pll_locked;   // 未锁定前保持复位

    //-------------------------------------------------------------------------
    // 720p 视频时序（时间基准）
    //-------------------------------------------------------------------------
    wire        hs, vs, de;
    wire [10:0] x, y;

    video_timing_720p u_timing (
        .clk_pix    (clk_pix),
        .rst_n      (rst_pix_n),
        .hs         (hs),
        .vs         (vs),
        .de         (de),
        .x          (x),
        .y          (y),
        .frame_start(),             // 本极简工程未使用
        .line_start ()
    );

    //-------------------------------------------------------------------------
    // 测试图：彩条 + 移动红方块 + 白边框
    //-------------------------------------------------------------------------
    wire [15:0] rgb565;

    test_pattern u_test_pattern (
        .clk_pix (clk_pix),
        .rst_n   (rst_pix_n),
        .de      (de),
        .x       (x),
        .y       (y),
        .rgb     (rgb565)
    );

    //-------------------------------------------------------------------------
    // HDMI 输出（软 TMDS，黑盒加密 IP）
    //-------------------------------------------------------------------------
    hdmi_tx_wrap u_hdmi (
        .clk_pix    (clk_pix),
        .clk_pix5x  (clk_pix5x),
        .rst_n      (rst_pix_n),
        .hs_i       (hs),
        .vs_i       (vs),
        .de_i       (de),
        .rgb565     (rgb565),
        .hdmi_clk_p (hdmi_clk_p),
        .hdmi_d0_p  (hdmi_d0_p),
        .hdmi_d1_p  (hdmi_d1_p),
        .hdmi_d2_p  (hdmi_d2_p)
    );

    //-------------------------------------------------------------------------
    // 状态指示：PLL 锁定则亮
    //-------------------------------------------------------------------------
    assign led = pll_locked;

    // synthesis translate_off
    wire _unused = &{1'b0, clk_25m};
    // synthesis translate_on

endmodule
