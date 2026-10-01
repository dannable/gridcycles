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
