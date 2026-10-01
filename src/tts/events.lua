-- tts/events.lua
-- Glue between the pure rules core and the TTS table: new game, committing a
-- move, applying a result to the visuals, save/load. (PLAN.md M2; turns/multiplayer M3.)
--
-- M2 is a single-rider loop: one rider (Events.controlled) is moved by UI buttons.

Events = {
  controlled = "Red",   -- M2: the one rider being driven
  pendingShift = 0,     -- -1 / 0 / +1, applied with the next move then reset
}

local function rollFn(n) return math.random(n) end

local function say(msg)
  local c = Config.palette[Events.controlled]
  broadcastToAll(msg, { c[1], c[2], c[3] })
end

function Events.newGame(colors)
  Events.pendingShift = 0
  State = Rules.newState(colors or { Events.controlled }, rollFn)
  Spawn.rebuild(State)
  UI_.refresh()
end

-- After load: rebuild visuals from saved state.
function Events.restore()
  Events.pendingShift = 0
  Spawn.rebuild(State)
  UI_.refresh()
end

function Events.setShift(n)
  Events.pendingShift = n
  UI_.refresh()
end

local function describe(color, move, r)
  local parts = {}
  if r.roll then
    parts[#parts + 1] = "rolled " .. r.roll
  end
  if r.spunOut then
    parts[#parts + 1] = "SPIN-OUT"
  elseif r.wentStraight then
    parts[#parts + 1] = "missed the turn, went straight"
  end
  if r.outcome == "crash" then
    parts[#parts + 1] = "CRASH (" .. r.crashReason .. "), respawning"
  end
  if #r.captured > 0 then
    parts[#parts + 1] = "captured " .. #r.captured .. " Prizm(s)"
  end
  return color .. " " .. move.kind .. " at G" .. tostring(r.gear)
    .. (#parts > 0 and (": " .. table.concat(parts, ", ")) or "")
end

-- Mirror a Rules result onto the table.
local function apply(color, r)
  if r.outcome == "crash" then
    Spawn.clearTrail(color)
    Spawn.rider(color, r.respawn)
    return
  end
  Spawn.tile(color, r.segs)
  Spawn.rider(color, r.exitPose)
  for _, id in ipairs(r.captured) do Spawn.removePrizm(id) end
  local first = #State.markers - #r.captured + 1
  for i = 1, #r.captured do
    Spawn.marker(color, first + i - 1, State.markers[first + i - 1].segs[1])
  end
  for _, p in ipairs(r.spawned) do Spawn.prizm(p) end
end

-- kind: "straight" | "left" | "right"
function Events.commitMove(kind)
  if State == nil then
    broadcastToAll("No game running. Start one first.", { 1, 1, 1 })
    return
  end
  local color = Events.controlled
  local move = { shift = Events.pendingShift, kind = kind }
  Events.pendingShift = 0
  local r = Rules.resolveMove(State, color, move, rollFn)
  apply(color, r)
  say(describe(color, move, r))
  if r.outcome == "win" then
    broadcastToAll(color .. " wins with " .. State.riders[color].prizms .. " Prizms!", { 1, 1, 1 })
  end
  UI_.refresh()
end
