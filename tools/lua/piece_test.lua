-- Calibration for the physical tile meshes (tools/make_tiles.py). Run with the game loaded:
--   python3 tools/push_tts.py --exec tools/lua/piece_test.lua --logs
-- Spawns one of each: a G3 soft RIGHT, a G3 soft LEFT, a G2 hard RIGHT and a G2 straight,
-- each at a known entry pose, plus a white cube at the exit point the rules expect. Check from
-- above (south edge at the bottom):
--   * the piece starts at its notched end and its pointed tip lines up with the white cube,
--     i.e. the piece lies ALONG the path the rules use;
--   * the RIGHT piece bends toward +x (to the right when you look north), the LEFT toward -x;
--   * the digits are not mirrored.
-- If a piece is mirrored or points backwards, set Config.tts.pieceModels.mirror / .yaw.
-- Running it again replaces the previous test pieces.
--
-- Self-contained on purpose: TTS runs this in its own context where Config and Geom (the game's
-- globals) do not exist. The numbers below mirror src/config.lua; tests/test_tts_glue.lua checks
-- that they still agree with Geom.
local BASE = "https://raw.githubusercontent.com/dannable/gridcycles/v0.3-pieces/assets/models/tiles/"
local TAG = "gc_piece_test"
local TABLE_Y = 1.0 + 0.1                       -- Config.tts.tableY + matThickness
local STRAIGHT = { [2] = 3.0 }                  -- Config.tiles[gear].straight
local CURVE = { soft = { [3] = { 4.0, 45 } }, hard = { [2] = { 1.5, 90 } } }   -- radius, sweep

for _, o in ipairs(getObjectsWithTag(TAG)) do o.destruct() end

-- Exit point of a tile (same maths as Geom.tilePath); heading in degrees, 0 = +z.
local function exitOf(entry, kind, gear, shape)
  local h = math.rad(entry.heading)
  if kind == "straight" then
    local len = STRAIGHT[gear]
    return { x = entry.x + math.sin(h) * len, z = entry.z + math.cos(h) * len, heading = entry.heading }
  end
  local r, sweep = CURVE[shape][gear][1], CURVE[shape][gear][2]
  local s = (kind == "right") and 1 or -1
  local cx = entry.x + r * math.sin(h + s * math.pi / 2)
  local cz = entry.z + r * math.cos(h + s * math.pi / 2)
  local hi = h + s * math.rad(sweep)
  return { x = cx - r * math.sin(hi + s * math.pi / 2), z = cz - r * math.cos(hi + s * math.pi / 2),
           heading = (entry.heading + s * sweep) % 360 }
end

local function piece(name, tint, entry, kind, gear, shape)
  local mesh = BASE .. name .. ".obj"
  spawnObjectData({
    data = {
      Name = "Custom_Model", Nickname = name,
      Transform = { posX = entry.x, posY = TABLE_Y, posZ = entry.z, rotX = 0, rotY = entry.heading, rotZ = 0,
                    scaleX = 1, scaleY = 1, scaleZ = 1 },
      ColorDiffuse = { r = tint[1], g = tint[2], b = tint[3] },
      Locked = true, Tags = { TAG },
      CustomMesh = { MeshURL = mesh, DiffuseURL = BASE .. "tiles_atlas.png", ColliderURL = mesh,
                     Convex = true, MaterialIndex = 0, TypeIndex = 0 },
    },
  })
  local exit = exitOf(entry, kind, gear, shape)
  spawnObject({
    type = "BlockSquare", position = { exit.x, TABLE_Y + 0.12, exit.z }, scale = { 0.12, 0.24, 0.12 },
    sound = false, snap_to_grid = false,
    callback_function = function(o)
      o.setColorTint({ r = 1, g = 1, b = 1 }); o.setLock(true); o.addTag(TAG); o.interactable = false
    end,
  })
  print(string.format("%s: entry (%.2f, %.2f) heading %d -> exit (%.2f, %.2f) heading %d",
    name, entry.x, entry.z, entry.heading, exit.x, exit.z, exit.heading))
end

local pink, cyan = { 1.00, 0.16, 0.43 }, { 0.02, 0.85, 0.91 }
piece("tile_g3_soft_right", pink, { x = -6, z = -4, heading = 0 }, "right", 3, "soft")
piece("tile_g3_soft_left", cyan, { x = 0, z = -4, heading = 0 }, "left", 3, "soft")
piece("tile_g2_hard_right", pink, { x = 5, z = -4, heading = 0 }, "right", 2, "hard")
piece("tile_g2_straight", cyan, { x = 9, z = -4, heading = 0 }, "straight", 2, "straight")
print("piece test spawned; look from above with the south edge at the bottom")
