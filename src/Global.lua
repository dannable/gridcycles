-- Global.lua
-- TTS Global script entry point. tools/build.lua flattens the #include lines below
-- into one file for TTS (search path: src/). Load order matters.

#include config
#include geom
#include rules
#include riders/riders
#include tts/spawn
#include tts/ui
#include tts/events

State = nil

function onLoad(saved)
  if saved and saved ~= "" then
    State = JSON.decode(saved)
  end
  if Rules.isValidState(State) then
    Events.restore()
  else
    Events.toLobby()   -- fresh table or stale save: show the lobby
  end
  Wait.time(function() Events.enforceSeats() end, 1)
  print("Gridcycles loaded")
end

-- Only the four playable colours may be seated.
function onPlayerConnect(player)
  Wait.time(function() Events.enforceSeats() end, 1)
end

function onPlayerChangeColor(color)
  Wait.time(function() Events.enforceSeats() end, 0.3)
end

function onSave()
  if State == nil then return "" end
  return JSON.encode(State)
end

-- Hand mode: a draggable tile was released.
function onObjectDrop(playerColor, obj)
  Events.handleDrop(playerColor, obj)
end
