-- config.lua
-- Every tunable number lives here. Logic modules read Config, never hard-code values.
-- Units: TTS world units on the table plane (x, z). Angles in degrees.
-- NOTE: placeholder values; tune during playtesting (PLAN.md M8).

Config = {
  prizmsToWin = 3,
  neutralPrizmsPerPlayer = 1,   -- unscored Prizms on the table, per rider; a scored one is replaced
  prizmRingRadius = 6,          -- the starting neutral Prizms sit evenly spaced on a ring this wide
  maxPlayers = 4,

  mat = { width = 36, depth = 36 },        -- play area, centred on origin

  gears = { min = 1, max = 5, maxShift = 1 },

  -- Tile geometry per gear: straight length, and for each curve shape its radius and
  -- sweep. "soft" is the gentle curve, "hard" the tight one. A shape missing here
  -- (and in tileSupply) doesn't exist at that gear: high gears can't turn sharply.
  tiles = {
    [1] = { straight = 2.0, soft = { radius = 2.0, sweep = 45 }, hard = { radius = 1.0, sweep = 90 } },
    [2] = { straight = 3.0, soft = { radius = 3.0, sweep = 45 }, hard = { radius = 1.5, sweep = 90 } },
    [3] = { straight = 4.0, soft = { radius = 4.0, sweep = 45 }, hard = { radius = 2.0, sweep = 90 } },
    [4] = { straight = 5.0, soft = { radius = 5.0, sweep = 45 } },
    [5] = { straight = 6.0 },
  },

  -- Pieces ("templates") each rider owns, per gear and shape. A laid tile stays on
  -- the table until its owner crashes (everything comes back) or has to give up their
  -- oldest tiles (see Rules.resolveMove). Shapes: "straight" | "soft" | "hard".
  tileSupply = {
    [1] = { straight = 2, soft = 2, hard = 2 },
    [2] = { straight = 2, soft = 2, hard = 2 },
    [3] = { straight = 2, soft = 2, hard = 2 },
    [4] = { straight = 2, soft = 2 },
    [5] = { straight = 2 },
  },

  arcSegments = 8,          -- polyline resolution for curves
  epsilon = 1e-6,           -- geometry tolerance

  -- The curve die has faces 1..die-1 plus one spin-out face (the highest, `die`).
  -- A curve succeeds on a numbered face >= your gear, fails (goes straight) on a
  -- lower one, and the spin-out face curves but drops you to gear 1, at any gear.
  turnCheck = {
    die = 6,
  },

  -- Prizm modelled as a segment of this length. A path that crosses the Prizm's
  -- long axis within endSlack of an end still captures: set to half the wall width
  -- (tts.trailWidth / 2) so a wall visibly touching the Prizm counts.
  -- Contact within passRadius of a Prizm never crashes (it is a gap in any wall). A
  -- tile that comes within touchDist of an unscored, unlocked Prizm without scoring
  -- nudges it away until it is nudgeClear from every wall.
  prizm = { length = 1.5, endSlack = 0.175, passRadius = 0.4, touchDist = 0.33, nudgeClear = 0.55 },

  -- The bike is part of its owner's trail: a segment this long ending at the trail
  -- end (nose on the exit of the last tile, tail back over it). Other riders crash
  -- into it. It is also the in-game length of the bike model. A fresh launch puts
  -- the tail on the mat edge.
  bikeLength = 1.8,

  launchMargin = 6,         -- keep launch points this far from mat corners
  prizmEdgeMargin = 3,      -- keep Prizm centres this far from the mat edge
  spawnTries = 50,          -- retries when a random spawn lands on something

  -- TTS presentation (grey-box M2). Sizes are in TTS units; BlockSquare is
  -- assumed to be 1x1x1 at scale 1. Verify in game and adjust.
  tts = {
    tableY = 1.0,           -- table surface height
    trailWidth = 0.35,
    dividerColor = { 0.95, 0.95, 1.0 },  -- bar across the wall at each tile joint
    labelPlate = 0.8,        -- gear-number plate on top of each tile (size, world units)
    labelFontSize = 400,     -- gear number text; tune in game
    labelPlateColor = { 0.02, 0.01, 0.05 },
    trailHeight = 0.36,      -- walls
    prizmWidth = 0.3,
    prizmHeight = 0.6,
    markerSize = 0.8,
    riderSize = 0.9,
    matThickness = 0.1,
    matColor = { 0.03, 0.02, 0.08 },
    tileWidth = 0.9,         -- hand-mode tray tiles
    tileHeight = 0.2,
    trayGap = 1.85,          -- spacing between tray slots (x)
    trayRowDepth = 8,        -- spacing between riders' tray rows (z)
    trayOffset = 6,          -- first tray row sits this far beyond the mat's south edge
    -- Custom rider mesh (assets/models/bike.obj + bike.png, uploaded somewhere public).
    -- Leave mesh empty to keep the grey-box triangle. The model is 1.0 long, nose +z,
    -- origin at bottom centre; in-game length is Config.bikeLength. Diffuse should be
    -- greyscale: it is multiplied by the rider's neon colour.
    riderModel = {
      mesh = "https://raw.githubusercontent.com/dannable/gridcycles/v0.2-playtest/assets/models/bike.obj",
      diffuse = "https://raw.githubusercontent.com/dannable/gridcycles/v0.2-playtest/assets/models/bike.png",
      collider = "",         -- optional; defaults to the mesh
      yaw = 180,              -- extra degrees if the bike points the wrong way (try 180)
      yOffset = 0,
    },
    blockType = "BlockSquare",
    riderType = "BlockTriangle",
  },

  -- The four playable seats, in turn order. Neon colour (r, g, b in 0..1) per seat.
  -- Anyone who sits in another colour is moved to a free seat from this list.
  seatOrder = { "Red", "Blue", "Green", "Yellow" },
  palette = {
    Red    = { 1.00, 0.16, 0.43 },   -- hot magenta-red
    Blue   = { 0.02, 0.85, 0.91 },   -- electric cyan
    Green  = { 0.22, 1.00, 0.08 },   -- acid green
    Yellow = { 1.00, 0.90, 0.00 },   -- laser yellow
  },
  prizmColor = { 0.85, 0.75, 1.00 },

  placementMode = "commit", -- "commit" | "hand"
  snapRadius = 3.0,         -- hand mode: max distance from a tile's landing spot
  abilitiesEnabled = true,

  -- Rider abilities (src/riders/riders.lua).
  abilities = {
    echoMaxShift = 2,       -- Echo may shift this many gears
    gridlockReach = 1.0,    -- Gridlock removes a rival tile this close to a Prizm it takes
  },
}
