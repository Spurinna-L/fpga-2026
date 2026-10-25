`timescale 1ns/1ps
//=============================================================================
// tb_disp_ctrl.v — 转场进度/直切模式单元测试
//=============================================================================
module tb_disp_ctrl;

    reg clk = 0;
    always #20 clk = ~clk;

    reg rst = 1;
    reg display_valid = 0;
    reg [1:0] disp_idx_in = 0;
    reg [1:0] trans_mode_in = 0;
    reg frame_tick = 0;

    wire [1:0] cur_idx, next_idx, mix_mode;
    wire [7:0] alpha;
    wire [9:0] dx;
    wire trans_active;

    disp_ctrl dut (
        .clk(clk), .rst(rst), .display_valid(display_valid),
        .disp_idx_in(disp_idx_in), .trans_mode_in(trans_mode_in),
        .frame_tick(frame_tick),
        .cur_idx(cur_idx), .next_idx(next_idx), .mix_mode(mix_mode),
        .alpha(alpha), .dx(dx), .trans_active(trans_active)
    );

    integer errs = 0;
    integer i;

    task tick;
        begin
            @(posedge clk); frame_tick <= 1'b1;
            @(posedge clk); frame_tick <= 1'b0;
            repeat (2) @(posedge clk);
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        rst = 0;
        display_valid = 1;
        repeat (3) @(posedge clk);

        // 溶解：0 -> 1
        disp_idx_in = 2'd1;
        trans_mode_in = 2'd0;
        repeat (4) @(posedge clk);
        tick;
        #1;
        if (!trans_active || next_idx !== 2'd1 || mix_mode !== 2'd0 || alpha !== 8'd0 || dx !== 10'd0) begin
            $display("ERR dissolve start active=%b next=%0d mode=%0d a=%0d dx=%0d",
                     trans_active, next_idx, mix_mode, alpha, dx);
            errs = errs + 1;
        end

        for (i = 0; i < 63; i = i + 1) tick;
        #1;
        if (!trans_active || alpha !== 8'd255 || dx !== 10'd640 || cur_idx !== 2'd0) begin
            $display("ERR dissolve mid active=%b a=%0d dx=%0d cur=%0d",
                     trans_active, alpha, dx, cur_idx);
            errs = errs + 1;
        end

        tick;
        #1;
        if (trans_active || cur_idx !== 2'd1 || next_idx !== 2'd1 || alpha !== 8'd255 || mix_mode !== 2'd2) begin
            $display("ERR dissolve end active=%b cur=%0d next=%0d a=%0d mode=%0d",
                     trans_active, cur_idx, next_idx, alpha, mix_mode);
            errs = errs + 1;
        end

        // 直切：1 -> 2
        disp_idx_in = 2'd2;
        trans_mode_in = 2'd2;
        repeat (4) @(posedge clk);
        tick;
        #1;
        if (trans_active || cur_idx !== 2'd2 || next_idx !== 2'd2) begin
            $display("ERR direct cur=%0d next=%0d active=%b", cur_idx, next_idx, trans_active);
            errs = errs + 1;
        end

        // 滑动：2 -> 3
        disp_idx_in = 2'd3;
        trans_mode_in = 2'd1;
        repeat (4) @(posedge clk);
        tick;
        #1;
        if (!trans_active || next_idx !== 2'd3 || mix_mode !== 2'd1 || alpha !== 8'd0) begin
            $display("ERR slide start active=%b next=%0d mode=%0d", trans_active, next_idx, mix_mode);
            errs = errs + 1;
        end

        if (errs == 0)
            $display("TB_DISP_CTRL PASS");
        else
            $display("TB_DISP_CTRL FAIL errs=%0d", errs);
        $finish;
    end

endmodule
