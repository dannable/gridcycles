-- Global.lua
-- TTS Global script entry point. tools/build.lua flattens the #include lines below
-- into one file for TTS (search path: src/). Load order matters.

#include config
#include geom
#include rules
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
    State = nil
    Events.newGame()   -- M2: start a single-rider game immediately
  end
  -- the XML UI may not be ready on the first frame
  Wait.time(function() UI_.refresh() end, 0.5)
  print("Gridcycles loaded")
end

function onSave()
  if State == nil then return "" end
  return JSON.encode(State)
end
