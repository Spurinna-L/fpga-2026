`timescale 1ns/1ps
//=============================================================================
// tb_line_buffer.v — 双时钟行缓冲读写测试
//=============================================================================
module tb_line_buffer;

    reg wr_clk = 0, rd_clk = 0;
    always #4 wr_clk = ~wr_clk;     // 125MHz
    always #20 rd_clk = ~rd_clk;    // 25MHz

    reg wr_en = 0;
    reg [10:0] wr_addr = 0;
    reg [23:0] wr_data = 0;
    reg [10:0] rd_addr = 0;
    wire [23:0] rd_data;

    line_buffer dut (
        .wr_clk(wr_clk), .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
        .rd_clk(rd_clk), .rd_addr(rd_addr), .rd_data(rd_data)
    );

    integer i, errs = 0;

    initial begin
        // 写满两个 bank（0..2047）
        @(posedge wr_clk);
        for (i = 0; i < 2048; i = i + 1) begin
            wr_en   <= 1'b1;
            wr_addr <= i[10:0];
            wr_data <= i[23:0];
            @(posedge wr_clk);
        end
        wr_en <= 1'b0;

        repeat (3) @(posedge rd_clk);
        for (i = 0; i < 2048; i = i + 1) begin
            rd_addr <= i[10:0];
            @(posedge rd_clk);
            #1;
            if (rd_data !== i[23:0]) begin
                if (errs < 5) $display("ERR addr=%0d got=%h exp=%h", i, rd_data, i[23:0]);
                errs = errs + 1;
            end
        end

        if (errs == 0) $display("TB_LINE_BUFFER PASS");
        else $display("TB_LINE_BUFFER FAIL errs=%0d", errs);
        $finish;
    end

endmodule
