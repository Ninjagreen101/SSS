--!strict
--[[
	Navigator
	Moves a mob toward a goal. If nothing blocks the straight line it walks
	there directly (cheap); otherwise it follows a PathfindingService path,
	recomputed at most every Mobs.AI.PathRecomputeInterval seconds or when
	the goal has moved more than Movement.RepathDistance.
]]

local PathfindingService = game:GetService("PathfindingService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)

local StatusService = require(script.Parent.Parent.StatusService)
local Types = require(script.Parent.Types)

local AI = Config.Mobs.AI
local MOVE = Config.Mobs.Movement

local Navigator = {}

local obstacleParams = RaycastParams.new()
obstacleParams.FilterType = Enum.RaycastFilterType.Exclude
obstacleParams.IgnoreWater = true
obstacleParams.RespectCanCollide = true

local function now(): number
	return Workspace:GetServerTimeNow()
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

-- Characters and mobs never count as walls.
function Navigator.SetIgnored(list: { Instance })
	obstacleParams.FilterDescendantsInstances = list
end

function Navigator.New(scale: number): Types.NavState
	local path = PathfindingService:CreatePath({
		AgentRadius = 2 * scale,
		AgentHeight = 5 * scale,
		AgentCanJump = false,
		AgentCanClimb = false,
		WaypointSpacing = 6,
	})
	return {
		Path = path,
		Waypoints = {},
		Index = 1,
		Goal = nil,
		ComputedAt = -math.huge,
		Computing = false,
	}
end

-- True if a mob can walk straight to `goal` (no wall at knee and chest height).
function Navigator.ClearLine(mob: Types.Mob, goal: Vector3): boolean
	local root = mob.Root
	local feet = root.Position - Vector3.new(0, mob.Humanoid.HipHeight + root.Size.Y / 2, 0)
	local offset = flat(goal - root.Position)
	if offset.Magnitude < 0.5 then
		return true
	end
	for _, height in { MOVE.ObstacleCheckHeight, MOVE.ObstacleCheckHeight * 2.5 } do
		local origin = feet + Vector3.new(0, height, 0)
		if Workspace:Raycast(origin, offset, obstacleParams) then
			return false
		end
	end
	return true
end

local function compute(mob: Types.Mob, goal: Vector3)
	local nav = mob.Nav
	nav.Computing = true
	nav.Goal = goal
	local start = mob.Root.Position
	task.spawn(function()
		local ok = pcall(function()
			nav.Path:ComputeAsync(start, goal)
		end)
		nav.Computing = false
		nav.ComputedAt = now()
		if mob.Dead then
			return
		end
		if ok and nav.Path.Status == Enum.PathStatus.Success then
			nav.Waypoints = nav.Path:GetWaypoints()
			nav.Index = 2 -- the first waypoint is where the mob already stands
		else
			nav.Waypoints = {}
			nav.Index = 1
		end
	end)
end

-- Walk toward `goal` at `speed` (slowed or stopped by statuses). Call every
-- think; it's cheap when the way is clear.
function Navigator.MoveTo(mob: Types.Mob, goal: Vector3, speed: number)
	local humanoid = mob.Humanoid
	humanoid.WalkSpeed = speed * StatusService.SpeedMultiplier(mob.Model)
	local nav = mob.Nav
	if Navigator.ClearLine(mob, goal) then
		nav.Waypoints = {}
		nav.Goal = goal
		humanoid:MoveTo(goal)
		return
	end
	local t = now()
	local stale = not nav.Goal or (nav.Goal - goal).Magnitude > MOVE.RepathDistance or #nav.Waypoints == 0
	if stale and not nav.Computing and t - nav.ComputedAt >= AI.PathRecomputeInterval then
		compute(mob, goal)
	end
	local position = mob.Root.Position
	local waypoint = nav.Waypoints[nav.Index]
	while waypoint and flat(waypoint.Position - position).Magnitude <= MOVE.WaypointReach do
		nav.Index += 1
		waypoint = nav.Waypoints[nav.Index]
	end
	-- No path yet (or none exists): head straight for the goal and let the
	-- next path, or the wall, sort it out.
	humanoid:MoveTo(if waypoint then waypoint.Position else goal)
end

function Navigator.Stop(mob: Types.Mob)
	local humanoid = mob.Humanoid
	humanoid:Move(Vector3.zero)
	humanoid:MoveTo(mob.Root.Position)
	mob.Nav.Waypoints = {}
end

return Navigator
