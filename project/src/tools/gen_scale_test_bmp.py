#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_scale_test_bmp.py — 生成 M3 缩放测试用的多尺寸 BMP

覆盖：
  - 640×480   1:1 旁路
  - 320×240   2 倍放大
  - 160×120   4 倍放大（M3 下限）
  - 1280×720  16:9 → 上下黑边
  - 1920×1080 16:9 → 上下黑边（M3 上限）
  - 641×481   奇数宽度 → 行填充 1 字节
  - 540×960   竖图 → 左右黑边

用法：
    python gen_scale_test_bmp.py
    python gen_scale_test_bmp.py --out D:/imgs/scale
"""

import argparse
import sys
from pathlib import Path

from PIL import Image, ImageDraw

for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8")
    except Exception:
        pass

from check_bmp import inspect_bmp

SPECS = [
    ("10_640x480.bmp", 640, 480),
    ("11_320x240.bmp", 320, 240),
    ("12_160x120.bmp", 160, 120),
    ("13_1280x720.bmp", 1280, 720),
    ("14_1920x1080.bmp", 1920, 1080),
    ("15_641x481.bmp", 641, 481),
    ("16_540x960.bmp", 540, 960),
]


def make_image(w, h, label):
    img = Image.new("RGB", (w, h), (18, 22, 30))
    d = ImageDraw.Draw(img)

    # 4 像素外框，便于检查边缘/黑边
    border = max(2, min(w, h) // 200)
    d.rectangle([0, 0, w - 1, h - 1], outline=(255, 255, 255), width=border)

    # 中心十字 + 网格，便于检查缩放方向/比例
    d.line([(w // 2, 0), (w // 2, h - 1)], fill=(0, 255, 255), width=max(1, w // 320))
    d.line([(0, h // 2), (w - 1, h // 2)], fill=(255, 0, 255), width=max(1, h // 240))

    step = max(16, min(w, h) // 8)
    for x in range(step, w, step):
        d.line([(x, 0), (x, h - 1)], fill=(70, 70, 70), width=1)
    for y in range(step, h, step):
        d.line([(0, y), (w - 1, y)], fill=(70, 70, 70), width=1)

    # 四角色块，方向错了会非常明显
    cw, ch = max(8, w // 10), max(8, h // 10)
    d.rectangle([0, 0, cw, ch], fill=(255, 0, 0))                   # 左上红
    d.rectangle([w - cw, 0, w - 1, ch], fill=(0, 255, 0))          # 右上绿
    d.rectangle([0, h - ch, cw, h - 1], fill=(0, 0, 255))          # 左下蓝
    d.rectangle([w - cw, h - ch, w - 1, h - 1], fill=(255, 255, 0))  # 右下黄

    text = f"{label}  {w}x{h}"
    d.text((max(4, w // 30), max(4, h // 20)), text, fill=(255, 255, 255))
    return img


def main():
    ap = argparse.ArgumentParser(description="生成 M3 缩放测试 BMP")
    ap.add_argument("--out", default="output_scale_bmp", help="输出目录")
    args = ap.parse_args()

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    for name, w, h in SPECS:
        path = out / name
        img = make_image(w, h, name.split("_")[0])
        img.save(path, format="BMP")
        info, errors, warnings = inspect_bmp(path, min_w=1, min_h=1)
        if errors:
            print(f"[FAIL] {name}: " + "; ".join(errors))
            sys.exit(2)
        print(
            f"[OK] {name:20s} {w:4d}x{h:<4d} "
            f"{path.stat().st_size:8d} B  stride={info['stride']:5d}  "
            f"pad={info['padding']}"
        )
        for wmsg in warnings:
            print(f"       WARN: {wmsg}")

    print(f"\n输出目录：{out.resolve()}")
    print("M2 当前 bit 只能用 10_640x480.bmp；其余用于 M3 缩放 bit。")


if __name__ == "__main__":
    main()
