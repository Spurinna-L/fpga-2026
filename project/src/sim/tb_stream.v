`timescale 1ns / 1ps
// ?? bmp_scale ????????????? 640 ? out_valid
module tb_stream;
  reg clk=0, rst=1; always #5 clk=~clk;
  reg src_valid=0; reg [23:0] src_data=0; reg src_config=0; reg src_eof=0;
  reg [15:0] src_w=0, src_h=0;
  wire out_valid, out_done, src_ready, dbg_bypass; wire [23:0] out_data;
  integer out_cnt=0, row_cnt=0, row_pix=0, err=0, done=0;
  integer min_row=9999, max_row=0;
  bmp_scale #(.DST_W(640), .DST_H(480), .MAX_SRC_W(1920), .MAX_SRC_H(1080)) dut(
    .clk(clk), .rst(rst), .src_valid(src_valid), .src_data(src_data),
    .src_config(src_config), .src_width(src_w), .src_height(src_h),
    .out_valid(out_valid), .out_data(out_data), .out_done(out_done),
    .src_ready(src_ready), .src_eof(src_eof), .dbg_bypass(dbg_bypass));

  always @(posedge clk) begin
    if (out_valid) begin
      row_pix = row_pix + 1;
      if (dut.out_x == 10'd0) begin
        // ??????????????
        if (row_pix != 640) begin
          if (err < 8) $display("  BADROW row=%0d pixels=%0d", row_cnt, row_pix);
          err = err + 1;
        end
        if (row_pix < min_row) min_row = row_pix;
        if (row_pix > max_row) max_row = row_pix;
        row_cnt = row_cnt + 1;
        row_pix = 0;
      end
      out_cnt = out_cnt + 1;
      if (out_cnt == 307200) done = 1;
    end
  end

  task run(input integer w, input integer h);
    integer x, y, t;
    begin
      out_cnt=0; row_cnt=0; row_pix=0; err=0; done=0; min_row=9999; max_row=0;
      @(posedge clk); src_w <= w[15:0]; src_h <= h[15:0];
      @(posedge clk); src_config <= 1;
      @(posedge clk); src_config <= 0;
      for (y = 0; y < h; y = y + 1)
        for (x = 0; x < w; x = x + 1) begin
          while (!src_ready) @(posedge clk);
          @(posedge clk); src_valid <= 1; src_data <= {x[7:0], y[7:0], 8'h5A};
        end
      @(posedge clk); src_valid <= 0; src_eof <= 1;
      t = 0;
      while (!done && t < 6000000) begin @(posedge clk); t = t + 1; end
      $fflush;`r`n      $display("%0dx%0d: out=%0d rows=%0d rowpix=%0d..%0d err=%0d bypass=%b %0s", w, h, out_cnt, row_cnt,
               min_row, max_row, err, dbg_bypass,
               (done && (err == 0) && (row_cnt == 480)) ? "PASS" : "FAIL");
      @(posedge clk); src_eof <= 0;
    end
  endtask

  initial begin
    repeat(5) @(posedge clk); rst<=0; repeat(2) @(posedge clk);
    run(320, 226);
    run(160, 90);
    run(320, 240);
    $finish;
  end
endmodule
