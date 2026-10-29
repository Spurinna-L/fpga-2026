//=============================================================================
// tb_bmp_pipeline.v — bmp_read + bmp_scale 集成自检
//-----------------------------------------------------------------------------
// 构造一张 320×240 的 BMP，让 SD 模型以 1 byte/clock 高速送数，
// 验证：
//   1) bmp_read 解析任意尺寸、bmp_scale 2× 放大；
//   2) src_ready 反压能在扇区边界暂停 SD 读取，不丢像素；
//   3) 输出恰好 640×480，且内容颜色正确（无黑边）。
//=============================================================================
`timescale 1ns / 1ps

module tb_bmp_pipeline;

    localparam integer W = 320;
    localparam integer H = 240;
    localparam integer PIX = 640 * 480;
    localparam integer FILE_BYTES = 54 + W * H * 3;

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #5 clk = ~clk;

    reg [7:0] mem [0:231000];

    reg         scan_start = 1'b0;
    reg  [31:0] scan_sector = 32'd0;
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

    wire        write_req;
    reg         write_req_ack = 1'b0;

    wire        src_valid;
    wire [23:0] src_data;
    wire        src_config;
    wire [15:0] src_width;
    wire [15:0] src_height;
    wire        src_sop;
    wire        src_eof;
    wire        src_ready;

    wire        out_valid;
    wire [23:0] out_data;
    wire        out_done;

    // SD 扇区模型：与 tb_bmp_read 相同的时序
    reg         sd_active = 1'b0;
    reg [9:0]   sd_cnt = 10'd0;
    reg [31:0]  sd_lat = 32'd0;
    reg [7:0]   sd_data = 8'd0;
    reg         sd_valid = 1'b0;
    reg         sd_end = 1'b0;
    reg         sd_need_low = 1'b0;

    assign sd_sec_read_data       = sd_data;
    assign sd_sec_read_data_valid = sd_valid;
    assign sd_sec_read_end        = sd_end;

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

    bmp_read u_read (
        .clk                    (clk),
        .rst                    (rst),
        .ready                  (ready),
        .scan_start             (scan_start),
        .scan_start_sector      (scan_sector),
        .scan_max_sector        (32'd131071),
        .scan_target_count      (3'd1),
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
        .bmp_data_wr_en         (src_valid),
        .bmp_data               (src_data),
        .src_ready              (src_ready),
        .bmp_src_config         (src_config),
        .bmp_src_width          (src_width),
        .bmp_src_height         (src_height),
        .bmp_src_sop            (src_sop),
        .bmp_src_eof            (src_eof)
    );

    bmp_scale #(
        .DST_W     (640),
        .DST_H     (480),
        .MAX_SRC_W (1920),
        .MAX_SRC_H (1080)
    ) u_scale (
        .clk        (clk),
        .rst        (rst),
        .src_valid  (src_valid),
        .src_data   (src_data),
        .src_config (src_config),
        .src_width  (src_width),
        .src_height (src_height),
        .out_valid  (out_valid),
        .out_data   (out_data),
        .out_done   (out_done),
        .src_ready  (src_ready)
    );

    integer errors  = 0;
    integer out_cnt = 0;
    integer done_seen = 0;

    always @(posedge clk) begin
        if (out_valid) begin
            if (out_data !== 24'h996633) begin
                if (errors < 20)
                    $display("FAIL out[%0d]=%06h exp=996633", out_cnt, out_data);
                errors = errors + 1;
            end
            if (out_cnt == PIX - 1)
                done_seen = 1;
            out_cnt = out_cnt + 1;
        end
    end

    // 构造 320×240 BMP，像素 BGR = 33/66/99
    initial begin : make_bmp
        integer i;
        for (i = 0; i < 231000; i = i + 1)
            mem[i] = 8'd0;

        mem[0]  = 8'h42;
        mem[1]  = 8'h4D;
        mem[2]  = FILE_BYTES[7:0];
        mem[3]  = FILE_BYTES[15:8];
        mem[4]  = FILE_BYTES[23:16];
        mem[5]  = FILE_BYTES[31:24];
        mem[10] = 8'd54;
        mem[14] = 8'd40;
        mem[18] = W[7:0];
        mem[19] = W[15:8];
        mem[22] = H[7:0];
        mem[23] = H[15:8];
        mem[26] = 8'd1;
        mem[28] = 8'd24;
        mem[30] = 8'd0;
        mem[34] = (W * H * 3) & 255;
        mem[35] = ((W * H * 3) >> 8) & 255;
        mem[36] = 0;
        mem[37] = 0;

        for (i = 0; i < W * H; i = i + 1) begin
            mem[54 + i * 3 + 0] = 8'h33;  // B
            mem[54 + i * 3 + 1] = 8'h66;  // G
            mem[54 + i * 3 + 2] = 8'h99;  // R
        end
    end

    initial begin
        repeat (5) @(posedge clk);
        rst <= 1'b0;
        repeat (3) @(posedge clk);

        @(posedge clk);
        scan_start <= 1'b1;
        @(posedge clk);
        scan_start <= 1'b0;

        begin : wait_scan
            integer t;
            t = 0;
            while (!scan_done && (t < 500000)) begin
                @(posedge clk);
                t = t + 1;
            end
            if (!scan_done) begin
                $display("TIMEOUT scan");
                errors = errors + 1;
            end
        end

        @(posedge clk);
        load_start <= 1'b1;
        load_sector <= 32'd0;
        @(posedge clk);
        load_start <= 1'b0;

        begin : wait_done
            integer t;
            t = 0;
            while (!done_seen && (t < 8000000)) begin
                @(posedge clk);
                t = t + 1;
            end
            if (!done_seen) begin
                $display("TIMEOUT out_cnt=%0d src_y=%0d fifo=%0d ld_row=%0d W=%0d H=%0d file_len=%0d off=%0d",
                         out_cnt, u_read.src_y, u_scale.fifo_cnt, u_scale.ld_row,
                         u_read.width, u_read.height, u_read.file_len, u_read.pixel_offset);
                $display("  out_y=%0d out_x=%0d rowA=%0d rdyA=%b rowB=%0d rdyB=%b want0=%0d want1=%0d ld_state=%0d ld_x=%0d o_state=%0d phase=%0d bar=%b",
                         u_scale.out_y, u_scale.out_x,
                         u_scale.buf_row_a, u_scale.buf_ready_a,
                         u_scale.buf_row_b, u_scale.buf_ready_b,
                         u_scale.want_y0_r, u_scale.want_y1_r,
                         u_scale.ld_state, u_scale.ld_x, u_scale.o_state, u_scale.phase,
                         u_scale.bar_pix);
                errors = errors + 1;
            end
        end

        if (out_cnt != PIX) begin
            $display("FAIL out_cnt=%0d (expect %0d)", out_cnt, PIX);
            errors = errors + 1;
        end

        $display("--------------------------------------------------");
        if (errors == 0)
            $display("tb_bmp_pipeline: PASS (%0d pixels)", out_cnt);
        else
            $display("tb_bmp_pipeline: %0d errors", errors);
        $display("--------------------------------------------------");
        $finish;
    end

endmodule
