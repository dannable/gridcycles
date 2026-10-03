-- geom.lua
-- Pure 2D geometry on the table plane (x, z). NO TTS API calls in this file:
-- it must run under plain Lua 5.2 so tests/run.lua can exercise it.
--
-- Types:
--   Point   = { x = number, z = number }
--   Pose    = { x = number, z = number, heading = number }  -- heading in degrees, 0 = +z
--   Segment = { a = Point, b = Point }
--   kind    = "straight" | "left" | "right"
--
-- Turn convention: the forward vector for heading h is (sin h, cos h), so
-- heading 0 = +z and heading 90 = +x. A RIGHT turn increases heading
-- (heading 0 bends toward +x); a LEFT turn decreases it (toward -x).

Geom = {}

local RAD = math.pi / 180

local function eps() return Config.epsilon end

local function orient(p, q, r)
  return (q.x - p.x) * (r.z - p.z) - (q.z - p.z) * (r.x - p.x)
end

local function sign(v)
  if v > eps() then return 1 elseif v < -eps() then return -1 end
  return 0
end

local function samePoint(p, q)
  return math.abs(p.x - q.x) <= eps() and math.abs(p.z - q.z) <= eps()
end

-- p is known collinear with segment a-b; is it within the segment's extent?
local function onSegment(a, b, p)
  return p.x >= math.min(a.x, b.x) - eps() and p.x <= math.max(a.x, b.x) + eps()
    and p.z >= math.min(a.z, b.z) - eps() and p.z <= math.max(a.z, b.z) + eps()
end

local function normHeading(h)
  h = h % 360
  return h
end

-- Build the path for one tile. `shape` picks the curve ("soft" default, or "hard");
-- it is ignored for straights.
-- Returns: segments (array of Segment), exitPose (Pose)
function Geom.tilePath(kind, gear, entryPose, shape)
  local t = Config.tiles[gear]
  assert(t, "Geom.tilePath: unknown gear " .. tostring(gear))
  local h = entryPose.heading * RAD
  local p = { x = entryPose.x, z = entryPose.z }

  if kind == "straight" then
    local q = { x = p.x + math.sin(h) * t.straight, z = p.z + math.cos(h) * t.straight }
    return { { a = p, b = q } },
      { x = q.x, z = q.z, heading = normHeading(entryPose.heading) }
  end

  local s
  if kind == "right" then s = 1 elseif kind == "left" then s = -1
  else error("Geom.tilePath: unknown kind " .. tostring(kind)) end

  local def = t[shape or "soft"]
  assert(def, "Geom.tilePath: no " .. tostring(shape or "soft") .. " curve at gear " .. tostring(gear))
  local r, sweep, n = def.radius, def.sweep, Config.arcSegments
  -- circle centre sits 90 degrees to the turning side of the entry heading
  local cx = p.x + r * math.sin(h + s * math.pi / 2)
  local cz = p.z + r * math.cos(h + s * math.pi / 2)
  local segs = {}
  local prev = p
  for i = 1, n do
    local hi = h + s * (sweep * RAD) * i / n
    local q = { x = cx - r * math.sin(hi + s * math.pi / 2), z = cz - r * math.cos(hi + s * math.pi / 2) }
    segs[i] = { a = prev, b = q }
    prev = q
  end
  return segs, { x = prev.x, z = prev.z, heading = normHeading(entryPose.heading + s * sweep) }
end

-- True if segments a and b intersect (touching within epsilon counts).
function Geom.segmentsIntersect(a, b)
  local o1 = sign(orient(a.a, a.b, b.a))
  local o2 = sign(orient(a.a, a.b, b.b))
  local o3 = sign(orient(b.a, b.b, a.a))
  local o4 = sign(orient(b.a, b.b, a.b))
  if o1 ~= o2 and o3 ~= o4 then return true end
  if o1 == 0 and onSegment(a.a, a.b, b.a) then return true end
  if o2 == 0 and onSegment(a.a, a.b, b.b) then return true end
  if o3 == 0 and onSegment(b.a, b.b, a.a) then return true end
  if o4 == 0 and onSegment(b.a, b.b, a.b) then return true end
  return false
end

local function touchesPoint(seg, p)
  return samePoint(seg.a, p) or samePoint(seg.b, p)
end

