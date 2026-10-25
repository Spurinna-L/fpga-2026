`timescale 1ns/1ps
//=============================================================================
// video_post.v — mixer 之后的视频后处理挂载点（M2 协作边界）
//-----------------------------------------------------------------------------
// 当前为“直通”实现，保证 M2 行缓冲/转场先独立上板。
// 队友负责的亮度/对比度、OSD 全部在这一模块内部完成：
//   - 输入 rgb_in/hs_in/vs_in/de_in/x_in/y_in 已与 mixer 输出严格同拍；
//   - 输出 rgb_out/hs_out/vs_out/de_out/x_out/y_out 必须保持同拍；
//   - 内部新增流水线时，请把 sideband 一起延迟相同拍数。
//
// 参数输入均为慢变量（按键/1Hz），当前直通版本不使用；队友实现时
// 请在模块内部对 brightness/contrast/time/img_idx 等做 2FF 同步后再消费。
//=============================================================================
module video_post (
    input  wire        clk,
    input  wire        rst,

    input  wire [23:0] rgb_in,
    input  wire        hs_in,
    input  wire        vs_in,
    input  wire        de_in,
    input  wire [9:0]  x_in,
    input  wire [9:0]  y_in,

    input  wire signed [7:0] brightness,
    input  wire [7:0]        contrast,
    input  wire              osd_en,
    input  wire [7:0]        time_mm,
    input  wire [7:0]        time_ss,
    input  wire [1:0]        img_idx,
    input  wire [1:0]        trans_mode,
    input  wire [1:0]        audio_src,

    output wire [23:0] rgb_out,
    output wire        hs_out,
    output wire        vs_out,
    output wire        de_out,
    output wire [9:0]  x_out,
    output wire [9:0]  y_out
);

    // TODO(M2 teammate): 亮度/对比度 + OSD 在这里叠加。
    // 先保持直通，便于行缓冲/转场单独验收。
    assign rgb_out = rgb_in;
    assign hs_out  = hs_in;
    assign vs_out  = vs_in;
    assign de_out  = de_in;
    assign x_out   = x_in;
    assign y_out   = y_in;

endmodule
