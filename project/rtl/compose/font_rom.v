//=============================================================================
// font_rom.v  —  字符点阵 ROM 封装（复用官方 ascii_3216）
//-----------------------------------------------------------------------------
// 复用：rtl/reuse/misc/ascii_3216.v（EG_LOGIC_BRAM，8bit 数据宽，深度 6080）。
// 结构：ASCII 32x16 点阵，1 字符 = 16 行 × 4 字节 = 64 字节；
//       95 个可打印字符 × 64 = 6080，正好等于 BRAM 深度。
//   地址 addr[12:0] = { char_code[6:0], row[3:0], byte_sel[1:0] }
//   char_code = ASCII - 32
//   row       = 0..15
//   byte_sel  = 0..3（32 位/行，byte0 为最左 8 像素）
//
// 读出延迟 1 拍（BRAM 同步读）。
//
// 【注意】ascii_3216 的字体内容来自 TD IP 生成时加载的初始化文件。
//   若复用当前 al_ip 中的 .v 未带字体数据，请用 3_LCD_320x240 例程的
//   ascii_3216.ipc 在 TD 中重新生成并覆盖 rtl/reuse/misc/ascii_3216.v。
//   中文 16x16 子集建议单独生成 ERAM 初始化文件。
//=============================================================================
`timescale 1ns / 1ps

module font_rom (
    input  wire        clk_pix,
    input  wire [12:0] addr,     // {char_code, row, byte_sel}
    output wire [7:0]  data      // 该行 8 像素（MSB 在左）
);

    ascii_3216 u_ascii_3216 (
        .doa  (data),
        .addra(addr),
        .clka (clk_pix),
        .rsta (1'b0)
    );

endmodule
