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
-- No rider abilities (tests/test_riders.lua covers those).
local function newState(prizms)
  local st = Rules.newState({ "Red", "Blue" }, fixed(3))
  st.riders.Red.ability, st.riders.Blue.ability = nil, nil
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
      assert_eq(Rules.prizmCount(st, c), 0)
      local hw, hd = Config.mat.width / 2, Config.mat.depth / 2
      local tail = Geom.bikeSeg(r.pose).a   -- bike tail starts on the edge
      assert_true(math.abs(math.abs(tail.x) - hw) < 1e-6 or math.abs(math.abs(tail.z) - hd) < 1e-6,
        "bike tail on edge")
      assert_true(Geom.inBounds({ { a = r.pose, b = r.pose } }, Config.mat), "nose inside mat")
    end
  end)
  it("starts with one unscored Prizm per rider, evenly spaced on a ring round the centre", function()
    for n = 1, 4 do
      local colors = { "Red", "Blue", "Green", "Yellow" }
      local list = {}
      for i = 1, n do list[i] = colors[i] end
      local st = Rules.newState(list, function(k) return math.random(k) end)
      assert_eq(#st.prizms, n * Config.neutralPrizmsPerPlayer)
      for _, p in ipairs(st.prizms) do
        assert_eq(p.owner, nil, "unscored")
        assert_true(Geom.inBounds({ p }, Config.mat))
        local cx, cz = (p.a.x + p.b.x) / 2, (p.a.z + p.b.z) / 2
        assert_near(math.sqrt(cx * cx + cz * cz), Config.prizmRingRadius, 1e-6)
      end
      if n >= 2 then
        for i = 1, n do
          for j = i + 1, n do
            local pi, pj = st.prizms[i], st.prizms[j]
            local d = Geom.distance({ x = (pi.a.x + pi.b.x) / 2, z = (pi.a.z + pi.b.z) / 2 },
              { x = (pj.a.x + pj.b.x) / 2, z = (pj.a.z + pj.b.z) / 2 })
            assert_true(d >= Config.tiles[3].straight, "no closer than a gear 3 straight")
          end
        end
      end
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
    assert_near(st.riders.Red.pose.heading, Config.tiles[3].soft.sweep)
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

  it("the spin-out face curves and drops to gear 1", function()
    local st = newState()
    st.riders.Red.gear = 4
    local r = Rules.resolveMove(st, "Red", { shift = 0, kind = "right" }, fixed(Config.turnCheck.die))
    assert_true(r.spunOut)
    assert_eq(r.kind, "right")
    assert_eq(r.gear, 1)
    assert_eq(st.riders.Red.gear, 1)
    assert_near(st.riders.Red.pose.heading, Config.tiles[4].soft.sweep)
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
    st.prizms = {
      { id = 1, owner = "Red", a = { x = -9, z = 0 }, b = { x = -8, z = 0 } },
      { id = 2, owner = "Red", a = { x = 9, z = 0 }, b = { x = 8, z = 0 } },
    }
    red.trail.segs = { { a = { x = 0, z = 10 }, b = { x = 0, z = 17 } } }
    local r = Rules.resolveMove(st, "Red", { shift = 0, kind = "straight" }, fixed(3))
    assert_eq(r.outcome, "crash")
    assert_eq(r.crashReason, "bounds")
    assert_eq(#red.trail.segs, 0)
    assert_eq(#red.trail.tiles, 0)
    assert_eq(red.gear, 1)
    assert_eq(Rules.prizmCount(st, "Red"), 2, "scored Prizms stay on the table")
    assert_true(r.respawn ~= nil)
  end)

  it("crash by hitting an opponent trail", function()
    local st = newState()
    st.riders.Blue.trail.segs = { { a = { x = -3, z = -9 }, b = { x = 3, z = -9 } } }
    local r = Rules.resolveMove(st, "Red", { shift = 0, kind = "straight" }, fixed(3))
    assert_eq(r.outcome, "crash")
    assert_eq(r.crashReason, "trail")
    assert_eq(#st.riders.Blue.trail.segs, 1, "opponent trail untouched")
    assert_eq(r.victim, nil, "a wall with no tile record costs its owner nothing")
  end)

  it("crash by hitting your own older trail", function()
    local st = newState()
    st.riders.Red.trail.segs = { { a = { x = -3, z = -9 }, b = { x = 3, z = -9 } } }
    local r = Rules.resolveMove(st, "Red", { shift = 0, kind = "straight" }, fixed(3))
    assert_eq(r.outcome, "crash")
  end)

  it("consecutive tiles do not crash on their own shared joint", function()
    local st = newState()
    st.riders.Red.gear = 3
    for _, k in ipairs({ "straight", "right", "straight", "left", "straight" }) do
      local r = Rules.resolveMove(st, "Red", { shift = 0, kind = k }, fixed(5))
      assert_eq(r.outcome, "placed", "tile " .. k)
    end
    assert_eq(#st.riders.Red.trail.tiles, 5)
  end)

  it("crossing an unscored Prizm scores it: it takes your colour, stays put, and a new one is tossed", function()
    local st = newState({ { id = 7, a = { x = -1, z = -9 }, b = { x = 1, z = -9 } } })
    local r = Rules.resolveMove(st, "Red", { shift = 0, kind = "straight" }, function(n) return math.random(n) end)
    assert_eq(r.outcome, "placed")
    assert_eq(#r.scored, 1)
    assert_eq(r.scored[1], 7)
    assert_eq(Rules.prizmCount(st, "Red"), 1)
    assert_eq(st.prizms[1].id, 7)
    assert_eq(st.prizms[1].owner, "Red")
    assert_near(st.prizms[1].a.z, -9, 1e-9)
    assert_eq(#st.prizms, 2, "scored one stays, replacement added")
    assert_eq(#r.spawned, 1)
    assert_eq(st.prizms[2].id, 100)
    assert_eq(st.prizms[2].owner, nil)
  end)

  it("a Prizm the tile only ends on is not scored (it is nudged clear instead)", function()
    local z = -10 + Config.tiles[1].straight
    local st = newState({ { id = 7, a = { x = -1, z = z }, b = { x = 1, z = z } } })
    local r = Rules.resolveMove(st, "Red", { shift = 0, kind = "straight" }, fixed(3))
    assert_eq(#r.scored, 0)
    assert_eq(st.prizms[1].owner, nil)
  end)

  it("a crash does not score Prizms on the failed path", function()
    local st = newState({ { id = 7, a = { x = -1, z = -9 }, b = { x = 1, z = -9 } } })
    st.riders.Blue.trail.segs = { { a = { x = -3, z = -9.5 }, b = { x = 3, z = -9.5 } } }
    local r = Rules.resolveMove(st, "Red", { shift = 0, kind = "straight" }, fixed(3))
    assert_eq(r.outcome, "crash")
    assert_eq(Rules.prizmCount(st, "Red"), 0)
    assert_eq(st.prizms[1].owner, nil)
  end)

  it("holding the target number of your colour wins immediately", function()
    local st = newState({
      { id = 7, a = { x = -1, z = -9 }, b = { x = 1, z = -9 } },
      { id = 8, owner = "Red", a = { x = -9, z = 0 }, b = { x = -8, z = 0 } },
      { id = 9, owner = "Red", a = { x = 9, z = 0 }, b = { x = 8, z = 0 } },
    })
    local r = Rules.resolveMove(st, "Red", { shift = 0, kind = "straight" }, fixed(3))
    assert_eq(r.outcome, "win")
    assert_eq(Rules.prizmCount(st, "Red"), Config.prizmsToWin)
    assert_eq(st.winner, "Red")
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
  it("one tile can score two Prizms", function()
    local st = newState({
      { id = 1, a = { x = -1, z = -9.5 }, b = { x = 1, z = -9.5 } },
      { id = 2, a = { x = -1, z = -8.5 }, b = { x = 1, z = -8.5 } },
    })
    st.riders.Red.gear = 3
    local r = Rules.resolveMove(st, "Red", { shift = 0, kind = "straight" }, function(n) return math.random(n) end)
    assert_eq(#r.scored, 2)
    assert_eq(Rules.prizmCount(st, "Red"), 2)
    assert_eq(#r.spawned, 2, "one new unscored Prizm per Prizm scored")
  end)
end)

describe("Rules turn order", function()
  it("round 1 with everyone in the same gear follows seating order", function()
    local st = Rules.newState({ "Red", "Blue", "Green" }, fixed(3))
    assert_eq(Rules.currentColor(st), "Red")
    assert_false(Rules.advanceTurn(st)); assert_eq(Rules.currentColor(st), "Blue")
    assert_false(Rules.advanceTurn(st)); assert_eq(Rules.currentColor(st), "Green")
  end)
  it("after the last rider a new round starts and the tie-breaker moves on one seat", function()
    local st = Rules.newState({ "Red", "Blue", "Green" }, fixed(3))
    Rules.advanceTurn(st); Rules.advanceTurn(st)
    assert_true(Rules.advanceTurn(st), "new round")
    assert_eq(st.round, 2)
    assert_eq(table.concat(st.roundOrder, ","), "Blue,Green,Red")
    Rules.advanceTurn(st); Rules.advanceTurn(st)
    assert_true(Rules.advanceTurn(st))
    assert_eq(table.concat(st.roundOrder, ","), "Green,Red,Blue")
  end)
  it("the fastest gear goes first; ties go to whoever is nearest the tie-breaker", function()
    local st = Rules.newState({ "Red", "Blue", "Green" }, fixed(3))
    st.riders.Red.gear, st.riders.Blue.gear, st.riders.Green.gear = 1, 3, 3
    Rules.advanceTurn(st); Rules.advanceTurn(st); Rules.advanceTurn(st)
    assert_eq(table.concat(st.roundOrder, ","), "Blue,Green,Red", "tie-breaker on Blue")
    st.riders.Red.gear, st.riders.Blue.gear, st.riders.Green.gear = 2, 3, 3
    Rules.advanceTurn(st); Rules.advanceTurn(st); Rules.advanceTurn(st)
    assert_eq(table.concat(st.roundOrder, ","), "Green,Blue,Red", "tie-breaker on Green")
    st.riders.Red.gear, st.riders.Blue.gear, st.riders.Green.gear = 5, 3, 4
    Rules.advanceTurn(st); Rules.advanceTurn(st); Rules.advanceTurn(st)
    assert_eq(table.concat(st.roundOrder, ","), "Red,Green,Blue", "gear beats seat")
  end)
  it("the order is fixed for the round even if gears change during it", function()
    local st = Rules.newState({ "Red", "Blue" }, fixed(3))
    st.riders.Blue.gear = 5
    assert_eq(Rules.currentColor(st), "Red")
    Rules.advanceTurn(st)
    assert_eq(Rules.currentColor(st), "Blue")
  end)
  it("a solo rider keeps the turn and rounds still count", function()
    local st = Rules.newState({ "Red" }, fixed(3))
    assert_true(Rules.advanceTurn(st))
    assert_eq(Rules.currentColor(st), "Red")
    assert_eq(st.round, 2)
  end)
  it("winning records the winner and freezes the turn", function()
    local st = newState({
      { id = 7, a = { x = -1, z = -9 }, b = { x = 1, z = -9 } },
      { id = 8, owner = "Red", a = { x = -9, z = 0 }, b = { x = -8, z = 0 } },
      { id = 9, owner = "Red", a = { x = 9, z = 0 }, b = { x = 8, z = 0 } },
    })
    assert_false(st.winner)
    Rules.resolveMove(st, "Red", { shift = 0, kind = "straight" }, fixed(3))
    assert_eq(st.winner, "Red")
    assert_false(Rules.advanceTurn(st))
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
  it("rejects states from an older version", function()
    local st = Rules.newState({ "Red" }, fixed(3))
    st.version = nil
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
  it("curveOdds: faces 1-5 plus a spin-out face; success needs a numbered face >= gear", function()
    local ok, spin = Rules.curveOdds(1)
    assert_near(ok, 5 / 6); assert_near(spin, 1 / 6)
    ok, spin = Rules.curveOdds(4)
    assert_near(ok, 2 / 6); assert_near(spin, 1 / 6)
    ok, spin = Rules.curveOdds(5)
    assert_near(ok, 1 / 6); assert_near(spin, 1 / 6)
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

describe("tile supply", function()
  local function setup()
    return newState()
  end
  local function use(st, shift, kind, curve, roll)
    return Rules.resolveMove(st, "Red", { shift = shift, kind = kind, curve = curve }, fixed(roll or 5))
  end

  it("starts with the configured pieces per gear and shape", function()
    local st = setup()
    for g = 1, 5 do
      for shape, n in pairs(Config.tileSupply[g]) do assert_eq(st.riders.Red.supply[g][shape], n) end
    end
    assert_eq(st.riders.Red.supply[5].soft, nil, "gear 5 has no curves")
    assert_eq(st.riders.Red.supply[4].hard, nil, "gear 4 has no hard curve")
  end)
  it("a placed tile uses one piece of its own gear and shape", function()
    local st = setup()
    local r = use(st, 1, "straight")
    assert_eq(r.tileGear, 2); assert_eq(r.shape, "straight"); assert_false(r.substituted)
    assert_eq(st.riders.Red.supply[2].straight, Config.tileSupply[2].straight - 1)
    assert_eq(st.riders.Red.supply[1].straight, Config.tileSupply[1].straight)
  end)
  it("a hard curve turns tighter than a soft one and uses the hard supply", function()
    local st = setup()
    st.riders.Red.gear = 2
    local r = use(st, 0, "right", "hard", 5)
    assert_eq(r.shape, "hard")
    assert_near(st.riders.Red.pose.heading, Config.tiles[2].hard.sweep)
    assert_eq(st.riders.Red.supply[2].hard, Config.tileSupply[2].hard - 1)
  end)
  it("a spin-out uses a piece of the gear it was laid at, not gear 1", function()
    local st = setup()
    st.riders.Red.gear = 4
    local r = use(st, 0, "left", "soft", Config.turnCheck.die)
    assert_true(r.spunOut)
    assert_eq(r.tileGear, 4)
    assert_eq(st.riders.Red.supply[4].soft, Config.tileSupply[4].soft - 1)
    assert_eq(st.riders.Red.gear, 1)
  end)
  it("out of straights in your gear: the straight from the next gear down", function()
    local st = setup()
    st.riders.Red.gear = 3
    st.riders.Red.supply[3].straight = 0
    local r = use(st, 0, "straight")
    assert_eq(r.tileGear, 2); assert_eq(r.shape, "straight"); assert_true(r.substituted)
    assert_eq(#r.removedTiles, 0)
    assert_eq(st.riders.Red.gear, 3, "your gear does not change")
    assert_eq(st.riders.Red.supply[2].straight, Config.tileSupply[2].straight - 1)
  end)
  it("walks down more than one gear if needed", function()
    local st = setup()
    st.riders.Red.gear = 3
    st.riders.Red.supply[3].straight = 0
    st.riders.Red.supply[2].straight = 0
    local r = use(st, 0, "straight")
    assert_eq(r.tileGear, 1)
  end)
  it("out of hard curves: the soft curve of the same gear before any lower gear", function()
    local st = setup()
    st.riders.Red.gear = 3
    st.riders.Red.supply[3].hard = 0
    local r = use(st, 0, "right", "hard", 5)
    assert_eq(r.tileGear, 3); assert_eq(r.shape, "soft"); assert_true(r.substituted)
  end)
  it("out of all curves in your gear: a curve from the next gear down, even with straights left", function()
    local st = setup()
    st.riders.Red.gear = 3
    st.riders.Red.supply[3].hard, st.riders.Red.supply[3].soft = 0, 0
    local r = use(st, 0, "left", "soft", 5)
    assert_eq(r.tileGear, 2); assert_eq(r.shape, "soft")
    assert_eq(st.riders.Red.supply[3].straight, Config.tileSupply[3].straight, "straights untouched")
  end)
  it("a successful turn in gear 5 (no curves exist) uses a gear 4 soft curve", function()
    local st = setup()
    st.riders.Red.gear = 5
    local r = use(st, 0, "right", "soft", 5)
    assert_false(r.wentStraight)
    assert_eq(r.tileGear, 4); assert_eq(r.shape, "soft")
  end)
  it("a failed turn needs a straight, so it uses the straight supply", function()
    local st = setup()
    st.riders.Red.gear = 3
    local r = use(st, 0, "right", "soft", 1)
    assert_true(r.wentStraight)
    assert_eq(r.shape, "straight")
    assert_eq(st.riders.Red.supply[3].straight, Config.tileSupply[3].straight - 1)
  end)
  it("nothing left at your gear or below: oldest tiles come off one at a time until one fits", function()
    local st = setup()
    -- two G1 straights on the line, then a third straight at G1
    use(st, 0, "straight"); use(st, 0, "straight")
    assert_eq(st.riders.Red.supply[1].straight, 0)
    local ids = { st.riders.Red.trail.tiles[1].id, st.riders.Red.trail.tiles[2].id }
    local r = use(st, 0, "straight")
    assert_eq(r.outcome, "placed")
    assert_eq(#r.removedTiles, 1)
    assert_eq(r.removedTiles[1], ids[1], "the oldest goes first")
    assert_eq(#st.riders.Red.trail.tiles, 2)
    assert_eq(st.riders.Red.trail.tiles[1].id, ids[2])
    assert_eq(#st.riders.Red.trail.segs, 2, "segments rebuilt without the removed tile")
    assert_eq(st.riders.Red.supply[1].straight, 0, "returned, then used again")
  end)
  it("tiles of higher gears are removed too if they come first, even though they don't help", function()
    local st = setup()
    local red = st.riders.Red
    red.gear = 2
    red.trail.tiles = {
      { id = 1, kind = "straight", shape = "straight", gear = 5, entry = { x = 0, z = -20, heading = 0 } },
      { id = 2, kind = "straight", shape = "straight", gear = 1, entry = { x = 0, z = -14, heading = 0 } },
    }
    red.supply[5].straight, red.supply[1].straight, red.supply[2].straight = 0, 0, 0
    local g, shape, removed = Rules.planPiece(red, "straight", nil, 2)
    assert_eq(removed, 2, "the G5 tile is taken first and does not help")
    assert_eq(g, 1)
    assert_eq(#red.trail.tiles, 2, "planPiece does not change the rider")
    assert_eq(red.supply[5].straight, 0)
  end)
  it("a crash gives every piece back", function()
    local st = setup()
    st.riders.Red.pose = { x = 0, z = 17, heading = 0 }
    use(st, 0, "straight")   -- leaves the mat
    assert_eq(st.riders.Red.supply[1].straight, Config.tileSupply[1].straight)
    assert_eq(#st.riders.Red.trail.tiles, 0)
  end)
  it("saves from before typed supplies are rejected", function()
    local st = setup()
    assert_true(Rules.isValidState(st))
    st.riders.Red.supply = { 8, 7, 6, 5, 4 }
    assert_false(Rules.isValidState(st))
  end)
  it("tiles get unique, increasing ids", function()
    local st = setup()
    use(st, 0, "straight"); use(st, 0, "straight")
    local t = st.riders.Red.trail.tiles
    assert_true(t[2].id > t[1].id)
  end)
end)

describe("Prizm capture reach", function()
  -- Prizm along x at z=0 from x=-0.75..0.75. A path running +z crosses at x=0.9, past the end.
  local function crossAt(x)
    local st = newState({ { id = 1, a = { x = -0.75, z = 0 }, b = { x = 0.75, z = 0 } } })
    st.riders.Red.pose = { x = x, z = -1, heading = 0 }
    return Rules.resolveMove(st, "Red", { shift = 1, kind = "straight" }, fixed(3))   -- G2: z -1 -> 2
  end
  it("captures when the wall's width overlaps the Prizm's end", function()
    assert_eq(#crossAt(0.9).scored, 1, "0.15 past the end is within the wall half-width")
  end)
  it("does not capture when the wall clears the Prizm", function()
    assert_eq(#crossAt(1.1).scored, 0)
  end)
  it("still captures a centred crossing", function()
    assert_eq(#crossAt(0).scored, 1)
  end)
end)

describe("Prizm stealing", function()
  local function prizmAt(id, owner)
    return { id = id, owner = owner, a = { x = -1, z = -9 }, b = { x = 1, z = -9 } }
  end
  it("crossing another rider's scored Prizm steals it, with no new Prizm tossed", function()
    local st = newState({ prizmAt(7, "Blue") })
    local r = Rules.resolveMove(st, "Red", { shift = 0, kind = "straight" }, fixed(3))
    assert_eq(r.outcome, "placed")
    assert_eq(#r.scored, 0)
    assert_eq(#r.stolen, 1)
    assert_eq(r.stolen[1].id, 7); assert_eq(r.stolen[1].from, "Blue")
    assert_eq(st.prizms[1].owner, "Red")
    assert_eq(Rules.prizmCount(st, "Red"), 1)
    assert_eq(Rules.prizmCount(st, "Blue"), 0)
    assert_eq(#st.prizms, 1)
    assert_eq(#r.spawned, 0)
  end)
  it("crossing your own scored Prizm does nothing", function()
    local st = newState({ prizmAt(7, "Red") })
    local r = Rules.resolveMove(st, "Red", { shift = 0, kind = "straight" }, fixed(3))
    assert_eq(#r.scored, 0); assert_eq(#r.stolen, 0)
    assert_eq(Rules.prizmCount(st, "Red"), 1)
  end)
  it("stealing the last Prizm you need wins, and the victim is down one", function()
    local st = newState({
      prizmAt(7, "Blue"),
      { id = 8, owner = "Red", a = { x = -9, z = 0 }, b = { x = -8, z = 0 } },
      { id = 9, owner = "Red", a = { x = 9, z = 0 }, b = { x = 8, z = 0 } },
      { id = 10, owner = "Blue", a = { x = 0, z = 12 }, b = { x = 1, z = 12 } },
    })
    local r = Rules.resolveMove(st, "Red", { shift = 0, kind = "straight" }, fixed(3))
    assert_eq(r.outcome, "win")
    assert_eq(Rules.prizmCount(st, "Blue"), 1)
  end)
  it("a rider keeps scored Prizms when they crash, and they can be stolen later", function()
    local st = newState({ prizmAt(7, "Red") })
    st.riders.Red.pose = { x = 0, z = 17, heading = 0 }
    Rules.resolveMove(st, "Red", { shift = 0, kind = "straight" }, fixed(3))   -- off the mat
    assert_eq(Rules.prizmCount(st, "Red"), 1)
    st.riders.Blue.pose = { x = 0, z = -10, heading = 0 }
    local r = Rules.resolveMove(st, "Blue", { shift = 0, kind = "straight" }, fixed(3))
    assert_eq(#r.stolen, 1)
    assert_eq(Rules.prizmCount(st, "Red"), 0)
  end)
end)

describe("Prizm pass-through", function()
  local wall = { { a = { x = -3, z = -9 }, b = { x = 3, z = -9 } } }
  it("contact on top of a Prizm is not a crash", function()
    local st = newState({ { id = 7, a = { x = -0.75, z = -9 }, b = { x = 0.75, z = -9 } } })
    st.riders.Blue.trail.segs = wall
    local r = Rules.resolveMove(st, "Red", { shift = 0, kind = "straight" }, fixed(3))
    assert_eq(r.outcome, "placed")
    assert_eq(#r.scored, 1)
  end)
  it("the same wall without a Prizm on it is a crash", function()
    local st = newState()
    st.riders.Blue.trail.segs = wall
    assert_eq(Rules.resolveMove(st, "Red", { shift = 0, kind = "straight" }, fixed(3)).outcome, "crash")
  end)
  it("a Prizm that is not where the lines meet does not help", function()
    local st = newState({ { id = 7, a = { x = 1, z = -9.75 }, b = { x = 1, z = -8.25 } } })
    st.riders.Blue.trail.segs = wall
    assert_eq(Rules.resolveMove(st, "Red", { shift = 0, kind = "straight" }, fixed(3)).outcome, "crash")
  end)
end)

describe("crash victims lose pieces", function()
  -- Blue lays three tiles heading -z from (10,10): G1 z10-8 (id 1), G2 z8-5 (id 2), G3 z5-1 (id 3)
  local function blueLine()
    local st = newState()
    for _, shift in ipairs({ 0, 1, 1 }) do
      assert_eq(Rules.resolveMove(st, "Blue", { shift = shift, kind = "straight" }, fixed(3)).outcome, "placed")
    end
    return st
  end
  local function redCrossesAt(st, z)
    st.riders.Red.pose = { x = 7, z = z, heading = 90 }
    st.riders.Red.gear = 3
    return Rules.resolveMove(st, "Red", { shift = 0, kind = "straight" }, fixed(3))   -- G3: x 7 -> 11
  end
  local function ids(rider)
    local t = {}
    for i, tile in ipairs(rider.trail.tiles) do t[i] = tile.id end
    return table.concat(t, ",")
  end

  it("the hit tile and every older one come off; the front tile stays", function()
    local st = blueLine()
    local r = redCrossesAt(st, 6.5)               -- hits tile 2
    assert_eq(r.outcome, "crash"); assert_eq(r.crashReason, "trail"); assert_eq(r.crashOwner, "Blue")
    assert_eq(r.victim.color, "Blue")
    assert_eq(table.concat(r.victim.removedTiles, ","), "1,2")
    assert_eq(ids(st.riders.Blue), "3")
    assert_eq(#st.riders.Blue.trail.segs, 1, "wall rebuilt from the surviving tile")
    assert_eq(st.riders.Blue.trail.segs[1].tile, 3)
    assert_eq(#st.riders.Red.trail.tiles, 0, "the crasher loses everything too")
  end)
  it("pieces come back to the victim's supply", function()
    local st = blueLine()
    local b = st.riders.Blue
    assert_eq(b.supply[1].straight, Config.tileSupply[1].straight - 1)
    redCrossesAt(st, 6.5)
    assert_eq(b.supply[1].straight, Config.tileSupply[1].straight)
    assert_eq(b.supply[2].straight, Config.tileSupply[2].straight)
    assert_eq(b.supply[3].straight, Config.tileSupply[3].straight - 1, "front tile still out")
  end)
  it("hitting the oldest tile costs only that one", function()
    local st = blueLine()
    local r = redCrossesAt(st, 9)
    assert_eq(table.concat(r.victim.removedTiles, ","), "1")
    assert_eq(ids(st.riders.Blue), "2,3")
  end)
  it("hitting the front tile strips everything behind it but never the front tile", function()
    local st = blueLine()
    local r = redCrossesAt(st, 3)
    assert_eq(r.crashReason, "trail")
    assert_eq(table.concat(r.victim.removedTiles, ","), "1,2")
    assert_eq(ids(st.riders.Blue), "3")
  end)
  it("a lone tile that is hit stays (it is the front tile)", function()
    local st = newState()
    Rules.resolveMove(st, "Blue", { shift = 0, kind = "straight" }, fixed(3))   -- z 10 -> 8
    local r = redCrossesAt(st, 9)
    assert_eq(#r.victim.removedTiles, 0)
    assert_eq(ids(st.riders.Blue), "1")
  end)
  it("hitting a bike or your own trail costs nobody else anything", function()
    local st = newState()
    local r = redCrossesAt(st, 11)                -- Blue's bike, no tiles laid
    assert_eq(r.crashReason, "bike")
    assert_eq(r.victim, nil)
    st = newState()
    Rules.resolveMove(st, "Red", { shift = 1, kind = "straight" }, fixed(3))   -- z -10 -> -7
    st.riders.Red.pose = { x = 3, z = -8.5, heading = 270 }
    r = Rules.resolveMove(st, "Red", { shift = 0, kind = "straight" }, fixed(3))
    assert_eq(r.crashOwner, "Red")
    assert_eq(r.victim, nil)
  end)
  it("a victim keeps scored Prizms", function()
    local st = blueLine()
    st.prizms = { { id = 1, owner = "Blue", a = { x = -9, z = 0 }, b = { x = -8, z = 0 } } }
    redCrossesAt(st, 6.5)
    assert_eq(Rules.prizmCount(st, "Blue"), 1)
  end)
end)

describe("Prizm nudge", function()
  local function beside(x)   -- a neutral Prizm running along z, alongside Red's tile (x=0, z -10..-8)
    return { id = 7, a = { x = x, z = -9.5 }, b = { x = x, z = -8.5 } }
  end
  it("a Prizm touched but not crossed is pushed clear of the wall", function()
    local st = newState({ beside(0.2) })
    local r = Rules.resolveMove(st, "Red", { shift = 0, kind = "straight" }, fixed(3))
    assert_eq(#r.scored, 0)
    assert_eq(#r.nudged, 1); assert_eq(r.nudged[1], 7)
    local p = st.prizms[1]
    assert_true(Geom.pathDistance(r.segs, p) >= Config.prizm.nudgeClear - 1e-6, "clear of the wall")
    assert_true((p.a.x + p.b.x) / 2 > 0.2, "pushed away from the wall")
    assert_near(p.b.z - p.a.z, 1.0, 1e-9, "same size and orientation")
    assert_eq(p.owner, nil)
  end)
  it("a Prizm that is already clear is left alone", function()
    local st = newState({ beside(2) })
    local r = Rules.resolveMove(st, "Red", { shift = 0, kind = "straight" }, fixed(3))
    assert_eq(#r.nudged, 0)
    assert_near(st.prizms[1].a.x, 2)
  end)
  it("a scored Prizm sitting on its owner's own line is locked and stays", function()
    local st = newState({ { id = 7, owner = "Red", a = { x = -0.75, z = -9 }, b = { x = 0.75, z = -9 } } })
    st.riders.Red.trail.segs = { { a = { x = 0, z = -10 }, b = { x = 0, z = -8 } } }
    st.riders.Blue.pose = { x = 3, z = -9.3, heading = 270 }   -- runs alongside the Prizm, not across it
    local r = Rules.resolveMove(st, "Blue", { shift = 1, kind = "straight" }, fixed(3))
    assert_eq(r.outcome, "placed")
    assert_eq(#r.nudged, 0)
    assert_near(st.prizms[1].a.x, -0.75)
  end)
  it("a Prizm touched by two riders' lines is locked and stays", function()
    local st = newState({ beside(0.2) })
    st.riders.Blue.trail.segs = { { a = { x = 0.5, z = -9.2 }, b = { x = 0.5, z = -8.8 } } }
    local r = Rules.resolveMove(st, "Red", { shift = 0, kind = "straight" }, fixed(3))
    assert_eq(r.outcome, "placed")
    assert_eq(#r.nudged, 0)
    assert_near(st.prizms[1].a.x, 0.2)
  end)
  it("a nudged Prizm does not land on another Prizm or off the mat", function()
    local st = newState({ beside(0.2), { id = 8, a = { x = 1.0, z = -9.5 }, b = { x = 1.0, z = -8.5 } } })
    Rules.resolveMove(st, "Red", { shift = 0, kind = "straight" }, fixed(3))
    local a, b = st.prizms[1], st.prizms[2]
    assert_true(Geom.segmentDistance(a, b) >= Config.prizm.nudgeClear - 1e-6, "clear of the other Prizm")
    assert_true(Geom.inBounds({ a }, Config.mat))
  end)
end)

describe("respawn gear choice", function()
  local function crashed()
    local st = newState()
    st.riders.Red.pose = { x = 0, z = 17, heading = 0 }
    local r = Rules.resolveMove(st, "Red", { shift = 0, kind = "straight" }, fixed(3))
    assert_eq(r.outcome, "crash")
    return st
  end
  it("a crash leaves the rider pending, in gear 1 until they choose", function()
    local st = crashed()
    assert_eq(st.pendingGear, "Red")
    assert_eq(st.riders.Red.gear, 1)
    assert_false(newState().pendingGear)
  end)
  it("the turn does not pass while a gear is pending", function()
    local st = crashed()
    assert_false(Rules.advanceTurn(st))
    assert_eq(Rules.currentColor(st), "Red")
  end)
  it("any gear from min to max can be chosen, once, by that rider", function()
    for g = Config.gears.min, Config.gears.max do
      local st = crashed()
      assert_true(Rules.chooseGear(st, "Red", g))
      assert_eq(st.riders.Red.gear, g)
      assert_false(st.pendingGear)
    end
    local st = crashed()
    local ok, why = Rules.chooseGear(st, "Blue", 3)
    assert_false(ok); assert_eq(why, "who")
    ok, why = Rules.chooseGear(st, "Red", 0); assert_false(ok); assert_eq(why, "range")
    ok, why = Rules.chooseGear(st, "Red", Config.gears.max + 1); assert_false(ok); assert_eq(why, "range")
    ok, why = Rules.chooseGear(st, "Red", 2.5); assert_false(ok); assert_eq(why, "range")
    assert_eq(st.pendingGear, "Red", "bad picks change nothing")
    Rules.chooseGear(st, "Red", 3)
    ok, why = Rules.chooseGear(st, "Red", 4); assert_false(ok); assert_eq(why, "none")
    assert_eq(st.riders.Red.gear, 3)
  end)
  it("the chosen gear sets the next round's order", function()
    local st = crashed()
    Rules.chooseGear(st, "Red", 5)
    Rules.advanceTurn(st)                       -- Blue's turn
    assert_true(Rules.advanceTurn(st))          -- new round
    assert_eq(Rules.currentColor(st), "Red", "gear 5 goes first, ahead of the tie-breaker")
  end)
  it("the chosen gear is the one the next move starts from", function()
    local st = crashed()
    Rules.chooseGear(st, "Red", 3)
    local r = Rules.resolveMove(st, "Red", { shift = 0, kind = "straight" }, fixed(3))
    assert_eq(r.tileGear, 3)
  end)
  it("hand-mode drops are refused while a gear is pending", function()
    local st = crashed()
    local ok, why = Rules.validateTileDrop(st, "Red", 1, "straight", { x = 0, z = 0 }, "straight")
    assert_false(ok); assert_eq(why, "pick")
  end)
  it("an out-of-pieces crash also asks for a gear, and a bad pendingGear name is invalid", function()
    local st = crashed()
    assert_true(Rules.isValidState(st))
    st.pendingGear = "Purple"
    assert_false(Rules.isValidState(st))
  end)
end)
