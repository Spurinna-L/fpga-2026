`timescale 1ns / 1ps
// tb_fb_write_layout: 验证 frame_fifo_write 的 VFLIP 写地址布局
// 用法：FIFO 里预放 write_len 个"线性递增"的字，观察每个字最终落在哪个地址
module tb_fb_write_layout;
    reg clk=0, rst=1;
    always #2 clk=~clk;                 // 250MHz 级时序，仿真快

    localparam W = 640;
    localparam H = 480;
    localparam PIX = W*H;
    localparam BURST = 256;

    // 内存模型：记录每个地址写入的"数据序号"
    reg [31:0] mem [0:1048575];

    reg  [31:0] out_cnt   = 0;          // 已弹出 FIFO 的字数
    wire [31:0] rdusedw   = (PIX - out_cnt > 1023) ? 32'd1023 : (PIX - out_cnt);
    wire [31:0] dout      = out_cnt;    // FIFO 队头 = 依次递增的字号

    reg         write_req = 1;
    wire        write_req_ack;
    wire        write_finish;
    wire        App_wr_en;
    wire [20:0] App_wr_addr;
    wire [3:0]  wr_dm;
    wire        fifo_aclr;
    wire        O_wr_busy;

    wire [9:0] rdusedw10 = rdusedw[9:0];

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
        .rdusedw         (rdusedw10),
        .App_wr_sop      (1'b0)         // 本 TB 测无行首标志的兼容路径
    );

    integer errors = 0;
    integer nw = 0;
    always @(posedge clk) begin
        if (App_wr_en) begin
            mem[App_wr_addr] <= dout;
            out_cnt <= out_cnt + 1;
            nw = nw + 1;
        end
        if (write_req_ack) write_req <= 1'b0;
    end

    integer r, c, k, bad;
    initial begin
        for (k=0;k<1048576;k=k+1) mem[k] = 32'hDEADBEEF;
        repeat(3) @(posedge clk); rst <= 0;
        while (!write_finish) @(posedge clk);
        repeat(4) @(posedge clk);
        $display("words written = %0d (expect %0d)", nw, PIX);
        bad = 0;
        for (r=0;r<H;r=r+1) begin
            for (c=0;c<W;c=c+1) begin
                k = r*W + c;
                if (mem[(H-1-r)*W + c] !== k[31:0]) begin
                    if (bad < 6)
                        $display("  MISMATCH stream(%0d,%0d)=word %0d -> addr %0d holds %0d (expect %0d @ addr %0d)",
                                 r, c, k, (H-1-r)*W+c, mem[(H-1-r)*W+c], k, (H-1-r)*W+c);
                    bad = bad + 1;
                end
            end
        end
        $display("layout mismatches = %0d / %0d  -> %0s", bad, PIX, (bad==0) ? "PASS" : "FAIL");
        $finish;
    end
endmodule
