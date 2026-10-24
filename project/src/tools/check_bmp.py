#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
check_bmp.py — 检查 BMP 是否满足 FPGA 读取要求

要求（见 bmp_read.v 的 header_match）：
  - 文件头 'BM'
  - 宽 = 640
  - 高 = 480（正数，bottom-up）
  - 24 bit
  - compression = 0（非压缩）
  - pixel data offset >= 54
  - 文件长度 = offset + 640*480*3（640×3 已 4 字节对齐）

用法：
    python check_bmp.py 01.bmp
    python check_bmp.py output_bmp
"""

import argparse
import glob
import os
import struct
import sys


def check_one(path):
    b = open(path, "rb").read()
    if len(b) < 54:
        return False, f"文件太小 ({len(b)} bytes)"

    sig = b[0:2]
    file_size = struct.unpack("<I", b[2:6])[0]
    offset = struct.unpack("<I", b[10:14])[0]
    dib = struct.unpack("<I", b[14:18])[0]
    width = struct.unpack("<i", b[18:22])[0]
    height = struct.unpack("<i", b[22:26])[0]
    bpp = struct.unpack("<H", b[28:30])[0]
    comp = struct.unpack("<I", b[30:34])[0]
    img_size = struct.unpack("<I", b[34:38])[0]

    errs = []
    if sig != b"BM":
        errs.append(f"签名不是 BM（是 {sig!r}）")
    if width != 640:
        errs.append(f"宽={width}，要求 640")
    if height != 480:
        if height == -480:
            errs.append("高=-480（top-down BMP），FPGA 不匹配；请用官方转换脚本")
        else:
            errs.append(f"高={height}，要求 +480")
    if bpp != 24:
        errs.append(f"位深={bpp}，要求 24")
    if comp != 0:
        errs.append(f"压缩={comp}，要求 0（非压缩）")
    if offset < 54:
        errs.append(f"像素偏移={offset}，要求 >=54")
    if file_size != len(b):
        errs.append(f"头里 file_size={file_size}，实际 {len(b)}")
    expect = offset + 640 * 480 * 3
    if len(b) != expect:
        errs.append(f"文件长度={len(b)}，期望 {expect}（640×480×3 + {offset}）")
    if img_size not in (0, 640 * 480 * 3):
        errs.append(f"image_size={img_size}，期望 {640*480*3}")

    info = (f"size={len(b):7d} sig={sig!r} w={width} h={height} "
            f"bpp={bpp} comp={comp} off={offset} dib={dib} img={img_size}")
    if errs:
        return False, info + " | " + "; ".join(errs)
    return True, info


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("path", help="BMP 文件或文件夹")
    args = ap.parse_args()

    if os.path.isdir(args.path):
        files = sorted(glob.glob(os.path.join(args.path, "*.bmp")))
    else:
        files = [args.path]

    if not files:
        print("没有找到 .bmp 文件")
        sys.exit(1)

    all_ok = True
    for p in files:
        ok, msg = check_one(p)
        print(f"[{'PASS' if ok else 'FAIL'}] {os.path.basename(p):24s} {msg}")
        all_ok = all_ok and ok

    print()
    print("ALL PASS" if all_ok else "FAILED: some files do not match")
    sys.exit(0 if all_ok else 2)


if __name__ == "__main__":
    main()
