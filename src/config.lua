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

  -- TTS presentation (grey-box M2). Sizes are in TTS units; BlockSquare is
  -- assumed to be 1x1x1 at scale 1. Verify in game and adjust.
  tts = {
    tableY = 1.0,           -- table surface height
    trailWidth = 0.35,
    trailHeight = 0.12,
    prizmWidth = 0.3,
    prizmHeight = 0.6,
    markerSize = 0.8,
    riderSize = 0.9,
    matThickness = 0.1,
    matColor = { 0.03, 0.02, 0.08 },
    blockType = "BlockSquare",
    riderType = "BlockTriangle",
  },

  -- Neon palette per rider colour (r, g, b in 0..1)
  palette = {
    Red    = { 1.00, 0.16, 0.43 },   -- hot magenta
    Blue   = { 0.02, 0.85, 0.91 },   -- electric cyan
    Green  = { 0.22, 1.00, 0.08 },   -- acid green
    Yellow = { 1.00, 0.90, 0.00 },   -- laser yellow
  },
  prizmColor = { 0.85, 0.75, 1.00 },

  placementMode = "commit", -- "commit" | "hand"
  snapRadius = 1.0,         -- hand mode only
  abilitiesEnabled = true,
}
