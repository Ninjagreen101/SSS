# Phase 11: Quests and onboarding

Spec sources:
- Section 14, "Quests and progression loop"
- Section 12: the HUD tracker and minimap, Quest Log (J), Map (M), toasts
- Section 16, item 11, and the acceptance line "a new player can finish the tutorial and kill their
  first mob in under 3 minutes without reading anything long"

## 1. What players get

| Feature | Spec | Our take |
|---|---|---|
| Main story | 10–15 quests per floor, voiced-text NPC dialogue, ending at the Guardian | 12 Floor 1 quests from the docks to the Brinewarden, given by named NPCs in a typewriter dialogue box |
| Side quests | 8–12 per floor, short stories, item rewards, tower lore | 10 Floor 1 side quests spread over the districts and wild zones |
| Dailies / weeklies | 3 dailies (kill, gather, dungeon), 2 weeklies, Shards and gold | Rolled per player at 00:00 UTC (dailies) and Monday 00:00 UTC (weeklies) from pools |
| Achievements | Titles under player names ("Floor 1 Pioneer", "Parry Master") | About 20 achievements. Some grant a title the player can show under their name |
| Onboarding | First 10 minutes guided on the Floor 1 docks at night; movement, light combo, dodge, parry taught by a Drowned Sailor, a Tide Bolt preview, Resonance once with a big prompt, then the town; taught by doing | 8 short steps (section 5). Each step is a one-line prompt plus an action to perform. First kill within about 2 minutes |
| Quest Log (J) | Main / floor / side / dailies; objectives, rewards with item previews, Track | A menu tab in the existing hub |
| Tracker | Right side: objective, counters, distance to marker, collapsible | HUD panel on the right |
| Map (M) | Full floor map, fog of war, Waystones (fast travel when standing at one), quest markers, custom pins, floor selector | MapController. Fog cells clear as you explore (server-tracked) |
| Minimap | Top-right, circular, rotating, quest markers, party, Waystones, Pressure icon | The same map source, clipped to a circle beside the Pressure icon |

## 2. Architecture

**Server (ServerScriptService/Systems):**
- `GameEvents`: the action bus (written; see the file header for its kinds).
  - Every system fires the actions it decides: kills, pickups, crafts, discoveries, attunement,
    clears, parries, dodges, combos, casts, Resonance, Confluences, level-ups, regions, gold, deaths.
- `QuestService` owns quest state in the profile:
  - accept, progress, ready, turn in, abandon, track
  - daily and weekly rolls and rewards
  - it listens to GameEvents
- `AchievementService`:
  - unlocks from GameEvents and PlayStats
  - Shards rewards
  - the player's chosen title, written as player attribute `Title`
- `NpcService`:
  - builds the town NPCs (R15 bodies, Builder-style) at `Workspace.Floor1.Npcs` markers
  - idle and route-walking behaviour
  - a ProximityPrompt per NPC
  - validates "near this NPC" for Talk, Accept and TurnIn
- `MapService`: records exploration (a 48×48 cell grid per floor, saved as a hex bitset) and custom
  pins.
- `TutorialService`: runs the onboarding for new profiles (section 5).

**Client (StarterPlayerScripts/Controllers):**
- `DialogueController`: dialogue box with a typewriter effect and a soft "voice" blip, choices, and
  Accept / Turn in.
- `QuestController`: Quest Log tab (J), the tracker, world markers (beams and billboards over NPCs
  and objectives: `!` for available, `?` for ready), and quest toasts.
- `AchievementController`: unlock toast, and a title picker in the Character sheet.
- `NameplateController`: name, level and title over every player.
- `MapController`: Map (M) and the minimap.
- `TutorialController`: one-line step prompts with input glyphs, the local night lighting override,
  and the big Resonance prompt.

**Data (ReplicatedStorage/Shared/Data):** `Quests`, `Npcs`, `Achievements`. Their schemas are in the
module headers. All player text lives in Strings: `Strings.Quests`, `Strings.Npcs`,
`Strings.Achievements`, `Strings.Tutorial`, `Strings.QuestUI`.

**World (edit-time tool `ServerStorage/Tools/Floor1Npcs`)** builds two folders:
- `Workspace.Floor1.Npcs`: one marker Part per NPC (attribute `NpcId`), plus `Route_<NpcId>`
  folders of ordered points for walkers.
- `Workspace.Floor1.QuestPoints`: Parts with attribute `PointId` and `Radius`, used by Reach
  objectives and marker positions, including the tutorial pier.

**Map image:**
- `tools/place/render_map.luau` (Lune, using Layouts/Floor1) writes a stylised top-down
  `assets/map/floor1_map.png`.
- `Config.World.Maps["1"].Image` takes its uploaded asset id. With an empty id, the client draws the
  map from `ReplicatedStorage.FloorData.Regions` as merged colour runs.
