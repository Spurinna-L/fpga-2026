import numpy as np, struct
d=open('output_bmp/apple.bmp','rb').read()
off=struct.unpack_from('<I',d,10)[0]; W=struct.unpack_from('<i',d,18)[0]; H=struct.unpack_from('<i',d,22)[0]
stride=(W*3+3)&~3
raw=np.frombuffer(d,np.uint8,count=stride*H,offset=off).reshape(H,stride)[:,:W*3].reshape(H,W,3)
file_rgb = raw[:,:,::-1].astype(np.int32)      # row0=bottom

ys=[];xs=[];px=[]
for line in open('../sim/dump_pixels.txt'):
    a=line.split()
    if len(a)!=3: continue
    ys.append(int(a[0])); xs.append(int(a[1])); px.append(int(a[2],16))
ys=np.array(ys); xs=np.array(xs); px=np.array(px,dtype=np.int64)
print("total", ys.size, " max y", ys.max())
import collections
cnt=collections.Counter(ys.tolist())
bad=[(y,cnt[y]) for y in range(0,ys.max()+1) if cnt.get(y,0)!=640]
print("rows with !=640 pixels:", bad[:10], "..." if len(bad)>10 else "", "count:", len(bad))
# per-row best offset d  (pixel should equal file_rgb[y][x+d])
res={}
for y in (0,1,2,3,10,50,100,200,300,400,479):
    m=ys==y
    if m.sum()<100: continue
    x=xs[m]; p=px[m]
    best=[]
    for dd in range(-260,40):
        xr=x+dd
        ok=(xr>=0)&(xr<W)
        if ok.sum()<100: continue
        fr=file_rgb[y][np.clip(xr,0,W-1)]
        fv=(fr[:,0]<<16)|(fr[:,1]<<8)|fr[:,2]
        cnt_ok=int((p[ok]==fv[ok]).sum())
        best.append((cnt_ok, dd, int(ok.sum())))
    best.sort(reverse=True)
    print(f"row {y:3d}: best (matches,d,overlap)={best[:2]}")
