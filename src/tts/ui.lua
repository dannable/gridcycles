-- tts/ui.lua
-- All on-table UI (PLAN.md M4): lobby settings, per-rider control panels, status
-- and event-log panel. The XML is generated here (UI_.buildXml) because rider
-- panels depend on who is seated; ui/Global.xml is just a boot stub.
--
-- Element ids:  gcLobby, gcl_*  lobby      gcStatusPanel, gcStatus, gcScore, gcLog
--               gcPanel_<Color>, gcGear_<Color>, gcOdds_<Color>, gcb_<Color>_<action>
-- Every button uses onClick="gcClick"; the id says what was pressed.

UI_ = {}  -- UI is a reserved TTS global; use UI_ for our helpers

local SHIFT_NAMES = { [-1] = "down", [0] = "hold", [1] = "up" }
local SHIFT_ACTIONS = { shiftdown = -1, shifthold = 0, shiftup = 1 }
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
<Panel id="gcLobby" active="true" width="440" height="360" rectAlignment="MiddleCenter"
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
<Panel id="gcStatusPanel" active="false" width="360" height="250" rectAlignment="UpperRight"
       offsetXY="-20 -70" color="#0A0618D9" padding="10 10 10 10">
  <VerticalLayout spacing="4">
    <Text id="gcStatus" fontSize="18" color="#05D9E8" alignment="MiddleCenter" preferredHeight="28">Gridcycles</Text>
    <Text id="gcScore" fontSize="14" color="#D9C8FF" alignment="MiddleCenter" preferredHeight="22"></Text>
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
  return string.format([[
<Panel id="gcPanel_%s" active="false" visibility="%s" width="520" height="372" rectAlignment="LowerCenter"
       offsetXY="0 20" color="#0A0618E6" padding="10 10 10 10">
  <VerticalLayout spacing="5">
    <Text id="gcGear_%s" fontSize="22" color="%s" alignment="MiddleCenter" fontStyle="Bold" preferredHeight="30"></Text>
    <Text id="gcOdds_%s" fontSize="14" color="#D9C8FF" alignment="MiddleCenter" preferredHeight="22"></Text>
    <Text fontSize="12" color="#9A8FC0" alignment="MiddleCenter" preferredHeight="16">YOUR TEMPLATES LEFT (shape: soft / hard curves)</Text>
    <Text id="gcSupply_%s" fontSize="13" color="#FFFFFF" alignment="MiddleCenter" preferredHeight="88"></Text>
    <Text id="gcWarn_%s" fontSize="12" color="#FFB000" alignment="MiddleCenter" preferredHeight="34"></Text>
    <Text fontSize="12" color="#9A8FC0" alignment="MiddleCenter" preferredHeight="16">1. choose a shift (optional)</Text>
    <HorizontalLayout spacing="8" preferredHeight="34">%s%s%s</HorizontalLayout>
    <Text fontSize="12" color="#9A8FC0" alignment="MiddleCenter" preferredHeight="16">2. commit your move (no take-backs)</Text>
    <HorizontalLayout spacing="6" preferredHeight="38">%s%s%s%s%s</HorizontalLayout>
  </VerticalLayout>
</Panel>]], color, color, color, h, color, color, color,
    b("shiftdown", "Shift down", "#2A1B5C"), b("shifthold", "Hold", "#2A1B5C"), b("shiftup", "Shift up", "#2A1B5C"),
    b("hardleft", "Hard L", h, "#000000"), b("softleft", "Soft L", h, "#000000"), b("straight", "Straight", h, "#000000"),
    b("softright", "Soft R", h, "#000000"), b("hardright", "Hard R", h, "#000000"))
end

-- Whole-UI XML. colors = riders in the current game (empty in the lobby).
function UI_.buildXml(colors)
  local parts = { lobbyXml(), statusXml() }
  for _, c in ipairs(colors or {}) do parts[#parts + 1] = riderXml(c) end
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
  else
    UI.setValue("gcStatus", cur .. "'s turn")
  end
  local parts = {}
  for _, c in ipairs(State.order) do
    parts[#parts + 1] = string.format("%s %d/%d", c, State.riders[c].prizms, Config.prizmsToWin)
  end
  UI.setValue("gcScore", "Prizms: " .. table.concat(parts, "  "))
  UI.setValue("gcLog", table.concat(logLines, "\n"))

  for _, c in ipairs(State.order) do
    local r = State.riders[c]
    local mine = (c == cur) and not State.winner
    setActive("gcPanel_" .. c, true)
    local shift = mine and Events.pendingShift or 0
    local g = Rules.gearAfterShift(r.gear, shift)
    UI.setValue("gcGear_" .. c, string.format("GEAR %d  [%s]", r.gear, bar(r.gear)))
    if State.winner then
      UI.setValue("gcOdds_" .. c, "Game over")
    elseif not mine then
      UI.setValue("gcOdds_" .. c, "Waiting for " .. cur .. "...")
    elseif hand then
      UI.setValue("gcOdds_" .. c, string.format(
        "Drag a tile (G%d-G%d) from your tray to where your trail ends",
        Rules.gearAfterShift(r.gear, -1), Rules.gearAfterShift(r.gear, 1)))
    else
      local ok, spin = Rules.curveOdds(g)
      local txt = string.format("After shift: G%d (%s). Curve success %d%%, spin-out %d%%", g, SHIFT_NAMES[shift],
        math.floor(ok * 100 + 0.5), math.floor(spin * 100 + 0.5))
      UI.setValue("gcOdds_" .. c, txt)
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
      local id = "gcb_" .. c .. "_" .. action
      UI.setAttribute(id, "interactable", (mine and not hand) and "true" or "false")
      UI.setAttribute(id, "color", (mine and v == Events.pendingShift) and "#05D9E8" or "#2A1B5C")
      UI.setAttribute(id, "textColor", (mine and v == Events.pendingShift) and "#000000" or "#FFFFFF")
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
  local color, action = id:match("^gcb_(%a+)_(%a+)$")
  if not color then return end
  if color ~= player.color then return end   -- panel is only shown to its owner anyway
  if SHIFT_ACTIONS[action] ~= nil then
    Events.setShift(player.color, SHIFT_ACTIONS[action])
  elseif MOVE_ACTIONS[action] then
    Events.commitMove(player.color, MOVE_ACTIONS[action][1], MOVE_ACTIONS[action][2])
  end
end
