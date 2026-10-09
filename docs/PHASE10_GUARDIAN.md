# Phase 10: The Brinewarden, Keeper of the First Gate

The Floor 1 Guardian. This document covers four things:
- the design, and the Roblox boss fights it borrows from
- the contracts every Phase 10 file codes against
- the build split between agents
- the acceptance checks

Spec sources: Section 10 "Floor Guardians", Section 12 (intro and victory cards), Section 13 (3-phase
Guardian track), Section 14 (announcements, private fights) and Section 16 item 10.

## 1. What popular Roblox RPGs do, and what we take

| Game / boss | Pattern | Taken as |
|---|---|---|
| Deepwoken, The Ferryman | Instanced boss. The wiki splits the move list by phase. Health, speed and damage all scale with party size. | Each move lists the phases it appears in. The fight is an instanced copy per party. Health scales with party size (spec formula), and so does the number of adds. Damage stays fixed, so the fight is fair to read. |
| Deepwoken, Elder Primadon | Every move carries explicit parry / block / dodge flags. A grab is used only under a condition. Two similar stomps differ by sound pitch. | Every move has explicit `Parryable` / `Blockable` flags. The grab is chosen mostly against a target that keeps blocking (anti-turtle). Look-alike moves get distinct audio and colour tells: red ember glint means unparryable. |
| Arcane Odyssey | "Supercharged" attacks: a sound, a vortex and a longer startup, followed by a long recovery to punish. Loot needs a minimum damage share. | The biggest moves have long, readable wind-ups and long recoveries; the Cleave sticks in the floor for 2.2 s. Rewards need a contribution share, kept low (2% damage or 45 s present) so support players still qualify. |
| Dungeon Quest | Red ground circles that fill before they fire. A teleport phase. Red-circle density rises with difficulty. A destroyable heart makes the boss invulnerable while it stands. | Every area attack draws a red ground decal that fills, as the spec requires. Lance and whirlpool counts rise with party size. Phase 3 exposes the core (spec) instead of an invulnerability heart; a hard immunity phase reads as unfair in a melee game. |
| Swordburst 3, Hagan | Health scales with players. A paw swipe comes from either side. | Coral Sweep alternates its opening side, so players read the shoulder, not a memorised side. |
| Souls-likes (spec pillar) | Posture break → deathblow window; health gates between phases. | Breaking posture kneels the Warden for 4 s, and the first hit is a Finisher. Health clamps at each phase threshold until the transition plays, so burst damage can't skip a phase. |

Rules that follow from this:
1. Every attack is telegraphed at least 0.4 s ahead (spec Section 10).
2. Area attacks always show a red ground decal that fills.
3. Unparryable attacks always flash the red ember glint.
4. Nothing is a guaranteed hit. Even the tidal wave can be dodged through with i-frames.
5. No damage scaling with party size; only health and add counts scale. A crowded fight should feel
   busier, not more random.

## 2. The fight

**Arena: "The Drowned Threshold".**
- A circular court, 140 studs across, of drowned flagstone ringed by broken colonnades, Current
  crystals and rune bands.
