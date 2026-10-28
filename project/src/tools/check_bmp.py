#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
check_bmp.py — 检查 BMP 是否满足 FPGA 读取要求

当前 RTL（M2）硬性要求 640×480；M3 缩放分支目标支持
160×120 ~ 1920×1080。默认按 M3 范围检查，M2 bit 请加
--strict-640x480。

硬性要求：
  - 文件头 'BM'
  - 24 bit、非压缩（BI_RGB=0）
  - 高度为正（bottom-up）
  - 行按 4 字节对齐
  - 文件头里的 file_size 与实际文件长度一致
  - 像素数据完整（offset + stride*height <= 文件长度）

用法：
    python check_bmp.py 01.bmp
    python check_bmp.py output_bmp
    python check_bmp.py output_bmp --strict-640x480
    python check_bmp.py 01.bmp --min 160x120 --max 1920x1080
"""

import argparse
import glob
import os
import struct
import sys

for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8")
    except Exception:
        pass

# M3 缩放支持范围（RTL 参数可在 bmp_scale 中调整）
DEFAULT_MIN_W = 160
DEFAULT_MIN_H = 120
DEFAULT_MAX_W = 1920
DEFAULT_MAX_H = 1080

STRICT_W = 640
STRICT_H = 480
SECTOR_SIZE = 512


def parse_size(text, default):
    """解析 '1920x1080' / '1920,1080' 形式的尺寸。"""
    if text is None:
        return default
    s = str(text).lower().replace(",", "x").replace("*", "x")
    if "x" not in s:
        raise argparse.ArgumentTypeError(f"尺寸格式应为 WxH，例如 1920x1080：{text}")
    try:
        w, h = [int(v) for v in s.split("x", 1)]
    except ValueError:
        raise argparse.ArgumentTypeError(f"尺寸格式应为 WxH，例如 1920x1080：{text}")
    if w <= 0 or h <= 0:
        raise argparse.ArgumentTypeError(f"尺寸必须为正：{text}")
    return w, h


def inspect_bmp(
    path,
    min_w=DEFAULT_MIN_W,
    min_h=DEFAULT_MIN_H,
    max_w=DEFAULT_MAX_W,
    max_h=DEFAULT_MAX_H,
    require_exact=False,
    allow_top_down=False,
    read_pixels=False,
):
    """
    检查单个 BMP，返回 (info, errors, warnings)。

    info 中的字段在 sd_pack.py / sd_verify.py 中复用。
    read_pixels=False 时只读文件头，适合大文件快速检查。
    """
    path = os.fspath(path)
    errors = []
    warnings = []
    info = {
        "path": path,
        "name": os.path.basename(path),
        "actual_size": 0,
        "sig": b"",
        "file_size": 0,
        "offset": 0,
        "dib_size": 0,
        "width": 0,
        "height": 0,
        "height_abs": 0,
        "bottom_up": False,
        "bpp": 0,
        "compression": 0,
        "image_size": 0,
        "stride": 0,
        "padding": 0,
        "pixel_bytes": 0,
        "expected_len": 0,
        "data": None,
    }

    try:
        actual_size = os.path.getsize(path)
        info["actual_size"] = actual_size
        with open(path, "rb") as f:
            head = f.read(54)
            if read_pixels:
                f.seek(0)
                info["data"] = f.read()
    except OSError as e:
        errors.append(f"无法读取：{e}")
        return info, errors, warnings

    if len(head) < 54:
        errors.append(f"文件太小（{len(head)} 字节，至少 54）")
        return info, errors, warnings

    sig = head[0:2]
    file_size = struct.unpack_from("<I", head, 2)[0]
    offset = struct.unpack_from("<I", head, 10)[0]
    dib_size = struct.unpack_from("<I", head, 14)[0]
    width = struct.unpack_from("<i", head, 18)[0]
    height = struct.unpack_from("<i", head, 22)[0]
    planes = struct.unpack_from("<H", head, 26)[0]
    bpp = struct.unpack_from("<H", head, 28)[0]
    compression = struct.unpack_from("<I", head, 30)[0]
    image_size = struct.unpack_from("<I", head, 34)[0]

    info.update(
        sig=sig,
        file_size=file_size,
        offset=offset,
        dib_size=dib_size,
        width=width,
        height=height,
        height_abs=abs(height),
        bottom_up=(height > 0),
        bpp=bpp,
        compression=compression,
        image_size=image_size,
    )

    # ---- 头字段 ----
    if sig != b"BM":
        errors.append(f"签名不是 BM（是 {sig!r}）")
    if dib_size < 40:
        errors.append(f"DIB 头 {dib_size} 字节，要求 >= 40（BITMAPINFOHEADER）")
    elif dib_size > actual_size - 14:
        errors.append(f"DIB 头 {dib_size} 字节，超过文件可容纳范围")
    if planes != 1:
        errors.append(f"planes={planes}，要求 1")
    if bpp != 24:
        errors.append(f"位深={bpp}，要求 24（当前 RTL 不支持 8/16/32bit）")
    if compression != 0:
        errors.append(f"压缩={compression}，要求 0（BI_RGB 非压缩）")
    if width <= 0:
        errors.append(f"宽={width}，必须为正")
    if height == 0:
        errors.append("高=0，非法 BMP")
    elif height < 0 and not allow_top_down:
        errors.append(
            f"高={height}（top-down BMP），当前 RTL 不支持；"
            "请转成 bottom-up（高度为正）"
        )
    if offset < 54:
        errors.append(f"像素偏移={offset}，要求 >= 54")
    elif offset < 14 + dib_size:
        errors.append(f"像素偏移={offset} 小于 14+DIB({14 + dib_size})，会覆盖头")
    if offset > actual_size:
        errors.append(f"像素偏移={offset} 超过文件长度 {actual_size}")
    if file_size == 0:
        errors.append("文件头 file_size=0；RTL 依赖该字段，必须填写真实文件长度")
    elif file_size != actual_size:
        errors.append(f"头里 file_size={file_size}，实际 {actual_size}")

    # ---- 尺寸范围 ----
    h_abs = abs(height) if height else 0
    if width > 0 and h_abs > 0:
        if require_exact:
            if width != STRICT_W or h_abs != STRICT_H:
                errors.append(
                    f"尺寸 {width}x{h_abs}，M2 版要求 {STRICT_W}x{STRICT_H}；"
                    "M3 缩放版请去掉 --strict-640x480"
                )
        else:
            if width < min_w or h_abs < min_h:
                errors.append(
                    f"尺寸 {width}x{h_abs} 小于下限 {min_w}x{min_h}；"
                    "如需支持更小图，请调整 --min 和 RTL 参数"
                )
            if width > max_w or h_abs > max_h:
                errors.append(
                    f"尺寸 {width}x{h_abs} 超过上限 {max_w}x{max_h}；"
                    "请先缩小或调整 RTL 参数"
                )

    # ---- 行对齐与像素区 ----
    if width > 0:
        stride = (width * 3 + 3) & ~3
        padding = stride - width * 3
        pixel_bytes = stride * h_abs
        expected_len = offset + pixel_bytes
        info.update(
            stride=stride,
            padding=padding,
            pixel_bytes=pixel_bytes,
            expected_len=expected_len,
        )

        if expected_len > actual_size:
            errors.append(
                f"像素数据不完整：需要 {expected_len} 字节，实际 {actual_size}"
            )
        elif actual_size > expected_len:
            warnings.append(
                f"文件比像素区多 {actual_size - expected_len} 字节（尾随数据，"
                "RTL 应只取 W*H 个像素）"
            )
        if image_size not in (0, pixel_bytes):
            warnings.append(
                f"image_size={image_size}，按 stride*H 计算应为 {pixel_bytes}"
                "（BI_RGB 允许 0）"
            )
        if padding:
            warnings.append(f"每行有 {padding} 字节填充（奇数宽度/非 4 倍数宽度）")

    return info, errors, warnings


def check_one(path, **kwargs):
    """兼容旧接口：返回 (ok, message)。"""
    info, errors, warnings = inspect_bmp(path, **kwargs)
    msg = (
        f"size={info['actual_size']:7d} sig={info['sig']!r} "
        f"w={info['width']} h={info['height']} bpp={info['bpp']} "
        f"comp={info['compression']} off={info['offset']} "
        f"stride={info['stride']} pad={info['padding']}"
    )
    if errors:
        msg += " | " + "; ".join(errors)
    elif warnings:
        msg += " | WARN: " + "; ".join(warnings)
    return (not errors), msg


def main():
    ap = argparse.ArgumentParser(description="检查 BMP 是否满足 FPGA 读取要求")
    ap.add_argument("path", help="BMP 文件或文件夹")
    ap.add_argument(
        "--strict-640x480",
        action="store_true",
        help="按当前 M2 RTL 的 640x480 硬性要求检查",
    )
    ap.add_argument("--min", default="160x120", help="M3 最小尺寸，默认 160x120")
    ap.add_argument("--max", default="1920x1080", help="M3 最大尺寸，默认 1920x1080")
    ap.add_argument(
        "--allow-top-down",
        action="store_true",
        help="允许高度为负的 top-down BMP（当前 RTL 仍不支持）",
    )
    args = ap.parse_args()

    if args.strict_640x480:
        min_w = min_h = max_w = max_h = 0
        require_exact = True
    else:
        min_w, min_h = parse_size(args.min, (DEFAULT_MIN_W, DEFAULT_MIN_H))
        max_w, max_h = parse_size(args.max, (DEFAULT_MAX_W, DEFAULT_MAX_H))
        require_exact = False

    if os.path.isdir(args.path):
        files = sorted(glob.glob(os.path.join(args.path, "*.bmp")))
    else:
        files = [args.path]

    if not files:
        print("没有找到 .bmp 文件")
        sys.exit(1)

    all_ok = True
    for p in files:
        info, errors, warnings = inspect_bmp(
            p,
            min_w=min_w,
            min_h=min_h,
            max_w=max_w,
            max_h=max_h,
            require_exact=require_exact,
            allow_top_down=args.allow_top_down,
        )
        ok = not errors
        all_ok = all_ok and ok
        tag = "PASS" if ok else "FAIL"
        print(
            f"[{tag}] {info['name']:28s} "
            f"{info['actual_size']:8d} B  {info['width']}x{info['height']}  "
            f"24bpp  stride={info['stride']:5d}  pad={info['padding']}  "
            f"bottom-up={info['bottom_up']}"
        )
        for e in errors:
            print(f"        ERROR: {e}")
        for w in warnings:
            print(f"        WARN : {w}")

    print()
    print("ALL PASS" if all_ok else "FAILED: some files do not match")
    sys.exit(0 if all_ok else 2)


if __name__ == "__main__":
    main()
