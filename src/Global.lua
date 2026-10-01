-- Global.lua
-- TTS Global script entry point. The VS Code TTS extension inlines #include files
-- (search path: src/, see .vscode/settings.json). Load order matters.

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
  print("Gridcycles loaded")
end

function onSave()
  if State == nil then return "" end
  return JSON.encode(State)
end
