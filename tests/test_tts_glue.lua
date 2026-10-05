-- Smoke test of src/tts/* against stubbed TTS APIs. Verifies the glue runs and
-- mirrors Rules results onto "objects"; it cannot verify real TTS behaviour.
local live = {}   -- all stub objects not yet destructed
local uiText = {}
local broadcasts = {}
local private = {}
local seated = { "Yellow" }
guidCounter = 0

local function makeObj(params)
  guidCounter = guidCounter + 1
  local o = { params = params, tags = {}, guid = "g" .. guidCounter, pos = params.position, name = "" }
  function o.setColorTint() end
  function o.setLock() end
  function o.setName(n) o.name = n end
  function o.getName() return o.name end
  function o.getPosition() return { x = o.pos[1], y = o.pos[2], z = o.pos[3] } end
  function o.setRotation(r) o.rot = r end
  function o.setPositionSmooth(p) o.pos = p; o.returned = (o.returned or 0) + 1 end
  function o.addTag(t) o.tags[t] = true end
  function o.createButton(b) o.button = b end
  function o.destruct() o.dead = true end
  function o.isDestroyed() return o.dead == true end
  live[#live + 1] = o
  if params.callback_function then params.callback_function(o) end
  return o
end

function spawnObject(params) return makeObj(params) end
local dataSpawns = {}
function spawnObjectData(params)
  dataSpawns[#dataSpawns + 1] = params.data
  local o = makeObj({ position = { params.data.Transform.posX, params.data.Transform.posY, params.data.Transform.posZ } })
  o.name = params.data.Nickname or ""
  o.data = params.data
  for _, tg in ipairs(params.data.Tags or {}) do o.addTag(tg) end
  if params.callback_function then params.callback_function(o) end
  return o
end
function getObjectsWithTag(tag)
  local out = {}
  for _, o in ipairs(live) do
    if o.tags[tag] and not o.dead then out[#out + 1] = o end
  end
  return out
end
local attrs = {}
UI = {
  setValue = function(id, v) uiText[id] = v end,
  setAttribute = function(id, k, v) attrs[id .. "." .. k] = v end,
  setXml = function(x) uiText.xml = x end,
}
function broadcastToAll(msg) broadcasts[#broadcasts + 1] = msg end
function printToColor(msg, color) private[#private + 1] = { color = color, msg = msg } end
Wait = { time = function(f) f() end }
Turns = {}
local changed = {}
Player = setmetatable({ getPlayers = function()
  local out = {}
  for _, c in ipairs(seated) do
    out[#out + 1] = { color = c, seated = true, steam_name = "p_" .. c,
      changeColor = function(to) changed[c] = to end }
  end
  return out
end }, { __index = function(_, c)
  for _, s in ipairs(seated) do if s == c then return { seated = true } end end
  return { seated = false }
end })

dofile("src/tts/spawn.lua")
dofile("src/tts/ui.lua")
dofile("src/tts/events.lua")

local function count(tag) return #getObjectsWithTag(tag) end

local function deepcopy(t)
  if type(t) ~= "table" then return t end
  local c = {}
  for k, v in pairs(t) do c[k] = deepcopy(v) end
  return c
end

describe("TTS glue, solo (stubbed)", function()
  it("newGame uses the seated colour and spawns mat, rider and Prizms", function()
    seated = { "Yellow" }
    Events.newGame()
    assert_eq(#State.order, 1)
    assert_eq(State.order[1], "Yellow")
    assert_eq(count("gc_mat"), 1)
    assert_eq(count("gc_rider_Yellow"), 1)
    assert_eq(count("gc_visual"), 1 + 1 + Config.neutralPrizmsPerPlayer)
    assert_true(uiText.gcStatus:find("Yellow's turn") ~= nil)
    assert_eq(Turns.turn_color, "Yellow")
  end)

  it("nobody seated falls back to a solo Red sandbox", function()
    seated = {}
    Events.newGame()
    assert_eq(State.order[1], "Red")
    seated = { "Yellow" }
    Events.newGame()
  end)

  it("a placed move adds trail blocks and moves the rider mini", function()
    State.riders.Yellow.pose = { x = 0, z = 0, heading = 0 }
    State.prizms = {}
    Events.commitMove("Yellow", "straight")
    assert_eq(count("gc_trail_Yellow"), 1, "one piece object per tile")
    assert_eq(count("gc_rider_Yellow"), 1)
  end)

  it("shift is applied once then resets", function()
    Events.setShift("Yellow", 1)
    assert_eq(Events.pendingShift, 1)
    Events.commitMove("Yellow", "straight")
    assert_eq(Events.pendingShift, 0)
    assert_eq(State.riders.Yellow.gear, 2)
  end)

  it("a crash clears the trail objects and asks the rider for a respawn gear", function()
    State.riders.Yellow.pose = { x = 0, z = Config.mat.depth / 2, heading = 0 }
    Events.commitMove("Yellow", "straight")
    assert_eq(count("gc_trail_Yellow"), 0)
    assert_eq(count("gc_rider_Yellow"), 1)
    assert_eq(State.pendingGear, "Yellow")
    assert_eq(attrs["gcPick_Yellow.active"], "true")
    assert_true(uiText.gcOdds_Yellow:find("Choose your respawn gear", 1, true) ~= nil)
    assert_true(uiText.gcStatus:find("choosing a gear", 1, true) ~= nil)
    assert_true(uiText.xml:find("gcb_Yellow_gear5", 1, true) ~= nil, "gear buttons exist")
    Events.commitMove("Yellow", "straight")
    assert_eq(#State.riders.Yellow.trail.tiles, 0, "no moves while the gear is pending")
    Events.chooseGear({ color = "Yellow", host = false }, 4)
    assert_eq(State.riders.Yellow.gear, 4)
    assert_eq(State.pendingGear, false)
    assert_eq(attrs["gcPick_Yellow.active"], "false")
  end)

  it("scoring redraws the Prizm in the rider's colour", function()
    State.riders.Yellow.pose = { x = 0, z = -10, heading = 0 }
    State.riders.Yellow.gear = 1
    State.prizms = { { id = 50, a = { x = -1, z = -9 }, b = { x = 1, z = -9 } } }
    Spawn.prizm(State.prizms[1])
    Events.commitMove("Yellow", "straight")
    assert_eq(count("gc_prizm_50"), 1, "redrawn, not removed")
    assert_eq(State.prizms[1].owner, "Yellow")
    assert_eq(Rules.prizmCount(State, "Yellow"), 1)
    assert_eq(getObjectsWithTag("gc_prizm_50")[1].name, "Yellow Prizm")
  end)

  it("restore rebuilds visuals from a copy of the saved state", function()
    State = deepcopy(State)
    Events.restore()
    assert_eq(count("gc_mat"), 1)
    assert_eq(count("gc_prizm_50"), 1)
    assert_eq(count("gc_rider_Yellow"), 1)
  end)
end)

describe("TTS glue, multiplayer (stubbed)", function()
  it("seats up to maxPlayers in seatOrder", function()
    seated = { "Green", "Red", "Blue", "Yellow", "Orange" }
    Events.newGame()
    assert_eq(#State.order, Config.maxPlayers)
    assert_eq(State.order[1], "Red")
    assert_eq(State.order[2], "Blue")
    assert_eq(State.order[3], "Green")
  end)

  it("rejects a move from the wrong player and tells them privately", function()
    seated = { "Red", "Blue" }
    Events.newGame()
    local before = #State.riders.Blue.trail.tiles
    Events.commitMove("Blue", "straight")
    assert_eq(#State.riders.Blue.trail.tiles, before)
    assert_eq(private[#private].color, "Blue")
    assert_true(private[#private].msg:find("Not your turn") ~= nil)
  end)

  it("a move passes the turn to the next rider and updates Turns", function()
    Events.commitMove("Red", "straight")
    assert_eq(Rules.currentColor(State), "Blue")
    assert_eq(Turns.turn_color, "Blue")
    assert_true(uiText.gcStatus:find("Blue's turn") ~= nil)
  end)

  it("a crash holds the turn until the gear is chosen; then the round ends on the new gear", function()
    State.riders.Blue.pose = { x = 0, z = Config.mat.depth / 2, heading = 0 }
    Events.commitMove("Blue", "straight")
    assert_eq(State.pendingGear, "Blue")
    assert_eq(State.round, 1, "turn not passed yet")
    assert_eq(Turns.turn_color, "Blue")
    assert_true(uiText.gcOdds_Red:find("Waiting for Blue", 1, true) ~= nil, uiText.gcOdds_Red)
    -- someone else can't choose, and nobody can move meanwhile
    local before = #private
    Events.chooseGear({ color = "Red", host = false }, 3)
    assert_eq(State.pendingGear, "Blue")
    assert_true(#private > before)
    Events.commitMove("Red", "straight")
    assert_eq(State.round, 1)
    -- bad gear is ignored; the host can pick for the crashed rider
    Events.chooseGear({ color = "Red", host = true }, 9)
    assert_eq(State.pendingGear, "Blue")
    Events.chooseGear({ color = "Red", host = true }, 4)
    assert_eq(State.riders.Blue.gear, 4)
    assert_eq(State.round, 2)
    assert_eq(Rules.currentColor(State), "Blue", "gear 4 beats gear 1")
    assert_eq(Turns.turn_color, "Blue")
    assert_eq(Turns.order[1], "Blue")
    local said = false
    for _, m in ipairs(broadcasts) do if m:find("Round 2 order: Blue, Red", 1, true) then said = true end end
    assert_true(said)
    assert_true(uiText.gcOrder:find("Round 2: Blue > Red", 1, true) ~= nil, uiText.gcOrder)
  end)

  it("a win freezes the game until New game", function()
    State.roundOrder, State.turn = { "Red", "Blue" }, 1
    State.riders.Red.pose = { x = 0, z = -10, heading = 0 }
    State.riders.Red.gear = 1
    State.prizms = { { id = 60, a = { x = -1, z = -9 }, b = { x = 1, z = -9 } } }
    for i = 1, Config.prizmsToWin - 1 do
      State.prizms[#State.prizms + 1] = { id = 70 + i, owner = "Red", a = { x = -9, z = i }, b = { x = -8, z = i } }
    end
    Events.commitMove("Red", "straight")
    assert_eq(State.winner, "Red")
    assert_true(uiText.gcStatus:find("WINS") ~= nil)
    local tiles = #State.riders.Blue.trail.tiles
    Events.commitMove("Blue", "straight")
    assert_eq(#State.riders.Blue.trail.tiles, tiles)
    Events.newGame()
    assert_false(State.winner)
  end)
end)

describe("Lobby and UI (stubbed)", function()
  local host = { color = "Red", host = true }
  local guest = { color = "Blue", host = false }

  it("toLobby clears the game and shows the lobby", function()
    Events.toLobby()
    assert_eq(State, nil)
    assert_eq(attrs["gcLobby.active"], "true")
    assert_eq(attrs["gcStatusPanel.active"], "false")
  end)

  it("lobby settings change only for the host and clamp", function()
    local before = Events.settings.maxPlayers
    Events.lobbyClick(guest, "players_inc")
    assert_eq(Events.settings.maxPlayers, before)
    Events.settings.maxPlayers = 4
    Events.lobbyClick(host, "players_inc")
    assert_eq(Events.settings.maxPlayers, 4)
    Events.lobbyClick(host, "players_dec")
    assert_eq(Events.settings.maxPlayers, 3)
    Events.settings.prizmsToWin = 6
    Events.lobbyClick(host, "prizms_inc")
    assert_eq(Events.settings.prizmsToWin, 6)
    Events.lobbyClick(host, "abilities")
    assert_false(Events.settings.abilities)
    Events.lobbyClick(host, "abilities")
  end)

  it("start applies settings to Config and builds rider panels", function()
    seated = { "Red", "Blue" }
    Events.settings.prizmsToWin = 5
    Events.settings.maxPlayers = 2
    Events.lobbyClick(host, "start")
    assert_eq(Config.prizmsToWin, 5)
    assert_eq(Config.maxPlayers, 2)
    assert_eq(State.settings.prizmsToWin, 5)
    assert_true(uiText.xml:find('id="gcPanel_Red"', 1, true) ~= nil)
    assert_true(uiText.xml:find('id="gcPanel_Blue"', 1, true) ~= nil)
    assert_true(uiText.xml:find('visibility="Blue"', 1, true) ~= nil)
    assert_eq(attrs["gcLobby.active"], "false")
    assert_eq(attrs["gcPanel_Red.active"], "true")
  end)

  it("only the current rider's buttons are interactable", function()
    assert_eq(attrs["gcb_Red_straight.interactable"], "true")
    assert_eq(attrs["gcb_Blue_straight.interactable"], "false")
  end)

  it("button ids route to moves for the clicking player", function()
    UI_.handle({ color = "Red" }, "gcb_Red_shiftup")
    assert_eq(Events.pendingShift, 1)
    assert_eq(attrs["gcb_Red_shiftup.color"], "#05D9E8")
    UI_.handle({ color = "Red" }, "gcb_Red_straight")
    assert_eq(Rules.currentColor(State), "Blue")
    assert_eq(State.riders.Red.gear, 2)
  end)

  it("a player cannot press another rider's button", function()
    local tiles = #State.riders.Red.trail.tiles
    UI_.handle({ color = "Blue" }, "gcb_Red_straight")
    assert_eq(#State.riders.Red.trail.tiles, tiles)
  end)

  it("event log keeps only the latest lines and shows odds", function()
    for i = 1, 20 do UI_.log("line " .. i) end
    UI_.refresh()
    assert_true(uiText.gcLog:find("line 20", 1, true) ~= nil)
    assert_true(uiText.gcLog:find("line 1\n", 1, true) == nil)
    assert_true(uiText.gcOdds_Blue:find("Curve success", 1, true) ~= nil)
  end)

  it("generated XML is balanced", function()
    local xml = UI_.buildXml({ "Red", "Blue", "Green" })
    local opens, closes, selfc = 0, 0, 0
    for tag in xml:gmatch("<(/?)[%a]+[^>]*>") do
      if tag == "/" then closes = closes + 1 else opens = opens + 1 end
    end
    for _ in xml:gmatch("/>") do selfc = selfc + 1 end
    assert_eq(opens - selfc, closes)
  end)

  it("restore adopts the saved settings", function()
    State = deepcopy(State)
    State.settings.prizmsToWin = 4
    Events.restore()
    assert_eq(Config.prizmsToWin, 4)
    assert_eq(Events.settings.prizmsToWin, 4)
  end)
end)

describe("Hand mode (stubbed)", function()
  local host = { color = "Red", host = true }

  local function tile(color, gear, label)
    for _, o in ipairs(getObjectsWithTag("gc_tile")) do
      if o.name == color .. " G" .. gear .. " " .. label then return o end
    end
  end

  local function drop(color, gear, kind, label, dx, shape)
    local o = tile(color, gear, label)
    local c = Geom.tileCenter(kind, gear, State.riders[color].pose, shape)
    o.pos = { c.x + (dx or 0), 2, c.z }
    Events.handleDrop(color, o)
    return o
  end

  it("lobby mode toggle switches to hand and trays spawn per rider", function()
    Events.toLobby()
    seated = { "Red", "Blue" }
    Events.settings.maxPlayers = 2
    Events.lobbyClick(host, "mode")
    assert_eq(Events.settings.mode, "hand")
    Events.lobbyClick(host, "start")
    -- one tray tile per straight, plus left and right of every soft/hard curve
    local perRider = 0
    for g = 1, 5 do
      for shape, n in pairs(Config.tileSupply[g]) do perRider = perRider + (shape == "straight" and 1 or 2) end
    end
    assert_eq(#getObjectsWithTag("gc_tile"), 2 * perRider)
    assert_eq(#getObjectsWithTag("gc_tray_Red"), perRider + 1)
    assert_true(uiText.gcOdds_Red:find("Drag a tile", 1, true) ~= nil)
    assert_eq(attrs["gcb_Red_straight.interactable"], "false")
  end)

  it("name parsing round-trips", function()
    local c, g, k, sh = Spawn.parseTileName("Red G3 Soft Left")
    assert_eq(c, "Red"); assert_eq(g, 3); assert_eq(k, "left"); assert_eq(sh, "soft")
    c, g, k, sh = Spawn.parseTileName("Red G2 Hard Right")
    assert_eq(k, "right"); assert_eq(sh, "hard")
    c, g, k, sh = Spawn.parseTileName("Blue G5 Straight")
    assert_eq(c, "Blue"); assert_eq(k, "straight"); assert_eq(sh, "straight")
    assert_eq(Spawn.parseTileName("Red G5 Hard Left"), nil, "gear 5 has no such tile")
    assert_eq(Spawn.parseTileName("Prizm"), nil)
  end)

  it("a good drop commits the move, passes the turn and returns the tile", function()
    State.riders.Red.pose = { x = 0, z = -10, heading = 0 }
    State.prizms = {}
    local o = drop("Red", 1, "straight", "Straight")
    assert_eq(#State.riders.Red.trail.tiles, 1)
    assert_eq(Rules.currentColor(State), "Blue")
    assert_eq(o.returned, 1)
  end)

  it("a drop with a gear jump is rejected and returned", function()
    local o = drop("Blue", 4, "straight", "Straight")
    assert_eq(#State.riders.Blue.trail.tiles, 0)
    assert_eq(Rules.currentColor(State), "Blue")
    assert_eq(o.returned, 1)
  end)

  it("a drop far from the trail end is rejected", function()
    local o = drop("Blue", 1, "straight", "Straight", Config.snapRadius + 2)
    assert_eq(#State.riders.Blue.trail.tiles, 0)
    assert_eq(o.returned, 1)
  end)

  it("a drop out of turn is rejected", function()
    local o = drop("Red", 2, "straight", "Straight")
    assert_eq(#State.riders.Red.trail.tiles, 1)
    assert_eq(o.returned, 1)
  end)

  it("dropping someone else's tile is rejected", function()
    local o = tile("Blue", 1, "Straight")
    local c = Geom.tileCenter("straight", 1, State.riders.Blue.pose)
    o.pos = { c.x, 2, c.z }
    Events.handleDrop("Red", o)
    assert_eq(#State.riders.Blue.trail.tiles, 0)
  end)

  it("a curve tile that fails its roll still places a straight", function()
    local o = drop("Blue", 1, "left", "Soft Left", 0, "soft")
    assert_eq(#State.riders.Blue.trail.tiles, 1)
    assert_eq(o.returned ~= nil, true)
  end)

  it("non-tile objects are ignored", function()
    Events.handleDrop("Red", { getName = function() return "Dice" end, guid = "x" })
  end)
end)

describe("Clearing while objects are still spawning (stubbed)", function()
  it("clearAll catches objects whose tags are not applied yet", function()
    local saved = spawnObject
    spawnObject = function(params)   -- spawn without running the callback (still 'spawning')
      local o = makeObj({ position = params.position })
      return o
    end
    Spawn.mat()
    spawnObject = saved
    Spawn.clearAll()
    local alive = 0
    for _, o in ipairs(live) do
      if not o.dead and o.params.callback_function == nil then alive = alive + 1 end
    end
    assert_eq(alive, 0)
  end)
end)

describe("Custom rider mesh (stubbed)", function()
  it("spawns a Custom_Model with colour, heading, yaw and scale when a mesh is set", function()
    Events.toLobby()
    local m = Config.tts.riderModel
    m.mesh, m.diffuse, m.yaw = "http://x/bike.obj", "http://x/bike.png", 180
    Spawn.rider("Red", { x = 3, z = 4, heading = 90 })
    local d = dataSpawns[#dataSpawns]
    assert_eq(d.Name, "Custom_Model")
    assert_eq(d.CustomMesh.MeshURL, "http://x/bike.obj")
    assert_eq(d.CustomMesh.ColliderURL, "http://x/bike.obj")
    assert_eq(d.Transform.rotY, 270)
    assert_eq(d.Transform.scaleX, Config.bikeLength)
    -- model is centred half a bike length behind the pose (heading 90 = +x)
    assert_near(d.Transform.posX, 3 - Config.bikeLength / 2)
    assert_near(d.Transform.posZ, 4)
    assert_near(d.ColorDiffuse.r, Config.palette.Red[1])
    assert_eq(count("gc_rider_Red"), 1)
    Spawn.rider("Red", { x = 3, z = 4, heading = 0 })
    assert_eq(count("gc_rider_Red"), 1, "old rider replaced")
    m.mesh, m.diffuse, m.yaw = "", "", 0
  end)
end)

describe("Seat enforcement (stubbed)", function()
  it("moves a player sitting in a non-playable colour to a free playable seat", function()
    seated = { "Red", "Orange" }
    changed = {}
    Events.enforceSeats()
    assert_eq(changed.Orange, "Blue")
    assert_eq(changed.Red, nil)
  end)
  it("sends them to spectator when all four seats are taken", function()
    seated = { "Red", "Blue", "Green", "Yellow", "White" }
    changed = {}
    Events.enforceSeats()
    assert_eq(changed.White, "Grey")
  end)
  it("leaves spectators and playable seats alone", function()
    seated = { "Red", "Grey", "Black" }
    changed = {}
    Events.enforceSeats()
    assert_eq(next(changed), nil)
  end)
  it("only the four playable colours have a palette entry", function()
    local n = 0
    for _ in pairs(Config.palette) do n = n + 1 end
    assert_eq(n, 4)
    assert_eq(#Config.seatOrder, 4)
  end)
end)

local function tileObjects(color)
  local out = {}
  for _, o in ipairs(getObjectsWithTag("gc_trail_" .. color)) do out[#out + 1] = o end
  return out
end

describe("Physical tile pieces (stubbed)", function()
  local base = Config.tts.pieceModels.base
  it("each laid tile is ONE Custom_Model standing at its entry pose", function()
    Events.settings.mode = "commit"
    seated = { "Red" }
    Events.newGame()
    State.riders.Red.pose = { x = 3, z = 4, heading = 90 }
    State.prizms = {}
    Events.setShift("Red", 1)
    Events.commitMove("Red", "straight")        -- G2 straight, entry (3, 4) heading 90
    local objs = tileObjects("Red")
    assert_eq(#objs, 1)
    local d = objs[1].data
    assert_eq(d.Name, "Custom_Model")
    assert_eq(d.Nickname, "Red G2 Straight")
    assert_eq(d.CustomMesh.MeshURL, base .. "tile_g2_straight.obj")
    assert_eq(d.CustomMesh.DiffuseURL, base .. "tiles_atlas.png")
    assert_eq(d.CustomMesh.ColliderURL, d.CustomMesh.MeshURL)
    assert_near(d.Transform.posX, 3); assert_near(d.Transform.posZ, 4)
    assert_near(d.Transform.posY, Config.tts.tableY + Config.tts.matThickness)
    assert_eq(d.Transform.rotY, 90)
    assert_eq(d.Transform.scaleX, 1)
    assert_true(d.Locked)
    assert_near(d.ColorDiffuse.r, Config.palette.Red[1])
    local id = State.riders.Red.trail.tiles[1].id
    assert_eq(#getObjectsWithTag("gc_tile_Red_" .. id), 1)
  end)
  it("curves use the mesh for their direction and shape", function()
    local entry = { x = 0, z = 0, heading = 0 }
    Spawn.tile("Red", { id = 91, kind = "right", shape = "soft", gear = 3, entry = entry })
    Spawn.tile("Red", { id = 92, kind = "left", shape = "hard", gear = 2, entry = entry })
    local n = {}
    for _, o in ipairs(getObjectsWithTag("gc_trail_Red")) do n[o.name] = o.data.CustomMesh.MeshURL end
    assert_eq(n["Red G3 Soft Right"], base .. "tile_g3_soft_right.obj")
    assert_eq(n["Red G2 Hard Left"], base .. "tile_g2_hard_left.obj")
  end)
  it("pieceModels.mirror swaps the left and right meshes; yaw turns every piece", function()
    local m = Config.tts.pieceModels
    m.mirror, m.yaw = true, 180
    Spawn.tile("Blue", { id = 1, kind = "right", shape = "soft", gear = 3, entry = { x = 0, z = 0, heading = 30 } })
    Spawn.tile("Blue", { id = 2, kind = "straight", shape = "straight", gear = 1, entry = { x = 0, z = 0, heading = 30 } })
    local o = getObjectsWithTag("gc_tile_Blue_1")[1]
    assert_eq(o.data.CustomMesh.MeshURL, base .. "tile_g3_soft_left.obj")
    assert_eq(o.data.Transform.rotY, 210)
    assert_eq(getObjectsWithTag("gc_tile_Blue_2")[1].data.CustomMesh.MeshURL, base .. "tile_g1_straight.obj")
    assert_eq(Spawn.pieceMeshName(2, "hard", "left"), "tile_g2_hard_right")
    m.mirror, m.yaw = false, 0
    assert_eq(Spawn.pieceMeshName(2, "hard", "left"), "tile_g2_hard_left")
  end)
  it("every piece type has a mesh file in assets/models/tiles", function()
    local entries = {}
    for g = 1, 5 do
      for shape in pairs(Config.tileSupply[g]) do
        for _, kind in ipairs(shape == "straight" and { "straight" } or { "left", "right" }) do
          entries[#entries + 1] = Spawn.pieceMeshName(g, shape, kind)
        end
      end
    end
    assert_eq(#entries, 19)
    for _, name in ipairs(entries) do
      local f = io.open("assets/models/tiles/" .. name .. ".obj", "r")
      assert_true(f ~= nil, "missing mesh " .. name)
      f:close()
    end
    assert_true(io.open("assets/models/tiles/tiles_atlas.png", "r") ~= nil, "missing atlas")
  end)
  it("meshes are pre-flipped for TTS, which mirrors OBJ x on import (right curves sit on -x in the file)", function()
    local function xrange(name)
      local lo, hi = math.huge, -math.huge
      for line in io.lines("assets/models/tiles/" .. name .. ".obj") do
        local x = line:match("^v ([%-%d%.eE]+) ")
        if x then lo, hi = math.min(lo, tonumber(x)), math.max(hi, tonumber(x)) end
      end
      return lo, hi
    end
    local lo, hi = xrange("tile_g3_soft_right")
    assert_true(hi < 0.5 and lo < -1, "soft right bends toward -x in the file")
    lo, hi = xrange("tile_g3_soft_left")
    assert_true(lo > -0.5 and hi > 1, "soft left bends toward +x in the file")
    lo, hi = xrange("tile_g2_hard_right")
    assert_true(hi < 0.5 and lo < -1, "hard right bends toward -x in the file")
    lo, hi = xrange("tile_g3_straight")
    assert_true(lo > -0.4 and hi < 0.4, "straights are symmetric about x = 0")
  end)
  it("rebuild after load draws one piece per tile with the right mesh", function()
    Events.newGame()
    State.prizms = {}
    State.riders.Red.pose = { x = 0, z = -14, heading = 0 }
    Events.setShift("Red", 1)
    Events.commitMove("Red", "straight")
    Events.commitMove("Red", "right", "soft")
    State = deepcopy(State)
    Events.restore()
    local tiles = State.riders.Red.trail.tiles
    assert_eq(#tileObjects("Red"), #tiles)
    for _, t in ipairs(tiles) do
      local o = getObjectsWithTag("gc_tile_Red_" .. t.id)[1]
      assert_eq(o.data.CustomMesh.MeshURL, base .. Spawn.pieceMeshName(t.gear, t.shape, t.kind) .. ".obj")
    end
  end)
  it("the bike stands on the last tile, but on the mat right after a launch", function()
    local top = Config.tts.tableY + Config.tts.matThickness
    local rm = Config.tts.riderModel
    local savedMesh, savedDiffuse = rm.mesh, rm.diffuse
    rm.mesh, rm.diffuse = "http://x/bike.obj", "http://x/bike.png"
    Events.newGame()
    local bike = getObjectsWithTag("gc_rider_Red")[1]
    assert_near(bike.data.Transform.posY, top + Config.tts.riderModel.yOffset, 1e-9, "on the mat at launch")
    State.prizms = {}
    Events.commitMove("Red", "straight")
    bike = getObjectsWithTag("gc_rider_Red")[1]
    assert_near(bike.data.Transform.posY, top + Config.tts.riderModel.yOffset + Config.tts.trailHeight, 1e-9,
      "on top of the piece")
    State = deepcopy(State)
    Events.restore()
    bike = getObjectsWithTag("gc_rider_Red")[1]
    assert_near(bike.data.Transform.posY, top + Config.tts.riderModel.yOffset + Config.tts.trailHeight, 1e-9,
      "after load too")
    State.riders.Red.pose = { x = 0, z = Config.mat.depth / 2, heading = 0 }
    Events.commitMove("Red", "straight")        -- crash: back on the mat
    Events.chooseGear({ color = "Red", host = false }, 1)
    bike = getObjectsWithTag("gc_rider_Red")[1]
    assert_near(bike.data.Transform.posY, top + Config.tts.riderModel.yOffset, 1e-9, "respawn on the mat")
    rm.mesh, rm.diffuse = savedMesh, savedDiffuse
  end)
end)

describe("Grey-box fallback when no piece URL is set (stubbed)", function()
  local m = Config.tts.pieceModels
  local saved = m.base
  it("lays wall blocks with a joint divider and a number plate", function()
    m.base = ""
    Events.settings.mode = "commit"
    seated = { "Red" }
    Events.newGame()
    State.riders.Red.pose = { x = 0, z = 0, heading = 0 }
    State.prizms = {}
    Events.setShift("Red", 1)
    Events.commitMove("Red", "straight")        -- G2 straight
    local plate, found
    for _, o in ipairs(getObjectsWithTag("gc_trail_Red")) do
      if o.name == "Red G2 Straight" then plate = o end
      if o.name == "Red tile joint" then found = true end
    end
    assert_true(plate ~= nil, "plate named by gear and shape")
    assert_eq(plate.button.label, "2")
    assert_eq(plate.button.click_function, "gcNoop")
    assert_true(found, "joint divider")
    assert_eq(#tileObjects("Red"), 3)
  end)
  it("curve plates carry S or H after the gear", function()
    State.riders.Red.gear = 2
    Events.commitMove("Red", "right", "hard")   -- may fail its roll and go straight; accept either
    local labels = {}
    for _, o in ipairs(getObjectsWithTag("gc_trail_Red")) do
      if o.button then labels[o.button.label] = true end
    end
    assert_true(labels["2H"] or labels["2"], "hard curve plate or the straight it fell back to")
  end)
  it("walls are three times the old height", function()
    assert_near(Config.tts.trailHeight, 0.36)
    m.base = saved
  end)
end)

describe("Tile supply and removal (stubbed)", function()
  it("the panel lists every gear's remaining templates and marks the gear you'll be in", function()
    Events.settings.mode = "commit"
    seated = { "Red" }
    Events.newGame()
    State.prizms = {}
    UI_.refresh()
    local txt = uiText.gcSupply_Red
    assert_true(txt:find("G1   Straight 2   Soft 2   Hard 2", 1, true) ~= nil, txt)
    assert_true(txt:find("G5   Straight 2   Soft -   Hard -", 1, true) ~= nil, txt)
    assert_true(txt:find(">", 1, true) ~= nil)
  end)
  it("the panel count drops after a tile is used", function()
    Events.commitMove("Red", "straight")
    assert_true(uiText.gcSupply_Red:find("G1   Straight 1", 1, true) ~= nil or
      uiText.gcSupply_Red:find("G1   Straight 1", 1, true) ~= nil)
  end)
  it("a warning appears when the move would use a lower tile", function()
    State.riders.Red.gear = 3
    State.riders.Red.supply[3].straight = 0
    UI_.refresh()
    assert_true(uiText.gcWarn_Red:find("Straight: would use a G2 straight", 1, true) ~= nil, uiText.gcWarn_Red)
  end)
  it("giving up oldest tiles removes exactly those tiles' objects", function()
    seated = { "Red" }
    Events.newGame()
    State.prizms = {}
    State.riders.Red.pose = { x = 0, z = -14, heading = 0 }
    Events.commitMove("Red", "straight")
    Events.commitMove("Red", "straight")
    local firstId = State.riders.Red.trail.tiles[1].id
    assert_eq(#getObjectsWithTag("gc_tile_Red_" .. firstId), 1)
    Events.commitMove("Red", "straight")        -- third G1 straight: oldest tile comes off
    assert_eq(#getObjectsWithTag("gc_tile_Red_" .. firstId), 0, "its piece is gone")
    assert_eq(#State.riders.Red.trail.tiles, 2)
    assert_eq(#getObjectsWithTag("gc_trail_Red"), 2)
  end)
  it("the log says when a rider gave up tiles", function()
    local said = false
    for _, m in ipairs(broadcasts) do if m:find("oldest", 1, true) then said = true end end
    assert_true(said)
  end)
  it("move buttons are never disabled for lack of tiles", function()
    Events.settings.mode = "commit"
    Events.newGame()
    State.riders.Red.supply[1].straight = 0
    UI_.refresh()
    assert_eq(attrs["gcb_Red_straight.interactable"], "true")
    assert_eq(attrs["gcb_Red_hardleft.interactable"], "true")
  end)
end)

describe("Prizm stealing and victims on the table (stubbed)", function()
  it("a stolen Prizm is redrawn in the thief's colour", function()
    Events.settings.mode = "commit"
    seated = { "Red", "Blue" }
    Events.newGame()
    State.roundOrder, State.turn = { "Red", "Blue" }, 1
    State.riders.Red.pose = { x = 0, z = -10, heading = 0 }
    State.prizms = { { id = 90, owner = "Blue", a = { x = -1, z = -9 }, b = { x = 1, z = -9 } } }
    Spawn.prizm(State.prizms[1])
    assert_eq(getObjectsWithTag("gc_prizm_90")[1].name, "Blue Prizm")
    Events.commitMove("Red", "straight")
    assert_eq(#getObjectsWithTag("gc_prizm_90"), 1)
    assert_eq(getObjectsWithTag("gc_prizm_90")[1].name, "Red Prizm")
    local said = false
    for _, m in ipairs(broadcasts) do if m:find("STOLE a Prizm from Blue", 1, true) then said = true end end
    assert_true(said)
  end)
  it("a crash victim's removed tiles disappear from the table", function()
    Events.newGame()
    State.prizms = {}
    State.roundOrder, State.turn = { "Blue", "Red" }, 1
    State.riders.Blue.pose = { x = 10, z = 10, heading = 180 }
    State.riders.Red.pose = { x = 7, z = 6.5, heading = 90 }
    for _, shift in ipairs({ 0, 1, 1 }) do
      State.roundOrder, State.turn = { "Blue", "Red" }, 1
      Events.setShift("Blue", shift)
      Events.commitMove("Blue", "straight")
    end
    assert_eq(#State.riders.Blue.trail.tiles, 3)
    assert_eq(#getObjectsWithTag("gc_tile_Blue_1"), 1)
    State.roundOrder, State.turn = { "Red", "Blue" }, 1
    State.riders.Red.gear = 3
    Events.commitMove("Red", "straight")
    assert_eq(#getObjectsWithTag("gc_tile_Blue_1"), 0, "oldest tile gone")
    assert_eq(#getObjectsWithTag("gc_tile_Blue_2"), 0, "the hit tile gone")
    assert_eq(#getObjectsWithTag("gc_tile_Blue_3"), 1, "front tile stays")
    assert_eq(#getObjectsWithTag("gc_trail_Red"), 0, "the crasher's line is cleared")
    local said = false
    for _, m in ipairs(broadcasts) do if m:find("Blue loses 2 tile", 1, true) then said = true end end
    assert_true(said)
  end)
end)

describe("Respawn gear picker (stubbed)", function()
  it("the pick buttons route to chooseGear for the crashed rider only", function()
    Events.settings.mode = "commit"
    seated = { "Red", "Blue" }
    Events.newGame()
    State.prizms = {}
    State.riders.Red.pose = { x = 0, z = Config.mat.depth / 2, heading = 0 }
    Events.commitMove("Red", "straight")
    assert_eq(State.pendingGear, "Red")
    UI_.handle({ color = "Blue", host = false }, "gcb_Red_gear2")
    assert_eq(State.pendingGear, "Red", "another player cannot pick")
    UI_.handle({ color = "Red", host = false }, "gcb_Red_gear2")
    assert_eq(State.pendingGear, false)
    assert_eq(State.riders.Red.gear, 2)
    assert_eq(Rules.currentColor(State), "Blue")
  end)
  it("a pending pick survives save and load", function()
    State.riders.Blue.pose = { x = 0, z = Config.mat.depth / 2, heading = 0 }
    Events.commitMove("Blue", "straight")
    assert_eq(State.pendingGear, "Blue")
    State = deepcopy(State)
    assert_true(Rules.isValidState(State))
    Events.restore()
    assert_eq(attrs["gcPick_Blue.active"], "true")
  end)
end)

describe("Hand mode with physical pieces (stubbed)", function()
  local function setup()
    Events.settings.mode = "hand"
    Events.settings.maxPlayers = 2
    seated = { "Red", "Blue" }
    Events.newGame()
    State.prizms = {}
  end
  local function tile(color, label)
    for _, o in ipairs(getObjectsWithTag("gc_tile")) do
      if o.name == color .. " " .. label then return o end
    end
  end

  it("tray pieces are draggable models of the right mesh, one per piece type", function()
    setup()
    local o = tile("Red", "G3 Soft Right")
    assert_true(o ~= nil)
    assert_eq(o.data.CustomMesh.MeshURL, Config.tts.pieceModels.base .. "tile_g3_soft_right.obj")
    assert_false(o.data.Locked, "draggable")
    assert_eq(o.data.Transform.rotY, 90, "lying along +x in the tray")
    assert_eq(#getObjectsWithTag("gc_tile"), 2 * 19)
  end)

  it("the tray layout never overlaps pieces, and keeps them inside the tray", function()
    local items, width, depth = Spawn.pieceLayout()
    assert_eq(#items, 19)
    local boxes = {}
    for i, it in ipairs(items) do
      local x0, x1, z0, z1 = Spawn.pieceBox(it.kind, it.gear, it.shape)
      boxes[i] = { x0 = it.x + x0, x1 = it.x + x1, z0 = it.z + z0, z1 = it.z + z1 }
      assert_true(boxes[i].x0 >= -width / 2 - 1e-9 and boxes[i].x1 <= width / 2 + 1e-9, "inside tray width")
      assert_true(boxes[i].z1 <= 1e-9 and boxes[i].z0 >= -depth - 1e-9, "inside tray depth")
    end
    for i = 1, #boxes do
      for j = i + 1, #boxes do
        local a, b = boxes[i], boxes[j]
        local overlap = a.x0 < b.x1 and b.x0 < a.x1 and a.z0 < b.z1 and b.z0 < a.z1
        assert_false(overlap, "pieces " .. i .. " and " .. j .. " overlap")
      end
    end
  end)

  it("trays are clear of the mat and of each other, for 2 and for 4 riders", function()
    for _, n in ipairs({ 2, 4 }) do
      local colors = { "Red", "Blue", "Green", "Yellow" }
      seated = {}
      for i = 1, n do seated[i] = colors[i] end
      Events.settings.maxPlayers = n
      Events.settings.mode = "hand"
      Events.newGame()
      local boxes = {}
      for i = 1, n do
        local b = { x0 = math.huge, x1 = -math.huge, z0 = math.huge, z1 = -math.huge }
        for _, o in ipairs(getObjectsWithTag("gc_tray_" .. colors[i])) do
          b.x0, b.x1 = math.min(b.x0, o.pos[1]), math.max(b.x1, o.pos[1])
          b.z0, b.z1 = math.min(b.z0, o.pos[3]), math.max(b.z1, o.pos[3])
        end
        assert_true(b.z1 < -Config.mat.depth / 2, "south of the mat")
        boxes[i] = b
      end
      for i = 1, n do
        for j = i + 1, n do
          local a, b = boxes[i], boxes[j]
          assert_false(a.x0 < b.x1 and b.x0 < a.x1 and a.z0 < b.z1 and b.z0 < a.z1, "trays " .. i .. "/" .. j)
        end
      end
      if n == 4 then
        assert_true(boxes[3].z1 < boxes[1].z0, "second band lies beyond the first")
        local _, _, d = Spawn.pieceLayout()
        assert_true(boxes[4].z0 > -(Config.mat.depth / 2 + Config.tts.trayOffset) - 2 * d - 4, "two bands, not four")
      end
    end
    Events.settings.maxPlayers = 2
    seated = { "Red", "Blue" }
  end)

  it("a dropped piece is judged by the middle of its bounds, not its grab point", function()
    setup()
    local r = State.riders.Red
    r.pose = { x = 0, z = -10, heading = 0 }
    local o = tile("Red", "G1 Straight")
    local c = Geom.tileCenter("straight", 1, r.pose, "straight")
    o.pos = { c.x + 25, 2, c.z }                                   -- origin far away...
    o.getBounds = function() return { center = { x = c.x, y = 2, z = c.z } } end   -- ...but the piece sits right
    Events.handleDrop("Red", o)
    assert_eq(#State.riders.Red.trail.tiles, 1)
    assert_eq(o.returned, 1)
    o.getBounds = nil
  end)

  it("a returned piece goes back lying along +x", function()
    local o = tile("Blue", "G2 Hard Left")
    o.rot = nil
    Spawn.returnTile(o)
    assert_eq(o.rot[2], 90)
  end)
end)

describe("Calibration script tools/lua/piece_test.lua", function()
  it("runs in a context with no game globals and marks the exits Geom expects", function()
    local f = assert(io.open("tools/lua/piece_test.lua", "r"))
    local src = f:read("a"); f:close()
    local printed, spawned, markers = {}, {}, {}
    local env = {   -- only what TTS gives an execute-code script; NO Config, Geom, Spawn
      math = math, string = string, ipairs = ipairs, pairs = pairs, print = function(m) printed[#printed + 1] = m end,
      getObjectsWithTag = function() return {} end,
      spawnObjectData = function(p) spawned[#spawned + 1] = p.data end,
      spawnObject = function(p) markers[#markers + 1] = p.position end,
    }
    local chunk = assert(load(src, "piece_test", "t", env))
    chunk()
    assert_eq(#spawned, 4)
    assert_eq(#markers, 4)
    local cases = {
      { "tile_g3_soft_right", "right", 3, "soft" }, { "tile_g3_soft_left", "left", 3, "soft" },
      { "tile_g2_hard_right", "right", 2, "hard" }, { "tile_g2_straight", "straight", 2, "straight" },
    }
    for i, c in ipairs(cases) do
      local d = spawned[i]
      assert_eq(d.Nickname, c[1])
      assert_eq(d.CustomMesh.MeshURL, Config.tts.pieceModels.base .. c[1] .. ".obj", "same URLs the game uses")
      local entry = { x = d.Transform.posX, z = d.Transform.posZ, heading = d.Transform.rotY }
      local _, exit = Geom.tilePath(c[2], c[3], entry, c[4])
      assert_near(markers[i][1], exit.x, 1e-9, c[1] .. " exit x")
      assert_near(markers[i][3], exit.z, 1e-9, c[1] .. " exit z")
      assert_near(d.Transform.posY, Config.tts.tableY + Config.tts.matThickness, 1e-9)
    end
  end)
end)
