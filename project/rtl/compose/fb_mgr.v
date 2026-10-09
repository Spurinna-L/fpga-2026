//=============================================================================
// fb_mgr.v  —  帧缓冲管理 + 行缓存（Ping-Pong 双缓冲）
//-----------------------------------------------------------------------------
// 职责：
//   1) 管理 SDRAM 中的前台/后台帧缓冲（A/B），在 frame_start 处完成翻转，
//      避免扫描过程中的撕裂；
//   2) 承受解码器（写侧）与扫描输出（读侧）的带宽冲突，向 sdram_ctrl_wrap
//      发起读写请求；
//   3) 为目标域扫描提供连续像素流（内含行缓存，供 bilinear_scaler 取 2x2）。
//
// 与 sdram_ctrl_wrap 的地址映射见 doc/框架说明.md（帧缓冲 A: 0x000000）。
//
// 【当前状态】接口骨架。buf_ready=0 时输出 fallback_rgb（测试图），
//   保证 M1（自研 720p 时序 + HDMI 输出）可先跑通；帧缓冲实读在存储/解码打通后接入。
//=============================================================================
`timescale 1ns / 1ps

module fb_mgr (
    input  wire        clk_pix,
    input  wire        rst_n,

    // 目标域扫描信息（来自 video_timing_720p）
    input  wire        hs_i,
    input  wire        vs_i,
    input  wire        de_i,
    input  wire [10:0] x,
    input  wire [10:0] y,
    input  wire        frame_start,

    // 未就绪时的回退画面（测试图 / 开机自检画面）
    input  wire [15:0] fallback_rgb,

    // 帧缓冲状态与控制
    input  wire        buf_ready,    // 前台缓冲可读（解码器置位）
    input  wire        swap_req,     // 请求翻转（帧末生效）
    output reg         swap_done,    // 翻转完成
    output wire        front_sel,    // 当前前台缓冲 A(0)/B(1)

    // SDRAM 读端口（← sdram_ctrl_wrap RD1）
    input  wire [15:0] sdram_rd_data,
    output wire        sdram_rd_req,
    output wire [20:0] sdram_rd_addr,

    // 解码器写端口（→ sdram_ctrl_wrap WR1）
    input  wire        dec_we,
    input  wire [10:0] dec_x,
    input  wire [10:0] dec_y,
    input  wire [15:0] dec_data,

    // 扫描像素输出
    output wire [15:0] rgb_o
);

    // ---- 前台/后台选择：仅允许在帧起始处翻转（切换无异常红线） ----
    reg front;
    always @(posedge clk_pix or negedge rst_n) begin
        if (!rst_n) begin
            front     <= 1'b0;
            swap_done <= 1'b0;
        end else begin
            swap_done <= 1'b0;
            if (swap_req && frame_start) begin
                front     <= ~front;
                swap_done <= 1'b1;
            end
        end
    end
    assign front_sel = front;

    // ---- SDRAM 读地址（后台实现：按线性像素地址顺序读） ----
    // 帧缓冲 A 起始字地址 = 0x000000；B = 0x0E1000（见存储映射）
    localparam FB_A_BASE = 21'h000000;
    localparam FB_B_BASE = 21'h0E1000;

    wire [20:0] fb_base = front ? FB_B_BASE : FB_A_BASE;
    assign sdram_rd_addr = fb_base + (y * 11'd1280) + x;
    assign sdram_rd_req  = de_i;

    // TODO(存储/解码打通后): 接入 sdram_ctrl_wrap 的 RD1，增加扫描行 FIFO，
    //   并把行缓存（ERAM）输出连到 bilinear_scaler 的 2x2 邻域接口。

    // ---- 扫描输出：缓冲就绪取帧缓冲，否则回退测试图 ----
    assign rgb_o = buf_ready ? sdram_rd_data : fallback_rgb;

    // 解码写侧暂未接入 SDRAM（占位，避免悬空）
    // synthesis translate_off
    wire _unused = &{1'b0, dec_we, dec_x, dec_y, dec_data};
    // synthesis translate_on

endmodule
