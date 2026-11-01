import numpy as np, struct
d=open('output_bmp/apple.bmp','rb').read()
off=struct.unpack_from('<I',d,10)[0]; W=struct.unpack_from('<i',d,18)[0]; H=struct.unpack_from('<i',d,22)[0]
stride=(W*3+3)&~3
raw=np.frombuffer(d,np.uint8,count=stride*H,offset=off).reshape(H,stride)[:,:W*3].reshape(H,W,3)
file_rgb=raw[:,::-1].astype(np.int32)    # RGB, row0 = bottom (= stream order)
lines=open('../sim/dump_frame.txt').read().split()
px=np.array([int(v,16) for v in lines],dtype=np.int64)
print("dumped frame pixels:", px.size)
got=np.stack([(px>>16)&255,(px>>8)&255,px&255],axis=1)
# 期望：写进帧缓存的字序 = stream 行序（bottom-up），VFLIP 只是地址翻转，不改数据顺序
exp=file_rgb.reshape(-1,3)
n=min(got.shape[0],exp.shape[0])
eq=(got[:n]==exp[:n]).all(axis=1)
print("pixel-exact match vs source stream:", int(eq.sum()), "/", n)
# 若不等，找第一条不匹配的位置
bad=np.where(~eq)[0]
if bad.size:
    k=int(bad[0]); print("first mismatch at stream pixel", k, "row", k//W, "col", k%W, "got",got[k],"exp",exp[k])
    print("mismatch count per row (first 10 rows):", [int((~eq[r*W:(r+1)*W]).sum()) for r in range(10)])
    print("mismatch count per row (rows 100-110):", [int((~eq[r*W:(r+1)*W]).sum()) for r in range(100,111)])
