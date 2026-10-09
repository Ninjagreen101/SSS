--!strict
-- DESIGN_DECISIONS.md: choices made where the design spec was ambiguous or
-- conflicted with Roblox. Stored as a ModuleScript (Studio can't hold .md
-- files); require it or open it in the script editor to read.

return [==[
# The Spire - Design Decisions

Each entry: the ambiguity, the choice, and why (fun, readability, mid-range phone performance).

## Phase 1 - Foundation

1. **Bootstrap names.** The spec's `Server.server.lua` / `Client.client.lua` are Rojo file names. In Studio they are a Script
   `ServerScriptService.Server` and a LocalScript `StarterPlayerScripts.Client`. No other scripts exist.
2. **ProfileStore.** The official module by loleris (MAD STUDIO, Apache-2.0), inserted from its Creator Store listing
   (asset 109379033046155) and kept unmodified at `ServerScriptService.Packages.ProfileStore`.
   It is third-party code, so it keeps its own type mode instead of `--!strict`. Autosave period is set to 120 s with
   `SetConstant`. In an unpublished place (or without "Enable Studio Access to API Services") ProfileStore runs in mock
   mode: everything works, but data is not kept between Studio sessions. Publish the place and enable API access to test
   real persistence.
3. **Trade lock.** Profiles are only mutated by a trade inside `DataService.RunAtomic`, which refuses to yield, so an
   autosave can never see a half-applied swap. While profiles are trade-locked, forced saves (`SaveNow`) are deferred and
   run when the lock is released.
4. **Newer save data.** If a profile was saved by a newer server build (higher DataVersion), the player is kicked with a
   "rejoin" message instead of loading, so an old server can't silently drop new fields.
5. **Settings saving.** The client applies a setting instantly and sends `RequestSaveSetting(key, value)` after a 1.5 s
   debounce. The server validates every key with its own schema (`Shared.Data.SettingsSchema`). Only keybinds that differ
   from the defaults are saved.
6. **Tab conflict.** The spec binds Tab to both Lock-on and Inventory. Tab = Lock-on (combat needs it); Inventory = I.
7. **Esc conflict.** Roblox reserves Escape for its own menu. Settings opens with O and from the menu hub; menus close
   with Backspace, the X button, or gamepad B.
8. **Dodge on Space.** Space stays Jump (Roblox convention, needed for platforming). Dodge is Q. Players can rebind.
9. **Menu tab keys.** Q / E switch tabs only while a menu is open (the Menu input context), so they don't clash with
   Dodge / Interact in gameplay. Gamepad uses LB / RB.
10. **Unassigned keys.** Quick items Z / X, ping G, emote wheel T, UI gallery F8 (Studio only).
11. **Gamepad.** Weapon Art = LT + RT chord (hold LT, then press RT; RT alone is Heavy Attack). Quick item = Y.
    Menu hub = View/Select. Back = B.
12. **Mobile jump.** Roblox's default jump button sits where the attack cluster goes, so it is hidden and replaced by our
    own Jump button inside the cluster (same style, no overlap). Thumbstick stays Roblox's.
13. **Mobile attack.** Tap = Light Attack; holding past 0.25 s = Heavy Attack (released on lift). All touch targets are at
    least 44 px and never scale below that.
14. **Mobile menus.** Full-screen on touch devices; the toast feed lifts above the touch cluster.
15. **Fonts.** Merriweather Bold for display/titles, Builder Sans for body and numbers.
16. **UI sounds.** Until original audio is produced (Phase 15 audio pass), UI uses sounds bundled with the Roblox client
    (`rbxasset://sounds/...`), which are legal to use. All ids are in `Config.Assets` for a one-line swap.
17. **Item icons.** Until the painted 256x256 icons exist (Phase 7), item slots show the item's initials in its rarity
    colour so slots still read clearly.
18. **Abyss colour.** "Deep indigo" is brightened to #5B4BD6 in UI so it stays readable on the navy panels.
19. **Unspecified numbers.** Values the spec doesn't give (block stamina per damage 0.6, posture recovery, Siphon 5 per
    hit, saturation per cast, upgrade fail chances, respec cost 75 gold/level, etc.) are first-pass picks, marked in
    `Shared.Config` for tuning in playtests.
20. **Anti-exploit in Studio.** Strikes are logged in Studio but never kick (`Config.Net.Strikes.KickInStudio = false`), so
    testing isn't interrupted.
21. **Analytics in Studio.** Events print to Output instead of calling Roblox AnalyticsService.
22. **Notifications.** The server sends toasts as a Strings path plus arguments (`Notify("Toasts.Welcome", {...})`), so
    every player-facing string still lives in `Strings`.
23. **Typing.** `Maid:Add` returns `any`, and InputController uses plain strings for action names internally. Both work
    around limits of the Luau type solver without weakening runtime checks.

## Phase 2: Player core

24. **Health lives on the Humanoid**, written only by the server (VitalsService). Roblox's default "Health" regen script is
    removed on spawn. There is no passive health regen: you heal by resting at a Waystone (and with consumables, Phase 7).
25. **Stamina and Current** are tracked by the server and replicated as Player attributes at 10 Hz, only when a value
    changes. Attribute names live in `Shared.Attributes`.
26. **Waystones.** Discovered by walking within 24 studs; resting is a 0.5 s hold of Interact. Resting sets your respawn
    point and fully restores health, stamina and Current.
27. **Death.** The body ragdolls, the world desaturates, and a Respawn button unlocks after 3 s (server-checked). You rise
    at the last Waystone you rested at, else the floor's default Waystone.
28. **Lost Current.** Dying drops 10% of carried gold as an orb where you fell. Walking back within 6 studs returns it.
    Dying again before that replaces the old orb, and its gold is lost. Only the owner sees their orb.
29. **No player collision.** Players pass through each other (busy hubs, no griefing by body-blocking).
30. **Mouse.** The cursor is locked to the centre during gameplay. Hold Left Alt (Free Cursor, rebindable) or open any menu to
    free it. Roblox's Shift Lock is disabled because our camera already works that way and Shift is Sprint. While the
    mouse is locked, a small teal reticle marks the screen centre.
31. **Facing.** Outside lock-on the character turns to face where it moves (classic third-person action), not the camera.
32. **HUD fade and placement.** The vitals cluster dims to 75% after 6 s out of combat when everything is full and you are
    not sprinting. It sits below Roblox's top-left buttons (CoreUISafeInsets) so the menu and chat buttons never cover it.
33. **Sprint per device.** Keyboard: hold Shift. Gamepad: click L3 to toggle; it turns off after 0.5 s standing still.
    Mobile: pushing the stick past 90% sprints (Auto Sprint setting, on by default). The client predicts walk speed for
    instant response; the server only takes the intent, drains stamina, and rejects anything faster than a legal sprint.
34. **Movement checks.** The server samples each character 4 times a second. Moving faster than sprint speed (+35% and
    6 studs/s slack for lag) three times in a row, or more than 60 studs in one sample, snaps the player back and adds
    strikes. Falling is ignored. Server teleports reset the check.
35. **Saturation ring and Resonance notches** are on the HUD now and stay empty until Phases 5 and 6 fill them.
36. **Blockout Waystones.** The two Floor 1 Waystones are simple stone-and-crystal blockouts until the Floor 1 build
    (Phase 9).
37. **DevHooks (Studio only).** `ServerStorage.DevHooks:Invoke("Damage", "Name", 40)` and similar commands (Heal, Kill,
    AddGold, SetLevel, SetStamina, Respawn, Restore, Dump) make testing easy. They are never created in live servers.
38. **Avatar.** Players use their own Roblox avatar until character creation arrives.
39. **Sprint speed lines** wait for the VFX polish pass. Sprinting already widens the FOV (70 to 76).
40. **Interact keys.** Prompts ignore Roblox's built-in key handling. Our Interact action (any binding, including mouse
    buttons) drives them, so rebinding Interact works everywhere. On touch the prompt itself can be held.

