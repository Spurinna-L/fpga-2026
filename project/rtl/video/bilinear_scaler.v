//=============================================================================
// bilinear_scaler.v  —  双线性缩放器（反向映射）
//-----------------------------------------------------------------------------
// 对应扩展要求 ③。把任意源分辨率（320x240 ~ 1920x1080）适配到 720p 目标。
//
// 架构（反向映射）：目标域逐像素扫描 —— 对每个目标像素 (x_out,y_out)：
//   1) 计算源坐标 f(x) = x_out * src_w / dst_w（Q16 定点）；
//   2) 取 (x0,y0)、(x0+1,y0)、(x0,y0+1)、(x0+1,y0+1) 四个源像素；
//   3) 按小数部分 wx、wy 加权：
//        out = p00*(1-wx)*(1-wy) + p01*wx*(1-wy)
//            + p10*(1-wx)*wy     + p11*wx*wy
//   4) 每帧在 frame_start 处更新 step_x/step_y。
//
// 说明：本模块假定上游（fb_mgr/行缓存）能在一个有效周期内提供 2x2 邻域
//       （p00~p11）。行缓存与取址由 fb_mgr 负责（ERAM 双行缓存）。
//
// 【当前状态】接口已定稿；内部为"旁路(identity)"占位实现，仅当 src==dst
//   时正确。双线性运算留待第 3 周实现（见 TODO）。
//=============================================================================
`timescale 1ns / 1ps

module bilinear_scaler #(
    parameter DW = 16
)(
    input  wire            clk_pix,
    input  wire            rst_n,
    input  wire            en,           // 1=启用缩放，0=旁路

    // 目标域扫描（来自 video_timing_720p）
    input  wire            de_out,
    input  wire [10:0]     x_out,
    input  wire [10:0]     y_out,
    input  wire            frame_start,

    // 源图像尺寸 / 目标尺寸
    input  wire [10:0]     src_w,
    input  wire [10:0]     src_h,
    input  wire [10:0]     dst_w,
    input  wire [10:0]     dst_h,

    // 源像素 2x2 邻域读取接口（由 fb_mgr / 行缓存提供）
    output wire [10:0]     rd_x0,
    output wire [10:0]     rd_y0,
    input  wire [DW-1:0]   p00,
    input  wire [DW-1:0]   p01,
    input  wire [DW-1:0]   p10,
    input  wire [DW-1:0]   p11,
    input  wire            rd_valid,

    // 缩放结果
    output reg  [DW-1:0]   dst_pix,
    output reg             dst_valid
);

    // ---- 反向映射系数（Q16 定点）：step = src<<16 / dst ----
    reg [31:0] step_x, step_y;
    always @(posedge clk_pix or negedge rst_n) begin
        if (!rst_n) begin
            step_x <= 32'd0;
            step_y <= 32'd0;
        end else if (frame_start) begin
            step_x <= (dst_w != 11'd0) ? ((src_w << 16) / dst_w) : 32'd0;
            step_y <= (dst_h != 11'd0) ? ((src_h << 16) / dst_h) : 32'd0;
        end
    end

    wire [31:0] fx = x_out * step_x;    // Q16
    wire [31:0] fy = y_out * step_y;    // Q16

    assign rd_x0 = fx[31:16];           // 源列整数部分
    assign rd_y0 = fy[31:16];           // 源行整数部分
    // 小数部分（供双线性加权，实现时使用）：
    wire [15:0] wx = fx[15:0];
    wire [15:0] wy = fy[15:0];
    // synthesis translate_off
    wire _unused_wx_wy = |{wx, wy};
    // synthesis translate_on

    // TODO(第 3 周): 用 wx/wy 对 p00~p11 做双线性加权（DSP 乘法器 + 饱和截断）。
    //   大比例缩小时先对源做均值预滤波以抑制摩尔纹。
    always @(posedge clk_pix or negedge rst_n) begin
        if (!rst_n) begin
            dst_pix   <= {DW{1'b0}};
            dst_valid <= 1'b0;
        end else if (!en) begin
            // 旁路：直通 p00（仅 src==dst 正确）
            dst_pix   <= p00;
            dst_valid <= de_out & rd_valid;
        end else begin
            dst_pix   <= p00;           // 占位：待替换为双线性结果
            dst_valid <= de_out & rd_valid;
        end
    end

endmodule
