import numpy as np, glob
from PIL import Image

def load_small(f, W=1400):
    im = Image.open(f).convert('L')
    w,h = im.size
    H = int(h*W/w)
    im = im.resize((W,H), Image.BILINEAR)
    return np.asarray(im, dtype=np.float32)

for f in sorted(glob.glob('*.jpeg')):
    a = load_small(f)
    H,W = a.shape
    g = np.abs(np.diff(a, axis=1))            # horizontal gradient
    # limit to central region (avoid bezel/desk)
    y0,y1 = int(H*0.12), int(H*0.88)
    x0,x1 = int(W*0.06), int(W*0.94)
    gg = g[y0:y1, x0:x1]
    hh,ww = gg.shape
    ys = np.arange(hh)
    res=[]
    for s in np.arange(-0.60, 0.601, 0.02):     # dx per row (photo px)
        coords = (np.arange(ww)[None,:] + np.round(s*(ys-hh/2))[:,None]).astype(int) % ww
        acc = np.take_along_axis(gg, coords, axis=1).mean(axis=0)
        p = int(acc.argmax())
        res.append((float(acc[p]), float(s), p+x0))
    res.sort(reverse=True)
    print(f"\n=== {f}  ({H}x{W}) mean|grad|={gg.mean():.2f}")
    for v,s,p in res[:6]:
        x_top = p + s*(-hh/2); x_bot = p + s*(hh/2)
        print(f"   score={v:6.2f}  slope={s:+.2f} px/row  x@top={x_top:6.0f} x@bot={x_bot:6.0f}  ({100*x_top/W:.0f}% -> {100*x_bot/W:.0f}%)")
