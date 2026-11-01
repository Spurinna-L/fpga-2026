#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
pre_scale_640.py — 把任意尺寸 BMP 预缩放成 640x480（保持比例 + 黑边，双线性）

用途：M2 版 RTL 只接受 640x480 源图；本工具在打包前把图片缩好，
      板上就能用"已验证正确"的 M2 通路显示任意尺寸素材。

几何与 RTL 的 bmp_scale 完全一致：
    DW/DH = min(640/W, 480/H)；OX/OY 居中；黑边填充。
"""
import struct, sys, os
import numpy as np

DST_W, DST_H = 640, 480


def load_bmp(path):
    d = open(path, 'rb').read()
    if d[:2] != b'BM':
        raise ValueError('not BMP: ' + path)
    off = struct.unpack_from('<I', d, 10)[0]
    w = struct.unpack_from('<i', d, 18)[0]
    h = struct.unpack_from('<i', d, 22)[0]
    bpp = struct.unpack_from('<H', d, 28)[0]
    comp = struct.unpack_from('<I', d, 30)[0]
    if bpp != 24 or comp != 0:
        raise ValueError('need 24bit uncompressed: ' + path)
    stride = (w * 3 + 3) & ~3
    bottom_up = h > 0
    h = abs(h)
    a = np.frombuffer(d, np.uint8, count=stride * h, offset=off)
    a = a.reshape(h, stride)[:, :w * 3].reshape(h, w, 3).astype(np.float32)
    if bottom_up:
        a = a[::-1]                      # row0 = top
    return a, w, h


def save_bmp(path, img):
    """img: (480,640,3) float32, row0 = top -> 写 24bit bottom-up BMP"""
    h, w = img.shape[:2]
    stride = (w * 3 + 3) & ~3
    pad = stride - w * 3
    hdr = bytearray(54)
    hdr[0:2] = b'BM'
    struct.pack_into('<I', hdr, 2, 54 + stride * h)
    struct.pack_into('<I', hdr, 10, 54)
    struct.pack_into('<I', hdr, 14, 40)
    struct.pack_into('<i', hdr, 18, w)
    struct.pack_into('<i', hdr, 22, h)      # positive -> bottom-up
    struct.pack_into('<H', hdr, 26, 1)
    struct.pack_into('<H', hdr, 28, 24)
    struct.pack_into('<I', hdr, 34, stride * h)
    data = img[::-1].astype(np.uint8).tobytes()       # bottom-up
    if pad:
        rows = [data[i * w * 3:(i + 1) * w * 3] + b'\x00' * pad for i in range(h)]
        data = b''.join(rows)
    open(path, 'wb').write(bytes(hdr) + data)


def scale_to_640(src, w, h):
    """双线性缩放到 640x480，保持比例、居中黑边（与 RTL bmp_scale 一致）"""
    s = min(DST_W / w, DST_H / h)
    dw = max(1, int(w * s))
    dh = max(1, int(h * s))
    ox = (DST_W - dw) // 2
    oy = (DST_H - dh) // 2
    out = np.zeros((DST_H, DST_W, 3), np.float32)
    # 采样坐标（与 RTL 一致：跨度 (W-1)/(DW-1)）
    if dw > 1:
        sx = np.arange(dw) * ((w - 1) / (dw - 1))
    else:
        sx = np.zeros(dw)
    if dh > 1:
        sy = np.arange(dh) * ((h - 1) / (dh - 1))
    else:
        sy = np.zeros(dh)
    x0 = np.floor(sx).astype(int); fx = (sx - x0)[None, :, None]
    y0 = np.floor(sy).astype(int); fy = (sy - y0)[:, None, None]
    x1 = np.minimum(x0 + 1, w - 1); y1 = np.minimum(y0 + 1, h - 1)
    x0 = np.minimum(x0, w - 1);     y0 = np.minimum(y0, h - 1)
    p00 = src[y0][:, x0]
    p01 = src[y0][:, x1]
    p10 = src[y1][:, x0]
    p11 = src[y1][:, x1]
    top = p00 + (p01 - p00) * fx
    bot = p10 + (p11 - p10) * fx
    img = top + (bot - top) * fy
    out[oy:oy + dh, ox:ox + dw] = np.clip(img + 0.5, 0, 255)
    return out, dw, dh, ox, oy


def main():
    if len(sys.argv) < 3:
        print('usage: pre_scale_640.py OUT_DIR SRC1.bmp [SRC2.bmp ...]')
        sys.exit(1)
    out_dir = sys.argv[1]
    os.makedirs(out_dir, exist_ok=True)
    for i, p in enumerate(sys.argv[2:]):
        a, w, h = load_bmp(p)
        img, dw, dh, ox, oy = scale_to_640(a, w, h)
        name = '%02d_%dx%d_to_640x480.bmp' % (i, w, h)
        save_bmp(os.path.join(out_dir, name), img)
        print('%-40s %4dx%-4d -> content %dx%d at (%d,%d)  -> %s'
              % (os.path.basename(p), w, h, dw, dh, ox, oy, name))


if __name__ == '__main__':
    main()
