//=============================================================================
// bmp_read.v — BMP 文件定位与像素搬运
//-----------------------------------------------------------------------------
// 功能：
//   1) 扫描模式（scan_start）：从 scan_start_sector 起逐扇区读取，用 54B
//      文件头判断 "BM" + 24bit + 不压缩 + 正高度 + 宽高不超过上限，
//      记录最多 4 张图的起始扇区；命中后按“文件长度向上取整的扇区数”跳读，
//      未命中则 +1 扇区。
//   2) 加载模式（load_start）：读文件头 → 发 write_req 给帧缓存（拿到 ack
//      后从头重读数据区）→ 每 3 字节拼成 24bit 像素（BMP 为 BGR 小端），
//      跳过每行 4 字节对齐填充；输出源像素流给 bmp_scale。
//   3) src_ready 反压：FIFO 高水位时在扇区边界暂停 sd_sec_read，
//      避免小图放大/上下黑边时源像素被丢弃。
//
// 时钟/复位：clk = 100MHz；rst 高有效；sd_init_done=0 时强制回 IDLE。
//
// 接口：
//   扫描：scan_start / scan_start_sector[31:0] / scan_max_sector[31:0] /
//         scan_target_count[2:0] → scan_done / scan_found_valid /
//         scan_found_sector[31:0] / scan_found_total[2:0]
//   加载：load_start / load_sector[31:0]
//   帧缓存：write_req / write_req_ack
//   SD：sd_sec_read / sd_sec_read_addr[31:0] / sd_sec_read_data[7:0] /
//       sd_sec_read_data_valid / sd_sec_read_end
//   输出：bmp_data_wr_en / bmp_data[23:0]（BGR→RGB 已交换）
//         bmp_src_config / bmp_src_width / bmp_src_height / bmp_src_sop / bmp_src_eof
//   输入：src_ready（bmp_scale FIFO 反压）
//   状态：state_code[3:0]
//
// 常量：
//   ST_IDLE / ST_SCAN / ST_LOAD_HDR / ST_LOAD_WAIT / ST_LOAD_DATA
//   BMP 头偏移：文件长度 2、像素偏移 10、宽 18、高 22、位深 28、压缩 30
//
// 内部例化：无
//
// 备注：
//   write_req_ack 为 2FF 同步；header_match / file_sector_count 各打一拍，
//   用于切断 100MHz 长组合路径（M1 时序修复点）。
//=============================================================================
module bmp_read(
    input                       clk,
    input                       rst,
    output                      ready,

    // 上电扫描：从 scan_start_sector 开始，顺序寻找前 scan_target_count 张 BMP
    input                       scan_start,
    input  [31:0]               scan_start_sector,
    input  [31:0]               scan_max_sector,
    input  [2:0]                scan_target_count,
    output reg                  scan_done,
    output reg                  scan_found_valid,
    output reg [31:0]           scan_found_sector,
    output reg [2:0]            scan_found_total,

    // 按指定扇区加载一张图到 SDRAM
    input                       load_start,
    input  [31:0]               load_sector,

    input                       sd_init_done,
    output reg [3:0]            state_code,
    input  [15:0]               bmp_width,
    input  [15:0]               bmp_height,

    output reg                  write_req,
    input                       write_req_ack,

    output reg                  sd_sec_read,
    output reg [31:0]           sd_sec_read_addr,
    input  [7:0]                sd_sec_read_data,
    input                       sd_sec_read_data_valid,
    input                       sd_sec_read_end,

    output reg                  bmp_data_wr_en,
    output reg [23:0]           bmp_data,

    input                       src_ready,     // 缩放 FIFO 未到高水位
    output reg                  bmp_src_config,
    output wire [15:0]          bmp_src_width,
    output wire [15:0]          bmp_src_height,
    output reg                  bmp_src_sop,
    output reg                  bmp_src_eof
);

localparam ST_IDLE      = 3'd0;
localparam ST_SCAN      = 3'd1;
localparam ST_LOAD_HDR  = 3'd2;
localparam ST_LOAD_WAIT = 3'd3;
localparam ST_LOAD_DATA = 3'd4;

reg [2:0]  state;
reg [9:0]  rd_cnt;

reg [7:0]  header_0;
reg [7:0]  header_1;
reg [31:0] file_len;
reg [31:0] pixel_offset;
reg [31:0] width;
reg [31:0] height;
reg [15:0] bit_count;
reg [31:0] compression;

reg [31:0] scan_sector;
reg [31:0] load_sector_latched;
reg [31:0] bmp_len_cnt;
reg [1:0]  bmp_byte_idx;

reg [15:0] src_x, src_y;
reg [15:0] row_byte_cnt;
reg        load_pause;

