`timescale 1ns/1ps
//=============================================================================
// tb_line_sched.v — 行调度边界测试（44 预取、45..523 取 1..479）
//=============================================================================
module tb_line_sched;

    reg clk = 0;
    always #20 clk = ~clk;

    reg rst = 1;
    reg display_valid = 0;
    reg [11:0] v_cnt = 0;

    wire line_toggle;
    wire [9:0] line_num;
    wire prefetch_zero;

    line_sched dut (
        .clk(clk), .rst(rst), .display_valid(display_valid),
        .v_cnt(v_cnt), .line_toggle(line_toggle), .line_num(line_num),
        .prefetch_zero(prefetch_zero)
    );

    integer errs = 0;
    integer v;
    integer count = 0;
    reg tog_d = 0;

    initial begin
        repeat (3) @(posedge clk);
        rst = 0;
        display_valid = 1;
        repeat (2) @(posedge clk);

        for (v = 0; v <= 524; v = v + 1) begin
            v_cnt = v;
            repeat (2) @(posedge clk);
            #1;
            if (prefetch_zero !== (v == 44)) begin
                $display("ERR prefetch_zero v=%0d", v); errs = errs + 1;
            end
            if (line_toggle !== tog_d) begin
                tog_d = line_toggle;
                if ((v < 44) || (v > 523)) begin
                    $display("ERR toggle at v=%0d", v); errs = errs + 1;
                end
                if (line_num !== (v - 44)) begin
                    $display("ERR line_num v=%0d num=%0d", v, line_num); errs = errs + 1;
                end
                count = count + 1;
            end
        end

        if (count != 480) begin
            $display("ERR toggle count=%0d exp=480", count); errs = errs + 1;
        end

        if (errs == 0)
            $display("TB_LINE_SCHED PASS (toggles=%0d)", count);
        else
            $display("TB_LINE_SCHED FAIL errs=%0d", errs);
        $finish;
    end

endmodule
