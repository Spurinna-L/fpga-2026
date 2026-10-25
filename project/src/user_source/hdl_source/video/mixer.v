`timescale 1ns/1ps
//=============================================================================
// mixer.v — A/B 溶解与水平滑动
//-----------------------------------------------------------------------------
// 输入 a_data/b_data 是上一拍行缓冲读出的像素；本模块在下一拍寄存输出，
// 因此从“给地址”到“RGB 有效”共 2 拍（BRAM 1 拍 + mixer 1 拍）。
//
// 地址生成与显示同拍：
//   溶解：A[x] / B[x]
//   滑动：sum = x + dx
//         sum < 640  -> 显示 A[sum]
//         sum >= 640 -> 显示 B[sum-640]
//   直通：A[x]
//
// 溶解公式（每通道 1 个乘法器，共 3 DSP）：
//   out = A + ((B - A) * alpha >> 8)
//=============================================================================
module mixer (
    input  wire        clk,
    input  wire        rst,

    input  wire [9:0]  x,
    input  wire [1:0]  mode,      // 0=溶解 1=滑动 2=直通
    input  wire [7:0]  alpha,
    input  wire [9:0]  dx,

    input  wire [23:0] a_data,
    input  wire [23:0] b_data,

    output wire [9:0]  a_addr,
    output wire [9:0]  b_addr,
    output reg  [23:0] rgb
);

    wire [10:0] sum = {1'b0, x} + {1'b0, dx};
    wire        sel = (sum >= 11'd640);

    assign a_addr = (mode == 2'd1) ? (sel ? 10'd0 : sum[9:0]) : x;
    assign b_addr = (mode == 2'd1) ? (sel ? (sum - 11'd640) : 10'd0) : x;

    reg [1:0] mode_d;
    reg       sel_d;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            mode_d <= 2'd2;
            sel_d  <= 1'b0;
        end else begin
            mode_d <= mode;
            sel_d  <= sel;
        end
    end

    function [7:0] mix8;
        input [7:0] a;
        input [7:0] b;
        input [7:0] al;
        reg signed [8:0]  d;
        reg signed [17:0] p;
        reg signed [9:0]  s;
        begin
            d = $signed({1'b0, b}) - $signed({1'b0, a});
            p = d * $signed({1'b0, al});
            s = $signed({1'b0, a}) + (p >>> 8);
            if (s < 0)
                mix8 = 8'd0;
            else if (s > 255)
                mix8 = 8'd255;
            else
                mix8 = s[7:0];
        end
    endfunction

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            rgb <= 24'd0;
        end else if (mode_d == 2'd0) begin
            rgb <= {mix8(a_data[23:16], b_data[23:16], alpha),
                    mix8(a_data[15:8],  b_data[15:8],  alpha),
                    mix8(a_data[7:0],   b_data[7:0],   alpha)};
        end else if (mode_d == 2'd1) begin
            rgb <= sel_d ? b_data : a_data;
        end else begin
            rgb <= a_data;
        end
    end

endmodule
