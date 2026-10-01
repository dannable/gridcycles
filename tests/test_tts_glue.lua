-- Smoke test of src/tts/* against stubbed TTS APIs. Verifies the glue runs and
-- mirrors Rules results onto "objects"; it cannot verify real TTS behaviour.
local live = {}   -- all stub objects not yet destructed
local uiText = {}
local broadcasts = {}

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
UI = { setValue = function(id, v) uiText[id] = v end }
function broadcastToAll(msg) broadcasts[#broadcasts + 1] = msg end
Wait = { time = function(f) f() end }

dofile("src/tts/spawn.lua")
dofile("src/tts/ui.lua")
dofile("src/tts/events.lua")

local function count(tag) return #getObjectsWithTag(tag) end

describe("TTS glue (stubbed)", function()
  it("newGame spawns mat, rider and Prizms", function()
    Events.newGame()
    assert_eq(count("gc_mat"), 1)
    assert_eq(count("gc_rider_Red"), 1)
    assert_eq(count("gc_visual"), 1 + 1 + Config.prizmsOnTable)
    assert_true(uiText.gcStatus:find("Gear 1") ~= nil)
  end)

  it("a placed move adds trail blocks and moves the rider mini", function()
    State.riders.Red.pose = { x = 0, z = 0, heading = 0 }
    State.prizms = {}
    Events.commitMove("straight")
    assert_eq(count("gc_trail_Red"), 1)
    assert_eq(count("gc_rider_Red"), 1)
  end)

  it("shift is applied once then resets", function()
    Events.setShift(1)
    assert_eq(Events.pendingShift, 1)
    Events.commitMove("straight")
    assert_eq(Events.pendingShift, 0)
    assert_eq(State.riders.Red.gear, 2)
  end)

  it("a crash clears the trail objects", function()
    State.riders.Red.pose = { x = 0, z = Config.mat.depth / 2, heading = 0 }
    Events.commitMove("straight")
    assert_eq(count("gc_trail_Red"), 0)
    assert_eq(count("gc_rider_Red"), 1)
  end)

  it("capture removes the Prizm, adds a marker and a replacement", function()
    State.riders.Red.pose = { x = 0, z = -10, heading = 0 }
    State.riders.Red.gear = 1
    State.prizms = { { id = 50, a = { x = -1, z = -9 }, b = { x = 1, z = -9 } } }
    Spawn.prizm(State.prizms[1])
    Events.commitMove("straight")
    assert_eq(count("gc_prizm_50"), 0)
    assert_eq(count("gc_marker_1"), 1)
    assert_eq(State.riders.Red.prizms, 1)
  end)

  it("restore rebuilds visuals from state", function()
    local trails = #State.riders.Red.trail.tiles
    Events.restore()
    assert_eq(count("gc_trail_Red") > 0, trails > 0)
    assert_eq(count("gc_mat"), 1)
    assert_eq(count("gc_marker_1"), 1)
  end)
end)
