import struct, os, numpy as np
def load(path):
    d=open(path,'rb').read()
    off=struct.unpack_from('<I',d,10)[0]; w=struct.unpack_from('<i',d,18)[0]
    h=struct.unpack_from('<i',d,22)[0]; stride=(w*3+3)&~3; bu=h>0; h=abs(h)
    a=np.frombuffer(d,np.uint8,count=stride*h,offset=off).reshape(h,stride)[:,:w*3].reshape(h,w,3).astype(np.float32)
    if bu: a=a[::-1]
    return a,w,h

for p in sorted(os.listdir('output_bmp')):
    if not p.lower().endswith('.bmp'): continue
    a,w,h=load('output_bmp/'+p)
    lum=a.mean(2)
    # median best vertical-lag shift between adjacent rows
    best=[]
    for y in range(0,h-1, max(1,h//60)):
        r0=lum[y]; r1=lum[y+1]
        scores=[]
        for d in range(-4,5):
            if d>=0: s=np.corrcoef(r0[:w-4], r1[d:w-4+d])[0,1]
            else:    s=np.corrcoef(r0[-d:w-4], r1[0:w-4+d])[0,1]
            scores.append((s,d))
        scores.sort(reverse=True)
        best.append(scores[0][1])
    vals,counts=np.unique(best,return_counts=True)
    print(f"{p}: {w}x{h}  median-lag={int(np.median(best))}  hist={dict(zip(vals.tolist(),counts.tolist()))}")
