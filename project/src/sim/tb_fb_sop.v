`timescale 1ns / 1ps
//=============================================================================
// tb_fb_sop — 验证 frame_fifo_write 的“行首标志”显式行对齐
//-----------------------------------------------------------------------------
// 场景：数据流里每行长度并不总是 640（每 7 行故意多 1 个字，模拟行内多/丢一个
//       像素的异常）。要求：每一行仍然落在 (H-1-row)*640 的起始地址上，
//       即误差不逐行累积。
// 做法：FIFO 队头 = dout（组合给出），bit0 = 行首标志，bit[26:8] = row*1024+col。
//=============================================================================
module tb_fb_sop;
    reg clk=0, rst=1;
    always #2 clk=~clk;

    localparam W = 640;
    localparam H = 480;
    localparam PIX = W*H;
    localparam BURST = 256;

    reg [31:0] mem [0:1048575];

    // ---- 数据流发生器：按 (row, col) 逐个吐出字 ----
    reg [9:0] s_row = 0;
    reg [9:0] s_col = 0;
    wire [9:0] row_len = ((s_row % 7) == 3) ? 10'd641 : 10'd640;
    wire       sop_now = (s_col == 10'd0);
    wire [31:0] dout   = {5'd0, (s_row * 10'd1024 + s_col), 7'd0, sop_now};

    wire [31:0] rdusedw = 32'd600;          // 始终“够一次突发”

    reg         write_req = 1;
    wire        write_req_ack;
    wire        write_finish;
    wire        App_wr_en;
    wire [20:0] App_wr_addr;
    wire        fifo_aclr;
    wire        O_wr_busy;

    frame_fifo_write #(
        .MEM_DATA_BITS (32),
        .ADDR_BITS     (21),
        .BURST_BITS    (9),
        .BURST_SIZE    (BURST),
        .WRITE_V_FLIP  (1),
        .FRAME_WIDTH   (W),
        .FRAME_HEIGHT  (H)
    ) dut (
        .rst             (rst),
        .mem_clk         (clk),
        .Sdr_init_done   (1'b1),
        .Sdr_init_ref_vld(1'b1),
        .Sdr_busy        (1'b0),
        .App_rd_busy     (1'b0),
        .O_wr_busy       (O_wr_busy),
        .App_wr_en       (App_wr_en),
        .App_wr_addr     (App_wr_addr),
        .write_req       (write_req),
        .write_req_ack   (write_req_ack),
        .write_finish    (write_finish),
        .write_addr_0    (21'd0),
        .write_addr_1    (21'd307200),
        .write_addr_2    (21'd614400),
        .write_addr_3    (21'd921600),
        .write_addr_index(2'd0),
        .write_len       (PIX[20:0]),
        .fifo_aclr       (fifo_aclr),
        .rdusedw         (rdusedw[9:0]),
        .App_wr_sop      (dout[0])
    );

    integer errors = 0;
    integer nw = 0;
    integer exp_addr;
    always @(posedge clk) begin
        if (App_wr_en) begin
            exp_addr = (H-1-s_row)*W + s_col;
            if (App_wr_addr !== exp_addr[20:0]) begin
                if (errors < 8)
                    $display("  BAD addr: row=%0d col=%0d -> addr %0d (expect %0d)",
                             s_row, s_col, App_wr_addr, exp_addr);
                errors = errors + 1;
            end
            nw = nw + 1;
            // 推进到下一个字
            if (s_col == row_len - 1) begin
                s_col <= 10'd0;
                s_row <= s_row + 10'd1;
            end else begin
                s_col <= s_col + 10'd1;
            end
        end
        if (write_req_ack) write_req <= 1'b0;
    end

    initial begin
        repeat(3) @(posedge clk); rst <= 0;
        fork : guard
            begin
                wait (write_finish);
                disable guard;
            end
            begin
                repeat (PIX * 4) @(posedge clk);
                $display("RESULT: TIMEOUT");
                $finish;
            end
        join
        repeat(4) @(posedge clk);
        $display("words written = %0d (expect %0d)", nw, PIX);
        $display("RESULT: %0s (addr errors=%0d)",
                 (errors==0 && nw==PIX) ? "PASS" : "FAIL", errors);
        $finish;
    end
endmodule
