--!strict
--[[
	ProgressionRules
	Pure rules for stat points, Positions, the skill tree and respecs. The
	server runs them on a copy of the profile and commits the result; the
	client runs the same checks to grey out buttons and preview costs, so
	what the menu allows is exactly what the server allows.

	Every mutating rule returns (ok, reason). Reasons are keys of
	Strings.Progression.Reasons.
]]

local Shared = script.Parent.Parent
local Config = require(Shared.Config)
local Types = require(Shared.Types)
local Positions = require(script.Parent.Positions)
local Abilities = require(script.Parent.Abilities)
local Affixes = require(script.Parent.Affixes)

type PlayerData = Types.PlayerData

export type Reason =
	"Invalid"
	| "Points"
	| "Level"
	| "NoPosition"
	| "AlreadyChosen"
	| "WrongPosition"
	| "Taken"
	| "Locked"
	| "NotUnlocked"
	| "Funds"
	| "Nothing"

export type NodeState = "Taken" | "Available" | "Unaffordable" | "Locked"

local P = Config.Progression

local STAT_NAMES = { "Vitality", "Endurance", "Strength", "Finesse", "Draw", "Density", "Control" }

local Rules = {}

Rules.StatNames = table.freeze(STAT_NAMES)

local function isStat(name: string): boolean
	return table.find(STAT_NAMES, name) ~= nil
end

-- STATS --------------------------------------------------------------------------

function Rules.InvestedStatPoints(data: PlayerData): number
	local total = 0
	for _, name in STAT_NAMES do
		total += (data.Stats :: any)[name]
	end
	return total
end

-- Spends stat points: `allocation` maps stat name -> points to add (all positive).
function Rules.AllocateStats(data: PlayerData, allocation: { [string]: number }): (boolean, Reason?)
	local total = 0
	for name, amount in allocation do
		if type(name) ~= "string" or not isStat(name) or type(amount) ~= "number" or amount % 1 ~= 0 or amount < 0 then
			return false, "Invalid"
		end
		total += amount
	end
	if total <= 0 or total > P.MaxAllocationPerRequest then
		return false, "Invalid"
	end
	if total > data.StatPoints then
		return false, "Points"
	end
	for name, amount in allocation do
		(data.Stats :: any)[name] += amount
	end
	data.StatPoints -= total
	return true, nil
end

-- POSITIONS -----------------------------------------------------------------------

function Rules.CanChoosePosition(data: PlayerData, positionId: string): (boolean, Reason?)
	if not Positions.Get(positionId) then
		return false, "Invalid"
	end
	if data.Position ~= "" then
		return false, "AlreadyChosen"
	end
	if data.Level < P.Positions.UnlockLevel then
		return false, "Level"
	end
	return true, nil
end

function Rules.ChoosePosition(data: PlayerData, positionId: string): (boolean, Reason?)
	local ok: boolean, reason: Reason? = Rules.CanChoosePosition(data, positionId)
	if not ok then
		return false, reason
	end
	data.Position = positionId
	return true, nil
end

-- SKILL TREE ----------------------------------------------------------------------

function Rules.NodeCost(node: Positions.NodeDef): number
	return (P.NodeCosts :: any)[node.Kind] or 1
end

function Rules.SpentSkillPoints(data: PlayerData): number
	local total = 0
	for id, taken in data.SkillTree do
		local node = Positions.Node(id)
		if taken and node then
			total += Rules.NodeCost(node)
		end
	end
	return total
end

-- True if a node it links back to is taken (entry nodes only need the Position).
function Rules.IsReachable(data: PlayerData, node: Positions.NodeDef): boolean
	if #node.Links == 0 then
		return true
	end
	for _, link in node.Links do
		if data.SkillTree[link] then
			return true
		end
	end
	return false
end

function Rules.CanUnlock(data: PlayerData, nodeId: string): (boolean, Reason?)
	local node = Positions.Node(nodeId)
	if not node then
		return false, "Invalid"
	end
	if data.Position == "" then
		return false, "NoPosition"
	end
	if node.Position ~= data.Position then
		return false, "WrongPosition"
	end
	if data.SkillTree[nodeId] then
		return false, "Taken"
	end
	if not Rules.IsReachable(data, node) then
		return false, "Locked"
	end
	if data.SkillPoints < Rules.NodeCost(node) then
		return false, "Points"
	end
	return true, nil
end

function Rules.Unlock(data: PlayerData, nodeId: string): (boolean, Reason?)
	local ok: boolean, reason: Reason? = Rules.CanUnlock(data, nodeId)
	if not ok then
		return false, reason
	end
	local node = Positions.Node(nodeId) :: Positions.NodeDef
	data.SkillTree[nodeId] = true
	data.SkillPoints -= Rules.NodeCost(node)
	-- The first ability you learn goes straight onto the Position key.
	if node.Ability and data.Hotbar.Ability == "" then
		data.Hotbar.Ability = node.Ability
	end
	return true, nil
end

function Rules.NodeState(data: PlayerData, nodeId: string): NodeState
	if data.SkillTree[nodeId] then
		return "Taken"
	end
	local ok, reason = Rules.CanUnlock(data, nodeId)
	if ok then
		return "Available"
	end
	return if reason == "Points" then "Unaffordable" else "Locked"
end

