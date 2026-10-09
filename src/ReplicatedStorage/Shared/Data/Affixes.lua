--!strict
--[[
	Affixes
	The bonus lines gear rolls (Spec Section 11) and the unique named effects
	Legendary-and-above gear carries.

	An affix is a number with a meaning. GearStats sums every equipped
	affix into one bonus table per player, and the systems that care read
	it (VitalsService for health, CombatService for damage and the parry
	window, CurrentService for Siphon and Resonance, SpellService for
	element damage and cast speed...). Adding an affix that changes an
	existing number is one entry here plus its string; a brand-new
	mechanic also needs the system that reads it.

	Kinds (how Value is stored and shown):
	  Percent  0.06 = "+6%"
	  Flat     8 = "+8"
	  Points   2 = "+2 Strength" (added to the stat before soft caps)
	  Frames   1 = "+1 frame" (1/60 s)
	  Seconds  0.5 = "+0.5 s"

	Groups say which gear can roll it: Weapon, Armor, Accessory.
	Min/Max are at AffixPower 1 (Common); Config.Items.Rarities scales them.
]]

local Enums = require(script.Parent.Parent.Enums)

export type AffixKind = "Percent" | "Flat" | "Points" | "Frames" | "Seconds"
export type AffixGroup = "Weapon" | "Armor" | "Accessory"

export type AffixDef = {
	Id: string,
	Kind: AffixKind,
	Min: number,
	Max: number,
	Groups: { AffixGroup },
	Weight: number,
	Stat: Enums.Stat?, -- Points affixes: which stat they raise
}

export type UniqueDef = {
	Id: string,
	Groups: { AffixGroup },
	Params: { [string]: number },
}

local ALL: { AffixGroup } = { "Weapon", "Armor", "Accessory" }
local NONE: { AffixGroup } = {} -- bonus ids that never roll on gear

