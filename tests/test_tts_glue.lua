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
  function o.setRotation() end
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
    assert_eq(count("gc_visual"), 1 + 1 + Config.prizmsOnTable)
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
    assert_eq(count("gc_trail_Yellow"), 1 + 2, "wall segment + joint divider + gear plate")
    assert_eq(count("gc_rider_Yellow"), 1)
  end)

  it("shift is applied once then resets", function()
    Events.setShift("Yellow", 1)
    assert_eq(Events.pendingShift, 1)
    Events.commitMove("Yellow", "straight")
    assert_eq(Events.pendingShift, 0)
    assert_eq(State.riders.Yellow.gear, 2)
  end)

  it("a crash clears the trail objects", function()
    State.riders.Yellow.pose = { x = 0, z = Config.mat.depth / 2, heading = 0 }
    Events.commitMove("Yellow", "straight")
    assert_eq(count("gc_trail_Yellow"), 0)
    assert_eq(count("gc_rider_Yellow"), 1)
  end)

  it("capture removes the Prizm and adds a marker", function()
    State.riders.Yellow.pose = { x = 0, z = -10, heading = 0 }
    State.riders.Yellow.gear = 1
    State.prizms = { { id = 50, a = { x = -1, z = -9 }, b = { x = 1, z = -9 } } }
    Spawn.prizm(State.prizms[1])
    Events.commitMove("Yellow", "straight")
    assert_eq(count("gc_prizm_50"), 0)
    assert_eq(count("gc_marker_1"), 1)
    assert_eq(State.riders.Yellow.prizms, 1)
  end)

  it("restore rebuilds visuals from a copy of the saved state", function()
    State = deepcopy(State)
    Events.restore()
    assert_eq(count("gc_mat"), 1)
    assert_eq(count("gc_marker_1"), 1)
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

  it("a crash also passes the turn", function()
    State.riders.Blue.pose = { x = 0, z = Config.mat.depth / 2, heading = 0 }
    Events.commitMove("Blue", "straight")
    assert_eq(Rules.currentColor(State), "Red")
  end)

  it("a win freezes the game until New game", function()
    State.riders.Red.pose = { x = 0, z = -10, heading = 0 }
    State.riders.Red.gear = 1
    State.riders.Red.prizms = Config.prizmsToWin - 1
    State.prizms = { { id = 60, a = { x = -1, z = -9 }, b = { x = 1, z = -9 } } }
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

  local function drop(color, gear, kind, label, dx)
    local o = tile(color, gear, label)
    local c = Geom.tileCenter(kind, gear, State.riders[color].pose)
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
    assert_eq(#getObjectsWithTag("gc_tile"), 2 * 15)
    assert_eq(#getObjectsWithTag("gc_tray_Red"), 16)
    assert_true(uiText.gcOdds_Red:find("Drag a tile", 1, true) ~= nil)
    assert_eq(attrs["gcb_Red_straight.interactable"], "false")
  end)

  it("name parsing round-trips", function()
    local c, g, k = Spawn.parseTileName("Red G3 Left")
    assert_eq(c, "Red"); assert_eq(g, 3); assert_eq(k, "left")
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
    local o = drop("Blue", 1, "left", "Left")
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

describe("Tile labels (stubbed)", function()
  it("each laid tile gets a divider and a plate showing its gear", function()
    seated = { "Red" }
    Events.newGame()
    State.riders.Red.pose = { x = 0, z = 0, heading = 0 }
    State.prizms = {}
    Events.setShift("Red", 1)
    Events.commitMove("Red", "straight")        -- G2
    local plate
    for _, o in ipairs(getObjectsWithTag("gc_trail_Red")) do
      if o.name == "Red G2" then plate = o end
    end
    assert_true(plate ~= nil, "plate named by gear")
    assert_eq(plate.button.label, "2")
    assert_eq(plate.button.click_function, "gcNoop")
    local found = false
    for _, o in ipairs(getObjectsWithTag("gc_trail_Red")) do
      if o.name == "Red tile joint" then found = true end
    end
    assert_true(found, "joint divider")
  end)
  it("walls are three times the old height", function()
    assert_near(Config.tts.trailHeight, 0.36)
  end)
  it("rebuild after load puts the right gear on each plate", function()
    local saved = deepcopy(State)
    State = saved
    Events.restore()
    local n = 0
    for _, o in ipairs(getObjectsWithTag("gc_trail_Red")) do
      if o.button then n = n + 1; assert_eq(o.button.label, "2") end
    end
    assert_eq(n, 1)
  end)
end)

describe("Tile supply (stubbed)", function()
  it("a placed tile uses one from its gear; the panel shows what is left", function()
    seated = { "Red" }
    Events.newGame()
    State.prizms = {}
    Events.commitMove("Red", "straight")
    assert_eq(State.riders.Red.supply[1], Config.tileSupply[1] - 1)
    assert_true(uiText.gcSupply_Red:find("G1:" .. (Config.tileSupply[1] - 1)) ~= nil)
  end)
  it("an empty gear is refused with a private message and the turn is kept", function()
    State.riders.Red.supply[1] = 0
    local tiles = #State.riders.Red.trail.tiles
    Events.commitMove("Red", "straight")
    assert_eq(#State.riders.Red.trail.tiles, tiles)
    assert_true(private[#private].msg:find("no G1 tiles left") ~= nil)
    assert_eq(Rules.currentColor(State), "Red")
  end)
  it("shift buttons for an empty gear are disabled", function()
    State.riders.Red.supply[2] = 0
    UI_.refresh()
    assert_eq(attrs["gcb_Red_shiftup.interactable"], "false")
    assert_eq(attrs["gcb_Red_shifthold.interactable"], "false")   -- G1 is empty too
  end)
end)