-- Bonus ids and stat points from every taken node (stats separately, so the
-- Character sheet can show "base + tree + gear").
function Rules.TreeBonuses(data: PlayerData): ({ [string]: number }, { [string]: number })
	local bonuses: { [string]: number } = {}
	local stats: { [string]: number } = {}
	for id, taken in data.SkillTree do
		local node = Positions.Node(id)
		if taken and node and node.Position == data.Position then
			for bonus, value in node.Bonuses do
				local affix = Affixes.Get(bonus)
				if isStat(bonus) or (affix and affix.Kind == "Points") then
					local stat = if affix and affix.Stat then affix.Stat else bonus
					stats[stat] = (stats[stat] or 0) + value
				else
					bonuses[bonus] = (bonuses[bonus] or 0) + value
				end
			end
		end
	end
	return bonuses, stats
end

-- ABILITIES -----------------------------------------------------------------------

-- Abilities whose Active node is taken, in tree order.
function Rules.UnlockedAbilities(data: PlayerData): { string }
	local list = {}
	for _, node in Positions.NodesOf(data.Position) do
		if node.Ability and data.SkillTree[node.Id] then
			table.insert(list, node.Ability)
		end
	end
	return list
end

-- Puts an unlocked ability on the Position key ("" clears it).
function Rules.EquipAbility(data: PlayerData, abilityId: string): (boolean, Reason?)
	if abilityId == "" then
		data.Hotbar.Ability = ""
		return true, nil
	end
	local node = Positions.AbilityNode(abilityId)
	if not node or not Abilities.Get(abilityId) then
		return false, "Invalid"
	end
	if node.Position ~= data.Position or not data.SkillTree[node.Id] then
		return false, "NotUnlocked"
	end
	data.Hotbar.Ability = abilityId
	return true, nil
end

-- RESPEC ----------------------------------------------------------------------------

function Rules.RespecCost(data: PlayerData): number
	if P.Respec.FirstFree and data.RespecCount == 0 then
		return 0
	end
	return P.Respec.GoldPerLevel * data.Level
end

-- True if a respec would change anything.
function Rules.HasAnythingToRespec(data: PlayerData, changePosition: boolean): boolean
	return Rules.InvestedStatPoints(data) > 0 or next(data.SkillTree) ~= nil or (changePosition and data.Position ~= "")
end

-- Every stat point and skill point goes back to unspent; with
-- `changePosition` the Position is cleared too (choose again at the Hall).
function Rules.Respec(data: PlayerData, changePosition: boolean): (boolean, Reason?)
	if not Rules.HasAnythingToRespec(data, changePosition) then
		return false, "Nothing"
	end
	local cost = Rules.RespecCost(data)
	if data.Currencies.Gold < cost then
		return false, "Funds"
	end
	data.Currencies.Gold -= cost
	data.StatPoints += Rules.InvestedStatPoints(data)
	for _, name in STAT_NAMES do
		(data.Stats :: any)[name] = 0
	end
	data.SkillPoints += Rules.SpentSkillPoints(data)
	data.SkillTree = {}
	data.Hotbar.Ability = ""
	if changePosition then
		data.Position = ""
	end
	data.RespecCount += 1
	return true, nil
end

-- REPAIR (on load) ------------------------------------------------------------------

-- Fixes a profile after the tree data changed in an update: nodes that no
-- longer exist, belong to another Position or can't be reached any more are
-- refunded, and an equipped ability that isn't unlocked is cleared.
-- Returns true if anything changed.
function Rules.Repair(data: PlayerData): boolean
	local changed = false
	-- Walk outward from the entry nodes; whatever isn't connected is refunded.
	local kept: { [string]: boolean } = {}
	local progress = true
	while progress do
		progress = false
		for id, taken in data.SkillTree do
			local node = Positions.Node(id)
			if taken and not kept[id] and node and node.Position == data.Position then
				local reachable = #node.Links == 0
				for _, link in node.Links do
					if kept[link] then
						reachable = true
					end
				end
				if reachable then
					kept[id] = true
					progress = true
				end
			end
		end
	end
	for id, taken in data.SkillTree do
		if not kept[id] then
			local node = Positions.Node(id)
			if taken and node then
				data.SkillPoints += Rules.NodeCost(node)
			end
			data.SkillTree[id] = nil
			changed = true
		end
	end
	local equipped = data.Hotbar.Ability
	if equipped ~= "" then
		local node = Positions.AbilityNode(equipped)
		if not node or not kept[node.Id] then
			data.Hotbar.Ability = ""
			changed = true
		end
	end
	if data.StatPoints < 0 then
		data.StatPoints = 0
		changed = true
	end
	if data.SkillPoints < 0 then
		data.SkillPoints = 0
		changed = true
	end
	return changed
end

-- ARCHETYPE -------------------------------------------------------------------------

-- The build's name for the Character sheet (Config.Progression.Archetypes).
function Rules.Archetype(data: PlayerData, weaponClass: string?): string
	local invested = Rules.InvestedStatPoints(data)
	local primary = data.Attunements.Primary
	for _, rule in P.Archetypes do
		local ok = true
		if rule.Classes and (not weaponClass or not table.find(rule.Classes, weaponClass)) then
			ok = false
		end
		if ok and rule.Attunements and not table.find(rule.Attunements, primary) then
			ok = false
		end
		if ok and rule.Share then
			local sum = 0
			for _, stat in rule.Share.Stats do
				sum += (data.Stats :: any)[stat] or 0
			end
			ok = invested > 0 and sum / invested >= rule.Share.Min
		end
		if ok then
			return rule.Id
		end
	end
	return "Bladecaller"
end

return table.freeze(Rules)
