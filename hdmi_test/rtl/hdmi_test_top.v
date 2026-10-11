//=============================================================================
// hdmi_test_top.v  —  SDRAM 帧缓冲上板顶层（Phase 6）
//-----------------------------------------------------------------------------
// 数据流：
//   clk_50m ─► stub_source(假数据源,带帧标记) ─► fb_mgr 写侧 ─► sdram_ctrl_wrap(WR1/WR2)
//                                                        SDRAM(片内 8MB)
//   clk_pix ─► video_timing_720p ─► fb_mgr 读侧(RD1/RD2) ─► hdmi_tx_wrap ─► 显示器
//                                   ▲
//                        fallback = test_pattern（帧缓冲未就绪时显示）
//
// 双缓冲：fb_mgr 内部 front/wr_buf 换班，只在垂直消隐期切换。
//
// 时钟：
//   clk_pix  75MHz   像素域（HDMI）        —— clk_gen(tx_pll)
//   clk_pix5x 375MHz TMDS 位时钟           —— clk_gen
//   clk_sdr_ctrl 100MHz  SDRAM 控制器      —— sdram_pll
//   clk_sdram 100MHz@90° SDRAM 器件时钟     —— sdram_pll
//
// 引脚见 constraints/hdmi_test.adc（SDRAM 为片内硬核，不占外部引脚）。
//=============================================================================
`timescale 1ns / 1ps

module hdmi_test_top #(
    parameter USE_FB = 1  // 1=显示帧缓冲(内存里的图)；0=只显示测试图(隔离 HDMI/时序问题)
)(
    input  wire        clk_50m,        // R7  50MHz
    input  wire        rst_n_in,       // A9  SW0，低有效

    output wire        hdmi_clk_p,     // P1
    output wire        hdmi_d0_p,      // N1
    output wire        hdmi_d1_p,      // P4
    output wire        hdmi_d2_p,      // J3

    output wire [7:0]  led             // B14..F16
);

    //-------------------------------------------------------------------
    // 1) HDMI 时钟（像素 75MHz / 位 375MHz / 辅助 25MHz）
    //-------------------------------------------------------------------
    wire clk_pix, clk_pix5x, clk_25m, hdmi_pll_locked;
    clk_gen u_clk_gen (
        .clk_50m    (clk_50m),
        .areset     (~rst_n_in),
        .clk_pix    (clk_pix),
        .clk_pix5x  (clk_pix5x),
        .clk_25m    (clk_25m),
        .pll_locked (hdmi_pll_locked)
    );

    //-------------------------------------------------------------------
    // 2) SDRAM 控制器（内含 sdram 硬核 + sdram_pll）
    //-------------------------------------------------------------------
    wire        clk_sdr_ctrl, clk_sdram, sdr_pll_locked;
    wire [15:0] wr1_data, wr2_data, rd1_data, rd2_data;
    wire [20:0] wr1_addr, wr1_max, wr2_addr, wr2_max;
    wire [20:0] rd1_addr, rd1_max, rd2_addr, rd2_max;
    wire [9:0]  wr1_len, wr2_len, rd1_len, rd2_len;
    wire        wr1_req, wr2_req, wr1_load, wr2_load, wr1_full, wr2_full;
    wire        rd1_req, rd2_req, rd1_load, rd2_load, rd1_empty, rd2_empty;

    sdram_ctrl_wrap u_sdram_ctrl (
        .clk_50m (clk_50m),
        .rst_n   (rst_n_in),            // PLL 复位只接 rst_n_in（避免自锁死）

        .wr1_data(wr1_data), .wr1_req(wr1_req), .wr1_addr(wr1_addr), .wr1_max_addr(wr1_max),
        .wr1_length(wr1_len), .wr1_load(wr1_load), .wr1_clk(clk_50m), .wr1_full(wr1_full), .wr1_use(),
        .wr2_data(wr2_data), .wr2_req(wr2_req), .wr2_addr(wr2_addr), .wr2_max_addr(wr2_max),
        .wr2_length(wr2_len), .wr2_load(wr2_load), .wr2_clk(clk_50m), .wr2_full(wr2_full), .wr2_use(),
        .rd1_data(rd1_data), .rd1_req(rd1_req), .rd1_addr(rd1_addr), .rd1_max_addr(rd1_max),
        .rd1_length(rd1_len), .rd1_load(rd1_load), .rd1_clk(clk_pix), .rd1_empty(rd1_empty), .rd1_use(),
        .rd2_data(rd2_data), .rd2_req(rd2_req), .rd2_addr(rd2_addr), .rd2_max_addr(rd2_max),
        .rd2_length(rd2_len), .rd2_load(rd2_load), .rd2_clk(clk_pix), .rd2_empty(rd2_empty), .rd2_use(),

        .clk_sdr_ctrl(clk_sdr_ctrl), .clk_sdram(clk_sdram), .pll_locked(sdr_pll_locked)
    );

    //-------------------------------------------------------------------
    // 3) 复位（异步拉低、同步释放）
    //-------------------------------------------------------------------
    wire rst_sys_n, rst_pix_n;
    reset_sync u_rst_sys (.clk(clk_50m), .arst_n(rst_n_in & sdr_pll_locked), .rst_n(rst_sys_n));
    reset_sync u_rst_pix (.clk(clk_pix), .arst_n(rst_n_in & hdmi_pll_locked), .rst_n(rst_pix_n));

    //-------------------------------------------------------------------
    // 4) 720p 视频时序
    //-------------------------------------------------------------------
    wire        hs, vs, de;
    wire [10:0] x, y;
    wire        frame_start;

    video_timing_720p u_timing (
        .clk_pix    (clk_pix),
        .rst_n      (rst_pix_n),
        .hs         (hs),
        .vs         (vs),
        .de         (de),
        .x          (x),
        .y          (y),
        .frame_start(frame_start),
        .line_start ()
    );

    //-------------------------------------------------------------------
    // 5) 图像源：假数据源（带帧标记，便于观察换班）
    //-------------------------------------------------------------------
    wire        px_we, frame_done, wr_stall;
    wire [10:0] px_x, px_y;
    wire [15:0] px_pix;
    reg  [7:0]  stub_fid;

    always @(posedge clk_50m or negedge rst_sys_n) begin
        if (!rst_sys_n)     stub_fid <= 8'd0;
        else if (frame_done) stub_fid <= stub_fid + 1'b1;
    end

    stub_source #(.W(1280), .H(720), .MARK(0), .PACE(1)) u_stub (
        .clk       (clk_50m),
        .rst_n     (rst_sys_n),
        .stall     (wr_stall),
        .frame_id  (stub_fid),
        .px_we     (px_we),
        .px_x      (px_x),
        .px_y      (px_y),
        .px_pix    (px_pix),
        .frame_done(frame_done)
    );

    // 帧缓冲未就绪时的回退画面（测试图）
    wire [15:0] tp_rgb;
    test_pattern u_tp (
        .clk_pix (clk_pix),
        .rst_n   (rst_pix_n),
        .de      (de),
        .x       (x),
        .y       (y),
        .rgb     (tp_rgb)
    );

    //-------------------------------------------------------------------
    // 6) 帧缓冲管家（写侧 50M 域 + 读侧像素域 + 双缓冲换班）
    //-------------------------------------------------------------------
    wire [15:0] rgb_o;
    wire        de_o, hs_o, vs_o, underrun, front_o, buf_ready_o;

    fb_mgr #(.W(1280), .H(720)) u_fb (
        .clk_wr   (clk_50m),
        .rst_n_wr (rst_sys_n),
        .px_we    (px_we),
        .px_x     (px_x),
        .px_y     (px_y),
        .px_pix   (px_pix),
        .frame_done(frame_done),
        .wr_stall (wr_stall),

        .wr1_data    (wr1_data), .wr1_req(wr1_req), .wr1_addr(wr1_addr),
        .wr1_max_addr(wr1_max), .wr1_length(wr1_len), .wr1_load(wr1_load),
        .wr1_clk(), .wr1_full(wr1_full),
        .wr2_data    (wr2_data), .wr2_req(wr2_req), .wr2_addr(wr2_addr),
        .wr2_max_addr(wr2_max), .wr2_length(wr2_len), .wr2_load(wr2_load),
        .wr2_clk(), .wr2_full(wr2_full),

        .clk_pix  (clk_pix),
        .rst_n_pix(rst_pix_n),
        .de_i     (de),
        .hs_i     (hs),
        .vs_i     (vs),
        .frame_start(frame_start),
        .fallback_rgb(tp_rgb),

        .rd1_data (rd1_data), .rd1_empty(rd1_empty), .rd1_req(rd1_req),
        .rd1_addr (rd1_addr), .rd1_max_addr(rd1_max), .rd1_length(rd1_len),
        .rd1_load (rd1_load), .rd1_clk(),
        .rd2_data (rd2_data), .rd2_empty(rd2_empty), .rd2_req(rd2_req),
        .rd2_addr (rd2_addr), .rd2_max_addr(rd2_max), .rd2_length(rd2_len),
        .rd2_load (rd2_load), .rd2_clk(),

        .rgb_o       (rgb_o),
        .de_o        (de_o),
        .hs_o        (hs_o),
        .vs_o        (vs_o),
        .underrun    (underrun),
        .front_o     (front_o),
        .buf_ready_o (buf_ready_o)
    );

    //-------------------------------------------------------------------
    // 7) HDMI 输出（软 TMDS）
    //-------------------------------------------------------------------
    hdmi_tx_wrap u_hdmi (
        .clk_pix    (clk_pix),
        .clk_pix5x  (clk_pix5x),
        .rst_n      (rst_pix_n),
        .hs_i       (hs_o),
        .vs_i       (vs_o),
        .de_i       (de_o),
        .rgb565     (USE_FB ? rgb_o : tp_rgb),   // USE_FB=0 时直接显示测试图（隔离诊断）
        .hdmi_clk_p (hdmi_clk_p),
        .hdmi_d0_p  (hdmi_d0_p),
        .hdmi_d1_p  (hdmi_d1_p),
        .hdmi_d2_p  (hdmi_d2_p)
    );

    //-------------------------------------------------------------------
    // 8) 状态指示
    //-------------------------------------------------------------------
    // 欠载锁存：一旦发生读 FIFO 欠载就常亮（诊断用）
    reg ur_flag;
    always @(posedge clk_pix or negedge rst_pix_n) begin
        if (!rst_pix_n)     ur_flag <= 1'b0;
        else if (underrun)  ur_flag <= 1'b1;
    end

    assign led[0] = hdmi_pll_locked;              // HDMI PLL 锁定
    assign led[1] = sdr_pll_locked;               // SDRAM PLL 锁定
    assign led[2] = buf_ready_o;                  // 帧缓冲就绪
    assign led[3] = front_o;                      // 当前前台(0=A 1=B)
    assign led[4] = frame_done;                   // 写入一帧结束脉冲
    assign led[5] = wr_stall;                     // 上游被反压
    assign led[6] = ur_flag;                      // ← 曾发生读欠载（常亮）
    assign led[7] = hdmi_pll_locked & sdr_pll_locked;

    // synthesis translate_off
    wire _unused = &{1'b0, clk_25m};
    // synthesis translate_on

endmodule
