# Phase 12: Multiplayer

Spec sources:
- Section 14, "Servers and floors" and "Parties and social"
- Section 12, party frames (bottom-left), the Party menu (P) and party members on the minimap
- Section 16, item 12: "parties, party finder, reserved dungeon servers, trading, Companies, emotes, inspect"

## 1. Features

| Feature | Spec | Our take |
|---|---|---|
| Parties | Up to 6 (8 for Guardians via a raid group), shared XP, party frames, ping markers (G or tap), party chat channel | **PartyService**: invites by name or from a nearby list (30 s), leader controls (kick, promote, disband, convert to raid, loot mode). Kill XP is shared with members within 150 studs, +10% per other member. Party frames sit bottom-left with health and Current. Pings show for party members for 8 s. A TextChatService channel exists per party. |
| Party Finder | A board in each town and in the Party menu | **Finder**: per-server listings by activity (Questing, the Cistern, the Brinewarden, Farming) with a filtered note. Listings join on request. A board prop by the Guild steps opens it. |
| Reserved servers | Dungeons and Guardian arenas are ReserveServer servers for the party | **InstanceService**: when published (`game.PlaceId ~= 0`), a party entering the Cistern or challenging the Gate teleports to a reserved server of the **same place**. The server reads the teleport data (`Mode` "Dungeon" or "Guardian", `Id`, party UserIds) and runs only that run, then teleports everyone back to the floor. In Studio, or if a teleport fails, today's in-server copies run instead. |
| Trading | Request, both place items and gold, both lock, 3 s countdown, both confirm; rarity colours and full tooltips | **TradeService**: in town, within 20 studs. Items and gold are validated item by item against both live profiles at final confirm. Both profiles are trade-locked (`DataService.LockForTrade`), swapped atomically, then saved. Any change unlocks both sides. |
| Climber Companies | Level 20: name, emblem from preset icons, member list, ranks, shared storage chest, weekly Company quests | **CompanyService**: records in their own DataStore (`UpdateAsync`), MessagingService for live updates across servers, and a short in-server cache. Ranks: Leader, Officer, Member, Recruit. Storage holds 40 slots, deposit/withdraw by rank. Two weekly Company quests are fed by members' GameEvents. |
| Emotes | A wheel with 8 slots | **EmoteController**: hold B (or a touch button) for the wheel. Emotes are the default Roblox character animations plus original ones from Assets.Animations, played on your own character (replicated by Roblox). Slots are saved in `Social.Emotes`. |
| Inspect | Inspect other players' gear by clicking them | **InspectController**: click or tap a player to request `RequestInspect`. The server sends their equipped gear, level, Position and title. It's shown with the existing item tooltips. |

Our own decision: the **Market Board** (auction house, Section 11) is **not** in Phase 12, because the build order lists it under economy.

## 2. Contracts

All of these are already written:
- **Net:**
  - to server: `RequestParty`, `RequestPing`, `RequestFinder`, `RequestTrade`, `RequestCompany`, `RequestSetEmoteSlot`, `RequestInspect`
  - to client: `PartyState`, `PartyInvite`, `Ping`, `FinderListings`, `TradeState`, `TradeRequest`, `CompanyState`, `CompanyInvite`, `InspectResult`
  - argument shapes are in `Shared/Net/Definitions.lua`; rates in `Config.Net`
- **Config:** `Config.Social` (Party, Finder, Instances, Trade, Company, Emotes, Inspect)
- **Profile v7:** `Social = { CompanyId, Emotes, LootMode, Blocked }`
- **Player attributes:** `PartyId`, `CompanyName`, `CompanyEmblem`, `Emote`

Text lives in Strings sections `Party`, `Finder`, `Trade`, `Company`, `Emotes` and `Inspect`. Each builder adds its own section with targeted edits only.

Server APIs other systems use:
- `PartyService.GetParty(player): { Player }?`
- `PartyService.MembersNear(player, radius): { Player }`
- `PartyService.IsRaid(player): boolean`
- `PartyService.Changed` (Signal)

**Integration points:**
- ProgressionService kill XP sharing uses `PartyService.MembersNear` with `ShareRadius` and `XPBonusPerMember`.
- DungeonService and GuardianService gatherings include the challenger's party members who are near the door or gate. They hand the run to `InstanceService.Start(mode, id, players)`. That call returns `false` when a reserved server can't be used, and the existing in-server path then runs.
- In a reserved instance server, DungeonService and GuardianService start their run directly for the arriving party (`InstanceService.GetMode()`).

## 3. Build split

| Work | Agent | Files |
|---|---|---|
| Parties, raids, pings, finder, party chat, shared XP | builder (Opus) | `PartyService`, `PartyController` (Party menu P, frames, invites, finder, pings, minimap dots via MapController), ProgressionService XP sharing |
| Reserved servers | builder (Opus, xhigh: teleports and saves) | `InstanceService`; DungeonService and GuardianService handoff and instance mode; FloorService return to the floor |
| Trading | builder (Opus, xhigh: duplication risk) | `TradeService`, `TradeController` |
| Companies | builder (Opus, xhigh: shared persistent state) | `CompanyService`, `CompanyController` (Company tab), the nameplate Company line |
| Emotes and inspect | builder (Sonnet) | `EmoteController`, `InspectController`, `InspectService` (or inside an existing service), `RequestSetEmoteSlot` handling |

## 4. Acceptance

- Type check clean (except ProfileStore); `rojo build` succeeds.
- Lune tests, each against a pure module:
  - trade state machine: lock, change, unlock, countdown, confirm; duplication and race cases
  - party rules: size caps, raid conversion, leader handoff on leave, invite expiry
  - XP-share math
  - Company rank permissions and storage rules
  - instance teleport-data parsing and its fallback decision
- A reviewer pass, focused on duplication, teleport data trust, DataStore races and leaks.
- Not possible here: a real 2-player test and real reserved-server teleports. Both need the published experience.
