-- tts/spawn.lua
-- Spawning and locking of tiles, Prizms, rider minis, mat.
-- All TTS API calls live here. Grey-box visuals (PLAN.md M2): thin tinted blocks
-- laid along each stored 2D path segment. Game logic never reads these objects.
--
-- Every visual carries the tag "gc_visual" plus a group tag so it can be removed:
--   gc_mat, gc_rider_<Color>, gc_trail_<Color>, gc_prizm_<id>

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

local function place(params, color, groupTag, tileTag)
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
      if tileTag then o.addTag(tileTag) end
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
  if tileTag then register(obj, tileTag) end
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
function Spawn.trailSegment(seg, color, groupTag, tileTag)
  local t = Config.tts
  local p = Geom.segmentPose(seg)
  place({
    position = { p.x, t.tableY + t.matThickness + t.trailHeight / 2, p.z },
    rotation = { 0, p.heading, 0 },
    scale = { t.trailWidth, t.trailHeight, p.length + t.trailWidth * 0.5 },
  }, Config.palette[color], groupTag, tileTag)
end

local SHAPE_LABEL = { straight = "", soft = "S", hard = "H" }
local SHAPE_NAME = { straight = "Straight", soft = "Soft", hard = "Hard" }

-- Physical pieces (Config.tts.pieceModels): one Custom_Model per tile, loaded from
-- assets/models/tiles. The mesh's origin is the tile's entry point, so a piece is placed at
-- its entry pose; the texture carries the gear digit, and the chevron tip / notch and the
-- bevelled edge show where each tile starts. Empty `base` means grey-box blocks instead.
local function useModels()
  local m = Config.tts.pieceModels
  return m ~= nil and m.base ~= nil and m.base ~= ""
end

local DIR_NAME = { left = "Left", right = "Right" }

-- "Straight", "Soft Left", "Hard Right": the label used in object names and the tray.
local function pieceLabel(kind, shape)
  if shape == "straight" then return "Straight" end
  return SHAPE_NAME[shape] .. " " .. DIR_NAME[kind]
end

-- Mesh file stem, e.g. tile_g3_soft_right. With pieceModels.mirror the left and right
-- meshes are swapped (for a TTS import that mirrors them).
function Spawn.pieceMeshName(gear, shape, kind)
  if shape == "straight" then return "tile_g" .. gear .. "_straight" end
  local dir = kind
  if Config.tts.pieceModels.mirror then dir = (kind == "left") and "right" or "left" end
  return "tile_g" .. gear .. "_" .. shape .. "_" .. dir
end

-- spawnObjectData table for a piece of this colour standing at `pos` (x, y, z) with the
-- entry heading `heading`.
local function pieceData(color, gear, kind, shape, pos, heading, locked, tags)
  local m = Config.tts.pieceModels
  local c = Config.palette[color]
  local mesh = m.base .. Spawn.pieceMeshName(gear, shape, kind) .. ".obj"
  return {
    Name = "Custom_Model",
    Nickname = color .. " G" .. tostring(gear) .. " " .. pieceLabel(kind, shape),
    Transform = { posX = pos[1], posY = pos[2], posZ = pos[3], rotX = 0, rotY = heading + m.yaw, rotZ = 0,
                  scaleX = 1, scaleY = 1, scaleZ = 1 },
    ColorDiffuse = { r = c[1], g = c[2], b = c[3] },
    Locked = locked,
    Tags = tags,
    CustomMesh = { MeshURL = mesh, DiffuseURL = m.base .. "tiles_atlas.png", ColliderURL = mesh,
                   Convex = true, MaterialIndex = 0, TypeIndex = 0 },
  }
end

