# The Spire

A third-person action RPG for Roblox, set inside an endless tower above a drowned world.

The game lives in two halves:

- **The place file** (`SPIRE_NEW.rbxl`) holds the world: Floor 1 *Lowharbor*, the SpireKit meshes,
  terrain, lighting, dungeons and animation rigs. It is too large and too binary for git, so it is
  shared directly.
- **This repository** holds every script in that place, as a [Rojo](https://rojo.space) project
  (Rojo 7.6+, see `rokit.toml`). The repo is the source of truth for code. The world is built inside
  the place by the edit-time tools in `ServerStorage/Tools`.

## Layout

```
default.project.json   Rojo project: maps only the script containers, and ignores every other
                       instance, so a sync never touches the world
src/
  ReplicatedStorage/Shared/        Config, Data, Net (+Definitions, RateLimiter), Strings, Types,
                                   Enums, Attributes, Util
  ServerScriptService/
    Server.server.lua              server bootstrap
    Systems/                       one ModuleScript per service (Combat, Mob, Spell, Data, ...)
    Packages/ProfileStore.lua      vendored third-party package (not strict-typed)
  ServerStorage/
    Tools/                         edit-time world tools; never run during play
                                   (FloorBuilder, DistrictGenerator, BuildingGenerator,
                                   LandmarkBuilder, WildBuilder, DungeonBuilder, KitLibrary,
                                   KitManifest, Layouts/Floor1, Floor1Polish, Floor1Courtyards)
    DESIGN_DECISIONS.md.lua        the design log (a ModuleScript named DESIGN_DECISIONS.md)
  StarterPlayer/StarterPlayerScripts/
    Client.client.lua              client bootstrap (fixed controller ORDER)
    Controllers/                   one ModuleScript per controller
    UI/                            UI theme, components and helpers
tools/place/                       Lune scripts that work on the place file offline
```

`ServerStorage.ToolsRun` in the place is an older copy of `Tools` and is not tracked here.

## Working in Studio

Open the place, `rojo serve`, and connect the Studio plugin. Rojo only owns the script containers
listed in `default.project.json`; the world, the kit and the terrain are never touched.

Edit-time tools run from the command bar in Edit mode, for example:

```lua
local C = require(game.ServerStorage.Tools.Floor1Courtyards)
C.Apply()   -- courtyard scenes in the block interiors
C.Resnap()  -- re-seat them on the voxel surface after a terrain edit
C.Undo()    -- remove them (only Workspace.Floor1.Courtyards is touched)
```

## Working without Studio

[Lune](https://lune-org.github.io/docs) **0.10.5 or newer** reads the place. Older versions fail on its
Animation tags.

```bash
# Write every script in src/ into a copy of the place (all else is kept), and optionally
# rebuild the courtyards there with the same tool Studio runs
lune run tools/place/sync_scripts.luau SPIRE_NEW.rbxl build/SPIRE_NEW_updated.rbxl --courtyards

# Export a place's scripts back into src/ (after editing scripts in Studio without Rojo)
lune run tools/place/export_scripts.luau SPIRE_NEW.rbxl src

# Top-down footprint plot of the town (buildings, polish, courtyards)
lune run tools/place/footprints.luau build/SPIRE_NEW_updated.rbxl build/foot.json
python3 tools/place/plot_footprints.py build/foot.json build/town.png -900 -720 120 780 1400

# Strict type-check
rojo sourcemap default.project.json -o sourcemap.json
luau-lsp analyze --platform roblox --sourcemap sourcemap.json \
    --definitions @roblox=globalTypes.d.luau $(find src -name "*.lua")
```

The type check reports nothing except the vendored `Packages/ProfileStore.lua`.
