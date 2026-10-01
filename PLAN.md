# Gridcycles: Tabletop Simulator Build Plan

Name: **Gridcycles**. It's an original reskin inspired by *Lazer Ryderz* (Greater Than Games, 2017). The mechanics are reimplemented in our own words, and all art, names, riders and text are new, so we can publish it on the Steam Workshop.

## 1. Goals

- Light-cycle racing on an open table for 2–4 players (stretch goal: 6).
- **Scripted assist:** players still decide and place their own moves. Lua handles the bookkeeping: speed, turn rolls, snapping tiles to the trail end, collisions, Prizm captures, respawns and the win check.
- Keep the original's core skill: **committing to a move without measuring it**.
- Publish publicly. That means no original assets, logos, rider names or rules text.

### Non-goals (v1)

- Full auto-play or AI opponents.
- Hotseat-only rules variants. Remixes come later, behind setting toggles.

## 2. Rules we're implementing (our version)

| Element | v1 rule |
|---|---|
| Win | First to **3 Prizms** wins. |
| Setup | Prizms are scattered at random across the play mat. Each rider gets a random launch point and heading on the mat edge (this replaces the original's "eyes-closed edge placement"). |
| Speed | 5 gears. At the start of your turn, shift up 1, down 1 or hold. Each gear has its own tile length (G1 shortest, G5 longest). |
| Move | Choose **Straight**, **Curve L** or **Curve R** at your current gear. The tile attaches to your trail end. |
| Turn check | A curve needs **d6 ≥ gear**. If you fail, you go straight instead. **Spin-out** (natural 1 at G4+, configurable): the curve happens, but your gear drops to G1. |
| Crash | If your new tile crosses any trail, or leaves the mat, you crash. Your trail is removed, you respawn at a new random edge point at G1, and you keep your captured Prizms. |
| Capture | If your tile fully crosses a Prizm's long axis, you capture it. Your colour marker takes its place, which blocks it like a trail. A new Prizm then spawns at a random free spot. |
| Riders | 4 original riders, each with one ability (see §6). |

Every number lives in a single `config.lua` (tile lengths, spin-out threshold, Prizms needed, mat size), so balancing never touches the logic code.

## 3. The core design problem: "no measuring" in TTS

In a digital version, a player could hover a tile over the table to preview where it lands. Two placement modes cover this, selectable in the lobby:

1. **Commit mode (default):** your rider panel has buttons such as `[G3] Straight / Left / Right`. You click, the script rolls if needed and spawns the tile already locked at your trail end. There's no preview, so you can't measure.
2. **Hand mode:** you drag a tile from your rider tray and drop it near your trail end. Within the snap radius, `onObjectDrop` snaps and locks it. Wrong-gear tiles are rejected and returned. This is more tactile and lets people measure, which is fine for casual tables.

Both modes feed the same resolution pipeline (§4.3).

## 4. Technical architecture

### 4.1 Platform facts

- TTS scripting is **Lua 5.2 (MoonSharp)**, with a Global script plus per-object scripts.
- Hooks we use: `onLoad`, `onObjectDrop`, `onPlayerTurn`, `Turns` API, `Player` colours, `spawnObject` / `spawnObjectJSON`, `UI` (XML) for panels, `setLock`, `Wait.time` for animations.
- Assets are either **Custom Model** (OBJ + diffuse/emissive PNG) or **Custom Tile** objects, hosted on Steam Cloud when published.

### 4.2 Geometry model (the heart of it)

Physics is never used for collisions; TTS colliders are too unreliable for this. Instead, every trail tile carries an exact **2D path in table space (x, z)**:

- Straight → one line segment.
- Curve → an arc, approximated as N segments (N=8). Each curve has a fixed radius and sweep (e.g. 45°) per gear.
- Each tile defines an **entry pose** (point + heading) and an **exit pose**. The next tile's entry is the previous tile's exit.

The `geom.lua` module (pure Lua, with no TTS calls) provides:

- `tilePath(kind, gear, entryPose) -> segments, exitPose`
- `segmentsIntersect(a, b)` (standard orientation test, with an epsilon)
- `pathHitsTrails(newSegs, allTrails, ownTailIgnore)`. This ignores the shared joint with your own previous tile.
- `pathCrossesPrizm(newSegs, prizmSeg)` for the full-cross capture test
- `inBounds(segs, mat)`

The logic is pure, so it can be **unit tested outside TTS** with the zero-dependency runner (`lua tests/run.lua`).

### 4.3 Turn resolution pipeline

```
choose gear → choose move → (curve? roll d6) → compute path
  → out of bounds? → CRASH
  → hits trail/marker? → CRASH
  → place tile (lock) → crosses Prizm? → CAPTURE (+respawn Prizm)
  → captures == 3? → WIN
  → ability hooks → end turn
```

The dice roll is a scripted d6 that shows the result on a big physical die object, so everyone sees it, plus a log line in chat.

### 4.4 State

- `state = { riders[color] = { gear, pose, trail = {tileGUIDs, segs}, prizms, ability, launch }, prizms = {...}, turn }`
- Persisted through `onSave` → JSON, so a saved game resumes correctly.
- Path segments are recomputed from the stored poses on load. Nothing depends on object positions drifting.

### 4.5 Repo layout

```
gridcycles/
  PLAN.md
  src/
    Global.lua          -- entry, #include the rest
    config.lua
    geom.lua            -- pure geometry (tested)
    rules.lua           -- pure turn resolution (tested)
    tts/
      spawn.lua         -- tiles, prizms, markers
      ui.lua            -- rider panels, lobby
      events.lua        -- onObjectDrop, turns, save/load
    riders/*.lua        -- ability hooks
  ui/Global.xml
  assets/
    models/*.obj
    textures/*.png
    blender/*.blend
  tests/                -- run.lua + test_*.lua
  save/Gridcycles.json   -- the TTS save we iterate on
```

### 4.6 Tooling

- **VS Code + "Tabletop Simulator Lua" extension** (rolandostar). It pushes and pulls scripts to a running TTS through the External Editor API and resolves `#include`.
- `lua tests/run.lua` (no dependencies) runs the geometry and rules tests. See docs/SETUP.md.
- Blender for the tile and Prizm models. Keep them low-poly. TTS has no bloom, so the neon look comes from a dark mat plus bright, flat emissive-style textures.
- Git, with the `.json` save committed so table layout changes can be diffed.

## 5. Components to build

| Component | Count | Notes |
|---|---|---|
| Play mat | 1 | Dark synthwave grid, bounds drawn on it, roughly 36"×36" equivalent |
| Trail tiles | 5 gears × {straight, curve} × 4 colours | Spawned from templates, not pre-placed |
| Rider minis | 4 | Simple bikes with a colour tint. The mini sits at the trail end. |
| Prizms | 5 on the table, plus spares | Translucent crystal bar |
| Capture markers | 3 × 4 colours | |
| Gear dial | 4 | Shows the current gear, script-controlled |
| d6 | 1 shared | Scripted roll |
| Rider cards | 4 | Ability text |
| Rules notebook | 1 | TTS Notebook tab plus a PDF |

## 6. Original riders (draft)

- **Volt Vixen:** once per game, ignore a failed turn check.
- **Gridlock:** when you capture, you may delete one opponent tile that's adjacent to the Prizm.
- **Echo:** may shift 2 gears instead of 1.
- **Overclock:** once per respawn, take two moves in a row at G1.

These are balanced in playtesting and can be toggled off for a pure game.

## 7. Milestones

| # | Milestone | Done when |
|---|---|---|
| M0 | Skeleton (git done; TTS push/pull = David) | Repo, VS Code push/pull working, empty mat loads |
| M1 ✅ | Geometry core | `geom.lua` + `rules.lua` with green tests (intersections, arcs, captures, bounds) |
| M2 ✅ | Single rider loop | One colour can shift gear, commit moves, roll curves and see tiles spawn and snap. Uses grey-box tiles. |
| M3 ✅ | Multiplayer rules | Turn order, crashes and respawn, Prizm capture/respawn, win screen, save/load |
| M4 ✅ | UI pass | Rider panels, lobby settings (mode, player count, abilities on/off, Prizm target), chat log |
| M5 (code done, needs TTS playtest) | Hand mode | Drag-and-drop snapping and rejection |
| M6 | Art | Final models and textures, mat, rider minis, rider cards, rules PDF |
| M7 | Abilities | 4 riders, toggleable |
| M8 | Playtest & balance | 3+ sessions, tuning in `config.lua` |
| M9 | Publish | Steam Cloud assets, Workshop page, thumbnail, description |

M1 is the risk spike, so do it first. If arc collisions are solid, everything else is plumbing.

## 8. Risks & open questions

- **Tile lengths and curve angles:** the original's exact dimensions aren't public in usable form. We'll tune our own in M8, which suits the reskin anyway.
- **Rubber-banding:** respawning without losing Prizms could make games drag. Option: a crash drops one Prizm back onto the table.
- **Trail clutter:** late game may be gridlocked. Option: trails older than N turns fade out (an optional "decay" rule).
- **Hand mode griefing:** players nudging locked tiles. Mitigation: everything placed is locked, and only the script can unlock.
- **Name check:** search the Steam Workshop and BoardGameGeek for the final name before publishing.

## 9. Possible remix modes (post-v1)

Team mode (2v2, allies can cross each other's trails), Prizm relay (carry a Prizm to your base), timed-turn blitz, 6-player large mat.