local function dist(p, q)
  local dx, dz = p.x - q.x, p.z - q.z
  return math.sqrt(dx * dx + dz * dz)
end

-- Distance from point p to segment seg.
function Geom.pointSegDist(p, seg)
  local dx, dz = seg.b.x - seg.a.x, seg.b.z - seg.a.z
  local len2 = dx * dx + dz * dz
  if len2 == 0 then return dist(p, seg.a) end
  local t = ((p.x - seg.a.x) * dx + (p.z - seg.a.z) * dz) / len2
  t = math.max(0, math.min(1, t))
  return dist(p, { x = seg.a.x + t * dx, z = seg.a.z + t * dz })
end

-- Smallest distance between two segments (0 if they touch or cross).
function Geom.segmentDistance(s1, s2)
  if Geom.segmentsIntersect(s1, s2) then return 0 end
  return math.min(
    Geom.pointSegDist(s1.a, s2), Geom.pointSegDist(s1.b, s2),
    Geom.pointSegDist(s2.a, s1), Geom.pointSegDist(s2.b, s1))
end

-- Smallest distance from any of `segs` to segment `seg`.
function Geom.pathDistance(segs, seg)
  local best = math.huge
  for _, s in ipairs(segs) do
    local d = Geom.segmentDistance(s, seg)
    if d < best then best = d end
  end
  return best
end

-- A representative point where intersecting segments a and b touch: the crossing
-- point, or for collinear overlaps / endpoint touches an endpoint lying on the other.
function Geom.contactPoint(a, b)
  local rx, rz = a.b.x - a.a.x, a.b.z - a.a.z
  local sx, sz = b.b.x - b.a.x, b.b.z - b.a.z
  local denom = rx * sz - rz * sx
  if math.abs(denom) > eps() then
    local t = ((b.a.x - a.a.x) * sz - (b.a.z - a.a.z) * sx) / denom
    return { x = a.a.x + t * rx, z = a.a.z + t * rz }
  end
  for _, p in ipairs({ b.a, b.b }) do
    if Geom.pointSegDist(p, a) <= eps() then return { x = p.x, z = p.z } end
  end
  for _, p in ipairs({ a.a, a.b }) do
    if Geom.pointSegDist(p, b) <= eps() then return { x = p.x, z = p.z } end
  end
  return { x = a.a.x, z = a.a.z }
end

