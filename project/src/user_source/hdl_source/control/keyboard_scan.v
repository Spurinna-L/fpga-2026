//=============================================================================
// keyboard_scan.v — 4×4 矩阵键盘行扫描（单时钟、无派生时钟）
//-----------------------------------------------------------------------------
// 功能：
//   每 SCAN_DIV 个 clk 切换一行（行低有效），在切换前锁存当前行的列值，
//   拼成 16bit 键值。列线上拉，因此按下为 0、松开为 1。
//
// 时钟/复位：clk = 50MHz；RSTn 低有效。
//
// 接口：
//   in  col[3:0]   列线电平
//   out row[3:0]   行驱动（one-hot，低有效）
//   out key[15:0]  键值：row=1110→[15:12]，1101→[11:8]，
//                        1011→[7:4]，0111→[3:0]
//
// 参数：
//   SCAN_DIV = 4999  → 50MHz/5000 = 10kHz，每行停留 0.4ms
//
// 内部例化：无
//
// 备注：
//   只输出电平，消抖由 key_filter 完成；行切换与列锁存同一拍完成。
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
