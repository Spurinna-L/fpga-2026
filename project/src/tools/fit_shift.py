import numpy as np, struct
from PIL import Image

SHOT = r"D:\fpga_2026\EG4S20开发板\shots\825d3439368d5e9c98f3e2482cebd30e.jpeg"
quad = np.load('quad_apple.npy')            # TL,TR,BR,BL  in 1400x1050 space
full = Image.open(SHOT).convert('RGB')
sx = full.size[0]/1400.0; sy = full.size[1]/1050.0
TL,TR,BR,BL = [(p[0]*sx, p[1]*sy) for p in quad]
# PIL QUAD order: upper-left, lower-left, lower-right, upper-right
data = [TL[0],TL[1], BL[0],BL[1], BR[0],BR[1], TR[0],TR[1]]
warp = full.transform((640,480), Image.QUAD, data, Image.BICUBIC)
warp.save('warp_apple.png')
w = np.asarray(warp, dtype=np.float32).mean(axis=2)

# source
d=open(r'output_bmp/苹果_640x480_24bit_显示正常_工程适配版.bmp','rb').read()
off=struct.unpack_from('<I',d,10)[0]; W=struct.unpack_from('<i',d,18)[0]; H=struct.unpack_from('<i',d,22)[0]
stride=(W*3+3)&~3; bu=H>0; H=abs(H)
src=np.frombuffer(d,np.uint8,count=stride*H,offset=off).reshape(H,stride)[:,:W*3].reshape(H,W,3).astype(np.float32)
if bu: src=src[::-1]
src=src.mean(axis=2)

def hp(x):
    k=31
    b=np.convolve(np.r_[x[-k:],x,x[:k]], np.ones(2*k+1)/(2*k+1), 'same')[k:-k]
    return x-b
def best_shift(r_disp, r_src):
    # cyclic shift d such that r_disp[x] ~ r_src[(x+d) mod 640]
    a=hp(r_disp); b=hp(r_src)
    a=(a-a.mean())/(a.std()+1e-6); b=(b-b.mean())/(b.std()+1e-6)
    best=(-9,0)
    for d in range(640):
        s=float(np.dot(a, np.roll(b,-d))/640.0)
        if s>best[0]: best=(s,d)
    return best

print(" y   bestShift  score")
for y in range(10,470,20):
    s,d = best_shift(w[y], src[y])
    print(f"{y:4d}   {d:5d}      {s:.3f}")
