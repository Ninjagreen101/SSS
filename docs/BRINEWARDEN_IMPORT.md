# The Brinewarden's body: importing SpireKit_Guardians

The Floor 1 Guardian's body is a Blender model built from code, the same way the SpireKit was
made. Until you import it, the Warden uses its placeholder body: Roblox parts defined in
`Shared/Data/Mobs.lua`. The fight works the same with either body.

| File | What it is |
|---|---|
| `assets/guardian/SpireKit_Guardians.fbx` | 22 rigid body pieces in 108 meshes (about 30k triangles), plus 4 calibration cubes |
| `assets/guardian/SpireKit_Guardians.blend` | the same scene, for hand edits in Blender |
| `tools/blender/guardian/build_brinewarden.py` | the generator: rebuilds the FBX, the manifest and the previews |
| `src/ServerStorage/Tools/KitManifestGuardians.lua` | generated piece data, merged into `KitManifest` |
| `docs/previews/brinewarden_*.png` | review renders: turnaround, close-ups, rest pose |

## 1. Import the FBX (Studio, Edit mode)

1. Work on a copy of `SPIRE_NEW.rbxl`. Never edit the only copy.
2. Open **Home > Import 3D** and choose `assets/guardian/SpireKit_Guardians.fbx`.
3. Use the settings from the SpireKit imports (Architecture, World, Nature). These ones matter:
   - **Import Only As Model**: on.
   - **Insert Using Scene Position**: on. Pieces must keep their places relative to each other.
   - **Merge Meshes**: off. Each `<Piece>__<Channel>` mesh has to stay its own MeshPart.
   - **Anchored**: on, so the import doesn't fall while you work.
   - **Rig type**: none. These are static meshes, not an avatar.
   - **Materials and textures**: anything. KitLibrary sets each part's Roblox material and colour
     from its channel.
   - **Scale, units and axes**: anything that doesn't mirror the model. The four
     `Calib_Guardians__*` cubes measure the import, and KitLibrary corrects scale and rotation. If an
     axis is mirrored, `Prepare` reports it.
4. Leave the import where the importer puts it, in Workspace. `Prepare` moves it to
   `ServerStorage.SpireKit.Source.SpireKit_Guardians`, so the raw meshes never render in play.

## 2. Build the templates (Command Bar, Edit mode)

```lua
local Kit = require(game.ServerStorage.Tools.KitLibrary)
local result = Kit.Prepare()
print(result.built, "templates")
print(table.concat(result.problems, "\n"))
print(#Kit.Category("Guardian"), "Guardian pieces (expect 22)")
```

- `Prepare` rebuilds every kit template, so `built` is the old count plus 22.
- `problems` should not mention Guardians.
- `ServerStorage.SpireKit.Templates` now holds `Brinewarden_Head`, `Brinewarden_ShellBack`,
  `Brinewarden_Core` and the rest. Each template Model carries the attributes `Body`, `Limb`,
  `Role` and `RigScale`, which the server reads at spawn.
- Save the place.

## 3. Check it in play

Press **Play** (F5). In the **server** Command Bar, spawn a passive Warden 30 studs in front of you:

```lua
local MobService = require(game.ServerScriptService.Systems.MobService)
local root = game.Players:GetPlayers()[1].Character.HumanoidRootPart
local mob = MobService.Spawn("Brinewarden", root.Position + root.CFrame.LookVector * 30, false, nil, { Scripted = true })
local meshes = 0
for _, part in mob.Model:GetChildren() do
	if part:IsA("MeshPart") and part:GetAttribute("Piece") then
		meshes += 1
	end
end
print(meshes, "mesh parts (0 means the placeholder body was used)")
print(mob.Model:FindFirstChild("Seam"), mob.Model:FindFirstChild("Core"), mob.Model:FindFirstChild("Claw"))
-- clean up afterwards: MobService.Despawn(mob.Model, false)
```

You should see about 108 mesh parts riding the hidden R15 rig. To check the whole fight, challenge
the Warden at the First Gate:

- In phase 3, every part named `Shell` drops: back plates, chest plate and both pauldrons.
- The glowing `Core` and its chest veins appear in phase 3.
- Lock-on cycles through the head, the pincer (`Claw`), the back `Seam` and, in phase 3, the core.

## 4. If you skip the import

Nothing breaks:

- `KitLibrary.Prepare()` lists `SpireKit_Guardians not found ... (optional: ...)` among its
  problems and builds every other template as before.
- `MobService/Builder` uses the mesh body only when **every** Brinewarden piece is in
  `ServerStorage.SpireKit.Templates`. Otherwise it builds the placeholder body (`Body.Extras` in
  `Data/Mobs.lua`), which uses the same role names: `Shell`, `Core`, `Seam`, `Claw` and `Helm`.

## How the pieces fit the rig

- Every piece is rigid and rides one R15 part. The pieces are:
  - `Head`, `UpperTorso`, `LowerTorso`, and each arm and leg part;
  - `Sword`, on `RightHand`;
  - `ShellBack`, `ShellChest` and `Core` (glow), all on `UpperTorso`;
  - `Seam` (glow), also on `UpperTorso`;
  - `ShellPauldronL` and `ShellPauldronR`, on the upper arms.
- A piece's origin is the centre of its R15 part. The reference rig is Roblox's default R15 at
  `Body.Scale` 3.4, measured from `Workspace.SpireAnimationRig`. The numbers are in the docstring of
  `build_brinewarden.py`.
- The server clones each piece and scales it by `scale / RigScale`. It turns the piece 180° about Y,
  because kit pieces face +Z and R15 parts face -Z. Then it sets the piece on its limb and welds it.
  The standard R15 animations then drive the body.
- The parts are massless and never collide, query or touch. Only the big pieces cast shadows.
  Small point lights sit on the eyes, the core, the seam and the sword veins.
- The pincer is on the Warden's **left** hand (`Claw`). The coral greatsword is in its **right** hand,
  blade forward along the hand's -Z like every R15 weapon, with the edge down.

## Rebuilding the model

```bash
/tmp/claude-0/bpyenv/bin/python tools/blender/guardian/build_brinewarden.py --repo .   # about 80 s with renders
/tmp/claude-0/bpyenv/bin/python tools/blender/guardian/build_brinewarden.py --repo . --no-render
```

The generator needs the Blender 4.5 `bpy` module. It renders with Cycles on the CPU. After a
rebuild:

1. Re-import the FBX.
2. Run `Kit.Prepare()`. It replaces the old `Source` copy and the templates.
3. Sync the scripts (`KitManifestGuardians.lua` changes with the model).
