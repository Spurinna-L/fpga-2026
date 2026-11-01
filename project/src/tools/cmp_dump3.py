import numpy as np, struct
d=open('output_bmp/apple.bmp','rb').read()
off=struct.unpack_from('<I',d,10)[0]; W=struct.unpack_from('<i',d,18)[0]; H=struct.unpack_from('<i',d,22)[0]
stride=(W*3+3)&~3
raw=np.frombuffer(d,np.uint8,count=stride*H,offset=off).reshape(H,stride)[:,:W*3].reshape(H,W,3)
file_rgb = raw[:,:,::-1].astype(np.int16)
lines=open('../sim/dump_pixels.txt').read().split()
px=np.array([int(v,16) for v in lines],dtype=np.uint32)
got=np.stack([(px>>16)&255,(px>>8)&255,px&255],axis=1).astype(np.int16)
for r in (0,5,20,100,200,300,400):
    g=got[r*W:(r+1)*W]
    s=file_rgb[r]
    best=[]
    for dd in range(-420,20):
        a=g[max(0,-dd):W-max(0,dd)]; b=s[max(0,dd):W-max(0,-dd)]
        if a.shape[0]<100: continue
        best.append((int((a==b).all(axis=1).sum()), dd))
    best.sort(reverse=True)
    print(f"row {r:3d}: top shifts (count,d) = {best[:3]}")
