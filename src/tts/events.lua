-- tts/events.lua
-- Glue between the pure rules core and the TTS table: new game, turn order,
-- committing a move, applying a result to the visuals, save/load. (PLAN.md M2/M3.)
--
-- Riders are the seated players' colours (first Config.maxPlayers, in
-- Config.seatOrder). A move may only be committed by the player whose turn it is.

Events = {
  pendingShift = 0,     -- -1 / 0 / +1 for the current rider; reset every turn
  settings = {          -- lobby settings; copied into State.settings when a game starts
    maxPlayers = Config.maxPlayers,
    prizmsToWin = Config.prizmsToWin,
    abilities = Config.abilitiesEnabled,
    mode = Config.placementMode,
  },
}

-- Announce to everyone: chat plus the on-table event log.
local function say(msg, color)
  broadcastToAll(msg, color or { 1, 1, 1 })
  UI_.log(msg)
end

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

-- Only the seats in Config.seatOrder are playable. Move anyone who sat elsewhere
-- (including a seat they just switched to) to a free playable seat, or to
-- spectator if all are taken.
local SPECTATOR = { Grey = true, Black = true }

function Events.enforceSeats()
  for _, p in ipairs(Player.getPlayers()) do
    local c = p.color
    if not Config.palette[c] and not SPECTATOR[c] then
      local free
      for _, seat in ipairs(Config.seatOrder) do
        if Player[seat] ~= nil and not Player[seat].seated then free = seat; break end
      end
      local name = p.steam_name or c
      if free then
        broadcastToAll(name .. ": only " .. table.concat(Config.seatOrder, ", ")
          .. " can play. Moving you to " .. free .. ".", { 1, 1, 1 })
        p.changeColor(free)
      else
        broadcastToAll(name .. ": all four seats are taken, moving you to spectator.", { 1, 1, 1 })
        p.changeColor("Grey")
      end
    end
  end
end

-- Mirror the current turn onto TTS's turn system (turn highlight).
local function syncTurns()
  if State == nil then return end
  local order = {}
  for i, c in ipairs(State.roundOrder) do order[i] = c end   -- copy: don't hand TTS our live table
  Turns.enable = true
  Turns.type = 2                       -- custom order
  Turns.order = order
  Turns.skip_empty_hands = false
  Turns.pass_turns = false             -- we pass turns ourselves
  Turns.turn_color = Rules.currentColor(State)
end

-- Push lobby settings into Config, the single source of tunables.
local function applySettings(s)
  Config.maxPlayers = s.maxPlayers
  Config.prizmsToWin = s.prizmsToWin
  Config.abilitiesEnabled = s.abilities
  Config.placementMode = s.mode
end

-- Back to the lobby: no game, empty mat, settings panel up.
function Events.toLobby()
  State = nil
  Events.pendingShift = 0
  UI_.clearLog()
  Spawn.clearAll()
  Spawn.mat()
  UI_.rebuild({})
end

-- colors: optional override (tests); defaults to the seated players.
function Events.newGame(colors)
  Events.pendingShift = 0
  applySettings(Events.settings)
  colors = colors or seatedColors()
  if #colors == 0 then colors = { "Red" } end   -- nobody seated: solo Red sandbox
  State = Rules.newState(colors, rollFn)
  State.settings = {
    maxPlayers = Events.settings.maxPlayers, prizmsToWin = Events.settings.prizmsToWin,
    abilities = Events.settings.abilities, mode = Events.settings.mode,
  }
  UI_.clearLog()
  Spawn.rebuild(State)
  syncTurns()
  UI_.rebuild(State.order)
  say("New game: " .. table.concat(colors, ", ") .. ". First to hold " .. Config.prizmsToWin
    .. " Prizms of their colour wins. " .. State.roundOrder[1] .. " goes first.", rgb(State.roundOrder[1]))
end

