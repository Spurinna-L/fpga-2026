//=============================================================================
// sd_card_bmp.v — SD 卡图片管理器（扫描 / 加载 / 双缓冲 / 轮播）
//-----------------------------------------------------------------------------
// 功能：
//   上电扫描前 4 张合法 BMP，并把它们**依次预载到 4 个 SDRAM 槽位**
//   （槽 i 基址 = i × 307200）；全部写完后才开显示。
//   之后 K1/自动轮播只改 `disp_buf_idx`（读基地址），**不再写 SDRAM**，
//   所以切换是瞬间的、不会与显示读并发。
//
// 时钟/复位：clk = 100MHz；rst 高有效。
//
// 接口：
//   in  key_next / key_auto        下一张 / 自动轮播（低有效）
//   in  write_finish_toggle        125MHz 域“整帧写完”翻转标志
//   in  bmp_width / bmp_height     源图允许的最大宽/高（缩放版 1920/1080）
//   out write_buf_idx[1:0]         当前写入缓冲
//   out disp_buf_idx[1:0]          当前显示缓冲
//   out img_idx_o[1:0]             当前图片序号（给 regs/OSD）
//   out display_valid              首帧已可显示
//   out state_code[3:0]            SD/BMP 状态码（给数码管）
//   out write_req / write_en / write_data[31:0]={R,G,B,8'h0}
//   out SD_nCS / SD_DCLK / SD_MOSI, in SD_MISO
//
// 参数：
//   CLK_FREQ_HZ       = 100_000_000
//   SCAN_START_SECTOR = 0
//   SCAN_MAX_SECTOR   = 131071
//   SCAN_TARGET_COUNT = 4
//
// 内部例化：
//   key_press_debounce ×2（本文件底部定义的 20ms 消抖模块）
//   bmp_read          BMP 定位、行填充跳过与源像素搬运
//   bmp_scale         双线性缩放 + 保持比例黑边（640×480 旁路）
//   sd_card_top       SD 卡子系统
//
// 备注：
//   write_finish_toggle 用 3FF 同步后取 bit2^bit1 的边沿作为提交条件，
//   这是“跨域单 bit 事件”的标准做法；不要改成电平判断。
//=============================================================================
// 扫描、BMP 解析、加载、双缓冲调度、按键
module sd_card_bmp #(
    parameter integer CLK_FREQ_HZ       = 100_000_000,
    parameter integer AUTO_PERIOD_S     = 4,            // 自动轮播间隔（秒）
    parameter [31:0]  SCAN_START_SECTOR = 32'd0,    // 扫描起始扇区
    parameter [31:0]  SCAN_MAX_SECTOR   = 32'd131071,   // 扫描最大扇区 
    parameter [2:0]   SCAN_TARGET_COUNT = 3'd4  // 扫描目标数量
)(
    input                       clk,
    input                       rst,
    input                       key_next,
    input                       key_auto,
    output [3:0]                state_code,
    input  [15:0]               bmp_width,   // 允许的最大源宽（缩放版 1920）
    input  [15:0]               bmp_height,  // 允许的最大源高（缩放版 1080）
    output reg                  display_valid,  // 首图已提交

    input                       write_finish_toggle,
    output reg [1:0]            write_buf_idx,    // 当前写入缓冲区索引
    output reg [1:0]            disp_buf_idx,     // 当前显示缓冲区索引
    output wire [1:0]           img_idx_o,        // 当前显示的图片序号（给 regs/OSD）

    // 临时诊断（DEBUG_SEG=1 时显示在数码管上）
    output wire [3:0]           dbg_found,        // 扫描到的图片数 0..4
    output wire [3:0]           dbg_def_t,        // 距满帧还差多少像素 /64（高 4 位）
    output wire [3:0]           dbg_def_o,        // 距满帧还差多少像素 /64（低 4 位）
    output wire [3:0]           dbg_flags,        // {display_valid, load_busy, source_done_seen, finish_seen}
    output wire                 dbg_scale_bypass, // 当前图是否走 640×480 旁路

    output                      write_req,
    input                       write_req_ack,
    output                      write_en,
    output [31:0]               write_data,
    output                      SD_nCS,
    output                      SD_DCLK,
    output                      SD_MOSI,
    input                       SD_MISO
);

wire key_next_press;
wire key_auto_press;

wire             sd_sec_read;
wire [31:0]      sd_sec_read_addr;
wire [7:0]       sd_sec_read_data;
wire             sd_sec_read_data_valid;
wire             sd_sec_read_end;
wire             bmp_src_valid;
wire [23:0]      bmp_src_data;
wire             bmp_src_config;
wire [15:0]      bmp_src_width;
wire [15:0]      bmp_src_height;
wire             bmp_src_sop;
wire             bmp_src_eof;
wire             scale_src_ready;
wire             scale_out_valid;
wire [23:0]      scale_out_data;
wire             scale_done;
wire             scale_bypass;
wire             sd_init_done;
wire             bmp_ready;
wire             scan_done;
wire             scan_found_valid;
wire [31:0]      scan_found_sector;
wire [2:0]       scan_found_total;

