#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
sd_verify.py — 模拟 bmp_read.v 的原始扇区扫描，检查镜像/卡片能否被 FPGA 识别

它不做文件系统解析，只按 512 字节扇区扫描 'BM'，与 RTL 的
SCAN_START_SECTOR..SCAN_MAX_SECTOR 行为一致。

用法：
    python sd_verify.py output_sd/sd_card.img
    python sd_verify.py output_sd/sd_card.img --expect 4
    python sd_verify.py "\\\\.\\PhysicalDrive2" --expect 4

注意：直接读物理磁盘需要管理员权限；更安全的方式是先校验 .img，
再用 Win32DiskImager / balenaEtcher 写卡。
"""

import argparse
import sys
from pathlib import Path

for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8")
    except Exception:
        pass

from check_bmp import (
    DEFAULT_MAX_H,
    DEFAULT_MAX_W,
    DEFAULT_MIN_H,
    DEFAULT_MIN_W,
    SECTOR_SIZE,
    parse_size,
)

SCAN_MAX_LBA = 131071


def parse_at(data, off, min_w, min_h, max_w, max_h, require_exact):
    """尝试把 off 处解析成 BMP 头；不是有效 BMP 返回 None。"""
    if off + 54 > len(data):
        return None
    head = data[off:off + 54]
    if head[0:2] != b"BM":
        return None

    sig = head[0:2]
    file_size = int.from_bytes(head[2:6], "little")
    offset = int.from_bytes(head[10:14], "little")
    dib = int.from_bytes(head[14:18], "little")
    width = int.from_bytes(head[18:22], "little", signed=True)
    height = int.from_bytes(head[22:26], "little", signed=True)
    planes = int.from_bytes(head[26:28], "little")
    bpp = int.from_bytes(head[28:30], "little")
    comp = int.from_bytes(head[30:34], "little")
    image_size = int.from_bytes(head[34:38], "little")

    if width <= 0 or height <= 0:  # RTL 只匹配 bottom-up
        return None
    if dib < 40 or planes != 1 or bpp != 24 or comp != 0:
        return None
    if offset < 54 or offset >= file_size:
        return None

    if require_exact:
        if width != 640 or height != 480:
            return None
    else:
        if width < min_w or height < min_h or width > max_w or height > max_h:
            return None

    stride = (width * 3 + 3) & ~3
    pixel_bytes = stride * height
    expected = offset + pixel_bytes
    if file_size < expected:
        return None
    if file_size > len(data) - off:
        return None

    return {
        "sig": sig,
        "file_size": file_size,
        "offset": offset,
        "width": width,
        "height": height,
        "bpp": bpp,
        "comp": comp,
        "stride": stride,
        "padding": stride - width * 3,
        "image_size": image_size,
        "sectors": (file_size + SECTOR_SIZE - 1) // SECTOR_SIZE,
    }


def main():
    ap = argparse.ArgumentParser(
        description="模拟 FPGA 原始扇区扫描，校验 SD 镜像/物理卡"
    )
    ap.add_argument("path", help=".img 文件，或 \\\\.\\PhysicalDriveN")
    ap.add_argument("--expect", type=int, default=4, help="期望找到的图片数，默认 4")
    ap.add_argument("--start-lba", type=int, default=0, help="扫描起始 LBA，默认 0")
    ap.add_argument("--max-mb", type=int, default=64, help="扫描范围，默认 64MB")
    ap.add_argument("--strict-640x480", action="store_true", help="按 M2 的 640x480 检查")
    ap.add_argument("--min", default="160x120", help="M3 最小尺寸，默认 160x120")
    ap.add_argument("--max", default="1920x1080", help="M3 最大尺寸，默认 1920x1080")
    args = ap.parse_args()

    if args.strict_640x480:
        min_w = min_h = max_w = max_h = 0
        require_exact = True
    else:
        min_w, min_h = parse_size(args.min, (DEFAULT_MIN_W, DEFAULT_MIN_H))
        max_w, max_h = parse_size(args.max, (DEFAULT_MAX_W, DEFAULT_MAX_H))
        require_exact = False

    max_lba = min(SCAN_MAX_LBA, args.start_lba + args.max_mb * 2048 - 1)
    read_limit = (max_lba + 1) * SECTOR_SIZE + 8 * 1024 * 1024

    p = Path(args.path) if not str(args.path).startswith("\\\\.\\") else args.path
    try:
        if isinstance(p, Path):
            with open(p, "rb") as f:
                data = f.read(read_limit)
        else:
            # 物理磁盘：需要管理员权限
            with open(p, "rb", buffering=0) as f:
                data = f.read(read_limit)
    except PermissionError:
        print("FAIL: 读取物理磁盘需要管理员权限（请用管理员 PowerShell）")
        sys.exit(2)
    except OSError as e:
        print(f"FAIL: 无法读取 {p}：{e}")
        sys.exit(2)

    if len(data) < SECTOR_SIZE:
        print("FAIL: 数据不足一个扇区")
        sys.exit(2)

    print(
        f"扫描 {p}  LBA {args.start_lba}..{max_lba}  "
        f"（{len(data) / 1024 / 1024:.1f}MB 已读）"
    )

    found = []
    lba = args.start_lba
    prev_end = None
    while lba <= max_lba:
        off = lba * SECTOR_SIZE
        info = parse_at(data, off, min_w, min_h, max_w, max_h, require_exact)
        if info is None:
            lba += 1
            continue

        info["lba"] = lba
        info["gap"] = 0 if prev_end is None else lba - prev_end
        found.append(info)
        prev_end = lba + info["sectors"]
        lba = prev_end if prev_end > lba else lba + 1

    print()
    print("  idx  lba      WxH          bytes    sectors  gap")
    for i, e in enumerate(found):
        print(
            f"  {i:>3}  {e['lba']:>7}  "
            f"{e['width']:>4}x{e['height']:<4}  "
            f"{e['file_size']:>8}  {e['sectors']:>7}  {e['gap']:>3}"
        )

    print()
    if not found:
        print("FAIL: 没有找到任何有效 BMP；检查镜像是否写对、LBA 范围是否正确")
        sys.exit(2)
    if len(found) < args.expect:
        print(f"FAIL: 只找到 {len(found)} 张，期望 {args.expect} 张")
        sys.exit(2)
    if len(found) > args.expect:
        print(f"WARN: 找到 {len(found)} 张，多于期望的 {args.expect} 张（RTL 只预载前 4 张）")
    gaps = [e["gap"] for e in found if e["gap"] > 0]
    if gaps:
        print(f"WARN: 有 {len(gaps)} 处文件间空洞（RTL 会逐扇区多扫几下，功能正常但会慢一点）")
    print(f"PASS: 找到 {len(found)} 张可识别的 BMP")
    sys.exit(0)


if __name__ == "__main__":
    main()
