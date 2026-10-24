//=============================================================================
// text_layer.v  —  文字/字幕图层生成器（滚动跑马灯 + 信息角标）
//-----------------------------------------------------------------------------
// 对应扩展要求 ①。为 osd_layer 提供叠加像素与 alpha：
//   1) 在字幕带 [txt_y, txt_y+16) 内，按 16 像素字符格取字模；
//   2) 字符内容来自文本行 RAM（char code，由控制层写入）；
//   3) scroll_x 实现无缝水平跑马灯（取模循环）；
//   4) 信息角标/价格牌复用同一取模逻辑，仅坐标窗口不同。
//
// 取模：调用 font_rom.v，地址 {char_code, row, byte_sel}，8bit/行。
//   像素位：pixel = fnt_data[7 - (x_in_char % 8)]，byte_sel = (x_in_char/8)。
//
// 【当前状态】接口骨架；内部尚未取模，ovl_valid 恒 0（不影响主链路的实现）。
//   真正取模与跑马灯逻辑在第 3 周实现（见 TODO）。
//=============================================================================
`timescale 1ns / 1ps

module text_layer (
    input  wire        clk_pix,
    input  wire        rst_n,

    input  wire        de_i,
    input  wire [10:0] x,
    input  wire [10:0] y,

    // font_rom 接口
    output reg  [12:0] fnt_addr,
    input  wire [7:0]  fnt_data,

    // 文本行 RAM 接口（char code 读取；由控制层写入）
    output reg  [6:0]  txt_char_idx,   // 第几个字符
    input  wire [6:0]  txt_char_code,  // ASCII-32

    // 配置
    input  wire [10:0] txt_y,          // 字幕带顶行
    input  wire [10:0] scroll_x,       // 跑马灯水平偏移
    input  wire [7:0]  fg_alpha,       // 文字不透明度
    input  wire [15:0] fg_color,       // 文字颜色 RGB565
    input  wire        osd_en,

    // 叠加层输出
    output reg  [15:0] ovl_rgb,
    output reg  [7:0]  ovl_alpha,
    output reg         ovl_valid
);

    // TODO(第 3 周):
    //   1) 判断 (x,y) 是否落在字幕带；
    //   2) 计算 char_col = (x + scroll_x) / 16，char_x = (x + scroll_x) % 16；
    //   3) txt_char_idx <= char_col; 一拍后取回 txt_char_code；
    //   4) fnt_addr <= {txt_char_code, row[3:0], byte_sel[1:0]}；再一拍取 fnt_data；
    //   5) 取对应 bit 决定 ovl_valid，ovl_rgb=fg_color, ovl_alpha=fg_alpha。
    //   注意：BRAM 与文本 RAM 各有 1 拍读延迟，需与视频流水线对齐（打拍）。

    always @(posedge clk_pix or negedge rst_n) begin
        if (!rst_n) begin
            fnt_addr    <= 13'd0;
            txt_char_idx<= 7'd0;
            ovl_rgb     <= 16'd0;
            ovl_alpha   <= 8'd0;
            ovl_valid   <= 1'b0;
        end else begin
            fnt_addr     <= 13'd0;      // 占位
            txt_char_idx <= 7'd0;       // 占位
            ovl_rgb      <= fg_color;
            ovl_alpha    <= fg_alpha;
            ovl_valid    <= 1'b0;       // 占位：暂不叠加
        end
    end

    // synthesis translate_off
    wire _unused = &{1'b0, de_i, x, y, fnt_data, txt_char_code, txt_y, scroll_x, osd_en};
    // synthesis translate_on

endmodule