-- One laid tile (a record from state: id, kind, shape, gear, entry). Every part is tagged
-- gc_tile_<Color>_<id> so the tile can be removed on its own when its owner gives up their
-- oldest tiles or is hit by a crash.
function Spawn.tile(color, tile)
  local t = Config.tts
  local group = "gc_trail_" .. color
  local tileTag = "gc_tile_" .. color .. "_" .. tostring(tile.id)
  if useModels() then
    local e = tile.entry
    local obj = spawnObjectData({
      data = pieceData(color, tile.gear, tile.kind, tile.shape,
        { e.x, t.tableY + t.matThickness + t.pieceModels.yOffset, e.z }, e.heading, true,
        { VISUAL_TAG, group, tileTag }),
      callback_function = function(o) o.interactable = false end,
    })
    register(obj, group)
    register(obj, tileTag)
    return
  end
  -- grey-box: a wall block per path segment, a pale divider at the joint, a number plate on top
  local segs = Geom.tilePath(tile.kind, tile.gear, tile.entry, tile.shape)
  for _, s in ipairs(segs) do
    Spawn.trailSegment(s, color, group, tileTag)
  end
  local top = t.tableY + t.matThickness + t.trailHeight
  local first = Geom.segmentPose(segs[1])
  place({
    position = { segs[1].a.x, t.tableY + t.matThickness + t.trailHeight * 0.55, segs[1].a.z },
    rotation = { 0, first.heading, 0 },
    scale = { t.trailWidth * 2.4, t.trailHeight * 1.1, 0.07 },
    name = color .. " tile joint",
  }, t.dividerColor, group, tileTag)
  local mid = Geom.segmentPose(segs[math.ceil(#segs / 2)])
  local plate = t.labelPlate
  local shape = tile.shape or "straight"
  place({
    position = { mid.x, top + 0.02, mid.z },
    scale = { plate, 0.04, plate },
    name = color .. " G" .. tostring(tile.gear) .. " " .. SHAPE_NAME[shape],
    label = { text = tostring(tile.gear) .. SHAPE_LABEL[shape], color = Config.palette[color] },
  }, t.labelPlateColor, group, tileTag)
end

function Spawn.removeTile(color, id)
  Spawn.clearGroup("gc_tile_" .. color .. "_" .. tostring(id))
end

-- An unscored Prizm is neutral; a scored one is tinted with its owner's colour.
function Spawn.prizm(prizm)
  local t = Config.tts
  local p = Geom.segmentPose(prizm)
  local owned = prizm.owner ~= nil
  place({
    position = { p.x, t.tableY + t.matThickness + t.prizmHeight / 2, p.z },
    rotation = { 0, p.heading, 0 },
    scale = { t.prizmWidth * (owned and 1.5 or 1), t.prizmHeight, p.length },
    name = owned and (prizm.owner .. " Prizm") or "Prizm",
  }, owned and Config.palette[prizm.owner] or Config.prizmColor, "gc_prizm_" .. prizm.id)
end

function Spawn.removePrizm(id)
  Spawn.clearGroup("gc_prizm_" .. id)
end

-- The bike is part of its owner's trail: it sits on the end of the last tile with
-- its nose on `pose` (see Geom.bikeSeg), so the model is centred half a bike length
-- behind the pose.
-- Custom bike mesh, spawned from a data table so tint/lock/tags are set up front
-- (setCustomObject would respawn the object and drop them).
local function customRider(color, pose, lift)
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
        posX = mid.x, posY = t.tableY + t.matThickness + m.yOffset + lift, posZ = mid.z,
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

-- `lifted`: the bike stands on a laid tile (so on top of it); false right after a launch,
-- when it stands on the mat.
function Spawn.rider(color, pose, lifted)
  local t = Config.tts
  local lift = lifted and t.trailHeight or 0
  Spawn.clearGroup("gc_rider_" .. color)
  if t.riderModel and t.riderModel.mesh ~= "" then
    customRider(color, pose, lift)
    return
  end
  local mid = Geom.segmentPose(Geom.bikeSeg(pose))
  place({
    type = t.riderType,
    position = { mid.x, t.tableY + t.matThickness + t.riderSize / 2 + lift, mid.z },
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
-- Each rider gets a tray: one locked slab plus one draggable tile per piece type
-- (every gear/shape/direction in Config.tileSupply). Tiles are named
-- "<Color> G<gear> <Straight|Soft Left|Hard Right|...>" and always return to their
-- slot; the script lays the real trail piece itself.

local DIRS = { { "left", "Left" }, { "right", "Right" } }
local SHAPES = { "straight", "soft", "hard" }

-- Ordered list of tray tiles: { gear, kind, shape, label }.
local function trayEntries()
  local list = {}
  for g = Config.gears.min, Config.gears.max do
    local row = Config.tileSupply[g] or {}
    for _, shape in ipairs(SHAPES) do
      if (row[shape] or 0) > 0 then
        if shape == "straight" then
          list[#list + 1] = { g, "straight", "straight", "Straight" }
        else
          for _, d in ipairs(DIRS) do
            list[#list + 1] = { g, d[1], shape, SHAPE_NAME[shape] .. " " .. d[2] }
          end
        end
      end
    end
  end
  return list
end

-- "Red G3 Soft Left" -> "Red", 3, "left", "soft"; "Red G2 Straight" -> "Red", 2, "straight", "straight"
function Spawn.parseTileName(name)
  local color, gear, rest = tostring(name):match("^(%a+) G(%d) (.+)$")
  if not color then return nil end
  for _, e in ipairs(trayEntries()) do
    if e[4] == rest and e[1] == tonumber(gear) then return color, e[1], e[2], e[3] end
  end
  return nil
end

-- Grey-box tray (no piece models): one chord-sized block per tile in a single row ----------
local function blockRowZ(index)
  return -(Config.mat.depth / 2 + Config.tts.trayOffset + (index - 1) * Config.tts.trayRowDepth)
end

local function blockHome(gear, kind, shape, rowIndex)
  local t = Config.tts
  local entries = trayEntries()
  local slot = 1
  for i, e in ipairs(entries) do
    if e[1] == gear and e[2] == kind and e[3] == shape then slot = i end
  end
  local x = (slot - (#entries + 1) / 2) * t.trayGap
  return { x, t.tableY + t.matThickness + t.tileHeight / 2 + 0.05, blockRowZ(rowIndex) }
end

-- Piece tray: real pieces lying along +x (heading 90), one shelf per gear -----------------
-- Box of a piece lying at heading 90 with its entry at the origin: x forward (including the
-- chevron tip), z across (right curves bend toward -z, left toward +z).
local function pieceBox(kind, gear, shape)
  local w = Config.tts.trailWidth / 2
  local minx, maxx, minz, maxz = 0, 0, 0, 0
  for _, sg in ipairs(Geom.tilePath(kind, gear, { x = 0, z = 0, heading = 90 }, shape)) do
    for _, p in ipairs({ sg.a, sg.b }) do
      minx, maxx = math.min(minx, p.x), math.max(maxx, p.x)
      minz, maxz = math.min(minz, p.z), math.max(maxz, p.z)
    end
  end
  return minx, maxx + w, minz - w, maxz + w   -- the tip pokes a half-width past the exit
end

-- Layout of one rider's tray, relative to its north edge at x = 0: every item gets
-- { gear, kind, shape, label, x, z } (the piece's entry point) and the tray's size.
local function pieceLayout()
  local pad = Config.tts.trayPad
  local rows, totalW, depth = {}, 0, 0
  for g = Config.gears.min, Config.gears.max do
    local items, rowW, rowD = {}, 0, 0
    for _, e in ipairs(trayEntries()) do
      if e[1] == g then
        local x0, x1, z0, z1 = pieceBox(e[2], g, e[3])
        items[#items + 1] = { e = e, x0 = x0, w = x1 - x0, z1 = z1, d = z1 - z0 }
        rowW = rowW + (x1 - x0) + (#items > 1 and pad or 0)
        rowD = math.max(rowD, z1 - z0)
      end
    end
    rows[#rows + 1] = { items = items, w = rowW, d = rowD }
    totalW = math.max(totalW, rowW)
    depth = depth + rowD + pad
  end
  local out, top = {}, -pad / 2
  for _, row in ipairs(rows) do
    local cursor = -row.w / 2
    for _, it in ipairs(row.items) do
      out[#out + 1] = { gear = it.e[1], kind = it.e[2], shape = it.e[3], label = it.e[4],
                        x = cursor - it.x0, z = top - it.z1 }
      cursor = cursor + it.w + pad
    end
    top = top - row.d - pad
  end
  return out, totalW + 2 * pad, depth
end

Spawn.pieceBox, Spawn.pieceLayout = pieceBox, pieceLayout   -- exposed for tests

-- Trays go two to a band, side by side, bands stacking south of the mat. With a single
-- rider the tray is centred. Returns the tray's x offset and its north edge z.
local function trayOrigin(index, width, depth)
  local riders = State and #State.order or 4
  local band, col = math.floor((index - 1) / 2), (index - 1) % 2
  local x = 0
  if riders > 1 then x = (col == 0 and -1 or 1) * (width / 2 + 0.5) end
  return x, -(Config.mat.depth / 2 + Config.tts.trayOffset) - band * (depth + 2)
end

-- Where a tray tile lives: position {x, y, z} and entry heading.
local function homePos(gear, kind, shape, rowIndex)
  local t = Config.tts
  if not useModels() then
    return blockHome(gear, kind, shape, rowIndex), 0
  end
  local items, width, depth = pieceLayout()
  local x0, z0 = trayOrigin(rowIndex, width, depth)
  for _, it in ipairs(items) do
    if it.gear == gear and it.kind == kind and it.shape == shape then
      return { x0 + it.x, t.tableY + t.matThickness - 0.04, z0 + it.z }, 90
    end
  end
  return { x0, t.tableY + t.matThickness, z0 }, 90
end

function Spawn.trayTiles(color, index)
  local t = Config.tts
  if useModels() then
    local items, width, depth = pieceLayout()
    local x0, z0 = trayOrigin(index, width, depth)
    place({
      position = { x0, t.tableY + t.matThickness / 2 - 0.05, z0 - depth / 2 },
      scale = { width, t.matThickness, depth },
      name = color .. " tray",
    }, t.matColor, "gc_tray_" .. color)
    for _, it in ipairs(items) do
      local pos, heading = homePos(it.gear, it.kind, it.shape, index)
      local obj = spawnObjectData({
        data = pieceData(color, it.gear, it.kind, it.shape, pos, heading, false,
          { VISUAL_TAG, "gc_tray_" .. color, "gc_tile" }),
      })
      register(obj, "gc_tray_" .. color)
    end
    return
  end
  local z = blockRowZ(index)
  place({
    position = { 0, t.tableY + t.matThickness / 2 - 0.05, z },
    scale = { Config.mat.width, t.matThickness, t.trayRowDepth - 1 },
    name = color .. " tray",
  }, t.matColor, "gc_tray_" .. color)
  for _, e in ipairs(trayEntries()) do
    local g, kind, shape, label = e[1], e[2], e[3], e[4]
    local obj = spawnObject({
      type = t.blockType,
      position = blockHome(g, kind, shape, index),
      rotation = { 0, 0, 0 },
      scale = { t.tileWidth, t.tileHeight * (kind == "straight" and 1 or 2), Geom.tileChord(kind, g, shape) },
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

-- Send a dragged tile back to its slot.
function Spawn.returnTile(obj)
  local color, gear, kind, shape = Spawn.parseTileName(obj.getName())
  if color == nil or State == nil then return end
  local rowIndex
  for i, c in ipairs(State.order) do if c == color then rowIndex = i end end
  if rowIndex == nil then return end
  local pos, heading = homePos(gear, kind, shape, rowIndex)
  obj.setRotation({ 0, heading + (useModels() and Config.tts.pieceModels.yaw or 0), 0 })
  obj.setPositionSmooth(pos, false, true)
end

-- Rebuild every visual from state (new game, or after load).
function Spawn.rebuild(state)
  Spawn.clearAll()
  Spawn.mat()
  for _, color in ipairs(state.order) do
    local r = state.riders[color]
    for _, tile in ipairs(r.trail.tiles) do
      Spawn.tile(color, tile)
    end
    Spawn.rider(color, r.pose, #r.trail.tiles > 0)
  end
  if Config.placementMode == "hand" then
    for i, color in ipairs(state.order) do Spawn.trayTiles(color, i) end
  end
  for _, p in ipairs(state.prizms) do Spawn.prizm(p) end
end
