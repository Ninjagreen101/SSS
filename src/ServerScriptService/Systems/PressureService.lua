--!strict
--[[
	PressureService
	Current Pressure (Spec Section 6): every place has a Pressure level from
	1 to 5 that changes how magic and steel behave there.

	  High Pressure (above Neutral): +SpellPowerPerLevelAboveNeutral spell
	  power per level, faster Current refill.
	  Low Pressure (below Neutral): slower refill, but weapon blows hit harder
	  (LowPressureMeleeBonus) and Siphon draws more Current
	  (LowPressureSiphonCostMultiplier).

	Zones are parts tagged "PressureZone" (or any part inside
	Workspace.PressureZones) with a Pressure attribute 1..5. Where zones
	overlap, the smallest one wins (the most specific place). Outside every
	zone the level is Neutral. Changing a zone's attribute at runtime (a
	Guardian raising the tide) takes effect on the next sample.

	Current sources: parts tagged "CurrentPool" refill PoolRefillPerSecond
	while you stand inside them; parts tagged "CurrentCanal" refill
	CanalRefillPerSecond within CanalRadius.

	Each player's level is sampled every SampleInterval and mirrored to the
	Pressure attribute (the HUD wave icon reads it).
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Attributes = require(Shared.Attributes)

local A = Attributes.Names
local P = Config.Current.Pressure
local R = Config.Current.Regen

local PressureService = {}

type Sample = { Level: number, PerSecond: number }

local samples: { [Player]: Sample } = {}

local function inside(part: BasePart, position: Vector3, margin: number): boolean
	local localPoint = part.CFrame:PointToObjectSpace(position)
	local half = part.Size / 2 + Vector3.one * margin
	return math.abs(localPoint.X) <= half.X and math.abs(localPoint.Y) <= half.Y and math.abs(localPoint.Z) <= half.Z
end

-- Pools and canals are thin water surfaces: a character standing in one has
-- its root part a few studs above the part, so the check reaches up.
local SOURCE_REACH_UP = 6

local function insideColumn(part: BasePart, position: Vector3, margin: number): boolean
	local localPoint = part.CFrame:PointToObjectSpace(position)
	local half = part.Size / 2
	return math.abs(localPoint.X) <= half.X + margin
		and math.abs(localPoint.Z) <= half.Z + margin
		and localPoint.Y >= -half.Y - margin
		and localPoint.Y <= half.Y + SOURCE_REACH_UP
end

local function volume(part: BasePart): number
	return part.Size.X * part.Size.Y * part.Size.Z
end

local function zoneLevel(part: BasePart): number?
	local value = part:GetAttribute(A.Pressure)
	if type(value) ~= "number" then
		return nil
	end
	return math.clamp(math.floor(value + 0.5), P.Min, P.Max)
end

-- Pressure level at a world position.
function PressureService.LevelAt(position: Vector3): number
	local best: BasePart? = nil
	local bestLevel = P.Neutral
	for _, instance in CollectionService:GetTagged(Attributes.Tags.PressureZone) do
		if instance:IsA("BasePart") and instance:IsDescendantOf(Workspace) then
			local level = zoneLevel(instance)
			if level and inside(instance, position, 0) and (best == nil or volume(instance) < volume(best)) then
				best = instance
				bestLevel = level
			end
		end
	end
	return bestLevel
end

-- Current refilled per second by pools and canals at a position.
local function sourcesAt(position: Vector3): number
	local perSecond = 0
	for _, instance in CollectionService:GetTagged(Attributes.Tags.CurrentPool) do
		if instance:IsA("BasePart") and instance:IsDescendantOf(Workspace) and insideColumn(instance, position, 1) then
			perSecond = math.max(perSecond, R.PoolRefillPerSecond)
		end
	end
	if perSecond > 0 then
		return perSecond
	end
	for _, instance in CollectionService:GetTagged(Attributes.Tags.CurrentCanal) do
		if instance:IsA("BasePart") and instance:IsDescendantOf(Workspace) and insideColumn(instance, position, R.CanalRadius) then
			return R.CanalRefillPerSecond
		end
	end
	return 0
end

local function sampleOf(player: Player): Sample
	return samples[player] or { Level = P.Neutral, PerSecond = 0 }
end

-- The Pressure level where this player stands.
function PressureService.Get(player: Player): number
	return sampleOf(player).Level
end

-- Spell power multiplier from Pressure (1 at Neutral and below).
function PressureService.SpellPower(player: Player): number
	return 1 + math.max(0, PressureService.Get(player) - P.Neutral) * P.SpellPowerPerLevelAboveNeutral
end

-- Weapon damage multiplier from Pressure (bonus only in low Pressure).
function PressureService.MeleePower(player: Player): number
	return 1 + (P.LowPressureMeleeBonus[PressureService.Get(player)] or 0)
end

-- Siphon multiplier from Pressure: low Pressure makes Siphon "cheaper", so
-- each weapon hit draws more Current.
function PressureService.SiphonPower(player: Player): number
	local cost = P.LowPressureSiphonCostMultiplier[PressureService.Get(player)] or 1
	return 1 / math.max(0.1, cost)
end

-- Passive Current regeneration multiplier from Pressure.
function PressureService.RegenMultiplier(player: Player): number
	return P.RefillMultiplier[PressureService.Get(player)] or 1
end

-- Extra Current per second from pools and canals where the player stands.
function PressureService.SourceRegen(player: Player): number
	return sampleOf(player).PerSecond
end

-- Sets a zone's Pressure (Guardian arenas shift it between phases).
function PressureService.SetZonePressure(zone: BasePart, level: number)
	zone:SetAttribute(A.Pressure, math.clamp(math.floor(level + 0.5), P.Min, P.Max))
end

local function sampleAll()
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			local sample = { Level = PressureService.LevelAt(root.Position), PerSecond = sourcesAt(root.Position) }
			samples[player] = sample
			if player:GetAttribute(A.Pressure) ~= sample.Level then
				player:SetAttribute(A.Pressure, sample.Level)
			end
		end
	end
end

local function tagFolder()
	local folder = Workspace:FindFirstChild("PressureZones")
	if not folder then
		return
	end
	local function tag(instance: Instance)
		if instance:IsA("BasePart") and not CollectionService:HasTag(instance, Attributes.Tags.PressureZone) then
			CollectionService:AddTag(instance, Attributes.Tags.PressureZone)
		end
	end
	for _, descendant in folder:GetDescendants() do
		tag(descendant)
	end
	folder.DescendantAdded:Connect(tag)
end

function PressureService.Start()
	tagFolder()
	Players.PlayerAdded:Connect(function(player: Player)
		player:SetAttribute(A.Pressure, P.Neutral)
	end)
	for _, player in Players:GetPlayers() do
		player:SetAttribute(A.Pressure, P.Neutral)
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		samples[player] = nil
	end)
	local accumulator = 0
	RunService.Heartbeat:Connect(function(dt: number)
		accumulator += dt
		if accumulator >= P.SampleInterval then
			accumulator = 0
			sampleAll()
		end
	end)
end

return PressureService
