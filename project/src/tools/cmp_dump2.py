import numpy as np, struct
d=open('output_bmp/apple.bmp','rb').read()
off=struct.unpack_from('<I',d,10)[0]; W=struct.unpack_from('<i',d,18)[0]; H=struct.unpack_from('<i',d,22)[0]
stride=(W*3+3)&~3
raw=np.frombuffer(d,np.uint8,count=stride*H,offset=off).reshape(H,stride)[:,:W*3].reshape(H,W,3)
file_rgb = raw[:,:,::-1].astype(np.int16)     # row0 = bottom
lines=open('../sim/dump_pixels.txt').read().split()
px=np.array([int(v,16) for v in lines],dtype=np.uint32)
got=np.stack([(px>>16)&255,(px>>8)&255,px&255],axis=1).astype(np.int16)
print("dumped",got.shape[0])

def rowof(idx): return got[idx*W:(idx+1)*W]
print("\n exact-match count per candidate shift (d: got[x]==file[x+d])")
for r in (0,1,2,100,200,300,400,478):
    g=rowof(r)
    row=[]
    for dd in range(-6,7):
        s=file_rgb[r]
        a=g[max(0,-dd):W-max(0,dd)]; b=s[max(0,dd):W-max(0,-dd)]
        row.append((dd,int((a==b).all(axis=1).sum())))
    row.sort(key=lambda t:-t[1])
    print(f" row {r:3d}: best {row[0]}  next {row[1]}  (of 640)")
