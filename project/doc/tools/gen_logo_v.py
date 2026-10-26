#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_logo_v.py — 把任意 PNG/JPG 图标缩成 32x32 点阵 Verilog ROM（logo_data_32x32.v）

用途：
    左上角「Logo 水印图层」（M2 扩展④ 第二层叠加）。与 font_ascii_8x16.v 同思路：
    纯 case 常量表 → 综合成纯 LUT ROM，不用 TD IP / MIF / BRAM，
    并且是**组合读**（0 拍延迟），因此可以“零影响”地插进现有视频通路。

处理流程（保证 32x32 下尽量清晰）：
    1) 白色背景 → alpha（本工程的 logo 是白底 RGB 图，直接叠加会带一个白方块）；
       a = 1 - min(r,g,b)/255，再反预乘还原真实颜色 c = (c_obs - 255*(1-a)) / a
    2) 按内容包围盒裁掉多余白边
    3) 预乘 alpha 后做 LANCZOS 缩放（避免透明边缘出现白/黑边），等比放进 32x32，
       居中留透明边（不拉伸变形）
    4) 对 alpha 做一次轻微反锐化，二值化后边缘更“实”，小尺寸下更清晰
    5) 颜色量化到 RGB555（用 v<<3 | v>>2 还原到 8bit，误差 <= 2）

用法：
    python gen_logo_v.py ^
        --src "C:/Users/Lenovo/Desktop/4c48b8a6466aa5fef0666674ab8f56ef.png" ^
        --out ../../src/user_source/hdl_source/video/logo_data_32x32.v ^
        --preview preview_logo.png

约定（与 logo_overlay.v 严格一致）：
    - 地址 = {dy[4:0], dx[4:0]}，即 addr = y*32 + x，y/x 为 Logo 内坐标（0..31）
    - 每像素 16 bit：{opaque, r[4:0], g[4:0], b[4:0]}，opaque=1 表示该点覆盖原图
    - opaque=0 的像素颜色无意义（输出恒 0），原图完全直通