-- Lobby button presses. Settings are host-only.
function Events.lobbyClick(player, action)
  if not player.host then
    printToColor("Only the host can change lobby settings.", player.color, { 1, 1, 1 })
    return
  end
  local s = Events.settings
  if action == "players_dec" then s.maxPlayers = math.max(1, s.maxPlayers - 1)
  elseif action == "players_inc" then s.maxPlayers = math.min(4, s.maxPlayers + 1)
  elseif action == "prizms_dec" then s.prizmsToWin = math.max(1, s.prizmsToWin - 1)
  elseif action == "prizms_inc" then s.prizmsToWin = math.min(6, s.prizmsToWin + 1)
  elseif action == "abilities" then s.abilities = not s.abilities
  elseif action == "mode" then
    s.mode = (s.mode == "hand") and "commit" or "hand"
  elseif action == "start" then
    if State == nil then Events.newGame() end
    return
  elseif action == "menu" then
    Events.toLobby()
    return
  end
  UI_.refresh()
end

-- After load: rebuild visuals from saved state.
function Events.restore()
  Events.pendingShift = 0
  if type(State.settings) == "table" then
    Events.settings = State.settings
  end
  applySettings(Events.settings)
  Spawn.rebuild(State)
  syncTurns()
  UI_.rebuild(State.order)
end

