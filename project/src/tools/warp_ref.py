import numpy as np
from PIL import Image
p=np.asarray(Image.open('warp_apple.png').convert('L'),dtype=np.float32)
print("warp", p.shape)
# OSD panel: dark rect around x 470..640, y 5..45. find left edge per row via gradient
gx=np.abs(np.diff(p,axis=1))
print("\n--- OSD panel left edge per row (search x 430..520) ---")
for y in range(6,46,4):
    seg=gx[y,430:540]
    x=430+int(seg.argmax())
    print(f"  y={y:2d}  left edge x={x}  grad={seg.max():.0f}")
print("\n--- OSD panel bottom edge per column (search y 30..60) ---")
gy=np.abs(np.diff(p,axis=0))
for x in range(490,640,20):
    seg=gy[28:62,x]
    y=28+int(seg.argmax())
    print(f"  x={x}  bottom edge y={y}  grad={seg.max():.0f}")
print("\n--- subtitle banner top edge per column (search y 435..455) ---")
for x in range(40,640,60):
    seg=gy[430:460,x]
    y=430+int(seg.argmax())
    print(f"  x={x}  top edge y={y}  grad={seg.max():.0f}")
print("\n--- logo box edges ---")
for y in range(2,34,6):
    seg=gx[y,0:60]; print(f"  y={y:2d} logo left x={int(seg.argmax())} g={seg.max():.0f}")