-- True if any of newSegs hits any trail segment. Further return values: the trail
-- entry that was hit and the exact old segment.
-- trails: array of { owner = color, segs = {Segment...}, kind = "bike"|nil }
-- ignoreJoint: Point to ignore (the joint with the mover's own previous tile).
-- A new/old segment pair that both end at the joint is skipped.
-- passFn(point) -> true: contact at that point is harmless (e.g. on top of a Prizm).
function Geom.pathHitsTrails(newSegs, trails, ignoreJoint, passFn)
  for _, trail in ipairs(trails) do
    for _, old in ipairs(trail.segs) do
      for _, ns in ipairs(newSegs) do
        if Geom.segmentsIntersect(ns, old) then
          local atJoint = ignoreJoint ~= nil
            and touchesPoint(ns, ignoreJoint) and touchesPoint(old, ignoreJoint)
          if not atJoint and not (passFn and passFn(Geom.contactPoint(ns, old))) then
            return true, trail, old
          end
        end
      end
    end
  end
  return false
end

-- True if the path fully crosses the Prizm's long axis (prizmSeg): the path must
-- pass from one side of the axis to the other, at a point on the Prizm.
-- Touching or ending on the axis does not count. `slack` (default 0) extends the
-- axis at both ends for the "crossing is on the Prizm" test, so a wall that overlaps
-- an end of the Prizm counts (see Config.prizm.endSlack).
-- `band` (default 0): points within this distance of the axis are "on top of" the
-- Prizm, on neither side, so a line that stops there has not crossed yet.
-- `leadIn` (optional): the path laid just before newSegs (ignored unless it ends where
-- newSegs starts).
-- A crossing may start on the lead-in, but must finish on newSegs: this is how a line
-- that stopped on top of a Prizm finishes crossing it with the next tile, without a
-- crossing that already happened counting twice.
function Geom.pathCrossesPrizm(newSegs, prizmSeg, slack, band, leadIn)
  local pa, pb = prizmSeg.a, prizmSeg.b
  local dx, dz = pb.x - pa.x, pb.z - pa.z
  local len = math.sqrt(dx * dx + dz * dz)
  slack, band = slack or 0, band or 0

  -- polyline vertices: lead-in first; `joint` is where newSegs starts
  local pts = {}
  if leadIn and #leadIn > 0 and samePoint(leadIn[#leadIn].b, newSegs[1].a) then
    pts[1] = leadIn[1].a
    for _, s in ipairs(leadIn) do pts[#pts + 1] = s.b end
  else
    pts[1] = newSegs[1].a
  end
  local joint = #pts
  for _, s in ipairs(newSegs) do pts[#pts + 1] = s.b end

  local function side(p)
    local o = orient(pa, pb, p)
    if band > 0 then
      o = o / len
      if o > band then return 1 elseif o < -band then return -1 end
      return 0
    end
    return sign(o)
  end

  -- where the polyline between pts[i0] and pts[i1] meets the axis line
  local function crossing(i0, i1)
    for j = i0, i1 - 1 do
      local p0, p1 = pts[j], pts[j + 1]
      local d0, d1 = orient(pa, pb, p0), orient(pa, pb, p1)
      if d0 == 0 then return p0 end
      if (d0 < 0) ~= (d1 < 0) or d1 == 0 then
        local t = d0 / (d0 - d1)
        return { x = p0.x + (p1.x - p0.x) * t, z = p0.z + (p1.z - p0.z) * t }
      end
    end
    return pts[i1]
  end

  local lastIdx, lastSide = nil, 0
  for i, p in ipairs(pts) do
    local sd = side(p)
    if sd ~= 0 then
      if lastSide ~= 0 and sd ~= lastSide and i > joint then
        local hit = crossing(lastIdx, i)
        -- on the Prizm: the crossing projects within the (slack-extended) axis
        local t = ((hit.x - pa.x) * dx + (hit.z - pa.z) * dz) / (len * len)
        local ext = slack / len
        if t >= -ext - eps() and t <= 1 + ext + eps() then return true end
      end
      lastIdx, lastSide = i, sd
    end
  end
  return false
end

-- True if every point of the path is inside the mat bounds (centred on origin).
function Geom.inBounds(segs, mat)
  local hw, hd = mat.width / 2, mat.depth / 2
  for _, s in ipairs(segs) do
    for _, p in ipairs({ s.a, s.b }) do
      if math.abs(p.x) > hw + eps() or math.abs(p.z) > hd + eps() then return false end
    end
  end
  return true
end

local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end

-- Midpoint, length and heading (degrees, 0 = +z, same convention as Pose) of a
-- segment. Used by TTS glue to lay a thin block along it.
function Geom.segmentPose(seg)
  local dx, dz = seg.b.x - seg.a.x, seg.b.z - seg.a.z
  return {
    x = (seg.a.x + seg.b.x) / 2,
    z = (seg.a.z + seg.b.z) / 2,
    length = math.sqrt(dx * dx + dz * dz),
    heading = (atan2(dx, dz) / RAD) % 360,
  }
end

-- Straight-line distance from a tile's entry to its exit (used to size physical tiles).
function Geom.tileChord(kind, gear, shape)
  local _, exit = Geom.tilePath(kind, gear, { x = 0, z = 0, heading = 0 }, shape)
  return dist({ x = 0, z = 0 }, exit)
end

-- Midpoint between entry and exit of the tile that WOULD be laid from `pose`.
function Geom.tileCenter(kind, gear, pose, shape)
  local _, exit = Geom.tilePath(kind, gear, pose, shape)
  return { x = (pose.x + exit.x) / 2, z = (pose.z + exit.z) / 2 }
end

Geom.distance = dist

-- Pose moved `d` along its heading (negative d moves backwards).
function Geom.advance(pose, d)
  local h = pose.heading * RAD
  return { x = pose.x + math.sin(h) * d, z = pose.z + math.cos(h) * d, heading = pose.heading }
end

-- The bike's footprint: a segment from its tail to its nose, where the nose sits
-- on `pose` (the trail end) and the tail lies back along the last tile.
function Geom.bikeSeg(pose)
  local tail = Geom.advance(pose, -Config.bikeLength)
  return { a = { x = tail.x, z = tail.z }, b = { x = pose.x, z = pose.z } }
end
