--!strict
--[[
	PositionService
	Positions, the skill tree, the ability key and respecs (Spec Section 9),
	decided on the server. Every request runs the shared rule
	(Shared/Data/ProgressionRules) on a copy of the profile and commits it
	only if it passes, then answers with ProgressionResult(ok, action,
	reason, payload) for the client's toasts.

	  RequestChoosePosition(id, stationId)  at the Hall of Positions (a station
	                                       with StationKind "Positions"), level 15+
	  RequestUnlockNode(nodeId)            spend skill points on a connected node
	  RequestEquipAbility(abilityId)       put an unlocked ability on the key
	  RequestRespec(changePosition)        out of combat; gold = GoldPerLevel x level
	                                       (first one free)
	  RequestAbility(aim)                  cast the equipped ability: a Move run by
	                                       ArtService.StartMove (Kind "Ability"),
	                                       cooldown mirrored to AbilityReadyAt

	On load, ProgressionRules.Repair refunds nodes an update removed or
	disconnected, so changing tree data never strands a profile.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Attributes = require(Shared.Attributes)
local Types = require(Shared.Types)
local Net = require(Shared.Net)
local Rules = require(Shared.Data.ProgressionRules)
local Positions = require(Shared.Data.Positions)
local Abilities = require(Shared.Data.Abilities)
local Formulas = require(Shared.Data.Formulas)

local Systems = script.Parent
local DataService = require(Systems.DataService)
local GearService = require(Systems.GearService)
local CombatService = require(Systems.CombatService)
local EconomyService = require(Systems.EconomyService)
local ArtService = require(Systems.ArtService)
local AnalyticsService = require(Systems.AnalyticsService)

type PlayerData = Types.PlayerData

local A = Attributes.Names
local P = Config.Progression

local PositionService = {}

local readyAt: { [Player]: number } = {}

local function now(): number
	return Workspace:GetServerTimeNow()
end

local function result(player: Player, ok: boolean, action: string, reason: string?, payload: { [string]: any }?)
	Net.Fire("ProgressionResult", player, ok, action, reason or "", payload or {})
end

-- A copy of everything these rules may change.
local function draftOf(data: PlayerData): PlayerData
	local draft = table.clone(data)
	draft.Stats = table.clone(data.Stats)
	draft.SkillTree = table.clone(data.SkillTree)
	draft.Hotbar = table.clone(data.Hotbar)
	draft.Currencies = table.clone(data.Currencies)
	return draft
end

local function sameSet(a: { [string]: boolean }, b: { [string]: boolean }): boolean
	for key, value in a do
		if b[key] ~= value then
			return false
		end
	end
	for key, value in b do
		if a[key] ~= value then
			return false
		end
	end
	return true
end

-- Writes whatever the draft changed back to the live profile (and replicates it).
local function commit(player: Player, data: PlayerData, draft: PlayerData)
	for _, field in { "StatPoints", "SkillPoints", "Position", "RespecCount" } do
		if (draft :: any)[field] ~= (data :: any)[field] then
			DataService.Set(player, { field }, (draft :: any)[field])
		end
	end
	for _, name in Rules.StatNames do
		local value = (draft.Stats :: any)[name]
		if value ~= (data.Stats :: any)[name] then
			DataService.Set(player, { "Stats", name }, value)
		end
	end
	if not sameSet(draft.SkillTree, data.SkillTree) then
		DataService.Set(player, { "SkillTree" }, draft.SkillTree)
	end
	if draft.Hotbar.Ability ~= data.Hotbar.Ability then
		DataService.Set(player, { "Hotbar", "Ability" }, draft.Hotbar.Ability)
	end
	if draft.Currencies.Gold ~= data.Currencies.Gold then
		DataService.Set(player, { "Currencies", "Gold" }, draft.Currencies.Gold)
	end
end

local function inCombat(player: Player): boolean
	local last = player:GetAttribute(A.LastCombat)
	return type(last) == "number" and now() - last < Config.Combat.Vitals.CombatTimeout
end

-- REQUESTS ---------------------------------------------------------------------------

local function onChoose(player: Player, positionId: string, stationId: string)
	local data = DataService.GetData(player)
	if not data then
		result(player, false, "Choose", "NotLoaded")
		return
	end
	local station = EconomyService.StationFor(player, stationId)
	if not station or EconomyService.KindOf(station) ~= P.Positions.StationKind then
		result(player, false, "Choose", "Distance")
		return
	end
	local draft = draftOf(data)
	local ok, reason = Rules.ChoosePosition(draft, positionId)
	if not ok then
		result(player, false, "Choose", reason, { level = P.Positions.UnlockLevel })
		return
	end
	commit(player, data, draft)
	result(player, true, "Choose", nil, { Position = positionId })
	AnalyticsService.Progression(player, `Position{positionId}`, "Complete", data.Level)
end

local function onUnlock(player: Player, nodeId: string)
	local data = DataService.GetData(player)
	if not data then
		result(player, false, "Unlock", "NotLoaded")
		return
	end
	local draft = draftOf(data)
	local ok, reason = Rules.Unlock(draft, nodeId)
	if not ok then
		result(player, false, "Unlock", reason)
		return
	end
	commit(player, data, draft)
	result(player, true, "Unlock", nil, { Node = nodeId })
	AnalyticsService.Custom(player, "SkillNodeUnlocked")
end

local function onEquip(player: Player, abilityId: string)
	local data = DataService.GetData(player)
	if not data then
		result(player, false, "Equip", "NotLoaded")
		return
	end
	local draft = draftOf(data)
	local ok, reason = Rules.EquipAbility(draft, abilityId)
	if not ok then
		result(player, false, "Equip", reason)
		return
	end
	commit(player, data, draft)
	result(player, true, "Equip", nil, { Ability = abilityId })
end

local function onRespec(player: Player, changePosition: boolean)
	local data = DataService.GetData(player)
	if not data then
		result(player, false, "Respec", "NotLoaded")
		return
	end
	if inCombat(player) then
		result(player, false, "Respec", "Combat")
		return
	end
	local cost = Rules.RespecCost(data)
	local draft = draftOf(data)
	local ok, reason = Rules.Respec(draft, changePosition)
	if not ok then
		result(player, false, "Respec", reason)
		return
	end
	commit(player, data, draft)
	PositionService.ResetCooldown(player)
	if cost > 0 then
		AnalyticsService.Economy(player, "Sink", "Gold", cost, draft.Currencies.Gold, "Respec")
	end
	result(player, true, "Respec", nil, { Cost = cost })
	AnalyticsService.Custom(player, "Respec", draft.RespecCount)
end

-- Damage of a 1.0 step: weapon power blended toward spell power by DensityShare.
local function powerFor(player: Player, def: Abilities.AbilityDef): number
	local weaponDamage = CombatService.GetWeaponPower(player)
	local spellPower = Formulas.SpellPower(GearService.GetStats(player).Density)
	local blend = 1 - def.DensityShare + def.DensityShare * spellPower
	return weaponDamage * blend * (1 + GearService.Bonus(player, "AbilityPower"))
end

local function onAbility(player: Player, aim: Vector3)
	local data = DataService.GetData(player)
	if not data then
		return
	end
	local abilityId = data.Hotbar.Ability
	local def = if abilityId ~= "" then Abilities.Get(abilityId) else nil
	local node = if def then Positions.AbilityNode(def.Id) else nil
	-- The key only casts what the tree really unlocked for this Position.
	if not def or not node or node.Position ~= data.Position or not data.SkillTree[node.Id] then
		Net.Fire("ActionRejected", player, "Ability", "NoAbility")
		return
	end
	local t = now()
	if (readyAt[player] or 0) > t + Config.Combat.HitValidation.TimingTolerance then
		Net.Fire("ActionRejected", player, "Ability", "Cooldown")
		return
	end
	local element: string? = nil
	if def.Element == "Primary" and data.Attunements.Primary ~= "" then
		element = data.Attunements.Primary
	end
	if ArtService.StartMove(player, "Ability", def.Id, def.Move, aim, powerFor(player, def), element, def.Cost) then
		local cooldown = math.max(P.Abilities.MinCooldown, def.Cooldown * (1 - GearService.Bonus(player, "AbilityCooldown")))
		readyAt[player] = t + cooldown
		player:SetAttribute(A.AbilityReadyAt, readyAt[player])
		AnalyticsService.Custom(player, `Ability{def.Id}`)
	end
end

-- Clears the ability cooldown (respec, Studio testing).
function PositionService.ResetCooldown(player: Player)
	readyAt[player] = 0
	player:SetAttribute(A.AbilityReadyAt, 0)
end

-- LIFECYCLE --------------------------------------------------------------------------

local function repair(player: Player, data: PlayerData)
	local draft = draftOf(data)
	if Rules.Repair(draft) then
		commit(player, data, draft)
	end
end

function PositionService.Init()
	Net.On("RequestChoosePosition", onChoose)
	Net.On("RequestUnlockNode", onUnlock)
	Net.On("RequestEquipAbility", onEquip)
	Net.On("RequestRespec", onRespec)
	Net.On("RequestAbility", onAbility)
end

function PositionService.Start()
	DataService.ProfileLoaded:Connect(repair)
	for _, player in Players:GetPlayers() do
		local data = DataService.GetData(player)
		if data then
			repair(player, data)
		end
		player:SetAttribute(A.AbilityReadyAt, 0)
	end
	Players.PlayerAdded:Connect(function(player: Player)
		player:SetAttribute(A.AbilityReadyAt, 0)
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		readyAt[player] = nil
	end)
end

return PositionService
