-- tts/ui.lua
-- All on-table UI (PLAN.md M4): lobby settings, per-rider control panels, status
-- and event-log panel. The XML is generated here (UI_.buildXml) because rider
-- panels depend on who is seated; ui/Global.xml is just a boot stub.
--
-- Element ids:  gcLobby, gcl_*  lobby      gcStatusPanel, gcStatus, gcScore, gcRiders, gcOrder, gcLog
--               gcPick_<Color>, gcb_<Color>_gear<N>  respawn gear picker
--               gcPanel_<Color>, gcGear_<Color>, gcOdds_<Color>, gcAbility_<Color>, gcb_<Color>_<action>
--               (abilities: gcb_<Color>_shiftdown2 / shiftup2 for Echo, _boost, _overclock)
-- Every button uses onClick="gcClick"; the id says what was pressed.

UI_ = {}  -- UI is a reserved TTS global; use UI_ for our helpers

local SHIFT_NAMES = { [-2] = "down 2", [-1] = "down", [0] = "hold", [1] = "up", [2] = "up 2" }
local SHIFT_ACTIONS = { shiftdown2 = -2, shiftdown = -1, shifthold = 0, shiftup = 1, shiftup2 = 2 }
local ABILITY_ACTIONS = { boost = true, overclock = true }

-- The current game's ability for `color` (nil in the lobby or with abilities off).
local function abilityOf(color)
  local r = State and State.riders and State.riders[color]
  return r and r.ability or nil
end

-- Does this rider's panel have the button for a shift of `v`? (+-2 is Echo only.)
local function hasShift(color, v)
  return math.abs(v) <= Config.gears.maxShift or abilityOf(color) == "echo"
end
-- action -> { kind, curve }
local MOVE_ACTIONS = {
  hardleft = { "left", "hard" }, softleft = { "left", "soft" }, straight = { "straight" },
  softright = { "right", "soft" }, hardright = { "right", "hard" },
}

local LOG_LINES = 7
local logLines = {}

local function hex(color)
  local c = Config.palette[color] or { 1, 1, 1 }
  local function h(v) return string.format("%02X", math.floor(v * 255 + 0.5)) end
  return "#" .. h(c[1]) .. h(c[2]) .. h(c[3])
end

---------------------------------------------------------------- XML

local function button(id, label, color, textColor, extra)
  return string.format('<Button id="%s" onClick="gcClick" color="%s" textColor="%s"%s>%s</Button>',
    id, color, textColor or "#FFFFFF", extra or "", label)
end

local function lobbyXml()
  return [[
<Panel id="gcLobby" active="true" width="440" height="404" rectAlignment="MiddleCenter"
       color="#0A0618F2" padding="16 16 16 16">
  <VerticalLayout spacing="10">
    <Text fontSize="30" color="#05D9E8" alignment="MiddleCenter" fontStyle="Bold">GRIDCYCLES</Text>
    <Text fontSize="14" color="#D9C8FF" alignment="MiddleCenter">Lobby settings (host only)</Text>
    <HorizontalLayout spacing="8">
      <Text fontSize="18" color="#FFFFFF" alignment="MiddleLeft">Max players</Text>
      <Button id="gcl_players_dec" onClick="gcClick" color="#2A1B5C" textColor="#FFFFFF" preferredWidth="40">-</Button>
      <Text id="gcl_players_val" fontSize="20" color="#39FF14" alignment="MiddleCenter" preferredWidth="40">4</Text>
      <Button id="gcl_players_inc" onClick="gcClick" color="#2A1B5C" textColor="#FFFFFF" preferredWidth="40">+</Button>
    </HorizontalLayout>
    <HorizontalLayout spacing="8">
      <Text fontSize="18" color="#FFFFFF" alignment="MiddleLeft">Prizms to win</Text>
      <Button id="gcl_prizms_dec" onClick="gcClick" color="#2A1B5C" textColor="#FFFFFF" preferredWidth="40">-</Button>
      <Text id="gcl_prizms_val" fontSize="20" color="#39FF14" alignment="MiddleCenter" preferredWidth="40">3</Text>
      <Button id="gcl_prizms_inc" onClick="gcClick" color="#2A1B5C" textColor="#FFFFFF" preferredWidth="40">+</Button>
    </HorizontalLayout>
    <HorizontalLayout spacing="8">
      <Text fontSize="18" color="#FFFFFF" alignment="MiddleLeft">Rider abilities</Text>
      <Button id="gcl_abilities" onClick="gcClick" color="#2A1B5C" textColor="#39FF14" preferredWidth="120">ON</Button>
    </HorizontalLayout>
    <HorizontalLayout spacing="8">
      <Text fontSize="18" color="#FFFFFF" alignment="MiddleLeft">Starting gear</Text>
      <Button id="gcl_blindstart" onClick="gcClick" color="#2A1B5C" textColor="#39FF14" preferredWidth="120">Blind pick</Button>
    </HorizontalLayout>
    <HorizontalLayout spacing="8">
      <Text fontSize="18" color="#FFFFFF" alignment="MiddleLeft">Placement</Text>
      <Button id="gcl_mode" onClick="gcClick" color="#2A1B5C" textColor="#39FF14" preferredWidth="120">Commit</Button>
    </HorizontalLayout>
    <Text id="gcl_seats" fontSize="14" color="#D9C8FF" alignment="MiddleCenter"></Text>
    <Button id="gcl_start" onClick="gcClick" color="#39FF14" textColor="#000000" fontSize="22" preferredHeight="48">START RACE</Button>
  </VerticalLayout>
</Panel>]]
end

