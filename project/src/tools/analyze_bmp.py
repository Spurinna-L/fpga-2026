import struct, os, numpy as np

def load_bmp(path):
    d = open(path,'rb').read()
    off = struct.unpack_from('<I', d, 10)[0]
    w   = struct.unpack_from('<i', d, 18)[0]
    h   = struct.unpack_from('<i', d, 22)[0]
    bpp = struct.unpack_from('<H', d, 28)[0]
    comp= struct.unpack_from('<I', d, 30)[0]
    stride = (w*3+3)&~3
    bottom_up = h>0; h=abs(h)
    a = np.frombuffer(d, dtype=np.uint8, count=stride*h, offset=off).reshape(h, stride)
    a = a[:, :w*3].reshape(h, w, 3).astype(np.float32)
    if bottom_up: a = a[::-1]
    return a,w,h,bpp,comp,stride

for p in sorted(os.listdir('output_bmp')):
    if not p.lower().endswith('.bmp'): continue
    a,w,h,bpp,comp,stride = load_bmp('output_bmp/'+p)
    lum = a.mean(axis=2)
    gw = w-1
    g = np.abs(np.diff(lum, axis=1))
    ys = np.arange(h)
    res=[]
    for s in np.arange(-1.0, 1.001, 0.05):
        coords = (np.arange(gw)[None,:] + np.round(s*ys)[:,None]).astype(int) % gw
        acc = np.take_along_axis(g, coords, axis=1).mean(axis=0)
        x0 = int(acc.argmax()); res.append((acc[x0]/(g.mean()+1e-6), s, x0))
    res.sort(reverse=True)
    print(f"{p}: {w}x{h} pad={stride-w*3}")
    print("   line-detector top3 (score, slope, x0):", [(round(r[0],2), round(r[1],2), r[2]) for r in res[:3]])
    print("   mean |grad| =", round(float(g.mean()),2), " p99 =", round(float(np.percentile(g,99)),2))
