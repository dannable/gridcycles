-- tts/ui.lua
-- Rider panel handlers (ui/Global.xml). M2/M3: shared commit-mode panel.
-- Full per-rider panels + lobby land in PLAN.md M4.

UI_ = {}  -- UI is a reserved TTS global; use UI_ for our helpers

local SHIFT_NAMES = { [-1] = "down", [0] = "hold", [1] = "up" }

function UI_.refresh()
  if State == nil then
    UI.setValue("gcStatus", "No game")
    UI.setValue("gcScore", "")
    return
  end
  local cur = Rules.currentColor(State)
  local r = State.riders[cur]
  if State.winner then
    UI.setValue("gcStatus", State.winner .. " WINS!")
  else
    UI.setValue("gcStatus", string.format("%s's turn   Gear %d   Next shift: %s",
      cur, r.gear, SHIFT_NAMES[Events.pendingShift]))
  end
  local parts = {}
  for _, c in ipairs(State.order) do
    parts[#parts + 1] = string.format("%s %d/%d", c, State.riders[c].prizms, Config.prizmsToWin)
  end
  UI.setValue("gcScore", "Prizms: " .. table.concat(parts, "   "))
end

-- XML onClick handlers must be globals: signature (player, value, id).
-- player.color is the TTS seat colour of whoever clicked.
function gcShiftDown(player) Events.setShift(player.color, -1) end
function gcShiftHold(player) Events.setShift(player.color, 0) end
function gcShiftUp(player) Events.setShift(player.color, 1) end
function gcStraight(player) Events.commitMove(player.color, "straight") end
function gcLeft(player) Events.commitMove(player.color, "left") end
function gcRight(player) Events.commitMove(player.color, "right") end
function gcNewGame(player) Events.newGame() end