local function statusXml()
  return [[
<Panel id="gcStatusPanel" active="false" width="360" height="296" rectAlignment="UpperRight"
       offsetXY="-20 -70" color="#0A0618D9" padding="10 10 10 10">
  <VerticalLayout spacing="4">
    <Text id="gcStatus" fontSize="18" color="#05D9E8" alignment="MiddleCenter" preferredHeight="28">Gridcycles</Text>
    <Text id="gcScore" fontSize="14" color="#D9C8FF" alignment="MiddleCenter" preferredHeight="22"></Text>
    <Text id="gcRiders" fontSize="12" color="#D9C8FF" alignment="MiddleCenter" preferredHeight="20"></Text>
    <Text id="gcOrder" fontSize="13" color="#9A8FC0" alignment="MiddleCenter" preferredHeight="20"></Text>
    <Text id="gcLog" fontSize="13" color="#FFFFFF" alignment="UpperLeft"></Text>
    <Button id="gcl_menu" onClick="gcClick" color="#444444" textColor="#FFFFFF" fontSize="14" preferredHeight="26">Back to lobby (host)</Button>
  </VerticalLayout>
</Panel>]]
end

local function riderXml(color)
  local h = hex(color)
  local function b(action, label, bg, fg)
    return button("gcb_" .. color .. "_" .. action, label, bg, fg)
  end
  local ability = abilityOf(color)
  local shifts = b("shiftdown", "Shift down", "#2A1B5C") .. b("shifthold", "Hold", "#2A1B5C")
    .. b("shiftup", "Shift up", "#2A1B5C")
  if ability == "echo" then
    shifts = b("shiftdown2", "Down 2", "#2A1B5C") .. shifts .. b("shiftup2", "Up 2", "#2A1B5C")
  end
  local extra, height = "", 372
  if ability then
    local armButton = ""
    if ability == "vixen" then
      armButton = b("boost", "Arm Volt (next curve can't fail)", "#2A1B5C")
    elseif ability == "overclock" then
      armButton = b("overclock", "Arm Overclock (2 moves at G1)", "#2A1B5C")
    end
    extra = string.format('\n    <Text id="gcAbility_%s" fontSize="12" color="%s" alignment="MiddleCenter" preferredHeight="34"></Text>',
      color, h)
    height = height + 38
    if armButton ~= "" then
      extra = extra .. '\n    <HorizontalLayout spacing="8" preferredHeight="30">' .. armButton .. "</HorizontalLayout>"
      height = height + 34
    end
  end
  return string.format([[
<Panel id="gcPanel_%s" active="false" visibility="%s" width="520" height="%d" rectAlignment="LowerCenter"
       offsetXY="0 20" color="#0A0618E6" padding="10 10 10 10">
  <VerticalLayout spacing="5">
    <Text id="gcGear_%s" fontSize="22" color="%s" alignment="MiddleCenter" fontStyle="Bold" preferredHeight="30"></Text>
    <Text id="gcOdds_%s" fontSize="14" color="#D9C8FF" alignment="MiddleCenter" preferredHeight="22"></Text>%s
    <Text fontSize="12" color="#9A8FC0" alignment="MiddleCenter" preferredHeight="16">YOUR TEMPLATES LEFT (shape: soft / hard curves)</Text>
    <Text id="gcSupply_%s" fontSize="13" color="#FFFFFF" alignment="MiddleCenter" preferredHeight="88"></Text>
    <Text id="gcWarn_%s" fontSize="12" color="#FFB000" alignment="MiddleCenter" preferredHeight="34"></Text>
    <Text fontSize="12" color="#9A8FC0" alignment="MiddleCenter" preferredHeight="16">1. choose a shift (optional)</Text>
    <HorizontalLayout spacing="8" preferredHeight="34">%s</HorizontalLayout>
    <Text fontSize="12" color="#9A8FC0" alignment="MiddleCenter" preferredHeight="16">2. commit your move (no take-backs)</Text>
    <HorizontalLayout spacing="6" preferredHeight="38">%s%s%s%s%s</HorizontalLayout>
  </VerticalLayout>
</Panel>]], color, color, height, color, h, color, extra, color, color, shifts,
    b("hardleft", "Hard L", h, "#000000"), b("softleft", "Soft L", h, "#000000"), b("straight", "Straight", h, "#000000"),
    b("softright", "Soft R", h, "#000000"), b("hardright", "Hard R", h, "#000000"))
