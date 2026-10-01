-- geom.lua
-- Pure 2D geometry on the table plane (x, z). NO TTS API calls in this file:
-- it must run under plain Lua 5.2 so tests/run.lua can exercise it.
--
-- Types:
--   Point   = { x = number, z = number }
--   Pose    = { x = number, z = number, heading = number }  -- heading in degrees, 0 = +z
--   Segment = { a = Point, b = Point }
--   kind    = "straight" | "left" | "right"

Geom = {}

-- Build the path for one tile.
-- Returns: segments (array of Segment), exitPose (Pose)
function Geom.tilePath(kind, gear, entryPose)
  error("Geom.tilePath: not implemented (PLAN.md M1)")
end

-- True if segments a and b intersect (touching within epsilon counts).
function Geom.segmentsIntersect(a, b)
  error("Geom.segmentsIntersect: not implemented (PLAN.md M1)")
end

-- True if any of newSegs hits any trail segment.
-- trails: array of { owner = color, segs = {Segment...} }
-- ignoreJoint: Point to ignore (the joint with the mover's own previous tile).
function Geom.pathHitsTrails(newSegs, trails, ignoreJoint)
  error("Geom.pathHitsTrails: not implemented (PLAN.md M1)")
end

-- True if the path fully crosses the Prizm's long axis (prizmSeg).
function Geom.pathCrossesPrizm(newSegs, prizmSeg)
  error("Geom.pathCrossesPrizm: not implemented (PLAN.md M1)")
end

-- True if every point of the path is inside the mat bounds.
function Geom.inBounds(segs, mat)
  error("Geom.inBounds: not implemented (PLAN.md M1)")
end
