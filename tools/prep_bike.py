"""Reorient and normalise the Meshy motorcycle for Tabletop Simulator.

Dev tooling (needs: numpy pillow). Not shipped.
Source: long axis is x, origin at the centre. TTS wants: nose toward +z, y up,
origin at bottom centre, length normalised to 1.0 (scaled in game by
Config.tts.riderModel.scale). UVs are kept as is; the texture is lifted a little
so the dark panels still read under a neon tint.

Usage: py -3.13 tools/prep_bike.py [+1|-1]    (+1: source +x is the nose)
Outputs: assets/models/bike.obj, bike.mtl, bike.png; previews in build/.
"""
import os
import sys
import numpy as np
from PIL import Image

SRC = "assets/source/meshy_motorcycle_v2/Meshy_AI_cyberpunk_motorcycle__1001232453_texture"
S = int(sys.argv[1]) if len(sys.argv) > 1 else 1
GAMMA, FLOOR, SIZE = 0.6, 0.06, 2048   # texture lift and output size

lines = open(SRC + ".obj").read().splitlines()
verts = np.array([[float(t) for t in l.split()[1:4]] for l in lines if l.startswith("v ")])
lo, hi = verts.min(axis=0), verts.max(axis=0)
cx, cz = (lo[0] + hi[0]) / 2, (lo[2] + hi[2]) / 2
length = hi[0] - lo[0]


def tv(p):
    x, y, z = p
    return (-S * (z - cz) / length, (y - lo[1]) / length, S * (x - cx) / length)


def tn(n):
    x, y, z = n
    return (-S * z, y, S * x)


out = ["# Gridcycles bike: reoriented from Meshy source by tools/prep_bike.py", "mtllib bike.mtl"]
for l in lines:
    t = l.split()
    if not t or t[0] in ("mtllib", "#"):
        continue
    if t[0] == "v":
        out.append("v %.5f %.5f %.5f" % tv([float(a) for a in t[1:4]]))
    elif t[0] == "vn":
        out.append("vn %.5f %.5f %.5f" % tn([float(a) for a in t[1:4]]))
    else:
        out.append(l)
os.makedirs("assets/models", exist_ok=True)
with open("assets/models/bike.obj", "w") as f:
    f.write("\n".join(out) + "\n")
with open("assets/models/bike.mtl", "w") as f:
    f.write("newmtl Material\nKd 1 1 1\nmap_Kd bike.png\n")

img = Image.open(SRC + ".png").convert("L")
if img.size[0] != SIZE:
    img = img.resize((SIZE, SIZE), Image.LANCZOS)
a = np.asarray(img, dtype=np.float64) / 255.0
a = FLOOR + (1 - FLOOR) * np.power(a, GAMMA)
Image.fromarray((a * 255).astype(np.uint8), "L").convert("RGB").save("assets/models/bike.png", optimize=True)

# previews: side (z right, y up) and top (z right, x up), points shaded by depth
v = np.array([tv(p) for p in verts])
os.makedirs("build", exist_ok=True)


def preview(path, ha, va, depth):
    n = 700
    im = np.zeros((n, n, 3), np.uint8)
    s = 0.9 * n / max(np.ptp(v[:, ha]), np.ptp(v[:, va]))
    ix = ((v[:, ha] - v[:, ha].min()) * s + 20).astype(int).clip(0, n - 1)
    iy = (n - 21 - (v[:, va] - v[:, va].min()) * s).astype(int).clip(0, n - 1)
    d = v[:, depth]
    d = (d - d.min()) / (np.ptp(d) + 1e-9)
    order = np.argsort(d)
    im[iy[order], ix[order]] = (80 + 175 * d[order, None]).astype(np.uint8)
    Image.fromarray(im).save(path)


preview("build/bike_side.png", 2, 1, 0)
preview("build/bike_top.png", 2, 0, 1)
print("verts", len(v), "extents", np.ptp(v, axis=0), "min", v.min(axis=0))
