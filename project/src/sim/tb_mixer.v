`timescale 1ns/1ps
//=============================================================================
// tb_mixer.v — 溶解/滑动单元测试
//=============================================================================
module tb_mixer;

    reg clk = 0;
    always #20 clk = ~clk;      // 25MHz

    reg rst = 1;
    reg [9:0] x = 0;
    reg [1:0] mode = 0;
    reg [7:0] alpha = 0;
    reg [9:0] dx = 0;

    wire [9:0] a_addr, b_addr;
    wire [23:0] rgb;

    reg [9:0] a_addr_d, b_addr_d;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            a_addr_d <= 0;
            b_addr_d <= 0;
        end else begin
            a_addr_d <= a_addr;
            b_addr_d <= b_addr;
        end
    end

    function [23:0] mem_a;
        input [9:0] a;
        begin
            mem_a = {8'h10 + a[7:0], 8'h20 + a[7:0], 8'h30 + a[7:0]};
        end
    endfunction

    function [23:0] mem_b;
        input [9:0] a;
        begin
            mem_b = {8'h80 + a[7:0], 8'h90 + a[7:0], 8'hA0 + a[7:0]};
        end
    endfunction

    wire [23:0] a_data = mem_a(a_addr_d);
    wire [23:0] b_data = mem_b(b_addr_d);

    mixer dut (
        .clk(clk), .rst(rst), .x(x), .mode(mode), .alpha(alpha), .dx(dx),
        .a_data(a_data), .b_data(b_data),
        .a_addr(a_addr), .b_addr(b_addr), .rgb(rgb)
    );

    integer errs = 0;
    integer i;

    task check_dissolve;
        input [9:0] xx;
        input [7:0] al;
        reg [7:0] ea, eb;
        reg [8:0] diff;
        integer exp;
        begin
            x = xx; mode = 2'd0; alpha = al; dx = 0;
            repeat (3) @(posedge clk);
            #1;
            ea = 8'h10 + xx[7:0];
            eb = 8'h80 + xx[7:0];
            diff = $signed({1'b0, eb}) - $signed({1'b0, ea});
            exp = ea + ((diff * al) >>> 8);
            if (exp < 0) exp = 0;
            if (exp > 255) exp = 255;
            if (rgb[23:16] !== exp[7:0]) begin
                $display("ERR dissolve x=%0d a=%0d got=%0d exp=%0d", xx, al, rgb[23:16], exp);
                errs = errs + 1;
            end
        end
    endtask

    task check_slide;
        input [9:0] xx;
        input [9:0] ddx;
        reg [10:0] sum;
        reg [23:0] exp;
        begin
            x = xx; mode = 2'd1; alpha = 0; dx = ddx;
            repeat (3) @(posedge clk);
            #1;
            sum = {1'b0, xx} + {1'b0, ddx};
            if (sum < 640)
                exp = mem_a(sum[9:0]);
            else
                exp = mem_b(sum[9:0] - 10'd640);
            if (rgb !== exp) begin
                $display("ERR slide x=%0d dx=%0d got=%h exp=%h", xx, ddx, rgb, exp);
                errs = errs + 1;
            end
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        rst = 0;
        repeat (2) @(posedge clk);

        check_dissolve(10'd0,   8'd0);
        check_dissolve(10'd100, 8'd0);
        check_dissolve(10'd100, 8'd128);
        check_dissolve(10'd639, 8'd255);

        check_slide(10'd0,   10'd0);
        check_slide(10'd100, 10'd0);
        check_slide(10'd100, 10'd320);
        check_slide(10'd500, 10'd320);
        check_slide(10'd0,   10'd640);

        if (errs == 0)
            $display("TB_MIXER PASS");
        else
            $display("TB_MIXER FAIL errs=%0d", errs);
        $finish;
    end

endmodule
