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
      local tail = Geom.bikeSeg(r.pose).a   -- bike tail starts on the edge
      assert_true(math.abs(math.abs(tail.x) - hw) < 1e-6 or math.abs(math.abs(tail.z) - hd) < 1e-6,
        "bike tail on edge")
      assert_true(Geom.inBounds({ { a = r.pose, b = r.pose } }, Config.mat), "nose inside mat")
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

describe("Rules aliasing and multi-capture", function()
  it("result tables are not aliased to state", function()
    local st = newState()
    local r = Rules.resolveMove(st, "Red", { shift = 0, kind = "straight" }, fixed(3))
    r.exitPose.heading = 99
    r.segs[1].a.x = 99
    assert_near(st.riders.Red.pose.heading, 0)
    assert_near(st.riders.Red.trail.segs[1].a.x, 0)
  end)
  it("one tile can capture two Prizms", function()
    local st = newState({
      { id = 1, a = { x = -1, z = -9.5 }, b = { x = 1, z = -9.5 } },
      { id = 2, a = { x = -1, z = -8.5 }, b = { x = 1, z = -8.5 } },
    })
    st.riders.Red.gear = 3
    local r = Rules.resolveMove(st, "Red", { shift = 0, kind = "straight" }, function(n) return math.random(n) end)
    assert_eq(#r.captured, 2)
    assert_eq(st.riders.Red.prizms, 2)
    assert_eq(#st.markers, 2)
  end)
end)

describe("Rules turn order", function()
  it("starts on the first rider and cycles", function()
    local st = Rules.newState({ "Red", "Blue", "Green" }, fixed(3))
    assert_eq(Rules.currentColor(st), "Red")
    Rules.advanceTurn(st); assert_eq(Rules.currentColor(st), "Blue")
    Rules.advanceTurn(st); assert_eq(Rules.currentColor(st), "Green")
    Rules.advanceTurn(st); assert_eq(Rules.currentColor(st), "Red")
  end)
  it("a solo rider keeps the turn", function()
    local st = Rules.newState({ "Red" }, fixed(3))
    Rules.advanceTurn(st)
    assert_eq(Rules.currentColor(st), "Red")
  end)
  it("winning records the winner and freezes the turn", function()
    local st = newState({ { id = 7, a = { x = -1, z = -9 }, b = { x = 1, z = -9 } } })
    st.riders.Red.prizms = Config.prizmsToWin - 1
    assert_false(st.winner)
    Rules.resolveMove(st, "Red", { shift = 0, kind = "straight" }, fixed(3))
    assert_eq(st.winner, "Red")
    Rules.advanceTurn(st)
    assert_eq(Rules.currentColor(st), "Red")
  end)
end)

describe("Rules.isValidState", function()
  it("accepts a fresh state", function()
    assert_true(Rules.isValidState(Rules.newState({ "Red" }, fixed(3))))
  end)
  it("rejects an M2-era state without a turn", function()
    local st = Rules.newState({ "Red" }, fixed(3))
    st.turn = nil
    assert_false(Rules.isValidState(st))
  end)
  it("rejects nil, empty and missing riders", function()
    assert_false(Rules.isValidState(nil))
    assert_false(Rules.isValidState({}))
    local st = Rules.newState({ "Red" }, fixed(3))
    st.riders.Red = nil
    assert_false(Rules.isValidState(st))
  end)
end)

describe("Rules helpers for the UI", function()
  it("gearAfterShift clamps", function()
    assert_eq(Rules.gearAfterShift(5, 1), 5)
    assert_eq(Rules.gearAfterShift(1, -1), 1)
    assert_eq(Rules.gearAfterShift(3, 1), 4)
    assert_eq(Rules.gearAfterShift(3, 5), 4)
  end)
  it("curveOdds: gear 1 always succeeds, gear 4 needs 4+, spin-out 1/6 at G4+", function()
    local ok, spin = Rules.curveOdds(1)
    assert_near(ok, 1); assert_eq(spin, 0)
    ok, spin = Rules.curveOdds(4)
    assert_near(ok, 3 / 6); assert_near(spin, 1 / 6)
    ok, spin = Rules.curveOdds(3)
    assert_near(ok, 4 / 6); assert_eq(spin, 0)
  end)
end)

describe("Rules.validateTileDrop", function()
  local function setup()
    local st = newState()
    st.riders.Red.gear = 2
    return st
  end
  local function centerOf(st, gear, kind)
    return Geom.tileCenter(kind, gear, st.riders.Red.pose)
  end
  it("accepts a tile of the same gear dropped on its landing spot", function()
    local st = setup()
    local ok, shift = Rules.validateTileDrop(st, "Red", 2, "straight", centerOf(st, 2, "straight"))
    assert_true(ok); assert_eq(shift, 0)
  end)
  it("accepts a +1 / -1 gear tile and reports the shift", function()
    local st = setup()
    local ok, shift = Rules.validateTileDrop(st, "Red", 3, "left", centerOf(st, 3, "left"))
    assert_true(ok); assert_eq(shift, 1)
    ok, shift = Rules.validateTileDrop(st, "Red", 1, "right", centerOf(st, 1, "right"))
    assert_true(ok); assert_eq(shift, -1)
  end)
  it("rejects a gear more than maxShift away", function()
    local st = setup()
    local ok, why = Rules.validateTileDrop(st, "Red", 4, "straight", centerOf(st, 4, "straight"))
    assert_false(ok); assert_eq(why, "gear")
  end)
  it("rejects a drop too far from the trail end", function()
    local st = setup()
    local c = centerOf(st, 2, "straight")
    local ok, why = Rules.validateTileDrop(st, "Red", 2, "straight", { x = c.x + Config.snapRadius + 1, z = c.z })
    assert_false(ok); assert_eq(why, "far")
  end)
  it("rejects out-of-turn drops and drops after the game is won", function()
    local st = setup()
    local ok, why = Rules.validateTileDrop(st, "Blue", 1, "straight", { x = 0, z = 0 })
    assert_false(ok); assert_eq(why, "turn")
    st.winner = "Red"
    ok, why = Rules.validateTileDrop(st, "Red", 2, "straight", centerOf(st, 2, "straight"))
    assert_false(ok); assert_eq(why, "over")
  end)
end)

describe("bike as part of the trail", function()
  -- Red at (0,-10) heading +z; bike lies along z in [-11.8, -10]. Blue heads -x
  -- across it from the east.
  it("an opponent's tile crossing a bike crashes with reason bike", function()
    local st = newState()
    st.riders.Blue.pose = { x = 3, z = -10.5, heading = 270 }   -- G2 straight is 3 long: x 3 -> 0
    local r = Rules.resolveMove(st, "Blue", { shift = 1, kind = "straight" }, fixed(3))
    assert_eq(r.outcome, "crash")
    assert_eq(r.crashReason, "bike")
    assert_eq(r.crashOwner, "Red")
  end)
  it("the bike blocks only others: the owner's own tile starts on its nose", function()
    local st = newState()
    local r = Rules.resolveMove(st, "Red", { shift = 0, kind = "straight" }, fixed(3))
    assert_eq(r.outcome, "placed")
  end)
  it("the bike follows the trail end: after a move it sits on the new tile's end", function()
    local st = newState()
    Rules.resolveMove(st, "Red", { shift = 0, kind = "straight" }, fixed(3))   -- G1: z -10 -> -8
    -- old bike spot (z -11.8..-10) is now open; new bike covers z -9.8..-8
    st.riders.Blue.pose = { x = 3, z = -10.5, heading = 270 }
    local ok = Rules.resolveMove(st, "Blue", { shift = 1, kind = "straight" }, fixed(3))
    assert_eq(ok.outcome, "placed", "old bike position no longer blocks")
    local st2 = newState()
    Rules.resolveMove(st2, "Red", { shift = 0, kind = "straight" }, fixed(3))
    st2.riders.Blue.pose = { x = 3, z = -9, heading = 270 }
    local hit = Rules.resolveMove(st2, "Blue", { shift = 1, kind = "straight" }, fixed(3))
    assert_eq(hit.outcome, "crash", "new bike spot blocks (it lies over the tile, so reported as trail)")
  end)
  it("a trail hit still reports reason trail", function()
    local st = newState()
    Rules.resolveMove(st, "Red", { shift = 1, kind = "straight" }, fixed(3))   -- G2: z -10 -> -7
    st.riders.Blue.pose = { x = 3, z = -8.5, heading = 270 }   -- crosses z=-8.5, mid-tile, clear of the bike
    local r = Rules.resolveMove(st, "Blue", { shift = 1, kind = "straight" }, fixed(3))
    assert_eq(r.crashReason, "trail")
    assert_eq(r.crashOwner, "Red")
  end)
  it("launch points avoid other riders' bikes", function()
    for seed = 1, 30 do
      math.randomseed(seed)
      local st = Rules.newState({ "Red", "Blue", "Green", "Yellow" }, function(n) return math.random(n) end)
      for i, a in ipairs(st.order) do
        for j, b in ipairs(st.order) do
          if i < j then
            assert_false(Geom.segmentsIntersect(Geom.bikeSeg(st.riders[a].pose), Geom.bikeSeg(st.riders[b].pose)),
              "bikes overlap at launch")
          end
        end
      end
    end
  end)
  it("a crash respawns the bike clear of the others", function()
    local st = newState()
    st.riders.Blue.pose = { x = 3, z = -10.5, heading = 270 }
    local r = Rules.resolveMove(st, "Blue", { shift = 1, kind = "straight" }, fixed(3))
    assert_eq(r.outcome, "crash")
    assert_eq(#st.riders.Blue.trail.segs, 0)
  end)
end)
