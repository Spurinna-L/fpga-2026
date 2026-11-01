import numpy as np, struct
d=open('output_bmp/apple.bmp','rb').read()
off=struct.unpack_from('<I',d,10)[0]; W=struct.unpack_from('<i',d,18)[0]; H=struct.unpack_from('<i',d,22)[0]
stride=(W*3+3)&~3
raw=np.frombuffer(d,np.uint8,count=stride*H,offset=off).reshape(H,stride)[:,:W*3].reshape(H,W,3)
file_rgb=raw[:,::-1].astype(np.int32)
lines=open('../sim/dump_frame.txt').read().split()
px=np.array([int(v,16) for v in lines],dtype=np.int64)
got=np.stack([(px>>16)&255,(px>>8)&255,px&255],axis=1)
exp=file_rgb.reshape(-1,3)
diff=got.astype(int)-exp.astype(int)
print("diff stats: min",diff.min(0),"max",diff.max(0),"mean",diff.mean(0).round(2))
print("abs diff histogram:", {int(v):int((np.abs(diff).max(axis=1)==v).sum()) for v in range(0,5)})
r=100
print("\nrow 100, first 12 px  got / exp:")
for x in range(12): print("   x=%3d  got=%s exp=%s"%(x,got[r*W+x],exp[r*W+x]))
print("\nrow 100, px 300..311:")
for x in range(300,312): print("   x=%3d  got=%s exp=%s"%(x,got[r*W+x],exp[r*W+x]))
