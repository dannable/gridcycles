-- tts/spawn.lua
-- Spawning and locking of tiles, Prizms, capture markers, rider minis, mat.
-- All TTS API calls live here. Grey-box visuals (PLAN.md M2): thin tinted blocks
-- laid along each stored 2D path segment. Game logic never reads these objects.
--
-- Every visual carries the tag "gc_visual" plus a group tag so it can be removed:
--   gc_mat, gc_rider_<Color>, gc_trail_<Color>, gc_prizm_<id>, gc_marker_<n>

Spawn = {}

local VISUAL_TAG = "gc_visual"

-- Objects get their tags in the spawn callback, which runs a little after
-- spawnObject returns. Keep our own registry so clears also catch objects that
-- are still spawning (or were destructed this frame).
local live = {}   -- groupTag -> { obj... }

local function register(obj, groupTag)
  live[groupTag] = live[groupTag] or {}
  table.insert(live[groupTag], obj)
end

local function destroy(o)
  if o == nil then return end
  if o.isDestroyed ~= nil and o.isDestroyed() then return end
  o.destruct()
end

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
      if params.label then
        -- flat text on the object's top face; the button is scaled to undo the
        -- object's own (non-uniform) scale so the digit isn't stretched
        local sc = params.scale
        o.createButton({
          click_function = "gcNoop", function_owner = Global,
          label = params.label.text, font_color = tint(params.label.color), color = { 0, 0, 0, 0 },
          position = { 0, 0.6, 0 }, rotation = { 0, 0, 0 },
          scale = { 1 / sc[1], 1, 1 / sc[3] },
          width = 0, height = 0, font_size = Config.tts.labelFontSize,
        })
      end
    end,
  })
  register(obj, groupTag)
  return obj
end

function Spawn.clearGroup(groupTag)
  for _, o in ipairs(live[groupTag] or {}) do destroy(o) end
  live[groupTag] = nil
  for _, o in ipairs(getObjectsWithTag(groupTag)) do destroy(o) end
end

function Spawn.clearAll()
  for tag, list in pairs(live) do
    for _, o in ipairs(list) do destroy(o) end
    live[tag] = nil
  end
  for _, o in ipairs(getObjectsWithTag(VISUAL_TAG)) do destroy(o) end
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

