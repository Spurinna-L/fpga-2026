#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
test_tools.py — 图片工具链冒烟测试

不需要 SD 卡，全部在临时目录完成：
  1) bmp_convert 把 PNG 转成 24-bit bottom-up BMP；
  2) check_bmp 接受 M3 范围、拒绝 top-down；
  3) sd_pack 打包 2 张图 + 补 2 张黑图；
  4) sd_verify 能按 RTL 方式找到 4 张。

用法：
    python test_tools.py
"""

import struct
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image

HERE = Path(__file__).resolve().parent


def run(args, expect=0):
    r = subprocess.run(
        [sys.executable] + args,
        cwd=HERE,
        text=True,
        encoding="utf-8",
        errors="replace",
        capture_output=True,
    )
    if r.returncode != expect:
        print(r.stdout)
        print(r.stderr)
        raise AssertionError(f"命令失败（期望 {expect}，实际 {r.returncode}）：{args}")
    return r


def make_png(path, w, h, color):
    Image.new("RGB", (w, h), color).save(path)


def main():
    with tempfile.TemporaryDirectory(prefix="fpga_tools_") as td:
        td = Path(td)
        src = td / "src"
        out = td / "out"
        src.mkdir()

        # 1) PNG -> BMP
        make_png(src / "a_640x480.png", 640, 480, (255, 0, 0))
        make_png(src / "b_320x240.png", 320, 240, (0, 255, 0))
        make_png(src / "c_641x481.png", 641, 481, (0, 0, 255))
        run(["bmp_convert.py", str(src), "-o", str(out)])

        for name in ("a_640x480.bmp", "b_320x240.bmp", "c_641x481.bmp"):
            assert (out / name).exists(), f"缺少输出 {name}"

        # 2) check_bmp：M3 范围通过
        run(["check_bmp.py", str(out)])

        # 3) top-down 必须被拒绝
        topdown = td / "topdown.bmp"
        b = bytearray((out / "c_641x481.bmp").read_bytes())
        struct.pack_into("<i", b, 22, -481)
        topdown.write_bytes(b)
        run(["check_bmp.py", str(topdown)], expect=2)

        # 4) 打包：2 张 + 2 张黑图；64MB 镜像
        img = td / "sd_card.img"
        run(
            [
                "sd_pack.py",
                str(out / "a_640x480.bmp"),
                str(out / "b_320x240.bmp"),
                "-o",
                str(img),
                "--fill-missing",
            ]
        )
        assert img.stat().st_size == 64 * 1024 * 1024
        assert (td / "sd_card.manifest.txt").exists()

        # 5) 模拟 RTL 扫描
        run(["sd_verify.py", str(img), "--expect", "4"])

        # 6) M2 严格模式应拒绝 320x240
        run(["check_bmp.py", str(out / "b_320x240.bmp"), "--strict-640x480"], expect=2)

    print("ALL TOOLS TESTS PASS")


if __name__ == "__main__":
    main()
