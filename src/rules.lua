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
--                             trail = { segs = {Segment...}, tiles = { {kind, gear, entry} } } } },
--     prizms  = { { id, a = Point, b = Point } ... },
--     markers = { { owner = color, segs = { Segment } } ... },   -- capture markers, block like trails
--     nextPrizmId = n,
--   }
--
-- Rules.resolveMove(state, color, move, rollFn) -> result
--   move   = { shift = -1|0|1, kind = "straight"|"left"|"right" }
--   result = { outcome = "placed"|"crash"|"win",
--              gear, roll, spunOut, wentStraight, kind (the tile actually laid),
--              segs, exitPose, captured = {prizmIds...}, spawned = {prizm...},
--              crashReason = "bounds"|"trail" (crash only), respawn = pose (crash only) }

Rules = {}

local function clamp(v, lo, hi)
  if v < lo then return lo elseif v > hi then return hi end
  return v
end

-- uniform float in [0, 1]
local function rand(rollFn)
  return (rollFn(10000) - 1) / 9999
end

local function allTrails(state)
  local list = {}
  for _, color in ipairs(state.order) do
    local r = state.riders[color]
    if r then list[#list + 1] = { owner = color, segs = r.trail.segs } end
  end
  for _, m in ipairs(state.markers) do
    list[#list + 1] = { owner = m.owner, segs = m.segs }
  end
  return list
end

-- Random edge launch point, heading inward. Retries if the point is on a trail.
local function randomLaunch(state, rollFn)
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
    local probe = { a = { x = pose.x, z = pose.z }, b = { x = pose.x, z = pose.z } }
    if not Geom.pathHitsTrails({ probe }, allTrails(state), nil) then return pose end
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
      trail = { segs = {}, tiles = {} },
    }
    state.riders[c].pose = randomLaunch(state, rollFn)
  end
  for _ = 1, Config.prizmsOnTable do
    local p = randomPrizm(state, rollFn)
    if p then state.prizms[#state.prizms + 1] = p end
  end
  return state
end

function Rules.resolveMove(state, color, move, rollFn)
  local rider = state.riders[color]
  assert(rider, "Rules.resolveMove: unknown rider " .. tostring(color))

  -- 1. shift gear
  local shift = clamp(move.shift or 0, -Config.gears.maxShift, Config.gears.maxShift)
  local gear = clamp(rider.gear + shift, Config.gears.min, Config.gears.max)

  -- 2. turn check
  local kind = move.kind
  local roll, spunOut, wentStraight = nil, false, false
  if kind == "left" or kind == "right" then
    roll = rollFn(Config.turnCheck.die)
    if roll >= gear then
      -- curve succeeds
    elseif roll == Config.turnCheck.spinOutRoll and gear >= Config.turnCheck.spinOutMinGear then
      spunOut = true            -- curve happens, gear drops afterwards
    else
      kind = "straight"
      wentStraight = true
    end
  elseif kind ~= "straight" then
    error("Rules.resolveMove: unknown kind " .. tostring(kind))
  end

  -- 3. geometry
  local segs, exitPose = Geom.tilePath(kind, gear, rider.pose)
  local result = {
    gear = gear, roll = roll, spunOut = spunOut, wentStraight = wentStraight,
    kind = kind, segs = segs, exitPose = exitPose, captured = {}, spawned = {},
  }

  -- 4. crash checks
  local crashReason
  if not Geom.inBounds(segs, Config.mat) then
    crashReason = "bounds"
  elseif Geom.pathHitsTrails(segs, allTrails(state), { x = rider.pose.x, z = rider.pose.z }) then
    crashReason = "trail"
  end
  if crashReason then
    rider.trail = { segs = {}, tiles = {} }
    rider.gear = Config.gears.min
    rider.pose = randomLaunch(state, rollFn)
    result.outcome = "crash"
    result.crashReason = crashReason
    result.gear = rider.gear
    result.respawn = { x = rider.pose.x, z = rider.pose.z, heading = rider.pose.heading }
    return result
  end

  -- 5. place tile
  local entry = { x = rider.pose.x, z = rider.pose.z, heading = rider.pose.heading }
  for _, s in ipairs(segs) do
    rider.trail.segs[#rider.trail.segs + 1] = { a = { x = s.a.x, z = s.a.z }, b = { x = s.b.x, z = s.b.z } }
  end
  rider.trail.tiles[#rider.trail.tiles + 1] = { kind = kind, gear = gear, entry = entry }
  rider.pose = { x = exitPose.x, z = exitPose.z, heading = exitPose.heading }
  rider.gear = spunOut and Config.gears.min or gear
  result.gear = rider.gear
  result.outcome = "placed"

  -- 6. captures (a marker replaces the Prizm and blocks like a trail)
  local remaining = {}
  local captured = {}
  for _, p in ipairs(state.prizms) do
    if Geom.pathCrossesPrizm(segs, p) then
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
      or type(r.trail.tiles) ~= "table" or type(r.trail.segs) ~= "table" then
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

-- Chance (0..1) that a curve attempted at `gear` succeeds, and the chance of a
-- spin-out (which also curves, but drops the rider to gear 1).
function Rules.curveOdds(gear)
  local die = Config.turnCheck.die
  local ok = math.max(0, math.min(die, die - gear + 1)) / die
  local spin = 0
  if gear >= Config.turnCheck.spinOutMinGear and Config.turnCheck.spinOutRoll < gear then
    spin = 1 / die
  end
  return ok, spin
end

-- Hand mode: may `color` drop a physical tile of (gear, kind) at table position
-- pos = {x, z}? Returns true, shift on success; false, reason otherwise, where
-- reason is "over" | "turn" | "gear" | "far".
function Rules.validateTileDrop(state, color, gear, kind, pos)
  if state.winner then return false, "over" end
  if Rules.currentColor(state) ~= color then return false, "turn" end
  local rider = state.riders[color]
  local shift = gear - rider.gear
  if math.abs(shift) > Config.gears.maxShift then return false, "gear" end
  local center = Geom.tileCenter(kind, gear, rider.pose)
  if Geom.distance(pos, center) > Config.snapRadius then return false, "far" end
  return true, shift
end
