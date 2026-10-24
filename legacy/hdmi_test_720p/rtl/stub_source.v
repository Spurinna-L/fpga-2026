//=============================================================================
// stub_source.v  —  "假数据源"（扮演 WS-B 的解码器，用于独立自测）
//-----------------------------------------------------------------------------
// 输出（接口 I1 的"像素流"部分）：
//   px_we / px_x / px_y / px_pix / frame_done
//
// 图案：白边框 + R 横向渐变 + G 纵向渐变 + B 棋盘格。
//
// 帧标记（双缓冲验证用）：
//   当 MARK=1 时，在左上角 (8..23, 8..23) 画一个 16x16 小方块，
//   颜色 = f(frame_id[1:0])：0=白 1=红 2=绿 3=蓝。
//   这样连续几帧内容不同，能"看见"双缓冲换班是否发生。
//   MARK=0（默认）时图案与旧版完全一致，不影响既有测试台。
//
// 反压：stall=1 时暂停（保持当前像素）。
//=============================================================================
`timescale 1ns / 1ps

module stub_source #(
    parameter W    = 1280,
    parameter H    = 720,
    parameter MARK = 0,       // 1 = 画出帧标记
    parameter PACE = 1,       // 每 PACE 拍才吐 1 个像素（降带宽；1=每拍）
    parameter CHK  = 0        // 1 = 带棋盘格；0 = 去掉棋盘（诊断摩尔纹用）
)(
    input  wire        clk,          // 系统时钟 50MHz
    input  wire        rst_n,
    input  wire        stall,        // 1 = 下游忙，暂停输出
    input  wire [7:0]  frame_id,     // 当前帧号（供帧标记取色）

    output wire        px_we,
    output wire [10:0] px_x,
    output wire [10:0] px_y,
    output wire [15:0] px_pix,
    output reg         frame_done
);

    localparam [15:0] PACEV = PACE;

    reg [10:0] sx, sy;
    reg [15:0] pace_cnt;

    wire pace_ok = (pace_cnt == 16'd0);
    wire adv     = (~stall) & pace_ok;     // 本拍是否推进并输出一个像素

    // 节流：每 PACE 拍输出一个像素（降低写带宽，避免抢占 SDRAM 读）
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)      pace_cnt <= 16'd0;
        else if (!stall) pace_cnt <= pace_ok ? (PACEV - 16'd1) : (pace_cnt - 16'd1);
    end

    // 逐像素推进
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sx         <= 11'd0;
            sy         <= 11'd0;
            frame_done <= 1'b0;
        end else begin
            frame_done <= 1'b0;
            if (adv) begin
                if (sx == W-1) begin
                    sx <= 11'd0;
                    if (sy == H-1) begin
                        sy         <= 11'd0;
                        frame_done <= 1'b1;
                    end else begin
                        sy <= sy + 1'b1;
                    end
                end else begin
                    sx <= sx + 1'b1;
                end
            end
        end
    end

    // ---- 图案 ----
    wire border = (sx < 11'd4) || (sx >= W-4) || (sy < 11'd4) || (sy >= H-4);

    wire [7:0] rr = sx[7:0];
    wire [7:0] gg = sy[7:0];
    wire [7:0] bb = (CHK && (sx[7] ^ sy[7])) ? 8'hFF : 8'h00;

    // ---- 帧标记（可选）----
    wire in_mark = MARK && (sx >= 11'd8) && (sx < 11'd24) &&
                          (sy >= 11'd8) && (sy < 11'd24);

    wire [15:0] mark_rgb = (frame_id[1:0] == 2'd0) ? 16'hFFFF :   // 白
                           (frame_id[1:0] == 2'd1) ? 16'hF800 :   // 红
                           (frame_id[1:0] == 2'd2) ? 16'h07E0 :   // 绿
                                                     16'h001F;    // 蓝

    assign px_we  = rst_n & adv;
    assign px_x   = sx;
    assign px_y   = sy;
    assign px_pix = border  ? 16'hFFFF :
                    in_mark ? mark_rgb :
                              {rr[7:3], gg[7:2], bb[7:3]};

endmodule