local list: { AffixDef } = {
	-- Weapon offence
	{ Id = "WeaponDamage", Kind = "Percent", Min = 0.04, Max = 0.08, Groups = { "Weapon" }, Weight = 12 },
	{ Id = "CritChance", Kind = "Percent", Min = 0.02, Max = 0.05, Groups = { "Weapon", "Accessory" }, Weight = 10 },
	{ Id = "PostureDamage", Kind = "Percent", Min = 0.05, Max = 0.1, Groups = { "Weapon" }, Weight = 9 },
	{ Id = "Siphon", Kind = "Percent", Min = 0.08, Max = 0.15, Groups = { "Weapon", "Accessory" }, Weight = 9 },

	-- Element damage: spells, Weapon Arts and Confluences of that Attunement.
	{ Id = "TideDamage", Kind = "Percent", Min = 0.04, Max = 0.08, Groups = { "Weapon", "Accessory" }, Weight = 6 },
	{ Id = "RimeDamage", Kind = "Percent", Min = 0.04, Max = 0.08, Groups = { "Weapon", "Accessory" }, Weight = 6 },
	{ Id = "TempestDamage", Kind = "Percent", Min = 0.04, Max = 0.08, Groups = { "Weapon", "Accessory" }, Weight = 6 },
	{ Id = "AbyssDamage", Kind = "Percent", Min = 0.04, Max = 0.08, Groups = { "Weapon", "Accessory" }, Weight = 6 },
	{ Id = "BloomDamage", Kind = "Percent", Min = 0.04, Max = 0.08, Groups = { "Weapon", "Accessory" }, Weight = 6 },

	-- Defence and tempo
	{ Id = "MaxHealth", Kind = "Flat", Min = 8, Max = 18, Groups = { "Armor", "Accessory" }, Weight = 12 },
	{ Id = "Armor", Kind = "Percent", Min = 0.01, Max = 0.03, Groups = { "Armor" }, Weight = 10 },
	{ Id = "MaxStamina", Kind = "Flat", Min = 6, Max = 14, Groups = { "Armor" }, Weight = 9 },
	{ Id = "StaminaRegen", Kind = "Percent", Min = 0.05, Max = 0.12, Groups = { "Armor", "Accessory" }, Weight = 8 },
	{ Id = "ParryWindow", Kind = "Frames", Min = 1, Max = 1.6, Groups = { "Armor", "Weapon" }, Weight = 5 },
	{ Id = "ResonanceDecay", Kind = "Seconds", Min = 0.5, Max = 1, Groups = { "Armor", "Accessory" }, Weight = 5 },

	-- The Current
	{ Id = "MaxCurrent", Kind = "Flat", Min = 8, Max = 16, Groups = { "Accessory", "Armor" }, Weight = 9 },
	{ Id = "CurrentRegen", Kind = "Percent", Min = 0.06, Max = 0.14, Groups = { "Accessory", "Armor" }, Weight = 8 },
	{ Id = "CastSpeed", Kind = "Percent", Min = 0.03, Max = 0.07, Groups = { "Accessory" }, Weight = 7 },

	-- Stat points
	{ Id = "Vitality", Kind = "Points", Min = 1, Max = 3, Groups = ALL, Weight = 7, Stat = "Vitality" },
	{ Id = "Endurance", Kind = "Points", Min = 1, Max = 3, Groups = ALL, Weight = 7, Stat = "Endurance" },
	{ Id = "Strength", Kind = "Points", Min = 1, Max = 3, Groups = ALL, Weight = 7, Stat = "Strength" },
	{ Id = "Finesse", Kind = "Points", Min = 1, Max = 3, Groups = ALL, Weight = 7, Stat = "Finesse" },
	{ Id = "Draw", Kind = "Points", Min = 1, Max = 3, Groups = ALL, Weight = 7, Stat = "Draw" },
	{ Id = "Density", Kind = "Points", Min = 1, Max = 3, Groups = ALL, Weight = 7, Stat = "Density" },
	{ Id = "Control", Kind = "Points", Min = 1, Max = 3, Groups = ALL, Weight = 7, Stat = "Control" },

	-- Beacon core bonuses (cores and the Beaconkeeper tree; never rolled on gear).
	{ Id = "SentryDamage", Kind = "Percent", Min = 0, Max = 0, Groups = NONE, Weight = 0 },
	{ Id = "AegisRecharge", Kind = "Percent", Min = 0, Max = 0, Groups = NONE, Weight = 0 },
	{ Id = "RelayCooldown", Kind = "Percent", Min = 0, Max = 0, Groups = NONE, Weight = 0 },

	-- Position tree bonuses (Shared/Data/Positions; never rolled on gear).
	-- Each has exactly one system that reads it:
	{ Id = "CritDamage", Kind = "Percent", Min = 0, Max = 0, Groups = NONE, Weight = 0 }, -- CombatService: crit multiplier
	{ Id = "ExecuteDamage", Kind = "Percent", Min = 0, Max = 0, Groups = NONE, Weight = 0 }, -- CombatService: foes under Progression.ExecuteThreshold
	{ Id = "RiposteDamage", Kind = "Percent", Min = 0, Max = 0, Groups = NONE, Weight = 0 }, -- CombatService: ripostes and finishers
	{ Id = "BlockCost", Kind = "Percent", Min = 0, Max = 0, Groups = NONE, Weight = 0 }, -- CombatService: stamina for blocked damage
	{ Id = "GuardPosture", Kind = "Percent", Min = 0, Max = 0, Groups = NONE, Weight = 0 }, -- CombatService: posture lost blocking
	{ Id = "DodgeCost", Kind = "Percent", Min = 0, Max = 0, Groups = NONE, Weight = 0 }, -- CombatService: dodge stamina
	{ Id = "Threat", Kind = "Percent", Min = 0, Max = 0, Groups = NONE, Weight = 0 }, -- MobService: threat your damage makes
	{ Id = "SpellDamage", Kind = "Percent", Min = 0, Max = 0, Groups = NONE, Weight = 0 }, -- SpellService: every spell
	{ Id = "SpellArea", Kind = "Percent", Min = 0, Max = 0, Groups = NONE, Weight = 0 }, -- SpellService: spell radius / reach
	{ Id = "ReactionDamage", Kind = "Percent", Min = 0, Max = 0, Groups = NONE, Weight = 0 }, -- SpellService: Reactions
	{ Id = "OverflowDuration", Kind = "Seconds", Min = 0, Max = 0, Groups = NONE, Weight = 0 }, -- CurrentService: Overflow length
	{ Id = "BeaconSlots", Kind = "Flat", Min = 0, Max = 0, Groups = NONE, Weight = 0 }, -- BeaconService: usable slots
	{ Id = "HealPower", Kind = "Percent", Min = 0, Max = 0, Groups = NONE, Weight = 0 }, -- Runner: healing your moves give
	{ Id = "MoveSpeed", Kind = "Percent", Min = 0, Max = 0, Groups = NONE, Weight = 0 }, -- CharacterController (SpeedBonus attribute)
	{ Id = "LootLuck", Kind = "Percent", Min = 0, Max = 0, Groups = NONE, Weight = 0 }, -- LootService: gear drop chance
	{ Id = "GoldFind", Kind = "Percent", Min = 0, Max = 0, Groups = NONE, Weight = 0 }, -- LootService: gold from foes
	{ Id = "MarkPower", Kind = "Percent", Min = 0, Max = 0, Groups = NONE, Weight = 0 }, -- Runner: Mark bonus damage
	{ Id = "AbilityPower", Kind = "Percent", Min = 0, Max = 0, Groups = NONE, Weight = 0 }, -- PositionService: ability damage
	{ Id = "AbilityCooldown", Kind = "Percent", Min = 0, Max = 0, Groups = NONE, Weight = 0 }, -- PositionService: ability cooldown
}

