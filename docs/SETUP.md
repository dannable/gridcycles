# Setup (Windows)

## 1. Lua (for tests)

Any Lua 5.2–5.4 works for running tests. Game code must still be Lua 5.2 compatible (see CLAUDE.md).

```powershell
winget install DEVCOM.Lua
```

Open a new terminal and check that `lua -v` works. (If `lua` isn't on PATH, the installer may name it `lua54`. Either alias it or call that directly.)

Then, from the repo root:

```powershell
lua tests/run.lua
```

## 2. Git

```powershell
git init
git add .
git commit -m "M0: scaffold"
```

## 3. VS Code + TTS extension

1. Install the recommended extension when VS Code prompts you (`rolandostar.tabletopsimulator-lua`).
2. `.vscode/settings.json` adds `src/` to the `#include` search path. If the extension version uses a different setting name, update it there.
3. In Tabletop Simulator, start a game. The extension uses TTS's External Editor API on localhost, so TTS has to be running.
4. Get Lua Scripts (Ctrl+Alt+L) pulls the scripts, and Save and Play (Ctrl+Alt+S) pushes them. Edit `src/Global.lua` in the repo, not the extension's temp copy.

## 4. Save file

When the table layout changes, save the game in TTS and copy the save JSON from
`Documents\My Games\Tabletop Simulator\Saves\` into `save/Gridcycles.json`, then commit it.

## 5. Blender (M6)

Model sources go in `assets/blender/`. Export OBJ to `assets/models/` and textures to `assets/textures/`.

## Pushing to TTS (what actually works)

The VS Code extension (v1.1.3) does not expand `#include`. Instead:

1. In TTS load a game, then in VS Code run **TTS Lua: Get Lua Scripts** once.
2. From the repo root: `lua tools/build.lua "C:/Users/<you>/AppData/Local/Temp/TabletopSimulator/Tabletop Simulator Lua"`
3. In VS Code run **TTS Lua: Save and Play**. Repeat steps 2-3 after each code change.

## Bike model (M6)

Raw Meshy exports live in `assets/source/` (git-ignored; the first export was 2.3M faces, so use Meshy's low-poly setting).
`py -3.13 tools/prep_bike.py [+1|-1]` reorients the OBJ (nose +z, y up, origin bottom centre, length 1.0), lifts the greyscale texture, and writes `assets/models/bike.obj|mtl|png`. Needs `pip install numpy pillow`.
TTS loads meshes by URL: upload `bike.obj` and `bike.png` somewhere public, then fill `Config.tts.riderModel.mesh` / `.diffuse`. If the bike faces backwards set `riderModel.yaw = 180`; adjust `scale` / `yOffset` to taste.

## Pushing to TTS without VS Code (Linux desktop)

Dev box (headless) and the machine running TTS can be different. On the TTS machine, with the repo cloned and Python 3 installed:

```bash
git pull && python3 tools/push_tts.py          # build + Save & Play
python3 tools/push_tts.py --logs               # same, then stream TTS chat/errors
```

It talks to TTS's External Editor API on localhost:39999 (replies on 39998), so TTS must be running with a game loaded. Linux saves live in `~/.local/share/Tabletop Simulator/Saves/`.
`prep_bike.py` on Linux: `python3 tools/prep_bike.py` (needs numpy, pillow).

## Physical tile meshes (prototype, not wired in yet)

`python3 tools/make_tiles.py` (needs `pip install pillow` and `lua`) writes one OBJ per piece type
plus a shared texture atlas to `assets/models/tiles/`. Origin = the piece's entry point, so place
with position = entry, rotationY = entry heading, scale 1. To check how TTS imports them (axis
handedness, mirrored curves), with the game running:

```bash
python3 tools/push_tts.py --exec tools/lua/piece_test.lua --logs
```

It spawns one piece of each kind next to a white cube at the exit point the rules expect.
TTS mirrors the x axis of imported OBJs, so `make_tiles.py` writes the meshes pre-flipped
(`TTS_FLIP_X`); the test confirms curves bend the right way and digits read correctly.