## Phase 3: Sword combat

41. **Parry is block timing.** Raising your guard opens the parry window (0.18 s, +2 frames for Longswords, +2 frames on
    touch). There is no separate parry button, so the unused RequestParry remote was removed. Re-raising is limited by
    Parry.Cooldown so mashing block doesn't work.
42. **The server finds the hits.** A client only says "I swung, aiming this way". When the windup ends, the server checks
    every enemy in reach and inside the swing arc, rewinding targets by the attacker's ping (max 0.2 s). Clients never
    report hits, so hit exploits have nothing to send.
43. **Server-owned combo.** The combo step is decided by the server (it resets 0.8 s after a swing ends). The client's
    combo number only picks the animation.
44. **Posture.** Enemies and dummies build posture from every blow. Players build it only by blocking (and attackers
    when parried). Full posture = Broken for 2 s; the next blow is a Finisher (x3 damage) that resets it.
45. **No PvP.** Players are on one team and can't hurt each other. Duels can be added later as an opt-in team swap.
46. **Placeholder weapons and slash arcs.** Until weapon meshes and animations exist, each weapon is a simple blade
    built from parts in the right hand (Twinfangs get two), and every swing draws a short glowing arc.
47. **Roll cancel.** Once a swing's blow has landed, its recovery can be cancelled into a dodge roll.
48. **Riposte.** After a parry, your next attack within 1.2 s deals x3 (Needles always crit for x2.5 on top).
49. **Training dummies never die.** They heal after 4 s alone and stand back up at 0 health. The Sparring Dummy glows
    red for 0.55 s before each swing so parry timing can be learned.
50. **Starter weapon.** An empty weapon slot wields the Climber's Longsword. In Studio,
    `DevHooks:Invoke("SetWeapon", nil, "StonejawGreatblade")` tries any class.
51. **Aim turn-rate check is for spells.** Melee aim only picks a direction inside a swing arc, so it is not
    rate-checked. MaxAimTurnDegreesPerSecond stays in Config for aimed spells (Phase 5).
52. **Lock-on owns the camera.** While locked, sideways mouse or right-stick flicks switch targets instead of turning
    the camera. Touch players tap LOCK to toggle.
53. **Lock-on keys.** Middle mouse or V. Tab was the spec's second key, but Roblox reserves Tab for its player list
    (it never reaches the game), so Tab is now a reserved key that can't be bound.
54. **Animation source.** Combat clips come from Mixamo's free Sword and Shield Pack plus the Sprinting Forward
    Roll, retargeted to R15 offline and published under the owner's account (no third-party animation IDs, which
    can't play in our place). Swings are retimed so contact lands exactly on the weapon's windup; Dodge is the
    roll squeezed to 0.4 s, in place, and plays for every dodge direction. Other classes borrow the Longsword set,
    sped up to their own windup, until they get their own clips.
55. **Guard and sprint animations.** Block is a braced two-handed guard: the blade angles up across the body and
    the arms are re-solved so the right hand sits by the guard and the left hand below it on the grip. It is held
    as a single pose so raising it is instant for parries. Sprint is a looping run layered over Roblox's default run (Movement
    priority). It only plays while sprinting on the ground and its playback rate follows real speed
    (Config.Combat.Movement.SprintAnimation), so a jump, a dodge or Winded switches it off.
56. **Two-handed guard by IK, not by animation alone.** Players use their own avatars, whose arm lengths, hand
    sizes and shoulder widths differ, so a keyframed guard put the off hand in the air on most bodies.
    GuardPoseController re-poses the arms every frame while Blocking with a two-bone IK built from each avatar's
    own joints: right hand on the grip at a guard point (Config.Combat.Block.GuardPose, scaled to the avatar),
    left hand on the same grip just behind it. The Block animation still drives legs and torso. It's visual only
    and runs on every client for every character. Two-handed weapons' grips are built long enough to fit both
    hands (Shared/Util/WeaponGrip); Twin weapons keep the animated pose.
