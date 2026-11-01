import numpy as np, struct
from PIL import Image
d=open('output_bmp/苹果_640x480_24bit_显示正常_工程适配版.bmp','rb').read()
off=struct.unpack_from('<I',d,10)[0]; W=struct.unpack_from('<i',d,18)[0]; H=struct.unpack_from('<i',d,22)[0]
stride=(W*3+3)&~3
a=np.frombuffer(d,np.uint8,count=stride*H,offset=off).reshape(H,stride)[:,:W*3].reshape(H,W,3).astype(np.float32)
src=a[::-1].mean(axis=2)
p=np.asarray(Image.open('warp_apple.png').convert('L'),dtype=np.float32)
def nz(r):
    r=r-r.mean(); s=r.std(); return r/(s+1e-9)
def best(r,s):
    b=(-9,0)
    for dd in range(640):
        c=float(np.dot(r,np.roll(s,-dd))/640)
        if c>b[0]: b=(c,dd)
    return b
rows=[]
for y in range(16,464,4):
    if 440<=y: continue
    c,dd=best(nz(p[y,40:600]), nz(src[y,40:600]))
    rows.append((y,dd,c))
good=[r for r in rows if r[2]>0.60]
print("rows with corr>0.6:",len(good),"of",len(rows))
ys=np.array([r[0] for r in good],float); ds=np.array([r[1] for r in good],float)
# unwrap to avoid 640 jumps
un=[ds[0]]
for v in ds[1:]:
    prev=un[-1]
    cand=[v, v-640, v+640]
    un.append(min(cand,key=lambda c:abs(c-prev)))
un=np.array(un)
b,a0=np.polyfit(ys,un,1)
print(f"fit: d(y) = {a0:.1f} + ({b:+.3f})*y   (n={len(ys)})")
resid=un-(a0+b*ys); print(f"residual std={resid.std():.2f} px")
for k in range(0,len(ys),max(1,len(ys)//12)):
    print(f"   y={ys[k]:5.0f}  d={un[k]:8.1f}  corr={good[k][2]:.2f}")
np.save('shift_fit.npy', np.array([a0,b]))
