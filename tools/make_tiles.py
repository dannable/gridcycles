#!/usr/bin/env python3
"""Generate physical tile meshes for TTS: one OBJ per piece type plus a shared texture atlas.

    python3 tools/make_tiles.py [outdir]        (default: assets/models/tiles)
    needs: pip install pillow     (and `lua` on PATH, to read src/config.lua)

Every piece type in Config.tileSupply gets an OBJ (straights, plus left and right of each
soft/hard curve; mirrored meshes are generated, not negative-scaled). Conventions:
  * origin = the piece's ENTRY point on the table, heading +z; right curves bend toward +x
    (same as Geom.tilePath), so place with position = entry, rotationY = entry heading, scale 1.
  * the exit end is a chevron tip that pokes `TIP - GAP` past the exit point; the entry end has
    a matching notch of depth TIP, so consecutive pieces nest with a small gap: the joint
    reads as a V seam, helped by a bevel round the top edge.
  * all faces share ONE material/texture (tiles_atlas.png, greyscale, tinted by the rider
    colour in game): top = white cell, bevel = light grey, sides = mid grey, plus raised
    plates on top showing the gear digit twice (once readable from each side of the
    table) and, on curves, a wave (soft) or bolt (hard) between them.
Collision logic stays on the centreline paths in Geom; these meshes are visual only.

TTS mirrors the x axis of every OBJ it imports (observed with tools/lua/piece_test.lua: curves
bent the wrong way and the digits came out mirrored). So the files are written PRE-FLIPPED
(x negated, triangle winding reversed, normals mirrored); TTS's flip then puts them right.
Set TTS_FLIP_X = False to write the plain, un-flipped meshes (e.g. for other viewers).
"""
import math
import os
import subprocess
import sys

from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

WIDTH = 0.6          # piece width (world units)
HEIGHT = 0.36        # Config.tts.trailHeight
TIP = WIDTH * 0.5    # notch depth (45 degree point)
GAP = 0.03           # the tip stops this short of filling the next piece's notch
BEVEL = 0.035        # top-edge chamfer
ARC_STEPS = 8        # matches Config.arcSegments
PLATE_LIFT = 0.004   # label plate floats this far above the top face
TTS_FLIP_X = True    # write meshes pre-flipped for TTS's import (see docstring)
CELL = 256           # atlas cell size; atlas is 4 x 4 cells


def read_config():
    """Tile geometry and supply from src/config.lua: {gear: {shape: (length|radius, sweep)}}."""
    lua = r'''
dofile("src/config.lua")
for g = Config.gears.min, Config.gears.max do
  local t = Config.tiles[g]
  local row = Config.tileSupply[g] or {}
  if (row.straight or 0) > 0 then print(g, "straight", t.straight, 0) end
  for _, shape in ipairs({ "soft", "hard" }) do
    if (row[shape] or 0) > 0 then print(g, shape, t[shape].radius, t[shape].sweep) end
  end
end'''
    out = subprocess.run(["lua", "-e", lua], cwd=ROOT, check=True, capture_output=True, text=True).stdout
    pieces = []
    for line in out.strip().splitlines():
        g, shape, a, b = line.split()
        pieces.append((int(g), shape, float(a), float(b)))
    return pieces


# ---- atlas -----------------------------------------------------------------------------

# cell index -> (column, row); row 0 is the TOP of the image
CELLS = {"top": 0, "side": 1, "d1": 2, "d2": 3, "d3": 4, "d4": 5, "d5": 6, "soft": 7, "hard": 8, "bevel": 9}


def cell_uv(name, u, v):
    """UV (0..1 inside the cell) -> atlas UV. OBJ v runs bottom-up, images top-down."""
    col, row = CELLS[name] % 4, CELLS[name] // 4
    return ((col + u) / 4.0, 1.0 - (row + (1.0 - v)) / 4.0)


DIGIT_SEGS = {  # seven-segment layout: a top, b top-right, c bottom-right, d bottom, e bottom-left, f top-left, g middle
    1: "bc", 2: "abged", 3: "abgcd", 4: "fgbc", 5: "afgcd",
}


