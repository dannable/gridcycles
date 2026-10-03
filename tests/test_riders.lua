-- Rider ability tests (M7). Abilities are set explicitly so each test is deterministic.
local function fixed(v) return function() return v end end

-- Red at (0, -10) heading +z, Blue far away, no Prizms. Abilities given per colour.
local function newState(redAbility, blueAbility, prizms)
  local st = Rules.newState({ "Red", "Blue" }, fixed(3))
  st.riders.Red.pose = { x = 0, z = -10, heading = 0 }
  st.riders.Blue.pose = { x = 10, z = 10, heading = 180 }
  st.riders.Red.ability, st.riders.Red.charged = redAbility, redAbility ~= nil
  st.riders.Blue.ability, st.riders.Blue.charged = blueAbility, blueAbility ~= nil
  st.pickingStart = false
  st.prizms = prizms or {}
  st.nextPrizmId = 100
  return st
end

describe("Riders.deal", function()
  it("gives each rider a different ability, charged", function()
    local st = Rules.newState({ "Red", "Blue", "Green", "Yellow" }, function(n) return math.random(n) end)
    local seen = {}
    for _, c in ipairs(st.order) do
      local r = st.riders[c]
      assert_true(Riders.defs[r.ability] ~= nil, "known ability")
      assert_false(seen[r.ability], "no duplicates")
      seen[r.ability] = true
      assert_true(r.charged)
    end
  end)
  it("is deterministic for the same rolls", function()
    local a = Rules.newState({ "Red", "Blue" }, fixed(2))
    local b = Rules.newState({ "Red", "Blue" }, fixed(2))
    assert_eq(a.riders.Red.ability, b.riders.Red.ability)
    assert_eq(a.riders.Blue.ability, b.riders.Blue.ability)
  end)
  it("deals nothing when abilities are off", function()
    local was = Config.abilitiesEnabled
    Config.abilitiesEnabled = false
    local st = Rules.newState({ "Red", "Blue" }, fixed(2))
    Config.abilitiesEnabled = was
    assert_eq(st.riders.Red.ability, nil)
    assert_eq(st.riders.Blue.ability, nil)
    assert_true(Rules.isValidState(st))
  end)
  it("every ability has a name and rules text", function()
    for _, id in ipairs(Riders.order) do
      assert_true(#Riders.name(id) > 0)
      assert_true(#Riders.text(id) > 0)
    end
  end)
  it("a save with an unknown ability is invalid", function()
    local st = newState("echo")
    assert_true(Rules.isValidState(st))
    st.riders.Red.ability = "teleport"
    assert_false(Rules.isValidState(st))
  end)
end)

describe("Echo (shift up to 2)", function()
  it("Echo can shift two gears; others are held to one", function()
    local st = newState("echo", "vixen")
    local r = Rules.resolveMove(st, "Red", { shift = 2, kind = "straight" }, fixed(3))
    assert_eq(r.gear, 3)
    st.riders.Blue.pose = { x = 10, z = -10, heading = 0 }
    r = Rules.resolveMove(st, "Blue", { shift = 2, kind = "straight" }, fixed(3))
    assert_eq(r.gear, 2)
  end)
  it("Echo's shift is still clamped to its limit", function()
    local st = newState("echo")
    local r = Rules.resolveMove(st, "Red", { shift = 4, kind = "straight" }, fixed(3))
    assert_eq(r.gear, 1 + Config.abilities.echoMaxShift)
  end)
  it("gearAfterShift takes a rider's limit", function()
    assert_eq(Rules.gearAfterShift(3, 2), 4)
    assert_eq(Rules.gearAfterShift(3, 2, 2), 5)
    assert_eq(Rules.gearAfterShift(3, -2, 2), 1)
  end)
  it("hand mode lets Echo drop a tile two gears away", function()
    local st = newState("echo", "vixen")
    local pose = st.riders.Red.pose
    local ok, shift = Rules.validateTileDrop(st, "Red", 3, "straight", Geom.tileCenter("straight", 3, pose))
    assert_true(ok)
    assert_eq(shift, 2)
    st.riders.Red.ability = "vixen"
    ok = Rules.validateTileDrop(st, "Red", 3, "straight", Geom.tileCenter("straight", 3, pose))
    assert_false(ok)
  end)
end)

describe("Volt Vixen (once per game, a failed check still curves)", function()
  it("an armed boost turns a failed check into a curve and spends the charge", function()
    local st = newState("vixen")
    st.riders.Red.gear = 4
    local r = Rules.resolveMove(st, "Red", { kind = "left", curve = "soft", boost = true }, fixed(2))
    assert_eq(r.kind, "left")
    assert_false(r.wentStraight)
    assert_true(r.boosted)
    assert_false(st.riders.Red.charged)
    assert_false(Riders.canBoost(st.riders.Red))
  end)
  it("a check that passes anyway keeps the charge", function()
    local st = newState("vixen")
    local r = Rules.resolveMove(st, "Red", { kind = "left", curve = "soft", boost = true }, fixed(3))
    assert_eq(r.kind, "left")
    assert_false(r.boosted)
    assert_true(st.riders.Red.charged)
  end)
  it("the spin-out face still spins out, and keeps the charge", function()
    local st = newState("vixen")
    st.riders.Red.gear = 3
    local r = Rules.resolveMove(st, "Red", { kind = "left", curve = "soft", boost = true }, fixed(Config.turnCheck.die))
    assert_true(r.spunOut)
    assert_eq(r.gear, 1)
    assert_true(st.riders.Red.charged)
  end)
  it("once spent, a failed check goes straight again", function()
    local st = newState("vixen")
    st.riders.Red.gear = 4
    st.riders.Red.charged = false
    local r = Rules.resolveMove(st, "Red", { kind = "left", curve = "soft", boost = true }, fixed(2))
    assert_true(r.wentStraight)
    assert_false(r.boosted)
  end)
  it("other riders cannot boost", function()
    local st = newState("echo")
    st.riders.Red.gear = 4
    local r = Rules.resolveMove(st, "Red", { kind = "left", curve = "soft", boost = true }, fixed(2))
    assert_true(r.wentStraight)
  end)
  it("arming a straight costs nothing", function()
    local st = newState("vixen")
    Rules.resolveMove(st, "Red", { kind = "straight", boost = true }, fixed(2))
    assert_true(st.riders.Red.charged)
  end)
end)

describe("Overclock (once per respawn, two moves at G1)", function()
  it("drops to G1 and grants a second move; the turn does not pass in between", function()
    local st = newState("overclock", "echo")
    st.riders.Red.gear = 4
    st.roundOrder, st.turn = { "Red", "Blue" }, 1
    local r = Rules.resolveMove(st, "Red", { kind = "straight", overclock = true }, fixed(3))
    assert_true(r.overclock)
    assert_true(r.bonusMove)
    assert_eq(r.tileGear, 1)
    assert_eq(r.gear, 1)
    assert_eq(st.bonusMove, "Red")
    assert_false(st.riders.Red.charged)
    assert_false(Rules.advanceTurn(st))
    assert_eq(Rules.currentColor(st), "Red", "still Red's turn")
    -- second move: G1 whatever the shift asks for
    r = Rules.resolveMove(st, "Red", { shift = 1, kind = "straight" }, fixed(3))
    assert_eq(r.tileGear, 1)
    assert_eq(r.gear, 1)
    assert_false(r.bonusMove)
    assert_eq(st.bonusMove, false)
    Rules.advanceTurn(st)
    assert_eq(Rules.currentColor(st), "Blue")
  end)
  it("cannot be used again until a crash recharges it", function()
    local st = newState("overclock")
    st.riders.Red.charged = false
    st.riders.Red.gear = 3
    local r = Rules.resolveMove(st, "Red", { kind = "straight", overclock = true }, fixed(3))
    assert_false(r.overclock)
    assert_eq(r.gear, 3)
    assert_eq(st.bonusMove, false)
    st.riders.Red.pose = { x = 0, z = Config.mat.depth / 2 - 0.5, heading = 0 }
    r = Rules.resolveMove(st, "Red", { kind = "straight" }, fixed(3))
    assert_eq(r.outcome, "crash")
    assert_true(st.riders.Red.charged, "a respawn recharges Overclock")
  end)
  it("a crash on the first move ends the Overclock", function()
    local st = newState("overclock")
    st.riders.Red.pose = { x = 0, z = Config.mat.depth / 2 - 0.5, heading = 0 }
    local r = Rules.resolveMove(st, "Red", { kind = "straight", overclock = true }, fixed(3))
    assert_eq(r.outcome, "crash")
    assert_false(r.bonusMove)
    assert_eq(st.bonusMove, false)
    assert_eq(st.pendingGear, "Red")
  end)
  it("other riders cannot overclock", function()
    local st = newState("echo")
    st.riders.Red.gear = 3
    local r = Rules.resolveMove(st, "Red", { kind = "straight", overclock = true }, fixed(3))
    assert_eq(r.gear, 3)
    assert_eq(st.bonusMove, false)
  end)
  it("hand mode only accepts a G1 tile for an Overclock move", function()
    local st = newState("overclock")
    st.riders.Red.gear = 2
    local pose = st.riders.Red.pose
    local ok, why = Rules.validateTileDrop(st, "Red", 2, "straight", Geom.tileCenter("straight", 2, pose), nil, true)
    assert_false(ok)
    assert_eq(why, "gear")
    ok = Rules.validateTileDrop(st, "Red", 1, "straight", Geom.tileCenter("straight", 1, pose), nil, true)
    assert_true(ok)
    st.bonusMove = "Red"
    ok = Rules.validateTileDrop(st, "Red", 2, "straight", Geom.tileCenter("straight", 2, pose))
    assert_false(ok, "the second move is G1 too")
  end)
  it("a bonus move survives a save round trip", function()
    local st = newState("overclock")
    st.bonusMove = "Red"
    assert_true(Rules.isValidState(st))
    st.bonusMove = "Purple"
    assert_false(Rules.isValidState(st))
  end)
end)

describe("Gridlock (taking a Prizm removes a rival tile next to it)", function()
  -- Red scores the Prizm across z = -9. Blue's line runs up x = 1.5 beside its end:
  -- the older tile is 0.5 from the Prizm, the front one is out of reach.
  local function setup(redAbility)
    local st = newState(redAbility, "echo", { { id = 1, a = { x = -1, z = -9 }, b = { x = 1, z = -9 } } })
    st.riders.Blue.pose = { x = 1.5, z = -10, heading = 0 }
    Rules.resolveMove(st, "Blue", { kind = "straight" }, fixed(3))
    Rules.resolveMove(st, "Blue", { kind = "straight" }, fixed(3))
    assert_eq(#st.riders.Blue.trail.tiles, 2)
    return st
  end
  it("removes the rival tile beside the Prizm and returns the piece", function()
    local st = setup("gridlock")
    local before = Rules.supplyLeft(st, "Blue", 1, "straight")
    local r = Rules.resolveMove(st, "Red", { kind = "straight" }, fixed(3))
    assert_eq(#r.scored, 1)
    assert_eq(#r.gridlock, 1)
    assert_eq(r.gridlock[1].color, "Blue")
    assert_eq(r.gridlock[1].tileId, 1)
    assert_eq(#st.riders.Blue.trail.tiles, 1)
    assert_eq(st.riders.Blue.trail.tiles[1].id, 2, "the front tile stays")
    assert_eq(Rules.supplyLeft(st, "Blue", 1, "straight"), before + 1)
  end)
  it("never removes a front tile", function()
    local st = newState("gridlock", "echo", { { id = 1, a = { x = -1, z = -9 }, b = { x = 1, z = -9 } } })
    st.riders.Blue.pose = { x = 1.5, z = -10, heading = 0 }
    Rules.resolveMove(st, "Blue", { kind = "straight" }, fixed(3))
    local r = Rules.resolveMove(st, "Red", { kind = "straight" }, fixed(3))
    assert_eq(#r.gridlock, 0)
    assert_eq(#st.riders.Blue.trail.tiles, 1)
  end)
  it("other riders remove nothing", function()
    local st = setup("echo")
    local r = Rules.resolveMove(st, "Red", { kind = "straight" }, fixed(3))
    assert_eq(#r.scored, 1)
    assert_eq(#r.gridlock, 0)
    assert_eq(#st.riders.Blue.trail.tiles, 2)
  end)
end)