57. **Floor 1 enemies (Phase 4).** The spec's Section 10 gives AI and Guardian numbers but no Floor 1 roster, so three
    original enemies fill it, one per fighting lesson: Saltworn Drifter (parry its slashes), Barnacled Hulk (dodge
    its uninterruptible slam, punish the recovery) and Brine Acolyte (close the distance through blockable,
    dodgeable bolts). Any of them can spawn as an Elite (Mobs.Elite multipliers, gold band and glow).
58. **Enemies are data.** Shared/Data/Mobs defines stats, body look, held blade and every move (range band,
    telegraph, blows, damage, posture, parry/block rules, hyper armour, lunge, recovery, cooldown). A new enemy is a
    table entry plus its name in Strings; spawn points are Parts in Workspace.MobSpawns with attributes.
59. **Mobs fight through CombatService.** Their blows use NpcSwing / NpcHit, so parry, block, dodge i-frames,
    posture, Broken and finishers behave exactly as against players and dummies. New CombatService calls:
    NpcBeginAttack / NpcEndAttack (shows Attacking, optional hyper armour) and NpcSwingVisual.
60. **Fair aggression.** At most Mobs.AI.MaxAttackersPerPlayer mobs attack one player at once (attack slots); the
    others circle at CircleRadius. No move repeats more than MaxSameAttackRepeats times. Every telegraph is at least
    MinTelegraph, and mobs stop turning toward you TrackCutoff (0.15 s) before contact so late dodges work.
61. **Threat and leash.** Damage adds threat (decaying 2%/s); mobs chase the top-threat player. Past LeashRadius
    from home, or after LoseTargetTime without a target, they walk home ignoring hits, then heal fully and reset
    posture. Pack mobs within PackRadius join when one is alerted or hit.
62. **Thinking budget.** 10 thinks/s near players, 1/s further out, asleep beyond SleepRadius. Moves run in their own
    thread so blow timing doesn't depend on the think rate. Paths come from PathfindingService only when a straight
    line is blocked, at most every PathRecomputeInterval.
63. **Client-side mob animation.** The server never plays mob animations. It publishes each blow in the MobBlow
    attribute (slot, windup, start time, telegraph flag); every client stretches the clip so its contact frame lands
    on the server's hit, and shows the red telegraph. Mobs reuse the owner's Longsword clips plus Roblox's standard
    idle/walk/run, so no new animation assets are needed. Only mobs within AnimationCullRadius animate.
64. **Projectiles.** Brine bolts are simulated on the server (sphere casts at Projectile.StepRate) and drawn by
    clients from the MobProjectile remote. They are blockable but not parryable; a bolt you roll through keeps flying.
65. **Rewards before loot.** Each kill gives full XP and gold to every player who damaged the mob and is within
    PartyXP.ShareRadius (elites x3). Level ups grant stat points (and skill points from level 15) and heal fully.
    Item drops wait for the inventory phase.
66. **Pacing.** After each move a mob waits Mobs.Pacing.MoveGap (ranged: RangedMoveGap) before starting another,
    repositioning meanwhile, so every exchange leaves a window to punish or heal. Lunges stop LungeStopDistance short
    of the target instead of shoving players around, and ranged mobs only shoot with a clear line of sight.
67. **Ragdolls on new avatar rigs.** Roblox avatars now load with AnimationConstraint joints, which the Phase 2
    ragdoll (Motor6D only) didn't touch, so dead bodies fell through the floor. CharacterService.Ragdoll handles both
    joint types and makes every limb collide; mobs use it too before they dissolve.

## Phase 5: The Current

68. **Scope.** Phase 5 ships the core of the Current: the 5 Attunements x 6 Forms (30 spells), Saturation, Overflow,
    Burnout, Resonance, statuses and Reactions. Infusion, Confluence, Beacons and Pressure are tuned in
    Config.Current but wait for a later phase, so the first magic playtest stays readable.
69. **Spells are Attunement x Form.** The spec names the elements but not 30 separate spells, so each spell is an
    element (colour, status, Reaction) shaping a Form (Bolt, Wave, Ward, Lance, Well, Step). Shared/Data/Spells holds
    two small tables and builds all 30 from them; a new Form or element is one table entry plus its Strings.
70. **Attunement Shrine.** Attunements are chosen at a Shrine in Climbers' Rest (Workspace.AttunementShrine, tagged
    AttunementShrine): a first one at Attunement.PrimaryLevel (8), a second at SecondaryLevel (30). The server only
    accepts RequestAttune after the Shrine offered it to that player and while they still stand within
    Casting.ShrineDistance, so an exploiter can't attune from anywhere or skip the level gate.
71. **Forms unlock by level.** Bolt 8, Wave 10, Ward 12, Lance 15, Well 18, Step 22. Each Form is learned for every
    Attunement you carry, and new spells fill empty hotbar slots (4 slots, keys 1-4 / D-pad / I-IV on touch).
72. **Casting goes through CombatService.** A cast is a combat action ("Casting") with a cast time and a recovery,
    so the hit order (dodge, parry, block, clean hit), stagger, posture and finishers all apply to casters too.
    A stagger during the cast time cancels it, and the Current spent is lost. Spell blows can be blocked but not
    parried. They don't refill Current (only sword hits do) and they never crit.
73. **Server-decided aim.** Clients send only the spell id and a world point. The server checks the spell is known,
    off cooldown, affordable and that the caster isn't busy, clamps the point to Casting.MaxCastRange, and does
    every hit test itself: Bolts are server projectiles, Waves and Lances are geometric checks stopped by walls,
    and Step's landing spot is raycast so you can't blink through walls.
74. **Aiming on every device.** Lock-on wins; otherwise touch players get the nearest enemy within
    MobileAutoTargetConeDegrees of where they face, and mouse/gamepad players aim at the centre of the camera.