reg              scan_start_pulse;
reg              load_start_pulse;
reg [31:0]       load_sector;
reg              scan_kicked;
reg              auto_play_en;
reg [31:0]       auto_cnt;
reg [2:0]        img_found_count;
reg [1:0]        img_idx;              // 当前真正显示中的图片编号
reg [1:0]        load_idx;             // 当前正在写入的图片编号
reg [1:0]        loaded_slot;          // 预加载进度：下一个要写的槽
reg              all_loaded;           // 4 张图已全部写入 SDRAM
reg [31:0]       img_sector0;
reg [31:0]       img_sector1;
reg [31:0]       img_sector2;
reg [31:0]       img_sector3;
reg              load_busy;

// bmp_ready 先表示“源文件读取/送 FIFO 完成”；真正切显示要等 write_finish_toggle 同步后
reg              source_done_seen;

// 同步 mem_clk 域的 write_finish_toggle
reg [2:0]        wrfin_tgl_sync;
wire             write_finish_pulse;

wire auto_tick;

assign write_en   = scale_out_valid;
assign write_data = {scale_out_data[23:16], scale_out_data[15:8], scale_out_data[7:0], 8'b0};
assign img_idx_o  = img_idx;
assign auto_tick  = (auto_cnt == (CLK_FREQ_HZ * AUTO_PERIOD_S - 1));
assign write_finish_pulse = wrfin_tgl_sync[2] ^ wrfin_tgl_sync[1];

// ---- 临时诊断计数器 ----
reg [23:0] dbg_wr_cnt;
reg        dbg_finish_seen;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        dbg_wr_cnt     <= 24'd0;
        dbg_finish_seen <= 1'b0;
    end else begin
        if (write_en && (dbg_wr_cnt != 24'hFFFFFF))
            dbg_wr_cnt <= dbg_wr_cnt + 24'd1;
        if (write_finish_pulse)
            dbg_finish_seen <= 1'b1;
    end
end
assign dbg_found = {1'b0, img_found_count};
// 距满帧（307200）还差多少像素：按 /64 显示成 2 位十六进制，
// 满帧 = 00；差 1 行(640) = 0A；差 8 行 = 50
wire [23:0] dbg_cnt_sat = (dbg_wr_cnt > 24'd307200) ? 24'd307200 : dbg_wr_cnt;
wire [23:0] dbg_def     = 24'd307200 - dbg_cnt_sat;
wire [23:0] dbg_def64   = dbg_def >> 6;
assign dbg_def_t = (dbg_def64 > 24'd255) ? 4'hF : dbg_def64[7:4];
assign dbg_def_o = (dbg_def64 > 24'd255) ? 4'hF : dbg_def64[3:0];
assign dbg_flags = {display_valid, load_busy, source_done_seen, dbg_finish_seen};
assign dbg_scale_bypass = scale_bypass;

key_press_debounce #(
    .CLK_FREQ_HZ (CLK_FREQ_HZ),
    .DEBOUNCE_MS (20)
) u_key_next (
    .clk        (clk),
    .rst        (rst),
    .button_in  (key_next),
    .press_pulse(key_next_press)
);

key_press_debounce #(
    .CLK_FREQ_HZ (CLK_FREQ_HZ),
    .DEBOUNCE_MS (20)
) u_key_auto (
    .clk        (clk),
    .rst        (rst),
    .button_in  (key_auto),
    .press_pulse(key_auto_press)
);

function [1:0] next_index_limited;
    input [1:0] cur;
    input [2:0] count;
    begin
        case (count)
            3'd0: next_index_limited = 2'd0;
            3'd1: next_index_limited = 2'd0;
            3'd2: next_index_limited = (cur == 2'd1) ? 2'd0 : (cur + 2'd1);
            3'd3: next_index_limited = (cur == 2'd2) ? 2'd0 : (cur + 2'd1);
            default: next_index_limited = (cur == 2'd3) ? 2'd0 : (cur + 2'd1);
        endcase
    end
endfunction

function [31:0] sector_lut;
    input [1:0] idx;
    begin
        case (idx)
            2'd0: sector_lut = img_sector0;
            2'd1: sector_lut = img_sector1;
            2'd2: sector_lut = img_sector2;
            2'd3: sector_lut = img_sector3;
            default: sector_lut = img_sector0;
        endcase
    end
endfunction

always @(posedge clk or posedge rst) begin
    if (rst) begin
        wrfin_tgl_sync   <= 3'b000;
        scan_start_pulse <= 1'b0;
        load_start_pulse <= 1'b0;
        load_sector      <= 32'd0;
        scan_kicked      <= 1'b0;
        auto_play_en     <= 1'b0;
        auto_cnt         <= 32'd0;
        img_found_count  <= 3'd0;
        img_idx          <= 2'd0;
        load_idx         <= 2'd0;
        loaded_slot      <= 2'd0;
        all_loaded       <= 1'b0;
        write_buf_idx    <= 2'd0;
        disp_buf_idx     <= 2'd0;
        img_sector0      <= 32'd0;
        img_sector1      <= 32'd0;
        img_sector2      <= 32'd0;
        img_sector3      <= 32'd0;
        load_busy        <= 1'b0;
        source_done_seen <= 1'b0;
        display_valid    <= 1'b0;
    end else begin
        wrfin_tgl_sync   <= {wrfin_tgl_sync[1:0], write_finish_toggle};
        scan_start_pulse <= 1'b0;
        load_start_pulse <= 1'b0;

        if (!sd_init_done) begin
            scan_kicked      <= 1'b0;
            auto_play_en     <= 1'b0;
            auto_cnt         <= 32'd0;
            img_found_count  <= 3'd0;
            img_idx          <= 2'd0;
            load_idx         <= 2'd0;
            loaded_slot      <= 2'd0;
            all_loaded       <= 1'b0;
            write_buf_idx    <= 2'd0;
            disp_buf_idx     <= 2'd0;
            img_sector0      <= 32'd0;
            img_sector1      <= 32'd0;
            img_sector2      <= 32'd0;
            img_sector3      <= 32'd0;
            load_busy        <= 1'b0;
            source_done_seen <= 1'b0;
            display_valid    <= 1'b0;
        end else begin
            // 扫描阶段缓存前 4 张图的起始 sector
            if (scan_found_valid) begin
                case (img_found_count)
                    3'd0: img_sector0 <= scan_found_sector;
                    3'd1: img_sector1 <= scan_found_sector;
                    3'd2: img_sector2 <= scan_found_sector;
                    3'd3: img_sector3 <= scan_found_sector;
                    default: ;
                endcase

                if (img_found_count < 3'd4)
                    img_found_count <= img_found_count + 3'd1;
            end

            // 记住 bmp_read 已经把源图送完 FIFO，但还不能切显示，得等整帧写完
            if (load_busy && (bmp_ready || scale_done))
                source_done_seen <= 1'b1;

            // 整帧写完：该槽有效；还有图就继续加载下一槽，全部完成才开显示
            if (load_busy && source_done_seen && write_finish_pulse) begin
                load_busy        <= 1'b0;
                source_done_seen <= 1'b0;

                if (({1'b0, loaded_slot} + 3'd1) >= img_found_count) begin
                    all_loaded    <= 1'b1;
                    disp_buf_idx  <= 2'd0;
                    img_idx       <= 2'd0;
                    display_valid <= 1'b1;
                end else begin
                    loaded_slot <= loaded_slot + 2'd1;
                end
            end

            // 上电后自动发起一次“扫描前 4 张 BMP”
            if (!scan_kicked && bmp_ready) begin
                scan_start_pulse <= 1'b1;
                scan_kicked      <= 1'b1;
                auto_play_en     <= 1'b0;
                auto_cnt         <= 32'd0;
                img_found_count  <= 3'd0;
                img_idx          <= 2'd0;
                load_idx         <= 2'd0;
                loaded_slot      <= 2'd0;
                all_loaded       <= 1'b0;
                write_buf_idx    <= 2'd0;
                disp_buf_idx     <= 2'd0;
                display_valid    <= 1'b0;
                load_busy        <= 1'b0;
                source_done_seen <= 1'b0;
            end else begin
                // 预加载：按槽顺序把前 N 张图全部写进 SDRAM
                //   写哪一张就写进哪个槽，之后显示只需改 read_addr_index
                if (scan_done && !all_loaded && bmp_ready && !load_busy &&
                    (img_found_count != 3'd0) &&
                    ({1'b0, loaded_slot} < img_found_count)) begin
                    load_idx         <= loaded_slot;
                    load_sector      <= sector_lut(loaded_slot);
                    write_buf_idx    <= loaded_slot;
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                end

                // 全部预载完成：切换只改槽号，不再写 SDRAM
                if (all_loaded) begin
                    img_idx <= disp_buf_idx;

                    if (key_next_press)
                        disp_buf_idx <= next_index_limited(disp_buf_idx, img_found_count);

                    if (key_auto_press && (img_found_count > 3'd1)) begin
                        auto_play_en <= ~auto_play_en;
                        auto_cnt     <= 32'd0;
                    end

                    if (auto_play_en && (img_found_count > 3'd1)) begin
                        if (auto_tick) begin
                            auto_cnt     <= 32'd0;
                            disp_buf_idx <= next_index_limited(disp_buf_idx, img_found_count);
                        end else begin
                            auto_cnt <= auto_cnt + 32'd1;
                        end
                    end else begin
                        auto_cnt <= 32'd0;
                    end
                end
            end
        end
    end
end

bmp_read bmp_read_m0(
    .clk                    (clk),
    .rst                    (rst),
    .ready                  (bmp_ready),

    .scan_start             (scan_start_pulse),
    .scan_start_sector      (SCAN_START_SECTOR),
    .scan_max_sector        (SCAN_MAX_SECTOR),
    .scan_target_count      (SCAN_TARGET_COUNT),
    .scan_done              (scan_done),
    .scan_found_valid       (scan_found_valid),
    .scan_found_sector      (scan_found_sector),
    .scan_found_total       (scan_found_total),

    .load_start             (load_start_pulse),
    .load_sector            (load_sector),

    .sd_init_done           (sd_init_done),
    .state_code             (state_code),
    .bmp_width              (bmp_width),
    .bmp_height             (bmp_height),
    .write_req              (write_req),
    .write_req_ack          (write_req_ack),
    .sd_sec_read            (sd_sec_read),
    .sd_sec_read_addr       (sd_sec_read_addr),
    .sd_sec_read_data       (sd_sec_read_data),
    .sd_sec_read_data_valid (sd_sec_read_data_valid),
    .sd_sec_read_end        (sd_sec_read_end),
    .bmp_data_wr_en         (bmp_src_valid),
    .bmp_data               (bmp_src_data),
    .src_ready              (scale_src_ready),
    .bmp_src_config         (bmp_src_config),
    .bmp_src_width          (bmp_src_width),
    .bmp_src_height         (bmp_src_height),
    .bmp_src_sop            (bmp_src_sop),
    .bmp_src_eof            (bmp_src_eof)
);

bmp_scale #(
    .DST_W       (640),
    .DST_H       (480),
    .MAX_SRC_W   (1920),
    .MAX_SRC_H   (1080)
) u_bmp_scale (
    .clk        (clk),
    .rst        (rst),
    .src_valid  (bmp_src_valid),
    .src_data   (bmp_src_data),
    .src_config (bmp_src_config),
    .src_width  (bmp_src_width),
    .src_height (bmp_src_height),
    .out_valid  (scale_out_valid),
    .out_data   (scale_out_data),
    .out_done   (scale_done),
    .src_ready  (scale_src_ready),
    .src_eof    (bmp_src_eof),
    .dbg_bypass (scale_bypass)
);

sd_card_top sd_card_top_m0(
    .clk                    (clk),
    .rst                    (rst),
    .SD_nCS                 (SD_nCS),
    .SD_DCLK                (SD_DCLK),
    .SD_MOSI                (SD_MOSI),
    .SD_MISO                (SD_MISO),
    .sd_init_done           (sd_init_done),
    .sd_sec_read            (sd_sec_read),
    .sd_sec_read_addr       (sd_sec_read_addr),
    .sd_sec_read_data       (sd_sec_read_data),
    .sd_sec_read_data_valid (sd_sec_read_data_valid),
    .sd_sec_read_end        (sd_sec_read_end),
    .sd_sec_write           (1'b0),
    .sd_sec_write_addr      (32'd0),
    .sd_sec_write_data      (),
    .sd_sec_write_data_req  (),
    .sd_sec_write_end       ()
);

endmodule

module key_press_debounce #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer DEBOUNCE_MS = 20
)(
    input  wire clk,
    input  wire rst,
    input  wire button_in,    // 默认：松开=1，按下=0
    output reg  press_pulse
);

localparam integer DEBOUNCE_CYCLES = (CLK_FREQ_HZ / 1000) * DEBOUNCE_MS;

reg button_sync0;
reg button_sync1;
reg button_stable;
reg [31:0] cnt;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        button_sync0  <= 1'b1;
        button_sync1  <= 1'b1;
        button_stable <= 1'b1;
        cnt           <= 32'd0;
        press_pulse   <= 1'b0;
    end else begin
        button_sync0 <= button_in;
        button_sync1 <= button_sync0;
        press_pulse  <= 1'b0;

        if (button_sync1 == button_stable) begin
            cnt <= 32'd0;
        end else begin
            if (cnt >= DEBOUNCE_CYCLES - 1) begin
                if (button_stable && !button_sync1)
                    press_pulse <= 1'b1;
                button_stable <= button_sync1;
                cnt           <= 32'd0;
            end else begin
                cnt <= cnt + 32'd1;
            end
        end
    end
end

endmodule
