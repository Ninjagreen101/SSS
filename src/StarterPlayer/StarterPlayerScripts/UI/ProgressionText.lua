--!strict
--[[
	ProgressionText
	Player-facing text for Positions, skill tree nodes and abilities, shared
	by the Skill Tree menu, the Character sheet and toasts. Bonus lines reuse
	ItemText.AffixLine, so a tree bonus reads exactly like the same bonus on
	gear.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Strings = require(Shared.Strings)
local Positions = require(Shared.Data.Positions)
local Abilities = require(Shared.Data.Abilities)

local ItemText = require(script.Parent.ItemText)

local S = Strings.Positions

local ProgressionText = {}

function ProgressionText.PositionName(id: string): string
	return S.Names[id] or id
end

function ProgressionText.BranchName(id: string): string
	return S.Branches[id] or id
end

function ProgressionText.AbilityName(id: string): string
	local entry = Strings.Abilities[id]
	return if entry then entry.Name else id
end

function ProgressionText.AbilityDescription(id: string): string
	local entry = Strings.Abilities[id]
	return if entry then entry.Description else ""
end

-- "+20 max health" style lines for a node's bonuses, in a stable order.
function ProgressionText.BonusLines(bonuses: { [string]: number }): { string }
	local ids = {}
	for id in bonuses do
		table.insert(ids, id)
	end
	table.sort(ids)
	local lines = {}
	for _, id in ids do
		table.insert(lines, ItemText.AffixLine(id, bonuses[id]))
	end
	return lines
end

-- A node's title: notables and keystones have names, actives use their
-- ability's name and minor nodes read as their (single) bonus.
function ProgressionText.NodeName(node: Positions.NodeDef): string
	if node.Ability then
		return ProgressionText.AbilityName(node.Ability)
	end
	if node.Key then
		return S.Nodes[node.Key] or node.Key
	end
	local lines = ProgressionText.BonusLines(node.Bonuses)
	return lines[1] or node.Id
end

-- Everything a node does, as lines (the ability's description for actives).
function ProgressionText.NodeLines(node: Positions.NodeDef): { string }
	if node.Ability then
		local def = Abilities.Get(node.Ability)
		local lines = { ProgressionText.AbilityDescription(node.Ability) }
		if def then
			table.insert(lines, Strings.Format(S.AbilityStats, { cost = def.Cost, cooldown = def.Cooldown }))
		end
		return lines
	end
	return ProgressionText.BonusLines(node.Bonuses)
end

return table.freeze(ProgressionText)
