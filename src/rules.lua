-- rules.lua
-- Pure turn resolution. NO TTS API calls: takes state + inputs, returns a result.
-- Randomness is injected (rollFn) so tests are deterministic.
--
-- rollFn(n) -> integer in 1..n  (the same function rolls the d6 and picks spawn points)
--
-- State (plain tables, JSON-safe):
--   state = {
--     order   = { color... },
--     riders  = { [color] = { gear, pose = {x,z,heading}, prizms = n,
--                             supply = { [gear] = { straight = n, soft = n, hard = n } },
--                             nextTileId = n,
--                             trail = { segs = {Segment...},
--                                       tiles = { {id, kind, shape, gear, entry} ... } } } },  -- oldest first
--     prizms  = { { id, a = Point, b = Point } ... },
--     markers = { { owner = color, segs = { Segment } } ... },   -- capture markers, block like trails
--     nextPrizmId = n,
--   }
--
-- Pieces: every tile has a gear and a shape ("straight" | "soft" | "hard"); riders own a
-- limited supply of each (Config.tileSupply). See Rules.planPiece for what happens
-- when the wanted piece has run out.
--
-- Rules.resolveMove(state, color, move, rollFn) -> result
--   move   = { shift = -1|0|1, kind = "straight"|"left"|"right", curve = "soft"|"hard" }
--   result = { outcome = "placed"|"crash"|"win",
--              gear (rider's gear afterwards), roll, spunOut, wentStraight,
--              kind (the tile actually laid), tileGear / shape (the piece used),
--              substituted (true if a lower gear or other curve shape was used),
--              removedTiles = { id... } (oldest tiles given up to get a piece),
--              segs, exitPose, captured = {prizmIds...}, spawned = {prizm...},
--              crashReason = "bounds"|"trail"|"bike"|"supply" (crash only), crashOwner = colour
--              whose trail/marker/bike was hit (not for "bounds"), respawn = pose (crash only) }
--
-- A rider's bike is part of their trail: Geom.bikeSeg(rider.pose), nose on the trail
-- end. It blocks every other rider but never its owner.

Rules = {}

local function clamp(v, lo, hi)
  if v < lo then return lo elseif v > hi then return hi end
  return v
end

-- uniform float in [0, 1]
local function rand(rollFn)
  return (rollFn(10000) - 1) / 9999
end

-- Everything a new path can crash into: every trail, capture marker and bike.
-- `exclude` names a rider whose own bike is left out (it never blocks its owner:
-- the owner's next tile starts on the bike's nose).
local function allTrails(state, exclude)
  local list = {}
  for _, color in ipairs(state.order) do
    local r = state.riders[color]
    if r then list[#list + 1] = { owner = color, segs = r.trail.segs } end
  end
  for _, color in ipairs(state.order) do
    local r = state.riders[color]
    if r and r.pose and color ~= exclude then
      list[#list + 1] = { owner = color, kind = "bike", segs = { Geom.bikeSeg(r.pose) } }
    end
  end
  for _, m in ipairs(state.markers) do
    list[#list + 1] = { owner = m.owner, segs = m.segs }
  end
  return list
end

-- Random edge launch, heading inward, with the bike's tail on the edge (so the
-- pose, the bike's nose, sits bikeLength inside). Retries if the bike would
-- land on a trail or another bike.
local function randomLaunch(state, rollFn, exclude)
  local mat = Config.mat
  local hw, hd = mat.width / 2, mat.depth / 2
  local m = Config.launchMargin
  local pose
  for _ = 1, Config.spawnTries do
    local edge = rollFn(4)
    local t = rand(rollFn)
    if edge == 1 then       -- south edge, heading +z
      pose = { x = -hw + m + t * (mat.width - 2 * m), z = -hd, heading = 0 }
    elseif edge == 2 then   -- west edge, heading +x
      pose = { x = -hw, z = -hd + m + t * (mat.depth - 2 * m), heading = 90 }
    elseif edge == 3 then   -- north edge, heading -z
      pose = { x = -hw + m + t * (mat.width - 2 * m), z = hd, heading = 180 }
    else                    -- east edge, heading -x
      pose = { x = hw, z = -hd + m + t * (mat.depth - 2 * m), heading = 270 }
    end
    pose = Geom.advance(pose, Config.bikeLength)
    if not Geom.pathHitsTrails({ Geom.bikeSeg(pose) }, allTrails(state, exclude), nil) then return pose end
  end
  return pose
end

-- Random Prizm: centred away from the mat edge, random orientation, clear of
-- trails, markers and other Prizms.
local function randomPrizm(state, rollFn)
  local mat = Config.mat
  local hw = mat.width / 2 - Config.prizmEdgeMargin
  local hd = mat.depth / 2 - Config.prizmEdgeMargin
  local half = Config.prizm.length / 2
  local prizm
  for _ = 1, Config.spawnTries do
    local cx = (rand(rollFn) * 2 - 1) * hw
    local cz = (rand(rollFn) * 2 - 1) * hd
    local ang = rand(rollFn) * math.pi
    local dx, dz = math.sin(ang) * half, math.cos(ang) * half
    local seg = { a = { x = cx - dx, z = cz - dz }, b = { x = cx + dx, z = cz + dz } }
    local blocked = Geom.pathHitsTrails({ seg }, allTrails(state), nil)
    if not blocked then
      for _, p in ipairs(state.prizms) do
        if Geom.segmentsIntersect(seg, p) then blocked = true; break end
      end
    end
    if not blocked then
      prizm = seg
      break
    end
  end
  if prizm == nil then return nil end
  prizm.id = state.nextPrizmId
  state.nextPrizmId = state.nextPrizmId + 1
  return prizm
end

local function fullSupply()
  local sup = {}
  for g = Config.gears.min, Config.gears.max do
    sup[g] = {}
    for shape, n in pairs(Config.tileSupply[g] or {}) do sup[g][shape] = n end
  end
  return sup
end

-- Pieces `color` has left of (gear, shape).
function Rules.supplyLeft(state, color, gear, shape)
  local row = state.riders[color].supply[gear]
  return (row and row[shape]) or 0
end

local function otherShape(shape) return shape == "soft" and "hard" or "soft" end

-- Preference order for a request: from the current gear downwards; a curve prefers
-- the shape asked for, then the other curve shape, before dropping a gear.
local function candidates(want, shape, gear)
  local list = {}
  for g = gear, Config.gears.min, -1 do
    if want == "straight" then
      list[#list + 1] = { g, "straight" }
    else
      list[#list + 1] = { g, shape }
      list[#list + 1] = { g, otherShape(shape) }
    end
  end
  return list
end

-- Which piece would a rider use? want = "straight" | "curve"; shape = "soft" | "hard"
-- (curves); gear = their gear. Uses the exact piece if they have one, else the same
-- kind from the next gear down (a curve tries the other curve shape in the same gear
-- first). If nothing at their gear or below is left, their oldest tiles come off the
-- line one at a time until something fits.
-- Returns pieceGear, pieceShape, removeCount (how many oldest tiles must go), or nil
-- if even an empty line can't supply one. Does not change the rider.
function Rules.planPiece(rider, want, shape, gear)
  local sup = {}
  for g, row in pairs(rider.supply) do
    sup[g] = {}
    for sh, n in pairs(row) do sup[g][sh] = n end
  end
  local removed = 0
  while true do
    for _, c in ipairs(candidates(want, shape, gear)) do
      if ((sup[c[1]] and sup[c[1]][c[2]]) or 0) > 0 then return c[1], c[2], removed end
    end
    removed = removed + 1
    local tile = rider.trail.tiles[removed]
    if tile == nil then return nil, nil, removed - 1 end
    sup[tile.gear][tile.shape] = (sup[tile.gear][tile.shape] or 0) + 1
  end
end

local function segsOf(tiles)
  local segs = {}
  for _, t in ipairs(tiles) do
    for _, sg in ipairs((Geom.tilePath(t.kind, t.gear, t.entry, t.shape))) do segs[#segs + 1] = sg end
  end
  return segs
end

-- Take the oldest `n` tiles off the line, returning their pieces to the supply.
local function removeOldest(rider, n)
  local ids = {}
  for _ = 1, n do
    local t = table.remove(rider.trail.tiles, 1)
    rider.supply[t.gear][t.shape] = (rider.supply[t.gear][t.shape] or 0) + 1
    ids[#ids + 1] = t.id
  end
  if n > 0 then rider.trail.segs = segsOf(rider.trail.tiles) end
  return ids
end

function Rules.newState(colors, rollFn)
  rollFn = rollFn or function(n) return math.random(n) end
  local state = {
    order = {},
    riders = {},
    prizms = {},
    markers = {},
    nextPrizmId = 1,
    turn = 1,          -- index into order
    winner = false,    -- colour of the winner once the game is won
  }
  for i, c in ipairs(colors) do state.order[i] = c end
  for _, c in ipairs(state.order) do
    state.riders[c] = {
      gear = Config.gears.min,
      pose = nil,
      prizms = 0,
      supply = fullSupply(),
      nextTileId = 1,
      trail = { segs = {}, tiles = {} },
    }
    state.riders[c].pose = randomLaunch(state, rollFn, c)
  end
  for _ = 1, Config.prizmsOnTable do
    local p = randomPrizm(state, rollFn)
    if p then state.prizms[#state.prizms + 1] = p end
  end
  return state
end

-- Wipe the rider's trail (returning their whole tile supply) and respawn them.
function Rules.crash(state, color, reason, owner, rollFn)
  local rider = state.riders[color]
  rider.trail = { segs = {}, tiles = {} }
  rider.supply = fullSupply()
  rider.gear = Config.gears.min
  rider.pose = randomLaunch(state, rollFn, color)
  return {
    outcome = "crash", crashReason = reason, crashOwner = owner,
    gear = rider.gear, captured = {}, spawned = {},
    respawn = { x = rider.pose.x, z = rider.pose.z, heading = rider.pose.heading },
  }
end

function Rules.resolveMove(state, color, move, rollFn)
  local rider = state.riders[color]
  assert(rider, "Rules.resolveMove: unknown rider " .. tostring(color))

  -- 1. shift gear
  local shift = clamp(move.shift or 0, -Config.gears.maxShift, Config.gears.maxShift)
  local gear = clamp(rider.gear + shift, Config.gears.min, Config.gears.max)

  -- 2. turn check: the curve die has numbered faces and one spin-out face
  local kind = move.kind
  local want = "straight"
  local shape = move.curve or "soft"
  local roll, spunOut, wentStraight = nil, false, false
  if kind == "left" or kind == "right" then
    want = "curve"
    roll = rollFn(Config.turnCheck.die)
    if roll == Config.turnCheck.die then
      spunOut = true            -- curve happens, gear drops afterwards
    elseif roll >= gear then
      -- curve succeeds
    else
      kind = "straight"
      want = "straight"
      wentStraight = true
    end
  elseif kind ~= "straight" then
    error("Rules.resolveMove: unknown kind " .. tostring(kind))
  end

  -- 3. pick the piece (may substitute a lower one, or give up the oldest tiles)
  local pieceGear, pieceShape, nRemove = Rules.planPiece(rider, want, shape, gear)
  if pieceGear == nil then
    return Rules.crash(state, color, "supply", nil, rollFn)   -- cannot happen with a sane config
  end
  local removedTiles = removeOldest(rider, nRemove)
  local substituted = pieceGear ~= gear or (want == "curve" and pieceShape ~= shape)

  -- 3b. geometry
  local segs, exitPose = Geom.tilePath(kind, pieceGear, rider.pose, pieceShape)
  local result = {
    gear = gear, tileGear = pieceGear, shape = pieceShape, substituted = substituted,
    removedTiles = removedTiles, roll = roll, spunOut = spunOut, wentStraight = wentStraight,
    kind = kind, segs = segs, exitPose = exitPose, captured = {}, spawned = {},
  }

  -- 4. crash checks
  local crashReason, crashOwner
  if not Geom.inBounds(segs, Config.mat) then
    crashReason = "bounds"
  else
    local hit, trail = Geom.pathHitsTrails(segs, allTrails(state, color),
      { x = rider.pose.x, z = rider.pose.z })
    if hit then
      crashReason = trail.kind == "bike" and "bike" or "trail"
      crashOwner = trail.owner
    end
  end
  if crashReason then
    local r = Rules.crash(state, color, crashReason, crashOwner, rollFn)
    r.segs, r.exitPose, r.kind, r.tileGear, r.shape = segs, exitPose, kind, pieceGear, pieceShape
    r.roll, r.spunOut, r.wentStraight = roll, spunOut, wentStraight
    r.substituted, r.removedTiles = substituted, removedTiles
    return r
  end

  -- 5. place tile
  local entry = { x = rider.pose.x, z = rider.pose.z, heading = rider.pose.heading }
  for _, s in ipairs(segs) do
    rider.trail.segs[#rider.trail.segs + 1] = { a = { x = s.a.x, z = s.a.z }, b = { x = s.b.x, z = s.b.z } }
  end
  rider.trail.tiles[#rider.trail.tiles + 1] = {
    id = rider.nextTileId, kind = kind, shape = pieceShape, gear = pieceGear, entry = entry,
  }
  rider.nextTileId = rider.nextTileId + 1
  rider.supply[pieceGear][pieceShape] = rider.supply[pieceGear][pieceShape] - 1
  rider.pose = { x = exitPose.x, z = exitPose.z, heading = exitPose.heading }
  rider.gear = spunOut and Config.gears.min or gear
  result.gear = rider.gear
  result.outcome = "placed"

  -- 6. captures (a marker replaces the Prizm and blocks like a trail)
  local remaining = {}
  local captured = {}
  for _, p in ipairs(state.prizms) do
    if Geom.pathCrossesPrizm(segs, p, Config.prizm.endSlack) then
      captured[#captured + 1] = p
    else
      remaining[#remaining + 1] = p
    end
  end
  state.prizms = remaining
  for _, p in ipairs(captured) do
    rider.prizms = rider.prizms + 1
    state.markers[#state.markers + 1] = {
      owner = color,
      segs = { { a = { x = p.a.x, z = p.a.z }, b = { x = p.b.x, z = p.b.z } } },
    }
    result.captured[#result.captured + 1] = p.id
  end

  if rider.prizms >= Config.prizmsToWin then
    result.outcome = "win"
    state.winner = color
    return result
  end

  -- 7. top the table back up
  for _ = 1, #captured do
    local np = randomPrizm(state, rollFn)
    if np then
      state.prizms[#state.prizms + 1] = np
      result.spawned[#result.spawned + 1] = np
    end
  end
  return result
end

function Rules.currentColor(state)
  return state.order[state.turn]
end

-- Pass play to the next rider in seating order. No-op once the game is won.
function Rules.advanceTurn(state)
  if state.winner then return end
  state.turn = state.turn % #state.order + 1
end

-- True if `state` (e.g. decoded from a save) has the shape this version expects.
-- Older or corrupt saves fail this and the game starts fresh.
function Rules.isValidState(state)
  if type(state) ~= "table" then return false end
  if type(state.order) ~= "table" or #state.order == 0 then return false end
  if type(state.turn) ~= "number" or state.order[state.turn] == nil then return false end
  if type(state.riders) ~= "table" or type(state.prizms) ~= "table"
    or type(state.markers) ~= "table" then return false end
  for _, c in ipairs(state.order) do
    local r = state.riders[c]
    if type(r) ~= "table" or type(r.pose) ~= "table" or type(r.trail) ~= "table"
      or type(r.trail.tiles) ~= "table" or type(r.trail.segs) ~= "table"
      or type(r.supply) ~= "table" or type(r.supply[1]) ~= "table"
      or type(r.nextTileId) ~= "number" then
      return false
    end
  end
  return true
end

-- Gear the rider will be in after applying `shift` (clamped like resolveMove).
function Rules.gearAfterShift(gear, shift)
  local s = clamp(shift or 0, -Config.gears.maxShift, Config.gears.maxShift)
  return clamp(gear + s, Config.gears.min, Config.gears.max)
end

-- Chance (0..1) that a curve attempted at `gear` succeeds (a numbered face >= gear)
-- and the chance of a spin-out (its own face: curves, then drops to gear 1).
function Rules.curveOdds(gear)
  local die = Config.turnCheck.die
  local numbered = die - 1
  local ok = math.max(0, math.min(numbered, numbered - gear + 1)) / die
  return ok, 1 / die
end

-- Hand mode: may `color` drop a physical tile of (gear, kind) at table position
-- pos = {x, z}? Returns true, shift on success; false, reason otherwise, where
-- reason is "over" | "turn" | "gear" | "far".
function Rules.validateTileDrop(state, color, gear, kind, pos, shape)
  if state.winner then return false, "over" end
  if Rules.currentColor(state) ~= color then return false, "turn" end
  local rider = state.riders[color]
  local shift = gear - rider.gear
  if math.abs(shift) > Config.gears.maxShift then return false, "gear" end
  local center = Geom.tileCenter(kind, gear, rider.pose, shape)
  if Geom.distance(pos, center) > Config.snapRadius then return false, "far" end
  return true, shift
end
