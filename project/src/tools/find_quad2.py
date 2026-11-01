import numpy as np
from PIL import Image

SHOT = r"D:\fpga_2026\EG4S20开发板\shots\825d3439368d5e9c98f3e2482cebd30e.jpeg"
im = Image.open(SHOT).convert('L'); im.thumbnail((1400,1400))
a = np.asarray(im, dtype=np.float32); H,W = a.shape
gx = np.abs(np.diff(a, axis=1)); gy = np.abs(np.diff(a, axis=0))

def robust_fit(ys, xs, iters=3, tol=3.0):
    ys=np.asarray(ys,float); xs=np.asarray(xs,float)
    m,c = np.polyfit(ys,xs,1)
    for _ in range(iters):
        r = np.abs(xs-(m*ys+c)); k = r < max(tol, 2.5*np.median(r)+1e-6)
        if k.sum()<10: break
        m,c = np.polyfit(ys[k],xs[k],1)
    return m,c,int(k.sum())

# vertical edges (fit x = m*y + c)
def edge_v(xlo,xhi):
    Y=[];X=[]
    for y in range(int(H*0.15), int(H*0.85), 2):
        seg=gx[y,xlo:xhi]
        if seg.size==0: continue
        i=int(seg.argmax())
        if seg[i]>15: Y.append(y); X.append(xlo+i)
    return robust_fit(Y,X)
# horizontal edges (fit y = m*x + c)
def edge_h(ylo,yhi):
    X=[];Y=[]
    for x in range(int(W*0.15), int(W*0.85), 2):
        seg=gy[ylo:yhi,x]
        if seg.size==0: continue
        i=int(seg.argmax())
        if seg[i]>15: X.append(x); Y.append(ylo+i)
    return robust_fit(X,Y)

lm,lc,nl = edge_v(int(W*0.01), int(W*0.17))
rm,rc,nr = edge_v(int(W*0.83), int(W*0.99))
tm,tc,nt = edge_h(int(H*0.05), int(H*0.22))
bm,bc,nb = edge_h(int(H*0.78), int(H*0.97))
print(f"left : x={lm:+.4f} y {lc:7.1f}  n={nl}   -> x@y=0 {lc:.0f}, x@y=H {lm*H+lc:.0f}")
print(f"right: x={rm:+.4f} y {rc:7.1f}  n={nr}   -> x@y=0 {rc:.0f}, x@y=H {rm*H+rc:.0f}")
print(f"top  : y={tm:+.4f} x {tc:7.1f}  n={nt}   -> y@x=0 {tc:.0f}, y@x=W {tm*W+tc:.0f}")
print(f"bot  : y={bm:+.4f} x {bc:7.1f}  n={nb}   -> y@x=0 {bc:.0f}, y@x=W {bm*W+bc:.0f}")

def inter(mv,cv,mh,ch):
    x=(mv*ch+cv)/(1-mv*mh); return x, mh*x+ch
tl=inter(lm,lc,tm,tc); tr=inter(rm,rc,tm,tc); br=inter(rm,rc,bm,bc); bl=inter(lm,lc,bm,bc)
print("quad TL,TR,BR,BL:",[tuple(round(v,1) for v in p) for p in (tl,tr,br,bl)])
np.save('quad_apple.npy', np.array([tl,tr,br,bl]))