- To refresh it: `lune run tools/place/render_map.luau` (about 75 s; needs Python 3 with Pillow and numpy) rewrites
  the 1024×1024 PNG, which covers the whole floor (Center (0, 0), Size 3000, north = -Z at the top, so image
  x = world X and image y = world Z) with no text labels. Upload it in Studio (Asset Manager > Bulk Import, as an
  Image) and paste the resulting `rbxassetid://` id into `Config.World.Maps["1"].Image`. The UI draws labels,
  Waystones, markers and fog on top.

## 3. Contracts

**Profile v6 (additive):**
- `Quests`:
  - `Dailies: { string }` and `Weeklies: { string }`: today's rolled quest ids
  - `Rerolls: number`
  - existing: Active, Completed, Tracked, DailyResetAt, WeeklyResetAt
- `QuestState.Progress`: keyed by objective index as a string ("1", "2", ...)
- `Map = { Explored: { [floor]: string }, Pins: { [floor]: { { X: number, Z: number, Icon: string } } } }`
- `Tutorial = { Step: number, Done: boolean, Skipped: boolean }`
  - existing profiles migrate to `Done = true`, so veterans are never sent back to the docks

**Net, client → server** (intent only; the server checks the NPC distance and every rule):
- `RequestQuestAction(action, questId, npcId)`
  - `action` is "Accept", "TurnIn", "Abandon", "Track" or "Reroll"
  - `npcId` is "" when no NPC is needed
- `RequestTalk(npcId)`: the player opened a dialogue (Talk objectives)
- `RequestSetTitle(achievementId)`: "" clears the title
- `RequestMapPin(action, x, z, icon)`: `action` is "Add" or "Remove"; Remove removes the nearest pin
- `RequestTutorial(action)`: `action` is "Skip" or "Continue" (Continue: closes a read-only prompt)

**Net, server → client:**
- `QuestEvent(kind, questId, payload)`: `kind` is "Accepted", "Progress", "Ready", "Completed",
  "Abandoned" or "Rolled". Used for toasts and sounds; the state itself replicates through
  DataController.
- `AchievementUnlocked(achievementId)`
- `TutorialStep(step, payload)`

**Attributes:**
- player: `Title`, a Strings path such as "Achievements.Titles.ParryMaster", or ""
- NPC model: `NpcId`
- quest point: `PointId`, `Radius`

**Tags:** `SpireNpc` on NPC models, `SpireQuestPoint` on quest points.

**NPC roster.** All names are original. Marker ids equal NPC ids.

| NpcId | Name / role | Where | Gives |
|---|---|---|---|
| `Brannoc` | Brannoc Hale, Dockmaster | Arrival quay, Climbers' Rest | M1, side "Nets and Knots" |
| `Ysolde` | Warden Ysolde Tarn, master of the Climbers' Guild | Guild hall steps | M2–M5, M11–M12 |
| `Pell` | Old Pell, a one-eyed net-mender | Docks | tutorial guide, side "What the Tide Brings" |
| `Ilse` | Ilse Marrow, Archivist of the Library of Floors | Library | M10, side "The Floors Above" |
| `Tobin` | Tobin Quill, Provisioner | Market plaza | side "Brine Pearls" |
| `Caddith` | Sister Caddith, Cathedral of the Ascent | Cathedral forecourt | side "Candles for the Drowned" |
| `Maren` | Captain Maren Dusk of the Watch | Barracks / Training Ground | M7, side "Parry Drill", "The Watch Needs Steel" |
| `Osk` | Reedwarden Osk | Reedwarden Post (marsh) | M6, side "Lanterns in the Reeds" |
| `Hesk` | Hesk Thornwell, forester | Rustwood Camp | M8, side "Rust on the Bark" |
| `Fen` | Fen, a canal urchin | Canal bridge, Market terrace | side "Fish That Glow" |

**Quest points (PointId):**
- Tutorial: `TutorialStart`, `TutorialMove`, `TutorialSprint`, `TutorialArena`, `TutorialExit`
- Town: `GuildSteps`, `RotundaDoor`, `LibraryDoor`, `CathedralDoor`, `MarketFountain`, `OldWharf`,
  `BrinehulkLagoon`, `CisternMouth`, `GateApproach`
- Canals: `CanalNorthFalls`, `CanalSouthFalls`, `CanalMouth`

**Main story** (quest ids `F1_M01`..`F1_M12`; levels are a guide):

