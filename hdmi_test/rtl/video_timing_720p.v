//=============================================================================
// video_timing_720p.v  —  1280x720@60 视频时序发生器（自研，替换官方 TPG）
//-----------------------------------------------------------------------------
// 标准：CEA-861 / 720p60
//   H: active=1280, front porch=110, sync=40, back porch=220, total=1650
//   V: active=720,  front porch=5,   sync=5,  back porch=20,  total=750
//   HS/VS 极性：均为正极性（active 期间为高）
//   pixel clk = 74.25MHz  =>  74.25M / (1650*750) = 60.000Hz
//
// 输出坐标 x/y 仅在 de=1 时有效，供测试图 / 缩放 / OSD / 转场统一使用，
// 是整条视频流水线的"时间基准"。
//
// 时间基准：整条视频流水线（缩放 / OSD / 转场 / HDMI 输出）统一使用该组 hs/vs/de/x/y。
//=============================================================================
`timescale 1ns / 1ps

module video_timing_720p (
    input  wire        clk_pix,     // 74.25MHz 像素时钟
    input  wire        rst_n,       // 像素域复位（低有效）

    // 扫描信息
    output reg         hs,          // 行同步
    output reg         vs,          // 场同步
    output reg         de,          // 数据有效
    output reg  [10:0] x,           // 当前像素列 (0..1279)，de 有效
    output reg  [10:0] y,           // 当前像素行 (0..719)， de 有效

    // 帧/行同步脉冲（供双缓冲翻转、转场启动、OSD 调度）
    output reg         frame_start, // 每帧第一个有效像素处 1 拍
    output reg         line_start   // 每行第一个有效像素处 1 拍
);

    // ---- 时序常量（本模块为唯一权威定义） ----
    localparam H_ACTIVE = 1280; // 水平有效像素数
    localparam H_FP     = 110;  // 水平前沿间隔
    localparam H_SYNC   = 40;   // 水平同步脉冲宽度
    localparam H_BP     = 220;  // 水平后沿间隔
    localparam H_TOTAL  = H_ACTIVE + H_FP + H_SYNC + H_BP;   // 1650
    localparam H_SYNC_START = H_ACTIVE + H_FP;               // 1390
    localparam H_SYNC_END   = H_SYNC_START + H_SYNC;         // 1430

    localparam V_ACTIVE = 720; // 垂直有效像素数
    localparam V_FP     = 5;   // 垂直前沿间隔
    localparam V_SYNC   = 5;   // 垂直同步脉冲宽度
    localparam V_BP     = 20;  // 垂直后沿间隔
    localparam V_TOTAL  = V_ACTIVE + V_FP + V_SYNC + V_BP;   // 750
    localparam V_SYNC_START = V_ACTIVE + V_FP;               // 725
    localparam V_SYNC_END   = V_SYNC_START + V_SYNC;         // 730

    reg [10:0] h_cnt;   // 0..1649
    reg [10:0] v_cnt;   // 0..749

    always @(posedge clk_pix or negedge rst_n) begin
        if (!rst_n) begin
            h_cnt <= 11'd0;
            v_cnt <= 11'd0;
        end else if (h_cnt == H_TOTAL-1) begin
            h_cnt <= 11'd0;
            if (v_cnt == V_TOTAL-1)
                v_cnt <= 11'd0;
            else
                v_cnt <= v_cnt + 1'b1;
        end else begin
            h_cnt <= h_cnt + 1'b1;
        end
    end

    // 组合产生同步与数据有效（均在像素时钟下被下游寄存/使用）
    always @(*) begin
        hs = (h_cnt >= H_SYNC_START) && (h_cnt < H_SYNC_END);   // 正极性
        vs = (v_cnt >= V_SYNC_START) && (v_cnt < V_SYNC_END);   // 正极性
        de = (h_cnt < H_ACTIVE) && (v_cnt < V_ACTIVE);
    end

    always @(posedge clk_pix or negedge rst_n) begin
        if (!rst_n) begin
            x <= 11'd0;
            y <= 11'd0;
        end else begin
            x <= (h_cnt < H_ACTIVE) ? h_cnt : 11'd0;
            y <= (v_cnt < V_ACTIVE) ? v_cnt : 11'd0;
        end
    end

    always @(posedge clk_pix or negedge rst_n) begin
        if (!rst_n) begin
            frame_start <= 1'b0;
            line_start  <= 1'b0;
        end else begin
            line_start  <= (h_cnt == 11'd0) && (v_cnt <  V_ACTIVE);
            frame_start <= (h_cnt == 11'd0) && (v_cnt == 11'd0);
        end
    end

endmodule
