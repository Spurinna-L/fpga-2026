`timescale 1ns / 1ps
// tb_read_path: 验证 显示读通路（frame_line_read + 双 bank 行缓冲 + mixer）
// 内存内容 = {R=x, G=y, B=0x5A}，比较屏幕像素是否等于 (x,y)
module tb_read_path;
    reg clk  = 0;   // 125MHz  (mem)
    reg vclk = 0;   // 25MHz   (video)
    reg rst  = 1;
    always #4  clk  = ~clk;
    always #20 vclk = ~vclk;

    localparam W = 640, H = 480;

    // ---- 内存模型（4 槽，只填 0 和 307200） ----
    reg [31:0] mem [0:1228799];
    integer i, k, xx, yy;
    reg [7:0] xb, yb;
    initial begin
        for (k=0;k<1228800;k=k+1) mem[k] = 32'h0;
        for (i=0;i<2;i=i+1)
            for (k=0;k<W*H;k=k+1) begin
                xx = k % W;
                yy = (k / W) % 256;
                xb = xx[7:0];
                yb = yy[7:0];
                mem[i*307200 + k] = {xb, yb, 8'h5a, 8'h00};
            end
    end

    // ---- 视频时序（与 color_bar 一致的 v_cnt 0..524） ----
    reg [11:0] v_cnt = 12'd0;
    reg [9:0]  h_cnt = 10'd0;
    wire de   = (v_cnt >= 12'd45) && (v_cnt <= 12'd524) && (h_cnt >= 10'd160);
    wire vs   = (v_cnt >= 12'd525);
    wire vs_f = 1'b0;
    always @(posedge vclk) begin
        if (h_cnt == 10'd799) begin
            h_cnt <= 10'd0;
            v_cnt <= (v_cnt == 12'd524) ? 12'd0 : (v_cnt + 12'd1);
        end else h_cnt <= h_cnt + 10'd1;
    end

    // 像素坐标（与 video_pos 等价）
    reg [9:0] pix_x = 0, pix_y = 0;
    always @(posedge vclk) begin
        if (v_cnt == 12'd0 && h_cnt == 10'd0) begin pix_x <= 0; pix_y <= 0; end
        else if (de) begin
            if (pix_x == 10'd639) begin pix_x <= 10'd0; pix_y <= (pix_y == 10'd479) ? 10'd0 : pix_y + 10'd1; end
            else pix_x <= pix_x + 10'd1;
        end
    end

    // ---- line_sched ----
    wire line_toggle;
    wire [9:0] line_num;
    wire prefetch_zero;
    line_sched u_sched (.clk(vclk), .rst(rst), .display_valid(1'b1),
                        .v_cnt(v_cnt), .line_toggle(line_toggle),
                        .line_num(line_num), .prefetch_zero(prefetch_zero));

    // ---- SDRAM 读返回模型：固定 6 拍延迟，保序 ----
    localparam LAT = 6;
    reg        pend [0:LAT-1];
    reg [20:0] paddr[0:LAT-1];
    reg        sdr_vld = 0;
    reg [31:0] sdr_dout = 0;
    wire       App_rd_en;
    wire [20:0]App_rd_addr;
    integer j;
    always @(posedge clk) begin
        sdr_vld  <= pend[LAT-1];
        sdr_dout <= mem[paddr[LAT-1]];
        for (j=LAT-1;j>0;j=j-1) begin pend[j] <= pend[j-1]; paddr[j] <= paddr[j-1]; end
        pend[0]  <= App_rd_en;
        paddr[0] <= App_rd_addr;
    end

    // ---- frame_line_read ----
    wire lb_we, lb_bank, lb_sel;
    wire [9:0] lb_addr;
    wire [23:0] lb_data;
    wire line_busy, line_done, first_done, last_done;

    frame_line_read u_lr (
        .clk(clk), .rst(rst), .enable(1'b1), .Sdr_init_done(1'b1), .sweep_busy(1'b0),
        .base_a(21'd0), .base_b(21'd307200),
        .line_toggle(line_toggle), .line_num(line_num),
        .line_busy(line_busy), .line_done(line_done),
        .first_line_done(first_done), .last_line_done(last_done),
        .App_rd_en(App_rd_en), .App_rd_addr(App_rd_addr),
        .Sdr_busy(1'b0), .Sdr_rd_en(sdr_vld), .Sdr_rd_dout(sdr_dout),
        .lb_we(lb_we), .lb_bank(lb_bank), .lb_addr(lb_addr), .lb_data(lb_data), .lb_sel(lb_sel)
    );

    // ---- 双 bank 行缓冲 + mixer ----
    wire [23:0] lb_a_rdata, lb_b_rdata;
    wire [9:0]  mix_a_addr, mix_b_addr;
    wire [23:0] mix_rgb;

    line_buffer u_lb_a (.wr_clk(clk), .wr_en(lb_we && !lb_sel), .wr_addr({lb_bank, lb_addr}),
                        .wr_data(lb_data), .rd_clk(vclk), .rd_addr({pix_y[0], mix_a_addr}),
                        .rd_data(lb_a_rdata));
    line_buffer u_lb_b (.wr_clk(clk), .wr_en(lb_we &&  lb_sel), .wr_addr({lb_bank, lb_addr}),
                        .wr_data(lb_data), .rd_clk(vclk), .rd_addr({pix_y[0], mix_b_addr}),
                        .rd_data(lb_b_rdata));
    mixer u_mix (.clk(vclk), .rst(rst), .x(pix_x), .mode(2'd2), .alpha(8'd255), .dx(10'd0),
                 .a_data(lb_a_rdata), .b_data(lb_b_rdata),
                 .a_addr(mix_a_addr), .b_addr(mix_b_addr), .rgb(mix_rgb));

    // 边带延迟 2 拍
    reg [9:0] dx1=0, dx2=0, dy1=0, dy2=0;
    reg       de1=0, de2=0, f1=0, f2=0;
    always @(posedge vclk) begin
        de1<=de; dx1<=pix_x; dy1<=pix_y;
        de2<=de1; dx2<=dx1; dy2<=dy1;
        f1 <= (v_cnt<=12'd2); f2 <= f1;      // 前两帧 warm-up 窗口
    end

    integer errors=0, checked=0, frames=0;
    always @(posedge vclk) begin
        if (de2 && !f2) begin
            checked = checked + 1;
            if (mix_rgb !== {dx2[7:0], dy2[7:0], 8'h5a}) begin
                if (errors < 10)
                    $display("  MISMATCH at (%0d,%0d): got %06x expect %06x",
                             dx2, dy2, mix_rgb, {dx2[7:0], dy2[7:0], 8'h5a});
                errors = errors + 1;
            end
        end
    end

    initial begin
        repeat(4) @(posedge vclk); rst <= 0;
        repeat(200000) @(posedge vclk);      // 约 3 帧
        $display("checked=%0d errors=%0d -> %0s", checked, errors, (errors==0) ? "PASS" : "FAIL");
        $finish;
    end
endmodule
