--!strict
--[[
	LootService
	Personal loot (Spec Section 11). When an enemy dies, every player who
	helped and is nearby gets their own roll from Config/Loot: gold, a few
	materials, sometimes a piece of gear, and rare extra drops. Only that
	player is told about (and can collect) their drops, so nothing can be
	stolen and nobody waits for a loot split.

	Drops live only on the server as records (no Instances); the owner's
	LootController draws them, flies them out of the corpse and asks to pick
	them up when close enough. The server re-checks ownership, distance and
	that the drop still exists before anything enters the bag.

	Pity: per zone, kills since the last Rare-or-better gear drop are saved
	in ItemState.Pity; at Config.Loot.Pity.Kills the next kill guarantees
	one.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Types = require(Shared.Types)
local Net = require(Shared.Net)
local Items = require(Shared.Data.Items)
local Mobs = require(Shared.Data.Mobs)
local Rules = require(Shared.Data.InventoryRules)

local DataService = require(script.Parent.DataService)
local InventoryService = require(script.Parent.InventoryService)
local AnalyticsService = require(script.Parent.AnalyticsService)
local GearService = require(script.Parent.GearService)
local GameEvents = require(script.Parent.GameEvents)

type PlayerData = Types.PlayerData

export type Drop = {
	Id: string,
	Item: Types.ItemInstance?, -- nil for gold
	Count: number,
	Gold: number,
	Origin: Vector3, -- where it flew out from
	Position: Vector3, -- where it landed
	Expires: number,
	Auto: boolean, -- gold and materials fly to you; gear needs walking over or Interact
}

-- What the owner's client is told about one drop.
export type DropView = {
	Id: string,
	DefId: string, -- "" for gold
	Rarity: string,
	Count: number,
	Gold: number,
	Origin: Vector3,
	Position: Vector3,
	Auto: boolean,
	Unique: string?,
}

local L = Config.Items.Loot

local LootService = {}

local drops: { [Player]: { [string]: Drop } } = {}
local order: { [Player]: { string } } = {} -- oldest first, for the per-player cap
local serial = 0
local random = Random.new()

local function now(): number
	return Workspace:GetServerTimeNow()
end

local function rootOf(player: Player): BasePart?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function weighted<T>(entries: { T }, weightOf: (T) -> number): T?
	local total = 0
	for _, entry in entries do
		total += weightOf(entry)
	end
	if total <= 0 then
		return nil
	end
	local roll = random:NextNumber() * total
	for _, entry in entries do
		roll -= weightOf(entry)
		if roll <= 0 then
			return entry
		end
	end
	return entries[#entries]
end

local function rollRarity(weights: { [string]: number }): string
	local entries = {}
	for _, rarity in Config.Items.RarityOrder do
		local weight = weights[rarity]
		if weight and weight > 0 then
			table.insert(entries, { Id = rarity, Weight = weight })
		end
	end
	local picked = weighted(entries, function(entry): number
		return entry.Weight
	end)
	return if picked then picked.Id else "Common"
end

-- Where a drop lands: scattered round the corpse, on the ground below.
local function landingFor(origin: Vector3, ignore: { Instance }): Vector3
	local angle = random:NextNumber() * math.pi * 2
	local distance = L.ScatterRadius * math.sqrt(random:NextNumber())
	local point = origin + Vector3.new(math.cos(angle) * distance, 0, math.sin(angle) * distance)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore
	local hit = Workspace:Raycast(point + Vector3.new(0, 4, 0), Vector3.new(0, -60, 0), params)
	return if hit then hit.Position + Vector3.new(0, 0.5, 0) else point
end

local function ignoreList(): { Instance }
	local list: { Instance } = {}
	local mobFolder = Workspace:FindFirstChild("Mobs")
	if mobFolder then
		table.insert(list, mobFolder)
	end
	for _, player in Players:GetPlayers() do
		if player.Character then
			table.insert(list, player.Character)
		end
	end
	return list
end

local function view(drop: Drop): DropView
	local item = drop.Item
	return {
		Id = drop.Id,
		DefId = if item then item.DefId else "",
		Rarity = if item then item.Rarity else "Common",
		Count = drop.Count,
		Gold = drop.Gold,
		Origin = drop.Origin,
		Position = drop.Position,
		Auto = drop.Auto,
		Unique = if item then item.Unique else nil,
	}
end

local function removeDrop(player: Player, id: string, collected: boolean)
	local owned = drops[player]
	if owned and owned[id] then
		owned[id] = nil
		local list = order[player]
		local index = list and table.find(list, id)
		if list and index then
			table.remove(list, index)
		end
		Net.Fire("LootRemoved", player, id, collected)
	end
end

-- Creates drops for one player and tells their client (one remote call).
local function spawnDrops(player: Player, origin: Vector3, entries: { { Item: Types.ItemInstance?, Count: number, Gold: number } })
	local owned = drops[player]
	local list = order[player]
	if not owned or not list then
		return
	end
	local ignore = ignoreList()
	local views = {}
	local expires = now() + L.DropLifetime
	for _, entry in entries do
		serial += 1
		local id = tostring(serial)
		local def = if entry.Item then Items.Get(entry.Item.DefId) else nil
		local drop: Drop = {
			Id = id,
			Item = entry.Item,
			Count = entry.Count,
			Gold = entry.Gold,
			Origin = origin + Vector3.new(0, 1.5, 0),
			Position = landingFor(origin, ignore),
			Expires = expires,
			Auto = entry.Gold > 0 or (def ~= nil and def.Type == "Material"),
		}
		owned[id] = drop
		table.insert(list, id)
		table.insert(views, view(drop))
	end
	-- Past the cap the oldest drops dissolve.
	while #list > L.MaxDropsPerPlayer do
		removeDrop(player, list[1], false)
	end
	if #views > 0 then
		Net.Fire("LootDropped", player, views)
	end
end

-- ROLLS -----------------------------------------------------------------------------

type Entry = { Item: Types.ItemInstance?, Count: number, Gold: number }

-- Gear roll with pity, run inside a transaction so the pity count saves with it.
local function rollGear(player: Player, mobTable: any, zone: string, elite: boolean): Types.ItemInstance?
	local zoneTable = Config.Loot.Zones[zone] or Config.Loot.Zones[Config.Loot.DefaultZone]
	local rolled: Types.ItemInstance? = nil
	InventoryService.Transact(player, function(draft: PlayerData): (boolean, string?)
		local kills = (draft.ItemState.Pity[zone] or 0) + 1
		local pity = kills >= Config.Loot.Pity.Kills
		-- Pathfinder tree: LootLuck raises the gear chance (pity is unchanged).
		local chance = (mobTable.GearChance + (if elite then Config.Loot.Elite.GearChanceBonus else 0))
			* (1 + GearService.Bonus(player, "LootLuck"))
		if pity or random:NextNumber() < chance then
			local pick = weighted(zoneTable.Gear, function(entry: any): number
				return entry.Weight
			end)
			if pick then
				local rarity = rollRarity(if elite then Config.Loot.RarityWeights.Elite else Config.Loot.RarityWeights.Normal)
				if pity and Items.RarityRank(rarity) < Items.RarityRank(Config.Loot.Pity.MinRarity) then
					rarity = Config.Loot.Pity.MinRarity
				end
				local item = Rules.NewItem(pick.Id, rarity, random)
				if Items.RarityRank(item.Rarity) >= Items.RarityRank(Config.Loot.Pity.MinRarity) then
					kills = 0
				end
				rolled = item
			end
		end
		draft.ItemState.Pity[zone] = kills
		return true, nil
	end)
	return rolled
end

local function rollFor(player: Player, mobId: string, def: Mobs.MobDef, elite: boolean, zone: string): { Entry }
	local mobTable = Config.Loot.Mobs[mobId] or Config.Loot.Default
	local entries: { Entry } = {}

	local gold = random:NextInteger(def.Rewards.GoldMin, def.Rewards.GoldMax)
		* (if elite then Config.Mobs.Elite.RewardMultiplier else 1)
		* (1 + GearService.Bonus(player, "GoldFind"))
	if gold > 0 then
		table.insert(entries, { Item = nil, Count = 1, Gold = math.floor(gold) })
	end

	-- Materials: merge repeats of the same material into one drop.
	local materials: { [string]: number } = {}
	local rolls = mobTable.MaterialRolls + (if elite then Config.Loot.Elite.MaterialRollBonus else 0)
	for _ = 1, rolls do
		local pick = weighted(mobTable.Materials, function(entry: any): number
			return entry.Weight
		end)
		if pick then
			materials[pick.Id] = (materials[pick.Id] or 0) + random:NextInteger(pick.Min or 1, pick.Max or 1)
		end
	end
	for id, count in materials do
		table.insert(entries, { Item = Rules.NewItem(id, nil, random), Count = count, Gold = 0 })
	end

	local gear = rollGear(player, mobTable, zone, elite)
	if gear then
		table.insert(entries, { Item = gear, Count = 1, Gold = 0 })
	end

	local extras: { any } = mobTable.Extra or {}
	for _, extra in extras do
		if (not extra.EliteOnly or elite) and random:NextNumber() < extra.Chance then
			table.insert(entries, { Item = Rules.NewItem(extra.Id, nil, random), Count = 1, Gold = 0 })
		end
	end
	return entries
end

-- Called by MobService once per death with the players who earned a share.
function LootService.AwardKill(mobId: string, def: Mobs.MobDef, elite: boolean, players: { Player }, position: Vector3, zone: string?)
	local zoneName = if zone and Config.Loot.Zones[zone] then zone else Config.Loot.DefaultZone
	for _, player in players do
		if DataService.IsLoaded(player) then
			spawnDrops(player, position, rollFor(player, mobId, def, elite, zoneName))
		end
	end
end

-- Studio testing (DevHooks): one drop of every rarity around the player.
function LootService.DevDropShowcase(player: Player)
	local root = rootOf(player)
	if not root then
		return
	end
	local entries: { Entry } = { { Item = nil, Count = 1, Gold = 25 } }
	local gear = { "ClimbersLongsword", "HarborCoat", "PearlRing", "Wispfangs", "SaltglassNeedle", "TidekeepersPromise", "TidewardenMail" }
	for index, rarity in Config.Items.RarityOrder do
		table.insert(entries, { Item = Rules.NewItem(gear[index], rarity, random), Count = 1, Gold = 0 })
	end
	table.insert(entries, { Item = Rules.NewItem("IronScrap", nil, random), Count = 4, Gold = 0 })
	table.insert(entries, { Item = Rules.NewItem("TidePearl", nil, random), Count = 2, Gold = 0 })
	spawnDrops(player, root.Position + root.CFrame.LookVector * 8, entries)
end

-- PICKUP -------------------------------------------------------------------------------

local function onPickup(player: Player, id: string)
	local owned = drops[player]
	local drop = owned and owned[id]
	local root = rootOf(player)
	if not drop or not root or not InventoryService.IsAlive(player) then
		return
	end
	local reach = (if drop.Auto then L.AutoPickupRadius else L.InteractRadius) + L.ServerRadiusSlack
	if (root.Position - drop.Position).Magnitude > reach then
		return
	end
	local ok, reason
	if drop.Gold > 0 then
		local landed = 0
		ok, reason = InventoryService.Transact(player, function(draft: PlayerData): (boolean, string?)
			landed = Rules.Earn(draft, "Gold", drop.Gold)
			return true, nil
		end)
		if ok then
			local data = DataService.GetData(player)
			AnalyticsService.Economy(player, "Source", "Gold", landed, if data then data.Currencies.Gold else 0, "Gameplay", "Loot")
			if landed > 0 then
				GameEvents.Fire(player, "Gold", "", landed)
			end
		end
	else
		ok, reason = InventoryService.AddItem(player, drop.Item :: Types.ItemInstance, drop.Count)
	end
	if not ok then
		InventoryService.Result(player, false, reason, { DropId = id })
		return
	end
	local item = drop.Item
	removeDrop(player, id, true)
	InventoryService.Result(player, true, "Pickup", {
		DefId = if item then item.DefId else "",
		Rarity = if item then item.Rarity else "Common",
		Count = drop.Count,
		Gold = drop.Gold,
	})
end

function LootService.Init()
	Net.On("RequestPickup", onPickup)
end

function LootService.Start()
	local function track(player: Player)
		drops[player] = {}
		order[player] = {}
	end
	Players.PlayerAdded:Connect(track)
	for _, player in Players:GetPlayers() do
		track(player)
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		drops[player] = nil
		order[player] = nil
	end)

	-- Expire old drops once a second.
	local accumulator = 0
	RunService.Heartbeat:Connect(function(dt: number)
		accumulator += dt
		if accumulator < 1 then
			return
		end
		accumulator = 0
		local t = now()
		for player, owned in drops do
			for id, drop in owned do
				if t >= drop.Expires then
					removeDrop(player, id, false)
				end
			end
		end
	end)
end

return LootService