75. **Statuses and Reactions.** Each hit applies its Attunement's status (Soaked slows, Chilled stacks to Frozen,
    Shocked chains Tempest hits to 2 more enemies, Heavy +20% damage taken, Rooted holds in place). A spell whose
    Attunement detonates a status already on the target consumes it for x1.75 damage, shown as REACTION:
    Tempest on Soaked, Abyss on Chilled, Tide on Rooted. Statuses work on mobs, dummies and players alike.
76. **Ward and Bloom.** Ward is a shield that absorbs damage before health (VitalsService) and marks attackers with
    your status. Bloom has no Reaction of its own; instead its Ward and Well heal (Renewing), so a support build
    exists from day one.
77. **Saturation, Overflow, Burnout, Resonance.** Casting fills Saturation (cost x 0.6); when it's full, Overflow
    gives +25% spell damage for 8 s, then Burnout slows casting 20% for 6 s and empties the ring. A sword hit
    within 2.5 s of a spell hit (or the reverse) adds a Resonance stack (+6% to both, up to 5); at 3 stacks the
    blade glows in your Attunement's colour. This rewards mixing sword and spell instead of spamming either.
78. **One projectile system.** Mob brine bolts and players' Bolts share ProjectileService (the old
    MobService.Projectiles is gone), with one Projectile remote carrying a colour. Shots pass through their own
    team, so you never block a friend's Bolt.
79. **Cast animations reuse sword clips.** No new animation assets are needed: each Form plays one of your sword
    clips (Bolt Light4, Wave Light5, Lance/Well Heavy, Ward Block, Step Dodge) stretched so its contact frame
    lands when the spell goes off. Dedicated casting animations can replace them later in Config.Assets.
80. **Fixes from the Phase 5 playtest.** (a) Roblox's default Backpack is turned off (SpellController): the game has
    no Tools, and the Backpack claims keys 1-9, which are the cast keys. (b) Ragdolls weld the HumanoidRootPart to the
    lower torso: on AnimationConstraint rigs its joint switches off at death, so it fell out of the world and
    dragged the death camera with it (amends 67). (c) The hotbar drops spells you no longer know before filling
    empty slots, so a future respec can never leave dead buttons.

## Phase 6: Resonance, Weapon Arts, Confluences, Pressure, Beacons

81. **Moves are data.** Weapon Arts and Confluences share one timeline format (Shared/Data/Moves): steps at set
    times (arc, circle, line, projectile, dash, leap, blink, strikes, chain, burst, field, pull, push, heal,
    leech, mark). One server Runner plays them through CombatService (dodges, blocks, posture and damage numbers
    work exactly like sword hits) and one client renderer draws them. A new Art or Confluence is a table entry,
    not new code.
82. **Resonance rewards alternating.** A stack comes from landing a weapon blow then a spell, or a spell then a
    weapon blow, within 2.5 s; the same tool twice doesn't count. Weapon Arts count as weapon blows. A
    successful parry adds a stack outright. Only blows that land count (dodged, parried or Aegis-absorbed ones
    don't). A Confluence consumes every stack.
83. **The Weapon Art button does three things.** Tap below max Resonance: the weapon's Art (Current cost and its
    own cooldown). Tap at max Resonance with an Attunement: the Confluence (30 Current, 25 s cooldown, 0.4 s of
    invincibility, hyper armour). Hold 0.6 s: Infusion (25 Current, 10 s; weapon blows apply your element's
    status and Siphon 50% more). The server picks between Art and Confluence, so a client can't force a
    Confluence.
84. **Arts can be interrupted; Confluences can't.** Arts (except the Greatblade's Crater) are cancelled by a
    stagger, like any swing, so using one in the middle of a crowd is a risk. Confluences have hyper armour for
    their whole length because they are the payoff of a full Resonance gauge.
85. **Arts don't Siphon.** Only plain weapon blows (light, heavy, charged, riposte, thrust) refill Current.
    Otherwise an Art that hits five enemies would refill more than it cost, and the Current economy breaks.
86. **Confluence damage blends steel and Density.** Power = weapon damage x (1 - 0.5 + 0.5 x spell power from
    Density), so both pure fighters and casters get a strong finisher, and hybrids get the most.
87. **Low Pressure Siphon.** The spec's "cheaper Siphon" is read as: each weapon hit draws more Current
    (gain divided by the cost multiplier, so 0.7 means +43%). There is no Siphon cost to reduce otherwise.
88. **Overflow and Burnout, finished.** Spells cost nothing during Overflow (on top of +25% damage); Burnout stops
    passive Current regeneration completely, so a player who overflows has to fight with steel for a while.
89. **Lance charges on the server's clock.** RequestChargeCast starts the charge; release sends RequestCast and the
    server measures the hold itself (with 0.15 s latency allowance) to scale damage from 0.6x to 1.8x. Held past
    the maximum, it fires straight ahead on its own. A hit while charging cancels it. A charge can't be rolled
    out of, unlike an aimed cast.
90. **Aimed cast is optional.** Quick cast (press = cast) stays the default because it's best on touch. The
    Aimed Cast setting shows a reticle in the element's colour while the key is held and casts on release;
    rolling cancels it.
91. **Pressure zones are parts.** Any part in Workspace.PressureZones (or tagged PressureZone) with a Pressure
    attribute 1-5 sets the level inside it; the smallest zone wins where they overlap; outside them it's
    Neutral (3). A floor builder only places parts, and a Guardian can change a zone's attribute mid-fight.
    Pools and canals (tags CurrentPool / CurrentCanal) count when you stand in or beside them, measured from the
    water surface up, since a character's root part sits a few studs above it.
92. **Beacons unlock with your first Attunement.** They are shaped Current, so a player without an element has
    none. The first slot is filled with a Sentry automatically so new players see them at once; Control 20/40/60
    opens slots 2-4. All four behaviours are available from the start; the choice is which to slot.
