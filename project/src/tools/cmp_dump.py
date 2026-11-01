import numpy as np, struct
d=open('output_bmp/apple.bmp','rb').read()
off=struct.unpack_from('<I',d,10)[0]; W=struct.unpack_from('<i',d,18)[0]; H=struct.unpack_from('<i',d,22)[0]
stride=(W*3+3)&~3
raw=np.frombuffer(d,np.uint8,count=stride*H,offset=off).reshape(H,stride)[:,:W*3].reshape(H,W,3)
file_rgb = raw[:,:,::-1].reshape(H,W,3)          # BGR -> RGB, row0 = bottom
lines=open('../sim/dump_pixels.txt').read().split()
px=np.array([int(v,16) for v in lines],dtype=np.uint32)
print("dumped pixels:", px.size, "expected:", W*H)
got=np.stack([(px>>16)&255,(px>>8)&255,px&255],axis=1).astype(np.int16)
n=min(got.shape[0], W*H)
rows = n//W
print("full rows:", rows)
bad=0
shifts=[]
for r in range(rows):
    g=got[r*W:(r+1)*W].mean(axis=1)
    s=file_rgb[r].mean(axis=1)
    # find best shift d: g[x] == s[x+d]
    best=(-1e9,0)
    for dd in range(-4,5):
        a=g[max(0,-dd):W-max(0,dd)]
        b=s[max(0,dd):W-max(0,-dd)]
        c=float(np.corrcoef(a,b)[0,1]) if a.size>10 else -9
        if c>best[0]: best=(c,dd)
    shifts.append(best[1])
    if best[1]!=0: bad+=1
sh=int(np.median(shifts))
print("rows with nonzero best shift:", bad, "of", rows, "median shift:", sh)
hist={}
for s_ in shifts: hist[s_]=hist.get(s_,0)+1
print("shift histogram:", dict(sorted(hist.items())))
# check shift vs row index trend
import statistics
first=[shifts[i] for i in range(0,min(rows,480),40)]
print("shift by row (every 40):", first)
