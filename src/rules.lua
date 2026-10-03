-- rules.lua
-- Pure turn resolution. NO TTS API calls: takes state + inputs, returns a result.
-- Randomness is injected (rollFn) so tests are deterministic.
--
-- rollFn(n) -> integer in 1..n  (the same function rolls the d6 and picks spawn points)
--
-- State (plain tables, JSON-safe):
--   state = {
--     version = Rules.STATE_VERSION,
--     order   = { color... },         -- seating order (clockwise); never changes
--     roundOrder = { color... },      -- who plays this round, fastest gear first
--     turn = n,                       -- index into roundOrder
--     round = n, tieBreaker = n,      -- tieBreaker: index into order, rotates each round
--     riders  = { [color] = { gear, pose = {x,z,heading},
--                             supply = { [gear] = { straight = n, soft = n, hard = n } },
--                             nextTileId = n,
--                             trail = { segs = {Segment...},   -- flat, each seg carries its tile id
--                                       tiles = { {id, kind, shape, gear, entry} ... } } } },  -- oldest first
--     prizms  = { { id, a = Point, b = Point, owner = color|nil } ... },   -- owner nil = unscored
--     nextPrizmId = n,
--     winner = color|false,
--     pendingGear = color|false,      -- a rider who crashed and must choose their respawn gear
--     bonusMove = color|false,        -- an Overclocking rider who still has their second move
--   }
--   Each rider also has `ability` (id or nil) and `charged`; see src/riders/riders.lua.
--
-- Pieces: every tile has a gear and a shape ("straight" | "soft" | "hard"); riders own a
-- limited supply of each (Config.tileSupply). See Rules.planPiece for what happens
-- when the wanted piece has run out.
--
-- Prizms: crossing an unscored Prizm scores it (it takes your colour and stays where it
-- is); crossing someone else's scored Prizm steals it. A line that stops on top of a
-- Prizm (within Config.prizm.onAxis of its axis) finishes crossing it with its next tile. You win with Config.prizmsToWin
-- of your colour on the table at once. Contact on top of any Prizm never crashes.
-- A rider's bike is part of their trail (Geom.bikeSeg), blocking everyone but its owner.
--
-- Rules.resolveMove(state, color, move, rollFn) -> result
--   move   = { shift = -1|0|1, kind = "straight"|"left"|"right", curve = "soft"|"hard",
--              boost = bool (Volt Vixen: a failed check still curves),
--              overclock = bool (Overclock: drop to G1, then a second move) }
--   Ability flags the rider can't use are ignored. Echo may shift further (Riders.maxShift).
--   result = { outcome = "placed"|"crash"|"win",
--              gear (rider's gear afterwards), roll, spunOut, wentStraight,
--              kind (the tile actually laid), tileGear / shape (the piece used),
--              substituted (true if a lower gear or other curve shape was used),
--              removedTiles = { id... } (oldest tiles given up to get a piece),
--              segs, exitPose,
--              scored = { prizmId... }  (unscored Prizms you took),
--              stolen = { { id, from = color } ... },
--              nudged = { prizmId... }, spawned = { prizm... } (new unscored Prizms),
--              crashReason = "bounds"|"trail"|"bike"|"supply" (crash only), crashOwner = colour
--              whose trail/bike was hit (not for "bounds"), respawn = pose (crash only),
--              victim = { color, removedTiles = { id... } } (crash into someone else's trail),
--              boosted (Volt Vixen's charge saved a failed check), overclock (this move was
--              an Overclock, first or second), bonusMove (the rider moves again now),
--              gridlock = { { color, tileId }... } (rival tiles Gridlock removed) }

Rules = {}

Rules.STATE_VERSION = 3

local function clamp(v, lo, hi)
  if v < lo then return lo elseif v > hi then return hi end
  return v
end

-- uniform float in [0, 1]
local function rand(rollFn)
  return (rollFn(10000) - 1) / 9999
end

-- Everything a new path can crash into: every trail and every bike.
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
  return list
end

-- Contact right on top of a Prizm is harmless: a Prizm is a gap in any wall.
local function passFn(state)
  return function(pt)
    for _, p in ipairs(state.prizms) do
      if Geom.pointSegDist(pt, p) <= Config.prizm.passRadius then return true end
    end
    return false
  end
end

function Rules.prizmCount(state, color)
  local n = 0
  for _, p in ipairs(state.prizms) do
    if p.owner == color then n = n + 1 end
  end
  return n
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

-- Is a Prizm segment clear of every wall and bike (by nudgeClear), every other
-- Prizm, and inside the mat? `ignoreId` skips the Prizm being moved.
local function prizmFits(state, seg, ignoreId)
  if not Geom.inBounds({ seg }, Config.mat) then return false end
  for _, t in ipairs(allTrails(state)) do
    if Geom.pathDistance(t.segs, seg) < Config.prizm.nudgeClear then return false end
  end
  for _, p in ipairs(state.prizms) do
    if p.id ~= ignoreId and Geom.segmentDistance(seg, p) < Config.prizm.nudgeClear then return false end
  end
  return true
end

local function newPrizmSeg(cx, cz, ang)
  local half = Config.prizm.length / 2
  local dx, dz = math.sin(ang) * half, math.cos(ang) * half
  return { a = { x = cx - dx, z = cz - dz }, b = { x = cx + dx, z = cz + dz } }
end

-- Toss a new unscored Prizm at a random free spot away from the mat edge.
local function randomPrizm(state, rollFn)
  local mat = Config.mat
  local hw = mat.width / 2 - Config.prizmEdgeMargin
  local hd = mat.depth / 2 - Config.prizmEdgeMargin
  local prizm
  for _ = 1, Config.spawnTries do
    local cx = (rand(rollFn) * 2 - 1) * hw
    local cz = (rand(rollFn) * 2 - 1) * hd
    local seg = newPrizmSeg(cx, cz, rand(rollFn) * math.pi)
    if prizmFits(state, seg) then
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

-- Segments of a tile, each tagged with the tile's id so a hit can be traced back to it.
local function tileSegs(tile)
  local segs = Geom.tilePath(tile.kind, tile.gear, tile.entry, tile.shape)
  for _, sg in ipairs(segs) do sg.tile = tile.id end
  return segs
end

local function segsOf(tiles)
  local segs = {}
  for _, t in ipairs(tiles) do
    for _, sg in ipairs(tileSegs(t)) do segs[#segs + 1] = sg end
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

-- Someone crashed into tile `tileId` of `owner`'s line: that tile and every older one
-- come off, but their front-most tile always stays. Returns the removed ids.
local function hitVictim(state, owner, tileId)
  local rider = state.riders[owner]
  local idx
  for i, t in ipairs(rider.trail.tiles) do
    if t.id == tileId then idx = i end
  end
  if idx == nil then return {} end
  return removeOldest(rider, math.min(idx, #rider.trail.tiles - 1))
end

-- Round order: fastest gear first. Ties go to whoever comes first clockwise from the
-- tie-breaker marker (which moves one seat on after every round).
local function startRound(state)
  local n = #state.order
  local keyed = {}
  for i, c in ipairs(state.order) do
    keyed[i] = { color = c, gear = state.riders[c].gear, away = (i - state.tieBreaker) % n }
  end
  table.sort(keyed, function(a, b)
    if a.gear ~= b.gear then return a.gear > b.gear end
    return a.away < b.away
  end)
  state.roundOrder = {}
  for i, k in ipairs(keyed) do state.roundOrder[i] = k.color end
  state.turn = 1
end

function Rules.newState(colors, rollFn)
  rollFn = rollFn or function(n) return math.random(n) end
  local state = {
    version = Rules.STATE_VERSION,
    order = {},
    roundOrder = {},
    riders = {},
    prizms = {},
    nextPrizmId = 1,
    turn = 1,          -- index into roundOrder
    round = 1,
    tieBreaker = 1,
    winner = false,    -- colour of the winner once the game is won
    pendingGear = false,
    bonusMove = false,
  }
  for i, c in ipairs(colors) do state.order[i] = c end
  for _, c in ipairs(state.order) do
    state.riders[c] = {
      gear = Config.gears.min,
      pose = nil,
      supply = fullSupply(),
      nextTileId = 1,
      trail = { segs = {}, tiles = {} },
    }
    state.riders[c].pose = randomLaunch(state, rollFn, c)
  end
  -- unscored Prizms: evenly spaced on a ring around the centre, random orientation
  local count = #state.order * Config.neutralPrizmsPerPlayer
  local start = rand(rollFn) * 2 * math.pi
  for i = 1, count do
    local a = start + (i - 1) * 2 * math.pi / count
    local seg = newPrizmSeg(math.sin(a) * Config.prizmRingRadius, math.cos(a) * Config.prizmRingRadius,
      rand(rollFn) * math.pi)
    seg.id = state.nextPrizmId
    state.nextPrizmId = state.nextPrizmId + 1
    state.prizms[#state.prizms + 1] = seg
  end
  if Config.abilitiesEnabled then Riders.deal(state, rollFn) end
  startRound(state)
  return state
end

-- Wipe the rider's trail (returning their whole tile supply) and respawn them.
-- Scored Prizms stay on the table. The rider then picks their starting gear
-- (Rules.chooseGear); until they do, state.pendingGear names them and the turn
-- does not pass. The gear is G1 until chosen.
function Rules.crash(state, color, reason, owner, rollFn)
  local rider = state.riders[color]
  rider.trail = { segs = {}, tiles = {} }
  rider.supply = fullSupply()
  rider.gear = Config.gears.min
  rider.pose = randomLaunch(state, rollFn, color)
  Riders.onRespawn(rider)
  state.pendingGear = color
  state.bonusMove = false
  return {
    outcome = "crash", crashReason = reason, crashOwner = owner,
    gear = rider.gear, captured = {}, spawned = {}, scored = {}, stolen = {}, nudged = {}, gridlock = {},
    respawn = { x = rider.pose.x, z = rider.pose.z, heading = rider.pose.heading },
  }
end

-- Is this Prizm locked (it will not be nudged)? Yes if it sits on its owner's own line,
-- or lines of two different colours touch it.
local function isLocked(state, prizm)
  local touching = {}
  local n = 0
  for _, c in ipairs(state.order) do
    local segs = state.riders[c].trail.segs
    if #segs > 0 and Geom.pathDistance(segs, prizm) <= Config.prizm.touchDist then
      if prizm.owner == c then return true end
      touching[c] = true
      n = n + 1
    end
  end
  return n >= 2
end

-- Push a free Prizm away from the path that touched it, as little as possible, until
-- it clears every wall by nudgeClear. Returns true if it moved.
local function nudge(state, prizm, path)
  -- nearest point of the new path to the Prizm's centre
  local cx, cz = (prizm.a.x + prizm.b.x) / 2, (prizm.a.z + prizm.b.z) / 2
  local best, bx, bz = math.huge, 0, 0
  for _, s in ipairs(path) do
    local dx, dz = s.b.x - s.a.x, s.b.z - s.a.z
    local len2 = dx * dx + dz * dz
    local t = len2 > 0 and clamp(((cx - s.a.x) * dx + (cz - s.a.z) * dz) / len2, 0, 1) or 0
    local px, pz = s.a.x + t * dx, s.a.z + t * dz
    local d = math.sqrt((cx - px) ^ 2 + (cz - pz) ^ 2)
    if d < best then best, bx, bz = d, px, pz end
  end
  local ux, uz
  if best > 1e-6 then
    ux, uz = (cx - bx) / best, (cz - bz) / best
  else                                  -- centred on the wall: push sideways off the axis
    local ax, az = prizm.b.x - prizm.a.x, prizm.b.z - prizm.a.z
    local l = math.sqrt(ax * ax + az * az)
    ux, uz = -az / l, ax / l
  end
  -- try straight away first, then fan out either side
  for _, turn in ipairs({ 0, 30, -30, 60, -60, 90, -90 }) do
    local th = math.rad(turn)
    local vx = ux * math.cos(th) - uz * math.sin(th)
    local vz = ux * math.sin(th) + uz * math.cos(th)
    for step = 0, 80 do
      local d = step * 0.05
      local seg = { a = { x = prizm.a.x + vx * d, z = prizm.a.z + vz * d },
                    b = { x = prizm.b.x + vx * d, z = prizm.b.z + vz * d } }
      if prizmFits(state, seg, prizm.id) then
        if d == 0 then return false end
        prizm.a, prizm.b = seg.a, seg.b
        return true
      end
    end
  end
  return false
end

-- Gridlock: remove the rival tile nearest to Prizm `prizm`, if one lies within
-- gridlockReach. Front tiles (a bike sits on them) are never taken. The piece goes
-- back to its owner. Returns { color, tileId } or nil.
local function gridlockNearest(state, color, prizm)
  local best, bestColor, bestIdx = Config.abilities.gridlockReach, nil, nil
  for _, c in ipairs(state.order) do
    local tiles = state.riders[c].trail.tiles
    if c ~= color then
      for i = 1, #tiles - 1 do
        local d = Geom.pathDistance(tileSegs(tiles[i]), prizm)
        if d <= best then best, bestColor, bestIdx = d, c, i end
      end
    end
  end
  if bestColor == nil then return nil end
  local victim = state.riders[bestColor]
  local t = table.remove(victim.trail.tiles, bestIdx)
  victim.supply[t.gear][t.shape] = (victim.supply[t.gear][t.shape] or 0) + 1
  victim.trail.segs = segsOf(victim.trail.tiles)
  return { color = bestColor, tileId = t.id }
end

function Rules.resolveMove(state, color, move, rollFn)
  local rider = state.riders[color]
  assert(rider, "Rules.resolveMove: unknown rider " .. tostring(color))

  -- 1. shift gear. An Overclock (first or second move) is always at the lowest gear.
  local overclock, firstOverclock = false, false
  if state.bonusMove == color then
    overclock = true
    state.bonusMove = false
  elseif move.overclock and Riders.canOverclock(rider) then
    overclock, firstOverclock = true, true
    rider.charged = false
  end
  local gear
  if overclock then
    gear = Config.gears.min
  else
    gear = Rules.gearAfterShift(rider.gear, move.shift, Riders.maxShift(rider))
  end

  -- 2. turn check: the curve die has numbered faces and one spin-out face
  local kind = move.kind
  local want = "straight"
  local shape = move.curve or "soft"
  local roll, spunOut, wentStraight, boosted = nil, false, false, false
  if kind == "left" or kind == "right" then
    want = "curve"
    roll = rollFn(Config.turnCheck.die)
    if roll == Config.turnCheck.die then
      spunOut = true            -- curve happens, gear drops afterwards
    elseif roll >= gear then
      -- curve succeeds
    elseif move.boost and Riders.canBoost(rider) then
      boosted = true            -- Volt Vixen: the failed check curves anyway
      rider.charged = false
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
    boosted = boosted, overclock = overclock, bonusMove = false,
    kind = kind, segs = segs, exitPose = exitPose,
    scored = {}, stolen = {}, nudged = {}, spawned = {}, gridlock = {},
  }

  -- 4. crash checks
  local crashReason, crashOwner, hitTile
  if not Geom.inBounds(segs, Config.mat) then
    crashReason = "bounds"
  else
    local hit, trail, oldSeg = Geom.pathHitsTrails(segs, allTrails(state, color),
      { x = rider.pose.x, z = rider.pose.z }, passFn(state))
    if hit then
      crashReason = trail.kind == "bike" and "bike" or "trail"
      crashOwner = trail.owner
      if crashReason == "trail" and trail.owner ~= color then hitTile = oldSeg.tile end
    end
  end
  if crashReason then
    local victimRemoved
    if hitTile then victimRemoved = hitVictim(state, crashOwner, hitTile) end
    local r = Rules.crash(state, color, crashReason, crashOwner, rollFn)
    r.segs, r.exitPose, r.kind, r.tileGear, r.shape = segs, exitPose, kind, pieceGear, pieceShape
    r.roll, r.spunOut, r.wentStraight = roll, spunOut, wentStraight
    r.boosted, r.overclock, r.bonusMove = boosted, overclock, false
    r.substituted, r.removedTiles = substituted, removedTiles
    if victimRemoved then r.victim = { color = crashOwner, removedTiles = victimRemoved } end
    return r
  end

  -- the tile laid before this one: a line that stopped on top of a Prizm can finish
  -- crossing it now
  local front = rider.trail.tiles[#rider.trail.tiles]
  local leadIn = front and tileSegs(front) or nil

  -- 5. place tile
  local entry = { x = rider.pose.x, z = rider.pose.z, heading = rider.pose.heading }
  local tile = {
    id = rider.nextTileId, kind = kind, shape = pieceShape, gear = pieceGear, entry = entry,
  }
  rider.nextTileId = rider.nextTileId + 1
  rider.trail.tiles[#rider.trail.tiles + 1] = tile
  for _, sg in ipairs(tileSegs(tile)) do rider.trail.segs[#rider.trail.segs + 1] = sg end
  rider.supply[pieceGear][pieceShape] = rider.supply[pieceGear][pieceShape] - 1
  rider.pose = { x = exitPose.x, z = exitPose.z, heading = exitPose.heading }
  rider.gear = spunOut and Config.gears.min or gear
  result.gear = rider.gear
  result.outcome = "placed"

  -- 6. scoring: cross an unscored Prizm to take it, someone else's to steal it
  local took = {}
  for _, p in ipairs(state.prizms) do
    if p.owner ~= color and Geom.pathCrossesPrizm(segs, p, Config.prizm.endSlack, Config.prizm.onAxis, leadIn) then
      if p.owner == nil then
        result.scored[#result.scored + 1] = p.id
      else
        result.stolen[#result.stolen + 1] = { id = p.id, from = p.owner }
      end
      p.owner = color
      took[p.id] = true
      if rider.ability == "gridlock" then
        local hit = gridlockNearest(state, color, p)
        if hit then result.gridlock[#result.gridlock + 1] = hit end
      end
    end
  end

  if Rules.prizmCount(state, color) >= Config.prizmsToWin then
    result.outcome = "win"
    state.winner = color
    return result
  end

  -- 7. a tile that touched an unscored, unlocked Prizm without taking it nudges it clear,
  -- unless the tile stopped on top of it (the next tile can finish crossing it)
  for _, p in ipairs(state.prizms) do
    if not took[p.id] and Geom.pathDistance(segs, p) <= Config.prizm.touchDist and not isLocked(state, p)
      and Geom.pointSegDist(exitPose, p) > Config.prizm.onAxis then
      if nudge(state, p, segs) then result.nudged[#result.nudged + 1] = p.id end
    end
  end

  -- 8. top the table back up: a new unscored Prizm for each one scored
  for _ = 1, #result.scored do
    local np = randomPrizm(state, rollFn)
    if np then
      state.prizms[#state.prizms + 1] = np
      result.spawned[#result.spawned + 1] = np
    end
  end

  -- 9. Overclock: the first move earns a second one, straight away
  if firstOverclock then
    state.bonusMove = color
    result.bonusMove = true
  end
  return result
end

-- A rider who just crashed picks any gear to respawn in. Returns true, or false and a
-- reason: "none" (nobody is choosing), "who" (not that rider), "range" (no such gear).
function Rules.chooseGear(state, color, gear)
  if not state.pendingGear then return false, "none" end
  if state.pendingGear ~= color then return false, "who" end
  if type(gear) ~= "number" or gear ~= math.floor(gear)
    or gear < Config.gears.min or gear > Config.gears.max then return false, "range" end
  state.riders[color].gear = gear
  state.pendingGear = false
  return true
end

function Rules.currentColor(state)
  return state.roundOrder[state.turn]
end

-- Pass play to the next rider this round; after the last, start a new round (the order
-- is re-sorted by gear and the tie-breaker moves on). Returns true if a new round began.
-- No-op once the game is won, while a crashed rider still has to choose their gear, or
-- while an Overclocking rider still has their second move.
function Rules.advanceTurn(state)
  if state.winner or state.pendingGear or state.bonusMove then return false end
  if state.turn < #state.roundOrder then
    state.turn = state.turn + 1
    return false
  end
  state.tieBreaker = state.tieBreaker % #state.order + 1
  state.round = state.round + 1
  startRound(state)
  return true
end

-- True if `state` (e.g. decoded from a save) has the shape this version expects.
-- Older or corrupt saves fail this and the game starts fresh.
function Rules.isValidState(state)
  if type(state) ~= "table" or state.version ~= Rules.STATE_VERSION then return false end
  if type(state.order) ~= "table" or #state.order == 0 then return false end
  if type(state.roundOrder) ~= "table" or type(state.turn) ~= "number"
    or state.roundOrder[state.turn] == nil then return false end
  if type(state.round) ~= "number" or type(state.tieBreaker) ~= "number" then return false end
  if type(state.riders) ~= "table" or type(state.prizms) ~= "table" then return false end
  if state.pendingGear and state.riders[state.pendingGear] == nil then return false end
  if state.bonusMove and state.riders[state.bonusMove] == nil then return false end
  for _, c in ipairs(state.order) do
    local r = state.riders[c]
    if type(r) ~= "table" or type(r.pose) ~= "table" or type(r.trail) ~= "table"
      or type(r.trail.tiles) ~= "table" or type(r.trail.segs) ~= "table"
      or type(r.supply) ~= "table" or type(r.supply[1]) ~= "table"
      or type(r.nextTileId) ~= "number" or not Riders.isValid(r) then
      return false
    end
  end
  return true
end

-- Gear the rider will be in after applying `shift` (clamped like resolveMove).
-- maxShift: the rider's limit (Riders.maxShift); defaults to Config.gears.maxShift.
function Rules.gearAfterShift(gear, shift, maxShift)
  local m = maxShift or Config.gears.maxShift
  local s = clamp(shift or 0, -m, m)
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
-- pos = {x, z}? overclock: the rider is starting an Overclock (the tile must then be
-- G1, as must the second move). Returns true, shift on success; false, reason
-- otherwise, where reason is "over" | "pick" | "turn" | "gear" | "far".
function Rules.validateTileDrop(state, color, gear, kind, pos, shape, overclock)
  if state.winner then return false, "over" end
  if state.pendingGear then return false, "pick" end
  if Rules.currentColor(state) ~= color then return false, "turn" end
  local rider = state.riders[color]
  local shift = gear - rider.gear
  if state.bonusMove == color or (overclock and Riders.canOverclock(rider)) then
    if gear ~= Config.gears.min then return false, "gear" end
  elseif math.abs(shift) > Riders.maxShift(rider) then
    return false, "gear"
  end
  local center = Geom.tileCenter(kind, gear, rider.pose, shape)
  if Geom.distance(pos, center) > Config.snapRadius then return false, "far" end
  return true, shift
end
