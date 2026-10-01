-- Smoke test of src/tts/* against stubbed TTS APIs. Verifies the glue runs and
-- mirrors Rules results onto "objects"; it cannot verify real TTS behaviour.
local live = {}   -- all stub objects not yet destructed
local uiText = {}
local broadcasts = {}
local private = {}
local seated = { "White" }

local function makeObj(params)
  local o = { params = params, tags = {} }
  function o.setColorTint() end
  function o.setLock() end
  function o.setName() end
  function o.addTag(t) o.tags[t] = true end
  function o.destruct() o.dead = true end
  live[#live + 1] = o
  if params.callback_function then params.callback_function(o) end
  return o
end

function spawnObject(params) return makeObj(params) end
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
Player = { getPlayers = function()
  local out = {}
  for _, c in ipairs(seated) do out[#out + 1] = { color = c, seated = true } end
  return out
end }

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
    seated = { "White" }
    Events.newGame()
    assert_eq(#State.order, 1)
    assert_eq(State.order[1], "White")
    assert_eq(count("gc_mat"), 1)
    assert_eq(count("gc_rider_White"), 1)
    assert_eq(count("gc_visual"), 1 + 1 + Config.prizmsOnTable)
    assert_true(uiText.gcStatus:find("White's turn") ~= nil)
    assert_eq(Turns.turn_color, "White")
  end)

  it("nobody seated falls back to a solo Red sandbox", function()
    seated = {}
    Events.newGame()
    assert_eq(State.order[1], "Red")
    seated = { "White" }
    Events.newGame()
  end)

  it("a placed move adds trail blocks and moves the rider mini", function()
    State.riders.White.pose = { x = 0, z = 0, heading = 0 }
    State.prizms = {}
    Events.commitMove("White", "straight")
    assert_eq(count("gc_trail_White"), 1)
    assert_eq(count("gc_rider_White"), 1)
  end)

  it("shift is applied once then resets", function()
    Events.setShift("White", 1)
    assert_eq(Events.pendingShift, 1)
    Events.commitMove("White", "straight")
    assert_eq(Events.pendingShift, 0)
    assert_eq(State.riders.White.gear, 2)
  end)

  it("a crash clears the trail objects", function()
    State.riders.White.pose = { x = 0, z = Config.mat.depth / 2, heading = 0 }
    Events.commitMove("White", "straight")
    assert_eq(count("gc_trail_White"), 0)
    assert_eq(count("gc_rider_White"), 1)
  end)

  it("capture removes the Prizm and adds a marker", function()
    State.riders.White.pose = { x = 0, z = -10, heading = 0 }
    State.riders.White.gear = 1
    State.prizms = { { id = 50, a = { x = -1, z = -9 }, b = { x = 1, z = -9 } } }
    Spawn.prizm(State.prizms[1])
    Events.commitMove("White", "straight")
    assert_eq(count("gc_prizm_50"), 0)
    assert_eq(count("gc_marker_1"), 1)
    assert_eq(State.riders.White.prizms, 1)
  end)

  it("restore rebuilds visuals from a copy of the saved state", function()
    State = deepcopy(State)
    Events.restore()
    assert_eq(count("gc_mat"), 1)
    assert_eq(count("gc_marker_1"), 1)
    assert_eq(count("gc_rider_White"), 1)
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