// 当前字节在像素中的相位（0/1/2）。行首字节强制为 0：这样即使行末有
// 数据空拍（真实 SPI 每 8 拍才来 1 字节）或该行有 4 字节填充，相位也不会错。
wire [1:0] cur_phase = (row_byte_cnt == 16'd0) ? 2'd0 : bmp_byte_idx;

// 行字节数/stride 在文件头解析后寄存，避免每字节都走 width*3+对齐的长组合路径
reg  [16:0] row_pixel_bytes_r;
reg  [16:0] row_stride_r;

assign bmp_src_width  = width[15:0];
assign bmp_src_height = height[15:0];

wire header_match;
wire bmp_data_valid;
wire [31:0] next_scan_sector_if_match;
wire [31:0] next_scan_sector_if_miss;

// write_req_ack 来自 125MHz SDRAM 域，先 2FF 同步到 100MHz 再用于状态机
reg  [1:0]  write_ack_sync;
wire        write_req_ack_s = write_ack_sync[1];

always @(posedge clk or posedge rst) begin
    if (rst)
        write_ack_sync <= 2'b00;
    else
        write_ack_sync <= {write_ack_sync[0], write_req_ack};
end

assign ready = (state == ST_IDLE);
// bmp_width/bmp_height 在缩放版里表示“允许的最大宽/高”（top 传 1920/1080）。
// 只接受正高度（bottom-up）、24bit、非压缩；具体尺寸由 bmp_scale 适配。
assign header_match = (header_0 == "B") &&
                      (header_1 == "M") &&
                      (width  != 32'd0) &&
                      (height != 32'd0) &&
                      (height[31] == 1'b0) &&
                      (width[31:16] == 16'd0) &&
                      (height[31:16] == 16'd0) &&
                      (width[15:0]  <= bmp_width) &&
                      (height[15:0] <= bmp_height) &&
                      (bit_count    == 16'd24) &&
                      (compression  == 32'd0);

// header_match 是 32bit 比较 + 多字段与，扇出到扫描地址/写请求；
// 先打一拍再给状态机，避免 100MHz 下的长组合路径（M1 报告 -0.496ns）。
reg header_match_r;
always @(posedge clk or posedge rst) begin
    if (rst)
        header_match_r <= 1'b0;
    else
        header_match_r <= header_match;
end
assign bmp_data_valid = (sd_sec_read_data_valid == 1'b1) &&
                        (bmp_len_cnt >= pixel_offset) &&
                        (bmp_len_cnt <  file_len) &&
                        (src_y < height[15:0]) &&
                        ({1'b0, row_byte_cnt} < row_pixel_bytes_r);
// file_sector_count 由 file_len 组合计算，会扇出到扫描地址/状态机；
// 打一拍后再用，消除 100MHz 长路径（M1 报告 -0.086ns）。
reg [31:0] file_sector_count_r;
always @(posedge clk or posedge rst) begin
    if (rst)
        file_sector_count_r <= 32'd1;
    else
        file_sector_count_r <= (file_len == 32'd0) ? 32'd1 : ((file_len + 32'd511) >> 9);
end

assign next_scan_sector_if_match = scan_sector + file_sector_count_r;
assign next_scan_sector_if_miss  = scan_sector + 32'd1;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        rd_cnt <= 10'd0;
    end else if ((state == ST_SCAN) || (state == ST_LOAD_HDR)) begin
        if (sd_sec_read_data_valid)
            rd_cnt <= rd_cnt + 10'd1;
        else if (sd_sec_read_end)
            rd_cnt <= 10'd0;
    end else begin
        rd_cnt <= 10'd0;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        header_0     <= 8'd0;
        header_1     <= 8'd0;
        file_len     <= 32'd0;
        pixel_offset <= 32'd54;
        width        <= 32'd0;
        height       <= 32'd0;
        bit_count    <= 16'd0;
        compression  <= 32'd0;
    end else if (((state == ST_SCAN) || (state == ST_LOAD_HDR)) && sd_sec_read_data_valid) begin
        case (rd_cnt)
            10'd0 : header_0 <= sd_sec_read_data;
            10'd1 : header_1 <= sd_sec_read_data;

            10'd2 : file_len[7:0] <= sd_sec_read_data;
            10'd3 : file_len[15:8] <= sd_sec_read_data;
            10'd4 : file_len[23:16] <= sd_sec_read_data;
            10'd5 : file_len[31:24] <= sd_sec_read_data;

            10'd10: pixel_offset[7:0] <= sd_sec_read_data;
            10'd11: pixel_offset[15:8] <= sd_sec_read_data;
            10'd12: pixel_offset[23:16] <= sd_sec_read_data;
            10'd13: pixel_offset[31:24] <= sd_sec_read_data;

            10'd18: width[7:0] <= sd_sec_read_data;
            10'd19: width[15:8] <= sd_sec_read_data;
            10'd20: width[23:16] <= sd_sec_read_data;
            10'd21: width[31:24] <= sd_sec_read_data;

            10'd22: height[7:0] <= sd_sec_read_data;
            10'd23: height[15:8] <= sd_sec_read_data;
            10'd24: height[23:16] <= sd_sec_read_data;
            10'd25: height[31:24] <= sd_sec_read_data;

            10'd28: bit_count[7:0] <= sd_sec_read_data;
            10'd29: bit_count[15:8] <= sd_sec_read_data;

            10'd30: compression[7:0] <= sd_sec_read_data;
            10'd31: compression[15:8] <= sd_sec_read_data;
            10'd32: compression[23:16] <= sd_sec_read_data;
            10'd33: compression[31:24] <= sd_sec_read_data;
            default: ;
        endcase
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        bmp_len_cnt <= 32'd0;
    end else if (state == ST_LOAD_DATA) begin
        if (sd_sec_read_data_valid)
            bmp_len_cnt <= bmp_len_cnt + 32'd1;
    end else begin
        bmp_len_cnt <= 32'd0;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        src_x        <= 16'd0;
        src_y        <= 16'd0;
        row_byte_cnt <= 16'd0;
    end else if (state != ST_LOAD_DATA) begin
        src_x        <= 16'd0;
        src_y        <= 16'd0;
        row_byte_cnt <= 16'd0;
    end else if (sd_sec_read_data_valid &&
                 (bmp_len_cnt >= pixel_offset) &&
                 (src_y < height[15:0])) begin
        if (row_byte_cnt == row_stride_r[15:0] - 16'd1) begin
            row_byte_cnt <= 16'd0;
            src_y        <= src_y + 16'd1;
            src_x        <= 16'd0;
        end else begin
            row_byte_cnt <= row_byte_cnt + 16'd1;
            if (bmp_data_valid && (cur_phase == 2'd2))
                src_x <= src_x + 16'd1;
        end
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        bmp_byte_idx <= 2'd0;
    end else if (state == ST_LOAD_DATA) begin
        // 绝不能在行末字节之前清零相位（那会让该行最后一个像素丢失，
        // 每行少 1 个像素 -> 逐行累积成斜切）。相位只跟随有效字节推进。
        if (bmp_data_valid)
            bmp_byte_idx <= (cur_phase == 2'd2) ? 2'd0 : (cur_phase + 2'd1);
        else if (row_byte_cnt == 16'd0)
            bmp_byte_idx <= 2'd0;
    end else begin
        bmp_byte_idx <= 2'd0;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        bmp_data_wr_en <= 1'b0;
        bmp_data       <= 24'd0;
        bmp_src_sop    <= 1'b0;
    end else if (state == ST_LOAD_DATA) begin
        bmp_src_sop <= 1'b0;
        if (bmp_data_valid) begin
            case (cur_phase)
                2'd0: begin
                    bmp_data_wr_en <= 1'b0;
                    bmp_data[7:0]  <= sd_sec_read_data;
                end
                2'd1: begin
                    bmp_data_wr_en <= 1'b0;
                    bmp_data[15:8] <= sd_sec_read_data;
                end
                2'd2: begin
                    bmp_data_wr_en  <= 1'b1;
                    bmp_data[23:16] <= sd_sec_read_data;
                    // 每个源行第一个像素给出行首标志：让缩放器/写通路以“真实行边界”
                    // 对齐，而不是靠数像素推断。任何行内丢/多一个像素都不会累积成斜切。
                    if (src_x == 16'd0)
                        bmp_src_sop <= 1'b1;
                end
                default: begin
                    bmp_data_wr_en <= 1'b0;
                end
            endcase
        end else begin
            bmp_data_wr_en <= 1'b0;
        end
    end else begin
        bmp_data_wr_en <= 1'b0;
        bmp_src_sop    <= 1'b0;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state             <= ST_IDLE;
        state_code        <= 4'd0;
        sd_sec_read       <= 1'b0;
        sd_sec_read_addr  <= 32'd0;
        write_req         <= 1'b0;
        scan_done         <= 1'b0;
        scan_found_valid  <= 1'b0;
        scan_found_sector <= 32'd0;
        scan_found_total  <= 3'd0;
        scan_sector       <= 32'd0;
        load_sector_latched <= 32'd0;
        bmp_src_config    <= 1'b0;
        bmp_src_eof       <= 1'b0;
        load_pause        <= 1'b0;
        row_pixel_bytes_r <= 17'd0;
        row_stride_r      <= 17'd0;
    end else if (!sd_init_done) begin
        state             <= ST_IDLE;
        state_code        <= 4'd0;
        sd_sec_read       <= 1'b0;
        sd_sec_read_addr  <= 32'd0;
        write_req         <= 1'b0;
        scan_done         <= 1'b0;
        scan_found_valid  <= 1'b0;
        scan_found_sector <= 32'd0;
        scan_found_total  <= 3'd0;
        scan_sector       <= 32'd0;
        load_sector_latched <= 32'd0;
        bmp_src_config    <= 1'b0;
        bmp_src_eof       <= 1'b0;
        load_pause        <= 1'b0;
        row_pixel_bytes_r <= 17'd0;
        row_stride_r      <= 17'd0;
    end else begin
        scan_found_valid <= 1'b0;
        bmp_src_config   <= 1'b0;
        bmp_src_eof      <= 1'b0;

        case (state)
            ST_IDLE: begin
                state_code  <= 4'd1;
                sd_sec_read <= 1'b0;
                write_req   <= 1'b0;

                if (scan_start) begin
                    scan_done        <= 1'b0;
                    scan_found_total <= 3'd0;
                    scan_sector      <= scan_start_sector;
                    sd_sec_read_addr <= scan_start_sector;
                    state            <= ST_SCAN;
                end else if (load_start) begin
                    load_sector_latched <= load_sector;
                    sd_sec_read_addr    <= load_sector;
                    load_pause          <= 1'b0;
                    bmp_src_eof         <= 1'b0;
                    state               <= ST_LOAD_HDR;
                end
            end

            ST_SCAN: begin
                state_code  <= 4'd2;
                sd_sec_read <= 1'b1;

                if (sd_sec_read_end) begin
                    sd_sec_read <= 1'b0;

                    if (header_match_r) begin
                        scan_found_valid  <= 1'b1;
                        scan_found_sector <= scan_sector;
                        scan_found_total  <= scan_found_total + 3'd1;

                        if ((scan_found_total + 3'd1 >= scan_target_count) || (next_scan_sector_if_match > scan_max_sector)) begin
                            scan_done        <= 1'b1;
                            state            <= ST_IDLE;
                            sd_sec_read_addr <= next_scan_sector_if_match;
                            scan_sector      <= next_scan_sector_if_match;
                        end else begin
                            sd_sec_read_addr <= next_scan_sector_if_match;
                            scan_sector      <= next_scan_sector_if_match;
                        end
                    end else begin
                        if (scan_sector >= scan_max_sector) begin
                            scan_done <= 1'b1;
                            state     <= ST_IDLE;
                        end else begin
                            sd_sec_read_addr <= next_scan_sector_if_miss;
                            scan_sector      <= next_scan_sector_if_miss;
                        end
                    end
                end
            end

            ST_LOAD_HDR: begin
                state_code  <= 4'd2;
                sd_sec_read <= 1'b1;

                if (sd_sec_read_end) begin
                    sd_sec_read <= 1'b0;
                    if (header_match_r) begin
                        write_req        <= 1'b1;
                        sd_sec_read_addr <= load_sector_latched;
                        bmp_src_config   <= 1'b1;   // 给 bmp_scale 锁存 W/H
                        row_pixel_bytes_r <= {1'b0, width[15:0]} * 17'd3;
                        row_stride_r      <= (({1'b0, width[15:0]} * 17'd3) + 17'd3) & ~17'd3;
                        state            <= ST_LOAD_WAIT;
                    end else begin
                        state <= ST_IDLE;
                    end
                end
            end

            ST_LOAD_WAIT: begin
                state_code <= 4'd3;
                if (write_req_ack_s) begin
                    write_req   <= 1'b0;
                    load_pause  <= 1'b0;
                    state       <= ST_LOAD_DATA;
                end
            end

            ST_LOAD_DATA: begin
                state_code <= 4'd4;

                if (sd_sec_read_end && !load_pause) begin
                    sd_sec_read <= 1'b0;
                    if (bmp_len_cnt >= file_len) begin
                        bmp_src_eof <= 1'b1;
                        state       <= ST_IDLE;
                        load_pause  <= 1'b0;
                    end else begin
                        // 必须让 sd_sec_read 至少低一拍：新地址在下一拍才稳定，
                        // 控制器/仿真模型需要看到低电平再启动下一扇区。
                        sd_sec_read_addr <= sd_sec_read_addr + 32'd1;
                        load_pause       <= 1'b1;
                    end
                end else if (load_pause) begin
                    if (src_ready) begin
                        sd_sec_read <= 1'b1;
                        load_pause  <= 1'b0;
                    end
                end else begin
                    sd_sec_read <= 1'b1;
                end
            end

            default: begin
                state       <= ST_IDLE;
                state_code  <= 4'd1;
                sd_sec_read <= 1'b0;
                write_req   <= 1'b0;
            end
        endcase
    end
end

endmodule
