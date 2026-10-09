--!strict
--[[
	ProgressionService
	XP, levels, kill rewards and stat points (Spec Section 9).

	AwardKill: everyone who damaged an enemy and is within
	Progression.PartyXP.ShareRadius when it dies gets its full XP and gold
	(elites give Mobs.Elite.RewardMultiplier times as much). Helpers aren't
	punished for grouping up; party bonuses arrive with parties.

	AddXP: levels up as many times as the XP covers (XP needed per level:
	Formulas.XPToNext). Each level gives StatPointsPerLevel stat points, and
	SkillPointsPerLevel skill points from SkillPointsFromLevel on. Levelling
	up fully heals (LevelUp.FullHeal), shows the toast and a golden-teal
	pillar of light everyone nearby sees (LevelUp remote).

	AwardDiscovery: XP for a first-time discovery (Waystones now; quests,
	dungeons and Guardians add their own sources in later phases).

	RequestAllocateStats: spends stat points (ProgressionRules.AllocateStats
	on a copy, then committed). Positions, the skill tree, abilities and
	respecs live in PositionService.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Net = require(Shared.Net)
local Formulas = require(Shared.Data.Formulas)
local Mobs = require(Shared.Data.Mobs)
local Rules = require(Shared.Data.ProgressionRules)

local DataService = require(script.Parent.DataService)
local VitalsService = require(script.Parent.VitalsService)
local AnalyticsService = require(script.Parent.AnalyticsService)

local P = Config.Progression

local ProgressionService = {}

-- Players near `position` (for the level-up pillar).
local function nearby(position: Vector3, radius: number): { Player }
	local list = {}
	for _, other in Players:GetPlayers() do
		local character = other.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") and (root.Position - position).Magnitude <= radius then
			table.insert(list, other)
		end
	end
	return list
end

local function celebrate(player: Player, level: number, statPoints: number, skillPoints: number, before: number)
	if P.LevelUp.FullHeal then
		VitalsService.RestoreAll(player)
	end
	local key = if skillPoints == 0 then "Toasts.LevelUp" elseif skillPoints == 1 then "Toasts.LevelUpSkill" else "Toasts.LevelUpSkills"
	Net.Fire("Notify", player, key, { level = level, points = statPoints, skill = skillPoints }, "Success")
	local data = DataService.GetData(player)
	if before < P.Positions.UnlockLevel and level >= P.Positions.UnlockLevel and data and data.Position == "" then
		Net.Fire("Notify", player, "Toasts.PositionsUnlocked", { level = level }, "Info")
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if character and root and root:IsA("BasePart") then
		Net.FireList("LevelUp", nearby(root.Position, P.LevelUp.PillarRadius), character, level)
	end
	AnalyticsService.Progression(player, "Level", "Complete", level)
end

-- Points earned between two levels (stat points every level, skill points from SkillPointsFromLevel).
local function pointsBetween(from: number, to: number): (number, number)
	local statPoints, skillPoints = 0, 0
	for level = from + 1, to do
		statPoints += P.StatPointsPerLevel
		if level >= P.SkillPointsFromLevel then
			skillPoints += P.SkillPointsPerLevel
		end
	end
	return statPoints, skillPoints
end

local function applyLevel(player: Player, before: number, level: number)
	local statPoints, skillPoints = pointsBetween(before, level)
	DataService.Increment(player, { "StatPoints" }, statPoints)
	if skillPoints > 0 then
		DataService.Increment(player, { "SkillPoints" }, skillPoints)
	end
	DataService.Set(player, { "Level" }, level)
	celebrate(player, level, statPoints, skillPoints, before)
end

-- Adds XP and applies any level ups. Returns the new level.
function ProgressionService.AddXP(player: Player, amount: number): number
	local data = DataService.GetData(player)
	if not data or amount <= 0 then
		return if data then data.Level else 1
	end
	local before = data.Level
	local level = before
	local xp = data.XP + math.floor(amount)
	while level < P.LevelCap and xp >= Formulas.XPToNext(level) do
		xp -= Formulas.XPToNext(level)
		level += 1
	end
	if level >= P.LevelCap then
		xp = 0 -- nothing left to earn toward
	end
	DataService.Set(player, { "XP" }, xp)
	if level ~= before then
		applyLevel(player, before, level)
	end
	return level
end

-- Studio testing: jump to a level. Going up grants the points those levels
-- would have; going down keeps what was earned (only the number changes).
function ProgressionService.SetLevel(player: Player, level: number): number
	local data = DataService.GetData(player)
	if not data then
		return 1
	end
	level = math.clamp(math.floor(level), 1, P.LevelCap)
	local before = data.Level
	DataService.Set(player, { "XP" }, 0)
	if level > before then
		applyLevel(player, before, level)
	else
		DataService.Set(player, { "Level" }, level)
	end
	return level
end

-- XP for discovering something for the first time.
function ProgressionService.AwardDiscovery(player: Player, kind: "Waystone" | "Secret" | "Cache")
	local data = DataService.GetData(player)
	if not data then
		return
	end
	local base = P.DiscoveryXP[kind] or P.DiscoveryXP.Waystone
	local xp = base + P.DiscoveryXP.PerLevel * data.Level
	Net.Fire("Notify", player, "Toasts.DiscoveryXP", { xp = xp }, "Info")
	ProgressionService.AddXP(player, xp)
end

-- Everyone who helped kill an enemy and is still nearby (they share XP and
-- each get their own personal loot from LootService).
function ProgressionService.KillEligible(contributors: { [Player]: number }, position: Vector3): { Player }
	local list = {}
	for player, damage in contributors do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local near = root ~= nil and root:IsA("BasePart") and (root.Position - position).Magnitude <= P.PartyXP.ShareRadius
		if player.Parent == Players and damage > 0 and near then
			table.insert(list, player)
		end
	end
	return list
end

-- XP for a kill. Gold and items are dropped on the ground by LootService.
function ProgressionService.AwardKill(def: Mobs.MobDef, elite: boolean, players: { Player })
	local multiplier = if elite then Config.Mobs.Elite.RewardMultiplier else 1
	local xp = math.floor(def.Rewards.XP * multiplier)
	for _, player in players do
		DataService.Increment(player, { "PlayStats", "Kills" }, 1)
		Net.Fire("Notify", player, "Toasts.KillRewards", { xp = xp }, "Info")
		ProgressionService.AddXP(player, xp)
	end
end

-- A Floor Guardian felled (GuardianService pays every member who earned a share): its XP,
-- the GuardianKills count and the usual "+XP" toast. Loot, gold and first-clear rewards are
-- GuardianService's.
function ProgressionService.AwardGuardianKill(player: Player, xp: number)
	if not DataService.IsLoaded(player) then
		return
	end
	local amount = math.max(0, math.floor(xp))
	DataService.Increment(player, { "PlayStats", "GuardianKills" }, 1)
	Net.Fire("Notify", player, "Toasts.KillRewards", { xp = amount }, "Info")
	ProgressionService.AddXP(player, amount)
end

-- Extra skill points (a Guardian's first clear).
function ProgressionService.AwardSkillPoints(player: Player, points: number)
	local amount = math.max(0, math.floor(points))
	if amount > 0 and DataService.IsLoaded(player) then
		DataService.Increment(player, { "SkillPoints" }, amount)
	end
end

-- STAT POINTS ------------------------------------------------------------------------

local function result(player: Player, ok: boolean, action: string, reason: string?, payload: { [string]: any }?)
	Net.Fire("ProgressionResult", player, ok, action, reason or "", payload or {})
end

local function onAllocate(player: Player, allocation: { [string]: number })
	local data = DataService.GetData(player)
	if not data then
		result(player, false, "Stats", "NotLoaded")
		return
	end
	-- Run the rule on a copy; nothing changes unless it all checks out.
	local draft = table.clone(data)
	draft.Stats = table.clone(data.Stats)
	local ok, reason = Rules.AllocateStats(draft, allocation)
	if not ok then
		result(player, false, "Stats", reason)
		return
	end
	for _, name in Rules.StatNames do
		local value = (draft.Stats :: any)[name]
		if value ~= (data.Stats :: any)[name] then
			DataService.Set(player, { "Stats", name }, value)
		end
	end
	DataService.Set(player, { "StatPoints" }, draft.StatPoints)
	result(player, true, "Stats", nil, {})
	AnalyticsService.Custom(player, "StatsAllocated")
end

function ProgressionService.Init()
	Net.On("RequestAllocateStats", onAllocate)
end

return ProgressionService
