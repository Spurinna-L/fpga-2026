//=============================================================================
// top_tf_hdmi_audio.v — 系统顶层：TF 卡 BMP → SDRAM → 640×480@60 HDMI + 音频
//-----------------------------------------------------------------------------
// 功能：
//   上电后自动扫描 TF 卡中的 640×480 / 24bit / 非压缩 BMP，并把前 4 张
//   **依次预载**到 SDRAM 的 4 个槽位（BUF0..BUF3）；预载完成前不读帧缓存。
//   运行期只读：M2 改为**按行读取 A/B 两个槽**（frame_line_read），每行
//   1280 字写入双 bank 行缓冲，经 mixer 做溶解/水平滑动，再送 HDMI；
//   K1/自动轮播只改槽号，运行期不写 SDRAM。
//   同时产生 48kHz I2S 测试音，解串成 PCM 并生成 ACR 一起送核。
//   16 键矩阵键盘负责切图/参数，4 位数码管与 8 个 LED 做状态回显。
//
// 时钟（全部由 50MHz 板载时钟经 PLL 产生）：
//   clk           50MHz   系统/POR/键盘/regs/数码管
//   sd_card_clk  100MHz   SD-SPI、FAT/BMP 解析、帧缓存写侧
//   ext_mem_clk  125MHz   帧缓存读写 FSM、SDRAM 控制器
//   video_clk     25MHz   视频时序、像素对齐、HDMI 核、I2S 接收
//   hdmi_5x_clk  125MHz   TMDS 10:1 串行化（5×像素时钟）
//   audio_mclk  12.288MHz I2S 测试音（256fs）
// 复位：
//   3 个 PLL 锁定 + 约 1.3ms POR 计数 → por_done；每个时钟域一个 reset_sync
//   （异步置位 / 同步释放），下游模块使用高有效 rst_*。
//
// 接口：
//   in  clk / rst_n                    50MHz 时钟 / 低有效复位（A9）
//   out HDMI_CLK_P / D0_P / D1_P / D2_P  TMDS 差分对
//   out sd_ncs / sd_dclk / sd_mosi, in sd_miso   TF 卡 SPI
//   out kb_row[3:0], in kb_col[3:0]      4×4 矩阵键盘
//   out seg_sel[3:0] / seg_led[7:0]      数码管位选 / 段码
//   out led[7:0]                         状态灯
//   out audio_pwm                        备份音频，本版恒 0
//
// 参数/常量：
//   FRAME_PIXELS = 307200   一帧像素数（640×480）
//   BUF0_ADDR    = 0        A 缓冲基地址
//   BUF1_ADDR    = 307200   B 缓冲基地址
//
// 内部例化：
//   sys_pll / video_pll / PLL_HDMI_AUDIO        三个时钟 PLL
//   reset_sync ×6                               每域复位同步
//   keyboard_scan / key_filter                  键盘扫描与消抖
//   sd_card_bmp                                 SD + FAT32 + BMP + 双缓冲调度
//   video_timing_data / video_pos               视频时序、行计数与像素坐标
//   line_sched / frame_line_read                提前一行取 A/B
//   line_buffer ×2 / mixer                      A/B 乒乓行缓冲与溶解/滑动
//   disp_ctrl                                   当前槽/目标槽/转场进度
//   video_post                                  亮度/对比度 + 参数 OSD + Logo 图层（M2）
//   test_pattern_640x480                        无图/首行未就绪时的彩条回退
//   frame_read_write                            帧缓存写侧（仅开机预载）
//   sdr_refresh_sweep                           消隐期顺序扫描，保持闲置槽
//   sdram                                       SDRAM 控制器（含加密核）
//   video_rgb_to_axis_640x480                   RGB/DE/VS → AXIS
//   hdmi_audio_tone_i2s_64fs / I2S_receiver / audio_arc_calculate
//                                               测试音 → PCM → ACR
//   hdmi_1_4b_transmitter_core_wrapper          HDMI 1.4b 加密核（黑盒）
//   hdmi_phy_wrapper                            TMDS 并串转换
//   regs / seg_led                              按键参数与数码管
//
// 备注：
//   - 本板无 DDC/EDID，I_edid_read_trig 恒 0。
//   - M2 起 A/B 每行都取；空闲时 next_idx=cur_idx，B 行与 A 行相同。
//   - 调试用的 SDRAM 自检 / 总线开关已在 M1 封档时移除（源码保留在 SD/sdram_selftest.v）。
//   - frame_read_write_dual 等双读源码保留在仓库中，但顶层不例化。
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
    localparam [20:0] BUF0_ADDR    = 21'd0;     // 图 0 槽
    localparam [20:0] BUF1_ADDR    = FRAME_PIXELS; // 图 1 槽
    localparam [20:0] BUF2_ADDR    = FRAME_PIXELS * 2; // 图 2 槽
    localparam [20:0] BUF3_ADDR    = FRAME_PIXELS * 3; // 图 3 槽
    // 4 槽共 1,228,800 字，SDRAM 有 2,097,152 字

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

    //-------------------------------------------------------------------------
    // POR + 各时钟域独立复位同步
    //   - 3 个 PLL 中只有音频 PLL 有 extlock；其余靠 ~1.3ms POR 覆盖锁定时间
    //   - por_done 在 50MHz 域打拍后，分发到各域的 reset_sync
    //   - 每个域异步置位、同步释放，避免 release 跨域造成 recovery 违例
    //-------------------------------------------------------------------------
    reg [1:0] lock_sync;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            lock_sync <= 2'b00;
        else
            lock_sync <= {lock_sync[0], audio_pll_lock};
    end
    wire pll_ready = lock_sync[1];

    reg [15:0] por_cnt;
    reg        por_done_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            por_cnt    <= 16'd0;
            por_done_r <= 1'b0;
        end else if (!pll_ready) begin
            por_cnt    <= 16'd0;
            por_done_r <= 1'b0;
        end else if (!por_done_r) begin
            if (por_cnt == 16'hFFFF)
                por_done_r <= 1'b1;
            else
                por_cnt <= por_cnt + 16'd1;
        end
    end

    wire rst_n_sys, rst_n_sd, rst_n_mem, rst_n_vid, rst_n_5x, rst_n_aud;
    wire rst_sd  = ~rst_n_sd;
    wire rst_mem = ~rst_n_mem;
    wire rst_vid = ~rst_n_vid;
    wire rst_5x  = ~rst_n_5x;
    wire rst_aud = ~rst_n_aud;

    reset_sync u_rst_sys (.clk(clk),         .rst_n_in(rst_n), .por_done(por_done_r), .rst_n_out(rst_n_sys));
    reset_sync u_rst_sd  (.clk(sd_card_clk), .rst_n_in(rst_n), .por_done(por_done_r), .rst_n_out(rst_n_sd));
    reset_sync u_rst_mem (.clk(ext_mem_clk), .rst_n_in(rst_n), .por_done(por_done_r), .rst_n_out(rst_n_mem));
    reset_sync u_rst_vid (.clk(video_clk),   .rst_n_in(rst_n), .por_done(por_done_r), .rst_n_out(rst_n_vid));
    reset_sync u_rst_5x  (.clk(hdmi_5x_clk), .rst_n_in(rst_n), .por_done(por_done_r), .rst_n_out(rst_n_5x));
    reset_sync u_rst_aud (.clk(audio_mclk),  .rst_n_in(rst_n), .por_done(por_done_r), .rst_n_out(rst_n_aud));

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

    wire key_next = ~key_deb[0];  // 矩阵第 4 行第 1 列（按下为低，匹配 sd_card_bmp 的消抖输入极性）
    wire key_auto = ~key_deb[1];  // 矩阵第 4 行第 2 列

    //-------------------------------------------------------------------------
    // SD / FAT32 / BMP / 双缓冲
    //-------------------------------------------------------------------------
    wire        display_valid;
    wire [3:0]  state_code;
    wire [1:0]  write_buf_idx;
    wire [1:0]  disp_buf_idx;
    wire [1:0]  img_idx;

    wire        sd_write_req;
    wire        sd_write_req_ack;
    wire        sd_write_en;
    wire [31:0] sd_write_data;

    wire        frame_write_finish;
    reg         frame_write_toggle_mem;

    always @(posedge ext_mem_clk or posedge rst_mem) begin
        if (rst_mem)
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
        .rst               (rst_sd),
        .key_next          (key_next),  // 下一帧按键
        .key_auto          (key_auto),  // 自动播放按键
        .state_code        (state_code),    // SD 卡状态码
        .bmp_width         (16'd640),
        .bmp_height        (16'd480),
        .display_valid     (display_valid), // 首图已提交  
        .write_finish_toggle(frame_write_toggle_mem),
        .write_buf_idx     (write_buf_idx), // 当前写入缓冲区索引
        .disp_buf_idx      (disp_buf_idx),  // 当前显示缓冲区索引
        .img_idx_o         (img_idx),
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
    // 视频时序 / 像素坐标 / 行缓冲选择
    //-------------------------------------------------------------------------
    wire        hs_0, vs_0, de_0;
    wire [11:0] v_cnt;
    wire        hs, vs, de;
    wire [23:0] post_rgb;
    wire [23:0] vout_data_raw;
    wire [23:0] vout_data;
    wire [9:0]  pix_x, pix_y;
    wire        vs_fall;

    video_timing_data u_timing (
        .video_clk    (video_clk),
        .rst          (rst_vid),
        .read_req     (),
        .read_req_ack (1'b0),
        .hs           (hs_0),
        .vs           (vs_0),
        .de           (de_0),
        .v_cnt        (v_cnt)
    );

    video_pos u_pos (
        .clk     (video_clk),
        .rst     (rst_vid),
        .vs      (vs_0),
        .de      (de_0),
        .x       (pix_x),
        .y       (pix_y),
        .vs_d    (),
        .vs_fall (vs_fall)
    );

    // display_valid 来自 100MHz 域，2FF 同步后再参与视频选择
    reg [1:0] disp_valid_sync;
    always @(posedge video_clk or posedge rst_vid) begin
        if (rst_vid)
            disp_valid_sync <= 2'b00;
        else
            disp_valid_sync <= {disp_valid_sync[0], display_valid};
    end
    wire display_valid_v = disp_valid_sync[1];

    // 行读取调度：提前一行发出 line_toggle/line_num
    wire        line_toggle;
    wire [9:0]  line_num;
    wire        prefetch_zero;
    line_sched u_line_sched (
        .clk           (video_clk),
        .rst           (rst_vid),
        .display_valid (display_valid_v),
        .v_cnt         (v_cnt),
        .line_toggle   (line_toggle),
        .line_num      (line_num),
        .prefetch_zero (prefetch_zero)
    );

    // 转场控制（实例放在 regs 之后，见下文）
    wire [1:0] cur_idx, next_idx, mix_mode;
    wire [7:0] alpha;
    wire [9:0] dx;
    wire       trans_active;

    // 行缓冲写口（来自 frame_line_read）
    wire        lb_we, lb_bank, lb_sel;
    wire [9:0]  lb_addr;
    wire [23:0] lb_data;
    wire [23:0] lb_a_rdata, lb_b_rdata;
    wire [9:0]  mix_a_addr, mix_b_addr;

    // 每个图片源一个 2-bank 行缓冲，地址 = {bank, x}
    line_buffer u_lb_a (
        .wr_clk  (ext_mem_clk),
        .wr_en   (lb_we && !lb_sel),
        .wr_addr ({lb_bank, lb_addr}),
        .wr_data (lb_data),
        .rd_clk  (video_clk),
        .rd_addr ({pix_y[0], mix_a_addr}),
        .rd_data (lb_a_rdata)
    );

    line_buffer u_lb_b (
        .wr_clk  (ext_mem_clk),
        .wr_en   (lb_we && lb_sel),
        .wr_addr ({lb_bank, lb_addr}),
        .wr_data (lb_data),
        .rd_clk  (video_clk),
        .rd_addr ({pix_y[0], mix_b_addr}),
        .rd_data (lb_b_rdata)
    );

    // A/B 溶解 / 水平滑动
    wire [23:0] mix_rgb;
    mixer u_mixer (
        .clk    (video_clk),
        .rst    (rst_vid),
        .x      (pix_x),
        .mode   (mix_mode),
        .alpha  (alpha),
        .dx     (dx),
        .a_data (lb_a_rdata),
        .b_data (lb_b_rdata),
        .a_addr (mix_a_addr),
        .b_addr (mix_b_addr),
        .rgb    (mix_rgb)
    );

    // BRAM 1 拍 + mixer 1 拍，边带整体延迟 2 拍
    wire [22:0] side_in  = {hs_0, vs_0, de_0, pix_x, pix_y};
    wire [22:0] side_out;
    video_delay2 #(.WIDTH(23)) u_side_delay (
        .clk  (video_clk),
        .rst  (rst_vid),
        .din  (side_in),
        .dout (side_out)
    );

    wire        post_hs = side_out[22];
    wire        post_vs = side_out[21];
    wire        post_de = side_out[20];
    wire [9:0]  post_x  = side_out[19:10];
    wire [9:0]  post_y  = side_out[9:0];

    // video_post 内部有 2 拍亮度/对比度流水，rgb_out 比输入晚 2 拍；
    // 因此 hs/vs/de 必须取 video_post 对齐后的输出，才能与 post_rgb 同拍。
    wire        post_hs_v, post_vs_v, post_de_v;

    assign hs = post_hs_v;
    assign vs = post_vs_v;
    assign de = post_de_v;

    assign vout_data_raw = post_rgb;

    // 无图时输出彩条（诊断：有彩条=HDMI 链路 OK，问题在 SD/BMP）
    wire [23:0] test_rgb;
    test_pattern_640x480 u_test_pattern (
        .clk (video_clk),
        .rst (rst_vid),
        .vs  (vs),
        .de  (de),
        .rgb (test_rgb)
    );

    // display_valid 来自 100MHz 域，2FF 同步后再参与视频选择
    // （disp_valid_sync / display_valid_v 已在视频时序段声明）

    // 显示源在行缓冲输出之后选择（见下方 vout_data）

    //-------------------------------------------------------------------------
    // 帧缓存：写侧仍由 frame_read_write 负责（仅开机预载）
    //         读侧改为 frame_line_read（按行取 A/B）
    //-------------------------------------------------------------------------
    wire        line_rd_en;
    wire [20:0] line_rd_addr;
    wire        line_busy, line_done, first_line_done, last_line_done;
    wire        sweep_active, sweep_en;
    wire [20:0] sweep_addr;

    wire        App_rd_en;
    wire [20:0] App_rd_addr;
    wire        App_wr_en;
    wire [20:0] App_wr_addr;
    wire [31:0] App_wr_din;
    wire [3:0]  App_wr_dm;

    wire        Sdr_rd_en;
    wire [31:0] Sdr_rd_dout;
    wire        Sdr_init_done;
    wire        Sdr_init_ref_vld;
    wire        Sdr_busy;

    // display_valid / A,B 槽号 2FF 到 mem 域
    reg [1:0] disp_valid_mem;
    reg [1:0] cur_idx_mem, next_idx_mem;
    reg [1:0] prefetch_sync_mem;
    always @(posedge ext_mem_clk or posedge rst_mem) begin
        if (rst_mem) begin
            disp_valid_mem   <= 2'd0;
            cur_idx_mem      <= 2'd0;
            next_idx_mem     <= 2'd0;
            prefetch_sync_mem <= 2'd0;
        end else begin
            disp_valid_mem   <= {disp_valid_mem[0], display_valid};
            cur_idx_mem      <= cur_idx;
            next_idx_mem     <= next_idx;
            prefetch_sync_mem <= {prefetch_sync_mem[0], prefetch_zero};
        end
    end

    function [20:0] slot_base;
        input [1:0] idx;
        begin
            case (idx)
                2'd0: slot_base = BUF0_ADDR;
                2'd1: slot_base = BUF1_ADDR;
                2'd2: slot_base = BUF2_ADDR;
                default: slot_base = BUF3_ADDR;
            endcase
        end
    endfunction

    wire [20:0] base_a = slot_base(cur_idx_mem);
    wire [20:0] base_b = slot_base(next_idx_mem);

    // 首行就绪标志：预载完成后的第一帧先显示彩条，直到第 0 行真正写满
    reg        frame_ready_mem;
    always @(posedge ext_mem_clk or posedge rst_mem) begin
        if (rst_mem)
            frame_ready_mem <= 1'b0;
        else if (!disp_valid_mem[1])
            frame_ready_mem <= 1'b0;
        else if (first_line_done)
            frame_ready_mem <= 1'b1;
    end

    reg [1:0] frame_ready_sync;
    always @(posedge video_clk or posedge rst_vid) begin
        if (rst_vid)
            frame_ready_sync <= 2'b00;
        else
            frame_ready_sync <= {frame_ready_sync[0], frame_ready_mem};
    end
    wire frame_ready_v = frame_ready_sync[1];

    //-------------------------------------------------------------------------
    // 帧缓存写侧：仅开机预载使用；读侧全部交给 frame_line_read
    //-------------------------------------------------------------------------
    frame_read_write #(
        .WRITE_V_FLIP  (1),
        .FRAME_WIDTH   (640),
        .FRAME_HEIGHT  (480)
    ) u_fb (
        .rst              (rst_mem),
        .mem_clk          (ext_mem_clk),
        .Sdr_init_done    (Sdr_init_done),
        .Sdr_init_ref_vld (Sdr_init_ref_vld),
        .Sdr_busy         (Sdr_busy),
        .App_rd_en        (),
        .App_rd_addr      (),
        .Sdr_rd_en        (1'b0),
        .Sdr_rd_dout      (32'd0),
        .read_clk         (video_clk),
        .read_req         (1'b0),
        .read_req_ack     (),
        .read_finish      (),
        .read_addr_0      (BUF0_ADDR),
        .read_addr_1      (BUF1_ADDR),
        .read_addr_2      (BUF2_ADDR),
        .read_addr_3      (BUF3_ADDR),
        .read_addr_index  (2'd0),
        .read_len         (FRAME_PIXELS),
        .read_en          (1'b0),
        .read_data        (),
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
        .write_addr_2     (BUF2_ADDR),
        .write_addr_3     (BUF3_ADDR),
        .write_addr_index (write_buf_idx),
        .write_len        (FRAME_PIXELS),
        .write_en         (sd_write_en),
        .write_data       (sd_write_data)
    );

    //-------------------------------------------------------------------------
    // 行读取：每行取 A 640 字 + B 640 字，写入 2-bank 行缓冲
    //-------------------------------------------------------------------------
    frame_line_read u_line_read (
        .clk            (ext_mem_clk),
        .rst            (rst_mem),
        .enable         (disp_valid_mem[1]),
        .Sdr_init_done  (Sdr_init_done),
        .sweep_busy     (sweep_active),
        .base_a         (base_a),
        .base_b         (base_b),
        .line_toggle    (line_toggle),
        .line_num       (line_num),
        .line_busy      (line_busy),
        .line_done      (line_done),
        .first_line_done(first_line_done),
        .last_line_done (last_line_done),
        .App_rd_en      (line_rd_en),
        .App_rd_addr    (line_rd_addr),
        .Sdr_busy       (Sdr_busy),
        .Sdr_rd_en      (Sdr_rd_en),
        .Sdr_rd_dout    (Sdr_rd_dout),
        .lb_we          (lb_we),
        .lb_bank        (lb_bank),
        .lb_addr        (lb_addr),
        .lb_data        (lb_data),
        .lb_sel         (lb_sel)
    );

    //-------------------------------------------------------------------------
    // 后台顺序扫描：最后一行取完后开始，下一帧首行预取前停止
    //   —— 只有“顺序整段读”能保持闲置槽数据（点读/自动刷新都不够）
    //-------------------------------------------------------------------------
    sdr_refresh_sweep u_sweep (
        .clk    (ext_mem_clk),
        .rst    (rst_mem),
        .start  (last_line_done),
        .stop   (prefetch_sync_mem[1]),
        .active (sweep_active),
        .en     (sweep_en),
        .addr   (sweep_addr)
    );

    assign App_rd_en   = sweep_active ? sweep_en   : line_rd_en;
    assign App_rd_addr = sweep_active ? sweep_addr : line_rd_addr;

    assign vout_data = (display_valid_v && frame_ready_v) ? vout_data_raw : test_rgb;

    sdram u_sdram (
        .Clk              (ext_mem_clk),
        .Clk_sft          (ext_mem_clk_sft),
        .Rst              (rst_mem),
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
        .I_rst         (rst_vid),
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
        .I_rst      (rst_aud),
        .O_i2s_BCLK (audio_i2s_bclk),
        .O_i2s_LRCK (audio_i2s_lrck),
        .O_i2s_DOUT (audio_i2s_dout)
    );

    I2S_receiver u_i2s_rx (
        .I_clk              (video_clk),
        .I_rst              (rst_vid),
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
        .I_rst         (rst_vid),
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
        .I_rst             (rst_vid),
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
        .I_rst              (rst_5x),
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
    // 交互寄存器：16 键、参数、时间戳、数码管显示值
    //-------------------------------------------------------------------------
    wire signed [7:0] regs_brightness;
    wire [7:0]  regs_contrast;
    wire [1:0]  regs_trans_mode;
    wire        regs_osd_en;
    wire [1:0]  regs_audio_src;
    wire [1:0]  regs_viz_mode;
    wire [1:0]  regs_timbre;
    wire [7:0]  regs_time_mm;
    wire [7:0]  regs_time_ss;
    wire        regs_tick_1hz;
    wire [31:0] regs_seg_value;
    wire [15:0] regs_key_press;

    regs u_regs (
        .clk          (clk),
        .rst_n        (rst_n_sys),
        .key_deb      (key_deb),
        .state_code   (state_code),
        .img_idx      (img_idx),
        .disp_buf_idx (disp_buf_idx),
        .brightness   (regs_brightness),
        .contrast     (regs_contrast),
        .trans_mode   (regs_trans_mode),
        .osd_en       (regs_osd_en),
        .audio_src    (regs_audio_src),
        .viz_mode     (regs_viz_mode),
        .timbre       (regs_timbre),
        .time_mm      (regs_time_mm),
        .time_ss      (regs_time_ss),
        .tick_1hz     (regs_tick_1hz),
        .seg_value    (regs_seg_value),
        .key_press    (regs_key_press)
    );

    //-------------------------------------------------------------------------
    // 显示槽 A/B 与转场控制（video_clk 域）
    //-------------------------------------------------------------------------
    disp_ctrl u_disp_ctrl (
        .clk           (video_clk),
        .rst           (rst_vid),
        .display_valid (display_valid_v),
        .disp_idx_in   (disp_buf_idx),
        .trans_mode_in (regs_trans_mode),
        .frame_tick    (vs_fall),
        .cur_idx       (cur_idx),
        .next_idx      (next_idx),
        .mix_mode      (mix_mode),
        .alpha         (alpha),
        .dx            (dx),
        .trans_active  (trans_active)
    );

    //-------------------------------------------------------------------------
    // mixer 之后的视频后处理：亮度/对比度 + 参数 OSD + 左上角 Logo（M2 扩展④）
    //   参数在 50MHz 按键域，视频在 25MHz 像素域 → video_post 内部用
    //   video_param_latch 做「2FF + 连续稳定检测 + vs 帧边界整组锁存」，
    //   再串 video_proc（2 拍）与 osd_composer / logo_overlay（均为组合，0 拍），
    //   并把 hs/vs 同步延迟 2 拍。
    //   logo_en 恒 1：Logo 始终显示；若要跟 K4 一起开关，把它改成 regs_osd_en。
    //-------------------------------------------------------------------------
    video_post u_video_post (
        .clk        (video_clk),
        .rst        (rst_vid),
        .rgb_in     (mix_rgb),
        .hs_in      (post_hs),
        .vs_in      (post_vs),
        .de_in      (post_de),
        .x_in       (post_x),
        .y_in       (post_y),
        .brightness (regs_brightness),
        .contrast   (regs_contrast),
        .osd_en     (regs_osd_en),
        .logo_en    (1'b1),
        .time_mm    (regs_time_mm),
        .time_ss    (regs_time_ss),
        .img_idx    (img_idx),
        .trans_mode (regs_trans_mode),
        .audio_src  (regs_audio_src),
        .rgb_out    (post_rgb),
        .hs_out     (post_hs_v),
        .vs_out     (post_vs_v),
        .de_out     (post_de_v),
        .x_out      (),
        .y_out      ()
    );

    //-------------------------------------------------------------------------
    // 数码管 / LED
    //-------------------------------------------------------------------------
    seg_led u_seg (
        .clk     (clk),
        .rst_n   (rst_n_sys),
        .value   (regs_seg_value),
        .dot     (4'b0000),
        .seg_sel (seg_sel),
        .seg_led (seg_led)
    );

    // tick_1hz 只有 20ns，不能直接驱动 LED；翻转成 0.5s 电平 => 1Hz 闪烁
    reg led_heart;
    always @(posedge clk or negedge rst_n_sys) begin
        if (!rst_n_sys)
            led_heart <= 1'b0;
        else if (regs_tick_1hz)
            led_heart <= ~led_heart;
    end

    assign led[0] = audio_pll_lock;
    assign led[1] = Sdr_init_done;
    assign led[2] = display_valid;
    assign led[3] = disp_buf_idx[0];
    assign led[4] = 1'b0;
    assign led[5] = 1'b0;
    assign led[6] = video_locked;
    assign led[7] = led_heart;           // 1Hz 心跳

    assign audio_pwm = 1'b0;

endmodule
