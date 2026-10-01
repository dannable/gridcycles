-- tts/events.lua
-- Glue between the pure rules core and the TTS table: new game, turn order,
-- committing a move, applying a result to the visuals, save/load. (PLAN.md M2/M3.)
--
-- Riders are the seated players' colours (first Config.maxPlayers, in
-- Config.seatOrder). A move may only be committed by the player whose turn it is.

Events = {
  pendingShift = 0,     -- -1 / 0 / +1 for the current rider; reset every turn
}

local function rollFn(n) return math.random(n) end

local function rgb(color)
  local c = Config.palette[color]
  return { c[1], c[2], c[3] }
end

-- Colours of the seated players, capped at maxPlayers, in seatOrder.
local function seatedColors()
  local seated = {}
  for _, p in ipairs(Player.getPlayers()) do
    if p.seated and Config.palette[p.color] then seated[p.color] = true end
  end
  local colors = {}
  for _, c in ipairs(Config.seatOrder) do
    if seated[c] and #colors < Config.maxPlayers then colors[#colors + 1] = c end
  end
  return colors
end

-- Mirror the current turn onto TTS's turn system (turn highlight).
local function syncTurns()
  if State == nil then return end
  Turns.enable = true
  Turns.type = 2                       -- custom order
  Turns.order = State.order
  Turns.turn_color = Rules.currentColor(State)
  Turns.skip_empty_hands = false
  Turns.pass_turns = false             -- we pass turns ourselves
end

-- colors: optional override (tests); defaults to the seated players.
function Events.newGame(colors)
  Events.pendingShift = 0
  colors = colors or seatedColors()
  if #colors == 0 then colors = { "Red" } end   -- nobody seated: solo Red sandbox
  State = Rules.newState(colors, rollFn)
  Spawn.rebuild(State)
  syncTurns()
  UI_.refresh()
  broadcastToAll("New game: " .. table.concat(colors, ", ") .. ". " .. colors[1] .. " goes first.",
    rgb(colors[1]))
end

-- After load: rebuild visuals from saved state.
function Events.restore()
  Events.pendingShift = 0
  Spawn.rebuild(State)
  syncTurns()
  UI_.refresh()
end

-- Is `playerColor` allowed to act now? Tells them why if not.
local function mayAct(playerColor)
  if State == nil then
    broadcastToAll("No game running. Press New game.", { 1, 1, 1 })
    return false
  end
  if State.winner then
    printToColor("The game is over. Press New game.", playerColor, { 1, 1, 1 })
    return false
  end
  local cur = Rules.currentColor(State)
  if playerColor ~= cur then
    printToColor("Not your turn. It's " .. cur .. "'s.", playerColor, rgb(cur))
    return false
  end
  return true
end

function Events.setShift(playerColor, n)
  if not mayAct(playerColor) then return end
  Events.pendingShift = n
  UI_.refresh()
end

local function describe(color, move, r)
  local parts = {}
  if r.roll then parts[#parts + 1] = "rolled " .. r.roll end
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

-- playerColor: the TTS colour of whoever clicked. kind: "straight"|"left"|"right"
function Events.commitMove(playerColor, kind)
  if not mayAct(playerColor) then return end
  local color = playerColor
  local move = { shift = Events.pendingShift, kind = kind }
  Events.pendingShift = 0
  local r = Rules.resolveMove(State, color, move, rollFn)
  apply(color, r)
  broadcastToAll(describe(color, move, r), rgb(color))
  if r.outcome == "win" then
    broadcastToAll("=== " .. string.upper(color) .. " WINS with "
      .. State.riders[color].prizms .. " Prizms! Press New game to race again. ===", rgb(color))
  else
    Rules.advanceTurn(State)
    local nxt = Rules.currentColor(State)
    if nxt ~= color then
      broadcastToAll(nxt .. "'s turn.", rgb(nxt))
    end
  end
  syncTurns()
  UI_.refresh()
end
