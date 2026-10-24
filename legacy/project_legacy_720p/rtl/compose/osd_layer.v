//=============================================================================
// osd_layer.v  —  统一图层 alpha 混合单元
//-----------------------------------------------------------------------------
// 对应扩展要求 ①。作为"合成层"的公共混合器：底图(base) 与叠加层(overlay)
// 按 alpha 混合，形成"底图 + 滚动字幕 + 信息角标 + 频谱条 + Logo"的多图层效果。
//
// 图像代数（每通道 8bit 精度近似）：
//   out = (base*(255-a) + ovl*a) / 255
// 其中叠加层像素(ovl_rgb)与不透明度(ovl_alpha)由各子层生成器提供：
//   - text_layer.v : 滚动字幕 / 信息角标（调用 font_rom）
//   - spec_layer   : 音频频谱柱（来自 audio_viz）
//   - logo         : 固件内固定图案
// 多子层：上层用"画家算法"依次通过本单元叠加即可（示例见 top.v）。
//
// 【当前状态】混合单元 + 流水线已实现；各子层生成器为骨架（见 text_layer.v）。
//=============================================================================
`timescale 1ns / 1ps

module osd_layer (
    input  wire        clk_pix,
    input  wire        rst_n,

    // 底图（来自 fb_mgr / 缩放 / 转场）
    input  wire [15:0] base_rgb,
    input  wire        hs_i,
    input  wire        vs_i,
    input  wire        de_i,

    // 叠加层（来自各子层生成器）
    input  wire [15:0] ovl_rgb,
    input  wire [7:0]  ovl_alpha,   // 0=全透明(显示底图), 255=不透明(显示叠加层)
    input  wire        ovl_valid,   // 该像素有叠加内容

    // 输出
    output reg  [15:0] rgb_o,
    output reg         hs_o,
    output reg         vs_o,
    output reg         de_o
);

    // 通道级混合：c = (base*(255-a) + ovl*a) >> 8
    function [4:0] mix5;
        input [4:0] base;
        input [4:0] ovl;
        input [7:0] a;
        begin
            mix5 = (base*(8'd255-a) + ovl*a) >> 8;
        end
    endfunction

    function [5:0] mix6;
        input [5:0] base;
        input [5:0] ovl;
        input [7:0] a;
        begin
            mix6 = (base*(8'd255-a) + ovl*a) >> 8;
        end
    endfunction

    wire [15:0] blended = {
        mix5(base_rgb[15:11], ovl_rgb[15:11], ovl_alpha),
        mix6(base_rgb[10:5],  ovl_rgb[10:5],  ovl_alpha),
        mix5(base_rgb[4:0],   ovl_rgb[4:0],   ovl_alpha)
    };

    always @(posedge clk_pix or negedge rst_n) begin
        if (!rst_n) begin
            rgb_o <= 16'd0;
            hs_o  <= 1'b0;
            vs_o  <= 1'b0;
            de_o  <= 1'b0;
        end else begin
            rgb_o <= !de_i      ? 16'd0 :
                     ovl_valid  ? blended : base_rgb;
            hs_o  <= hs_i;
            vs_o  <= vs_i;
            de_o  <= de_i;
        end
    end

endmodule
