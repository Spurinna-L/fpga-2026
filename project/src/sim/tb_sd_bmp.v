//=============================================================================
// tb_sd_bmp.v — 用真实 SD 镜像回放 sd_card_bmp 全流程
//-----------------------------------------------------------------------------
// 目的：不开板即可复现“卡在彩条（display_valid=0）”类问题。
//
// 做法：
//   - 用 $fseek/$fread 直接从 sd_card_m3_a.img 按扇区取数据，模拟 sd_card_top
//     的 512B/扇区读出时序（含 data_valid / read_end）；
//   - 用 force 覆盖 sd_card_bmp 内部 sd_card_top 的输出（只仿真）；
//   - 写侧模型：write_req 后 2 拍 ack；统计 write_en，满 307200 字翻转
//     write_finish_toggle（等价 frame_read_write 的整帧写完）；
//   - 监视 display_valid / state_code / img_found_count / load_busy /
//     all_loaded / 每张图写入字数。
//=============================================================================
`timescale 1ns / 1ps

module tb_sd_bmp;

    localparam integer PIXELS = 640 * 480;
    localparam [1023:0] IMG_PATH =
        "D:/fpga_2026/project/out/sd_card_m3_a.img";

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #5 clk = ~clk;

    integer fd;
    integer fread_n = 0;
    integer fseek_n = 0;
    reg [7:0] sec_buf [0:511];

    // ---------------- SD 扇区模型 ----------------
    reg         sd_busy   = 1'b0;
    reg [9:0]   sd_cnt    = 10'd0;
    reg [7:0]   sd_data   = 8'd0;
    reg         sd_valid  = 1'b0;
    reg         sd_end    = 1'b0;
    reg         sd_need_low = 1'b0;
    reg         sd_end_sent = 1'b0;
    reg [31:0]  sd_lat    = 32'd0;

    // ---------------- 写侧模型 ----------------
    reg         write_ack  = 1'b0;
    reg         wrfin_tgl  = 1'b0;
    integer     wr_cnt     = 0;
    integer     frame_no   = 0;
    integer     total_wr   = 0;

    wire        write_req;
    wire        write_en;
    wire [31:0] write_data;
    wire [3:0]  state_code;
    wire        display_valid;
    wire [1:0]  write_buf_idx;
    wire [1:0]  disp_buf_idx;
    wire [1:0]  img_idx;
    wire        SD_nCS, SD_DCLK, SD_MOSI;

    sd_card_bmp #(
        .CLK_FREQ_HZ       (100_000_000),
        .AUTO_PERIOD_S     (4),
        .SCAN_START_SECTOR (32'd0),
        .SCAN_MAX_SECTOR   (32'd131071),
        .SCAN_TARGET_COUNT (3'd4)
    ) dut (
        .clk                 (clk),
        .rst                 (rst),
        .key_next            (1'b0),
        .key_auto            (1'b0),
        .state_code          (state_code),
        .bmp_width           (16'd1920),
        .bmp_height          (16'd1080),
        .display_valid       (display_valid),
        .write_finish_toggle (wrfin_tgl),
        .write_buf_idx       (write_buf_idx),
        .disp_buf_idx        (disp_buf_idx),
        .img_idx_o           (img_idx),
        .write_req           (write_req),
        .write_req_ack       (write_ack),
        .write_en            (write_en),
        .write_data          (write_data),
        .SD_nCS              (SD_nCS),
        .SD_DCLK             (SD_DCLK),
        .SD_MOSI             (SD_MOSI),
        .SD_MISO             (1'b1)
    );

    // 扇区读出：sd_sec_read 为高 → 下一拍起连送 512B
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            sd_busy     <= 1'b0;
            sd_cnt      <= 10'd0;
            sd_valid    <= 1'b0;
            sd_end      <= 1'b0;
            sd_need_low <= 1'b0;
            sd_end_sent <= 1'b0;
            sd_lat      <= 32'd0;
            sd_data     <= 8'd0;
        end else begin
            sd_valid <= 1'b0;
            sd_end   <= 1'b0;

            if (!dut.sd_sec_read) begin
                sd_busy     <= 1'b0;
                sd_cnt      <= 10'd0;
                sd_need_low <= 1'b0;
                sd_end_sent <= 1'b0;
            end else if (!sd_busy && !sd_need_low) begin
                fseek_n = $fseek(fd, dut.sd_sec_read_addr * 512, 0);
                fread_n = $fread(sec_buf, fd);
                sd_busy  <= 1'b1;
                sd_lat   <= dut.sd_sec_read_addr;
                sd_cnt   <= 10'd1;
                sd_valid <= 1'b1;
                sd_data  <= sec_buf[0];
            end else if (sd_cnt < 10'd512) begin
                sd_valid <= 1'b1;
                sd_data  <= sec_buf[sd_cnt];
                sd_cnt   <= sd_cnt + 10'd1;
            end else if (!sd_end_sent) begin
                // read_end 只发一拍（真实 sd_card_top 的行为）
                sd_end      <= 1'b1;
                sd_end_sent <= 1'b1;
                sd_busy     <= 1'b0;
                sd_need_low <= 1'b1;
            end
        end
    end

    // 写应答：write_req 后 2 拍
    reg write_req_d1 = 1'b0;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            write_ack    <= 1'b0;
            write_req_d1 <= 1'b0;
        end else begin
            write_req_d1 <= write_req;
            write_ack    <= write_req_d1 & write_req;
        end
    end

    // 整帧写完 → 翻转 toggle
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            wr_cnt    <= 0;
            wrfin_tgl <= 1'b0;
            frame_no  <= 0;
            total_wr  <= 0;
        end else if (write_en) begin
            wr_cnt   <= wr_cnt + 1;
            total_wr <= total_wr + 1;
            if (wr_cnt == PIXELS - 1) begin
                $display("[T=%0t] frame %0d written: %0d words", $time, frame_no, wr_cnt + 1);
                wr_cnt    <= 0;
                wrfin_tgl <= ~wrfin_tgl;
                frame_no  <= frame_no + 1;
            end
        end
    end

    // 进度打印
    integer   last_code  = -1;
    reg [2:0] last_found = 3'd7;
    integer   sec_cnt    = 0;
    reg [9:0] last_out_y  = 10'h3FF;
    always @(posedge clk) begin
        if (!rst) begin
            if (sd_end) sec_cnt <= sec_cnt + 1;
            if (state_code !== last_code) begin
                $display("[T=%0t] state_code=%0d found=%0d scan_done=%b load_busy=%b all_loaded=%b",
                         $time, state_code, dut.img_found_count, dut.scan_done,
                         dut.load_busy, dut.all_loaded);
                last_code = state_code;
            end
            if (dut.img_found_count !== last_found) begin
                last_found = dut.img_found_count;
                $display("[T=%0t] img_found_count=%0d (w=%0d h=%0d bpp=%0d cmp=%0d sectors_served=%0d)",
                         $time, dut.img_found_count, dut.bmp_read_m0.width,
                         dut.bmp_read_m0.height, dut.bmp_read_m0.bit_count,
                         dut.bmp_read_m0.compression, sec_cnt);
            end

            if (dut.bmp_read_m0.scan_found_valid)
                $display("  FOUND pulse t=%0t found_sector=%0d total=%0d",
                         $time, dut.bmp_read_m0.scan_found_sector,
                         dut.bmp_read_m0.scan_found_total);

            if (dut.u_bmp_scale.out_y !== last_out_y) begin
                last_out_y = dut.u_bmp_scale.out_y;
                $display("  ROW y=%0d ld_row=%0d rowA=%0d rowB=%0d want0=%0d want1=%0d rdyA=%b rdyB=%b fifo=%0d bar=%b",
                         dut.u_bmp_scale.out_y, dut.u_bmp_scale.ld_row,
                         dut.u_bmp_scale.buf_row_a, dut.u_bmp_scale.buf_row_b,
                         dut.u_bmp_scale.want_y0_r, dut.u_bmp_scale.want_y1_r,
                         dut.u_bmp_scale.buf_ready_a, dut.u_bmp_scale.buf_ready_b,
                         dut.u_bmp_scale.fifo_cnt, dut.u_bmp_scale.bar_row);
            end
        end
    end

    initial begin
        fd = $fopen(IMG_PATH, "rb");
        if (fd == 0) begin
            $display("ERROR: cannot open image %0s", IMG_PATH);
            $finish;
        end
        $display("opened %0s", IMG_PATH);

        // 只仿真：覆盖内部 sd_card_top 的输出
        force dut.sd_sec_read_data       = sd_data;
        force dut.sd_sec_read_data_valid = sd_valid;
        force dut.sd_sec_read_end        = sd_end;
        force dut.sd_init_done           = 1'b1;

        repeat (10) @(posedge clk);
        rst <= 1'b0;

        begin : wait_done
            integer t;
            t = 0;
            while (!display_valid && (t < 60_000_000)) begin
                @(posedge clk);
                t = t + 1;
                if ((t % 2_000_000) == 0)
                    $display("... t=%0d state=%0d found=%0d loaded_slot=%0d all=%b wr_cnt=%0d frame=%0d",
                             t, state_code, dut.img_found_count, dut.loaded_slot,
                             dut.all_loaded, wr_cnt, frame_no);
            end
        end

        if (display_valid) begin
            $display("RESULT: display_valid=1, frames=%0d total_wr=%0d", frame_no, total_wr);
        end else begin
            $display("RESULT: HANG. state=%0d found=%0d loaded_slot=%0d all=%b",
                     state_code, dut.img_found_count, dut.loaded_slot, dut.all_loaded);
            $display("  load_busy=%b source_done_seen=%b wr_cnt=%0d frame=%0d",
                     dut.load_busy, dut.source_done_seen, wr_cnt, frame_no);
            $display("  read_sector=%0d bmp_ready=%b scan_done=%b",
                     dut.sd_sec_read_addr, dut.bmp_ready, dut.scan_done);
            $display("  scale: out_y=%0d out_x=%0d o_state=%0d phase=%0d fifo=%0d ld_row=%0d W=%0d H=%0d bypass=%b",
                     dut.u_bmp_scale.out_y, dut.u_bmp_scale.out_x, dut.u_bmp_scale.o_state,
                     dut.u_bmp_scale.phase, dut.u_bmp_scale.fifo_cnt, dut.u_bmp_scale.ld_row,
                     dut.u_bmp_scale.W, dut.u_bmp_scale.H, dut.u_bmp_scale.bypass);
            $display("  bmp_read: state=%0d src_y=%0d src_x=%0d len_cnt=%0d eof=%b",
                     dut.bmp_read_m0.state, dut.bmp_read_m0.src_y, dut.bmp_read_m0.src_x,
                     dut.bmp_read_m0.bmp_len_cnt, dut.bmp_read_m0.bmp_src_eof);
        end
        $fclose(fd);
        $finish;
    end

endmodule
