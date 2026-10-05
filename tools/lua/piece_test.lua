-- Calibration for the physical tile meshes (tools/make_tiles.py). Run with the game loaded:
--   python3 tools/push_tts.py --exec tools/lua/piece_test.lua --logs
-- Spawns one of each: a G3 soft RIGHT, a G3 soft LEFT, a G2 hard RIGHT and a G2 straight,
-- each at a known entry pose, plus a white cube at the exit point Geom says the piece should
-- reach. Check from above (south edge at the bottom):
--   * the piece starts at its cube-less end (the notched end) and its pointed tip lines up with the
--     white cube, i.e. the piece lies ALONG the path the rules use;
--   * the RIGHT piece bends toward +x (to the right when you look north), the LEFT toward -x;
--   * the digits are not mirrored.
-- If a piece is mirrored or points backwards, tell Claude which, and the generator gets a flag.
-- Running it again replaces the previous test pieces.
local BASE = "https://raw.githubusercontent.com/dannable/gridcycles/main/assets/models/tiles/"
local TAG = "gc_piece_test"
local y = Config.tts.tableY + Config.tts.matThickness

for _, o in ipairs(getObjectsWithTag(TAG)) do o.destruct() end

local function piece(name, tint, entry, kind, gear, shape)
  local mesh = BASE .. name .. ".obj"
  spawnObjectData({
    data = {
      Name = "Custom_Model", Nickname = name,
      Transform = { posX = entry.x, posY = y, posZ = entry.z, rotX = 0, rotY = entry.heading, rotZ = 0,
                    scaleX = 1, scaleY = 1, scaleZ = 1 },
      ColorDiffuse = { r = tint[1], g = tint[2], b = tint[3] },
      Locked = true, Tags = { TAG },
      CustomMesh = { MeshURL = mesh, DiffuseURL = BASE .. "tiles_atlas.png", ColliderURL = mesh,
                     Convex = true, MaterialIndex = 0, TypeIndex = 0 },
    },
  })
  local _, exit = Geom.tilePath(kind, gear, entry, shape)
  spawnObject({
    type = "BlockSquare", position = { exit.x, y + 0.12, exit.z }, scale = { 0.12, 0.24, 0.12 },
    sound = false, snap_to_grid = false,
    callback_function = function(o)
      o.setColorTint({ r = 1, g = 1, b = 1 }); o.setLock(true); o.addTag(TAG); o.interactable = false
    end,
  })
  print(string.format("%s: entry (%.2f, %.2f) heading %d -> exit (%.2f, %.2f) heading %d",
    name, entry.x, entry.z, entry.heading, exit.x, exit.z, exit.heading))
end

local pink, cyan = Config.palette.Red, Config.palette.Blue
piece("tile_g3_soft_right", pink, { x = -6, z = -4, heading = 0 }, "right", 3, "soft")
piece("tile_g3_soft_left", cyan, { x = 0, z = -4, heading = 0 }, "left", 3, "soft")
piece("tile_g2_hard_right", pink, { x = 5, z = -4, heading = 0 }, "right", 2, "hard")
piece("tile_g2_straight", cyan, { x = 9, z = -4, heading = 0 }, "straight", 2, "straight")
print("piece test spawned; look from above with the south edge at the bottom")
