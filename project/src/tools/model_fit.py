import numpy as np, struct, itertools
from PIL import Image

# --- source (image row 0 = top) ---
d=open('output_bmp/苹果_640x480_24bit_显示正常_工程适配版.bmp','rb').read()
off=struct.unpack_from('<I',d,10)[0]; W=struct.unpack_from('<i',d,18)[0]; H=struct.unpack_from('<i',d,22)[0]
stride=(W*3+3)&~3
a=np.frombuffer(d,np.uint8,count=stride*H,offset=off).reshape(H,stride)[:,:W*3].reshape(H,W,3).astype(np.float32)
src=a[::-1].mean(axis=2)          # image row0 = top

# --- photo, warped to 640x480 ---
p=np.asarray(Image.open('warp_apple.png').convert('L'),dtype=np.float32)

# mask out overlay regions (not from framebuffer)
mask=np.ones((480,640),bool)
mask[0:50, 460:640]=False          # OSD panel
mask[0:40, 0:40]=False             # logo
mask[440:480, :]=False             # subtitle banner

def hp2(img):
    k=15
    ker=np.ones(2*k+1)/(2*k+1)
    out=np.empty_like(img)
    for i in range(img.shape[0]):
        r=img[i]; b=np.convolve(np.r_[r[-k:],r,r[:k]],ker,'same')[k:-k]
        out[i]=r-b
    return out
ph=hp2(p); sh=hp2(src)

def score(disp):
    dh=hp2(disp)
    x=dh[mask]; y=ph[mask]
    x=(x-x.mean())/(x.std()+1e-9); y=(y-y.mean())/(y.std()+1e-9)
    return float((x*y).mean())

PIX=W*H
def build(Sw, vflip=True):
    mem=np.full(PIX+3000, 128.0)
    for r in range(H):
        imgrow = H-1-r                       # BMP bottom-up: stream row r = image row H-1-r
        base = (H-1)*W - Sw*r if vflip else Sw*r
        for c in range(W):
            idx = base + c
            if 0 <= idx < mem.size: mem[idx]=src[imgrow,c]
    return mem

cands=[]
for Sw in (640,639,641):
    for vf in (True,False):
        mem=build(Sw,vf)
        for Sr in (640,639,641):
            ys=np.arange(H)[:,None]; xs=np.arange(W)[None,:]
            idx=(Sr*ys+xs)
            disp=mem[np.clip(idx,0,mem.size-1)]
            mem2=None
            cands.append((score(disp), Sw, vf, Sr))
cands.sort(reverse=True)
print("score   writeStride  vflip  readStride")
for s,Sw,vf,Sr in cands[:10]:
    print(f"{s:+.3f}      {Sw}       {str(vf):5s}   {Sr}")