93. **Sentry only fires while you fight.** It shoots when you have hit, or been hit by, an enemy in the last few
    seconds. Its own shots don't count, otherwise it would keep a fight going on its own forever. It aims at
    whatever you last fought, or the nearest enemy.
94. **Relay never stores Step.** Relay recasts the last spell at whoever you parry; a free Step would teleport you
    into the enemy you just parried, which is never what you want.
95. **Element colours follow the art guide.** Tide teal #3FE0D0, Rime ice white-blue #CFEFFF, Tempest electric
    violet #A274FF, Abyss deep indigo #5B4BD6, Bloom soft green-gold #C3E27A (Phase 5 used placeholder colours).
    Text in an element's colour is lifted 35% toward white so Abyss stays readable on dark panels.
96. **Phase 6 animations fall back to sword clips.** Casting, Art and Confluence clips have their own slots in
    Config.Assets.Animations (Casting, Arts, Confluences). Until those are uploaded, each move plays the sword
    clip named in its data (FallbackAnimation), retimed, so everything works without new assets.
97. **Fixes from the Phase 6 playtest.** (a) A move's first step could reach clients before MoveStart, so the
    effect used the wrong colour; moves now start deferred, after MoveStart is sent. (b) Current pools didn't
    refill anyone, because the character's root part is above the water surface; the check now reaches up 6
    studs. (c) A locked Beacon slot's text overlapped the "Slot 4" label in the Spellbook.

## Phase 7: Items and loot

98. **Phase 7 rebuilt from a first draft.** A first draft (written outside this project) added the item systems
    but gear stats never reached combat, affixes were flat stat points, and the code lived in "Phase7" modules.
    It was rebuilt on the project's conventions; its world stations, recipe and shop ideas, item text and the
    save-data branch were kept. Profiles it touched (DataVersion 2) migrate to version 3 automatically.
99. **One transaction path for every item change.** InventoryService runs the pure InventoryRules on a copy of
    the item branches and commits only if the whole operation succeeds, in one non-yielding step. Only what
    changed is replicated (single items by uid), so a pickup sends one item, not the whole bag.
100. **Gear numbers live in one shared module.** GearStats turns equipped gear into stats and bonuses; the server
    (GearService) uses it for combat and the client uses the same code for tooltips and the Character sheet, so
    what you read is what you get. Every system that reads stats now asks GearService instead of data.Stats.
101. **Rarity scales the item, not just its affixes.** Each rarity multiplies the item's base numbers
    (Common 1.0 up to Spire-Forged 1.6) and its rolled affix values, and adds affix lines (0 to 4). A drop can
    roll above an item's own rarity but never below it. Upgrades add 6% per level; broken gear gives half.
102. **Affixes change mechanics, not only stats.** Besides stat points there are weapon damage, crit, posture,
    Siphon, per-element damage, max health/stamina/Current, armour, regeneration, cast speed, parry window
    frames and slower Resonance decay. Fixed lines on an item never roll again as affixes.