| # | Id | Name | Objectives | Level |
|---|---|---|---|---|
| 1 | F1_M01 | Salt in the Lungs | Talk Brannoc (unlocked by the tutorial) | 1 |
| 2 | F1_M02 | A Climber's Mark | Reach GuildSteps, Talk Ysolde | 1 |
| 3 | F1_M03 | Rest at the Stone | Discover 2 Waystones | 2 |
| 4 | F1_M04 | Teeth of the Tide | Kill 6 Bilgecrab | 2 |
| 5 | F1_M05 | The Shrine of Currents | Attune (any) | 3 |
| 6 | F1_M06 | Lights in the Reeds | Reach the Reedwarden Post (Discover Waystone F1_ReedwardenPost), Kill 4 MarshWisp | 4 |
| 7 | F1_M07 | What the Sailors Took | Reach OldWharf, Kill 5 DrownedSailor | 5 |
| 8 | F1_M08 | Hunters in Rustwood | Discover Waystone F1_RustwoodCamp, Kill 5 RustwoodStalker | 6 |
| 9 | F1_M09 | The Lagoon's Lord | Kill 1 Brinehulk | 8 |
| 10 | F1_M10 | Beneath the Pumphouse | Talk Ilse, Clear Dungeon:SunkenCistern | 9 |
| 11 | F1_M11 | The Keeper's Price | Talk Ysolde, Discover Waystone F1_GateApproach | 11 |
| 12 | F1_M12 | The First Gate | Clear Guardian:Brinewarden | 12 |

**Side quests** (`F1_S01`..`F1_S10`, 8–12 per the spec):
- Nets and Knots (Brannoc)
- What the Tide Brings (Pell)
- The Floors Above (Ilse, 2 secrets)
- Brine Pearls (Tobin)
- Candles for the Drowned (Caddith)
- Parry Drill (Maren, 10 parries)
- The Watch Needs Steel (Maren, craft a weapon)
- Lanterns in the Reeds (Osk, Lantern Acolytes)
- Rust on the Bark (Hesk)
- Fish That Glow (Fen, Reach 3 canal points)

**Dailies:** pools Kill, Gather and Dungeon, one quest rolled from each per day. **Weeklies:** 2 from
a pool of 4. Rewards are Shards and gold.

## 4. Build split

| Work | Agent | Files |
|---|---|---|
| Contracts (this doc, GameEvents, data schemas, Net, profile types, Strings.QuestUI) | orchestrator | as listed |
| Server systems | builder (Opus, xhigh: save data, remotes) | QuestService, AchievementService, NpcService, MapService, the GameEvents fire calls in existing services, profile v6, a shared `EconomyService.GrantShards` |
| Tutorial | builder (Opus) | TutorialService, TutorialController, tutorial mobs via MobService options |
| Client UI | builder (Opus) | DialogueController, QuestController, AchievementController, NameplateController, MapController, UIController registration |
| World and map | builder (Sonnet) | Tools/Floor1Npcs, tools/place/render_map.luau, `assets/map/floor1_map.png`, `--npcs` in sync_scripts |
| Content | content-author (Sonnet) | Data/Quests, Data/Npcs, Data/Achievements content; `Strings.Quests`, `Strings.Npcs`, `Strings.Achievements`, `Strings.Tutorial` |

## 5. Tutorial

The tutorial starts when a profile has `Tutorial.Done ~= true`. It runs on the docks, locally at night
(the client overrides its own lighting during the tutorial). The Drowned Sailor and the crab are
tutorial mobs that only fight this player (`AllowedTargets`).

| Step | Prompt (Strings.Tutorial) | Done when |
|---|---|---|
| 1 Move | "Move" plus stick/WASD glyphs | Reach TutorialMove |
| 2 Sprint | "Hold {key} to sprint" | Reach TutorialSprint while sprinting |
| 3 Light combo | "Strike the crab" | Kill the tutorial Bilgecrab (the first kill, under 2 minutes) |
| 4 Dodge | "Dodge the red swing" | One Dodge or PerfectDodge against the tutor |
| 5 Parry | "Block just as it strikes to Parry" | 2 Parry events against the tutor (Old Pell calls out the timing) |
| 6 Spell | "Cast Tide Bolt" | One Cast of the preview Tide Bolt (granted for the tutorial only) |
| 7 Resonance | Big prompt: "Resonance! Hits and spells build it. At 5 stacks, unleash a Confluence." | Shown once on the first Resonance stack, then Continue |
| 8 Finish | "Defeat the Drowned Sailor" | Kill the tutor; then F1_M01 is given automatically and the marker points to Brannoc |

The tutorial can be skipped from the first prompt (the button appears after 5 s). Skipping sets `Skipped`
and gives F1_M01.

## 6. Acceptance

- Type check clean (except ProfileStore); `rojo build` succeeds.
- The Lune quest simulation passes. It steps every Floor 1 quest's objectives through GameEvents and
  checks that:
  - every quest can be accepted, progressed, completed and turned in
  - rewards add up
  - dailies roll deterministically per day
  - no main-story quest needs an earlier one that isn't in its chain
- The place sync runs with `--npcs`. The map PNG renders.
- A reviewer pass.
- Not possible here: the 2-player Studio test, and the 3-minute tutorial timing with real input.
