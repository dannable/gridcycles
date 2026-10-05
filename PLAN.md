# Gridcycles: Tabletop Simulator Build Plan

Name: **Gridcycles**. It's an original reskin inspired by *Lazer Ryderz* (Greater Than Games, 2017). The mechanics are reimplemented in our own words, and all art, names, riders and text are new, so we can publish it on the Steam Workshop.

## 1. Goals

- Light-cycle racing on an open table for 2–4 players (stretch goal: 6). Four playable seats: Red, Blue, Green, Yellow.
- **Scripted assist:** players still decide and place their own moves. Lua handles the bookkeeping: speed, turn rolls, snapping tiles to the trail end, collisions, Prizm captures, respawns and the win check.
- Keep the original's core skill: **committing to a move without measuring it**.
- Publish publicly. That means no original assets, logos, rider names or rules text.

### Non-goals (v1)

- Full auto-play or AI opponents.
- Hotseat-only rules variants. Remixes come later, behind setting toggles.

## 2. Rules we're implementing (our version)

| Element | v1 rule |
|---|---|
| Win | First to hold **3 Prizms of their colour on the table at once** wins. |
| Setup | One unscored Prizm per rider, evenly spaced on a ring round the centre. Each rider gets a random launch point and heading on the mat edge; the first tile starts against the edge, with the bike standing just ahead of it (this replaces the original's "eyes-closed edge placement"). |
| Speed | 5 gears. At the start of your turn, shift up 1, down 1 or hold. Each gear has its own tile length (G1 shortest, G5 longest). |
| Tiles | Each rider owns a limited set of pieces: per gear, 2 straights, 2 soft curves and 2 hard curves, except gear 4 (no hard curves) and gear 5 (straights only). See `Config.tileSupply`. Laid tiles stay out until the rider crashes, which returns everything. |
| Out of pieces | If the exact piece is gone, use the same kind from the next gear down (a curve tries the other curve shape in the same gear first). If nothing at your gear or below is left, your **oldest tiles come off the line one at a time** until a piece fits. Your gear is unchanged. |
| Move | Choose **Straight**, or a **soft** or **hard** curve to the left or right, at your current gear. The tile attaches to your trail end. |
| Turn check | The curve die has faces 1, 2, 3, 4, 5 and a spin-out face. A numbered face **≥ your gear** succeeds (place the curve); a lower one fails (place a straight instead). The **spin-out** face (1 in 6, any gear) places the curve, then drops you to G1. |
| Respawn | After a crash you respawn at a random edge point and **choose any gear** (the host can pick for you). Your turn ends once you have. |
| Crash | If your new tile crosses any trail, **any rider's bike**, or leaves the mat, you crash. A bike is part of its owner's trail: it rides on the end of their last tile (nose on the trail end), or stands just ahead of the launch point before any tile is laid, and never blocks its owner. Your trail is removed, you respawn at a new random edge point at G1, and you keep your captured Prizms. |
| Capture | If your tile fully crosses an unscored Prizm's long axis (within half a wall width of its ends), you **score** it: it takes your colour and stays where it is, and a new unscored Prizm is tossed onto the table. Crossing another rider's scored Prizm **steals** it (no new Prizm). Scored Prizms stay on the table when their owner crashes. |
| Pass-through | Contact right on top of a Prizm never crashes, so a Prizm is a gap in any wall. |
| Nudge | A tile that touches an unscored Prizm without scoring pushes it clear (one wall width from every wall). A Prizm is **locked** and never nudged if it sits on its owner's own line, or lines of two different colours touch it. |
| Crash victim | If you crash into another rider's tile, they lose that tile and every tile older than it (their front tile always stays); the pieces return to their supply. Hitting a bike or your own wall costs nobody else anything. |
| Turn order | Each round the fastest gear goes first. Ties go to whoever sits nearest, clockwise, to a tie-breaker marker that moves one seat on after every round. |
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

## 10. Rules backlog (from comparing with the tabletop game's published rules)

Done: choosing your gear when you respawn; typed, limited pieces; substitution and oldest-tile removal; the curve die (spin-out face); crash victims lose pieces; Prizm scoring, stealing, pass-through, nudge and locking; the three-at-once win; unscored Prizms evenly spaced on a ring, replaced when scored; turn order by gear with a rotating tie-breaker.

Not yet matching, roughly by impact on play:

1. **Starting gear.** Initial gears are chosen blind and equal picks stall to G1; we start everyone at G1. (Respawn gear is now chosen, see above.)
2. **Launch point is a wall piece**, and start positions are placed blind. Ours is a random edge point and the launch is not part of the line.
3. **Scoring across two turns.** A line that stops partway over a Prizm can finish scoring next turn; ours checks only the newly laid tile.
4. **Scored Prizm placement.** The real game slides a newly scored Prizm to the front of the scoring tile; ours stays where it was crossed.
5. **Power Prizms.** Per-rider one-shot powers, recharged when someone steals one of your Prizms (steals now exist).
6. Table-size variants (small: no gear 5 / 4-soft / 3-hard; large: bonus G5 straight at launch).
