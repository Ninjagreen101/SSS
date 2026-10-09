--!strict
--[[
	Rewards (helper, not a system)
	Grants a written reward list: "IronScrap x8, ClimbersLongsword:Rare" (defId[:minRarity][ xCount],
	comma separated) plus gold. Used by caches (SecretService) and dungeon chests (DungeonService).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Log = require(Shared.Util.Log)

local DataService = require(script.Parent.DataService)
local InventoryService = require(script.Parent.InventoryService)

local log = Log.new("Rewards")

local Rewards = {}

export type Entry = { Id: string, Count: number, Rarity: string? }

function Rewards.Parse(spec: string): { Entry }
	local out = {}
	for _, raw in string.split(spec, ",") do
		local text = string.match(raw, "^%s*(.-)%s*$") or ""
		if text ~= "" then
			local count = 1
			local body, n = string.match(text, "^(.-)%s*x(%d+)$")
			if body and n then
				text = body
				count = tonumber(n) or 1
			end
			local id, rarity = string.match(text, "^([%w_]+):(%a+)$")
			table.insert(out, { Id = id or text, Count = count, Rarity = rarity })
		end
	end
	return out
end

-- Gives every entry (a full bag drops nothing silently: the failure is logged) and the gold.
function Rewards.Grant(player: Player, spec: string?, gold: number?)
	if spec then
		for _, entry in Rewards.Parse(spec) do
			local ok, err = InventoryService.Give(player, entry.Id, entry.Count, entry.Rarity)
			if not ok then
				log:Warn(`{player.Name}: could not give {entry.Id}: {tostring(err)}`)
			end
		end
	end
	if gold and gold > 0 then
		DataService.Increment(player, { "Currencies", "Gold" }, gold, 0, Config.Economy.MaxGold)
	end
end

return Rewards
