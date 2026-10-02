#!/usr/bin/env python3
"""Rewrite an OBJ so every vertex corner has one shared v/vt/vn index (v//vt//vn all equal)
and drop o/s/g/mtllib/usemtl lines: the plain layout TTS's own exports use.
Idempotent. Usage: python3 tools/unify_obj.py assets/models/bike.obj"""
import sys

path = sys.argv[1]
v, vt, vn, faces = [], [], [], []
for line in open(path, encoding="utf-8"):
    p = line.split()
    if not p:
        continue
    if p[0] == "v": v.append(" ".join(p[1:4]))
    elif p[0] == "vt": vt.append(" ".join(p[1:3]))
    elif p[0] == "vn": vn.append(" ".join(p[1:4]))
    elif p[0] == "f":
        faces.append([tuple(int(x) if x else 0 for x in (c.split("/") + ["", ""])[:3]) for c in p[1:]])

ids, out_v, out_vt, out_vn, out_f = {}, [], [], [], []
for face in faces:
    idx = []
    for c in face:
        if c not in ids:
            ids[c] = len(out_v) + 1
            out_v.append(v[c[0] - 1])
            out_vt.append(vt[c[1] - 1] if c[1] else "0 0")
            out_vn.append(vn[c[2] - 1] if c[2] else "0 1 0")
        idx.append(ids[c])
    for i in range(1, len(idx) - 1):  # fan-triangulate
        out_f.append((idx[0], idx[i], idx[i + 1]))

with open(path, "w", encoding="utf-8", newline="\n") as f:
    f.write("# Gridcycles bike (unified indices, see tools/unify_obj.py)\n")
    f.write("".join("v %s\n" % x for x in out_v))
    f.write("".join("vt %s\n" % x for x in out_vt))
    f.write("".join("vn %s\n" % x for x in out_vn))
    f.write("".join("f %d/%d/%d %d/%d/%d %d/%d/%d\n" % (a, a, a, b, b, b, c, c, c) for a, b, c in out_f))
print("%d verts, %d tris" % (len(out_v), len(out_f)))
