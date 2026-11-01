import numpy as np, struct
d=open('output_bmp/apple.bmp','rb').read()
off=struct.unpack_from('<I',d,10)[0]; W=struct.unpack_from('<i',d,18)[0]; H=struct.unpack_from('<i',d,22)[0]
stride=(W*3+3)&~3
raw=np.frombuffer(d,np.uint8,count=stride*H,offset=off).reshape(H,stride)[:,:W*3].reshape(H,W,3)
stream=raw[:,::-1][:,:,::-1].reshape(-1,3).astype(np.int32)   # 行反(底->上) + BGR->RGB
lines=open('../sim/dump_frame.txt').read().split()
px=np.array([int(v,16) for v in lines],dtype=np.int64)
got=np.stack([(px>>16)&255,(px>>8)&255,px&255],axis=1).astype(np.int32)
n=min(got.shape[0],stream.shape[0])
eq=(got[:n]==stream[:n]).all(axis=1)
print("frame pixels:",got.shape[0],"  exact match:",int(eq.sum()),"/",n)
d_=np.abs(got[:n]-stream[:n]).max(axis=1)
print("abs-diff hist:",{int(v):int((d_==v).sum()) for v in range(0,4)})
# 每行最佳整体平移（按行比较）
def best_shift(r):
    g=got[r*W:(r+1)*W]; s=stream[r*W:(r+1)*W]
    res=[]
    for dd in range(-4,5):
        a=g[max(0,-dd):W-max(0,dd)]; b=s[max(0,dd):W-max(0,-dd)]
        res.append((int((a==b).all(axis=1).sum()), dd))
    res.sort(reverse=True); return res[0]
for r in (0,1,2,50,100,200,300,400,479):
    print("row %3d best %s"%(r,best_shift(r)))
