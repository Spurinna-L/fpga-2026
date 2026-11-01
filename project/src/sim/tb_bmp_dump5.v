`timescale 1ns / 1ps
// tb_bmp_dump5: 真实 BMP -> bmp_read，dump (src_y, src_x, 输入字节计数, 像素)
module tb_bmp_dump;
    reg clk=0, rst=1;
    always #5 clk=~clk;

    localparam [1023:0] BMP_PATH = "D:/fpga_2026/project/src/tools/output_bmp/apple.bmp";

    reg  [7:0]  sec_buf [0:511];
    integer     fd, i, n, out, k;
    integer     bcnt = 0;
    reg  [31:0] sec_base;

    reg         scan_start=0;
    reg  [31:0] scan_start_sector=0, scan_max_sector=32'd131071;
    reg  [2:0]  scan_target_count=3'd1;
    wire        scan_done, scan_found_valid;
    wire [31:0] scan_found_sector;
    wire [2:0]  scan_found_total;
    reg         load_start=0;
    reg  [31:0] load_sector=0;
    wire        sd_sec_read;
    wire [31:0] sd_sec_read_addr;
    wire [7:0]  sd_sec_read_data;
    wire        sd_sec_read_data_valid, sd_sec_read_end;
    wire        write_req;
    reg         write_req_ack=0;
    wire        bmp_data_wr_en;
    wire [23:0] bmp_data;
    wire        bmp_src_config, bmp_src_sop, bmp_src_eof;
    wire [15:0] bmp_src_width, bmp_src_height;
    wire [3:0]  dbg_bad_rows;
    wire [15:0] dbg_last_x;
    wire [3:0]  state_code;

    reg sd_active=0, sd_valid=0, sd_end=0;
    reg [9:0] sd_cnt=0;
    reg [7:0] sd_data=0;

    assign sd_sec_read_data = sd_data;
    assign sd_sec_read_data_valid = sd_valid;
    assign sd_sec_read_end = sd_end;

    always @(posedge clk) begin
        sd_valid <= 0; sd_end <= 0;
        if (sd_sec_read) begin
            if (!sd_active) begin
                sd_active <= 1;
                sec_base = sd_sec_read_addr*512;
                k = $fseek(fd, sec_base, 0);
                k = $fread(sec_buf, fd);
                sd_data  <= sec_buf[0];
                sd_cnt   <= 10'd1;
                sd_valid <= 1;
            end else if (sd_cnt < 10'd512) begin
                sd_valid <= 1; sd_data <= sec_buf[sd_cnt]; sd_cnt <= sd_cnt+1;
            end else begin
                sd_end <= 1; sd_active <= 0;
            end
        end else sd_active <= 0;

        write_req_ack <= write_req;
        if (sd_sec_read_data_valid) bcnt <= bcnt + 1;
        if (dut.bmp_data_valid && (dut.bmp_byte_idx == 2'd2) && (dut.src_y < 12))
            $fwrite(out, "%0d %0d %0d %06x\n", dut.src_y, dut.src_x, bcnt,
                    {sd_sec_read_data, bmp_data[15:8], bmp_data[7:0]});
    end

    bmp_read dut (
        .clk(clk), .rst(rst), .ready(),
        .scan_start(scan_start), .scan_start_sector(scan_start_sector),
        .scan_max_sector(scan_max_sector), .scan_target_count(scan_target_count),
        .scan_done(scan_done), .scan_found_valid(scan_found_valid),
        .scan_found_sector(scan_found_sector), .scan_found_total(scan_found_total),
        .load_start(load_start), .load_sector(load_sector),
        .sd_init_done(1'b1), .state_code(state_code),
        .bmp_width(16'd1920), .bmp_height(16'd1080),
        .write_req(write_req), .write_req_ack(write_req_ack),
        .sd_sec_read(sd_sec_read), .sd_sec_read_addr(sd_sec_read_addr),
        .sd_sec_read_data(sd_sec_read_data), .sd_sec_read_data_valid(sd_sec_read_data_valid),
        .sd_sec_read_end(sd_sec_read_end),
        .bmp_data_wr_en(bmp_data_wr_en), .bmp_data(bmp_data),
        .src_ready(1'b1),
        .bmp_src_config(bmp_src_config), .bmp_src_width(bmp_src_width),
        .bmp_src_height(bmp_src_height), .bmp_src_sop(bmp_src_sop), .bmp_src_eof(bmp_src_eof),
        .dbg_bad_rows(dbg_bad_rows), .dbg_last_x(dbg_last_x)
    );

    integer t;
    initial begin
        fd  = $fopen(BMP_PATH, "rb");
        out = $fopen("D:/fpga_2026/project/src/sim/dump_xy.txt", "w");
        if (fd==0) begin $display("ERROR open bmp"); $finish; end
        repeat(5) @(posedge clk); rst<=0; repeat(5) @(posedge clk);
        @(posedge clk); scan_start<=1;
        @(posedge clk); scan_start<=0;
        t=0; while (!scan_done && t<300000) begin @(posedge clk); t=t+1; end
        $display("scan_done=%b found=%0d sector=%0d", scan_done, scan_found_total, scan_found_sector);
        @(posedge clk); load_sector <= scan_found_sector; load_start<=1;
        @(posedge clk); load_start<=0;
        t=0; while (!bmp_src_eof && t<6000000) begin @(posedge clk); t=t+1; end
        $display("eof=%b w=%0d h=%0d bad_rows=%0d last_x=%0d", bmp_src_eof, bmp_src_width,
                 bmp_src_height, dbg_bad_rows, dbg_last_x);
        $fclose(out); $finish;
    end
endmodule