-- Unique named effects (Legendary and above). GearEffects implements each one;
-- Params are its numbers so they can be tuned here.
local uniques: { UniqueDef } = {
	-- Every Nth weapon hit on the same foe releases a tidal burst around it.
	{ Id = "Undertow", Groups = { "Weapon" }, Params = { Every = 4, DamageFraction = 0.4, Radius = 9 } },
	-- Dropping under a health threshold raises a shield. Has a cooldown.
	{ Id = "Brineward", Groups = { "Armor" }, Params = { Threshold = 0.3, ShieldFraction = 0.25, Duration = 6, Cooldown = 45 } },
	-- Parries grant a Resonance stack and refill some Current.
	{ Id = "RiptideReflex", Groups = { "Armor", "Weapon" }, Params = { Stacks = 1, CurrentFraction = 0.1 } },
	-- Spells cast while the Vessel is nearly full hit harder.
	{ Id = "Deepglass", Groups = { "Accessory" }, Params = { Threshold = 0.8, DamageBonus = 0.18 } },
	-- Resonance doesn't decay while health stays high.
	{ Id = "Spireheart", Groups = { "Accessory" }, Params = { HealthThreshold = 0.6 } },
	-- A Perfect Dodge heals a slice of max health.
	{ Id = "Lanternwake", Groups = { "Armor", "Accessory" }, Params = { HealFraction = 0.08, Cooldown = 4 } },
}

local byId: { [string]: AffixDef } = {}
for _, def in list do
	byId[def.Id] = table.freeze(def)
end
local uniqueById: { [string]: UniqueDef } = {}
for _, def in uniques do
	uniqueById[def.Id] = table.freeze(def)
end

local Affixes = {}

Affixes.List = table.freeze(list)
Affixes.Uniques = table.freeze(uniques)

function Affixes.Get(id: string): AffixDef?
	return byId[id]
end

function Affixes.GetUnique(id: string): UniqueDef?
	return uniqueById[id]
end

-- Rounds a rolled value to how it's displayed (whole %, whole flat, tenths of a second).
function Affixes.Round(kind: AffixKind, value: number): number
	if kind == "Percent" then
		return math.floor(value * 100 + 0.5) / 100
	elseif kind == "Seconds" then
		return math.floor(value * 10 + 0.5) / 10
	end
	return math.max(1, math.floor(value + 0.5))
end

-- Affixes and uniques a gear group may roll.
function Affixes.Pool(group: AffixGroup): { AffixDef }
	local pool = {}
	for _, def in list do
		if table.find(def.Groups, group) then
			table.insert(pool, def)
		end
	end
	return pool
end

function Affixes.UniquePool(group: AffixGroup): { UniqueDef }
	local pool = {}
	for _, def in uniques do
		if table.find(def.Groups, group) then
			table.insert(pool, def)
		end
	end
	return pool
end

return table.freeze(Affixes)
