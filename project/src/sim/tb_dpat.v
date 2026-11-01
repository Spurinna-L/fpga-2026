`timescale 1ns / 1ps
// 行为级 FWFT 异步 FIFO（替代纯空壳 stub，用于验证写通路）
module wfifo_32_32_512 #(
    parameter DATA_WIDTH_W = 32,
    parameter DATA_WIDTH_R = 32,
    parameter ADDR_WIDTH_W = 9,
    parameter ADDR_WIDTH_R = 9
)(
    input  wire        clkr,
    input  wire        clkw,
    input  wire        rst,
    input  wire        we,
    input  wire        re,
    input  wire [31:0] di,
    output wire        empty_flag,
    output wire        full_flag,
    output wire [ADDR_WIDTH_W-1:0]  wrusedw,
    output wire [ADDR_WIDTH_R-1:0]  rdusedw,
    output wire [31:0] dout
);
    reg [31:0] mem [0:511];
    reg [9:0]  wptr, rptr;
    wire [9:0] used_w = wptr - rptr;
    assign rdusedw    = used_w[ADDR_WIDTH_R-1:0];
    assign wrusedw    = used_w[ADDR_WIDTH_W-1:0];
    assign empty_flag = (used_w == 10'd0);
    assign full_flag  = (used_w == 10'd512);
    assign dout       = mem[rptr[8:0]];
    always @(posedge clkw) if (we && !full_flag) begin mem[wptr[8:0]] <= di; wptr <= wptr + 10'd1; end
    always @(posedge clkr) if (re && !empty_flag) rptr <= rptr + 10'd1;
    initial begin wptr = 10'd0; rptr = 10'd0; end
    // 复位（异步清零）
    always @(posedge rst) begin wptr <= 10'd0; rptr <= 10'd0; end
endmodule

module rfifo_32_32_512 #(
    parameter DATA_WIDTH_W = 32,
    parameter DATA_WIDTH_R = 32,
    parameter ADDR_WIDTH_W = 9,
    parameter ADDR_WIDTH_R = 9
)(
    input  wire        clkr,
    input  wire        clkw,
    input  wire        rst,
    input  wire        we,
    input  wire        re,
    input  wire [31:0] di,
    output wire        empty_flag,
    output wire        full_flag,
    output wire [ADDR_WIDTH_W-1:0]  wrusedw,
    output wire [ADDR_WIDTH_R-1:0]  rdusedw,
    output wire [31:0] dout
);
    reg [31:0] mem [0:511];
    reg [9:0]  wptr, rptr;
    wire [9:0] used_w = wptr - rptr;
    assign wrusedw    = used_w[ADDR_WIDTH_W-1:0];
    assign rdusedw    = used_w[ADDR_WIDTH_R-1:0];
    assign empty_flag = (used_w == 10'd0);
    assign full_flag  = (used_w == 10'd512);
    assign dout       = mem[rptr[8:0]];
    always @(posedge clkw) if (we && !full_flag) begin mem[wptr[8:0]] <= di; wptr <= wptr + 10'd1; end
    always @(posedge clkr) if (re && !empty_flag) rptr <= rptr + 10'd1;
    initial begin wptr = 10'd0; rptr = 10'd0; end
    always @(posedge rst) begin wptr <= 10'd0; rptr <= 10'd0; end
endmodule

module tb_dpat;
    reg sdclk = 0, mclk = 0, rst = 1;
    always #5  sdclk = ~sdclk;      // 100MHz
    always #4  mclk  = ~mclk;       // 125MHz

    localparam W = 640, H = 480, PIX = W*H;

    reg [31:0] mem [0:1048575];
    integer nwr = 0;

    wire        App_wr_en;
    wire [20:0] App_wr_addr;
    wire [31:0] App_wr_din;
    wire [3:0]  App_wr_dm;
    wire        write_req_ack;
    wire        write_finish;

    // 图案 FSM（与 top 中 DIAG_PAT 段一致）
    reg  [9:0]  dpat_xr;
    reg  [8:0]  dpat_yr;
    reg  [2:0]  dpat_st;
    reg  [4:0]  dpat_dly;
    reg         dpat_req, dpat_done;
    wire        dpat_we  = (dpat_st == 3'd2);
    wire [23:0] dpat_rgb = { dpat_xr[3] ? 8'hFF : 8'h00,
                             dpat_yr[6] ? 8'hFF : 8'h00,
                             (dpat_xr[5:4] == 2'd0) ? 8'hA0 : 8'h20 };
    wire        dpat_last = (dpat_yr == 9'd479) && (dpat_xr == 10'd639);

    always @(posedge sdclk or posedge rst) begin
        if (rst) begin
            dpat_xr <= 10'd0; dpat_yr <= 9'd0; dpat_st <= 3'd0; dpat_dly <= 5'd0;
            dpat_req <= 1'b0; dpat_done <= 1'b0;
        end else begin
            case (dpat_st)
                3'd0: begin dpat_req <= 1'b1; dpat_st <= 3'd1; end
                3'd1: if (write_req_ack) begin dpat_req <= 1'b0; dpat_dly <= 5'd0; dpat_st <= 3'd5; end
                3'd5: begin
                    if (dpat_dly == 5'd15) dpat_st <= 3'd2;
                    else                   dpat_dly <= dpat_dly + 5'd1;
                end
                3'd2: begin
                    if (dpat_last) dpat_st <= 3'd3;
                    if (dpat_xr == 10'd639) begin dpat_xr <= 10'd0; dpat_yr <= dpat_yr + 9'd1; end
                    else                          dpat_xr <= dpat_xr + 10'd1;
                end
                3'd3: if (write_finish) begin dpat_done <= 1'b1; dpat_st <= 3'd4; end
                default: ;
            endcase
        end
    end

    always @(posedge mclk) begin
        if (App_wr_en) begin
            mem[App_wr_addr] = App_wr_din;
            nwr = nwr + 1;
        end
    end

    frame_read_write #(
        .WRITE_V_FLIP (1),
        .FRAME_WIDTH  (640),
        .FRAME_HEIGHT (480)
    ) u_fb (
        .rst              (rst),
        .mem_clk          (mclk),
        .Sdr_init_done    (1'b1),
        .Sdr_init_ref_vld (1'b1),
        .Sdr_busy         (1'b0),
        .App_rd_en        (),
        .App_rd_addr      (),
        .Sdr_rd_en        (1'b0),
        .Sdr_rd_dout      (32'd0),
        .read_clk         (sdclk),
        .read_req         (1'b0),
        .read_req_ack     (),
        .read_finish      (),
        .read_addr_0      (21'd0),
        .read_addr_1      (21'd307200),
        .read_addr_2      (21'd614400),
        .read_addr_3      (21'd921600),
        .read_addr_index  (2'd0),
        .read_len         (21'd307200),
        .read_en          (1'b0),
        .read_data        (),
        .App_wr_en        (App_wr_en),
        .App_wr_addr      (App_wr_addr),
        .App_wr_din       (App_wr_din),
        .App_wr_dm        (App_wr_dm),
        .write_clk        (sdclk),
        .write_req        (dpat_req),
        .write_req_ack    (write_req_ack),
        .write_finish     (write_finish),
        .write_addr_0     (21'd0),
        .write_addr_1     (21'd307200),
        .write_addr_2     (21'd614400),
        .write_addr_3     (21'd921600),
        .write_addr_index (2'd0),
        .write_len        (21'd307200),
        .write_en         (dpat_we),
        .write_data       ({dpat_rgb, 8'h00})
    );

    integer r, c, bad;
    initial begin
        for (r=0;r<1048576;r=r+1) mem[r] = 32'hDEADBEEF;
        repeat(5) @(posedge sdclk); rst <= 0;
        r = 0;
        while (!dpat_done && r < 20000000) begin @(posedge sdclk); r = r + 1; end
        $display("done=%b cycles=%0d writes=%0d", dpat_done, r, nwr);
        bad = 0;
        for (r=0;r<H;r=r+1) begin
            for (c=0;c<W;c=c+1) begin
                if (mem[(H-1-r)*W + c] !== { ((c[3])?8'hFF:8'h00), ((r[6])?8'hFF:8'h00),
                                             ((c[5:4]==2'd0)?8'hA0:8'h20), 8'h00 }) begin
                    if (bad < 5) $display("  mismatch at mem row %0d col %0d: %08x", r, c, mem[(H-1-r)*W+c]);
                    bad = bad + 1;
                end
            end
        end
        $display("pattern check: bad=%0d / %0d -> %0s", bad, PIX, (bad==0) ? "PASS" : "FAIL");
        $finish;
    end
endmodule
