#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_test_bmp.py — 生成 4 张"已知正确"的 640×480 24bit 非压缩 BMP
用于排除“测试图片本身有问题”。

用法：
    python gen_test_bmp.py
    python gen_test_bmp.py --out D:/imgs

输出：
    output_bmp/00_bars.bmp
    output_bmp/01_gradient.bmp
    output_bmp/02_checker.bmp
    output_bmp/03_text.bmp
"""

import argparse
import os
import struct

from PIL import Image, ImageDraw, ImageFont

W, H = 640, 480


def make_bars():
    img = Image.new("RGB", (W, H), (0, 0, 0))
    d = ImageDraw.Draw(img)
    colors = [
        (255, 255, 255),  # white
        (255, 255, 0),    # yellow
        (0, 255, 255),    # cyan
        (0, 255, 0),      # green
        (255, 0, 255),    # magenta
        (255, 0, 0),      # red
        (0, 0, 255),      # blue
        (0, 0, 0),        # black
    ]
    for i, c in enumerate(colors):
        d.rectangle([i * 80, 0, (i + 1) * 80 - 1, H - 1], fill=c)
    d.rectangle([0, 0, W - 1, H - 1], outline=(255, 255, 255), width=8)
    d.text((20, 20), "BARS 640x480", fill=(0, 0, 0))
    return img


def make_gradient():
    img = Image.new("RGB", (W, H), (0, 0, 0))
    d = ImageDraw.Draw(img)
    for y in range(H):
        r = y * 255 // (H - 1)
        g = 255 - r
        d.line([(0, y), (W - 1, y)], fill=(r, g, 128))
    for x in range(0, W, 80):
        d.line([(x, 0), (x, H - 1)], fill=(255, 255, 255))
    return img


def make_checker():
    img = Image.new("RGB", (W, H), (0, 0, 0))
    d = ImageDraw.Draw(img)
    s = 40
    for y in range(0, H, s):
        for x in range(0, W, s):
            c = (255, 255, 255) if ((x // s + y // s) % 2 == 0) else (0, 0, 0)
            d.rectangle([x, y, x + s - 1, y + s - 1], fill=c)
    d.rectangle([0, 0, W - 1, H - 1], outline=(255, 0, 0), width=6)
    return img


def make_text():
    img = Image.new("RGB", (W, H), (255, 255, 255))
    d = ImageDraw.Draw(img)
    font = None
    for f in ("C:/Windows/Fonts/arial.ttf", "C:/Windows/Fonts/arialbd.ttf"):
        if os.path.exists(f):
            try:
                font = ImageFont.truetype(f, 72)
                break
            except Exception:
                pass
    d.rectangle([0, 0, W - 1, H - 1], outline=(0, 0, 255), width=10)
    d.text((40, 120), "FPGA", fill=(0, 0, 0), font=font)
    d.text((40, 220), "640x480", fill=(200, 0, 0), font=font)
    d.text((40, 320), "BMP TEST", fill=(0, 120, 0), font=font)
    return img


def save_and_check(img, path):
    img.save(path, "BMP")
    b = open(path, "rb").read()
    sig = b[0:2]
    width = struct.unpack("<i", b[18:22])[0]
    height = struct.unpack("<i", b[22:26])[0]
    bpp = struct.unpack("<H", b[28:30])[0]
    comp = struct.unpack("<I", b[30:34])[0]
    off = struct.unpack("<I", b[10:14])[0]
    print(f"{os.path.basename(path):16s} size={len(b):7d} sig={sig!r} "
          f"w={width} h={height} bpp={bpp} comp={comp} off={off}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "output_bmp"))
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)

    items = [
        ("00_bars.bmp", make_bars()),
        ("01_gradient.bmp", make_gradient()),
        ("02_checker.bmp", make_checker()),
        ("03_text.bmp", make_text()),
    ]
    for name, img in items:
        save_and_check(img, os.path.join(args.out, name))
    print(f"\nOK: {len(items)} images -> {args.out}")


if __name__ == "__main__":
    main()
