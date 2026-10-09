--!strict
--[[
	Attributes
	Names of every replicated attribute the server sets for clients to read.
	Using these constants (not string literals) means a typo is a type error,
	not a silent bug.

	Player attributes (server-written, replicated to everyone):
		Stamina, MaxStamina, Current, MaxCurrent  -- vitals (Health lives on the Humanoid)
		Saturation (0..100), Resonance (0..5)     -- filled by Phases 5 and 6
		Sprinting, Winded, SprintLocked           -- movement state
		LastCombat                                -- server time of the last hit taken/dealt
		RespawnAt                                 -- server time the Respawn button unlocks
		Level                                     -- shown on HUD badges and nameplates
		Attunement                                -- primary Attunement ("" until chosen), for spell colours
		Shield                                    -- Ward shield left (absorbs damage first)
		Overflow, Burnout                         -- server time each state ends (0 = not active)
		Pressure                                  -- Current Pressure where the player stands (1..5)
		Infusion, InfusedUntil                    -- Infused element and the server time it ends
		ArtReadyAt, ConfluenceReadyAt             -- server time the Weapon Art / Confluence is off cooldown
		Beacons                                   -- slotted Beacon behaviours, comma separated ("Sentry,Aegis")
		AegisReadyAt                              -- server time the Aegis Beacon re-forms (0 = ready)
		RelaySpell                                -- spell id the Relay Beacon holds ("" = empty)
		Overburdened                              -- bag over carry weight: no sprint, slower walk
		BeaconCore                                -- slotted Beacon core item id ("" = none): orb colour
		Buffs                                     -- active food buffs, "MarshStew:endTime,..." (server time)
		QuickItemReadyAt                          -- server time quick items can be used again
		SpeedBonus                                -- movement speed bonus (0.1 = +10%) from the tree and buffs
		AbilityReadyAt                            -- server time the Position ability is off cooldown

	Combat target attributes (on the target's Model: player characters,
	dummies, enemies):
		Team                                      -- "Players" | "Enemies"
		CombatState                               -- Idle | Attacking | Heavy | Dodging | Blocking | Staggered | Broken
		Posture, MaxPosture                       -- balance meter (full = Broken)
		NameKey                                   -- Strings path for the target's display name
		WeaponId, WeaponClass                     -- on player characters: equipped weapon
		Status<Name>                              -- server time a status ends, e.g. StatusSoaked
		ChillStacks                               -- Rime stacks (Frozen at ChilledStacksToFreeze)

	Mob attributes (on enemy Models, server-written):
		MobId                                     -- key into Shared.Data.Mobs
		MobState                                  -- Enums.MobState (Idle, Chase, Attack, ...)
		Elite                                     -- true for elite variants
		MobBlow                                   -- "slot;windup;serverTime;telegraph" each blow, for client animation

	Instance attributes (set in the world):
		WaystoneId, DefaultWaystone               -- on Waystone models
		DummyType                                 -- "Training" | "Sparring" on practice dummies
		MobId, SpawnCount, Elite,                 -- on mob spawn points (Parts in Workspace.MobSpawns)
		RespawnTime, PatrolRadius
		Pressure                                  -- on Pressure zone parts (Workspace.PressureZones), 1..5
		RevealTransparency                        -- on LanternReveal parts: how visible a Lantern makes them
		Zone                                      -- on mob spawn points: loot zone (Config/Loot Zones)
		StationId, StationKind, ShopId            -- on crafting stations / shops / the bank (tag ItemStation)
]]

local Attributes = {
	Stamina = "Stamina",
	MaxStamina = "MaxStamina",
	Current = "Current",
	MaxCurrent = "MaxCurrent",
	Saturation = "Saturation",
	Resonance = "Resonance",
	Sprinting = "Sprinting",
	Winded = "Winded",
	SprintLocked = "SprintLocked",
	LastCombat = "LastCombat",
	RespawnAt = "RespawnAt",
	Level = "Level",
	Attunement = "Attunement",
	Shield = "Shield",
	Overflow = "Overflow",
	Burnout = "Burnout",
	Pressure = "Pressure",
	Infusion = "Infusion",
	InfusedUntil = "InfusedUntil",
	ArtReadyAt = "ArtReadyAt",
	ConfluenceReadyAt = "ConfluenceReadyAt",
	Beacons = "Beacons",
	AegisReadyAt = "AegisReadyAt",
	RelaySpell = "RelaySpell",
	Overburdened = "Overburdened",
	BeaconCore = "BeaconCore",
	Buffs = "Buffs",
	QuickItemReadyAt = "QuickItemReadyAt",
	SpeedBonus = "SpeedBonus",
	AbilityReadyAt = "AbilityReadyAt",
	ChillStacks = "ChillStacks",

	Team = "Team",
	CombatState = "CombatState",
	Posture = "Posture",
	MaxPosture = "MaxPosture",
	NameKey = "NameKey",
	WeaponId = "WeaponId",
	WeaponClass = "WeaponClass",

	MobId = "MobId",
	MobState = "MobState",
	Elite = "Elite",
	MobBlow = "MobBlow",

	WaystoneId = "WaystoneId",
	DefaultWaystone = "DefaultWaystone",
	DummyType = "DummyType",
	SpawnCount = "SpawnCount",
	RespawnTime = "RespawnTime",
	PatrolRadius = "PatrolRadius",
	Zone = "Zone",
	StationId = "StationId",
	StationKind = "StationKind",
	ShopId = "ShopId",
}

-- CollectionService tags.
local Tags = {
	Waystone = "Waystone",
	WaystoneCrystal = "WaystoneCrystal",
	CombatTarget = "CombatTarget", -- anything that can be hit and locked on to
	TrainingDummy = "TrainingDummy",
	Mob = "Mob", -- every live enemy model
	AttunementShrine = "AttunementShrine",
	PressureZone = "PressureZone", -- a part whose volume sets Current Pressure (attribute Pressure)
	CurrentPool = "CurrentPool", -- standing inside refills Current quickly
	CurrentCanal = "CurrentCanal", -- standing near refills Current
	LanternReveal = "LanternReveal", -- hidden until a Lantern Beacon comes close
	ItemStation = "ItemStation", -- Forge, Armorer, Alchemy, Loom, Altar, Shop, TokenShop, Bank
}

-- Status attribute name for a status, e.g. "StatusSoaked".
local function statusAttribute(status: string): string
	return "Status" .. status
end

return table.freeze({
	Names = table.freeze(Attributes),
	Tags = table.freeze(Tags),
	Status = statusAttribute,
})
