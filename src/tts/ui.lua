-- tts/ui.lua
-- Rider panel handlers (ui/Global.xml). M2: minimal commit-mode panel.
-- Full rider panels + lobby land in PLAN.md M4.

UI_ = {}  -- UI is a reserved TTS global; use UI_ for our helpers

local SHIFT_NAMES = { [-1] = "down", [0] = "hold", [1] = "up" }

function UI_.refresh()
  if State == nil then
    UI.setValue("gcStatus", "No game")
    return
  end
  local r = State.riders[Events.controlled]
  UI.setValue("gcStatus", string.format("%s   Gear %d   Prizms %d/%d   Next shift: %s",
    Events.controlled, r.gear, r.prizms, Config.prizmsToWin,
    SHIFT_NAMES[Events.pendingShift]))
end

-- XML onClick handlers must be globals: signature (player, value, id).
function gcShiftDown(player) Events.setShift(-1) end
function gcShiftHold(player) Events.setShift(0) end
function gcShiftUp(player) Events.setShift(1) end
function gcStraight(player) Events.commitMove("straight") end
function gcLeft(player) Events.commitMove("left") end
function gcRight(player) Events.commitMove("right") end
function gcNewGame(player) Events.newGame() end