-- One laid tile: its wall segments, a pale divider bar across the wall at the joint
-- where it starts, and a plate on top showing its gear. The plate keeps a fixed
-- orientation (not rotated with the trail) so the digit reads the same everywhere.
function Spawn.tile(color, segs, gear)
  local t = Config.tts
  local group = "gc_trail_" .. color
  for _, s in ipairs(segs) do
    Spawn.trailSegment(s, color, group)
  end
  local top = t.tableY + t.matThickness + t.trailHeight
  local first = Geom.segmentPose(segs[1])
  place({
    position = { segs[1].a.x, t.tableY + t.matThickness + t.trailHeight * 0.55, segs[1].a.z },
    rotation = { 0, first.heading, 0 },
    scale = { t.trailWidth * 2.4, t.trailHeight * 1.1, 0.07 },
    name = color .. " tile joint",
  }, t.dividerColor, group)
  local mid = Geom.segmentPose(segs[math.ceil(#segs / 2)])
  local plate = t.labelPlate
  place({
    position = { mid.x, top + 0.02, mid.z },
    scale = { plate, 0.04, plate },
    name = color .. " G" .. tostring(gear),
    label = { text = tostring(gear), color = Config.palette[color] },
  }, t.labelPlateColor, group)
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

-- The bike is part of its owner's trail: it sits on the end of the last tile with
-- its nose on `pose` (see Geom.bikeSeg), so the model is centred half a bike length
-- behind the pose.
-- Custom bike mesh, spawned from a data table so tint/lock/tags are set up front
-- (setCustomObject would respawn the object and drop them).
local function customRider(color, pose)
  local t = Config.tts
  local mid = Geom.segmentPose(Geom.bikeSeg(pose))
  local m = t.riderModel
  local group = "gc_rider_" .. color
  local c = Config.palette[color]
  local obj = spawnObjectData({
    data = {
      Name = "Custom_Model",
      Nickname = color .. " rider",
      Transform = {
        posX = mid.x, posY = t.tableY + t.matThickness + m.yOffset, posZ = mid.z,
        rotX = 0, rotY = pose.heading + m.yaw, rotZ = 0,
        scaleX = Config.bikeLength, scaleY = Config.bikeLength, scaleZ = Config.bikeLength,
      },
      ColorDiffuse = { r = c[1], g = c[2], b = c[3] },
      Locked = true,
      Tags = { VISUAL_TAG, group },
      CustomMesh = {
        MeshURL = m.mesh,
        DiffuseURL = m.diffuse,
        ColliderURL = (m.collider ~= "" and m.collider) or m.mesh,
        Convex = true,
        MaterialIndex = 0,
        TypeIndex = 0,
      },
    },
    callback_function = function(o) o.interactable = false end,
  })
  register(obj, group)
end

function Spawn.rider(color, pose)
  local t = Config.tts
  Spawn.clearGroup("gc_rider_" .. color)
  if t.riderModel and t.riderModel.mesh ~= "" then
    customRider(color, pose)
    return
  end
  local mid = Geom.segmentPose(Geom.bikeSeg(pose))
  place({
    type = t.riderType,
    position = { mid.x, t.tableY + t.matThickness + t.riderSize / 2, mid.z },
    rotation = { 0, pose.heading, 0 },
    scale = { t.riderSize, t.riderSize, t.riderSize },
    name = color .. " rider",
  }, Config.palette[color], "gc_rider_" .. color)
end

function Spawn.clearTrail(color)
  Spawn.clearGroup("gc_trail_" .. color)
end

-- Click target for the gear-number labels; they are not buttons, but TTS wants a function.
function gcNoop() end

-- Hand mode ---------------------------------------------------------------
-- Each rider gets a tray: one locked slab plus 15 draggable tiles
-- (5 gears x straight/left/right). Tiles are named "<Color> G<gear> <Kind>" and
-- always return to their slot; the script lays the real trail piece itself.

local KINDS = { { "straight", "Straight" }, { "left", "Left" }, { "right", "Right" } }

local function trayRowZ(index)
  return -(Config.mat.depth / 2 + Config.tts.trayOffset + (index - 1) * Config.tts.trayRowDepth)
end

local function slotX(slot)
  local total = (Config.gears.max - Config.gears.min + 1) * #KINDS
  return (slot - (total + 1) / 2) * Config.tts.trayGap
end

-- "Red G3 Left" -> "Red", 3, "left"
function Spawn.parseTileName(name)
  local color, gear, kindName = tostring(name):match("^(%a+) G(%d) (%a+)$")
  if not color then return nil end
  for _, k in ipairs(KINDS) do
    if k[2] == kindName then return color, tonumber(gear), k[1] end
  end
  return nil
end

-- Slot position of a tray tile, derived from its name so no object ids are needed.
local function homePos(color, gear, kind, rowIndex)
  local t = Config.tts
  local kindIdx = 1
  for i, k in ipairs(KINDS) do if k[1] == kind then kindIdx = i end end
  local slot = (gear - Config.gears.min) * #KINDS + kindIdx
  return { slotX(slot), t.tableY + t.matThickness + t.tileHeight / 2 + 0.05, trayRowZ(rowIndex) }
end

function Spawn.trayTiles(color, index)
  local t = Config.tts
  local z = trayRowZ(index)
  place({
    position = { 0, t.tableY + t.matThickness / 2 - 0.05, z },
    scale = { Config.mat.width, t.matThickness, t.trayRowDepth - 1 },
    name = color .. " tray",
  }, t.matColor, "gc_tray_" .. color)
  local slot = 0
  for g = Config.gears.min, Config.gears.max do
    for _, k in ipairs(KINDS) do
      slot = slot + 1
      local kind, label = k[1], k[2]
      local pos = homePos(color, g, kind, index)
      local obj = spawnObject({
        type = t.blockType,
        position = pos,
        rotation = { 0, 0, 0 },
        scale = { t.tileWidth, t.tileHeight * (kind == "straight" and 1 or 2), Geom.tileChord(kind, g) },
        sound = false,
        snap_to_grid = false,
        callback_function = function(o)
          o.setColorTint(tint(Config.palette[color]))
          o.setName(color .. " G" .. g .. " " .. label)
          o.addTag(VISUAL_TAG)
          o.addTag("gc_tray_" .. color)
          o.addTag("gc_tile")
        end,
      })
      register(obj, "gc_tray_" .. color)
    end
  end
end

-- Send a dragged tile back to its slot.
function Spawn.returnTile(obj)
  local color, gear, kind = Spawn.parseTileName(obj.getName())
  if color == nil or State == nil then return end
  local rowIndex
  for i, c in ipairs(State.order) do if c == color then rowIndex = i end end
  if rowIndex == nil then return end
  local pos = homePos(color, gear, kind, rowIndex)
  obj.setRotation({ 0, 0, 0 })
  obj.setPositionSmooth(pos, false, true)
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
      Spawn.tile(color, segs, tile.gear)
    end
    Spawn.rider(color, r.pose)
  end
  if Config.placementMode == "hand" then
    for i, color in ipairs(state.order) do Spawn.trayTiles(color, i) end
  end
  for _, p in ipairs(state.prizms) do Spawn.prizm(p) end
  for i, m in ipairs(state.markers) do Spawn.marker(m.owner, i, m.segs[1]) end
end
