-- Rules tests. Use a fixed rollFn for determinism.
local function fixed(v) return function() return v end end

-- Sequence roller: returns the listed values in order, then repeats the last.
local function seq(...)
  local vals, i = { ... }, 0
  return function()
    i = math.min(i + 1, #vals)
    return vals[i]
  end
end

-- Deterministic state: Red at the origin heading +z, no Prizms unless given.
local function newState(prizms)
  local st = Rules.newState({ "Red", "Blue" }, fixed(3))
  st.riders.Red.pose = { x = 0, z = -10, heading = 0 }
  st.riders.Blue.pose = { x = 10, z = 10, heading = 180 }
  st.prizms = prizms or {}
  st.nextPrizmId = 100
  return st
end

describe("Rules.newState", function()
  it("creates a rider per colour at gear 1 on the mat edge", function()
    local st = Rules.newState({ "Red", "Blue", "Green" }, function(n) return math.random(n) end)
    assert_eq(#st.order, 3)
    for _, c in ipairs(st.order) do
      local r = st.riders[c]
      assert_eq(r.gear, 1)
      assert_eq(r.prizms, 0)
      local hw, hd = Config.mat.width / 2, Config.mat.depth / 2
      assert_true(math.abs(r.pose.x) == hw or math.abs(r.pose.z) == hd, "launch on edge")
    end
  end)
  it("scatters Config.prizmsOnTable Prizms inside the mat", function()
    local st = Rules.newState({ "Red" }, function(n) return math.random(n) end)
    assert_eq(#st.prizms, Config.prizmsOnTable)
    for _, p in ipairs(st.prizms) do
      assert_true(Geom.inBounds({ p }, Config.mat))
    end
  end)
  it("is deterministic for the same rolls", function()
    local a = Rules.newState({ "Red" }, fixed(7))
    local b = Rules.newState({ "Red" }, fixed(7))
    assert_eq(a.riders.Red.pose.x, b.riders.Red.pose.x)
    assert_eq(#a.prizms, #b.prizms)
  end)
end)

describe("Rules.resolveMove", function()
  it("shift clamps to gear range and maxShift", function()
    local st = newState()
    st.riders.Red.gear = 5
    local r = Rules.resolveMove(st, "Red", { shift = 1, kind = "straight" }, fixed(3))
    assert_eq(r.gear, 5, "cannot exceed max gear")
    st = newState()
    r = Rules.resolveMove(st, "Red", { shift = -1, kind = "straight" }, fixed(3))
    assert_eq(r.gear, 1, "cannot go below min gear")
    st = newState()
    r = Rules.resolveMove(st, "Red", { shift = 3, kind = "straight" }, fixed(3))
    assert_eq(r.gear, 2, "shift limited to maxShift")
  end)

  it("straight moves the pose forward by the gear length", function()
    local st = newState()
    local r = Rules.resolveMove(st, "Red", { shift = 0, kind = "straight" }, fixed(3))
    assert_eq(r.outcome, "placed")
    assert_near(st.riders.Red.pose.z, -10 + Config.tiles[1].straight)
    assert_eq(#st.riders.Red.trail.tiles, 1)
    assert_eq(r.roll, nil, "straight does not roll")
  end)

  it("curve succeeds when roll >= gear", function()
    local st = newState()
    st.riders.Red.gear = 3
    local r = Rules.resolveMove(st, "Red", { shift = 0, kind = "right" }, fixed(3))
    assert_eq(r.kind, "right")
    assert_false(r.wentStraight)
    assert_near(st.riders.Red.pose.heading, Config.tiles[3].sweep)
  end)

  it("failed curve goes straight", function()
    local st = newState()
    st.riders.Red.gear = 3
    local r = Rules.resolveMove(st, "Red", { shift = 0, kind = "left" }, fixed(2))
    assert_eq(r.kind, "straight")
    assert_true(r.wentStraight)
    assert_near(st.riders.Red.pose.heading, 0)
    assert_eq(r.gear, 3, "gear unchanged on failed curve")
  end)

  it("spin-out at high gear curves and drops to gear 1", function()
    local st = newState()
    st.riders.Red.gear = 4
    local r = Rules.resolveMove(st, "Red", { shift = 0, kind = "right" }, fixed(1))
    assert_true(r.spunOut)
    assert_eq(r.kind, "right")
    assert_eq(r.gear, 1)
    assert_eq(st.riders.Red.gear, 1)
    assert_near(st.riders.Red.pose.heading, Config.tiles[4].sweep)
  end)

  it("a natural 1 below the spin-out gear just fails the curve", function()
    local st = newState()
    st.riders.Red.gear = 3
    local r = Rules.resolveMove(st, "Red", { shift = 0, kind = "right" }, fixed(1))
    assert_false(r.spunOut)
    assert_true(r.wentStraight)
  end)

  it("shift happens before the turn check uses the gear", function()
    local st = newState()
    st.riders.Red.gear = 3
    local r = Rules.resolveMove(st, "Red", { shift = 1, kind = "right" }, fixed(3))
    assert_true(r.wentStraight, "roll 3 < new gear 4")
    assert_eq(r.gear, 4)
  end)

  it("crash by leaving the mat resets trail, respawns at gear 1, keeps Prizms", function()
    local st = newState()
    local red = st.riders.Red
    red.pose = { x = 0, z = 17, heading = 0 }
    red.gear = 3
    red.prizms = 2
    red.trail.segs = { { a = { x = 0, z = 10 }, b = { x = 0, z = 17 } } }
    local r = Rules.resolveMove(st, "Red", { shift = 0, kind = "straight" }, fixed(3))
    assert_eq(r.outcome, "crash")
    assert_eq(r.crashReason, "bounds")
    assert_eq(#red.trail.segs, 0)
    assert_eq(#red.trail.tiles, 0)
    assert_eq(red.gear, 1)
    assert_eq(red.prizms, 2)
    assert_true(r.respawn ~= nil)
  end)

  it("crash by hitting an opponent trail", function()
    local st = newState()
    st.riders.Blue.trail.segs = { { a = { x = -3, z = -9 }, b = { x = 3, z = -9 } } }
    local r = Rules.resolveMove(st, "Red", { shift = 0, kind = "straight" }, fixed(3))
    assert_eq(r.outcome, "crash")
    assert_eq(r.crashReason, "trail")
    assert_eq(#st.riders.Blue.trail.segs, 1, "opponent trail untouched")
  end)

  it("crash by hitting your own older trail", function()
    local st = newState()
    st.riders.Red.trail.segs = { { a = { x = -3, z = -9 }, b = { x = 3, z = -9 } } }
    local r = Rules.resolveMove(st, "Red", { shift = 0, kind = "straight" }, fixed(3))
    assert_eq(r.outcome, "crash")
  end)

  it("hitting a capture marker crashes", function()
    local st = newState()
    st.markers = { { owner = "Blue", segs = { { a = { x = -1, z = -9 }, b = { x = 1, z = -9 } } } } }
    local r = Rules.resolveMove(st, "Red", { shift = 0, kind = "straight" }, fixed(3))
    assert_eq(r.outcome, "crash")
  end)

  it("consecutive tiles do not crash on their own shared joint", function()
    local st = newState()
    for _, k in ipairs({ "straight", "right", "straight", "left", "straight" }) do
      local r = Rules.resolveMove(st, "Red", { shift = 0, kind = k }, fixed(6))
      assert_eq(r.outcome, "placed", "tile " .. k)
    end
    assert_eq(#st.riders.Red.trail.tiles, 5)
  end)

  it("capturing a Prizm credits the rider, drops a marker and spawns a replacement", function()
    local st = newState({ { id = 7, a = { x = -1, z = -9 }, b = { x = 1, z = -9 } } })
    local r = Rules.resolveMove(st, "Red", { shift = 0, kind = "straight" }, function(n) return math.random(n) end)
    assert_eq(r.outcome, "placed")
    assert_eq(#r.captured, 1)
    assert_eq(r.captured[1], 7)
    assert_eq(st.riders.Red.prizms, 1)
    assert_eq(#st.markers, 1)
    assert_eq(st.markers[1].owner, "Red")
    assert_eq(#st.prizms, 1, "replacement spawned")
    assert_eq(#r.spawned, 1)
    assert_eq(st.prizms[1].id, 100)
  end)

  it("a Prizm the tile only ends on is not captured", function()
    local z = -10 + Config.tiles[1].straight
    local st = newState({ { id = 7, a = { x = -1, z = z }, b = { x = 1, z = z } } })
    local r = Rules.resolveMove(st, "Red", { shift = 0, kind = "straight" }, fixed(3))
    assert_eq(#r.captured, 0)
    assert_eq(#st.prizms, 1)
  end)

  it("a crash does not capture Prizms on the failed path", function()
    local st = newState({ { id = 7, a = { x = -1, z = -9 }, b = { x = 1, z = -9 } } })
    st.riders.Blue.trail.segs = { { a = { x = -3, z = -9.5 }, b = { x = 3, z = -9.5 } } }
    local r = Rules.resolveMove(st, "Red", { shift = 0, kind = "straight" }, fixed(3))
    assert_eq(r.outcome, "crash")
    assert_eq(st.riders.Red.prizms, 0)
    assert_eq(#st.prizms, 1)
  end)

  it("capturing the final Prizm returns outcome 'win'", function()
    local st = newState({ { id = 7, a = { x = -1, z = -9 }, b = { x = 1, z = -9 } } })
    st.riders.Red.prizms = Config.prizmsToWin - 1
    local r = Rules.resolveMove(st, "Red", { shift = 0, kind = "straight" }, fixed(3))
    assert_eq(r.outcome, "win")
    assert_eq(st.riders.Red.prizms, Config.prizmsToWin)
  end)

  it("state survives a JSON-style deep copy (no functions or cycles)", function()
    local st = newState()
    Rules.resolveMove(st, "Red", { shift = 0, kind = "right" }, fixed(6))
    local function check(t, seen)
      assert_true(type(t) ~= "function" and type(t) ~= "userdata")
      if type(t) == "table" then
        assert_false(seen[t], "cycle")
        seen[t] = true
        for _, v in pairs(t) do check(v, seen) end
        seen[t] = nil
      end
    end
    check(st, {})
  end)
end)

describe("Rules simulation", function()
  it("random full games never error and always keep riders in bounds", function()
    math.randomseed(12345)
    local rf = function(n) return math.random(n) end
    local kinds = { "straight", "left", "right" }
    for _ = 1, 30 do
      local st = Rules.newState({ "Red", "Blue", "Green", "Yellow" }, rf)
      for turn = 1, 300 do
        local c = st.order[(turn - 1) % 4 + 1]
        local r = Rules.resolveMove(st, c, { shift = math.random(3) - 2, kind = kinds[math.random(3)] }, rf)
        if r.outcome == "win" then break end
        local p = st.riders[c].pose
        assert_true(math.abs(p.x) <= Config.mat.width / 2 + 1e-6 and math.abs(p.z) <= Config.mat.depth / 2 + 1e-6)
      end
    end
  end)
end)
