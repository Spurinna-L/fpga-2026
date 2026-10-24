//=============================================================================
// tb_sdram_bhv.v  —  sdram_bhv 自测：写一串已知数据，再读回比对
//=============================================================================
`timescale 1ns / 1ps

module tb_sdram_bhv;

    localparam N = 1000;     // 测试字数

    // ---- 三个时钟（模拟真实：CTRL 100M / 写 50M / 读 75M）----
    reg ctrl_clk = 0, wr_clk = 0, rd_clk = 0;
    always #5    ctrl_clk = ~ctrl_clk;
    always #10   wr_clk   = ~wr_clk;
    always #6.667 rd_clk  = ~rd_clk;

    reg rst_n = 0;

    // WR1
    reg  [15:0] wr1_data = 0;
    reg         wr1      = 0;
    reg  [20:0] wr1_addr = 0, wr1_max = 0;
    reg  [9:0]  wr1_len  = 16;
    reg         wr1_load = 0;
    wire        wr1_full;
    wire [15:0] wr1_use;

    // RD1
    wire [15:0] rd1_data;
    reg         rd1      = 0;
    reg  [20:0] rd1_addr = 0, rd1_max = 0;
    reg  [9:0]  rd1_len  = 16;
    reg         rd1_load = 0;
    wire        rd1_empty;
    wire [15:0] rd1_use;

    sdram_bhv dut (
        .CTRL_CLK(ctrl_clk), .SDRAM_CLK(ctrl_clk), .RESET_N(rst_n),

        .WR1_DATA(wr1_data), .WR1(wr1), .WR1_ADDR(wr1_addr), .WR1_MAX_ADDR(wr1_max),
        .WR1_LENGTH(wr1_len), .WR1_LOAD(wr1_load), .WR1_CLK(wr_clk),
        .WR1_FULL(wr1_full), .WR1_USE(wr1_use),

        .WR2_DATA(16'd0), .WR2(1'b0), .WR2_ADDR(21'd0), .WR2_MAX_ADDR(21'd0),
        .WR2_LENGTH(10'd16), .WR2_LOAD(1'b0), .WR2_CLK(wr_clk),
        .WR2_FULL(), .WR2_USE(),

        .RD1_DATA(rd1_data), .RD1(rd1), .RD1_ADDR(rd1_addr), .RD1_MAX_ADDR(rd1_max),
        .RD1_LENGTH(rd1_len), .RD1_LOAD(rd1_load), .RD1_CLK(rd_clk),
        .RD1_EMPTY(rd1_empty), .RD1_USE(rd1_use),

        .RD2_DATA(), .RD2(1'b0), .RD2_ADDR(21'd0), .RD2_MAX_ADDR(21'd0),
        .RD2_LENGTH(10'd16), .RD2_LOAD(1'b0), .RD2_CLK(rd_clk),
        .RD2_EMPTY(), .RD2_USE()
    );

    // 推一个字（在时钟负沿改变激励，避开采样沿）
    task wr_push; input [15:0] d;
        begin
            @(negedge wr_clk);
            while (wr1_full) @(negedge wr_clk);
            wr1_data = d; wr1 = 1'b1;
            @(negedge wr_clk);
            wr1 = 1'b0;
        end
    endtask

    // 弹一个字（先取 FIFO 头上的数据，再拉高 RD 让它弹出）
    task rd_pop; output [15:0] d;
        begin
            @(negedge rd_clk);
            while (rd1_empty) @(negedge rd_clk);
            d = rd1_data;
            rd1 = 1'b1;
            @(negedge rd_clk);
            rd1 = 1'b0;
        end
    endtask

    integer i, errors;
    reg [15:0] got;

    initial begin
        errors   = 0;
        wr1_addr = 21'd0;  wr1_max = N;
        rd1_addr = 21'd0;  rd1_max = N;

        rst_n = 1'b0;
        #100 rst_n = 1'b1;
        @(negedge ctrl_clk);

        // ---- 配置 + 写 N 个字 ----
        @(negedge wr_clk); wr1_load = 1'b1;
        @(negedge wr_clk); wr1_load = 1'b0;
        $display("[tb] 开始写入 %0d 个字 ...", N);
        for (i = 0; i < N; i = i + 1) wr_push(i[15:0]);

        $display("[tb] 写入完成，等待内部搬运到内存 ...");
        #20000;

        // ---- 配置 + 读回 N 个字 ----
        @(negedge rd_clk); rd1_load = 1'b1;
        @(negedge rd_clk); rd1_load = 1'b0;
        $display("[tb] 开始读回 ...");
        for (i = 0; i < N; i = i + 1) begin
            rd_pop(got);
            if (got !== i[15:0]) begin
                errors = errors + 1;
                if (errors <= 8) $display("   [错] idx=%0d got=%0d exp=%0d", i, got, i[15:0]);
            end
        end

        if (errors == 0) $display("[tb] === PASS: 写入与读回完全一致（%0d 个字）===", N);
        else             $display("[tb] === FAIL: %0d 处不一致 ===", errors);
        $finish;
    end

    // 超时保护
    initial begin
        #5_000_000;
        $display("[tb] TIMEOUT");
        $finish;
    end

endmodule
