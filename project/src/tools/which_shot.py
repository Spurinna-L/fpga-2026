import numpy as np, glob
from PIL import Image

for f in sorted(glob.glob('*.jpeg')):
    im = Image.open(f).convert('RGB')
    im.thumbnail((700,700))
    a = np.asarray(im, dtype=np.float32)
    R,G,B = a[:,:,0],a[:,:,1],a[:,:,2]
    red  = ((R>120)&(R>G*1.5)&(R>B*1.5)).mean()
    green= ((G>90)&(G>R*1.15)&(G>B*1.15)).mean()
    lum  = a.mean()
    print(f"{f}  red={red:.3f} green={green:.3f} meanlum={lum:.0f}")
