-- Removes the calibration pieces and cubes spawned by piece_test.lua:
--   python3 tools/push_tts.py --exec tools/lua/piece_test_clear.lua --logs
local n = 0
for _, o in ipairs(getObjectsWithTag("gc_piece_test")) do
  o.destruct()
  n = n + 1
end
print("removed " .. n .. " calibration objects")
