#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_font_mif.py — 从 TTF/TTC 生成 16x16 中文点阵 MIF（供 font_rom_cn 使用）

用法：
  python gen_font_mif.py \
      --font "C:/Windows/Fonts/msyh.ttc" \
      --chars font_chars.txt \
      --out ../../rtl/video/font_rom_cn.mif \
      --size 16 --depth 512

输出：
  - MIF：WIDTH=16, DEPTH=depth*16，每行一个 16bit 字（MSB 在左）
  - 同名 .map.txt：index<TAB>char，便于 text_layer 查表

约定：
  - 每个字 16 行 × 16 bit；地址 = char_index*16 + row
  - 行内 bit15 = 最左像素
  - 字符按 font_chars.txt 中首次出现顺序排列，空白/换行忽略
"""

import argparse
import os
import sys

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    print("ERROR: 需要 Pillow：pip install pillow", file=sys.stderr)
    sys.exit(1)


def read_chars(path):
    chars = []
    seen = set()
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.split("#", 1)[0]
            for ch in line:
                if ch.isspace():
                    continue
                if ch not in seen:
                    seen.add(ch)
                    chars.append(ch)
    return chars


def render_char(font, ch, size):
    img = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(img)
    # 以字形包围盒居中
    try:
        bbox = draw.textbbox((0, 0), ch, font=font)
        w = bbox[2] - bbox[0]
        h = bbox[3] - bbox[1]
        x = (size - w) // 2 - bbox[0]
        y = (size - h) // 2 - bbox[1]
    except Exception:
        x, y = 0, 0
    draw.text((x, y), ch, fill=255, font=font)
    return img


def img_to_rows(img, size, threshold=96):
    rows = []
    px = img.load()
    for y in range(size):
        word = 0
        for x in range(size):
            if px[x, y] >= threshold:
                word |= (1 << (size - 1 - x))
        rows.append(word)
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--font", required=True, help="TTF/TTC 字体路径")
    ap.add_argument("--chars", required=True, help="字符列表文本")
    ap.add_argument("--out", required=True, help="输出 MIF 路径")
    ap.add_argument("--size", type=int, default=16, help="点阵尺寸（默认 16）")
    ap.add_argument("--depth", type=int, default=512, help="字库容量（默认 512）")
    ap.add_argument("--index", type=int, default=0, help="TTC 字体索引")
    ap.add_argument("--threshold", type=int, default=96, help="二值化阈值")
    args = ap.parse_args()

    if args.size not in (12, 16, 24):
        print("WARN: size 建议 16（12/24 也可，但 ROM 宽度会变）", file=sys.stderr)

    chars = read_chars(args.chars)
    if len(chars) > args.depth:
        print(f"WARN: 字符数 {len(chars)} > 容量 {args.depth}，截断", file=sys.stderr)
        chars = chars[:args.depth]

    try:
        font = ImageFont.truetype(args.font, args.size, index=args.index)
    except Exception as e:
        print(f"ERROR: 打开字体失败：{e}", file=sys.stderr)
        sys.exit(1)

    # 生成字模
    glyphs = []
    for ch in chars:
        img = render_char(font, ch, args.size)
        glyphs.append(img_to_rows(img, args.size, args.threshold))

    # 补齐空白
    blank = [0] * args.size
    while len(glyphs) < args.depth:
        glyphs.append(blank)

    # 写 MIF
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    width = args.size
    depth_words = args.depth * args.size
    with open(args.out, "w", encoding="utf-8", newline="\n") as f:
        f.write(f"WIDTH={width};\n")
        f.write(f"DEPTH={depth_words};\n")
        f.write("ADDRESS_RADIX=UNS;\n")
        f.write("DATA_RADIX=HEX;\n")
        f.write("CONTENT BEGIN\n")
        addr = 0
        for g in glyphs:
            for row in g:
                mask = (1 << width) - 1
                f.write(f"{addr} : {row & mask:0{(width + 3) // 4}X};\n")
                addr += 1
        f.write("END;\n")

    # 写映射表
    map_path = os.path.splitext(args.out)[0] + ".map.txt"
    with open(map_path, "w", encoding="utf-8", newline="\n") as f:
        for i, ch in enumerate(chars):
            f.write(f"{i}\t{ch}\n")

    print(f"OK: {len(chars)} chars -> {args.out}")
    print(f"    ROM: {width}bit x {depth_words} words")
    print(f"    map: {map_path}")


if __name__ == "__main__":
    main()
