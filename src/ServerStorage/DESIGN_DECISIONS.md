# The Spire — Design Decisions

Choices made where the build prompt left room for interpretation, with the
reason for each (fun, readability, performance on a mid-range phone). The
synced copy lives in `ServerStorage/DESIGN_DECISIONS` (StringValue) and is
for reference only; nothing reads it at runtime.

## Phase 9 — World

1. **The planners are pure data; instantiation is a separate step.** Every
   generator (`ServerStorage/WorldBuilder/Plan/*`) outputs a plain-table
   `PlanNode` tree with no Roblox types, which `PlanApplier` turns into
   Instances. The same code runs in Studio and in the offline Luau harness
   (`tools/harness`), so layouts can be checked, budgeted and rendered in
   Blender (`tools/blender/preview_plan.py`) without opening Studio.
2. **Deterministic RNG and noise.** Planners use `Util/Rng` (Park–Miller) and
   `Util/Geom` lattice noise instead of `Random`/`math.noise`, so a floor
   rebuilds the same way on every machine. The noise hash keeps every product
   below 2^53 because larger multipliers lose bits in doubles and show up as
   banding in terrain.
3. **One Roblox material per kit piece.** A MeshPart has a single material, so
   composite props are assemblies of single-material pieces (lantern = iron
   cage + glowing glass) defined once in `Data/KitAssemblies`. Wall geometry
   is shared across materials: stone, plaster and plank walls are the same
   mesh with a different `Material`.
4. **Constant texel density through world-scale UVs.** The Blender kit
   box-projects UVs at 1 UV unit = 8 studs on every piece. Roblox materials
   therefore tile at the same scale everywhere, and MaterialVariants or
   SurfaceAppearance can be added later without re-UVing.
5. **Large flat surfaces are Parts.** Floor slabs, foundation fills, dungeon
   ceilings, water sheets and the far-below sea are anchored Parts with
   Roblox materials. They tile in world space at a constant texel density,
   which stretched meshes can't do.
6. **Collision.** Solid wall panels collide as their own box. Door, archdoor
   and broken panels carry explicit collider boxes from the manifest, so
   doorways stay open. Windows are solid (they hold glass). Stairs use
   invisible wedge ramps for smooth walking. This replaced a merged facade
   collider pass and saved about 2,000 instances per floor.
7. **Instance budget (~40,000 per floor).** Measured by the harness before
   anything is built. To fit: full-height corner pieces, roof slopes and
   ridges stretched along the ridge (shingle courses run along X), one
   stretched plinth per wall side, beams every 12 studs, lights parented
   straight to their lantern glass (no extra attachment), furnished ground
   floors everywhere but upper floors only 40% of the time, and tree counts
   split across wild zones by area and biome. Lowharbor plans at about 40.7k
   (within the "roughly 40,000" target).
8. **Every building is enterable.** Doors are modelled open. Every ground
   floor is furnished by building type (house, shop, tavern, smithy, library,
   barracks, warehouse, hall). The furnisher keeps the door corridor and stair
   entrance clear, so interiors can always be walked through.
9. **Stairs always connect storeys.** Each storey but the top gets a
   switchback stair (spiral in shallow buildings) in a reserved back-left
   cell. The slab above leaves a hole over it, with a balustrade on its open
   side.
10. **Streets are terrain.** Street, plaza and path surfaces are painted into
    terrain materials and their heights cut as corridors (stairs, ramps and the
    lighthouse causeway included). Terrain handles slopes and collision for
    free, and street Parts would have cost thousands of instances.
11. **Organic districts.** Districts lay curved lanes, warped by sine and
    noise, along the district's long axis, plus leaning cross lanes. Lots are
    placed by walking each street frontage, so buildings follow curves
    naturally. Lanes that run into a terrace drop end at an overlook
    balustrade.
12. **Terraces.** Lowharbor's districts are flat terrace pads (6 / 22 / 38 /
    54 / 72). Steep drops get retaining walls with a cornice and balustrade.
    Grand stairs and ramp roads cross the drops. Canals fall between terraces
    as glowing Current waterfalls.
13. **Current water is custom.** Canal and pool water are translucent teal
    Glass sheets with rising motes, teal lights and an optional scrolling flow
    texture, as the style guide asks. Terrain water is used only for the sea
    and the marsh tidepools.
14. **Landmarks reuse the kit at 1.5x–5x scale.** The Climbers' Guild (2x, with
    a 7-ring beacon tower), Tidewatch Cathedral (2x nave, bell tower, rose
    window), the lighthouse (1.25x rings with spiral stairs), and the Guardian
    Gate (5x pylons, 3x arch, 3.2x statues). This keeps architecture
    consistent and needs no one-off meshes.
15. **Streaming.** `StreamingEnabled`, target radius 512, minimum 160.
    Buildings and landmarks are `Atomic`. Waystones, gameplay markers, the
    Guardian Gate, the pumphouse and the skybox are `Persistent`. Landmarks use
    `LevelOfDetail = StreamingMesh`, so their silhouettes stay visible beyond
    the streaming radius.
16. **Skybox ring.** 72 colossal arcade wall segments at a radius of 2,300
    studs, Current falls pouring down them, the underside of Floor 2 hanging
    1,650 studs overhead, and a drowned sea far below with sunken towers. None
    of it casts shadows or collides.
17. **Townsfolk, gulls and fish are client-side.** They're cosmetic, so each
    client animates its own (no replication cost), culls them by distance and
    scales their counts by EffectsQuality. Quest-giver NPCs are separate
    server rigs (Phase 11).
18. **Dungeon instancing in place.** Until reserved-server routing exists, each
    party gets its own clone of the dungeon template in a far-away slot of the
    same server (up to 12). `DungeonService.SetPartyResolver` and
    `ReportBossDefeated` are the integration points for the party and boss
    systems.
19. **Session locking without the ProfileStore package.** ProfileStore's
    source couldn't be fetched from this build environment, so `DataService`
    implements the same pattern on `UpdateAsync`: lock with job id and
    timestamp, steal stale locks, never overwrite another server's session,
    and release on leave and shutdown. It also has versioned migrations and
    falls back to session-only profiles in Studio without API access.
20. **Asset ids that aren't uploaded yet.** Textures and ambience loops are
    referenced through `Data/AssetManifest`. An empty id means "not uploaded":
    systems fall back to plain glowing water or silence instead of erroring.
    Particles use built-in `rbxasset://` textures.
21. **Pressure per zone.** Each zone carries its Current Pressure (Town 3–4,
    Marsh 4, Forest 2, Gatewatch Crags 1 as the dry "dead zone", First Gate 5).
    `WorldService.GetPressure(position)` is what the Current system reads.
22. **The day starts at 20:30.** The tutorial happens on the docks at night,
    so a fresh server's clock starts at dusk. A full cycle takes 24 real
    minutes.
