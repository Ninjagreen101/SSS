--!strict
--[[
	Net Definitions
	Every remote in the game, by name. Client -> server remotes carry intent
	only and list an argument validator per parameter; the server rejects
	any call that fails, has extra arguments, or exceeds its rate limit.
	Server -> client remotes broadcast results for clients to render.
]]

local Schema = require(script.Parent.Parent.Util.Schema)

export type RemoteKind = "Event" | "Unreliable" | "Function"
export type Direction = "ToServer" | "ToClient"

export type RemoteDef = {
	Kind: RemoteKind,
	Direction: Direction,
	Args: { Schema.Validator }, -- ToServer only; ToClient payloads are trusted (server-made)
}

local S = Schema

local function toServer(args: { Schema.Validator }, kind: RemoteKind?): RemoteDef
	return { Kind = kind or "Event", Direction = "ToServer", Args = args }
end

local function toClient(kind: RemoteKind?): RemoteDef
	return { Kind = kind or "Event", Direction = "ToClient", Args = {} }
end

local Definitions: { [string]: RemoteDef } = {
	-- Client -> server (intent)
	ClientReady = toServer({}),
	RequestSaveSetting = toServer({ S.Id(32), S.Any() }), -- value validated per key by DataService
	RequestAttack = toServer({ S.Integer(1, 6), S.UnitVector3() }), -- comboIndex, aimDirection
	RequestHeavyAttack = toServer({ S.Number(0, 5), S.UnitVector3() }), -- chargeSeconds, aimDirection
	RequestCast = toServer({ S.Id(48), S.Vector3(1e5) }), -- spellId, targetPosition
	RequestDodge = toServer({ S.UnitVector3() }), -- direction
	RequestBlock = toServer({ S.Boolean(), S.Boolean() }), -- isBlocking, fromTouch (touch gets a slightly wider parry window)
	RequestSprint = toServer({ S.Boolean() }), -- isSprinting
	RequestInteract = toServer({ S.Id(64) }), -- targetId
	RequestRespawn = toServer({}), -- dead player asks to rise at their Waystone
	RequestAttune = toServer({ S.OneOf({ "Tide", "Rime", "Tempest", "Abyss", "Bloom" }) }), -- at the Attunement Shrine
	RequestEquipSpell = toServer({ S.Integer(1, 4), S.Id(32) }), -- hotbar slot, spell id
	RequestChargeCast = toServer({ S.Id(48) }), -- start charging a spell that charges (Lance); RequestCast releases it
	RequestWeaponArt = toServer({ S.UnitVector3() }), -- aim; the server picks Weapon Art or Confluence (max Resonance)
	RequestInfuse = toServer({}), -- held the Weapon Art button: Infuse the blade
	RequestSetBeacon = toServer({ S.Integer(1, 4), S.OneOf({ "", "Sentry", "Aegis", "Lantern", "Relay" }) }), -- slot, behaviour

	-- Items (Phase 7). Uids are item instance ids; the server re-checks everything.
	RequestItemAction = toServer({
		S.OneOf({ "Equip", "Unequip", "Use", "Lock", "Seen", "Split", "Salvage", "QuickSlot", "Track", "SlotCore", "UnslotCore" }),
		S.String(0, 32), -- uid ("" for actions that don't need one)
		S.String(0, 48), -- argument: equipment slot, recipe id or quick slot number
		S.Integer(0, 999), -- count (Split)
	}),
	RequestQuickItem = toServer({ S.Integer(1, 2), S.Vector3(1e5) }), -- quick slot, aim point (throwables)
	RequestStation = toServer({
		S.Id(64), -- station id (attribute StationId on the station)
		S.OneOf({ "Craft", "Upgrade", "Repair", "RepairAll", "Salvage", "Buy", "Sell", "Buyback", "Deposit", "Withdraw" }),
		S.String(0, 48), -- recipe id, item id (Buy), uid or buy-back id
		S.Integer(1, 99), -- count (Buy, Sell, Craft)
	}),
	RequestPickup = toServer({ S.Id(32) }), -- personal drop id

	-- Progression (Phase 8). The server re-checks every rule (ProgressionRules).
	RequestAllocateStats = toServer({
		S.MapOf(S.OneOf({ "Vitality", "Endurance", "Strength", "Finesse", "Draw", "Density", "Control" }), S.Integer(1, 200), 7),
	}), -- { stat = points to add }
	RequestChoosePosition = toServer({ S.OneOf({ "Vanguard", "Lancer", "Tidecaller", "Beaconkeeper", "Pathfinder" }), S.Id(64) }), -- position, Hall station id
	RequestUnlockNode = toServer({ S.String(1, 48) }), -- skill tree node id ("Vanguard.Bulwark.3"; unknown ids are refused)
	RequestEquipAbility = toServer({ S.String(0, 32) }), -- ability id ("" clears the key)
	RequestRespec = toServer({ S.Boolean() }), -- also give up the Position
	RequestAbility = toServer({ S.UnitVector3() }), -- cast the equipped Position ability along this aim

	-- Quests and onboarding (Phase 11, docs/PHASE11_QUESTS.md). The server checks NPC distance and every rule.
	RequestQuestAction = toServer({
		S.OneOf({ "Accept", "TurnIn", "Abandon", "Track", "Reroll" }),
		S.String(0, 48), -- quest id ("" for Track = untrack)
		S.String(0, 32), -- npc id ("" when no NPC is involved)
	}),
	RequestTalk = toServer({ S.Id(32) }), -- npc id: the player opened that NPC's dialogue
	RequestSetTitle = toServer({ S.String(0, 48) }), -- achievement id whose title to show ("" = none)
	RequestMapPin = toServer({ S.OneOf({ "Add", "Remove" }), S.Number(-5000, 5000), S.Number(-5000, 5000), S.String(0, 16) }), -- action, x, z, icon
	RequestTutorial = toServer({ S.OneOf({ "Skip", "Continue" }) }),
	RequestWaystoneTravel = toServer({ S.Id(48) }), -- target waystone id: travel from the waystone you stand at (map)

	-- Server -> client (results)
	DataSnapshot = toClient(), -- full replica of the player's own saved data
	DataChanged = toClient(), -- { Path, Value } list
	Notify = toClient(), -- toast: (stringKey, args, style)
	DamageDealt = toClient(), -- (targetModel, amount, kind, crit, position, attackerModel, reactionName?, element?)
	StatusApplied = toClient(),
	MobStateChanged = toClient(),
	LootDropped = toClient(), -- ({ drops }) personal drops for this player only
	LootRemoved = toClient(), -- (dropId, collected) picked up or expired
	ItemResult = toClient(), -- (ok, reason, payload) outcome of an item / station request, for toasts and reveals
	CraftState = toClient(), -- ("Start", recipeId, endsAt) | ("End", recipeId, 0)
	ResonanceTriggered = toClient(), -- (stacks) a Resonance stack was just gained (gauge pulse)
	CurrentVisual = toClient("Unreliable"), -- cosmetic, high-frequency bar smoothing hints
	SwingVisual = toClient("Unreliable"), -- (attackerModel, kind, aimDirection, reach, arc, windup) for other players' slash effects
	ActionRejected = toClient(), -- (action, reason) the server refused a combat action the client predicted
	Projectile = toClient(), -- ("Spawn", id, origin, velocity, radius, range, color) | ("End", id, position)
	SpellVisual = toClient(), -- (casterModel, spellId, kind, data) one-off spell effects for nearby players
	AttunementOffer = toClient(), -- (slot "Primary" | "Secondary", primaryName) open the Shrine picker
	MoveStart = toClient(), -- (casterModel, kind "Art" | "Confluence" | "Ability", key, aim, element) a move began
	MoveStep = toClient(), -- (casterModel, key, stepIndex, data) one step of a move happened (positions for effects)
	ProgressionResult = toClient(), -- (ok, action, reason, payload) outcome of a progression request, for toasts
	LevelUp = toClient(), -- (characterModel, level) someone nearby levelled up: draw the pillar of light
	SurgeBoom = toClient(), -- (characterModel) a nearby runner broke into a Surge: draw the sonic wind boom
	SpellCooldowns = toClient(), -- ({ [spellId]: serverTimeReady }) cooldowns changed on the server (Arcblade hits, Relay)

	-- Quests and onboarding (Phase 11). Quest state itself replicates through DataController.
	QuestEvent = toClient(), -- (kind "Accepted"|"Progress"|"Ready"|"Completed"|"Abandoned"|"Rolled", questId, payload)
	AchievementUnlocked = toClient(), -- (achievementId)
	TutorialStep = toClient(), -- (step, payload)

	-- Guardians (Phase 10). Payloads per kind: docs/PHASE10_GUARDIAN.md section 3.
	GuardianEvent = toClient(), -- (kind "Gather"|"Intro"|"Phase"|"Tide"|"Victory"|"Wipe"|"Banner", payload)
	-- Ground telegraph for any enemy: (shape "Circle"|"Ring"|"Line"|"Cone", cframe, sizeA, sizeB,
	-- duration, flags) - flags bit 1 = unparryable (red), bit 2 = cframe is relative to the attacker's root
	Telegraph = toClient(),
}

return table.freeze(Definitions)
