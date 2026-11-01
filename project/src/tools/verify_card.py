import struct, os, glob, hashlib
img = open('output_sd/sd_card.img','rb').read()
print("img size", len(img))
# 扫描 BM 头（与 RTL 的扫描逻辑一致：从 sector 0 起逐扇区找 'BM'）
found=[]
for s in range(0, len(img)//512):
    if img[s*512:s*512+2]==b'BM':
        off=s*512
        if off+34 <= len(img):
            flen=struct.unpack_from('<I',img,off+2)[0]
            w=struct.unpack_from('<i',img,off+18)[0]; h=struct.unpack_from('<i',img,off+22)[0]
            bpp=struct.unpack_from('<H',img,off+28)[0]; comp=struct.unpack_from('<I',img,off+30)[0]
            found.append((s,w,h,bpp,comp,flen))
print("sector-0 BM headers:", len(found))
for f in found[:8]: print("   sector=%d W=%d H=%d bpp=%d comp=%d len=%d" % f)
# 对每个找到的头，和 output_bmp 里的文件做整段比对
files = {}
for p in glob.glob('output_bmp/*.bmp'):
    files[os.path.basename(p)] = open(p,'rb').read()
print("\n--- full byte compare vs output_bmp files ---")
for (s,w,h,bpp,comp,flen) in found[:8]:
    off=s*512
    blob=img[off:off+flen]
    best=None
    for name,data in files.items():
        if data[:len(blob)]==blob: best=name; break
    if best is None:
        # 找长度相同的再比
        for name,data in files.items():
            if len(data)==flen:
                n=sum(1 for a,b in zip(blob,data) if a!=b)
                print(f"   sector {s}: len={flen} vs {name} len={len(data)}  bytes-diff={n}")
                best=f"{name}(diff)"
    else:
        print(f"   sector {s}: EXACT == {best}  ({flen} bytes)")
    if best is None: print(f"   sector {s}: no match, len={flen}")
