--!strict
--[[
	ProjectileService
	Server-simulated projectiles for everyone: mob brine bolts and players'
	Bolt spells. Each step sweeps a sphere along the path. The first combat
	target of the other team it touches is passed to the projectile's OnHit;
	world geometry stops it. Characters and mobs of the shooter's own team
	are ignored, so bolts fly through allies.

	OnHit returns true to keep flying (the target dodged: it's then ignored
	for the rest of the flight), false to stop.

	Clients draw projectiles from the Projectile remote ("Spawn" with the
	path and colour, "End" where it stopped).

	Big bodies (targets with a hit size) are also hit when the path passes
	within the projectile's radius of their hit capsule, even where their
	parts are thinner than the capsule.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Net = require(Shared.Net)

local TargetService = require(script.Parent.TargetService)

local P = Config.Mobs.Projectile

export type Shot = {
	Owner: Model,
	Team: TargetService.Team, -- the shooter's team; only the other team is hit
	Origin: Vector3,
	Direction: Vector3,
	Speed: number,
	Radius: number,
	Range: number,
	Color: Color3,
	OnHit: (target: Model, position: Vector3) -> boolean,
}

type Bolt = {
	Id: number,
	Shot: Shot,
	Position: Vector3,
	Velocity: Vector3,
	Remaining: number,
	Expires: number,
	Params: RaycastParams,
	Ignore: { Instance },
}

local ProjectileService = {}

local bolts: { [number]: Bolt } = {}
local nextId = 0

local function now(): number
	return Workspace:GetServerTimeNow()
end

local function playersNear(position: Vector3, radius: number): { Player }
	local list = {}
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if root and (root.Position - position).Magnitude <= radius then
			table.insert(list, player)
		end
	end
	return list
end

local function audience(bolt: Bolt): { Player }
	return playersNear(bolt.Position, bolt.Remaining + Config.Combat.FeedbackRadius)
end

-- Everything on the shooter's team (and the shooter) is see-through.
local function teamIgnoreList(team: TargetService.Team, owner: Model): { Instance }
	local list: { Instance } = { owner }
	for model, target in TargetService.GetAll() do
		if target.Team == team then
			table.insert(list, model)
		end
	end
	return list
end

local function finish(bolt: Bolt, position: Vector3)
	bolts[bolt.Id] = nil
	Net.FireList("Projectile", audience(bolt), "End", bolt.Id, position)
end

-- The combat target a hit part belongs to, if any.
local function targetOf(part: Instance): Model?
	local model = part:FindFirstAncestorOfClass("Model")
	while model do
		if TargetService.Get(model) then
			return model
		end
		model = model:FindFirstAncestorOfClass("Model")
	end
	return nil
end

-- The first big body (a target with a hit size) on the other team whose hit
-- capsule this step's path passes within the projectile's radius of, and how
-- far along the path the projectile reaches it. Targets without a hit size
-- are left to the spherecast.
local function bigBodyOnPath(bolt: Bolt, travel: Vector3): (Model?, number)
	local length = travel.Magnitude
	if length <= 1e-6 then
		return nil, 0
	end
	local from = bolt.Position
	local direction = travel / length
	local best: Model? = nil
	local bestDistance = math.huge
	for model, target in TargetService.GetAll() do
		if
			(target.HitRadius > 0 or target.HitHeight > 0)
			and target.Team ~= bolt.Shot.Team
			and TargetService.IsAlive(target)
			and not table.find(bolt.Ignore, model)
		then
			local point = TargetService.AxisPointToSegment(target, from, from + travel)
			local along = math.clamp((point - from):Dot(direction), 0, length)
			local miss = (point - (from + direction * along)).Magnitude
			local reach = bolt.Shot.Radius + target.HitRadius
			if miss <= reach then
				-- Back up to where the sphere first touches the capsule.
				local distance = math.max(0, along - math.sqrt(reach * reach - miss * miss))
				if distance < bestDistance then
					best = model
					bestDistance = distance
				end
			end
		end
	end
	return best, bestDistance
end

function ProjectileService.Fire(shot: Shot)
	nextId += 1
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true
	local ignore = teamIgnoreList(shot.Team, shot.Owner)
	params.FilterDescendantsInstances = ignore
	local direction = if shot.Direction.Magnitude > 0.001 then shot.Direction.Unit else Vector3.new(0, 0, -1)
	local bolt: Bolt = {
		Id = nextId,
		Shot = shot,
		Position = shot.Origin,
		Velocity = direction * shot.Speed,
		Remaining = shot.Range,
		Expires = now() + P.MaxLifetime,
		Params = params,
		Ignore = ignore,
	}
	bolts[bolt.Id] = bolt
	Net.FireList("Projectile", audience(bolt), "Spawn", bolt.Id, shot.Origin, bolt.Velocity, shot.Radius, shot.Range, shot.Color)
end

local function step(bolt: Bolt, dt: number)
	if now() >= bolt.Expires or bolt.Remaining <= 0 then
		finish(bolt, bolt.Position)
		return
	end
	local travel = bolt.Velocity * dt
	if travel.Magnitude > bolt.Remaining then
		travel = travel.Unit * bolt.Remaining
	end
	local result = Workspace:Spherecast(bolt.Position, bolt.Shot.Radius, travel, bolt.Params)
	local body, bodyDistance = bigBodyOnPath(bolt, travel)
	local target: Model?
	local distance: number
	if body and (not result or bodyDistance < result.Distance) then
		target = body
		distance = bodyDistance
	elseif result then
		target = targetOf(result.Instance)
		distance = result.Distance
	else
		bolt.Position += travel
		bolt.Remaining -= travel.Magnitude
		return
	end
	local contact = bolt.Position + travel.Unit * distance
	if target then
		local info = TargetService.Get(target)
		if info and info.Team ~= bolt.Shot.Team and bolt.Shot.OnHit(target, contact) then
			-- Dodged: fly on, and never hit them again.
			table.insert(bolt.Ignore, target)
			bolt.Params.FilterDescendantsInstances = bolt.Ignore
			bolt.Position = contact
			bolt.Remaining -= distance
			return
		end
	end
	finish(bolt, contact)
end

function ProjectileService.Start()
	local interval = 1 / P.StepRate
	local accumulator = 0
	RunService.Heartbeat:Connect(function(dt: number)
		accumulator += dt
		if accumulator < interval then
			return
		end
		local elapsed = accumulator
		accumulator = 0
		for _, bolt in bolts do
			step(bolt, elapsed)
		end
	end)
end

return ProjectileService
