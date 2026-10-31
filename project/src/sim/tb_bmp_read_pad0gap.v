`timescale 1ns / 1ps
//=============================================================================
// tb_bmp_read_pad0gap — 复现“真实 SPI 有空拍 + 行无填充”时的丢像素 bug
//-----------------------------------------------------------------------------
// 源图 4×3、24bit、stride=12（无行填充，正好是 3 的整数倍）。
// SD 字节流每 4 拍才给 1 个字节（真实 SPI 25MHz、8 拍/字节）。
//
// 旧逻辑：在“行末字节到达之前”就把相位强制清零 → 该行最后一个像素丢失，
//         每行少 1 个像素（= 斜切的根因）。
// 期望：12 个像素、3 个行首标志、像素值全部正确。
//=============================================================================
module tb_bmp_read_pad0gap;

    localparam W = 4;
    localparam H = 3;
    localparam STRIDE = 12;
    localparam FILE_LEN = 54 + W*H*3;      // 90
    localparam GAP = 3;                    // 字节之间插 3 拍空拍

    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1;

    reg [7:0] mem [0:65535];

    // ---- SD 模型 ----
    reg        sd_valid = 0;
    reg [7:0]  sd_data  = 0;
    reg        sd_end   = 0;
    reg        sd_active = 0;
    reg        sd_need_low = 0;
    reg [9:0]  sd_cnt = 0;
    reg [31:0] sd_lat = 0;
    reg [1:0]  sd_gap = 0;

    wire        sd_sec_read;
    wire [31:0] sd_sec_read_addr;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            sd_active <= 0; sd_cnt <= 0; sd_data <= 0; sd_valid <= 0;
            sd_end <= 0; sd_need_low <= 0; sd_gap <= 0;
        end else begin
            sd_valid <= 0;
            sd_end   <= 0;
            if (!sd_sec_read) begin
                sd_active   <= 0;
                sd_cnt      <= 0;
                sd_gap      <= 0;
                sd_need_low <= 0;
            end else if (!sd_active && !sd_need_low) begin
                sd_active <= 1;
                sd_lat    <= sd_sec_read_addr;
                sd_cnt    <= 0;
                sd_gap    <= 0;
            end else if (sd_cnt < 10'd512) begin
                if (sd_gap != GAP[1:0]) begin
                    sd_gap <= sd_gap + 2'd1;
                end else begin
                    sd_gap   <= 0;
                    sd_valid <= 1;
                    sd_data  <= mem[sd_lat * 512 + sd_cnt];
                    sd_cnt   <= sd_cnt + 10'd1;
                end
            end else begin
                sd_end <= 1;
                sd_active <= 0;
                sd_need_low <= 1;
            end
        end
    end

    wire        write_req;
    reg         write_req_ack = 0;
    reg         load_start = 0;
    reg  [31:0] load_sector = 0;

    wire        bmp_data_wr_en;
    wire [23:0] bmp_data;
    wire        bmp_src_config, bmp_src_sop, bmp_src_eof;
    wire [15:0] bmp_src_width, bmp_src_height;
    wire [3:0]  state_code;

    always @(posedge clk or posedge rst)
        if (rst) write_req_ack <= 0;
        else     write_req_ack <= write_req;

    bmp_read dut (
        .clk                    (clk),
        .rst                    (rst),
        .ready                  (),
        .scan_start             (1'b0),
        .scan_start_sector      (32'd0),
        .scan_max_sector        (32'd0),
        .scan_target_count      (3'd0),
        .scan_done              (),
        .scan_found_valid       (),
        .scan_found_sector      (),
        .scan_found_total       (),
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
        .sd_sec_read_data       (sd_data),
        .sd_sec_read_data_valid (sd_valid),
        .sd_sec_read_end        (sd_end),
        .bmp_data_wr_en         (bmp_data_wr_en),
        .bmp_data               (bmp_data),
        .src_ready              (1'b1),
        .bmp_src_config         (bmp_src_config),
        .bmp_src_width          (bmp_src_width),
        .bmp_src_height         (bmp_src_height),
        .bmp_src_sop            (bmp_src_sop),
        .bmp_src_eof            (bmp_src_eof)
    );

    integer errors   = 0;
    integer pix_cnt  = 0;
    integer sop_cnt  = 0;
    integer sop_last = 0;
    integer eof_seen = 0;
    reg [23:0] last_pix;

    // 逐像素检查（期望：第 r 行第 x 列 = {r*10+x+3, r*10+x+2, r*10+x+1}）
    always @(posedge clk) begin
        if (bmp_src_eof) eof_seen = 1;
        if (bmp_data_wr_en) begin
            begin : chk
                integer r, x;
                reg [7:0] er, eg, eb;
                reg [23:0] exp;
                r = pix_cnt / W;
                x = pix_cnt % W;
                er = r*10+x+3; eg = r*10+x+2; eb = r*10+x+1;
                exp = {er, eg, eb};
                if ((r < H) && (bmp_data !== exp)) begin
                    if (errors < 6)
                        $display("  BAD pixel %0d (r=%0d x=%0d): got=%06h exp=%06h",
                                 pix_cnt, r, x, bmp_data, exp);
                    errors = errors + 1;
                end
            end
            if (bmp_src_sop) begin
                if ((sop_cnt != 0) && ((pix_cnt - sop_last) != W)) begin
                    if (errors < 6)
                        $display("  BAD sop spacing: row %0d has %0d pixels (expect %0d)",
                                 sop_cnt-1, pix_cnt - sop_last, W);
                    errors = errors + 1;
                end
                sop_cnt  = sop_cnt + 1;
                sop_last = pix_cnt;
            end
            pix_cnt = pix_cnt + 1;
        end
    end

    integer i, r, x;
    initial begin
        for (i = 0; i < 65536; i = i + 1) mem[i] = 8'd0;
        mem[0]  = 8'h42;            // 'B'
        mem[1]  = 8'h4D;            // 'M'
        mem[2]  = FILE_LEN[7:0];    // file size
        mem[3]  = FILE_LEN >> 8;
        mem[10] = 8'd54;            // 像素起始偏移
        mem[11] = 8'd0;
        mem[12] = 8'd0;
        mem[13] = 8'd0;
        mem[14] = 8'd40;            // DIB 大小
        mem[18] = W;                // 宽
        mem[19] = 8'd0;
        mem[22] = H;                // 高（正 = bottom-up）
        mem[23] = 8'd0;
        mem[26] = 8'd1;             // planes
        mem[28] = 8'd24;            // bpp
        mem[30] = 8'd0;             // BI_RGB
        for (r = 0; r < H; r = r + 1)
            for (x = 0; x < W; x = x + 1) begin
                mem[54 + r*STRIDE + x*3 + 0] = r*10 + x + 1;   // B
                mem[54 + r*STRIDE + x*3 + 1] = r*10 + x + 2;   // G
                mem[54 + r*STRIDE + x*3 + 2] = r*10 + x + 3;   // R
            end
    end

    initial begin
        repeat (5) @(posedge clk);
        rst <= 0;
        repeat (5) @(posedge clk);
        load_start  <= 1'b1;
        load_sector <= 32'd0;
        @(posedge clk);
        load_start  <= 1'b0;

        fork : guard
            begin
                while (!eof_seen) @(posedge clk);
                disable guard;
            end
            begin
                repeat (60000) @(posedge clk);
                $display("RESULT: FAIL (timeout: pix=%0d sop=%0d)", pix_cnt, sop_cnt);
                $finish;
            end
        join
        repeat (5) @(posedge clk);
        $display("pixels = %0d (expect %0d)", pix_cnt, W*H);
        $display("sops   = %0d (expect %0d)", sop_cnt, H);
        if (pix_cnt != W*H) errors = errors + 1;
        if (sop_cnt != H)   errors = errors + 1;
        $display("RESULT: %0s (errors=%0d)", (errors==0) ? "PASS" : "FAIL", errors);
        $finish;
    end

endmodule
