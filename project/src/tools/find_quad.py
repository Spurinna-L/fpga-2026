import numpy as np
from PIL import Image

SHOT = r"D:\fpga_2026\EG4S20开发板\shots\825d3439368d5e9c98f3e2482cebd30e.jpeg"
im = Image.open(SHOT).convert('L')
im.thumbnail((1400,1400))
a = np.asarray(im, dtype=np.float32)
H,W = a.shape
print("working res", W, H)
gx = np.abs(np.diff(a, axis=1))     # H x (W-1)
gy = np.abs(np.diff(a, axis=0))     # (H-1) x W

def fit_line(pts):
    ys = np.array([p[0] for p in pts], float); xs = np.array([p[1] for p in pts], float)
    A = np.vstack([ys, np.ones_like(ys)]).T
    m, c = np.linalg.lstsq(A, xs, rcond=None)[0]
    return m, c

# left edge: strongest gradient in a window, per row
def edge_v(xlo, xhi, pick='max'):
    pts=[]
    for y in range(int(H*0.18), int(H*0.82), 4):
        seg = gx[y, xlo:xhi]
        if seg.size==0: continue
        x = xlo + int(seg.argmax())
        if seg.max() > 12: pts.append((y,x))
    return fit_line(pts), len(pts)

(lm,lc),nl = edge_v(int(W*0.01), int(W*0.16))
(rm,rc),nr = edge_v(int(W*0.84), int(W*0.99))
print(f"left  edge: x = {lm:+.4f}*y + {lc:.1f}  (n={nl})")
print(f"right edge: x = {rm:+.4f}*y + {rc:.1f}  (n={nr})")

def edge_h(ylo, yhi):
    pts=[]
    for x in range(int(W*0.20), int(W*0.80), 4):
        seg = gy[ylo:yhi, x]
        if seg.size==0: continue
        y = ylo + int(seg.argmax())
        if seg.max() > 12: pts.append((x,y))
    # fit x as function of y (transpose)
    pts2 = [(p[1],p[0]) for p in pts]
    return fit_line(pts2), len(pts)

(tm,tc),nt = edge_h(int(H*0.05), int(H*0.20))
(bm,bc),nb = edge_h(int(H*0.80), int(H*0.97))
print(f"top   edge: y = {tm:+.4f}*x + {tc:.1f}  (n={nt})")
print(f"bot   edge: y = {bm:+.4f}*x + {bc:.1f}  (n={nb})")

def inter_v_h(mv,cv,mh,ch):
    # x = mv*y+cv ; y = mh*x+ch  -> x = mv*(mh*x+ch)+cv
    x = (mv*ch+cv)/(1-mv*mh)
    y = mh*x+ch
    return x,y
c_tl = inter_v_h(lm,lc,tm,tc); c_tr = inter_v_h(rm,rc,tm,tc)
c_bl = inter_v_h(lm,lc,bm,bc); c_br = inter_v_h(rm,rc,bm,bc)
print("corners TL,TR,BR,BL:", [tuple(round(v,1) for v in c) for c in (c_tl,c_tr,c_br,c_bl)])
np.save('quad.npy', np.array([c_tl,c_tr,c_br,c_bl]))
Image.fromarray(a.astype(np.uint8)).save('shot_gray.png')
