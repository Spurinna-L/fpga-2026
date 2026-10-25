#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_ascii_font_v.py — 生成 8x16 ASCII 点阵 Verilog 字库（font_ascii_8x16.v）

用途：
    实时参数 OSD（扩展要求 ④）只需要极少量字符，故本工程采用「精简 32 字符集」，
    直接用 case 常量表实现，不依赖 TD IP / MIF / BRAM，综合后是纯 LUT ROM。

用法：
    python gen_ascii_font_v.py ^
        --font "C:/Windows/Fonts/consola.ttf" ^
        --out  ../../src/user_source/hdl_source/video/font_ascii_8x16.v ^
        --size 13

约定（与 osd_composer.v 严格一致）：
    - 地址 = code*16 + row，code 为 0..31，row 为 0..15（row 0 = 顶部）
    - 每行 8 bit，bit7 = 最左像素，bit0 = 最右像素
    - 字符码表见 CODES，索引即 O_code

生成器只负责「画点」，编码/排版逻辑全部在 RTL 里。
"""

import argparse
import os
import sys

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    print("ERROR: 需要 Pillow：pip install pillow", file=sys.stderr)
    sys.exit(1)

# ---------------------------------------------------------------------------
# 字符码表（索引 = Verilog 里的 code，必须与 osd_composer.v 一致）
# 0-9 数字 / 10 ':' / 11 '/' / 12 '+' / 13 '-' / 14 空格 / 15..31 字母
# ---------------------------------------------------------------------------
CODES = (
    "0123456789"
    ":/+- "
    "TIME"
    "BRCN"
    "GAFD"
    "SPOL"
    "."
)

W = 8
H = 16
BITS = 6  # 二值化阈值（0..255）

assert len(CODES) == 32, "字符表必须正好 32 项"


def render(font, ch, align="fixed", dy=0):
    """把单个字符渲染成 8x16 二值位图，返回 16 个 8bit 行值。

    align="fixed" ：所有字符统一从 x=0 起画（等宽字体 advance=8），
                    保证「/」「+」「.」等窄字形不会左右漂移；
    align="center"：按每个字形的包围盒水平居中（不同字符会错位，仅对比用）。
    """
    img = Image.new("L", (W, H), 0)
    draw = ImageDraw.Draw(img)

    if ch == " ":
        return [0] * H

    x, y = 0, dy
    if align == "center":
        try:
            bbox = draw.textbbox((0, 0), ch, font=font)
            gw = bbox[2] - bbox[0]
            gh = bbox[3] - bbox[1]
            x = (W - gw) // 2 - bbox[0]
            y = (H - gh) // 2 - bbox[1]
        except Exception:
            x, y = 0, 0

    draw.text((x, y), ch, fill=255, font=font)

    rows = []
    px = img.load()
    for r in range(H):
        v = 0
        for c in range(W):
            v = (v << 1) | (1 if px[c, r] >= BITS else 0)
        rows.append(v)
    return rows


def ascii_art(rows):
    return "\n".join(
        "    " + "".join("#" if (v >> (7 - i)) & 1 else "." for i in range(W))
        for v in rows
    )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--font", default="C:/Windows/Fonts/consola.ttf")
    ap.add_argument("--out", required=True)
    ap.add_argument("--size", type=int, default=16)
    ap.add_argument("--align", choices=("fixed", "center"), default="fixed",
                    help="fixed=统一 x=0 起点（推荐）；center=逐字包围盒居中")
    ap.add_argument("--dy", type=int, default=0, help="整体垂直偏移（像素）")
    ap.add_argument("--preview", action="store_true", help="打印前几个字符的点阵用于自检")
    args = ap.parse_args()

    font = ImageFont.truetype(args.font, args.size)

    table = []
    for ch in CODES:
        table.append(render(font, ch, args.align, args.dy))

    lines = []
    lines.append("//=============================================================================")
    lines.append("// font_ascii_8x16.v — 8x16 ASCII 精简字库（参数 OSD 用）")
    lines.append("//-----------------------------------------------------------------------------")
    lines.append("// 【本文件由脚本生成，请勿手工修改】")
    lines.append("//   生成器：project/doc/tools/gen_ascii_font_v.py")
    lines.append("//   字体  ：%s  %dpx" % (os.path.basename(args.font), args.size))
    lines.append("//")
    lines.append("// 功能：")
    lines.append("//   组合逻辑常量 ROM：输入 5bit 字符码 + 4bit 行号，输出该行 8bit 点阵。")
    lines.append("//   用 case 常量表实现（不依赖 TD IP / MIF / BRAM），综合后为纯 LUT ROM。")
    lines.append("//")
    lines.append("// 约定（与 osd_composer.v 严格一致）：")
    lines.append("//   - code 0..9  = '0'..'9'；10=':' 11='/' 12='+' 13='-' 14=空格")
    lines.append("//   - code 15..31 = 字母，见下方码表")
    lines.append("//   - row 0 = 字符顶部，row 15 = 字符底部")
    lines.append("//   - bit7 = 最左像素，bit0 = 最右像素")
    lines.append("//")
    lines.append("// 字符码表：")
    for i in range(0, 32, 8):
        seg = "  ".join("%2d:%s" % (i + k, CODES[i + k].replace(" ", "SP"))
                        for k in range(8))
        lines.append("//   " + seg)
    lines.append("//")
    lines.append("// 接口：")
    lines.append("//   in  I_code[4:0]  字符码 0..31")
    lines.append("//   in  I_row[3:0]   行号 0..15")
    lines.append("//   out O_bits[7:0]  该行点阵，bit7 最左")
    lines.append("//")
    lines.append("// 参数：无")
    lines.append("//")
    lines.append("// 内部例化：无")
    lines.append("//=============================================================================")
    lines.append("`timescale 1ns / 1ps")
    lines.append("")
    lines.append("module font_ascii_8x16(")
    lines.append("    input  wire [4:0] I_code,")
    lines.append("    input  wire [3:0] I_row,")
    lines.append("    output reg  [7:0] O_bits")
    lines.append(");")
    lines.append("")
    lines.append("    // {I_code, I_row} 共 9bit，直接作为 case 常量索引")
    lines.append("    always @(*) begin")
    lines.append("        case ({I_code, I_row})")

    for ci, ch in enumerate(CODES):
        lines.append("            // ---- %2d : '%s' ----" % (ci, ch if ch != " " else "SP"))
        for r, v in enumerate(table[ci]):
            lines.append("            9'd%d: O_bits = 8'b%s;" % (ci * 16 + r, format(v, "08b")))

    lines.append("            default: O_bits = 8'b00000000;")
    lines.append("        endcase")
    lines.append("    end")
    lines.append("")
    lines.append("endmodule")

    out = os.path.abspath(args.out)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")

    print("generated: %s (%d codes x %d rows)" % (out, len(CODES), H))

    if args.preview:
        for ch in "0B:T8/+- .A":
            ci = CODES.index(ch)
            print("\n=== '%s' (code %d) ===" % (ch, ci))
            print(ascii_art(table[ci]))


if __name__ == "__main__":
    main()
