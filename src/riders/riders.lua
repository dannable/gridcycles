-- riders/riders.lua
-- The four original riders and their abilities (PLAN.md section 6, M7). Pure: no TTS
-- API calls. Rules consults these helpers; the numbers live in Config.abilities.
--
-- Each rider in state carries:
--   ability = id | nil    (nil when abilities are off for this game)
--   charged = bool        (the once-per-something ability is still available)
--
--   vixen      Volt Vixen. Once per game: arm before a curve. If the turn check fails,
--              you curve anyway. The charge is spent only if it saved you.
--   gridlock   Gridlock. Each Prizm you take (score or steal) removes the nearest
--              opponent tile within Config.abilities.gridlockReach of it. A rider's
--              front tile (their bike sits on it) is never removed.
--   echo       Echo. May shift up to Config.abilities.echoMaxShift gears.
--   overclock  Overclock. Once per respawn (the launch counts): drop straight to G1
--              and take two moves in a row, both at G1.
--
-- Power Prizms: when someone steals one of your Prizms, a spent Volt Vixen or Overclock
-- charge comes back.

Riders = {
  order = { "vixen", "gridlock", "echo", "overclock" },
  defs = {
    vixen = { name = "Volt Vixen",
      text = "Once per game: arm before a curve. If the check fails you curve anyway." },
    gridlock = { name = "Gridlock",
      text = "Each Prizm you take removes the nearest rival tile next to it (never a front tile)." },
    echo = { name = "Echo",
      text = "You may shift up to 2 gears instead of 1." },
    overclock = { name = "Overclock",
      text = "Once per respawn: drop to G1 and take two moves in a row at G1." },
  },
}

-- Give each rider a different ability, at random. Riders beyond the deck get none.
function Riders.deal(state, rollFn)
  local deck = {}
  for i, id in ipairs(Riders.order) do deck[i] = id end
  for _, color in ipairs(state.order) do
    local r = state.riders[color]
    if #deck > 0 then
      local i = math.max(1, math.min(#deck, rollFn(#deck)))
      r.ability = table.remove(deck, i)
      r.charged = true
    end
  end
end

function Riders.name(id)
  local d = Riders.defs[id]
  return d and d.name or nil
end

function Riders.text(id)
  local d = Riders.defs[id]
  return d and d.text or nil
end

-- Largest gear change this rider may make in one shift.
function Riders.maxShift(rider)
  if rider.ability == "echo" then return Config.abilities.echoMaxShift end
  return Config.gears.maxShift
end

-- Can this rider arm Volt Vixen's boost now?
function Riders.canBoost(rider)
  return rider.ability == "vixen" and rider.charged == true
end

-- Can this rider start an Overclock now?
function Riders.canOverclock(rider)
  return rider.ability == "overclock" and rider.charged == true
end

-- A crash gives a fresh respawn: Overclock recharges. (Volt Vixen is once per game.)
function Riders.onRespawn(rider)
  if rider.ability == "overclock" then rider.charged = true end
end

-- Power Prizms: having a Prizm stolen recharges a spent once-per ability (Volt Vixen,
-- Overclock). Returns true if it recharged.
function Riders.onStolenFrom(rider)
  if (rider.ability == "vixen" or rider.ability == "overclock") and not rider.charged then
    rider.charged = true
    return true
  end
  return false
end

function Riders.isValid(rider)
  if rider.ability == nil then return true end
  return Riders.defs[rider.ability] ~= nil and type(rider.charged) == "boolean"
end
