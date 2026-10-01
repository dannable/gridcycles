-- rules.lua
-- Pure turn resolution. NO TTS API calls: takes state + inputs, returns a result.
-- Randomness is injected (rollFn) so tests are deterministic.
--
-- Rules.resolveMove(state, color, move, rollFn) -> result
--   move   = { shift = -1|0|1, kind = "straight"|"left"|"right" }
--   result = { outcome = "placed"|"crash"|"win",
--              gear, roll, spunOut, wentStraight,
--              segs, exitPose, captured = {prizmIds...} }

Rules = {}

function Rules.newState(colors)
  error("Rules.newState: not implemented (PLAN.md M1)")
end

function Rules.resolveMove(state, color, move, rollFn)
  error("Rules.resolveMove: not implemented (PLAN.md M1)")
end
