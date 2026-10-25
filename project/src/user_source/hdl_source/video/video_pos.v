`timescale 1ns/1ps
//=============================================================================
// video_pos.v — 像素坐标（与 de 同拍）
//-----------------------------------------------------------------------------
// 只在 de 有效时推进 x；x=639 时换行。vs 下降沿清零。
// 输出 x/y 直接用于行缓冲读地址和 mixer 的 x 偏移。
//=============================================================================
module video_pos (
    input  wire        clk,
    input  wire        rst,
    input  wire        vs,     // 负极性
    input  wire        de,
    output reg  [9:0]  x,
    output reg  [9:0]  y,
    output reg         vs_d,
    output wire        vs_fall
);

    assign vs_fall = vs_d & ~vs;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            x     <= 10'd0;
            y     <= 10'd0;
            vs_d  <= 1'b1;
        end else begin
            vs_d <= vs;

            if (vs_fall) begin
                x <= 10'd0;
                y <= 10'd0;
            end else if (de) begin
                if (x == 10'd639) begin
                    x <= 10'd0;
                    y <= (y == 10'd479) ? 10'd0 : (y + 10'd1);
                end else begin
                    x <= x + 10'd1;
                end
            end
        end
    end

endmodule
