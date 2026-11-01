`timescale 1ns / 1ps
module tb_pad;
  reg clk=0, rst=1; always #5 clk=~clk;
  reg src_valid=0; reg [23:0] src_data=0; reg src_config=0; reg src_eof=0;
  reg [15:0] src_w=0, src_h=0;
  wire out_valid, out_done, src_ready; wire [23:0] out_data;
  integer out_cnt=0, done=0, err=0, i;
  bmp_scale #(.DST_W(640), .DST_H(480), .MAX_SRC_W(1920), .MAX_SRC_H(1080)) dut(
    .clk(clk), .rst(rst), .src_valid(src_valid), .src_data(src_data), .src_sop(1'b0),
    .src_config(src_config), .src_width(src_w), .src_height(src_h),
    .out_valid(out_valid), .out_data(out_data), .out_done(out_done),
    .src_ready(src_ready), .src_eof(src_eof));
  always @(posedge clk) begin
    if (out_valid) begin
      if (out_cnt >= 306700) begin
        if (out_data !== 24'h000000) err = err + 1;   // ???????
      end else if (out_data !== 24'h336699) err = err + 1;
      out_cnt = out_cnt + 1;
      if (out_cnt == 307200) done = 1;
    end
  end
  initial begin
    repeat(5) @(posedge clk); rst<=0; repeat(2) @(posedge clk);
    src_w <= 16'd640; src_h <= 16'd480;
    @(posedge clk); src_config <= 1; @(posedge clk); src_config <= 0;
    // ?? 306700 ??????? eof?????????????
    for (i=0;i<306700;i=i+1) begin
      @(posedge clk); src_valid <= 1; src_data <= 24'h336699;
    end
    @(posedge clk); src_valid <= 0; src_eof <= 1;
    repeat(5000) @(posedge clk);
    $display("PAD TEST: out=%0d done=%0d err=%0d %0s", out_cnt, done, err,
             (done && out_cnt==307200 && err==0) ? "PASS" : "FAIL");
    $finish;
  end
endmodule
