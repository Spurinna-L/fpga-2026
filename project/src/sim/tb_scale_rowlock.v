`timescale 1ns / 1ps
//=============================================================================
// tb_scale_rowlock — 验证 bmp_scale 的“源行首标志”行锁定
//-----------------------------------------------------------------------------
// 场景：源图 16x8，其中第 2、5 行各少 1 个像素（模拟源端丢像素）。
// 要求：
//   1) 仍然输出 DST_W*DST_H = 8*4 个像素（不死锁、不丢行）；
//   2) 8 个源行全部装载完成（ld_row == 8）；
//   3) 最后一个输出行（对应源第 7 行）必须是源第 7 行的颜色，不能被前面
//      的短行带偏。若没有行锁定，丢掉的像素会让后面每行左移，最后一行
//      会取到源第 6 行的值。
//=============================================================================
module tb_scale_rowlock;

    localparam DST_W = 8;
    localparam DST_H = 4;
    localparam SW    = 16;
    localparam SH    = 8;

    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1;

    reg        src_valid = 0;
    reg [23:0] src_data  = 0;
    reg        src_sop   = 0;
    reg        src_config = 0;
    reg [15:0] src_w = SW;
    reg [15:0] src_h = SH;
    reg        src_eof = 0;
    wire       src_ready;

    wire        out_valid;
    wire [23:0] out_data;
    wire        out_sop;
    wire        out_done;

    bmp_scale #(
        .DST_W     (DST_W),
        .DST_H     (DST_H),
        .MAX_SRC_W (SW),
        .MAX_SRC_H (SH),
        .ADDR_BITS (11),
        .FIFO_AW   (10)
    ) dut (
        .clk           (clk),
        .rst           (rst),
        .src_valid     (src_valid),
        .src_data      (src_data),
        .src_sop       (src_sop),
        .src_config    (src_config),
        .src_width     (src_w),
        .src_height    (src_h),
        .out_valid     (out_valid),
        .out_data      (out_data),
        .out_sop       (out_sop),
        .out_done      (out_done),
        .src_ready     (src_ready),
        .src_eof       (src_eof)
    );

    integer errors = 0;
    integer out_cnt = 0;
    reg [23:0] cap [0:63];
    integer r, x, len;

    always @(posedge clk) begin
        if (out_valid) begin
            if (out_cnt < 64)
                cap[out_cnt] = out_data;
            out_cnt = out_cnt + 1;
        end
    end

    // 每个源行第一个像素给 sop；第 2、5 行少 1 个像素
    task send_pixel;
        input integer row;
        input integer col;
        begin
            while (!src_ready) @(posedge clk);
            src_valid <= 1'b1;
            src_data  <= row * 16 + col;
            src_sop   <= (col == 0);
            @(posedge clk);
            src_valid <= 1'b0;
            src_sop   <= 1'b0;
            @(posedge clk);
        end
    endtask

    initial begin
        repeat (5) @(posedge clk);
        rst <= 0;
        repeat (3) @(posedge clk);

        // 配置
        src_config <= 1'b1;
        @(posedge clk);
        src_config <= 1'b0;

        // 等除法器算完 DW/DH/步长
        while (!dut.cfg_done) @(posedge clk);
        repeat (2) @(posedge clk);

        // 送 8 行
        for (r = 0; r < SH; r = r + 1) begin
            len = ((r == 2) || (r == 5)) ? (SW - 1) : SW;
            for (x = 0; x < len; x = x + 1)
                send_pixel(r, x);
        end

        // 源结束
        src_eof <= 1'b1;
        @(posedge clk);
        src_eof <= 1'b0;

        // 等输出跑完（32 个像素）
        fork : wait_out
            begin
                while (out_cnt < DST_W * DST_H) @(posedge clk);
                disable wait_out;
            end
            begin
                repeat (200000) @(posedge clk);
                $display("RESULT: FAIL (timeout, out_cnt=%0d)", out_cnt);
                $finish;
            end
        join
        repeat (20) @(posedge clk);

        $display("out_cnt = %0d (expect %0d)", out_cnt, DST_W * DST_H);
        $display("ld_row  = %0d (expect %0d)", dut.ld_row, SH);

        if (out_cnt != DST_W * DST_H) errors = errors + 1;
        if (dut.ld_row != SH)          errors = errors + 1;

        // 最后一个输出行 = 源第 7 行（纯色带），值域 7*16 + [0..15] = 112..127
        for (x = 0; x < DST_W; x = x + 1) begin
            if ((cap[(DST_H-1)*DST_W + x] < 24'd112) || (cap[(DST_H-1)*DST_W + x] > 24'd127)) begin
                $display("  BAD: last row px %0d = %0d (expect 112..127)", x, cap[(DST_H-1)*DST_W + x]);
                errors = errors + 1;
            end
        end
        $display("last row = %0d %0d %0d %0d %0d %0d %0d %0d",
                 cap[3*DST_W+0], cap[3*DST_W+1], cap[3*DST_W+2], cap[3*DST_W+3],
                 cap[3*DST_W+4], cap[3*DST_W+5], cap[3*DST_W+6], cap[3*DST_W+7]);

        $display("RESULT: %0s (errors=%0d)", (errors == 0) ? "PASS" : "FAIL", errors);
        $finish;
    end

endmodule
