//=============================================================================
// keyboard_scan.v — 4×4 矩阵键盘行扫描（单时钟、无派生时钟）
//-----------------------------------------------------------------------------
// 每 SCAN_DIV 个 clk 切换一行；在当前行槽结束前锁存列值。
// 输出 key[15:0]：每位对应一个键，按下为 0（列有上拉）。
// 位映射（与行扫描顺序一致）：
//   row=1110 -> key[15:12]
//   row=1101 -> key[11:8]
//   row=1011 -> key[7:4]
//   row=0111 -> key[3:0]
//=============================================================================
`timescale 1ns / 1ps

module keyboard_scan #(
    parameter integer SCAN_DIV = 16'd4999   // 50MHz / 5000 = 10kHz
)(
    input  wire        clk,
    input  wire        RSTn,
    input  wire [3:0]  col,
    output reg  [3:0]  row,
    output reg  [15:0] key
);

    reg [15:0] div_cnt;
    reg [1:0]  row_idx;

    always @(posedge clk or negedge RSTn) begin
        if (!RSTn) begin
            div_cnt <= 16'd0;
            row_idx <= 2'd0;
            row     <= 4'b1110;
            key     <= 16'hFFFF;
        end else begin
            if (div_cnt == SCAN_DIV) begin
                div_cnt <= 16'd0;

                // 锁存当前行的列值（此时列已稳定）
                case (row_idx)
                    2'd0: key[15:12] <= col;
                    2'd1: key[11:8]  <= col;
                    2'd2: key[7:4]   <= col;
                    default: key[3:0] <= col;
                endcase

                // 切换到下一行
                row_idx <= row_idx + 1'b1;
                case (row_idx + 1'b1)
                    2'd0: row <= 4'b1110;
                    2'd1: row <= 4'b1101;
                    2'd2: row <= 4'b1011;
                    default: row <= 4'b0111;
                endcase
            end else begin
                div_cnt <= div_cnt + 1'b1;
            end
        end
    end

endmodule