103. **Six unique effects for Legendary+ gear.** Undertow, Brineward, Riptide Reflex, Deepglass, Spireheart and
    Lanternwake. Named Legendaries (Tidekeeper's Promise) carry a fixed one; other Legendary+ drops roll one that
    fits their slot. Their numbers are data (Affixes.Params).
104. **Carry weight slows, never blocks.** The spec's weight bar is real: going over it means no sprinting and a
    25% slower walk. Pickups are never refused for weight (only for a full bag), so nobody loses loot to it.
105. **Personal loot is server records, client models.** Drops exist only as records on the server; the owner's
    client draws them and asks to pick them up when close. The server checks owner, distance (+4 studs slack)
    and existence. When the bag is full, drops wait on the ground and stop asking until something leaves it.
106. **Pity is per player and per zone, and saved.** Kills since the last Rare-or-better gear drop are stored in
    ItemState.Pity by zone; the 40th kill guarantees one. Zones come from the mob spawn point's Zone attribute.
107. **Gold is loot too.** Kill gold now drops as a coin pile that flies to you (auto-pickup radius), so kill
    toasts show XP only. Everyone who helped and is nearby gets their own gold, materials and gear rolls.
108. **Beacon cores are slotted, not consumed.** Using a core moves it into the Beacon slot (recolouring your
    orbs and boosting one behaviour); slotting another returns the first to your bag. This also stops the
    "slot it then sell it" trick.
109. **Item icons are live 3D renders.** Every item has a small part-built model (ItemModels) used both for
    inventory icons (a still ViewportFrame) and for loot on the ground. Uploaded 2D icons can replace any of
    them later by setting the item's Icon.
110. **Upgrades from +7 can fail.** The item is kept at its level and the gold and materials are spent; the UI
    shows the success chance and asks for confirmation before every risky attempt. +7 and up also need Spire
    Ingots (crafted at the Forge or bought with Floor Tokens).
111. **Sales go through buy-back.** The last 12 things you sold can be bought back for what you got, so a
    misclick is never permanent. Rare+ or upgraded gear asks before selling.
112. **Salvage anywhere, upgrade at the Forge.** Salvage is in every item's context menu (and the Forge), since
    it only turns gear into materials. Upgrading and repairing need the Forge (repairs also at the Armorer).
113. **Crafting takes a moment at the station.** A 1.6 s progress ring, then the item reveals in its rarity
    colour. Nothing is spent until the ring finishes; walking away or dying cancels it.
114. **Quick items use a shared cooldown.** Z / X (gamepad Y) use the two quick slots; any quick item puts both
    on a 1.5 s cooldown so potions can't be chained instantly. Throwables land where you aim.
115. **Phase 7 leaves three economy pieces for their phases.** The Market Board and player trading come with
    Multiplayer (Phase 12), the Shard shop and cosmetics with Monetization (Phase 13), and Floor Tokens are
    earned in dungeons (Phase 9). Their data and vendors already work (the Floor 1 token vendor sells now).

## Phase 8 - Progression

116. **Positions are chosen at a Hall in Lowharbor until Floor 2 exists.** The spec puts the Position quest on
     Floor 2, which isn't built yet. A Hall of Positions in Lowharbor (a station, StationKind "Positions")
     opens the choice at level 15; Phase 11/14 turns it into the Floor 2 quest without touching the rules.
117. **One ability per branch (15 total), one on the key at a time.** The spec allows 2-3 per branch; one each
     keeps every branch's identity clear and the art/animation load sane. Learning your first ability puts it
     on the key; the Skill Tree's ability list swaps it.
118. **Every branch has the same shape.** 12 nodes: 7 minor, 3 notables, 1 ability, 1 keystone, with one fork
     and one join. Learning a node needs any node it links back to. Costs 1 / 2 / 2 / 3, so a full tree is 54
     points against 46 by level 60 (plus Guardian bonuses): a maxed Climber still chooses.
119. **Tree bonuses are gear bonuses.** Nodes use the same bonus ids as affixes, summed by GearStats, so the
     Character sheet, tooltips and every system read one table. New ids added for the tree (crit damage,
     execute, block/dodge cost, threat, spell damage/area, reactions, Overflow length, Beacon slots, healing,
     move speed, loot luck, gold find, Mark power, ability power/cooldown) each have exactly one reader.
     Block, guard, dodge, cooldown and speed bonuses are capped (Config.Progression.BonusCaps).
120. **Hidden-chest sense and revive speed wait for their systems.** Chests (Phase 9) and revives (Phase 12)
     don't exist yet; adding their Pathfinder / Beaconkeeper nodes then is data only.
121. **Respec lives in the Skill Tree, not a station.** The spec puts the respec button in the Skill Tree's
     side panel. It works anywhere out of combat: first one free, then 75 gold x level. "Change Position"
     is the same respec plus giving up the Position (choose again at the Hall).
122. **Stat points are spent with Confirm.** + and - on the Character sheet stage points; nothing is sent until
     Confirm, and spent points only come back with a respec. The archetype name (Bladecaller, Warden...)
     comes from weapon class, Attunement and where your own points went.
123. **Abilities are moves.** They use the Weapon Art move format (plus Taunt, Buff, Shield and Refill steps)
     and run through CombatService like every other blow. Power blends weapon damage and spell power by each
     ability's DensityShare, so strikers and casters both scale. Key: B, LT+RB on gamepad, SKILL on touch.
124. **Taunt is a real target lock.** Harbor Bell sets each nearby enemy's target to the caster for 6 s (if
     they stay in the enemy's leash) on top of a big threat bonus, so the tank keeps the fight after it ends.
125. **Level-ups are seen by everyone near.** The server sends the golden-teal pillar to every player within
     120 studs; only the levelling player hears the chime and sees the banner. First-time Waystone
     discoveries give 60 + 10 x level XP.
126. **Old profiles repair themselves.** On load, nodes that an update removed or disconnected are refunded,
     and the ability key is cleared if its node is gone, so retuning trees never strands a save.

## Phase 9: World (Floor 1, Lowharbor)

127. **The building kit is generated in Blender from code.** 168 pieces are built by Python scripts
     (blender/*.py) and exported as 3 FBX files. Each file carries calibration cubes, so the kit imports
     correctly whatever the 3D Importer's unit or axis settings. Pieces are split into one MeshPart per
     material channel, so they use Roblox materials (Limestone, WoodPlanks, Slate...) instead of uploaded
     textures. Collision comes from invisible box Parts; the visual meshes never collide.
128. **Lowharbor is an amphitheatre around its bay.** Five terraces step up from the water:
     - Docks (y 6), Market (30), Lower Terraces (54), Upper Terraces (78), Guild Terrace (102).
     - A crescent spanning +-0.66 rad (about 800 studs across).
     - Three stair avenues climb straight up the middle and sides; two Current canals pour down the terraces
       as waterfalls.
     - Every terrace can see the bay, the lighthouse and the First Gate. The Climb (the central avenue)
       leads from the arrival quay, through the Market plaza, to the Climbers' Guild.
129. **Terrain is procedural, buildings are kit placements.** One layout module (Layouts/Floor1) holds the
     floor's geometry functions and all of its data:
     - bands, landmarks, district specs, roads, waystones, spawns, pressure zones, secrets, scatter.
     - FloorBuilder, DistrictGenerator, LandmarkBuilder and WildBuilder read it.
     A new floor is a new layout module plus kit art, not new tools.
130. **Wild zones follow the land.** Rustwood Forest covers the northern highlands (y 120-170), Tidepool
     Marsh the southern lowland (y 0-6) with tide pools and the Brinehulk's lagoon, and the Gatewatch Downs
     sit between them, with the Cistern basin and the First Gate plateau. Region edges are noise-warped,
     so nothing outside the town is a straight line.
131. **No ceiling over the floor.** A solid ceiling would kill sunlight and shadows. The tower is shown by a
     distant ring of wall with Current veins, the dark ledge of the floor above, the drowned sea 900 studs
     below and the Current falls where the harbour spills off the edge. Invisible barriers keep players on
     the platform.
132. **Instance budget: about 52k, not 40k.** That breaks down as:
     - 158 buildings with furnished ground floors: about 35k instances.
     - Civil works: 3.9k. Landmarks: 2.7k. Scatter: 9.7k.
     Savings already made: corners stretched across storeys, collision removed from small clutter, fewer
     lots, sparser scatter. The rest comes from one MeshPart per material channel (Roblox CSG can't merge
     the kit's non-manifold meshes). StreamingEnabled with ModelStreamingMode Atomic per building keeps
     what a client holds well below the total. Merging channels into textured single-mesh pieces is
     planned for the Phase 15 performance pass.
133. **Dungeons are instanced in the same server for now.** Each group that steps through the Cistern door
     within 8 s (up to 4) gets its own copy, placed beyond the Spire wall at y -300. The spec's
     reserved-server dungeons need the party system (Phase 12); DungeonService already gathers groups,
     so moving to ReserveServer then is a transport change.
134. **The Cistern's lock is the sluice.** Two levers in the Flooded Hall raise the sluice gate. The hoard
     chest unlocks only when every enemy in your run is dead. Each member opens it once per run, and the
     first clear of the day adds a Spire Ingot.
135. **One clock for everyone, computed on each client.** The server publishes DayEpoch, and clients derive
     the time from server time. The sun moves smoothly, every client agrees, and it costs no network
     traffic. Weather (Clear 60, Overcast 25, Rain 15 by weight) is server-picked and cross-fades over 20 s.
136. **Night lights are cheap.** Lamps and windows switch a batch per frame at staggered times (up to 0.6 h
     apart), so streets light up gradually. PointLights more than 260 studs from the camera stay off. About
     a quarter of houses stay dark at night (Lit = false) so the town doesn't look like a lit grid.
137. **Ambient audio is licensed library audio.** Region beds (town, harbour, wharf, marsh, forest, downs,
     Cistern), rain, gulls, waterfalls and the dawn and dusk bell use Roblox Creator Store sounds from
     Pro Sound Effects, which are free to use in experiences. A region grid baked to
     ReplicatedStorage.FloorData picks the bed.
138. **The bestiary matches the spec's seven.** The Phase 4 placeholders were reworked rather than replaced:
     Saltworn Drifter is now the Drowned Sailor, Barnacled Hulk is the Brinehulk, Brine Acolyte is the
     Lantern Acolyte. Old ids still resolve (Mobs.Resolve). New mechanics:
     - Brinehulk: weak point on its back, x2 damage and posture within a 110-degree arc.
     - Lantern Acolyte: Kindle gives nearby engaged allies +30% damage for 8 s, shown by an amber glow.
     - Cistern Leech: its bites heal it by 60% of the damage dealt and drain 10 Current.
     - Rustwood Stalker: fades while lurking until you're within 18 studs.
     - Drowned Sailors: only walk the Old Wharf at night.
139. **Creatures ride a hidden rig.** Crabs, wisps and leeches are built from parts welded to the limbs of an
     invisible R15 rig. Pathfinding, hit boxes and the standard mob animations all keep working, and the
     walk and attack animations swing their legs, claws and motes procedurally. Custom creature meshes and
     rigs can replace the parts later without touching AI code.
140. **Secrets reward exploring.** There are 4 hidden places: a sea cave, a root hollow, a pool shrine and a
     cliff grotto. Each is carved into the terrain, gives discovery XP (120 + 10 x level) the first time
     you stand in it, and holds a cache that opens once per player.
141. **Lowharbor is dark fantasy, and drowned.** The floor sits at the bottom of a flooded tower, so light
     arrives as if filtered through sea water. The look comes from data (Config.Environment):
     - Desaturated teal-grey days, a violet dusk and near-abyss nights. Night OutdoorAmbient is kept
       high enough to stay readable on phones.
     - A denser teal atmosphere, faint light shafts, and dark wet terrain and building palettes. The
       Current's teal glow is the brightest colour in the world.
     - Marine snow around the camera, and about 10 glowing drifters in the wilds. Both are client-only,
       cost one emitter plus about 10 parts, and scale with graphics quality.
     - Kelp, anemones, barnacles and half-buried leviathan skeletons in the harbour, marsh and wilds.
     Terrain colours are applied by EnvironmentService at server start, so a terrain rebuild never
     loses them.
142. **Canal water follows the voxel grid.** Terrain water only fills voxels that hold no solid. Each
     band's canal water line sits on a 4-stud voxel boundary, so the canal bed is 5 studs below it, not
     3; otherwise the channel holds no water at all. A faint Neon seam on the bed and rising motes show
     the Current in the canals.
143. **Storeys have no seams.** Wall panels are 12 tall but storeys are 13 apart, so every storey except
     the top has its panels stretched by 13/12 to meet the next floor.
144. **Trees are giants.** Rustwood, Marshroot and Spirepine stand 50 to 110 studs tall, with twisted
     trunks, buttress roots, heavy sagging crowns and hanging moss. Every part touches the trunk, so
     nothing floats. They are scattered wide apart (spacing 30 to 40) with understory between them:
     fewer, larger silhouettes read as more ominous and cost fewer parts.
145. **Every station has a building.** The Market plaza is ringed by 8 workshops, one per station kind
     (Layout.Workshops):
     - The Ember Anvil (Forge), Brinewall Armoury, The Tidewoven Loom, Murkglass Apothecary
     - Lowharbor Provisions (Shop), The Drowned Vault (Bank), The Floorwarden's Exchange (TokenShop),
       The Votive Hollow (Altar)
     Each has a lit signboard, themed dressing and its station in front of the door. The slots avoid the
     Climb and the ring street, and stay inside the Market terrace. Stations keep their ids: SeatFixtures
     only moves them onto each building's StationSpot, matched by StationKind. A new floor's market is
     just a new Workshops table.
146. **The Rotunda of Attunement.** The Shrine stands in a twelve-bayed domed drum on the Guild Terrace,
     about 75 studs to the crown. It has a portal facing the bay, a ring pool of Current water, a dais and
     light falling from the oculus. It is the floor's second-largest landmark after the Cathedral, because
     choosing an Attunement is the biggest decision a player makes on Floor 1.

## Phase 9 polish - courtyards and canal life

147. **Courtyards fill the block interiors.** The land behind and between the houses was bare terrain. The
     edit-time tool `Tools.Floor1Courtyards` now puts a small scene there, built from SpireKit
     templates and chosen by district:
     - Docks: net yards, boats hauled up on logs, crate yards
     - Market: stall stores, traders' tables
     - Terraces: drowned gardens, kitchen yards, Climber shrines, crystal grottos
     - Guild Terrace: formal courts, reading nooks
     How a spot qualifies:
     - Its whole footprint is lot ground at the band height.
     - It keeps 3 studs clear of every part already in Workspace (oriented-box test, so paving strips
       and collision boxes count).
     - It is 30 studs from the next scene.
     - Its open side faces the ring street.
     Each scene keeps at most one PointLight; the other candles and glows stay emissive only. Each scene
     is an Atomic model. Everything lives in `Workspace.Floor1.Courtyards`, so Undo deletes that folder
     and touches nothing else. The pass is seeded with its own generator, so Studio and offline builds
     agree. `Resnap()` re-seats the scenes on the voxels after a terrain edit.
148. **Fish in the canals.** `CanalFishController` (client) puts a school of small dark tidefish with
     glowing teal tails in each canal leg. Each leg is found by its CurrentSeam part, so fish follow
     streaming in and out.
     - They swim a slow figure-eight between the bed and the surface, so they turn smoothly at the
       waterfalls.
     - Only legs within 200 studs of the camera are animated, with one BulkMoveTo per frame.
     - School size scales with graphics quality (2 to 8 fish; none on the lowest settings). That is
       at most about 160 local parts, and usually 2 or 3 legs are near.

## Phase 10 - Guardian: the Brinewarden

The design and its Roblox references are in docs/PHASE10_GUARDIAN.md.

149. **Guardian arenas are private copies, like dungeons.** Each party that challenges the First Gate
     gets its own clone of `ServerStorage.GuardianArenas.Brinewarden`. Clones sit at
     Config.Mobs.Guardian.ArenaOrigin, on the opposite side of the floor from the dungeons. The spec asks
     for reserved servers; as with #133, that is a transport change for Phase 12. One busy server
     never makes a party wait, and nobody can interfere with another party's fight.
150. **Challenging is a gathering.** The gate prompt starts a 10 s window. Anyone else who uses the gate
     in that window joins, up to 8. Players below the Guardian's level get a warning but are not
     refused: the spec's level 12 is advice. Re-fights are allowed. First-clear rewards (unlock, shards,
     skill points) are paid once per player; loot and XP are paid every clear.
151. **Health scales with the party; damage does not.** Health uses the spec formula,
     BaseHealth x (1 + 0.75 x (players - 1)), with players counted at the start. Adds, lances and
     whirlpools also scale with the party. Blow damage never changes, so a dodge learned solo works in
     a group of 8. BaseHealth 7500 gives a fight of about 3.5 min solo and about 3 min for 4 or 8
     players (tools/place/sim_guardian.luau).
152. **Health gates instead of phase skips.** Health clamps at each phase threshold (60%, 25%) until the
     3 s transition has played. The Warden is immune during the transition, and its running move is
     cancelled (a held player is released). Burst damage cannot skip a phase or its arena change.
153. **The Warden is unflinching.** Ordinary hits never stagger it, and stuns and parries don't
     interrupt it. Only a posture break does: it kneels for 4 s, and the first blow is a Finisher.
     Parries still add their heavy posture damage, so parrying is the fastest route to a break.
     Weak-point blows deal x1.5 damage and x2 posture: the back seam in phases 1-2, the front core in
     phase 3.
154. **The tide is the Pressure shift.** From phase 2 the arena alternates:
     - High tide for 14 s: Pressure 5, spells strongest.
     - Ebb for 7 s: Pressure 1, and the drying shell takes x1.5 posture.
     A 1.5 s tell (wall runes, sound, a "The tide turns..." line) comes before each turn. Tide Surge
     forces an early turn. Players read the water to choose casting or swinging.
155. **The grab punishes turtling, and allies can break it.** Claw Grab is weighted x3 against a target
     who blocked in the last 1.5 s. It is unparryable and unblockable but dodgeable. A held player takes
     three crushes and is thrown. Allies free them early by dealing 120 posture to the Warden. The victim
     is released on every exit: phase change, posture break, death, leaving, wipe or victory.
156. **Everything is telegraphed, and red means "don't parry".** No wind-up is shorter than 0.4 s, even
     in phase 3, where telegraphs are x0.85. Every area attack draws a red ground shape that fills
     before it fires: circle, ring, line, cone or the travelling tidal-wave ring. Unparryable blows
     flash an ember glint and play a distinct sound. The tidal wave can only be avoided by dodging
     through it, using i-frames timed to the ring.
157. **Big bodies have hit sizes.** Targets can carry a hit radius and height. Melee, spells,
     projectiles and arts measure to the target's capsule, not to its root. A 20-stud Warden is hit
     where it visibly stands, and its blows reach players below its root. Targets with no size behave
     exactly as before.
158. **Rewards need a small contribution.** A member must deal 2% of the Warden's health or stay alive
     in the arena for 45 s. The bar is low on purpose: healers, tanks and newer Climbers still earn the
     clear. Arcane Odyssey's 20% damage gate punishes support play.
159. **Announcements.** The first clear of a floor on a server sends everyone a banner, "Floor 1 has
     been cleared by {names}". A MessagingService message (pcall-guarded, at most one per 30 s) shows
     other servers an "Across the Spire" toast. Personal unlock cards show only to the party.
160. **Boss UI.**
     - The boss bar sits at the bottom of the screen (spec). On touch devices it moves to the top so
       the action buttons never cover it.
     - The intro is skippable after the first view (`Floors.IntrosSeen`, profile v5). The Warden stays
       dormant until the intro has ended for everyone, so skipping gives no head start.
     - Roblox has no global time scale. The victory slow motion slows the Warden's animations,
       desaturates the screen and moves the camera in, on each client.
161. **Music needs licensed tracks.** MusicController crossfades layers over 2 s: one per phase, plus a
     victory sting. Track ids live in Config.Environment.Music. Ids are left empty rather than guessed,
     and an empty layer is silent. The place owner picks licensed tracks from the Creator Store.
162. **No Floor 2 yet.** A first clear sets `Floors.Unlocked["2"]` and shows the unlock card. After each victory a
     toast says the stair to Amberveil "will rise soon". Floor 2 and its teleport arrive in Phase 14.
]==]