生成器只负责「画点」，叠加/定位逻辑全部在 RTL 里。
"""

import argparse
import os
import sys

try:
    import numpy as np
    from PIL import Image, ImageFilter
except ImportError:
    print("ERROR: 需要 Pillow 与 numpy：pip install pillow numpy", file=sys.stderr)
    sys.exit(1)

SIZE = 32


def load_rgba(path):
    """白底 → RGBA（反预乘），返回 float32 [h,w,4]，分量 0..1。"""
    im = Image.open(path).convert("RGB")
    obs = np.asarray(im).astype(np.float32) / 255.0

    # 白底抠图：越接近白色 alpha 越小
    mn = obs.min(axis=2)
    a = np.clip(1.0 - mn, 0.0, 1.0)
    a[a < 0.02] = 0.0

    # 反预乘：obs = a*c + (1-a)*1  →  c = (obs - (1-a)) / a
    safe = np.where(a > 1e-6, a, 1.0)[..., None]
    c = (obs - (1.0 - a[..., None])) / safe
    c = np.clip(c, 0.0, 1.0)
    c[a == 0.0] = 0.0
    return np.dstack([c, a])


def crop_content(rgba, thresh=0.08):
    m = rgba[..., 3] > thresh
    if not m.any():
        return rgba
    ys, xs = np.where(m)
    return rgba[ys.min():ys.max() + 1, xs.min():xs.max() + 1]


def resize_premul(rgba, w, h):
    """预乘后缩放，避免透明边缘串色；返回非预乘 float32 [h,w,4]。"""
    a = rgba[..., 3]
    pm = rgba[..., :3] * a[..., None]
    A = Image.fromarray((np.clip(a, 0, 1) * 255).astype(np.uint8), "L")
    Pm = [Image.fromarray((np.clip(pm[..., i], 0, 1) * 255).astype(np.uint8), "L")
          for i in range(3)]

    A = A.resize((w, h), Image.LANCZOS)
    Pm = [p.resize((w, h), Image.LANCZOS) for p in Pm]

    a2 = np.asarray(A).astype(np.float32) / 255.0
    pm2 = np.stack([np.asarray(p).astype(np.float32) / 255.0 for p in Pm], axis=2)
    safe = np.where(a2 > 1e-3, a2, 1.0)[..., None]
    c2 = np.clip(pm2 / safe, 0.0, 1.0)
    c2[a2 <= 1e-3] = 0.0
    return np.dstack([c2, a2])


def sharpen_alpha(rgba, amount=0.55):
    a = Image.fromarray((np.clip(rgba[..., 3], 0, 1) * 255).astype(np.uint8), "L")
    blur = a.filter(ImageFilter.GaussianBlur(radius=0.7))
    a2 = np.asarray(a).astype(np.float32) + amount * (
        np.asarray(a).astype(np.float32) - np.asarray(blur).astype(np.float32))
    out = rgba.copy()
    out[..., 3] = np.clip(a2 / 255.0, 0.0, 1.0)
    return out


def quantize(rgba, alpha_thresh):
    """→ uint16 值数组 [h,w]，{opaque, r5, g5, b5}。"""
    rgb = np.clip(np.rint(rgba[..., :3] * 255.0), 0, 255).astype(np.int32)
    r5 = np.rint(rgb[..., 0] * 31 / 255).astype(np.int32)
    g5 = np.rint(rgb[..., 1] * 31 / 255).astype(np.int32)
    b5 = np.rint(rgb[..., 2] * 31 / 255).astype(np.int32)
    op = (rgba[..., 3] >= alpha_thresh).astype(np.int32)
    # 透明像素不要贡献颜色，避免量化抖动
    out = np.where(op > 0, (1 << 15) | (r5 << 10) | (g5 << 5) | b5, 0)
    return out.astype(np.uint16)


def despeckle(pix):
    """去掉 8 邻域全空的孤立像素（缩到 32px 后常出现，肉眼是很脏的白点）。"""
    op = (pix & 0x8000).astype(np.int32)
    h, w = op.shape
    pad = np.zeros((h + 2, w + 2), dtype=np.int32)
    pad[1:-1, 1:-1] = op
    cnt = np.zeros((h, w), dtype=np.int32)
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            cnt += pad[1 + dy:1 + dy + h, 1 + dx:1 + dx + w]
    keep = (op > 0) & (cnt > 1)
    out = pix.copy()
    out[~keep] = 0
    return out


def make_canvas(pix):
    """把内容居中放进 32x32 画布（不缩放）。"""
    h, w = pix.shape
    canvas = np.zeros((SIZE, SIZE), dtype=np.uint16)
    y0 = (SIZE - h) // 2
    x0 = (SIZE - w) // 2
    canvas[y0:y0 + h, x0:x0 + w] = pix
    return canvas


def preview(canvas, path):
    """把结果放大 8 倍贴在中灰底上，方便肉眼检查清晰度。"""
    bg = np.full((SIZE, SIZE, 3), 110, dtype=np.int32)
    for y in range(SIZE):
        for x in range(SIZE):
            v = int(canvas[y, x])
            if v & 0x8000:
                r = ((v >> 10) & 31)
                g = ((v >> 5) & 31)
                b = (v & 31)
                bg[y, x] = [(r << 3) | (r >> 2), (g << 3) | (g >> 2), (b << 3) | (b >> 2)]
    img = Image.fromarray(bg.astype(np.uint8), "RGB").resize(
        (SIZE * 8, SIZE * 8), Image.NEAREST)
    img.save(path)
    # 终端 ASCII 预览：A=深色 R=红 .=透明
    for y in range(SIZE):
        line = []
        for x in range(SIZE):
            v = int(canvas[y, x])
            if not (v & 0x8000):
                line.append(".")
            else:
                if (v >> 10) & 31 > 10 and (v & 31) < 12:
                    line.append("R")
                else:
                    line.append("#")
        print("    " + "".join(line))


def emit_verilog(canvas, out_path, src_name):
    L = []
    L.append("//=============================================================================")
    L.append("// logo_data_32x32.v — 32x32 Logo 点阵 ROM（左上角水印图层用）")
    L.append("//-----------------------------------------------------------------------------")
    L.append("// 【本文件由脚本生成，请勿手工修改】")
    L.append("//   生成器：project/doc/tools/gen_logo_v.py")
    L.append("//   源图  ：%s" % src_name)
    L.append("//")
    L.append("// 功能：")
    L.append("//   组合逻辑常量 ROM：输入 10bit 像素地址（{y[4:0], x[4:0]}），")
    L.append("//   输出 16bit = {opaque, r[4:0], g[4:0], b[4:0]}。")
    L.append("//   用 case 常量表实现（不依赖 TD IP / MIF / BRAM），综合后为纯 LUT ROM，")
    L.append("//   组合读 = 0 拍延迟，可直接串进像素通路而不改变原有流水对齐。")
    L.append("//")
    L.append("// 约定（与 logo_overlay.v 严格一致）：")
    L.append("//   - 地址 addr = y*32 + x，x 0..31 自左向右，y 0..31 自上向下")
    L.append("//   - opaque = 1：该点覆盖原图；opaque = 0：原图完全直通")
    L.append("//   - 颜色为 RGB555，还原 8bit：v8 = (v5 << 3) | (v5 >> 2)")
    L.append("//")
    L.append("// 内容预览（'.'=透明  '#'=深色  'R'=红色）：")
    for y in range(SIZE):
        row = []
        for x in range(SIZE):
            v = int(canvas[y, x])
            if not (v & 0x8000):
                row.append(".")
            elif ((v >> 10) & 31) > 10 and (v & 31) < 12:
                row.append("R")
            else:
                row.append("#")
        L.append("//   %s" % "".join(row))
    L.append("//")
    L.append("// 接口：")
    L.append("//   in  I_addr[9:0]   像素地址 {y[4:0], x[4:0]}")
    L.append("//   out O_pix[15:0]   {opaque, r[4:0], g[4:0], b[4:0]}")
    L.append("//")
    L.append("// 参数/常量：SIZE = 32")
    L.append("// 内部例化：无")
    L.append("//=============================================================================")
    L.append("`timescale 1ns / 1ps")
    L.append("")
    L.append("module logo_data_32x32(")
    L.append("    input  wire [9:0]  I_addr,")
    L.append("    output reg  [15:0] O_pix")
    L.append(");")
    L.append("")
    L.append("    always @(*) begin")
    L.append("        case (I_addr)")
    for y in range(SIZE):
        row = [int(v) for v in canvas[y]]
        if all(v == 0 for v in row):
            continue  # 整行透明（上下留白）不占表项
        L.append("            // ---- row %2d ----" % y)
        for x in range(SIZE):
            v = row[x]
            if v == 0:
                continue
            L.append("            10'd%-4d: O_pix = 16'h%04X;" % (y * SIZE + x, v))
    L.append("            default: O_pix = 16'h0000;")
    L.append("        endcase")
    L.append("    end")
    L.append("")
    L.append("endmodule")
    L.append("")

    with open(out_path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(L))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True, help="源图片（白底 PNG/JPG）")
    ap.add_argument("--out", required=True, help="输出 .v 文件")
    ap.add_argument("--alpha-thresh", type=float, default=0.45,
                    help="alpha 二值化阈值（越小越粗，越大越细）")
    ap.add_argument("--sharpen", type=float, default=0.55, help="alpha 反锐化强度")
    ap.add_argument("--preview", default=None, help="输出 8x 预览 PNG 并打印 ASCII")
    args = ap.parse_args()

    rgba = load_rgba(args.src)
    rgba = crop_content(rgba)

    h, w = rgba.shape[:2]
    scale = min(SIZE / float(w), SIZE / float(h))
    nw = max(1, int(round(w * scale)))
    nh = max(1, int(round(h * scale)))
    print("source %dx%d -> %dx%d (fit %dx%d)" % (w, h, nw, nh, SIZE, SIZE))

    small = resize_premul(rgba, nw, nh)
    small = sharpen_alpha(small, args.sharpen)
    pix = quantize(small, args.alpha_thresh)
    pix = despeckle(pix)
    canvas = make_canvas(pix)

    emit_verilog(canvas, args.out, os.path.basename(args.src))
    print("wrote %s" % args.out)

    if args.preview:
        preview(canvas, args.preview)
        print("wrote %s" % args.preview)


if __name__ == "__main__":
    main()
