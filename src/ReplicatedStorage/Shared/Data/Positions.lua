--!strict
--[[
	Positions
	The five team roles chosen at level 15 (Spec Section 9) and their skill
	trees. Pure data, shared: the server validates unlocks against it and the
	Skill Tree menu draws it.

	Every Position has 3 branches of 12 nodes laid out the same way, so a
	branch is just a list of 12 entries in this order:

	   1  Minor     entry (links to the Position's centre)
	   2  Minor
	   3  Notable
	   4  Minor  5  Minor         (the branch forks)
	   6  Active 7  Notable       (6 needs 4, 7 needs 5)
	   8  Minor                   (needs 6 or 7: the fork joins again)
	   9  Minor 10  Notable       (both need 8)
	  11  Minor                   (needs 9 or 10)
	  12  Keystone                (needs 11)

	A node can be taken when any node it links back to is taken (the entry
	node only needs the Position). Costs: Config.Progression.NodeCosts.

	Node bonuses use the bonus ids in Shared/Data/Affixes (gear and trees
	share one bonus table, GearStats.Summarize adds them up). Stat ids
	(Vitality...) are stat points added before soft caps.

	Active nodes unlock an ability (Shared/Data/Abilities) for the Position
	key; one is equipped at a time.

	Adding a node later (hidden-chest sense, revive speed...) is one entry
	here plus its string, once the system that reads its bonus exists.

	Names: Strings.Positions (positions, branches, notable / keystone keys)
	and Strings.Abilities.
]]

export type NodeKind = "Minor" | "Notable" | "Active" | "Keystone"

export type NodeDef = {
	Id: string, -- "Vanguard.Bulwark.3"
	Position: string,
	Branch: string,
	Index: number, -- 1..12 along the branch
	Kind: NodeKind,
	Key: string?, -- Notable / Keystone name key (Strings.Positions.Nodes)
	Ability: string?, -- Active: ability id
	Bonuses: { [string]: number },
	Links: { string }, -- any one of these must be taken first ({} = entry node)
	X: number, -- constellation position (tree units, centre = 0, 0)
	Y: number,
}

export type BranchDef = {
	Id: string,
	Angle: number, -- degrees, 0 = right, -90 = up
	Nodes: { NodeDef },
}

export type PositionDef = {
	Id: string,
	Color: Color3, -- accent for the tree, nameplates and the Hall
	Branches: { BranchDef },
	Order: number,
}

type Entry = { Kind: NodeKind, Key: string?, Ability: string?, Bonuses: { [string]: number } }

-- SHORTHANDS ----------------------------------------------------------------------

local function M(bonuses: { [string]: number }): Entry
	return { Kind = "Minor", Bonuses = bonuses }
end

local function N(key: string, bonuses: { [string]: number }): Entry
	return { Kind = "Notable", Key = key, Bonuses = bonuses }
end

local function K(key: string, bonuses: { [string]: number }): Entry
	return { Kind = "Keystone", Key = key, Bonuses = bonuses }
end

local function A(ability: string): Entry
	return { Kind = "Active", Ability = ability, Bonuses = {} }
end

-- Shared branch shape: (distance along the branch, sideways offset) and the
-- indices each node links back to.
local LAYOUT: { { Along: number, Side: number, Links: { number } } } = {
	{ Along = 2.2, Side = 0, Links = {} },
	{ Along = 3.4, Side = 0, Links = { 1 } },
	{ Along = 4.7, Side = 0, Links = { 2 } },
	{ Along = 5.9, Side = -1.3, Links = { 3 } },
	{ Along = 5.9, Side = 1.3, Links = { 3 } },
	{ Along = 7.2, Side = -1.8, Links = { 4 } },
	{ Along = 7.2, Side = 1.8, Links = { 5 } },
	{ Along = 8.4, Side = 0, Links = { 6, 7 } },
	{ Along = 9.5, Side = -1.1, Links = { 8 } },
	{ Along = 9.5, Side = 1.1, Links = { 8 } },
	{ Along = 10.6, Side = 0, Links = { 9, 10 } },
	{ Along = 12, Side = 0, Links = { 11 } },
}

local EXPECTED_KINDS: { NodeKind } = {
	"Minor", "Minor", "Notable", "Minor", "Minor", "Active", "Notable", "Minor", "Minor", "Notable", "Minor", "Keystone",
}

local ANGLES = { -90, 30, 150 }

local byId: { [string]: NodeDef } = {}
local abilityNode: { [string]: NodeDef } = {}
local positions: { [string]: PositionDef } = {}
local order: { string } = {}

local function branch(positionId: string, branchId: string, angle: number, entries: { Entry }): BranchDef
	assert(#entries == #LAYOUT, `{positionId}.{branchId}: needs {#LAYOUT} nodes`)
	local radians = math.rad(angle)
	local along = Vector2.new(math.cos(radians), math.sin(radians))
	local side = Vector2.new(-along.Y, along.X)
	local nodes: { NodeDef } = {}
	for index, entry in entries do
		assert(entry.Kind == EXPECTED_KINDS[index], `{positionId}.{branchId} node {index}: expected {EXPECTED_KINDS[index]}`)
		local shape = LAYOUT[index]
		local links = {}
		for _, link in shape.Links do
			table.insert(links, `{positionId}.{branchId}.{link}`)
		end
		local point = along * shape.Along + side * shape.Side
		local node: NodeDef = {
			Id = `{positionId}.{branchId}.{index}`,
			Position = positionId,
			Branch = branchId,
			Index = index,
			Kind = entry.Kind,
			Key = entry.Key,
			Ability = entry.Ability,
			Bonuses = table.freeze(entry.Bonuses),
			Links = table.freeze(links),
			X = math.floor(point.X * 100 + 0.5) / 100,
			Y = math.floor(point.Y * 100 + 0.5) / 100,
		}
		table.freeze(node)
		byId[node.Id] = node
		if node.Ability then
			assert(abilityNode[node.Ability] == nil, `ability {node.Ability} used twice`)
			abilityNode[node.Ability] = node
		end
		table.insert(nodes, node)
	end
	return table.freeze({ Id = branchId, Angle = angle, Nodes = table.freeze(nodes) })
end

local function position(id: string, color: Color3, branches: { { Id: string, Entries: { Entry } } })
	local list = {}
	for index, def in branches do
		table.insert(list, branch(id, def.Id, ANGLES[index], def.Entries))
	end
	table.insert(order, id)
	positions[id] = table.freeze({ Id = id, Color = color, Branches = table.freeze(list), Order = #order })
end

-- THE FIVE POSITIONS ----------------------------------------------------------------

-- Vanguard (front line): taunts, damage reduction, guard counters, posture shredding.
position("Vanguard", Color3.fromHex("#D9A441"), {
	{
		Id = "Bulwark",
		Entries = {
			M({ MaxHealth = 20 }),
			M({ Vitality = 2 }),
			N("TidewallFrame", { Armor = 0.04, MaxHealth = 30 }),
			M({ Armor = 0.02 }),
			M({ MaxHealth = 25 }),
			A("Seawall"),
			N("Unbowed", { GuardPosture = 0.25, BlockCost = 0.15 }),
			M({ Vitality = 3 }),
			M({ Armor = 0.02 }),
			N("BarnacleHide", { MaxHealth = 60, StaminaRegen = 0.1 }),
			M({ MaxHealth = 30 }),
			K("LighthouseStance", { Armor = 0.06, MaxHealth = 80, Threat = 0.5 }),
		},
	},
	{
		Id = "Challenge",
		Entries = {
			M({ Threat = 0.2 }),
			M({ MaxStamina = 10 }),
			N("Bellwether", { Threat = 0.5, Armor = 0.03 }),
			M({ Endurance = 2 }),
			M({ Threat = 0.2 }),
			A("HarborBell"),
			N("IronLungs", { MaxStamina = 25, StaminaRegen = 0.12 }),
			M({ Vitality = 2 }),
			M({ Threat = 0.25 }),
			N("StandFirm", { GuardPosture = 0.2, Armor = 0.03 }),
			M({ MaxHealth = 30 }),
			K("RallyingMast", { AbilityCooldown = 0.2, Threat = 0.6, MaxHealth = 40 }),
		},
	},
	{
		Id = "Breaker",
		Entries = {
			M({ PostureDamage = 0.05 }),
			M({ Strength = 2 }),
			N("Counterweight", { RiposteDamage = 0.2, ParryWindow = 1 }),
			M({ PostureDamage = 0.05 }),
			M({ RiposteDamage = 0.1 }),
			A("Keelbreaker"),
			N("Shatterguard", { PostureDamage = 0.12, BlockCost = 0.15 }),
			M({ Strength = 3 }),
			M({ PostureDamage = 0.06 }),
			N("AnsweringBlow", { RiposteDamage = 0.3, CritChance = 0.03 }),
			M({ WeaponDamage = 0.04 }),
			K("Wreckmaker", { PostureDamage = 0.2, RiposteDamage = 0.25 }),
		},
	},
})

-- Lancer (striker): damage bursts, crit chains, gap closers, execution bonuses.
position("Lancer", Color3.fromHex("#E2574C"), {
	{
		Id = "Edge",
		Entries = {
			M({ CritChance = 0.02 }),
			M({ Finesse = 2 }),
			N("GlintEye", { CritChance = 0.04, CritDamage = 0.1 }),
			M({ CritDamage = 0.08 }),
			M({ Finesse = 2 }),
			A("Glintstorm"),
			N("KeenEdge", { CritDamage = 0.2 }),
			M({ CritChance = 0.02 }),
			M({ Finesse = 3 }),
			N("Cascade", { CritChance = 0.03, AbilityCooldown = 0.1 }),
			M({ CritDamage = 0.1 }),
			K("ThousandCuts", { CritChance = 0.06, CritDamage = 0.25 }),
		},
	},
	{
		Id = "Surge",
		Entries = {
			M({ MoveSpeed = 0.03 }),
			M({ DodgeCost = 0.08 }),
			N("RiptideStep", { MoveSpeed = 0.05, DodgeCost = 0.12 }),
			M({ MaxStamina = 10 }),
			M({ WeaponDamage = 0.03 }),
			A("RiptideLunge"),
			N("Momentum", { WeaponDamage = 0.08, StaminaRegen = 0.1 }),
			M({ Endurance = 2 }),
			M({ MoveSpeed = 0.03 }),
			N("Slipstream", { DodgeCost = 0.15, AbilityCooldown = 0.1 }),
			M({ WeaponDamage = 0.04 }),
			K("WavebreakerCharge", { AbilityPower = 0.25, MoveSpeed = 0.05, WeaponDamage = 0.06 }),
		},
	},
	{
		Id = "Reaper",
		Entries = {
			M({ ExecuteDamage = 0.06 }),
			M({ Strength = 2 }),
			N("LowTide", { ExecuteDamage = 0.15 }),
			M({ WeaponDamage = 0.03 }),
			M({ ExecuteDamage = 0.06 }),
			A("Severance"),
			N("Bloodwake", { Siphon = 0.12, ExecuteDamage = 0.1 }),
			M({ Finesse = 2 }),
			M({ WeaponDamage = 0.04 }),
			N("NoQuarter", { RiposteDamage = 0.2, ExecuteDamage = 0.1 }),
			M({ ExecuteDamage = 0.08 }),
			K("LastLight", { ExecuteDamage = 0.3, CritChance = 0.04 }),
		},
	},
})

-- Tidecaller (caster): spell power, area magic, Overflow extension, reaction amplification.
position("Tidecaller", Color3.fromHex("#3FB8D9"), {
	{
		Id = "Wellspring",
		Entries = {
			M({ SpellDamage = 0.03 }),
			M({ Density = 2 }),
			N("DeepReservoir", { MaxCurrent = 20, SpellDamage = 0.05 }),
			M({ CurrentRegen = 0.06 }),
			M({ SpellDamage = 0.04 }),
			A("Floodtide"),
			N("Brimming", { OverflowDuration = 1.5, CurrentRegen = 0.08 }),
			M({ Density = 3 }),
			M({ SpellDamage = 0.04 }),
			N("SpringTide", { OverflowDuration = 1.5, MaxCurrent = 20 }),
			M({ CastSpeed = 0.04 }),
			K("EndlessFlow", { OverflowDuration = 2.5, SpellDamage = 0.1 }),
		},
	},
	{
		Id = "Maelstrom",
		Entries = {
			M({ SpellArea = 0.04 }),
			M({ Control = 2 }),
			N("WideWaters", { SpellArea = 0.1 }),
			M({ CastSpeed = 0.03 }),
			M({ SpellDamage = 0.03 }),
			A("Maelstrom"),
			N("UndertowPull", { SpellArea = 0.08, AbilityPower = 0.1 }),
			M({ Control = 3 }),
			M({ SpellArea = 0.05 }),
			N("SwiftCurrents", { CastSpeed = 0.08 }),
			M({ SpellDamage = 0.04 }),
			K("EyeOfTheStorm", { SpellArea = 0.15, SpellDamage = 0.08 }),
		},
	},
	{
		Id = "Catalyst",
		Entries = {
			M({ ReactionDamage = 0.06 }),
			M({ Draw = 2 }),
			N("VolatileMix", { ReactionDamage = 0.15 }),
			M({ SpellDamage = 0.03 }),
			M({ ReactionDamage = 0.06 }),
			A("CatalystPulse"),
			N("ChainReaction", { ReactionDamage = 0.12, CastSpeed = 0.04 }),
			M({ Density = 2 }),
			M({ ReactionDamage = 0.06 }),
			N("Saturate", { ResonanceDecay = 1, CurrentRegen = 0.08 }),
			M({ SpellDamage = 0.04 }),
			K("GrandReaction", { ReactionDamage = 0.3 }),
		},
	},
})

-- Beaconkeeper (support): extra Beacons, stronger Beacons, healing, ally buffs.
position("Beaconkeeper", Color3.fromHex("#7BD98C"), {
	{
		Id = "Lightkeeper",
		Entries = {
			M({ SentryDamage = 0.08 }),
			M({ Control = 2 }),
			N("SecondLamp", { BeaconSlots = 1 }),
			M({ AegisRecharge = 0.08 }),
			M({ SentryDamage = 0.08 }),
			A("Kindle"),
			N("SteadyFlame", { RelayCooldown = 0.15, AegisRecharge = 0.12 }),
			M({ Control = 3 }),
			M({ SentryDamage = 0.1 }),
			N("Watchfire", { SentryDamage = 0.2, MaxCurrent = 15 }),
			M({ RelayCooldown = 0.08 }),
			K("Constellation", { BeaconSlots = 1, SentryDamage = 0.15, AegisRecharge = 0.15 }),
		},
	},
	{
		Id = "Wellkeeper",
		Entries = {
			M({ HealPower = 0.06 }),
			M({ Draw = 2 }),
			N("FreshSpring", { HealPower = 0.15, CurrentRegen = 0.06 }),
			M({ MaxHealth = 20 }),
			M({ HealPower = 0.06 }),
			A("Tidewell"),
			N("DeepwaterMend", { HealPower = 0.12, MaxCurrent = 15 }),
			M({ Vitality = 2 }),
			M({ HealPower = 0.06 }),
			N("SharedBreath", { StaminaRegen = 0.12, CurrentRegen = 0.08 }),
			M({ HealPower = 0.08 }),
			K("Wellmother", { HealPower = 0.3, AbilityCooldown = 0.15 }),
		},
	},
	{
		Id = "Lanternguard",
		Entries = {
			M({ Armor = 0.02 }),
			M({ Vitality = 2 }),
			N("WarmGlow", { MaxHealth = 30, HealPower = 0.08 }),
			M({ AbilityCooldown = 0.05 }),
			M({ Armor = 0.02 }),
			A("GuidingLantern"),
			N("SteadfastLight", { Armor = 0.04, StaminaRegen = 0.1 }),
			M({ Endurance = 2 }),
			M({ AbilityCooldown = 0.05 }),
			N("BrightWard", { AbilityPower = 0.15, MaxHealth = 30 }),
			M({ HealPower = 0.06 }),
			K("BeaconOfTheClimb", { AbilityCooldown = 0.15, AbilityPower = 0.2, Armor = 0.04 }),
		},
	},
})

-- Pathfinder (scout): movement, traps, weak-point reveal, loot luck.
position("Pathfinder", Color3.fromHex("#B98CF2"), {
	{
		Id = "Trailblazer",
		Entries = {
			M({ MoveSpeed = 0.03 }),
			M({ Endurance = 2 }),
			N("LightFeet", { MoveSpeed = 0.05, DodgeCost = 0.1 }),
			M({ MaxStamina = 10 }),
			M({ StaminaRegen = 0.06 }),
			A("Windstep"),
			N("SecondWind", { StaminaRegen = 0.15, MaxStamina = 15 }),
			M({ Finesse = 2 }),
			M({ MoveSpeed = 0.03 }),
			N("GhostTrail", { DodgeCost = 0.15, CritChance = 0.02 }),
			M({ MaxStamina = 10 }),
			K("FarStrider", { MoveSpeed = 0.08, DodgeCost = 0.15, StaminaRegen = 0.1 }),
		},
	},
	{
		Id = "Snare",
		Entries = {
			M({ AbilityPower = 0.05 }),
			M({ Control = 2 }),
			N("BarbedWire", { AbilityPower = 0.12 }),
			M({ AbilityCooldown = 0.05 }),
			M({ PostureDamage = 0.04 }),
			A("Tanglewire"),
			N("QuickSet", { AbilityCooldown = 0.12 }),
			M({ Finesse = 2 }),
			M({ AbilityPower = 0.06 }),
			N("HuntersPatience", { CritChance = 0.03, AbilityPower = 0.1 }),
			M({ AbilityCooldown = 0.06 }),
			K("KillingGround", { AbilityPower = 0.25, AbilityCooldown = 0.1 }),
		},
	},
	{
		Id = "Seeker",
		Entries = {
			M({ LootLuck = 0.05 }),
			M({ GoldFind = 0.05 }),
			N("KeenNose", { LootLuck = 0.12 }),
			M({ MarkPower = 0.08 }),
			M({ GoldFind = 0.06 }),
			A("ExposeWeakness"),
			N("WeakSeam", { MarkPower = 0.2, CritChance = 0.02 }),
			M({ Finesse = 2 }),
			M({ LootLuck = 0.06 }),
			N("TreasureSense", { GoldFind = 0.15, LootLuck = 0.08 }),
			M({ MarkPower = 0.1 }),
			K("SpireCartographer", { LootLuck = 0.2, GoldFind = 0.15, MarkPower = 0.15 }),
		},
	},
})

-- API ------------------------------------------------------------------------------

local Positions = {}

Positions.Order = table.freeze(order)

function Positions.Get(id: string): PositionDef?
	return positions[id]
end

function Positions.All(): { [string]: PositionDef }
	return positions
end

function Positions.Node(id: string): NodeDef?
	return byId[id]
end

function Positions.Nodes(): { [string]: NodeDef }
	return byId
end

-- The node that unlocks an ability (nil for unknown ids).
function Positions.AbilityNode(abilityId: string): NodeDef?
	return abilityNode[abilityId]
end

-- Every node of a Position, branch by branch.
function Positions.NodesOf(positionId: string): { NodeDef }
	local def = positions[positionId]
	local list = {}
	if def then
		for _, branchDef in def.Branches do
			for _, node in branchDef.Nodes do
				table.insert(list, node)
			end
		end
	end
	return list
end

return table.freeze(Positions)
