//=============================================================================
// tb_bmp_read.v — bmp_read 自检（小 BMP / 行填充 / 源配置 / 像素顺序）
//-----------------------------------------------------------------------------
// 构造一张 5×3、24bit、bottom-up BMP，每行 stride=16（15 像素字节 + 1 填充）。
// 验证：
//   1) 扫描能识别任意尺寸（5×3）BMP；
//   2) 加载输出 15 个像素，BGR→RGB 顺序正确；
//   3) 行填充字节 0xEE 不会被当成像素；
//   4) bmp_src_config / sop / eof、width/height 正确。
//=============================================================================
`timescale 1ns / 1ps

module tb_bmp_read;

    reg         clk = 1'b0;
    reg         rst = 1'b1;
    always #5 clk = ~clk;

    reg  [7:0]  mem [0:4095];

    reg         scan_start = 1'b0;
    reg  [31:0] scan_start_sector = 32'd0;
    reg  [31:0] scan_max_sector   = 32'd131071;
    reg  [2:0]  scan_target_count = 3'd1;
    wire        scan_done;
    wire        scan_found_valid;
    wire [31:0] scan_found_sector;
    wire [2:0]  scan_found_total;

    reg         load_start = 1'b0;
    reg  [31:0] load_sector = 32'd0;
    wire        ready;
    wire [3:0]  state_code;

    wire        sd_sec_read;
    wire [31:0] sd_sec_read_addr;
    wire [7:0]  sd_sec_read_data;
    wire        sd_sec_read_data_valid;
    wire        sd_sec_read_end;

    reg         write_req;
    reg         write_req_ack = 1'b0;

    wire        bmp_data_wr_en;
    wire [23:0] bmp_data;
    wire        bmp_src_config;
    wire [15:0] bmp_src_width;
    wire [15:0] bmp_src_height;
    wire        bmp_src_sop;
    wire        bmp_src_eof;

    // SD 扇区模型
    reg         sd_active = 1'b0;
    reg [9:0]   sd_cnt = 10'd0;
    reg [31:0]  sd_lat = 32'd0;
    reg [7:0]   sd_data = 8'd0;
    reg         sd_valid = 1'b0;
    reg         sd_end = 1'b0;
    reg         sd_need_low = 1'b0;

    assign sd_sec_read_data      = sd_data;
    assign sd_sec_read_data_valid = sd_valid;
    assign sd_sec_read_end       = sd_end;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            sd_active <= 1'b0;
            sd_cnt    <= 10'd0;
            sd_lat    <= 32'd0;
            sd_data   <= 8'd0;
            sd_valid  <= 1'b0;
            sd_end    <= 1'b0;
            sd_need_low <= 1'b0;
        end else begin
            sd_valid <= 1'b0;
            sd_end   <= 1'b0;

            if (!sd_sec_read) begin
                sd_active   <= 1'b0;
                sd_cnt      <= 10'd0;
                sd_need_low <= 1'b0;
            end else if (!sd_active && !sd_need_low) begin
                sd_active <= 1'b1;
                sd_lat    <= sd_sec_read_addr;
                sd_cnt    <= 10'd1;
                sd_valid  <= 1'b1;
                sd_data   <= mem[sd_sec_read_addr * 512];
            end else if (sd_cnt < 10'd512) begin
                sd_valid <= 1'b1;
                sd_data  <= mem[sd_lat * 512 + sd_cnt];
                sd_cnt   <= sd_cnt + 10'd1;
            end else begin
                sd_end      <= 1'b1;
                sd_active   <= 1'b0;
                sd_need_low <= 1'b1;
            end
        end
    end

    always @(posedge clk or posedge rst) begin
        if (rst)
            write_req_ack <= 1'b0;
        else
            write_req_ack <= write_req;
    end

    bmp_read dut (
        .clk                    (clk),
        .rst                    (rst),
        .ready                  (ready),
        .scan_start             (scan_start),
        .scan_start_sector      (scan_start_sector),
        .scan_max_sector        (scan_max_sector),
        .scan_target_count      (scan_target_count),
        .scan_done              (scan_done),
        .scan_found_valid       (scan_found_valid),
        .scan_found_sector      (scan_found_sector),
        .scan_found_total       (scan_found_total),
        .load_start             (load_start),
        .load_sector            (load_sector),
        .sd_init_done           (1'b1),
        .state_code             (state_code),
        .bmp_width              (16'd1920),
        .bmp_height             (16'd1080),
        .write_req              (write_req),
        .write_req_ack          (write_req_ack),
        .sd_sec_read            (sd_sec_read),
        .sd_sec_read_addr       (sd_sec_read_addr),
        .sd_sec_read_data       (sd_sec_read_data),
        .sd_sec_read_data_valid (sd_sec_read_data_valid),
        .sd_sec_read_end        (sd_sec_read_end),
        .bmp_data_wr_en         (bmp_data_wr_en),
        .bmp_data               (bmp_data),
        .src_ready              (1'b1),
        .bmp_src_config         (bmp_src_config),
        .bmp_src_width          (bmp_src_width),
        .bmp_src_height         (bmp_src_height),
        .bmp_src_sop            (bmp_src_sop),
        .bmp_src_eof            (bmp_src_eof)
    );

    integer errors = 0;
    integer pix_cnt = 0;
    integer cfg_seen = 0;
    integer sop_seen = 0;
    integer eof_seen = 0;

    // 构造 BMP：5×3，24bit，bottom-up，stride=16
    initial begin : make_bmp
        integer r, x;
        for (r = 0; r < 4096; r = r + 1)
            mem[r] = 8'd0;

        mem[0]  = 8'h42;  // B
        mem[1]  = 8'h4D;  // M
        mem[2]  = 8'd102; // file_size = 54 + 16*3
        mem[10] = 8'd54;  // pixel offset
        mem[14] = 8'd40;  // DIB size
        mem[18] = 8'd5;   // width
        mem[22] = 8'd3;   // height
        mem[26] = 8'd1;   // planes
        mem[28] = 8'd24;  // bpp
        mem[30] = 8'd0;   // BI_RGB
        mem[34] = 8'd48;  // image size = 16*3

        for (r = 0; r < 3; r = r + 1) begin
            for (x = 0; x < 5; x = x + 1) begin
                // BGR 小端
                mem[54 + r * 16 + x * 3 + 0] = r * 10 + x + 1;
                mem[54 + r * 16 + x * 3 + 1] = r * 10 + x + 2;
                mem[54 + r * 16 + x * 3 + 2] = r * 10 + x + 3;
            end
            // 行填充：绝不能当成像素
            mem[54 + r * 16 + 15] = 8'hEE;
        end
    end

    // 像素检查
    always @(posedge clk) begin
        if (rst) begin
            pix_cnt  = 0;
            cfg_seen = 0;
            sop_seen = 0;
            eof_seen = 0;
        end else begin
            if (bmp_src_config)
                cfg_seen = 1;
            if (bmp_src_sop)
                sop_seen = 1;
            if (bmp_src_eof)
                eof_seen = 1;

            if (bmp_data_wr_en) begin
                begin : check_pix
                    integer r, x;
                    reg [7:0] er, eg, eb;
                    reg [23:0] exp;
                    r = pix_cnt / 5;
                    x = pix_cnt % 5;
                    er = r * 10 + x + 3;
                    eg = r * 10 + x + 2;
                    eb = r * 10 + x + 1;
                    exp = {er, eg, eb};
                    if ((r >= 3) || (bmp_data !== exp)) begin
                        $display("FAIL pixel %0d: got=%06h exp=%06h", pix_cnt, bmp_data, exp);
                        errors = errors + 1;
                    end
                end
                pix_cnt = pix_cnt + 1;
            end
        end
    end

    initial begin
        repeat (5) @(posedge clk);
        rst <= 1'b0;
        repeat (3) @(posedge clk);

        // 扫描
        @(posedge clk);
        scan_start <= 1'b1;
        @(posedge clk);
        scan_start <= 1'b0;

        begin : wait_scan
            integer t;
            t = 0;
            while (!scan_done && (t < 20000)) begin
                @(posedge clk);
                t = t + 1;
            end
            if (!scan_done) begin
                $display("TIMEOUT scan");
                errors = errors + 1;
            end
        end
        if (scan_found_total != 1) begin
            $display("FAIL scan_found_total=%0d", scan_found_total);
            errors = errors + 1;
        end

        // 加载
        @(posedge clk);
        load_start <= 1'b1;
        load_sector <= 32'd0;
        @(posedge clk);
        load_start <= 1'b0;

        begin : wait_load
            integer t;
            t = 0;
            while ((pix_cnt < 15) && (t < 20000)) begin
                @(posedge clk);
                t = t + 1;
            end
            while (!eof_seen && (t < 20000)) begin
                @(posedge clk);
                t = t + 1;
            end
        end

        if (pix_cnt != 15) begin
            $display("FAIL pixel count=%0d (expect 15)", pix_cnt);
            $display("DBG state=%0d len=%0d src_y=%0d rowbc=%0d valid=%b hdr_r=%b wr=%b ack=%b sdr=%b sde=%b",
                     dut.state, dut.bmp_len_cnt, dut.src_y, dut.row_byte_cnt,
                     dut.bmp_data_valid, dut.header_match_r, dut.write_req,
                     dut.write_req_ack_s, dut.sd_sec_read, dut.sd_sec_read_end);
            $display("DBG width=%0d height=%0d stride=%0d pixel_off=%0d file_len=%0d",
                     dut.width, dut.height, dut.row_stride_r, dut.pixel_offset, dut.file_len);
            errors = errors + 1;
        end
        if ((bmp_src_width != 5) || (bmp_src_height != 3)) begin
            $display("FAIL src size=%0dx%0d", bmp_src_width, bmp_src_height);
            errors = errors + 1;
        end
        if (!cfg_seen || !sop_seen || !eof_seen) begin
            $display("FAIL pulses: cfg=%0d sop=%0d eof=%0d", cfg_seen, sop_seen, eof_seen);
            errors = errors + 1;
        end

        $display("--------------------------------------------------");
        if (errors == 0)
            $display("tb_bmp_read: PASS");
        else
            $display("tb_bmp_read: %0d errors", errors);
        $display("--------------------------------------------------");
        $finish;
    end

endmodule
