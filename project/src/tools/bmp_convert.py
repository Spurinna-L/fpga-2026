#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
bmp_convert.py — 把 PNG/JPG 等图片转成 FPGA 可读的 24-bit BMP

输出固定为：
  - 'BM' 头
  - 24-bit RGB（无 alpha）
  - BI_RGB 非压缩
  - bottom-up（高度为正）
  - 4 字节行对齐

默认只缩小、不放大，最大 1920×1080（M3 缩放分支上限）；
可用 --no-resize 保留原始尺寸，或用 --max 调整上限。

用法：
    python bmp_convert.py photo.jpg
    python bmp_convert.py photo.jpg -o 01.bmp
    python bmp_convert.py input_images -o output_bmp
    python bmp_convert.py photo.jpg --max 1280x720
    python bmp_convert.py photo.jpg --no-resize
"""

import argparse
import sys
from pathlib import Path

from PIL import Image, ImageOps

for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8")
    except Exception:
        pass

try:
    _LANCZOS = Image.Resampling.LANCZOS
except AttributeError:  # Pillow < 9
    _LANCZOS = Image.LANCZOS

from check_bmp import inspect_bmp, parse_size, DEFAULT_MAX_W, DEFAULT_MAX_H


IMAGE_EXTS = {".png", ".jpg", ".jpeg", ".bmp", ".webp", ".tif", ".tiff", ".gif"}


def parse_bg(text):
    s = str(text).strip().lstrip("#")
    if len(s) != 6:
        raise argparse.ArgumentTypeError("背景色格式应为 RRGGBB，例如 000000")
    try:
        r, g, b = int(s[0:2], 16), int(s[2:4], 16), int(s[4:6], 16)
    except ValueError:
        raise argparse.ArgumentTypeError("背景色格式应为 RRGGBB，例如 000000")
    return (r, g, b)


def convert_one(src, dst, max_size, bg, overwrite=False):
    src = Path(src)
    dst = Path(dst)

    if src.resolve() == dst.resolve() and not overwrite:
        return False, "输入和输出是同一个文件；如确需覆盖请加 --overwrite"

    try:
        img = Image.open(src)
        img = ImageOps.exif_transpose(img)
    except Exception as e:
        return False, f"无法打开图片：{e}"

    src_mode = img.mode
    src_size = img.size

    # 带 alpha / 调色板透明的图先合成到背景色，避免黑边或花屏
    if img.mode in ("RGBA", "LA") or (
        img.mode == "P" and "transparency" in img.info
    ):
        img = img.convert("RGBA")
        canvas = Image.new("RGBA", img.size, bg + (255,))
        img = Image.alpha_composite(canvas, img).convert("RGB")
    else:
        img = img.convert("RGB")

    if max_size is not None:
        mw, mh = max_size
        if img.width > mw or img.height > mh:
            img.thumbnail((mw, mh), _LANCZOS)

    dst.parent.mkdir(parents=True, exist_ok=True)
    try:
        img.save(dst, format="BMP")
    except Exception as e:
        return False, f"保存失败：{e}"

    info, errors, warnings = inspect_bmp(
        dst, min_w=1, min_h=1, max_w=99999, max_h=99999
    )
    if errors:
        return False, "输出文件未通过校验：" + "; ".join(errors)
    if warnings:
        # bmp_convert 的输出应为标准格式，出现警告也提示出来
        print(f"  WARN: {'; '.join(warnings)}")

    print(
        f"  {src.name} [{src_mode} {src_size[0]}x{src_size[1]}] -> "
        f"{dst.name} [{img.width}x{img.height}, {dst.stat().st_size} B]"
    )
    return True, ""


def main():
    ap = argparse.ArgumentParser(description="把图片转换为 FPGA 可读的 24-bit BMP")
    ap.add_argument("input", help="图片文件，或包含图片的文件夹")
    ap.add_argument(
        "-o",
        "--out",
        default="output_bmp",
        help="输出 BMP 文件或输出目录，默认 output_bmp",
    )
    ap.add_argument(
        "--max",
        default=f"{DEFAULT_MAX_W}x{DEFAULT_MAX_H}",
        help=f"最大尺寸，默认 {DEFAULT_MAX_W}x{DEFAULT_MAX_H}；只缩小不放大",
    )
    ap.add_argument(
        "--no-resize",
        action="store_true",
        help="保留原始尺寸（超过 RTL 上限时由 check_bmp.py 报错）",
    )
    ap.add_argument(
        "--bg",
        type=parse_bg,
        default=(0, 0, 0),
        help="透明图合成背景色，RRGGBB，默认 000000",
    )
    ap.add_argument("--overwrite", action="store_true", help="允许覆盖输入文件本身")
    args = ap.parse_args()

    max_size = None if args.no_resize else parse_size(args.max, (DEFAULT_MAX_W, DEFAULT_MAX_H))

    in_path = Path(args.input)
    out_path = Path(args.out)

    if in_path.is_dir():
        files = sorted(
            p for p in in_path.iterdir() if p.is_file() and p.suffix.lower() in IMAGE_EXTS
        )
        if not files:
            print(f"目录里没有可转换的图片：{in_path}")
            sys.exit(1)
        if out_path.suffix.lower() == ".bmp":
            print("输入是目录时，--out 必须是目录")
            sys.exit(1)
        out_dir = out_path
        jobs = [(p, out_dir / (p.stem + ".bmp")) for p in files]
    elif in_path.is_file():
        if out_path.suffix.lower() == ".bmp":
            jobs = [(in_path, out_path)]
        else:
            jobs = [(in_path, out_path / (in_path.stem + ".bmp"))]
    else:
        print(f"输入不存在：{in_path}")
        sys.exit(1)

    print(f"转换 {len(jobs)} 张图片 -> {out_path}")
    ok_count = 0
    for src, dst in jobs:
        ok, err = convert_one(src, dst, max_size, args.bg, args.overwrite)
        if ok:
            ok_count += 1
        else:
            print(f"  FAIL {src.name}: {err}")

    print()
    print(f"完成：{ok_count}/{len(jobs)} 张")
    if ok_count != len(jobs):
        sys.exit(2)


if __name__ == "__main__":
    main()