-- Is `playerColor` allowed to act now? Tells them why if not.
local function mayAct(playerColor)
  if State == nil then
    broadcastToAll("No game running. The host starts one from the lobby.", { 1, 1, 1 })
    return false
  end
  if State.winner then
    printToColor("The game is over. The host can go back to the lobby.", playerColor, { 1, 1, 1 })
    return false
  end
  if State.pendingGear then
    printToColor(State.pendingGear .. " is choosing a respawn gear.", playerColor, rgb(State.pendingGear))
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
  if r.roll then
    parts[#parts + 1] = (r.roll == Config.turnCheck.die) and "rolled the SPIN-OUT face" or ("rolled " .. r.roll)
  end
  if r.spunOut then
    parts[#parts + 1] = "SPIN-OUT, drops to G1"
  elseif r.wentStraight then
    parts[#parts + 1] = "missed the turn, went straight"
  end
  if r.removedTiles and #r.removedTiles > 0 then
    parts[#parts + 1] = "out of tiles: gave up their " .. #r.removedTiles .. " oldest"
  end
  if r.substituted then parts[#parts + 1] = "used a lower/other tile" end
  if r.outcome == "crash" then
    local why = r.crashReason
    if r.crashReason == "bike" then why = "hit " .. r.crashOwner .. "'s bike"
    elseif r.crashReason == "supply" then why = "no tile available" end
    parts[#parts + 1] = "CRASH (" .. why .. "), respawning"
  end
  if r.scored and #r.scored > 0 then
    parts[#parts + 1] = "scored " .. #r.scored .. " Prizm(s)"
  end
  for _, st in ipairs(r.stolen or {}) do
    parts[#parts + 1] = "STOLE a Prizm from " .. st.from
  end
  if r.nudged and #r.nudged > 0 then
    parts[#parts + 1] = "nudged " .. #r.nudged .. " Prizm(s) clear"
  end
  if r.victim and #r.victim.removedTiles > 0 then
    parts[#parts + 1] = r.victim.color .. " loses " .. #r.victim.removedTiles .. " tile(s)"
  end
  local what = (r.shape and r.shape ~= "straight" and (r.shape .. " ") or "") .. (r.kind or move.kind)
  return color .. " " .. what .. " (G" .. tostring(r.tileGear or r.gear) .. " tile)"
    .. (#parts > 0 and (": " .. table.concat(parts, ", ")) or "")
end

-- Redraw a Prizm from state (new owner colour, or a new spot after a nudge).
local function refreshPrizm(id)
  Spawn.removePrizm(id)
  for _, p in ipairs(State.prizms) do
    if p.id == id then Spawn.prizm(p) end
  end
end

-- Mirror a Rules result onto the table.
local function apply(color, r)
  if r.victim then
    for _, id in ipairs(r.victim.removedTiles) do Spawn.removeTile(r.victim.color, id) end
  end
  if r.outcome == "crash" then
    Spawn.clearTrail(color)
    Spawn.rider(color, r.respawn)
    return
  end
  for _, id in ipairs(r.removedTiles or {}) do Spawn.removeTile(color, id) end
  Spawn.tile(color, r.segs, r.tileGear, r.shape, State.riders[color].nextTileId - 1)
  Spawn.rider(color, r.exitPose)
  for _, id in ipairs(r.scored) do refreshPrizm(id) end
  for _, st in ipairs(r.stolen) do refreshPrizm(st.id) end
  for _, id in ipairs(r.nudged) do refreshPrizm(id) end
  for _, p in ipairs(r.spawned) do Spawn.prizm(p) end
end

-- "Round 2 order: Red, Blue." Logged whenever a round starts.
local function announceRound()
  say("Round " .. State.round .. " order: " .. table.concat(State.roundOrder, ", ") .. ".",
    rgb(State.roundOrder[1]))
end

-- playerColor: the TTS colour of whoever clicked. kind: "straight"|"left"|"right";
-- curve: "soft"|"hard" (curves only).
-- The mover's turn is over: pass play on (starting a new round if that was the last turn).
local function endTurn(color)
  local newRound = Rules.advanceTurn(State)
  local nxt = Rules.currentColor(State)
  if newRound and #State.order > 1 then
    announceRound()
  elseif nxt ~= color then
    say(nxt .. "'s turn.", rgb(nxt))
  end
  syncTurns()
  UI_.refresh()
end

function Events.commitMove(playerColor, kind, curve)
  if not mayAct(playerColor) then return end
  local color = playerColor
  local move = { shift = Events.pendingShift, kind = kind, curve = curve or "soft" }
  Events.pendingShift = 0
  local r = Rules.resolveMove(State, color, move, rollFn)
  apply(color, r)
  say(describe(color, move, r), rgb(color))
  if r.outcome == "win" then
    say("=== " .. string.upper(color) .. " WINS with "
      .. Rules.prizmCount(State, color) .. " Prizms! Host: Back to lobby to race again. ===", rgb(color))
    syncTurns()
    UI_.refresh()
  elseif r.outcome == "crash" then
    -- the turn is not over until the crashed rider picks the gear they respawn in
    say(color .. ", choose your respawn gear.", rgb(color))
    syncTurns()
    UI_.refresh()
  else
    endTurn(color)
  end
end

-- A crashed rider picks their respawn gear (the host may pick for them, so an absent
-- player can't stall the table). `player` is the clicking TTS player: { color, host }.
function Events.chooseGear(player, gear)
  if State == nil or not State.pendingGear then return end
  local color = State.pendingGear
  if player.color ~= color and not player.host then
    printToColor("Only " .. color .. " (or the host) can choose that.", player.color, { 1, 1, 1 })
    return
  end
  local ok = Rules.chooseGear(State, color, gear)
  if not ok then return end
  say(color .. " respawns in G" .. gear .. ".", rgb(color))
  endTurn(color)
end

-- Hand mode: a tile was dropped. Whatever happens, it goes back to its tray slot;
-- if the drop was legal, the move is committed through the normal pipeline.
local DROP_MESSAGES = {
  turn = "It isn't your turn.",
  pick = "A crashed rider has to choose a respawn gear first.",
  over = "The game is over.",
  gear = "That tile is more than %d gear(s) from your current gear (G%d).",
  far  = "Drop the tile closer to where your trail ends.",
}

function Events.handleDrop(playerColor, obj)
  if State == nil or obj == nil then return end
  local owner, gear, kind, shape = Spawn.parseTileName(obj.getName())
  if owner == nil or State.riders[owner] == nil then return end   -- not one of our tiles
  if Config.placementMode ~= "hand" then Spawn.returnTile(obj) return end
  if playerColor ~= owner then
    printToColor("That's " .. owner .. "'s tile.", playerColor, rgb(owner))
    Spawn.returnTile(obj)
    return
  end
  local p = obj.getPosition()
  local ok, v = Rules.validateTileDrop(State, owner, gear, kind, { x = p.x, z = p.z }, shape)
  Spawn.returnTile(obj)
  if not ok then
    local msg = DROP_MESSAGES[v]
    if v == "gear" then
      msg = string.format(msg, Config.gears.maxShift, State.riders[owner].gear)
    end
    printToColor(msg, playerColor, { 1, 1, 1 })
    return
  end
  Events.pendingShift = v
  Events.commitMove(owner, kind, shape ~= "straight" and shape or nil)
end
