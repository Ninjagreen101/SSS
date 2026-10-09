--!strict
--[[
	TargetService
	One registry of everything that can be hit: player characters now,
	training dummies now, enemies from Phase 4. Combat code never cares what
	a target is; it asks this service.

	- Register(model, kind, team, player?) tags the model "CombatTarget" and
	  sets its Team attribute so clients can lock on to enemies only.
	- Position history: every target's root position is sampled
	  HistoryRate times a second and kept for HistorySeconds. Hit checks
	  "rewind" targets to where the attacking player saw them (their ping,
	  capped at MaxRewind), so laggy players still land fair hits.
	- ApplyDamage routes player damage through VitalsService (one owner for
	  player health) and everything else straight to the Humanoid.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Attributes = require(Shared.Attributes)
local Signal = require(Shared.Util.Signal)

local VitalsService = require(script.Parent.VitalsService)

local A = Attributes.Names
local V = Config.Combat.HitValidation

export type Kind = "Player" | "Dummy" | "Mob"
export type Team = "Players" | "Enemies"

type Sample = { Time: number, Position: Vector3 }

export type Target = {
	Model: Model,
	Humanoid: Humanoid,
	Root: BasePart,
	Kind: Kind,
	Team: Team,
	Player: Player?,
	History: { Sample },
	HistoryIndex: number,
	Connections: { RBXScriptConnection },
}

local TargetService = {}

TargetService.Registered = Signal.new() :: Signal.Signal<Target>
TargetService.Removed = Signal.new() :: Signal.Signal<Target>

local targets: { [Model]: Target } = {}
local HISTORY_SIZE = math.ceil(V.HistorySeconds * V.HistoryRate) + 2

local function now(): number
	return Workspace:GetServerTimeNow()
end

local function record(target: Target)
	target.HistoryIndex = target.HistoryIndex % HISTORY_SIZE + 1
	target.History[target.HistoryIndex] = { Time = now(), Position = target.Root.Position }
end

-- PUBLIC API -----------------------------------------------------------------

function TargetService.Register(model: Model, kind: Kind, team: Team, player: Player?): Target?
	local existing = targets[model]
	if existing then
		return existing
	end
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local root = (model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart) :: BasePart?
	if not humanoid or not root then
		return nil
	end
	local target: Target = {
		Model = model,
		Humanoid = humanoid,
		Root = root,
		Kind = kind,
		Team = team,
		Player = player,
		History = {},
		HistoryIndex = 0,
		Connections = {},
	}
	targets[model] = target
	record(target)
	model:SetAttribute(A.Team, team)
	CollectionService:AddTag(model, Attributes.Tags.CombatTarget)
	table.insert(target.Connections, model.AncestryChanged:Connect(function()
		if not model:IsDescendantOf(Workspace) then
			TargetService.Unregister(model)
		end
	end))
	TargetService.Registered:Fire(target)
	return target
end

function TargetService.Unregister(model: Model)
	local target = targets[model]
	if not target then
		return
	end
	targets[model] = nil
	for _, connection in target.Connections do
		connection:Disconnect()
	end
	if model.Parent then
		CollectionService:RemoveTag(model, Attributes.Tags.CombatTarget)
	end
	TargetService.Removed:Fire(target)
end

function TargetService.Get(model: Model): Target?
	return targets[model]
end

function TargetService.GetForPlayer(player: Player): Target?
	local character = player.Character
	return if character then targets[character] else nil
end

function TargetService.GetAll(): { [Model]: Target }
	return targets
end

function TargetService.IsAlive(target: Target): boolean
	return target.Humanoid.Health > 0 and target.Model.Parent ~= nil
end

-- Where the target's root was at server time `time` (interpolated).
function TargetService.PositionAt(target: Target, time: number): Vector3
	local history = target.History
	local newest: Sample? = nil
	local older: Sample? = nil
	local newer: Sample? = nil
	for _, sample in history do
		if not newest or sample.Time > newest.Time then
			newest = sample
		end
		if sample.Time <= time and (not older or sample.Time > older.Time) then
			older = sample
		end
		if sample.Time >= time and (not newer or sample.Time < newer.Time) then
			newer = sample
		end
	end
	if older and newer and newer.Time > older.Time then
		local alpha = (time - older.Time) / (newer.Time - older.Time)
		return older.Position:Lerp(newer.Position, alpha)
	end
	local sample = older or newer or newest
	return if sample then sample.Position else target.Root.Position
end

-- How far back to rewind targets for a hit thrown by this attacker.
function TargetService.RewindFor(attacker: Target): number
	local player = attacker.Player
	if not player then
		return 0
	end
	local ok, ping = pcall(function()
		return player:GetNetworkPing()
	end)
	-- The attacker saw targets one trip ago and their request took another trip
	-- to arrive, so their view is about one round trip (GetNetworkPing) old.
	return if ok and type(ping) == "number" then math.clamp(ping, 0, V.MaxRewind) else 0
end

-- Applies already-mitigated damage. Returns the damage actually dealt.
function TargetService.ApplyDamage(target: Target, amount: number): number
	if amount <= 0 or not TargetService.IsAlive(target) then
		return 0
	end
	local player = target.Player
	if player then
		return VitalsService.Damage(player, amount)
	end
	local humanoid = target.Humanoid
	local applied = math.min(amount, humanoid.Health)
	humanoid.Health -= applied
	return applied
end

function TargetService.Start()
	local interval = 1 / V.HistoryRate
	local accumulator = 0
	RunService.Heartbeat:Connect(function(dt: number)
		accumulator += dt
		if accumulator < interval then
			return
		end
		accumulator = 0
		for _, target in targets do
			if target.Root.Parent then
				record(target)
			end
		end
	end)
end

return TargetService
