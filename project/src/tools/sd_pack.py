#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
sd_pack.py — 把 1~4 张 BMP 打包成 FPGA 可直接读取的原始 SD 卡镜像

为什么要打包：
  当前 bmp_read.v 不解析 FAT32，它从 sector 0 开始逐扇区扫描 'BM'，
  命中后按 file_len 连续读取。因此每张 BMP 必须是连续扇区。
  Windows 直接复制不保证连续，官方 sync_to_sd.py 也只是“顺序复制”，
  无法保证碎片化卡上的连续性。

本工具生成确定性的 64MB 原始镜像：
  - 从 --start-lba（默认 2048）开始，按 512 字节对齐连续放置；
  - 每张图记录 LBA/扇区数/SHA256 到 manifest；
  - 剩余空间填 0，旧数据不会干扰扫描；
  - 写卡时用 Win32DiskImager / balenaEtcher 写到物理磁盘。

用法：
    python sd_pack.py 01.bmp 02.bmp 03.bmp 04.bmp
    python sd_pack.py output_bmp -o output_sd/sd_card.img
    python sd_pack.py --fill-missing 01.bmp 02.bmp
    python sd_pack.py output_bmp --strict-640x480
"""

import argparse
import hashlib
import os
import struct
import sys
from datetime import datetime
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
    inspect_bmp,
    parse_size,
)

MAX_IMAGES = 4
DEFAULT_SIZE_MB = 64
DEFAULT_START_LBA = 2048
SCAN_MAX_LBA = 131071  # 与 sd_card_bmp.v 的 SCAN_MAX_SECTOR 一致


def make_black_bmp(width=640, height=480):
    """生成一张纯黑 24-bit bottom-up BMP，用于 --fill-missing。"""
    stride = (width * 3 + 3) & ~3
    pixel_bytes = stride * height
    file_size = 54 + pixel_bytes
    header = struct.pack("<2sIHHI", b"BM", file_size, 0, 0, 54)
    dib = struct.pack(
        "<IiiHHIIiiII",
        40,          # biSize
        width,
        height,      # 正数 = bottom-up
        1,           # biPlanes
        24,          # biBitCount
        0,           # BI_RGB
        pixel_bytes,
        2835, 2835,  # 72 DPI
        0, 0,
    )
    return header + dib + bytes(pixel_bytes)


def black_entry(index):
    data = make_black_bmp()
    width, height = 640, 480
    stride = (width * 3 + 3) & ~3
    return {
        "path": None,
        "name": f"black_{index:02d}.bmp",
        "data": data,
        "size": len(data),
        "width": width,
        "height": height,
        "bpp": 24,
        "stride": stride,
        "padding": stride - width * 3,
        "sha256": hashlib.sha256(data).hexdigest(),
    }


def resolve_inputs(items):
    files = []
    for item in items:
        p = Path(item)
        if p.is_dir():
            files.extend(sorted(x for x in p.iterdir() if x.is_file() and x.suffix.lower() == ".bmp"))
        elif p.is_file():
            files.append(p)
        else:
            raise FileNotFoundError(f"输入不存在：{p}")
    return files


def load_entry(path, index, min_w, min_h, max_w, max_h, require_exact, allow_top_down):
    info, errors, warnings = inspect_bmp(
        path,
        min_w=min_w,
        min_h=min_h,
        max_w=max_w,
        max_h=max_h,
        require_exact=require_exact,
        allow_top_down=allow_top_down,
        read_pixels=True,
    )
    if errors:
        raise ValueError(f"{path}: " + "; ".join(errors))
    for w in warnings:
        print(f"  WARN {Path(path).name}: {w}")

    data = info["data"]
    if data is None:
        raise ValueError(f"{path}: 读取像素失败")
    return {
        "path": Path(path),
        "name": Path(path).name,
        "data": data,
        "size": len(data),
        "width": info["width"],
        "height": info["height_abs"],
        "bpp": info["bpp"],
        "stride": info["stride"],
        "padding": info["padding"],
        "sha256": hashlib.sha256(data).hexdigest(),
    }


def build_manifest(entries, image_path, image_size, start_lba, scan_max_lba):
    lines = [
        "# sd_card.img manifest",
        f"# generated: {datetime.now().isoformat(timespec='seconds')}",
        f"# image: {image_path}",
        f"# image_size_bytes: {image_size}",
        f"# sector_size: {SECTOR_SIZE}",
        f"# start_lba: {start_lba}",
        f"# scan_start_lba: 0",
        f"# scan_max_lba: {scan_max_lba}",
        "# columns: index name lba start_byte sectors bytes width height bpp stride pad sha256",
    ]
    for i, e in enumerate(entries):
        lines.append(
            f"{i}\t{e['name']}\t{e['lba']}\t{e['lba'] * SECTOR_SIZE}\t"
            f"{e['sectors']}\t{e['size']}\t{e['width']}\t{e['height']}\t"
            f"{e['bpp']}\t{e['stride']}\t{e['padding']}\t{e['sha256']}"
        )
    return "\n".join(lines) + "\n"


def main():
    ap = argparse.ArgumentParser(
        description="把 1~4 张 BMP 打包成 FPGA 可读的原始 SD 卡镜像"
    )
    ap.add_argument(
        "images",
        nargs="*",
        help="BMP 文件或目录；按参数顺序对应 SDRAM 槽 0..3",
    )
    ap.add_argument(
        "-o", "--out", default="output_sd/sd_card.img", help="输出镜像，默认 output_sd/sd_card.img"
    )
    ap.add_argument(
        "--size-mb",
        type=int,
        default=DEFAULT_SIZE_MB,
        help=f"镜像大小，默认 {DEFAULT_SIZE_MB}MB（RTL 只扫描前 64MB）",
    )
    ap.add_argument(
        "--start-lba",
        type=int,
        default=DEFAULT_START_LBA,
        help=f"第一张图的起始 LBA，默认 {DEFAULT_START_LBA}（1MB 偏移）",
    )
    ap.add_argument(
        "--fill-missing",
        action="store_true",
        help="不足 4 张时补纯黑 640×480 图，保证 4 个槽位都有确定内容",
    )
    ap.add_argument(
        "--strict-640x480",
        action="store_true",
        help="按当前 M2 RTL 的 640×480 硬性要求检查",
    )
    ap.add_argument("--min", default="160x120", help="M3 最小尺寸，默认 160x120")
    ap.add_argument("--max", default="1920x1080", help="M3 最大尺寸，默认 1920x1080")
    ap.add_argument(
        "--allow-top-down",
        action="store_true",
        help="允许 top-down BMP（当前 RTL 仍不支持，不建议）",
    )
    ap.add_argument("--sort", action="store_true", help="按文件名排序后再分配槽位")
    ap.add_argument("--force", action="store_true", help="覆盖已存在的镜像")
    ap.add_argument("--no-verify", action="store_true", help="写完不做回读校验")
    ap.add_argument("--no-manifest", action="store_true", help="不生成 manifest")
    ap.add_argument("--sha256", action="store_true", help="输出镜像 SHA256")
    args = ap.parse_args()

    if args.size_mb < 1:
        print("--size-mb 必须 >= 1")
        sys.exit(2)
    if args.start_lba < 0:
        print("--start-lba 必须 >= 0")
        sys.exit(2)

    if args.strict_640x480:
        min_w = min_h = 0
        max_w = max_h = 0
        require_exact = True
    else:
        min_w, min_h = parse_size(args.min, (DEFAULT_MIN_W, DEFAULT_MIN_H))
        max_w, max_h = parse_size(args.max, (DEFAULT_MAX_W, DEFAULT_MAX_H))
        require_exact = False

    try:
        files = resolve_inputs(args.images)
    except FileNotFoundError as e:
        print(e)
        sys.exit(2)

    if args.sort:
        files.sort(key=lambda p: p.name)

    if not files and not args.fill_missing:
        print("FAIL: 没有输入 BMP；至少给 1 张，或用 --fill-missing 生成纯黑占位图")
        sys.exit(2)

    if len(files) > MAX_IMAGES:
        print(f"最多 {MAX_IMAGES} 张图，当前 {len(files)} 张；请删减或分卡")
        sys.exit(2)

    entries = []
    try:
        for i, p in enumerate(files):
            entries.append(
                load_entry(
                    p,
                    i,
                    min_w,
                    min_h,
                    max_w,
                    max_h,
                    require_exact,
                    args.allow_top_down,
                )
            )
    except ValueError as e:
        print(f"FAIL: {e}")
        sys.exit(2)

    if len(entries) < MAX_IMAGES:
        if args.fill_missing:
            while len(entries) < MAX_IMAGES:
                entries.append(black_entry(len(entries)))
        else:
            print(
                f"WARN: 只有 {len(entries)} 张图，槽 {len(entries)}..{MAX_IMAGES - 1} "
                "可能保留旧数据；建议加 --fill-missing"
            )

    cur_lba = args.start_lba
    for i, e in enumerate(entries):
        e["index"] = i
        e["lba"] = cur_lba
        e["sectors"] = (e["size"] + SECTOR_SIZE - 1) // SECTOR_SIZE
        cur_lba += e["sectors"]

    end_lba = cur_lba
    required_bytes = end_lba * SECTOR_SIZE
    image_size = args.size_mb * 1024 * 1024

    if required_bytes > image_size:
        need_mb = (required_bytes + 1024 * 1024 - 1) // (1024 * 1024)
        print(
            f"FAIL: 数据需要 {required_bytes} 字节（约 {need_mb}MB），"
            f"镜像只有 {args.size_mb}MB；请增大 --size-mb"
        )
        sys.exit(2)
    if end_lba > SCAN_MAX_LBA + 1:
        print(
            f"FAIL: 最后一张图结束于 LBA {end_lba}，超过 RTL 扫描上限 "
            f"{SCAN_MAX_LBA}；请减小 --start-lba 或图片尺寸"
        )
        sys.exit(2)
    if args.size_mb > 64:
        print(
            f"WARN: 镜像 {args.size_mb}MB > 64MB，RTL 只扫描前 64MB；"
            "超出部分不会参与开机预载"
        )

    out = Path(args.out)
    if out.exists() and not args.force:
        print(f"FAIL: {out} 已存在；加 --force 覆盖")
        sys.exit(2)
    out.parent.mkdir(parents=True, exist_ok=True)

    print(
        f"打包 {len(entries)} 张图 -> {out}  "
        f"({args.size_mb}MB, start_lba={args.start_lba})"
    )
    print("  idx  name                      lba      sectors      bytes    WxH")
    for e in entries:
        print(
            f"  {e['index']:>3}  {e['name'][:24]:24s} "
            f"{e['lba']:>7}  {e['sectors']:>7}  {e['size']:>9}  "
            f"{e['width']}x{e['height']}"
        )

    img = bytearray(image_size)
    for e in entries:
        off = e["lba"] * SECTOR_SIZE
        img[off:off + e["size"]] = e["data"]

    tmp = out.with_name(out.name + ".tmp")
    try:
        with open(tmp, "wb") as f:
            f.write(img)
        os.replace(tmp, out)
    except OSError as e:
        try:
            tmp.unlink(missing_ok=True)
        except OSError:
            pass
        print(f"FAIL: 写镜像失败：{e}")
        sys.exit(2)

    if not args.no_manifest:
        manifest = out.with_suffix(".manifest.txt")
        manifest.write_text(
            build_manifest(entries, out, image_size, args.start_lba, SCAN_MAX_LBA),
            encoding="utf-8",
        )
        print(f"manifest: {manifest}")

    if not args.no_verify:
        print("回读校验 ...")
        with open(out, "rb") as f:
            for e in entries:
                f.seek(e["lba"] * SECTOR_SIZE)
                data = f.read(e["size"])
                if len(data) != e["size"] or hashlib.sha256(data).hexdigest() != e["sha256"]:
                    print(f"FAIL: 回读不一致：{e['name']} @ LBA {e['lba']}")
                    sys.exit(2)
        print("回读校验 OK")

    if args.sha256:
        h = hashlib.sha256()
        with open(out, "rb") as f:
            for chunk in iter(lambda: f.read(1024 * 1024), b""):
                h.update(chunk)
        print(f"SHA256: {h.hexdigest()}")

    print()
    print("下一步：用 Win32DiskImager / balenaEtcher 把该 .img 写到物理 SD 卡")
    print("注意：写到 PhysicalDrive，不是盘符；写完 Windows 提示格式化时不要格式化")


if __name__ == "__main__":
    main()
