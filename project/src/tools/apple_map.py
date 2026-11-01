import struct, numpy as np
p='output_bmp/苹果_640x480_24bit_显示正常_工程适配版.bmp'
d=open(p,'rb').read()
off=struct.unpack_from('<I',d,10)[0]; w=struct.unpack_from('<i',d,18)[0]; h=struct.unpack_from('<i',d,22)[0]
stride=(w*3+3)&~3; bu=h>0; h=abs(h)
a=np.frombuffer(d,np.uint8,count=stride*h,offset=off).reshape(h,stride)[:,:w*3].reshape(h,w,3).astype(np.int16)
if bu: a=a[::-1]
B,G,R=a[:,:,0],a[:,:,1],a[:,:,2]
red=(R>140)&(G<110)&(B<110)
green=(G>110)&(R<150)
ys,xs=np.where(red); print("red bbox: x",xs.min(),xs.max()," y",ys.min(),ys.max()," count",int(red.sum()))
ys2,xs2=np.where(green); print("green bbox: x",xs2.min(),xs2.max()," y",ys2.min(),ys2.max()," count",int(green.sum()))
H,W=32,64
ch=[]
for j in range(H):
    row=''
    for i in range(W):
        y0=j*h//H; y1=max(y0+1,(j+1)*h//H); x0=i*w//W; x1=max(x0+1,(i+1)*w//W)
        rr=red[y0:y1,x0:x1].mean(); gg=green[y0:y1,x0:x1].mean(); lum=a[y0:y1,x0:x1].mean()
        row += '#' if rr>0.5 else ('o' if rr>0.15 else ('L' if gg>0.5 else ('g' if gg>0.15 else (' ' if lum>200 else ('.' if lum>110 else '*')))))
    ch.append(row)
print('\n'.join(ch))
