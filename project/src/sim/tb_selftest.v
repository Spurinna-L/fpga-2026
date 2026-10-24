`timescale 1ns/1ps
//=============================================================================
// tb_selftest.v — sdram_selftest 的单元测试
//-----------------------------------------------------------------------------
// 用行为级 SDRAM 模型（固定 5 拍读延迟、按序返回）验证：
//   1) 正常存储：bad_cnt = 0，done = 1；
//   2) 注入 1 个字错误：bad_cnt = 1，first_addr/first_y/first_x 正确；
//   3) 读阶段超时保护不误触发。
// 运行：powershell -File sim/run_sim.ps1
//=============================================================================
module tb_selftest;

    localparam integer WORDS = 1024;
    localparam integer FAULT = 700;          // 700/640 = 1 行，700%640 = 60 列

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg  rst       = 1'b1;
    reg  start_req = 1'b0;
    reg  init_done = 1'b0;
    reg  fault_en  = 1'b0;

    wire        O_active, O_done, O_timeout;
    wire [23:0] O_bad_cnt;
    wire [20:0] O_first_addr;
    wire [8:0]  O_first_y;
    wire [9:0]  O_first_x;
    wire        O_wr_en, O_rd_en;
    wire [20:0] O_wr_addr, O_rd_addr;
    wire [31:0] O_wr_din;

    //-------------------------------------------------------------------------
    // 行为级 SDRAM：写立即生效，读延迟 5 拍、按序返回
    //-------------------------------------------------------------------------
    reg [31:0] mem [0:2047];
    reg [20:0] a0, a1, a2, a3;
    reg        v0, v1, v2, v3;
    reg        sdr_rd_en = 1'b0;
    reg [31:0] sdr_dout  = 32'd0;

    always @(posedge clk) begin
        if (O_wr_en) begin
            if (fault_en && (O_wr_addr == FAULT))
                mem[O_wr_addr[10:0]] <= O_wr_din ^ 32'h0000_0001;
            else
                mem[O_wr_addr[10:0]] <= O_wr_din;
        end

        a0 <= O_rd_addr; v0 <= O_rd_en;
        a1 <= a0;        v1 <= v0;
        a2 <= a1;        v2 <= v1;
        a3 <= a2;        v3 <= v2;
        sdr_rd_en <= v3;
        if (v3) sdr_dout <= mem[a3[10:0]];
    end

    //-------------------------------------------------------------------------
    // DUT
    //-------------------------------------------------------------------------
    sdram_selftest #(
        .TEST_WORDS    (WORDS),
        .SETTLE_CYCLES (16),
        .DRAIN_CYCLES  (16)
    ) dut (
        .clk            (clk),
        .rst            (rst),
        .start_req      (start_req),
        .Sdr_init_done  (init_done),
        .Sdr_rd_en      (sdr_rd_en),
        .Sdr_rd_dout    (sdr_dout),
        .I_base         (21'd0),
        .O_active       (O_active),
        .O_done         (O_done),
        .O_timeout      (O_timeout),
        .O_bad_cnt      (O_bad_cnt),
        .O_first_addr   (O_first_addr),
        .O_first_y      (O_first_y),
        .O_first_x      (O_first_x),
        .O_wr_en        (O_wr_en),
        .O_wr_addr      (O_wr_addr),
        .O_wr_din       (O_wr_din),
        .O_rd_en        (O_rd_en),
        .O_rd_addr      (O_rd_addr)
    );

    integer errors = 0;

    task run_test(input integer exp_bad, input integer exp_addr,
                  input integer exp_y,   input integer exp_x);
        begin
            @(posedge clk); #1 start_req = ~start_req;
            wait (O_active === 1'b1);
            wait (O_active === 1'b0);
            @(posedge clk); #1;

            if (O_done !== 1'b1) begin
                $display("  FAIL: O_done 没有置位"); errors = errors + 1;
            end
            if (O_timeout !== 1'b0) begin
                $display("  FAIL: 意外超时"); errors = errors + 1;
            end
            if (O_bad_cnt !== exp_bad) begin
                $display("  FAIL: bad_cnt=%0d 期望 %0d", O_bad_cnt, exp_bad);
                errors = errors + 1;
            end else begin
                $display("  ok: bad_cnt=%0d", O_bad_cnt);
            end

            if (exp_bad > 0) begin
                if (O_first_addr !== exp_addr) begin
                    $display("  FAIL: first_addr=%0d 期望 %0d", O_first_addr, exp_addr);
                    errors = errors + 1;
                end
                if (O_first_y !== exp_y) begin
                    $display("  FAIL: first_y=%0d 期望 %0d", O_first_y, exp_y);
                    errors = errors + 1;
                end
                if (O_first_x !== exp_x) begin
                    $display("  FAIL: first_x=%0d 期望 %0d", O_first_x, exp_x);
                    errors = errors + 1;
                end
            end
        end
    endtask

    initial begin
        $display("=== tb_selftest ===");

        repeat (5) @(posedge clk);
        #1 rst = 1'b0;
        repeat (3) @(posedge clk);
        init_done = 1'b1;
        repeat (2) @(posedge clk);

        $display("[1] 正常存储（无故障）");
        run_test(0, 0, 0, 0);

        $display("[2] 注入 1 字错误 @ %0d (y=%0d x=%0d)", FAULT, FAULT/640, FAULT%640);
        fault_en = 1'b1;
        run_test(1, FAULT, FAULT/640, FAULT%640);

        if (errors == 0) $display("PASS: 全部检查通过");
        else             $display("FAIL: %0d 处错误", errors);
        $finish;
    end

    initial begin
        #500000;
        $display("FAIL: 仿真超时（DUT 卡死）");
        $finish;
    end

endmodule
