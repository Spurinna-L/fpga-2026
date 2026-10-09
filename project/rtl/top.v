//=============================================================================
// top.v  —  系统顶层（智能商业展陈 HDMI 多媒体播放系统）
//-----------------------------------------------------------------------------
// 数据流（详见 项目计划.md §4.1）：
//   SD → sd_ctrl → fat32_reader/media_scan → bmp_decoder/wav_player
//     → SDRAM 帧缓存(fb_mgr/sdram_ctrl_wrap) → 缩放 → 参数处理 → OSD 合成
//     → 转场 → HDMI 软 TMDS 输出；音频 → PWM(F3) → 功放。
//   控制：矩阵键盘 → 消抖 → main_fsm/regs → 各模块 + 数码管/LED。
//
// 当前里程碑 M1：自研 720p 时序 + 测试图 + HDMI 输出已可跑通；
//   帧缓冲/解码/音频/OSD 为骨架，按项目计划逐周填充。
//
// 引脚约束见 constraints/top.adc（取自官方例程 .adc，权威）。
//=============================================================================
`timescale 1ns / 1ps

module top (
    // 时钟与复位
    input  wire        clk_50m,        // R7  50MHz 有源晶振
    input  wire        rst_n_in,       // A9  SW0，低有效复位

    // HDMI（LVDS33 软 TMDS）
    output wire        hdmi_clk_p,     // P1
    output wire        hdmi_d0_p,      // N1
    output wire        hdmi_d1_p,      // P4
    output wire        hdmi_d2_p,      // J3

    // SD 卡（SPI）
    output wire        sd_clk,         // F15
    output wire        sd_cs,          // F13
    output wire        sd_mosi,        // F14
    input  wire        sd_miso,        // D14

    // 音频输出
    output wire        audio_pwm,      // F3 → 低通 + FM8002A 功放

    // 麦克风 ADC（SPI）
    output wire        mic_cs,         // J6
    input  wire        mic_miso,       // K5
    output wire        mic_sck,        // H3
    output wire        mic_rst_n,      // G6

    // 4 位七段数码管
    output wire [3:0]  seg_sel,        // C9,B6,A5,A3
    output wire [7:0]  seg_led,        // A4,A6,B8,E8,A7,B5,A8,C8

    // 4x4 矩阵键盘
    output wire [3:0]  kb_row,         // D9,F9,C10,E10
    input  wire [3:0]  kb_col,         // E11,D11,C11,F10

    // LED 状态
    output wire [7:0]  led             // B14,B15,B16,C15,C16,E13,E16,F16
);

    //-------------------------------------------------------------------------
    // 时钟：像素 74.25MHz / 位时钟 371.25MHz / 辅助 25MHz
    //-------------------------------------------------------------------------
    wire clk_pix, clk_pix5x, clk_25m, pll_locked;
    clk_gen u_clk_gen (
        .clk_50m    (clk_50m),
        .areset     (~rst_n_in),
        .clk_pix    (clk_pix),
        .clk_pix5x  (clk_pix5x),
        .clk_25m    (clk_25m),
        .pll_locked (pll_locked)
    );

    //-------------------------------------------------------------------------
    // 复位（异步拉低、同步释放）
    //-------------------------------------------------------------------------
    wire rst_n;      // 系统 50MHz 域
    wire rst_pix_n;  // 像素域
    reset_sync u_rst_sys (.clk(clk_50m), .arst_n(rst_n_in), .rst_n(rst_n));
    reset_sync u_rst_pix (.clk(clk_pix), .arst_n(rst_n_in), .rst_n(rst_pix_n));


    //-------------------------------------------------------------------------
    // 视频时序（全链路时间基准）
    //-------------------------------------------------------------------------
    wire        hs, vs, de;
    wire [10:0] x, y;
    wire        frame_start, line_start;

    video_timing_720p u_timing (
        .clk_pix    (clk_pix),
        .rst_n      (rst_pix_n),
        .hs         (hs),
        .vs         (vs),
        .de         (de),
        .x          (x),
        .y          (y),
        .frame_start(frame_start),
        .line_start (line_start)
    );

    //-------------------------------------------------------------------------
    // 测试图（M1 回退画面；帧缓冲就绪后由 fb_mgr 切换为真实图像）
    //-------------------------------------------------------------------------
    wire [15:0] tp_rgb;
    test_pattern u_test_pattern (
        .clk_pix (clk_pix),
        .rst_n   (rst_pix_n),
        .de      (de),
        .x       (x),
        .y       (y),
        .rgb     (tp_rgb)
    );

    //-------------------------------------------------------------------------
    // 控制寄存器 + 主控状态机
    //-------------------------------------------------------------------------
    wire [7:0]  reg_brightness, reg_contrast, reg_saturation, reg_audio_volume, reg_media_index;
    wire [1:0]  reg_transition_type;
    wire [2:0]  reg_display_mode;
    wire        reg_osd_en, reg_auto_play;

    regs u_regs (
        .clk            (clk_50m),
        .rst_n          (rst_n),
        .wr_en          (1'b0),                 // TODO: 由键盘事件/OSD 写入
        .wr_addr        (8'd0),
        .wr_data        (32'd0),
        .brightness     (reg_brightness),
        .contrast       (reg_contrast),
        .saturation     (reg_saturation),
        .transition_type(reg_transition_type),
        .audio_volume   (reg_audio_volume),
        .media_index    (reg_media_index),
        .display_mode   (reg_display_mode),
        .osd_en         (reg_osd_en),
        .auto_play      (reg_auto_play)
    );

    // 键盘扫描 + 消抖（系统 50MHz 域）
    wire [15:0] key_raw, key_deb;
    keyboard_scan u_keyboard (
        .clk  (clk_50m),
        .RSTn (rst_n),
        .col  (kb_col),
        .row  (kb_row),
        .key  (key_raw)
    );
    key_filter u_key_filter (
        .clk   (clk_50m),
        .rstn  (rst_n),
        .key_in(key_raw),
        .key_deb(key_deb)
    );

    // 按键事件：低有效 → 同步到像素域 → 下降沿检测为单拍脉冲
    wire [3:0] key_sync;
    cdc_sync #(.WIDTH(4)) u_key_sync (
        .clk_dst  (clk_pix),
        .rst_n_dst(rst_pix_n),
        .d_async  (key_deb[3:0]),
        .q_sync   (key_sync)
    );
    reg [3:0] key_sync_d;
    always @(posedge clk_pix or negedge rst_pix_n) begin
        if (!rst_pix_n) key_sync_d <= 4'hF;
        else            key_sync_d <= key_sync;
    end
    wire ev_next = ~key_sync[0] &  key_sync_d[0];
    wire ev_prev = ~key_sync[1] &  key_sync_d[1];
    wire ev_mode = ~key_sync[2] &  key_sync_d[2];
    wire ev_auto = ~key_sync[3] &  key_sync_d[3];

    // 主控状态机
    wire        scan_start, swap_req, transition_active;
    wire [1:0]  fsm_tmode;
    wire [7:0]  fsm_blend, fsm_media_index;
    wire [2:0]  fsm_state;
    wire        sd_init_done, scan_done, img_ready;

    main_fsm u_main_fsm (
        .clk_pix          (clk_pix),
        .rst_n            (rst_pix_n),
        .frame_start      (frame_start),
        .sd_init_done     (sd_init_done),
        .scan_done        (scan_done),
        .media_count      (8'd8),
        .img_ready        (img_ready),
        .ev_next          (ev_next),
        .ev_prev          (ev_prev),
        .ev_mode          (ev_mode),
        .ev_auto          (ev_auto),
        .scan_start       (scan_start),
        .media_index      (fsm_media_index),
        .swap_req         (swap_req),
        .transition_mode  (fsm_tmode),
        .blend            (fsm_blend),
        .transition_active(transition_active),
        .auto_play        (),
        .state            (fsm_state)
    );

    //-------------------------------------------------------------------------
    // 帧缓冲（SDRAM 双缓冲）——当前回退到测试图
    //-------------------------------------------------------------------------
    wire [15:0] fb_rgb;
    wire [15:0] fb_rd_data;
    wire        fb_rd_req;
    wire [20:0] fb_rd_addr;
    wire        swap_done;

    fb_mgr u_fb_mgr (
        .clk_pix       (clk_pix),
        .rst_n         (rst_pix_n),
        .hs_i          (hs),
        .vs_i          (vs),
        .de_i          (de),
        .x             (x),
        .y             (y),
        .frame_start   (frame_start),
        .fallback_rgb  (tp_rgb),
        .buf_ready     (1'b0),               // TODO: 解码完成后置 1
        .swap_req      (swap_req),
        .swap_done     (swap_done),
        .front_sel     (),
        .sdram_rd_data (fb_rd_data),
        .sdram_rd_req  (fb_rd_req),
        .sdram_rd_addr (fb_rd_addr),
        .dec_we        (1'b0),
        .dec_x         (11'd0),
        .dec_y         (11'd0),
        .dec_data      (16'd0),
        .rgb_o         (fb_rgb)
    );

    // 片内 SDRAM 控制器（4 端口）；当前仅占用 RD1 供扫描读
    sdram_ctrl_wrap u_sdram_ctrl (
        .clk_50m     (clk_50m),
        .rst_n       (rst_n),
        .wr1_data    (16'd0),  .wr1_req(1'b0), .wr1_addr(21'd0), .wr1_max_addr(21'd0),
        .wr1_length  (10'd0),  .wr1_load(1'b0), .wr1_clk(clk_50m), .wr1_full(), .wr1_use(),
        .wr2_data    (16'd0),  .wr2_req(1'b0), .wr2_addr(21'd0), .wr2_max_addr(21'd0),
        .wr2_length  (10'd0),  .wr2_load(1'b0), .wr2_clk(clk_50m), .wr2_full(), .wr2_use(),
        .rd1_data    (fb_rd_data), .rd1_req(fb_rd_req), .rd1_addr(fb_rd_addr),
        .rd1_max_addr(21'h0E1000), .rd1_length(10'd256), .rd1_load(1'b0),
        .rd1_clk     (clk_pix), .rd1_empty(), .rd1_use(),
        .rd2_data    (), .rd2_req(1'b0), .rd2_addr(21'd0), .rd2_max_addr(21'd0),
        .rd2_length  (10'd0), .rd2_load(1'b0), .rd2_clk(clk_pix), .rd2_empty(), .rd2_use(),
        .clk_sdr_ctrl(), .clk_sdram(), .pll_locked()
    );

    //-------------------------------------------------------------------------
    // 视频参数处理（亮度/对比度/饱和度）
    //-------------------------------------------------------------------------
    wire [15:0] proc_rgb;
    wire        hs1, vs1, de1;
    video_proc u_video_proc (
        .clk_pix   (clk_pix),
        .rst_n     (rst_pix_n),
        .rgb_in    (fb_rgb),
        .de_in     (de),
        .hs_in     (hs),
        .vs_in     (vs),
        .brightness(reg_brightness),
        .contrast  (reg_contrast),
        .saturation(reg_saturation),
        .rgb_out   (proc_rgb),
        .de_out    (de1),
        .hs_out    (hs1),
        .vs_out    (vs1)
    );

    //-------------------------------------------------------------------------
    // OSD 图层合成（文字/字幕 + 频谱柱）
    //-------------------------------------------------------------------------
    wire [15:0] ovl_rgb;
    wire [7:0]  ovl_alpha;
    wire        ovl_valid;
    wire [12:0] fnt_addr;
    wire [7:0]  fnt_data;

    text_layer u_text_layer (
        .clk_pix     (clk_pix),
        .rst_n       (rst_pix_n),
        .de_i        (de1),
        .x           (x),
        .y           (y),
        .fnt_addr    (fnt_addr),
        .fnt_data    (fnt_data),
        .txt_char_idx(),
        .txt_char_code(7'd0),
        .txt_y       (11'd640),
        .scroll_x    (11'd0),
        .fg_alpha    (8'd200),
        .fg_color    (16'hFFFF),
        .osd_en      (reg_osd_en),
        .ovl_rgb     (ovl_rgb),
        .ovl_alpha   (ovl_alpha),
        .ovl_valid   (ovl_valid)
    );
    font_rom u_font_rom (
        .clk_pix (clk_pix),
        .addr    (fnt_addr),
        .data    (fnt_data)
    );

    wire [15:0] osd_rgb;
    wire        hs2, vs2, de2;
    osd_layer u_osd_layer (
        .clk_pix  (clk_pix),
        .rst_n    (rst_pix_n),
        .base_rgb (proc_rgb),
        .hs_i     (hs1),
        .vs_i     (vs1),
        .de_i     (de1),
        .ovl_rgb  (ovl_rgb),
        .ovl_alpha(ovl_alpha),
        .ovl_valid(ovl_valid),
        .rgb_o    (osd_rgb),
        .hs_o     (hs2),
        .vs_o     (vs2),
        .de_o     (de2)
    );

    //-------------------------------------------------------------------------
    // 转场（当前 A/B 同源；接入 SDRAM 双帧后生效）
    //-------------------------------------------------------------------------
    wire [15:0] tr_rgb;
    wire        hs3, vs3, de3;
    transition u_transition (
        .clk_pix (clk_pix),
        .rst_n   (rst_pix_n),
        .a_rgb   (osd_rgb),
        .b_rgb   (osd_rgb),
        .hs_i    (hs2),
        .vs_i    (vs2),
        .de_i    (de2),
        .x       (x),
        .y       (y),
        .mode    (fsm_tmode),
        .blend   (fsm_blend),
        .rgb_o   (tr_rgb),
        .hs_o    (hs3),
        .vs_o    (vs3),
        .de_o    (de3)
    );

    //-------------------------------------------------------------------------
    // 输出：HDMI（软 TMDS）
    //-------------------------------------------------------------------------
    hdmi_tx_wrap u_hdmi (
        .clk_pix    (clk_pix),
        .clk_pix5x  (clk_pix5x),
        .rst_n      (rst_pix_n),
        .hs_i       (hs3),
        .vs_i       (vs3),
        .de_i       (de3),
        .rgb565     (tr_rgb),
        .hdmi_clk_p (hdmi_clk_p),
        .hdmi_d0_p  (hdmi_d0_p),
        .hdmi_d1_p  (hdmi_d1_p),
        .hdmi_d2_p  (hdmi_d2_p)
    );

    //-------------------------------------------------------------------------
    // 存储与解码（骨架，第 2 周填充）
    //-------------------------------------------------------------------------
    wire [31:0] sd_sec;
    wire        sd_req;
    wire [7:0]  sd_data;
    wire        sd_valid, sd_done, sd_pop;

    sd_ctrl u_sd_ctrl (
        .clk      (clk_50m),
        .rst_n    (rst_n),
        .sd_clk   (sd_clk),
        .sd_cs    (sd_cs),
        .sd_mosi  (sd_mosi),
        .sd_miso  (sd_miso),
        .rd_sec   (sd_sec),
        .rd_req   (sd_req),
        .rd_data  (sd_data),
        .rd_valid (sd_valid),
        .rd_pop   (sd_pop),
        .rd_done  (sd_done),
        .init_done(sd_init_done)
    );

    wire [7:0]  file_data;
    wire        file_valid, file_eof, file_pop;

    fat32_reader u_fat32 (
        .clk         (clk_50m),
        .rst_n       (rst_n),
        .sd_sec      (sd_sec),
        .sd_req      (sd_req),
        .sd_data     (sd_data),
        .sd_valid    (sd_valid),
        .sd_done     (sd_done),
        .sd_pop      (sd_pop),
        .file_data   (file_data),
        .file_valid  (file_valid),
        .eof         (file_eof),
        .file_pop    (file_pop),
        .start       (1'b0),
        .file_cluster(32'd0),
        .busy        (),
        .done        ()
    );

    media_scan u_media_scan (
        .clk        (clk_50m),
        .rst_n      (rst_n),
        .scan_start (scan_start),
        .scanning   (),
        .done       (scan_done),
        .dir_pop    (),
        .dir_valid  (1'b0),
        .dir_data   (8'd0),
        .idx_we     (),
        .idx_addr   (),
        .idx_type   (),
        .idx_cluster(),
        .idx_size   (),
        .media_count()
    );

    wire [15:0] bmp_px_data;
    wire [15:0] bmp_px_x, bmp_px_y;
    wire        bmp_px_we;

    bmp_decoder u_bmp_decoder (
        .clk       (clk_50m),
        .rst_n     (rst_n),
        .file_pop  (),
        .file_valid(1'b0),
        .file_data (8'd0),
        .img_w     (),
        .img_h     (),
        .header_ok (img_ready),
        .frame_done(),
        .px_data   (bmp_px_data),
        .px_x      (bmp_px_x),
        .px_y      (bmp_px_y),
        .px_we     (bmp_px_we)
    );

    wire [15:0] pcm_l, pcm_r;
    wire        pcm_valid;
    wire [31:0] wav_rate;
    wire [2:0]  wav_channels;
    wire [5:0]  wav_bits;

    wav_player u_wav_player (
        .clk        (clk_50m),
        .rst_n      (rst_n),
        .file_pop   (),
        .file_valid (1'b0),
        .file_data  (8'd0),
        .sample_rate(wav_rate),
        .channels   (wav_channels),
        .bits       (wav_bits),
        .header_ok  (),
        .pcm_l      (pcm_l),
        .pcm_r      (pcm_r),
        .pcm_valid  (pcm_valid),
        .eof        ()
    );

    //-------------------------------------------------------------------------
    // 音频：数字音量 + Σ-Δ PWM 输出
    //-------------------------------------------------------------------------
    pwm_audio u_pwm_audio (
        .clk      (clk_50m),
        .rst_n    (rst_n),
        .pcm      (pcm_l),
        .pcm_valid(pcm_valid),
        .volume   (reg_audio_volume),
        .audio_pwm(audio_pwm)
    );

    // 音频可视化（频谱柱；第 4 周实现）
    wire [127:0] viz_bars;
    wire         viz_valid;
    audio_viz #(.BARS(16)) u_audio_viz (
        .clk      (clk_50m),
        .rst_n    (rst_n),
        .pcm      (pcm_l),
        .pcm_valid(pcm_valid),
        .src_sel  (2'd0),
        .bars     (viz_bars),
        .bars_valid(viz_valid)
    );

    // 麦克风采集（现场声源，差异化亮点）
    wire [15:0] mic_sample;
    wire        mic_valid;
    mic_adc u_mic_adc (
        .clk         (clk_50m),
        .rst_n       (rst_n),
        .adc_cs      (mic_cs),
        .adc_miso    (mic_miso),
        .adc_sck     (mic_sck),
        .adc_rst_n   (mic_rst_n),
        .sample      (mic_sample),
        .sample_valid(mic_valid)
    );

    //-------------------------------------------------------------------------
    // 数码管 / LED 状态指示
    //-------------------------------------------------------------------------
    wire [31:0] seg_value = {16'h0000, fsm_media_index, fsm_state, fsm_blend[3:0]};
    seg_led u_seg_led (
        .clk    (clk_50m),
        .rst_n  (rst_n),
        .value  (seg_value),
        .dot    (4'b0000),
        .seg_sel(seg_sel),
        .seg_led(seg_led)
    );

    assign led[0] = pll_locked;
    assign led[1] = rst_n;
    assign led[2] = sd_init_done;
    assign led[3] = frame_start;
    assign led[4] = transition_active;
    assign led[5] = 1'b0;
    assign led[6] = 1'b0;
    assign led[7] = 1'b0;

    // synthesis translate_off
    wire _unused = &{1'b0, line_start, reg_transition_type, reg_display_mode,
                     reg_media_index, reg_auto_play, swap_done,
                     file_data, file_valid, file_eof, file_pop,
                     bmp_px_data, bmp_px_x, bmp_px_y, bmp_px_we,
                     pcm_r, wav_rate, wav_channels, wav_bits, viz_bars, viz_valid,
                     mic_sample, mic_valid, img_ready};
    // synthesis translate_on

endmodule