- The sealed First Gate stands at its west edge. Tide-line runes on the walls glow as the water rises.
- It is a template in `ServerStorage.GuardianArenas.Brinewarden`, cloned per party into a slot beyond
  the Spire wall, as the Cistern does (decision #133). Reserved servers come with Phase 12.

**Entry.**
- At the First Gate, `Workspace.Floor1.GuardianGate` holds a prompt: "Challenge the Brinewarden".
- Using it opens a 10 s gathering. Anyone else who uses the gate inside the window joins, up to 8.
- Then the gate's Current seal parts, the screen fades, and the party arrives in its arena.

**Intro (4.5 s).**
- The camera sweeps up from the Warden's claws to its helm.
- Name card in large serif type: "The Brinewarden", subtitle "Keeper of the First Gate".
- Skippable after the player's first view (`Floors.IntrosSeen`).
- The Warden stays dormant until the intro has ended for everyone, so skipping gives no advantage.

**Scaling.**
- Health = BaseHealth × (1 + 0.75 × (players − 1)), players counted at the start and capped at 8.
- Bilgecrab adds: 2 + 1 per 2 extra players, max 5.
- Lances: 3, or 5 with 4+ players.
- Whirlpools: one per player, max 4.

**Phases.** Health gates at 100%, 60% and 25%. A transition is about 3 s: the Warden is immune, the
running move is cancelled, the phase card shows, and the music layer changes.

| Phase | Name | Arena | New behaviour |
|---|---|---|---|
| 1 (100–60%) | The Warden's Vigil | Dry court, Pressure 3 (calm) | Teaches the moves. Weak point: the shell seam on its **back**. |
| 2 (60–25%) | The Rising Tide | Arena floods to ankle depth, wall tide-lines light, Pressure 5 | Summons Bilgecrabs, water-jet Lances, Undertow whirlpools. The **tide cycle** starts (below). |
| 3 (25–0%) | The Shell Breaks | Shell cracks, plates fall away, a glowing **core** is exposed on its chest | Faster (telegraphs ×0.85, never under 0.4 s). Desperate Flurry, Core Pulse, full-arena Tidal Wave. Weak point moves to the **front core**. |

**The tide cycle** (phases 2–3) is the spec's Pressure-tide shift:
- **High tide, 14 s.** Water lines high, Pressure 5: spells hit hardest and Current refills fast.
- **Ebb, 7 s.** Water drains, Pressure 1: spells are weak, but the Warden's drying shell takes
  ×1.5 posture damage. This is the melee window.
- A 1.5 s tell plays before each change: a wall-rune pulse and a rush or drain sound.
- So players read the tide and decide when to cast and when to swing.

**Moves.** There are 12; parameters are in `Shared/Data/Guardians.lua`.

| # | Move | Phases | Type | Parry / Block | Tell | Punish |
|---|---|---|---|---|---|---|
| 1 | Coral Sweep | 1 2 3 | 2-blow wide sweep, opens left or right | yes / yes | Greatsword drawn back over a shoulder | 1.1 s |
| 2 | Overhead Cleave | 1 2 3 | Line slam, 34 × 7 | yes / no | Blade raised, a line decal fills | Sword stuck, 2.2 s |
| 3 | Claw Grab (grab) | 1 2 3 | Short cone; holds 2 s, crushes ×3, throws | **no / no** (red) | Ember glint on the claw, low crouch | 1.6 s |
| 4 | Shell Rush | 1 2 3 | Charge line toward a far target | no / yes (red) | Shell lowers, the line decal points at you | Skids, 1.8 s |
| 5 | Brine Stomp | 1 2 3 | Circle r14 around itself, only when 2+ players are behind it | yes / yes | Rears up, ring decal | 1.2 s |
| 6 | Call of the Brine | 2 | Summons Bilgecrabs from the tide pools | — | Roar, pools bubble | 2.0 s |
| 7 | Water-jet Lances | 2 3 | 3 or 5 line decals toward players, then jets | no / yes | Claw raised, lines fill 1.1 s | 1.0 s |
| 8 | Undertow (area denial) | 2 3 | Whirlpools under players: damage over time, Soaked, 7 s | — | Swirl decals fill 1.2 s | — |
| 9 | Tide Surge (Pressure shift) | 2 3 | Forces the tide to change now | — | Raises the sword to the sky | 1.0 s |
| 10 | Desperate Flurry | 3 | 4-blow string; the last blow is red | yes,yes,yes,**no** / yes | Fast wind-up; the glint comes before the 4th | 1.6 s |
| 11 | Core Pulse | 3 | Circle r11 around itself | no / yes | Core brightens, a hum rises | 1.4 s |
| 12 | Tidal Wave | 3 | Ring wave from the Warden to the walls at 34 studs/s; only i-frames avoid it | **no / no** | Water rises at its feet 2.0 s, ring decal at the wall | 2.0 s |

Requirements met:
- grab: #3
- area denial: #8
- unparryable red: #3, #4, #10 (last blow), #11, #12
- Pressure-tide shift: #9 plus the tide cycle
- 12 distinct attacks, within the spec's 8–12

**Posture and weak points.**
- MaxPosture 900. Breaking it stops the running move and kneels the Warden for 4 s.
- The first blow on a kneeling Warden is a Finisher.
- Weak point blows deal ×1.5 damage and ×2 posture (`Config.Mobs.Guardian`): the back seam in
  phases 1–2, the front core in phase 3.
- The Warden doesn't flinch from ordinary hits (it is unflinching); only posture breaks interrupt it.

**Lock points.** Lock-on can cycle between the Head, the Claw (the left pincer) and the Back seam, or the Core in
phase 3. These are `LockPoint` attachments on the body.

**Victory.**
- Clients see 1.6 s of slow motion: the Warden's animation slows, the camera zooms, colour drains, and
  a deep bell tolls.
- Then the "Guardian Felled" card shows: name, fight time and party names.
- Then a personal card: "Floor 2: Amberveil unlocked".

**Rewards.** Every member who meets the contribution share gets:
- XP and gold, personal loot from the `Brinewarden` loot table, and +1 `GuardianKills`
- on their first clear only: `Floors.Unlocked["2"]`, `Floors.GuardiansCleared["1"]` (unix time),
  the Guardian skill points (`Config.Progression.GuardianBonusSkillPoints`) and Spire Shards

**Announcements.**
- The first clear of Floor 1 on each server sends everyone the banner "Floor 1 has been cleared by
  {names}".
- A MessagingService message (`SpireGuardianCleared`) shows other servers a smaller "Across the Spire"
  toast. It is rate-limited and pcall-guarded.

**Wipe.** When every member is dead or gone:
- the Warden resets, and the arena closes after 6 s
- the dead respawn at their Waystone as usual, and their clients see "The tide recedes..."

**Music.**
- A Guardian layer crossfades over 2 s, with one track per phase.
- Track ids live in `Config.Environment.Music`. An empty id plays nothing, so the place owner picks
  licensed tracks from the Creator Store.

## 3. Contracts (fixed before the build; don't change them without the orchestrator)

**Data**
- `Shared/Data/Guardians.lua`: the Guardian definitions (schema documented in the file).
- `Shared/Data/Mobs.lua` entry `Brinewarden`: the body only (a Creature built from Extras). Its
  `Moves` table is empty, so MobService never drives it.

**Config**
- `Config.Mobs.Guardian`: fight-wide tuning (existing keys kept, new keys added).
- `Config.Net` rates for any new to-server remote. Phase 10 adds none; the gate uses `RequestInteract`.

**Net (server → client)**
- `GuardianEvent(kind, payload)`. Each kind and its payload:

| kind | payload |
|---|---|
| `Gather` | `{ EndsAt, Count, Max }` |
| `Intro` | `{ Model, Duration, Skippable }` |
| `Phase` | `{ Model, Phase, Duration }` |
| `Tide` | `{ Model, State: "Calm" \| "High" \| "Ebb", EndsAt, Warning: boolean }` |
| `Victory` | `{ Model, Seconds, Names, FirstClear, Unlocked: string? }` |
| `Wipe` | `{}` |
| `Banner` | `{ Scope: "Server" \| "Global", Floor, Names }` |

- `Telegraph(shape, cframe, sizeA, sizeB, duration, flags)`:
  - Generic ground telegraph, usable by any mob.
  - `shape` is `"Circle"` (radius = A), `"Ring"` (outer radius = A, inner radius = B), `"Line"`
    (length = A along the CFrame's LookVector from its position, width = B) or `"Cone"` (radius = A,
    arc in degrees = B).
  - `flags` is a bit set: 1 = unparryable (red, ember), 2 = follows the attacker (`cframe` is relative
    to the boss root).

**Attributes on the Warden's Model** (the existing mob attributes also apply):
- `GuardianId` = "Brinewarden"
- `GuardianPhase` = 1..3
- `GuardianTide` = "Calm" | "High" | "Ebb"
- `GuardianTideEndsAt` = server time
- `FightStartedAt` = server time
- `MobBlow` telegraph field: 0 = none, 1 = telegraph, **2 = unparryable** (red ember glint and the
  unparryable sound)

**Lock points:** `Attachment`s named `LockPoint`, with attribute `LockName` and attribute `Enabled`
(boolean).

**Profile (DataVersion 4 → 5, additive):** `Floors.IntrosSeen: { [string]: boolean }` (key = Guardian
id).

**Workspace (built by the edit-time tool):**
- `Workspace.Floor1.GuardianGate` contains:
  - a `ChallengePrompt` part tagged `SpireGuardianGate`, with attributes `GuardianId` and `GatherRadius`
  - a `Return` part, where the party comes back after the fight

**Arena template:** `ServerStorage.GuardianArenas.Brinewarden`, a Model with PrimaryPart `Origin`
(floor centre, +Z toward the gate). Children:
- `BossSpawn`
- `PlayerSpawns` (8 Parts)
- `AddPools` (Parts)
- `TideWater` (Part, CanCollide off), plus attributes `CalmY`, `HighY` and `EbbY` (offsets from Origin)
- `TideLines` (Neon parts, lit by tide)
- `PressureZone` (tagged `PressureZone`, attribute `Pressure`)
- `Seal` (Part, collides only while sealed)
- `Bounds` (attribute `Radius` = 70)

## 4. Build split

| Work | Agent | Files |
|---|---|---|
| Contracts (this doc, Data/Guardians, Config, Net, Strings, Attributes doc) | orchestrator | as listed |
| Server fight | builder (Opus) | new `Systems/GuardianService/*`; small additions to `MobService` (scripted mobs), `CombatService` (unflinching, per-fighter Broken time, big-body hit sizes), `TargetService` (hit size), `DataService` (v5), `Server.server.lua` ORDER |
| Client fight | builder (Opus) | new `Controllers/GuardianController`, `Controllers/TelegraphController`, `Controllers/MusicController`; small changes to `MobController` (no plate for Guardians, unparryable glint), `LockOnController` (lock points), `Client.client.lua` ORDER |
| Arena and gate | builder (Opus) | new `ServerStorage/Tools/Floor1GuardianArena.lua` (Apply/Undo, KitLibrary pieces); the Warden's body in `Data/Mobs` |
| Loot and items | content-author (Sonnet) | `Data/Items`, `Config/Loot` (`Brinewarden` table) |

## 5. Acceptance

- Strict type check clean (only ProfileStore errors); `rojo build` succeeds.
- Lune: sync the scripts into a copy of the place, run the arena tool, and the place round-trips.
- Offline fight simulation (`tools/place/sim_guardian.luau`):
  - drives GuardianService's pure decision logic through a scripted fight
  - checks the phase gates, move choice per phase, scaling and the tide timing
- Reviewer pass over the server and client diffs.
- Not possible here: a 2-player Studio test. The final report says so.