end

-- Shown (to that rider and the host) after a crash: pick the gear to respawn in. Also
-- used at the start of a blind-start game to pick a starting gear in secret.
local function pickXml(color)
  local h = hex(color)
  local buttons = {}
  for g = Config.gears.min, Config.gears.max do
    buttons[#buttons + 1] = button("gcb_" .. color .. "_gear" .. g, "G" .. g, h, "#000000", ' fontSize="22"')
  end
  return string.format([[
<Panel id="gcPick_%s" active="false" visibility="%s|Host" width="460" height="130" rectAlignment="MiddleCenter"
       offsetXY="0 60" color="#0A0618F2" padding="12 12 12 12">
  <VerticalLayout spacing="8">
    <Text id="gcPickTitle_%s" fontSize="20" color="%s" alignment="MiddleCenter" fontStyle="Bold" preferredHeight="34">%s crashed! Choose your respawn gear</Text>
    <HorizontalLayout spacing="8" preferredHeight="48">%s</HorizontalLayout>
  </VerticalLayout>
</Panel>]], color, color, color, h, color, table.concat(buttons))
end

-- Whole-UI XML. colors = riders in the current game (empty in the lobby).
function UI_.buildXml(colors)
  local parts = { lobbyXml(), statusXml() }
  for _, c in ipairs(colors or {}) do
    parts[#parts + 1] = riderXml(c)
    parts[#parts + 1] = pickXml(c)
  end
  return table.concat(parts, "\n")
end

-- Replace the on-table UI, then refresh once TTS has built it.
function UI_.rebuild(colors)
  UI.setXml(UI_.buildXml(colors))
  -- UI changes land a little after setXml; refresh twice in case the first is early
  Wait.time(function() UI_.refresh() end, 0.4)
  Wait.time(function() UI_.refresh() end, 1.5)
end

---------------------------------------------------------------- state -> UI

local function setActive(id, on)
  UI.setAttribute(id, "active", on and "true" or "false")
end

local function bar(gear)
  local s = {}
  for g = Config.gears.min, Config.gears.max do s[#s + 1] = (g <= gear) and "#" or "." end
  return table.concat(s)
end

function UI_.log(msg)
  logLines[#logLines + 1] = msg
  while #logLines > LOG_LINES do table.remove(logLines, 1) end
  if State ~= nil then UI.setValue("gcLog", table.concat(logLines, "\n")) end
end

function UI_.clearLog()
  logLines = {}
end

-- Warn the rider if a move at `gear` would not get the exact piece asked for.
function UI_.substitutionNote(state, color, gear)
  local rider = state.riders[color]
  local notes = {}
  for _, req in ipairs({ { "straight", "straight", "Straight" }, { "curve", "soft", "Soft curve" },
                         { "curve", "hard", "Hard curve" } }) do
    local pg, ps, removed = Rules.planPiece(rider, req[1], req[2], gear)
    if pg == nil then
      notes[#notes + 1] = req[3] .. ": no tile available"
    elseif removed > 0 then
      notes[#notes + 1] = req[3] .. ": none left, your " .. removed .. " oldest tile(s) would come off"
    elseif pg ~= gear or (req[1] == "curve" and ps ~= req[2]) then
      notes[#notes + 1] = req[3] .. ": would use a G" .. pg .. " " .. ps
    end
  end
  return table.concat(notes, "\n")
end

function UI_.refresh()
  local s = Events.settings
  UI.setValue("gcl_players_val", tostring(s.maxPlayers))
  UI.setValue("gcl_prizms_val", tostring(s.prizmsToWin))
  UI.setValue("gcl_abilities", s.abilities and "ON" or "OFF")
  UI.setValue("gcl_blindstart", s.blindStart and "Blind pick" or "All G1")
  UI.setValue("gcl_mode", s.mode == "hand" and "Hand" or "Commit")
  UI.setValue("gcl_seats", "Sit in " .. table.concat(Config.seatOrder, ", ")
    .. ", then press start. First " .. s.maxPlayers .. " seated colours race.")

  local inGame = State ~= nil
  setActive("gcLobby", not inGame)
  setActive("gcStatusPanel", inGame)
  if not inGame then return end

  local cur = Rules.currentColor(State)
  local hand = Config.placementMode == "hand"
  if State.winner then
    UI.setValue("gcStatus", State.winner .. " WINS!")
  elseif State.pickingStart then
    UI.setValue("gcStatus", "Choosing starting gears (secret)")
  elseif State.pendingGear then
    UI.setValue("gcStatus", State.pendingGear .. " is choosing a gear")
  else
    UI.setValue("gcStatus", cur .. "'s turn")
  end
  local parts = {}
  for _, c in ipairs(State.order) do
    parts[#parts + 1] = string.format("%s %d/%d", c, Rules.prizmCount(State, c), Config.prizmsToWin)
  end
  UI.setValue("gcScore", "Prizms: " .. table.concat(parts, "  "))
  local riders = {}
  for _, c in ipairs(State.order) do
    local id = State.riders[c].ability
    if id then riders[#riders + 1] = c .. ": " .. Riders.name(id) end
  end
  UI.setValue("gcRiders", table.concat(riders, "  "))
  UI.setValue("gcOrder", string.format("Round %d: %s", State.round, table.concat(State.roundOrder, " > ")))
  UI.setValue("gcLog", table.concat(logLines, "\n"))

  for _, c in ipairs(State.order) do
    local r = State.riders[c]
    local mine = (c == cur) and not State.winner and not State.pendingGear and not State.pickingStart
    local picking = State.pickingStart and State.startPicks[c] == nil
    setActive("gcPanel_" .. c, true)
    setActive("gcPick_" .. c, State.pendingGear == c or picking)
    UI.setValue("gcPickTitle_" .. c, State.pickingStart and (c .. ": choose your starting gear (secret)")
      or (c .. " crashed! Choose your respawn gear"))
    local shift = mine and Events.pendingShift or 0
    local overclocking = mine and (State.bonusMove == c or Events.pendingOverclock)
    local maxShift = Riders.maxShift(r)
    local g = overclocking and Config.gears.min or Rules.gearAfterShift(r.gear, shift, maxShift)
    UI.setValue("gcGear_" .. c, string.format("GEAR %d  [%s]", r.gear, bar(r.gear)))
    if State.winner then
      UI.setValue("gcOdds_" .. c, "Game over")
    elseif State.pickingStart then
      UI.setValue("gcOdds_" .. c, picking and "Choose your starting gear in secret. Matching picks stall to G1"
        or "Picked. Waiting for the others...")
    elseif State.pendingGear == c then
      UI.setValue("gcOdds_" .. c, "You crashed! Choose your respawn gear")
    elseif State.pendingGear then
      UI.setValue("gcOdds_" .. c, "Waiting for " .. State.pendingGear .. " to choose a gear...")
    elseif not mine then
      UI.setValue("gcOdds_" .. c, "Waiting for " .. cur .. "...")
    elseif hand and overclocking then
      UI.setValue("gcOdds_" .. c, (State.bonusMove == c and "Overclock second move: " or "Overclock: ")
        .. "drag a G1 tile to where your trail ends")
    elseif hand then
      UI.setValue("gcOdds_" .. c, string.format(
        "Drag a tile (G%d-G%d) from your tray to where your trail ends",
        Rules.gearAfterShift(r.gear, -maxShift, maxShift), Rules.gearAfterShift(r.gear, maxShift, maxShift)))
    else
      local ok, spin = Rules.curveOdds(g)
      local head = overclocking and ((State.bonusMove == c and "Overclock second move" or "Overclock") .. ": G1")
        or string.format("After shift: G%d (%s)", g, SHIFT_NAMES[shift])
      local txt = string.format("%s. Curve success %d%%, spin-out %d%%", head,
        math.floor(ok * 100 + 0.5), math.floor(spin * 100 + 0.5))
      UI.setValue("gcOdds_" .. c, txt)
    end
    if r.ability then
      local status = ""
      if r.ability == "vixen" then
        status = not r.charged and " (used)" or ((mine and Events.pendingBoost) and " ARMED" or " (ready)")
      elseif r.ability == "overclock" then
        status = State.bonusMove == c and " SECOND MOVE"
          or (not r.charged and " (used until you respawn)"
          or ((mine and Events.pendingOverclock) and " ARMED" or " (ready)"))
      end
      UI.setValue("gcAbility_" .. c, Riders.name(r.ability) .. status .. "\n" .. Riders.text(r.ability))
    end
    -- templates left, one line per gear; '>' marks the gear you'll be in after the shift
    local lines = {}
    for gr = Config.gears.min, Config.gears.max do
      local function cell(shape, name)
        if (Config.tileSupply[gr] or {})[shape] == nil then return name .. " -" end
        return string.format("%s %d", name, Rules.supplyLeft(State, c, gr, shape))
      end
      lines[#lines + 1] = string.format("%s G%d   %s   %s   %s", gr == g and ">" or " ", gr,
        cell("straight", "Straight"), cell("soft", "Soft"), cell("hard", "Hard"))
    end
    UI.setValue("gcSupply_" .. c, table.concat(lines, "\n"))
    UI.setValue("gcWarn_" .. c, mine and not State.winner and UI_.substitutionNote(State, c, g) or "")
    for action, v in pairs(SHIFT_ACTIONS) do
      if hasShift(c, v) then
        local id = "gcb_" .. c .. "_" .. action
        local lit = mine and not overclocking and v == Events.pendingShift
        UI.setAttribute(id, "interactable", (mine and not hand and not overclocking) and "true" or "false")
        UI.setAttribute(id, "color", lit and "#05D9E8" or "#2A1B5C")
        UI.setAttribute(id, "textColor", lit and "#000000" or "#FFFFFF")
      end
    end
    local arm = (r.ability == "vixen" and "boost") or (r.ability == "overclock" and "overclock") or nil
    if arm then
      local armed = mine and ((arm == "boost" and Events.pendingBoost) or (arm == "overclock" and Events.pendingOverclock))
      local can = mine and ((arm == "boost" and Riders.canBoost(r))
        or (arm == "overclock" and Riders.canOverclock(r) and not State.bonusMove))
      local id = "gcb_" .. c .. "_" .. arm
      UI.setAttribute(id, "interactable", can and "true" or "false")
      UI.setAttribute(id, "color", armed and "#05D9E8" or "#2A1B5C")
      UI.setAttribute(id, "textColor", armed and "#000000" or "#FFFFFF")
    end
    for action in pairs(MOVE_ACTIONS) do
      UI.setAttribute("gcb_" .. c .. "_" .. action, "interactable", (mine and not hand) and "true" or "false")
    end
  end
end

---------------------------------------------------------------- input

-- Single global click handler: (player, value, id)
function gcClick(player, value, id)
  UI_.handle(player, id)
end

function UI_.handle(player, id)
  local lobbyAction = id:match("^gcl_(.+)$")
  if lobbyAction then
    Events.lobbyClick(player, lobbyAction)
    return
  end
  local color, action = id:match("^gcb_(%a+)_(%w+)$")
  if not color then return end
  local gear = action:match("^gear(%d)$")
  if gear then
    Events.chooseGear(player, tonumber(gear), color)   -- the host may pick for an absent rider
    return
  end
  if color ~= player.color then return end   -- panel is only shown to its owner anyway
  if SHIFT_ACTIONS[action] ~= nil then
    Events.setShift(player.color, SHIFT_ACTIONS[action])
  elseif ABILITY_ACTIONS[action] then
    Events.toggleAbility(player.color, action)
  elseif MOVE_ACTIONS[action] then
    Events.commitMove(player.color, MOVE_ACTIONS[action][1], MOVE_ACTIONS[action][2])
  end
end
