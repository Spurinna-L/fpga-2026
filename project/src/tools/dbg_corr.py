import numpy as np, struct
from PIL import Image
d=open('output_bmp/苹果_640x480_24bit_显示正常_工程适配版.bmp','rb').read()
off=struct.unpack_from('<I',d,10)[0]; W=struct.unpack_from('<i',d,18)[0]; H=struct.unpack_from('<i',d,22)[0]
stride=(W*3+3)&~3
a=np.frombuffer(d,np.uint8,count=stride*H,offset=off).reshape(H,stride)[:,:W*3].reshape(H,W,3).astype(np.float32)
src=a[::-1].mean(axis=2)
p=np.asarray(Image.open('warp_apple.png').convert('L'),dtype=np.float32)
print("src", src.shape, src.mean(), src.std())
print("photo", p.shape, p.mean(), p.std())
# per-row zero-lag correlation to see if rows line up at all
def rowcorr(i,j):
    x=src[i]-src[i].mean(); y=p[j]-p[j].mean()
    return float((x*y).mean()/(x.std()*y.std()+1e-9))
for y in (60,120,180,240,300,360,420):
    best=max(((rowcorr(y,j),j) for j in range(max(0,y-6),min(480,y+7))))
    print(f"src row {y}: best photo row {best[1]} corr={best[0]:+.3f}")
