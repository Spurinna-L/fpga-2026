//=============================================================================
// top_tf_hdmi_audio.v — 基础通路 v1（TF 卡 BMP + HDMI 1.4b 音视频）
//-----------------------------------------------------------------------------
// 目标（M0/M1 基础通路）：
//   TF 卡 → SPI → FAT32/BMP → SDRAM 双缓冲 → 640×480 时序
//          → AXIS → HDMI 1.4b 核（内嵌 48kHz 测试音）→ PHY → 显示器
//
// 说明：
//   - 本文件从官方 lab_ex5_i2s 的 top 改造，适配我们板（无 DDC/EDID）
//   - 音频：内部音阶测试音（满足赛题基础要求③）
//   - 显示：640×480@60，RGB888，VIC=1
//   - 按键：4×4 矩阵（key_deb[0]=下一张，key_deb[1]=自动轮播）
//   - 数码管：显示 sd_card_bmp 的 state_code
//=============================================================================
`timescale 1ns / 1ps

module top(
    input  wire        clk,           // R7 50MHz
    input  wire        rst_n,         // A9 SW0

    // HDMI（本板无 DDC）
    output wire        HDMI_CLK_P,    // P1
    output wire        HDMI_D2_P,     // J3
    output wire        HDMI_D1_P,     // P4
    output wire        HDMI_D0_P,     // N1

    // TF 卡 SPI
    output wire        sd_ncs,        // F13
    output wire        sd_dclk,       // F15
    output wire        sd_mosi,       // F14
    input  wire        sd_miso,       // D14

    // 4×4 矩阵键盘
    output wire [3:0]  kb_row,        // D9/F9/C10/E10
    input  wire [3:0]  kb_col,        // E11/D11/C11/F10

    // 4 位数码管
    output wire [3:0]  seg_sel,       // C9/B6/A5/A3
    output wire [7:0]  seg_led,       // A4/A6/B8/E8/A7/B5/A8/C8

    // 8 位 LED
    output wire [7:0]  led,           // B14/B15/B16/C15/C16/E13/E16/F16

    // 音频备份（本版接 0；主线走 HDMI）
    output wire        audio_pwm      // F3
);

    //-------------------------------------------------------------------------
    // 参数
    //-------------------------------------------------------------------------
    localparam [20:0] FRAME_PIXELS = 21'd307200;   // 640×480
    localparam [20:0] BUF0_ADDR    = 21'd0;
    localparam [20:0] BUF1_ADDR    = FRAME_PIXELS;

    //-------------------------------------------------------------------------
    // 时钟与复位
    //-------------------------------------------------------------------------
    wire sd_card_clk;
    wire ext_mem_clk;
    wire ext_mem_clk_sft;
    wire video_clk;
    wire hdmi_5x_clk;
    wire audio_mclk;
    wire audio_pll_lock;

    sys_pll u_sys_pll (
        .refclk   (clk),
        .reset    (1'b0),
        .clk0_out (sd_card_clk),
        .clk1_out (ext_mem_clk),
        .clk2_out (ext_mem_clk_sft)
    );

    video_pll u_video_pll (
        .refclk   (clk),
        .reset    (1'b0),
        .clk0_out (video_clk),
        .clk1_out (hdmi_5x_clk)
    );

    PLL_HDMI_AUDIO u_audio_pll (
        .refclk   (clk),
        .reset    (1'b0),
        .extlock  (audio_pll_lock),
        .clk0_out (),
        .clk1_out (),
        .clk2_out (audio_mclk)
    );

    // POR：等音频 PLL 锁定 + 约 1.3ms 计数，再释放复位
    reg [15:0] por_cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            por_cnt <= 16'd0;
        else if (!audio_pll_lock)
            por_cnt <= 16'd0;
        else if (por_cnt != 16'hFFFF)
            por_cnt <= por_cnt + 1'b1;
    end
    wire por_done = (por_cnt == 16'hFFFF);
    wire rst_all  = ~rst_n | ~por_done;

    //-------------------------------------------------------------------------
    // 键盘：4×4 矩阵 → 消抖 → key1/key2
    //-------------------------------------------------------------------------
    wire [15:0] key_raw;
    wire [15:0] key_deb;

    keyboard_scan u_kb (
        .clk  (clk),
        .RSTn (rst_n),
        .col  (kb_col),
        .row  (kb_row),
        .key  (key_raw)
    );

    key_filter u_kf (
        .clk    (clk),
        .rstn   (rst_n),
        .key_in (key_raw),
        .key_deb(key_deb)
    );

    wire key_next = key_deb[0];   // 矩阵第 4 行第 1 列
    wire key_auto = key_deb[1];   // 矩阵第 4 行第 2 列

    //-------------------------------------------------------------------------
    // SD / FAT32 / BMP / 双缓冲
    //-------------------------------------------------------------------------
    wire        display_valid;
    wire [3:0]  state_code;
    wire [1:0]  write_buf_idx;
    wire [1:0]  disp_buf_idx;

    wire        sd_write_req;
    wire        sd_write_req_ack;
    wire        sd_write_en;
    wire [31:0] sd_write_data;

    wire        frame_write_finish;
    reg         frame_write_toggle_mem;

    always @(posedge ext_mem_clk or posedge rst_all) begin
        if (rst_all)
            frame_write_toggle_mem <= 1'b0;
        else if (frame_write_finish)
            frame_write_toggle_mem <= ~frame_write_toggle_mem;
    end

    sd_card_bmp #(
        .CLK_FREQ_HZ       (100_000_000),
        .SCAN_START_SECTOR (32'd0),
        .SCAN_MAX_SECTOR   (32'd131071),
        .SCAN_TARGET_COUNT (3'd4)
    ) u_sd_bmp (
        .clk               (sd_card_clk),
        .rst               (rst_all),
        .key_next          (key_next),
        .key_auto          (key_auto),
        .state_code        (state_code),
        .bmp_width         (16'd640),
        .bmp_height        (16'd480),
        .display_valid     (display_valid),
        .write_finish_toggle(frame_write_toggle_mem),
        .write_buf_idx     (write_buf_idx),
        .disp_buf_idx      (disp_buf_idx),
        .write_req         (sd_write_req),
        .write_req_ack     (sd_write_req_ack),
        .write_en          (sd_write_en),
        .write_data        (sd_write_data),
        .SD_nCS            (sd_ncs),
        .SD_DCLK           (sd_dclk),
        .SD_MOSI           (sd_mosi),
        .SD_MISO           (sd_miso)
    );

    //-------------------------------------------------------------------------
    // 视频时序 / 帧缓存读
    //-------------------------------------------------------------------------
    wire        hs_0, vs_0, de_0;
    wire        video_read_req;
    wire        video_read_req_ack;
    wire        video_read_en;
    wire [31:0] video_read_data;
    wire        hs, vs, de;
    wire [23:0] vout_data_raw;
    wire [23:0] vout_data;

    video_timing_data u_timing (
        .video_clk    (video_clk),
        .rst          (rst_all),
        .read_req     (video_read_req),
        .read_req_ack (video_read_req_ack),
        .hs           (hs_0),
        .vs           (vs_0),
        .de           (de_0)
    );

    video_delay u_delay (
        .video_clk (video_clk),
        .rst       (rst_all),
        .read_en   (video_read_en),
        .read_data (video_read_data[31:8]),
        .hs        (hs_0),
        .vs        (vs_0),
        .de        (de_0),
        .hs_r      (hs),
        .vs_r      (vs),
        .de_r      (de),
        .vout_data (vout_data_raw)
    );

    // 无图时输出彩条（诊断：有彩条=HDMI 链路 OK，问题在 SD/BMP）
    wire [23:0] test_rgb;
    test_pattern_640x480 u_test_pattern (
        .clk (video_clk),
        .rst (rst_all),
        .vs  (vs),
        .de  (de),
        .rgb (test_rgb)
    );

    assign vout_data = display_valid ? vout_data_raw : test_rgb;

    //-------------------------------------------------------------------------
    // 帧缓存（官方单读口；M2 再换 4 端口双读做 A/B 溶解）
    //-------------------------------------------------------------------------
    wire        App_rd_en;
    wire [20:0] App_rd_addr;
    wire        Sdr_rd_en;
    wire [31:0] Sdr_rd_dout;
    wire        App_wr_en;
    wire [20:0] App_wr_addr;
    wire [31:0] App_wr_din;
    wire [3:0]  App_wr_dm;

    wire Sdr_init_done;
    wire Sdr_init_ref_vld;
    wire Sdr_busy;

    frame_read_write #(
        .WRITE_V_FLIP  (1),
        .FRAME_WIDTH   (640),
        .FRAME_HEIGHT  (480)
    ) u_fb (
        .mem_clk          (ext_mem_clk),
        .rst              (rst_all),
        .Sdr_init_done    (Sdr_init_done),
        .Sdr_init_ref_vld (Sdr_init_ref_vld),
        .Sdr_busy         (Sdr_busy),
        .App_rd_en        (App_rd_en),
        .App_rd_addr      (App_rd_addr),
        .Sdr_rd_en        (Sdr_rd_en),
        .Sdr_rd_dout      (Sdr_rd_dout),
        .read_clk         (video_clk),
        .read_req         (video_read_req),
        .read_req_ack     (video_read_req_ack),
        .read_finish      (),
        .read_addr_0      (BUF0_ADDR),
        .read_addr_1      (BUF1_ADDR),
        .read_addr_2      (21'd0),
        .read_addr_3      (21'd0),
        .read_addr_index  (disp_buf_idx),
        .read_len         (FRAME_PIXELS),
        .read_en          (video_read_en),
        .read_data        (video_read_data),
        .App_wr_en        (App_wr_en),
        .App_wr_addr      (App_wr_addr),
        .App_wr_din       (App_wr_din),
        .App_wr_dm        (App_wr_dm),
        .write_clk        (sd_card_clk),
        .write_req        (sd_write_req),
        .write_req_ack    (sd_write_req_ack),
        .write_finish     (frame_write_finish),
        .write_addr_0     (BUF0_ADDR),
        .write_addr_1     (BUF1_ADDR),
        .write_addr_2     (21'd0),
        .write_addr_3     (21'd0),
        .write_addr_index (write_buf_idx),
        .write_len        (FRAME_PIXELS),
        .write_en         (sd_write_en),
        .write_data       (sd_write_data)
    );

    sdram u_sdram (
        .Clk              (ext_mem_clk),
        .Clk_sft          (ext_mem_clk_sft),
        .Rst              (rst_all),
        .Sdr_init_done    (Sdr_init_done),
        .Sdr_init_ref_vld (Sdr_init_ref_vld),
        .Sdr_busy         (Sdr_busy),
        .App_wr_en        (App_wr_en),
        .App_wr_addr      (App_wr_addr),
        .App_wr_dm        (App_wr_dm),
        .App_wr_din       (App_wr_din),
        .App_rd_en        (App_rd_en),
        .App_rd_addr      (App_rd_addr),
        .Sdr_rd_en        (Sdr_rd_en),
        .Sdr_rd_dout      (Sdr_rd_dout)
    );

    //-------------------------------------------------------------------------
    // RGB/DE/VS → AXIS
    //-------------------------------------------------------------------------
    wire        axis_s_user;
    wire        axis_s_valid;
    wire        axis_s_last;
    wire [23:0] axis_s_data;
    wire        axis_s_ready;

    video_rgb_to_axis_640x480 u_axis (
        .I_clk         (video_clk),
        .I_rst         (rst_all),
        .I_vs          (vs),
        .I_de          (de),
        .I_rgb         (vout_data),
        .O_video_user  (axis_s_user),
        .O_video_valid (axis_s_valid),
        .O_video_last  (axis_s_last),
        .O_video_data  (axis_s_data)
    );

    //-------------------------------------------------------------------------
    // 音频：内部音阶测试音 → I2S 解串 → PCM + ACR
    //-------------------------------------------------------------------------
    wire        audio_i2s_bclk;
    wire        audio_i2s_lrck;
    wire        audio_i2s_dout;
    wire        audio_valid;
    wire [23:0] audio_left_data;
    wire [23:0] audio_right_data;
    wire        acr_valid;
    wire [19:0] acr_cts;
    wire [19:0] acr_n;

    hdmi_audio_tone_i2s_64fs #(
        .PHASE_INC (32'd39370534),
        .AMP       (24'sd2000000)
    ) u_tone (
        .I_mclk     (audio_mclk),
        .I_rst      (rst_all),
        .O_i2s_BCLK (audio_i2s_bclk),
        .O_i2s_LRCK (audio_i2s_lrck),
        .O_i2s_DOUT (audio_i2s_dout)
    );

    I2S_receiver u_i2s_rx (
        .I_clk              (video_clk),
        .I_rst              (rst_all),
        .I_i2s_BCLK         (audio_i2s_bclk),
        .I_i2s_LRCK         (audio_i2s_lrck),
        .I_i2s_DOUT         (audio_i2s_dout),
        .O_audio_valid      (audio_valid),
        .O_audio_left_data  (audio_left_data),
        .O_audio_right_data (audio_right_data)
    );

    audio_arc_calculate #(
        .ACR_N (6144)
    ) u_acr (
        .I_clk         (video_clk),
        .I_rst         (rst_all),
        .I_audio_valid (audio_valid),
        .O_acr_valid   (acr_valid),
        .O_acr_cts     (acr_cts),
        .O_acr_n       (acr_n)
    );

    //-------------------------------------------------------------------------
    // HDMI 1.4b：视频 + 音频
    //   - 本板无 DDC：I_edid_read_trig = 0
    //   - DDC 引脚接内部线，不引到外部
    //-------------------------------------------------------------------------
    wire [9:0] tmds_ch0_data;
    wire [9:0] tmds_ch1_data;
    wire [9:0] tmds_ch2_data;
    wire [9:0] tmds_clk_data;
    wire       video_locked;
    wire       ddc_scl_unused;
    wire       ddc_sda_unused;

    hdmi_1_4b_transmitter_core_wrapper #(
        .DEVICE            ("EG"),
        .HTOTAL            (800),
        .HSA               (96),
        .HFP               (16),
        .HBP               (48),
        .HACTIVE           (640),
        .VTOTAL            (525),
        .VSA               (2),
        .VFP               (10),
        .VBP               (33),
        .VACTIVE           (480),
        .VIDEO_VIC         (1),
        .VIDEO_TPG         ("Disable"),
        .VIDEO_FORMAT      ("RGB"),
        .AUDIO_SAMPLE_RATE ("48K"),
        .IIC_SCL_DIV       (250)
    ) u_hdmi (
        .I_pixel_clk       (video_clk),
        .I_rst             (rst_all),
        .I_edid_read_trig  (1'b0),
        .O_edid_read_valid (),
        .O_edid_read_data  (),
        .I_axis_s_user     (axis_s_user),
        .I_axis_s_valid    (axis_s_valid),
        .I_axis_s_last     (axis_s_last),
        .I_axis_s_data     (axis_s_data),
        .O_axis_s_ready    (axis_s_ready),
        .I_audio_valid     (audio_valid),
        .I_audio_left_data (audio_left_data),
        .I_audio_right_data(audio_right_data),
        .I_acr_valid       (acr_valid),
        .I_acr_cts         (acr_cts),
        .I_acr_n           (acr_n),
        .O_video_locked    (video_locked),
        .O_ddc_scl         (ddc_scl_unused),
        .IO_ddc_sda        (ddc_sda_unused),
        .O_ch0_tmds_data   (tmds_ch0_data),
        .O_ch1_tmds_data   (tmds_ch1_data),
        .O_ch2_tmds_data   (tmds_ch2_data),
        .O_clk_tmds_data   (tmds_clk_data)
    );

    hdmi_phy_wrapper #(
        .DEVICE ("EG")
    ) u_hdmi_phy (
        .I_pixel_clk        (video_clk),
        .I_serial_clk       (hdmi_5x_clk),
        .I_rst              (rst_all),
        .I_tmds_channel_0   (tmds_ch0_data),
        .I_tmds_channel_1   (tmds_ch1_data),
        .I_tmds_channel_2   (tmds_ch2_data),
        .I_tmds_channel_clk (tmds_clk_data),
        .O_tmds_ch0_p       (HDMI_D0_P),
        .O_tmds_ch1_p       (HDMI_D1_P),
        .O_tmds_ch2_p       (HDMI_D2_P),
        .O_tmds_clk_p       (HDMI_CLK_P)
    );

    //-------------------------------------------------------------------------
    // 数码管 / LED
    //-------------------------------------------------------------------------
    seg_led u_seg (
        .clk     (clk),
        .rst_n   (rst_n),
        .value   ({28'h0000000, state_code}),
        .dot     (4'b0000),
        .seg_sel (seg_sel),
        .seg_led (seg_led)
    );

    assign led[0] = audio_pll_lock;
    assign led[1] = Sdr_init_done;
    assign led[2] = display_valid;
    assign led[3] = disp_buf_idx[0];
    assign led[4] = frame_write_finish;
    assign led[5] = write_buf_idx[0];
    assign led[6] = video_locked;
    assign led[7] = 1'b1;

    assign audio_pwm = 1'b0;

endmodule
