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

-- Build the path for one tile.
-- Returns: segments (array of Segment), exitPose (Pose)
function Geom.tilePath(kind, gear, entryPose)
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

  local r, sweep, n = t.radius, t.sweep, Config.arcSegments
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

-- True if any of newSegs hits any trail segment. A second return value is the
-- trail entry that was hit.
-- trails: array of { owner = color, segs = {Segment...}, kind = "bike"|nil }
-- ignoreJoint: Point to ignore (the joint with the mover's own previous tile).
-- A new/old segment pair that both end at the joint is skipped.
function Geom.pathHitsTrails(newSegs, trails, ignoreJoint)
  for _, trail in ipairs(trails) do
    for _, old in ipairs(trail.segs) do
      for _, ns in ipairs(newSegs) do
        if Geom.segmentsIntersect(ns, old) then
          local atJoint = ignoreJoint ~= nil
            and touchesPoint(ns, ignoreJoint) and touchesPoint(old, ignoreJoint)
          if not atJoint then return true, trail end
        end
      end
    end
  end
  return false
end

-- True if the path fully crosses the Prizm's long axis (prizmSeg): the path must
-- pass from one side of the axis to the other, at a point on the Prizm.
-- Touching or ending on the axis does not count.
function Geom.pathCrossesPrizm(newSegs, prizmSeg)
  local pa, pb = prizmSeg.a, prizmSeg.b
  -- polyline vertices
  local pts = { newSegs[1].a }
  for _, s in ipairs(newSegs) do pts[#pts + 1] = s.b end

  local lastIdx, lastSide = nil, 0
  for i, p in ipairs(pts) do
    local side = sign(orient(pa, pb, p))
    if side ~= 0 then
      if lastSide ~= 0 and side ~= lastSide then
        -- crossing happened between pts[lastIdx] and pts[i]; locate it
        local hit
        if i - lastIdx > 1 then
          hit = pts[lastIdx + 1]            -- first vertex lying on the axis
        else
          local p0, p1 = pts[lastIdx], p
          local d0, d1 = orient(pa, pb, p0), orient(pa, pb, p1)
          local t = d0 / (d0 - d1)
          hit = { x = p0.x + (p1.x - p0.x) * t, z = p0.z + (p1.z - p0.z) * t }
        end
        if onSegment(pa, pb, hit) then return true end
      end
      lastIdx, lastSide = i, side
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

local function dist(p, q)
  local dx, dz = p.x - q.x, p.z - q.z
  return math.sqrt(dx * dx + dz * dz)
end

-- Straight-line distance from a tile's entry to its exit (used to size physical tiles).
function Geom.tileChord(kind, gear)
  local _, exit = Geom.tilePath(kind, gear, { x = 0, z = 0, heading = 0 })
  return dist({ x = 0, z = 0 }, exit)
end

-- Midpoint between entry and exit of the tile that WOULD be laid from `pose`.
function Geom.tileCenter(kind, gear, pose)
  local _, exit = Geom.tilePath(kind, gear, pose)
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
