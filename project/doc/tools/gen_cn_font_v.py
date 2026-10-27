#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_cn_font_v.py — 生成 16x16 中文点阵 Verilog 字库（font_cn_16x16.v）

用途：
    底部滚动字幕只需要十几个汉字，故沿用 font_ascii_8x16 的思路：
    用 case 常量表实现「组合 LUT ROM」，不依赖 TD IP / MIF / BRAM，
    综合后是纯 LUT 逻辑，0 BRAM、0 拍延迟。

用法：
    python gen_cn_font_v.py ^
        --text "逐逻辑而行，赴创新之约" ^
        --font "C:/Windows/Fonts/simsun.ttc" ^
        --out  ../../src/user_source/hdl_source/video/font_cn_16x16.v ^
        --size 16 --preview

约定（与 scroll_text_overlay.v 严格一致）：
    - 每个汉字占 16x16 像素，字符码 = 在 TEXT 中的序号（0 起）
    - 地址 = code*16 + row，row 0 = 顶部，row 15 = 底部
    - 每行 16 bit，bit15 = 最左像素，bit0 = 最右像素
    - 生成器只负责「画点」，滚动/排版全部在 RTL 里

注意：
    - 汉字必须用等宽 16px 渲染（--align fixed），否则同一行的字会左右漂移；
    - 全角标点（，。！？）同样占满一个 16x16 单元，属于正常排版。
"""

import argparse
import os
import sys

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    print("ERROR: 需要 Pillow：pip install pillow", file=sys.stderr)
    sys.exit(1)

W = 16
H = 16


def render(font, ch, threshold=96, dy=0):
    """把单个字符渲染成 16x16 二值位图，返回 16 个 16bit 行值。"""
    img = Image.new("L", (W, H), 0)
    draw = ImageDraw.Draw(img)

    if ch == " ":
        return [0] * H

    draw.text((0, dy), ch, fill=255, font=font)

    rows = []
    px = img.load()
    for r in range(H):
        v = 0
        for c in range(W):
            v = (v << 1) | (1 if px[c, r] >= threshold else 0)
        rows.append(v)
    return rows


def ascii_art(rows):
    return "\n".join(
        "    " + "".join("#" if (v >> (15 - i)) & 1 else "." for i in range(W))
        for v in rows
    )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--text", default="逐逻辑而行，赴创新之约",
                    help="要生成的字幕文本（每个字符一个 16x16 单元）")
    ap.add_argument("--font", default="C:/Windows/Fonts/simsun.ttc")
    ap.add_argument("--out", required=True)
    ap.add_argument("--size", type=int, default=16)
    ap.add_argument("--threshold", type=int, default=96,
                    help="二值化阈值 0..255（较小=笔画更粗）")
    ap.add_argument("--dy", type=int, default=0, help="整体垂直偏移（像素）")
    ap.add_argument("--preview", action="store_true", help="打印全部点阵用于自检")
    args = ap.parse_args()

    text = args.text
    if len(text) == 0 or len(text) > 16:
        print("ERROR: 文本长度必须在 1..16 之间（code 为 4bit）", file=sys.stderr)
        sys.exit(1)

    font = ImageFont.truetype(args.font, args.size)

    table = [render(font, ch, args.threshold, args.dy) for ch in text]

    lines = []
    lines.append("//=============================================================================")
    lines.append("// font_cn_16x16.v — 16x16 中文点阵字库（底部滚动字幕用）")
    lines.append("//-----------------------------------------------------------------------------")
    lines.append("// 【本文件由脚本生成，请勿手工修改】")
    lines.append("//   生成器：project/doc/tools/gen_cn_font_v.py")
    lines.append("//   字体  ：%s  %dpx" % (os.path.basename(args.font), args.size))
    lines.append("//   文本  ：%s" % text)
    lines.append("//")
    lines.append("// 功能：")
    lines.append("//   组合逻辑常量 ROM：输入 4bit 字符码 + 4bit 行号，输出该行 16bit 点阵。")
    lines.append("//   用 case 常量表实现（不依赖 TD IP / MIF / BRAM），综合后为纯 LUT ROM。")
    lines.append("//   0 BRAM、0 拍延迟，可直接插在像素通路里组合叠加。")
    lines.append("//")
    lines.append("// 约定（与 scroll_text_overlay.v 严格一致）：")
    lines.append("//   - code 0..%d = 文本第 1..%d 个字符（含全角标点，均占 16x16）" %
                 (len(text) - 1, len(text)))
    lines.append("//   - row 0 = 字符顶部，row 15 = 字符底部")
    lines.append("//   - bit15 = 最左像素，bit0 = 最右像素")
    lines.append("//")
    lines.append("// 字符码表：")
    for i, ch in enumerate(text):
        lines.append("//   %2d : %s" % (i, ch))
    lines.append("//")
    lines.append("// 接口：")
    lines.append("//   in  I_code[3:0]   字符码 0..%d" % (len(text) - 1))
    lines.append("//   in  I_row[3:0]    行号 0..15")
    lines.append("//   out O_bits[15:0]  该行点阵，bit15 最左")
    lines.append("//")
    lines.append("// 参数：TEXT_N = %d（字符个数）" % len(text))
    lines.append("//")
    lines.append("// 内部例化：无")
    lines.append("//=============================================================================")
    lines.append("`timescale 1ns / 1ps")
    lines.append("")
    lines.append("module font_cn_16x16(")
    lines.append("    input  wire [3:0]  I_code,")
    lines.append("    input  wire [3:0]  I_row,")
    lines.append("    output reg  [15:0] O_bits")
    lines.append(");")
    lines.append("")
    lines.append("    // 文本：%s" % text)
    lines.append("    localparam integer TEXT_N = %d;" % len(text))
    lines.append("")
    lines.append("    // {I_code, I_row} 共 8bit，直接作为 case 常量索引")
    lines.append("    always @(*) begin")
    lines.append("        case ({I_code, I_row})")

    for ci, ch in enumerate(text):
        lines.append("            // ---- %2d : '%s' ----" % (ci, ch))
        for r, v in enumerate(table[ci]):
            lines.append("            8'd%d: O_bits = 16'b%s;" % (ci * 16 + r, format(v, "016b")))

    lines.append("            default: O_bits = 16'b0000000000000000;")
    lines.append("        endcase")
    lines.append("    end")
    lines.append("")
    lines.append("endmodule")

    out = os.path.abspath(args.out)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")

    print("generated: %s (%d codes x %d rows)" % (out, len(text), H))

    if args.preview:
        for ch, rows in zip(text, table):
            print("\n=== '%s' ===" % ch)
            print(ascii_art(rows))


if __name__ == "__main__":
    main()
