-- tts/spawn.lua
-- Spawning and locking of tiles, Prizms, capture markers, rider minis, mat.
-- All TTS API calls live here. Grey-box visuals (PLAN.md M2): thin tinted blocks
-- laid along each stored 2D path segment. Game logic never reads these objects.
--
-- Every visual carries the tag "gc_visual" plus a group tag so it can be removed:
--   gc_mat, gc_rider_<Color>, gc_trail_<Color>, gc_prizm_<id>, gc_marker_<n>

Spawn = {}

local VISUAL_TAG = "gc_visual"

local function tint(c) return { r = c[1], g = c[2], b = c[3] } end

local function place(params, color, groupTag)
  local obj = spawnObject({
    type = params.type or Config.tts.blockType,
    position = params.position,
    rotation = params.rotation or { 0, 0, 0 },
    scale = params.scale,
    sound = false,
    snap_to_grid = false,
    callback_function = function(o)
      o.setColorTint(tint(color))
      o.setLock(true)
      o.interactable = false
      o.addTag(VISUAL_TAG)
      o.addTag(groupTag)
      if params.name then o.setName(params.name) end
    end,
  })
  return obj
end

function Spawn.clearGroup(groupTag)
  for _, o in ipairs(getObjectsWithTag(groupTag)) do
    o.destruct()
  end
end

function Spawn.clearAll()
  for _, o in ipairs(getObjectsWithTag(VISUAL_TAG)) do
    o.destruct()
  end
end

-- Flat dark play surface covering Config.mat.
function Spawn.mat()
  local t = Config.tts
  place({
    position = { 0, t.tableY + t.matThickness / 2, 0 },
    scale = { Config.mat.width, t.matThickness, Config.mat.depth },
    name = "Gridcycles Mat",
  }, t.matColor, "gc_mat")
end

-- One thin block per path segment.
function Spawn.trailSegment(seg, color, groupTag)
  local t = Config.tts
  local p = Geom.segmentPose(seg)
  place({
    position = { p.x, t.tableY + t.matThickness + t.trailHeight / 2, p.z },
    rotation = { 0, p.heading, 0 },
    scale = { t.trailWidth, t.trailHeight, p.length + t.trailWidth * 0.5 },
  }, Config.palette[color], groupTag)
end

function Spawn.tile(color, segs)
  for _, s in ipairs(segs) do
    Spawn.trailSegment(s, color, "gc_trail_" .. color)
  end
end

function Spawn.prizm(prizm)
  local t = Config.tts
  local p = Geom.segmentPose(prizm)
  place({
    position = { p.x, t.tableY + t.matThickness + t.prizmHeight / 2, p.z },
    rotation = { 0, p.heading, 0 },
    scale = { t.prizmWidth, t.prizmHeight, p.length },
    name = "Prizm",
  }, Config.prizmColor, "gc_prizm_" .. prizm.id)
end

function Spawn.removePrizm(id)
  Spawn.clearGroup("gc_prizm_" .. id)
end

-- Capture marker occupies the Prizm's footprint in the capturer's colour.
function Spawn.marker(owner, index, seg)
  local t = Config.tts
  local p = Geom.segmentPose(seg)
  place({
    position = { p.x, t.tableY + t.matThickness + t.markerSize / 4, p.z },
    rotation = { 0, p.heading, 0 },
    scale = { t.markerSize, t.markerSize / 2, p.length },
    name = owner .. " marker",
  }, Config.palette[owner], "gc_marker_" .. index)
end

-- Rider mini sits at the trail end, pointing along the heading.
function Spawn.rider(color, pose)
  local t = Config.tts
  Spawn.clearGroup("gc_rider_" .. color)
  place({
    type = t.riderType,
    position = { pose.x, t.tableY + t.matThickness + t.riderSize / 2, pose.z },
    rotation = { 0, pose.heading, 0 },
    scale = { t.riderSize, t.riderSize, t.riderSize },
    name = color .. " rider",
  }, Config.palette[color], "gc_rider_" .. color)
end

function Spawn.clearTrail(color)
  Spawn.clearGroup("gc_trail_" .. color)
end

-- Rebuild every visual from state (new game, or after load).
function Spawn.rebuild(state)
  Spawn.clearAll()
  Spawn.mat()
  for _, color in ipairs(state.order) do
    local r = state.riders[color]
    for _, tile in ipairs(r.trail.tiles) do
      -- tiles hold their entry pose + kind; segments are recomputed, not stored per tile
      local segs = Geom.tilePath(tile.kind, tile.gear, tile.entry)
      Spawn.tile(color, segs)
    end
    Spawn.rider(color, r.pose)
  end
  for _, p in ipairs(state.prizms) do Spawn.prizm(p) end
  for i, m in ipairs(state.markers) do Spawn.marker(m.owner, i, m.segs[1]) end
end
