-- config.lua
-- Every tunable number lives here. Logic modules read Config, never hard-code values.
-- Units: TTS world units on the table plane (x, z). Angles in degrees.
-- NOTE: placeholder values; tune during playtesting (PLAN.md M8).

Config = {
  prizmsToWin = 3,
  prizmsOnTable = 5,
  maxPlayers = 4,

  mat = { width = 36, depth = 36 },        -- play area, centred on origin

  gears = { min = 1, max = 5, maxShift = 1 },

  -- Tile geometry per gear: straight length, curve radius, curve sweep
  tiles = {
    [1] = { straight = 2.0, radius = 2.0, sweep = 45 },
    [2] = { straight = 3.0, radius = 3.0, sweep = 45 },
    [3] = { straight = 4.0, radius = 4.0, sweep = 45 },
    [4] = { straight = 5.0, radius = 5.0, sweep = 45 },
    [5] = { straight = 6.0, radius = 6.0, sweep = 45 },
  },

  arcSegments = 8,          -- polyline resolution for curves
  epsilon = 1e-6,           -- geometry tolerance

  turnCheck = {
    die = 6,                -- curve succeeds if roll >= gear
    spinOutRoll = 1,        -- natural roll that triggers spin-out...
    spinOutMinGear = 4,     -- ...only at this gear or higher
  },

  prizm = { length = 1.5 }, -- Prizm modelled as a segment of this length

  launchMargin = 6,         -- keep launch points this far from mat corners
  prizmEdgeMargin = 3,      -- keep Prizm centres this far from the mat edge
  spawnTries = 50,          -- retries when a random spawn lands on something

  placementMode = "commit", -- "commit" | "hand"
  snapRadius = 1.0,         -- hand mode only
  abilitiesEnabled = true,
}