def draw_digit(d, digit, box, ink):
    x0, y0, x1, y1 = box
    w, h, t = x1 - x0, y1 - y0, (x1 - x0) * 0.2
    mid = (y0 + y1) / 2
    seg = {
        "a": (x0 + t * 0.5, y0, x1 - t * 0.5, y0 + t), "d": (x0 + t * 0.5, y1 - t, x1 - t * 0.5, y1),
        "g": (x0 + t * 0.5, mid - t / 2, x1 - t * 0.5, mid + t / 2),
        "f": (x0, y0 + t * 0.5, x0 + t, mid - t * 0.2), "e": (x0, mid + t * 0.2, x0 + t, y1 - t * 0.5),
        "b": (x1 - t, y0 + t * 0.5, x1, mid - t * 0.2), "c": (x1 - t, mid + t * 0.2, x1, y1 - t * 0.5),
    }
    for s in DIGIT_SEGS[digit]:
        d.rounded_rectangle(seg[s], radius=t * 0.45, fill=ink)


def build_atlas(path):
    S = 4  # supersample
    img = Image.new("L", (CELL * 4 * S, CELL * 4 * S), 255)
    d = ImageDraw.Draw(img)
    ink, plate = 18, 255

    def cell_box(name):
        col, row = CELLS[name] % 4, CELLS[name] // 4
        return (col * CELL * S, row * CELL * S, (col + 1) * CELL * S, (row + 1) * CELL * S)

    d.rectangle(cell_box("side"), fill=110)                       # sides: mid grey
    d.rectangle(cell_box("bevel"), fill=185)                      # bevel: light grey
    for g in range(1, 6):
        x0, y0, x1, y1 = cell_box("d%d" % g)
        d.rectangle((x0, y0, x1, y1), fill=plate)
        m = CELL * S * 0.2
        draw_digit(d, g, (x0 + m * 1.25, y0 + m, x1 - m * 1.25, y1 - m), ink)
    x0, y0, x1, y1 = cell_box("soft")                             # soft curve: a wave
    d.rectangle((x0, y0, x1, y1), fill=plate)
    pts = []
    for i in range(41):
        t = i / 40.0
        pts.append((x0 + CELL * S * (0.16 + 0.68 * t), y0 + CELL * S * (0.5 - 0.2 * math.sin(t * 2 * math.pi))))
    d.line(pts, fill=ink, width=int(CELL * S * 0.1), joint="curve")
    x0, y0, x1, y1 = cell_box("hard")                             # hard curve: a bolt
    d.rectangle((x0, y0, x1, y1), fill=plate)
    cx, cy, s = (x0 + x1) / 2, (y0 + y1) / 2, CELL * S
    d.polygon([(cx + 0.10 * s, cy - 0.38 * s), (cx - 0.22 * s, cy + 0.05 * s), (cx - 0.02 * s, cy + 0.05 * s),
               (cx - 0.12 * s, cy + 0.38 * s), (cx + 0.24 * s, cy - 0.08 * s), (cx + 0.03 * s, cy - 0.08 * s)], fill=ink)
    img = img.resize((CELL * 4, CELL * 4), Image.LANCZOS)
    img.save(path)


# ---- geometry --------------------------------------------------------------------------

def centreline(shape, a, b, direction):
    """Points (x, z) and unit tangents along the piece, entry first. a = length or radius, b = sweep."""
    if shape == "straight":
        pts = [(0.0, 0.0), (0.0, a)]
        tans = [(0.0, 1.0), (0.0, 1.0)]
    else:
        pts, tans = [], []
        for i in range(ARC_STEPS + 1):
            ph = math.radians(b) * i / ARC_STEPS
            pts.append((a * (1 - math.cos(ph)), a * math.sin(ph)))
            tans.append((math.sin(ph), math.cos(ph)))
    if direction == "left":
        pts = [(-x, z) for x, z in pts]
        tans = [(-x, z) for x, z in tans]
    return pts, tans


def ccw(poly):
    area = sum(poly[i][0] * poly[(i + 1) % len(poly)][1] - poly[(i + 1) % len(poly)][0] * poly[i][1]
               for i in range(len(poly)))
    return area > 0


def footprint(pts, tans, w, tip_len, notch_len, tip_back, notch_fwd, tip_corner, notch_corner):
    """Polygon (right side forward, tip, left side back, notch) of half-width w. The tip
    apex sits tip_len past the exit; the notch apex notch_len past the entry. The end
    corners are moved along the tangent by tip_corner / notch_corner (used for insets)."""
    n = len(pts)
    right, left = [], []
    for i, (p, t) in enumerate(zip(pts, tans)):
        along = 0.0
        if i == n - 1:
            along = tip_corner
        if i == 0:
            along = notch_corner
        px, pz = p[0] + t[0] * along, p[1] + t[1] * along
        right.append((px + t[1] * w, pz - t[0] * w))
        left.append((px - t[1] * w, pz + t[0] * w))
    tip = (pts[-1][0] + tans[-1][0] * tip_len, pts[-1][1] + tans[-1][1] * tip_len)
    notch = (pts[0][0] + tans[0][0] * notch_len, pts[0][1] + tans[0][1] * notch_len)
    return list(right) + [tip] + list(reversed(left)) + [notch]


