import numpy as np, struct
d=open('output_bmp/apple.bmp','rb').read()
off=struct.unpack_from('<I',d,10)[0]; W=struct.unpack_from('<i',d,18)[0]; H=struct.unpack_from('<i',d,22)[0]
stride=(W*3+3)&~3
raw=np.frombuffer(d,np.uint8,count=stride*H,offset=off).reshape(H,stride)[:,:W*3].reshape(H,W,3)
stream=raw[::-1][:,:,::-1].reshape(-1,3).astype(np.int32)   # 底->上 + BGR->RGB, 展平
lines=open('../sim/dump_frame.txt').read().split()
px=np.array([int(v,16) for v in lines],dtype=np.int64)
got=np.stack([(px>>16)&255,(px>>8)&255,px&255],axis=1).astype(np.int32)
print("frame pixels:",got.shape[0], " stream:",stream.shape[0])
for r in (0,1,2,5,20,100,200,300,400,478,479):
    g=got[r*W:(r+1)*W]; s=stream[r*W:(r+1)*W]
    if g.shape[0]<W: continue
    best=[]
    for dd in range(-500,500):
        a=g[max(0,-dd):W-max(0,dd)]; b=s[max(0,dd):W-max(0,-dd)]
        if a.shape[0]<200: continue
        best.append((int((a==b).all(axis=1).sum()), dd))
    best.sort(reverse=True)
    print("row %3d  top3 (matchcount,shift): %s"%(r,best[:3]))
