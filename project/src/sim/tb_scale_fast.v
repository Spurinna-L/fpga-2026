// tb_scale_fast.v — 快速遍历源尺寸（1 pixel/clk 喂数），查死锁 + 像素位置/黑边
`timescale 1ns / 1ps

module tb_scale_fast;
  reg clk = 0, rst = 1;
  always #5 clk = ~clk;

  reg src_valid = 0;
  reg [23:0] src_data = 0;
  reg src_config = 0;
  reg [15:0] src_w = 0, src_h = 0;
  wire out_valid, out_done, src_ready;
  wire [23:0] out_data;

  bmp_scale #(.DST_W(640), .DST_H(480), .MAX_SRC_W(1920), .MAX_SRC_H(1080)) dut (
    .clk(clk), .rst(rst),
    .src_valid(src_valid), .src_data(src_data), .src_sop(1'b0),
    .src_config(src_config), .src_width(src_w), .src_height(src_h),
    .out_valid(out_valid), .out_data(out_data), .out_done(out_done),
    .src_eof(1'b0),
    .src_ready(src_ready));

  integer out_cnt = 0, done = 0, err = 0;
  integer exp_dw, exp_dh, exp_ox, exp_oy;
  reg [23:0] exp_color = 24'h123456;

  always @(posedge clk) begin
    if (out_valid) begin
      begin : chk
        integer ox, oy;
        ox = out_cnt % 640;
        oy = out_cnt / 640;
        if ((ox >= exp_ox) && (ox < exp_ox + exp_dw) &&
            (oy >= exp_oy) && (oy < exp_oy + exp_dh)) begin
          if (out_data !== exp_color) begin
            if (err < 5) $display("   FAIL @idx=%0d (%0d,%0d) got=%06h exp=%06h", out_cnt, ox, oy, out_data, exp_color);
            err = err + 1;
          end
        end else if (out_data !== 24'h000000) begin
          if (err < 5) $display("   FAIL bar @idx=%0d (%0d,%0d) got=%06h", out_cnt, ox, oy, out_data);
          err = err + 1;
        end
      end
      out_cnt = out_cnt + 1;
      if (out_cnt == 307200) done = 1;
    end
  end

  task geom(input integer w, input integer h);
    begin
      if ((w * 480) >= (h * 640)) begin
        exp_dw = 640; exp_dh = (h * 640) / w;
      end else begin
        exp_dw = (w * 480) / h; exp_dh = 480;
      end
      exp_ox = (640 - exp_dw) / 2;
      exp_oy = (480 - exp_dh) / 2;
    end
  endtask

  task run_img(input integer w, input integer h);
    integer x, y, t;
    begin
      out_cnt = 0; done = 0; err = 0;
      geom(w, h);
      @(posedge clk); src_w <= w[15:0]; src_h <= h[15:0];
      @(posedge clk); src_config <= 1;
      @(posedge clk); src_config <= 0;
      for (y = 0; y < h; y = y + 1)
        for (x = 0; x < w; x = x + 1) begin
          while (!src_ready) @(posedge clk);
          @(posedge clk);
          src_valid <= 1; src_data <= exp_color;
        end
      @(posedge clk); src_valid <= 0;
      t = 0;
      while (!done && t < 6000000) begin @(posedge clk); t = t + 1; end
      $display("%0dx%0d -> %0dx%0d @(%0d,%0d) : out=%0d err=%0d bypass=%b %0s",
               w, h, exp_dw, exp_dh, exp_ox, exp_oy, out_cnt, err, dut.bypass,
               (done && (out_cnt == 307200) && (err == 0)) ? "PASS" : "FAIL");
      if (!done)
        $display("   HANG o_state=%0d phase=%0d y=%0d x=%0d ld_row=%0d rowA=%0d rdyA=%b rowB=%0d rdyB=%b want0=%0d want1=%0d fifo=%0d",
                 dut.o_state, dut.phase, dut.out_y, dut.out_x, dut.ld_row,
                 dut.buf_row_a, dut.buf_ready_a, dut.buf_row_b, dut.buf_ready_b,
                 dut.want_y0_r, dut.want_y1_r, dut.fifo_cnt);
    end
  endtask

  initial begin
    repeat (5) @(posedge clk); rst <= 0; repeat (2) @(posedge clk);
    run_img(160, 120);
    run_img(540, 960);
    run_img(1280, 720);
    run_img(1920, 1080);
    $display("--------------------------------------------------");
    $finish;
  end
endmodule