def outer_and_inset(pts, tans):
    w = WIDTH / 2
    tip_t = TIP - GAP                       # the tip is a little shorter than the notch
    outer = footprint(pts, tans, w, tip_t, TIP, 0, 0, 0.0, 0.0)
    # inset by BEVEL: side lines move in; chevron lines move in by BEVEL along their normals
    Lt, Ln = math.hypot(w, tip_t), math.hypot(w, TIP)
    wi = w - BEVEL
    tip_apex = tip_t - BEVEL * Lt / w
    tip_corner = BEVEL * (tip_t - Lt) / w
    notch_apex = TIP + BEVEL * Ln / w
    notch_corner = BEVEL * (Ln + TIP) / w
    inset = footprint(pts, tans, wi, tip_apex, notch_apex, 0, 0, tip_corner, notch_corner)
    if not ccw(outer):
        outer, inset = list(reversed(outer)), list(reversed(inset))
    return outer, inset


def triangulate(poly):
    """Ear clipping for a simple polygon with positive area (x right, z up). Returns index triples."""
    idx = list(range(len(poly)))

    def cross(o, a, b):
        return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])

    def inside(p, a, b, c):
        return cross(a, b, p) >= -1e-12 and cross(b, c, p) >= -1e-12 and cross(c, a, p) >= -1e-12

    tris = []
    guard = 0
    while len(idx) > 3 and guard < 10000:
        guard += 1
        for k in range(len(idx)):
            i0, i1, i2 = idx[k - 1], idx[k], idx[(k + 1) % len(idx)]
            a, b, c = poly[i0], poly[i1], poly[i2]
            if cross(a, b, c) <= 1e-12:
                continue
            if any(inside(poly[j], a, b, c) for j in idx if j not in (i0, i1, i2)):
                continue
            tris.append((i0, i1, i2))
            idx.pop(k)
            break
        else:
            raise RuntimeError("triangulation failed")
    tris.append((idx[0], idx[1], idx[2]))
    return tris


class Mesh:
    def __init__(self):
        self.v, self.vt, self.vn, self.f = [], [], [], []

    def add(self, pos, uv, n):
        self.v.append(pos)
        self.vt.append(uv)
        self.vn.append(n)
        return len(self.v)

    def tri(self, a, b, c):
        self.f.append((a, b, c))

    def write(self, path, header):
        with open(path, "w", newline="\n") as fh:
            fh.write("# %s\n" % header)
            sx = -1.0 if TTS_FLIP_X else 1.0
            for p in self.v:
                fh.write("v %.5f %.5f %.5f\n" % (p[0] * sx, p[1], p[2]))
            for t in self.vt:
                fh.write("vt %.5f %.5f\n" % t)
            for n in self.vn:
                fh.write("vn %.5f %.5f %.5f\n" % (n[0] * sx, n[1], n[2]))
            for a, b, c in self.f:
                if TTS_FLIP_X:
                    b, c = c, b                      # mirroring reverses the winding
                fh.write("f %d/%d/%d %d/%d/%d %d/%d/%d\n" % (a, a, a, b, b, b, c, c, c))


def plate(m, cell, cx, cz, up, fwd, size):
    """A raised square on the top face. `fwd` is the cell's +u direction, `up` its +v direction
    (unit vectors in (x, z)); the glyph reads along `fwd` with its top towards `up`."""
    h = size / 2
    ids = []
    for su, sv, u, v in ((-h, -h, 0, 0), (h, -h, 1, 0), (h, h, 1, 1), (-h, h, 0, 1)):
        x = cx + fwd[0] * su + up[0] * sv
        z = cz + fwd[1] * su + up[1] * sv
        ids.append(m.add((x, HEIGHT + PLATE_LIFT, z), cell_uv(cell, u, v), (0, 1, 0)))
    m.tri(ids[0], ids[2], ids[1])
    m.tri(ids[0], ids[3], ids[2])


def build_piece(gear, shape, a, b, direction):
    pts, tans = centreline(shape, a, b, direction)
    outer, inset = outer_and_inset(pts, tans)
    m = Mesh()
    top_uv, side_uv, bevel_uv = cell_uv("top", 0.5, 0.5), cell_uv("side", 0.5, 0.5), cell_uv("bevel", 0.5, 0.5)
    n = len(outer)
    ytop, ybev = HEIGHT, HEIGHT - BEVEL
    top = [m.add((x, ytop, z), top_uv, (0, 1, 0)) for x, z in inset]
    bot = [m.add((x, 0.0, z), side_uv, (0, -1, 0)) for x, z in outer]
    for i0, i1, i2 in triangulate(inset):
        m.tri(top[i0], top[i2], top[i1])          # CCW in (x, z) -> wound to face up
    for i0, i1, i2 in triangulate(outer):
        m.tri(bot[i0], bot[i1], bot[i2])
    for i in range(n):
        j = (i + 1) % n
        p, q = outer[i], outer[j]
        dx, dz = q[0] - p[0], q[1] - p[1]
        ln = math.hypot(dx, dz)
        nx, nz = dz / ln, -dx / ln                # outward normal for a CCW (x, z) polygon
        # vertical wall up to the bevel start
        w0 = m.add((p[0], 0.0, p[1]), side_uv, (nx, 0, nz))
        w1 = m.add((q[0], 0.0, q[1]), side_uv, (nx, 0, nz))
        w2 = m.add((q[0], ybev, q[1]), side_uv, (nx, 0, nz))
        w3 = m.add((p[0], ybev, p[1]), side_uv, (nx, 0, nz))
        m.tri(w0, w2, w1)
        m.tri(w0, w3, w2)
        # chamfer from the outline (at ybev) to the inset (at ytop)
        ip, iq = inset[i], inset[j]
        s = math.sqrt(0.5)
        c0 = m.add((p[0], ybev, p[1]), bevel_uv, (nx * s, s, nz * s))
        c1 = m.add((q[0], ybev, q[1]), bevel_uv, (nx * s, s, nz * s))
        c2 = m.add((iq[0], ytop, iq[1]), bevel_uv, (nx * s, s, nz * s))
        c3 = m.add((ip[0], ytop, ip[1]), bevel_uv, (nx * s, s, nz * s))
        m.tri(c0, c2, c1)
        m.tri(c0, c3, c2)
    # label plates: the digit twice (each readable from one side of the table), icon between
    def at(frac):
        if shape == "straight":
            return ((pts[0][0] + pts[1][0]) * 0.0 + 0.0, pts[1][1] * frac, 0.0, 1.0)
        k = min(len(pts) - 1, max(0, int(round(frac * (len(pts) - 1)))))
        return (pts[k][0], pts[k][1], tans[k][0], tans[k][1])

    digit = 0.34 if shape != "straight" else 0.4
    fr = (0.3, 0.7) if shape != "straight" else (0.33, 0.67)
    x, z, tx, tz = at(fr[0])
    left = (-tz, tx)
    plate(m, "d%d" % gear, x, z, left, (tx, tz), digit)                       # reads along travel
    x, z, tx, tz = at(fr[1])
    plate(m, "d%d" % gear, x, z, (tz, -tx), (-tx, -tz), digit)                # reads the other way
    if shape != "straight":
        x, z, tx, tz = at(0.5)
        plate(m, shape, x, z, (-tz, tx), (tx, tz), 0.26)
    return m


def piece_name(gear, shape, direction):
    return "tile_g%d_%s" % (gear, shape if shape == "straight" else "%s_%s" % (shape, direction))


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "assets", "models", "tiles")
    os.makedirs(out, exist_ok=True)
    build_atlas(os.path.join(out, "tiles_atlas.png"))
    count = 0
    for gear, shape, a, b in read_config():
        for direction in (["straight"] if shape == "straight" else ["left", "right"]):
            m = build_piece(gear, shape, a, b, "right" if direction == "straight" else direction)
            name = piece_name(gear, shape, direction)
            m.write(os.path.join(out, name + ".obj"), "Gridcycles piece %s (tools/make_tiles.py)" % name)
            count += 1
            print("%-26s %4d verts %4d tris" % (name, len(m.v), len(m.f)))
    print("wrote %d meshes + tiles_atlas.png to %s" % (count, out))


if __name__ == "__main__":
    main()
