--!strict
--[[
	NpcService
	The town's people (docs/PHASE11_QUESTS.md sections 2 and 3; Shared.Data.Npcs).

	- Bodies: for every NPC of this floor with a marker in Workspace.Floor<N>.Npcs (a Part with
	  attribute NpcId, built by Tools.Floor1Npcs; its LookVector is where the NPC faces), an R15
	  rig is made from a HumanoidDescription in the NPC's colours and scale, dressed with its
	  Extras (MobService.Builder's welded detail parts), tagged SpireNpc with attribute NpcId, and
	  stood on the ground under the marker in Workspace.SpireNpcs. NPCs don't collide with players
	  (collision group "Npcs") and play Roblox's standard idle and walk animations.
	- Behaviour, every Config.Quests.Npcs.ThinkSeconds:
	    Stand / Work  stay on the spot (walk back if displaced) and face the nearest player within
	                  FaceRadius, else the marker's direction.
	    Route         walk the points of Npcs.Route_<id> (by attribute Order, else name) in a loop,
	                  pausing PauseSeconds at each; a walker that stops making headway is placed on
	                  its next point. With fewer than two points it stands.
	  Anyone who opens an NPC's dialogue (the Talk prompt, or RequestTalk through QuestService)
	  holds it for TalkHoldSeconds: it stops and faces them.
	- Talk prompt: a Custom-style ProximityPrompt (ActionText Strings.QuestUI.Talk, ObjectText the
	  NPC's name). The client opens the dialogue and sends RequestTalk; the server only holds the
	  NPC here.
	- IsNear(player, npcId) is the distance check QuestService uses for Talk, Accept and TurnIn
	  (Config.Quests.TalkRadius from the NPC's body). Missing markers are reported once and those
	  NPCs simply don't exist (IsNear is false for them).
]]

local CollectionService = game:GetService("CollectionService")
local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Attributes = require(Shared.Attributes)
local Strings = require(Shared.Strings)
local Log = require(Shared.Util.Log)
local Npcs = require(Shared.Data.Npcs)

local FloorService = require(script.Parent.FloorService)
local Builder = require(script.Parent.MobService.Builder)

local A = Attributes.Names
local NPC = Config.Quests.Npcs
local LOCOMOTION = Config.Mobs.Locomotion
local log = Log.new("NpcService")

local GROUP = "Npcs"
local PLAYER_GROUP = "Players" -- CharacterService's group for player characters
local MODEL_FOLDER = "SpireNpcs"
local ROUTE_PREFIX = "Route_"
local ORDER_ATTRIBUTE = "Order" -- route points (Tools.Floor1Npcs)
local ARRIVE_DISTANCE = 2.5 -- studs: a walker this close to its point has arrived
local REISSUE_SECONDS = 4 -- Humanoid:MoveTo gives up after 8 s, so long legs are re-sent
local FALL_DEPTH = 60 -- studs below its spot: something went wrong, put it back
local RESPAWN_SECONDS = 5

type Npc = {
	Id: string,
	Def: Npcs.NpcDef,
	Marker: BasePart,
	Model: Model,
	Root: BasePart,
	Humanoid: Humanoid,
	Align: AlignOrientation,
	Height: number, -- root centre above the ground
	Home: CFrame, -- root CFrame on its spot
	Route: { Vector3 }, -- walk points on the ground; empty = it stands
	Leg: number, -- the route point it is heading for
	PauseUntil: number,
	MoveIssued: number,
	Target: Vector3?,
	BestDistance: number,
	ProgressAt: number,
	HoldUntil: number,
	HoldPlayer: Player?,
	Walking: boolean,
	DeadSince: number?,
	Connections: { RBXScriptConnection },
}

local NpcService = {}

local npcs: { [string]: Npc } = {}
local modelFolder: Folder
local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Exclude
groundParams.IgnoreWater = true

local function now(): number
	return Workspace:GetServerTimeNow()
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function flatDistance(a: Vector3, b: Vector3): number
	return flat(a - b).Magnitude
end

local function rootOf(player: Player): BasePart?
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if humanoid and humanoid.Health > 0 and root and root:IsA("BasePart") then
		return root
	end
	return nil
end

local function markerFolder(): Instance?
	local floor = Workspace:FindFirstChild(`Floor{FloorService.GetFloorId()}`)
	return if floor then floor:FindFirstChild("Npcs") else nil
end

-- Ground height under a marker (markers sit just above it and can't be hit by rays).
local function groundUnder(position: Vector3): number
	local exclude: { Instance } = { modelFolder }
	local mobs = Workspace:FindFirstChild("Mobs")
	if mobs then
		table.insert(exclude, mobs)
	end
	for _, player in Players:GetPlayers() do
		if player.Character then
			table.insert(exclude, player.Character)
		end
	end
	groundParams.FilterDescendantsInstances = exclude
	local hit = Workspace:Raycast(position + Vector3.new(0, 2, 0), Vector3.new(0, -8, 0), groundParams)
	return if hit then hit.Position.Y else position.Y
end

-- Route points in walking order (attribute Order, else the part's name).
local function routeOf(folder: Instance, id: string): { Vector3 }
	local route = folder:FindFirstChild(ROUTE_PREFIX .. id)
	if not route then
		return {}
	end
	local points: { { Order: number, Position: Vector3 } } = {}
	for _, child in route:GetChildren() do
		if child:IsA("BasePart") then
			local order = child:GetAttribute(ORDER_ATTRIBUTE)
			local index = if type(order) == "number" then order else tonumber(child.Name)
			if index then
				table.insert(points, { Order = index, Position = child.Position })
			end
		end
	end
	table.sort(points, function(a: { Order: number, Position: Vector3 }, b: { Order: number, Position: Vector3 }): boolean
		return a.Order < b.Order
	end)
	local out: { Vector3 } = {}
	for _, point in points do
		table.insert(out, point.Position)
	end
	return out
end

-- BODY ---------------------------------------------------------------------------------------

local function buildBody(id: string, def: Npcs.NpcDef): Model
	local look = def.Look
	local description = Instance.new("HumanoidDescription")
	description.HeadColor = look.Skin
	description.TorsoColor = look.Torso
	description.LeftArmColor = look.Arms
	description.RightArmColor = look.Arms
	description.LeftLegColor = look.Legs
	description.RightLegColor = look.Legs
	local model = Players:CreateHumanoidModelFromDescription(description, Enum.HumanoidRigType.R15)
	description:Destroy()
	model.Name = id
	-- Driven from here; no scripts inside.
	for _, item in model:GetDescendants() do
		if item:IsA("LuaSourceContainer") then
			item:Destroy()
		end
	end
	if math.abs(look.Scale - 1) > 1e-3 then
		model:ScaleTo(look.Scale)
	end
	for _, spec in look.Extras do
		Builder.AddExtra(model, spec, look.Scale)
	end
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			part.CollisionGroup = GROUP
		end
	end

	local humanoid = model:FindFirstChildOfClass("Humanoid") :: Humanoid
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	humanoid.NameDisplayDistance = 0
	humanoid.BreakJointsOnDeath = false
	humanoid.WalkSpeed = NPC.WalkSpeed
	for _, state in { Enum.HumanoidStateType.Climbing, Enum.HumanoidStateType.Swimming, Enum.HumanoidStateType.Seated, Enum.HumanoidStateType.FallingDown, Enum.HumanoidStateType.Ragdoll } do
		humanoid:SetStateEnabled(state, false)
	end
	if not humanoid:FindFirstChildOfClass("Animator") then
		Instance.new("Animator").Parent = humanoid
	end
	model:SetAttribute(A.NpcId, id)
	model.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
	return model
end

local function loadTrack(humanoid: Humanoid, animationId: string, priority: Enum.AnimationPriority): AnimationTrack?
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator or animationId == "" then
		return nil
	end
	local animation = Instance.new("Animation")
	animation.AnimationId = animationId
	local ok, track = pcall(function(): AnimationTrack
		return animator:LoadAnimation(animation)
	end)
	if not ok then
		return nil
	end
	track.Priority = priority
	track.Looped = true
	return track
end

-- Idle when still, walk when moving (played on the server; Animator replicates it).
local function animate(npc: Npc)
	local humanoid = npc.Humanoid
	local idle = loadTrack(humanoid, LOCOMOTION.Idle, Enum.AnimationPriority.Idle)
	local walk = loadTrack(humanoid, LOCOMOTION.Walk, Enum.AnimationPriority.Movement)
	if idle then
		idle:Play()
	end
	table.insert(
		npc.Connections,
		humanoid.Running:Connect(function(speed: number)
			if not walk then
				return
			end
			if speed > 0.5 then
				if not walk.IsPlaying then
					walk:Play(0.2)
				end
				walk:AdjustSpeed(speed / LOCOMOTION.WalkAnimSpeed)
			elseif walk.IsPlaying then
				walk:Stop(0.2)
			end
		end)
	)
end

local function addPrompt(npc: Npc)
	local names = Strings.Npcs[npc.Id]
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "TalkPrompt"
	prompt.Style = Enum.ProximityPromptStyle.Custom
	prompt.ActionText = Strings.QuestUI.Talk
	prompt.ObjectText = if names then names.Name else npc.Id
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = NPC.PromptDistance
	prompt.RequiresLineOfSight = false
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.GamepadKeyCode = Enum.KeyCode.ButtonX
	prompt.Parent = npc.Root
	table.insert(
		npc.Connections,
		prompt.Triggered:Connect(function(player: Player)
			NpcService.Hold(npc.Id, player)
		end)
	)
end

local function spawnNpc(id: string, def: Npcs.NpcDef, marker: BasePart, route: { Vector3 }): Npc
	local model = buildBody(id, def)
	local humanoid = model:FindFirstChildOfClass("Humanoid") :: Humanoid
	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart
	local height = humanoid.HipHeight + root.Size.Y / 2
	local markerPosition = marker.Position
	local standAt = Vector3.new(markerPosition.X, groundUnder(markerPosition) + height + 0.05, markerPosition.Z)
	local look = flat(marker.CFrame.LookVector)
	local home = if look.Magnitude > 1e-3 then CFrame.lookAt(standAt, standAt + look.Unit) else CFrame.new(standAt)
	model:PivotTo(home)

	local attachment = Instance.new("Attachment")
	attachment.Name = "FacingAttachment"
	attachment.Parent = root
	local align = Instance.new("AlignOrientation")
	align.Name = "Facing"
	align.Mode = Enum.OrientationAlignmentMode.OneAttachment
	align.Attachment0 = attachment
	align.Responsiveness = Config.Mobs.Movement.TurnResponsiveness
	align.MaxTorque = math.huge
	align.CFrame = home.Rotation
	align.Enabled = true
	align.Parent = root
	humanoid.AutoRotate = false

	model.Parent = modelFolder
	root:SetNetworkOwner(nil)
	CollectionService:AddTag(model, Attributes.Tags.Npc)

	-- Walkers start toward the route point after the one nearest their marker.
	local leg = 1
	if #route >= 2 then
		local best = math.huge
		for index, point in route do
			local distance = flatDistance(point, markerPosition)
			if distance < best then
				best = distance
				leg = index % #route + 1
			end
		end
	end

	local t = now()
	local npc: Npc = {
		Id = id,
		Def = def,
		Marker = marker,
		Model = model,
		Root = root,
		Humanoid = humanoid,
		Align = align,
		Height = height,
		Home = home,
		Route = route,
		Leg = leg,
		PauseUntil = t + (def.PauseSeconds or 0),
		MoveIssued = 0,
		Target = nil,
		BestDistance = math.huge,
		ProgressAt = t,
		HoldUntil = 0,
		HoldPlayer = nil,
		Walking = false,
		DeadSince = nil,
		Connections = {},
	}
	animate(npc)
	addPrompt(npc)
	return npc
end

local function despawn(npc: Npc)
	for _, connection in npc.Connections do
		connection:Disconnect()
	end
	table.clear(npc.Connections)
	npc.Model:Destroy()
end

-- BEHAVIOUR ----------------------------------------------------------------------------------

local function nearestPlayer(position: Vector3, radius: number): Vector3?
	local best: Vector3? = nil
	local bestDistance = radius
	for _, player in Players:GetPlayers() do
		local root = rootOf(player)
		if root then
			local distance = flatDistance(root.Position, position)
			if distance <= bestDistance then
				bestDistance = distance
				best = root.Position
			end
		end
	end
	return best
end

local function face(npc: Npc, target: Vector3)
	local direction = flat(target - npc.Root.Position)
	if direction.Magnitude < 0.1 then
		return
	end
	npc.Humanoid.AutoRotate = false
	npc.Align.CFrame = CFrame.lookAt(Vector3.zero, direction.Unit)
	npc.Align.Enabled = true
end

local function stop(npc: Npc)
	if npc.Walking then
		npc.Humanoid:MoveTo(npc.Root.Position)
		npc.Walking = false
		npc.Target = nil
	end
end

local function goTo(npc: Npc, point: Vector3, t: number)
	npc.Align.Enabled = false
	npc.Humanoid.AutoRotate = true
	if not npc.Walking or npc.Target ~= point or t - npc.MoveIssued >= REISSUE_SECONDS then
		npc.Humanoid:MoveTo(point)
		npc.MoveIssued = t
		npc.Target = point
	end
	npc.Walking = true
end

local function stand(npc: Npc, t: number)
	local position = npc.Root.Position
	local home = npc.Home.Position
	if flatDistance(position, home) > NPC.ReturnDistance then
		goTo(npc, home, t)
		return
	end
	stop(npc)
	face(npc, nearestPlayer(position, NPC.FaceRadius) or (position + npc.Home.LookVector))
end

local function walk(npc: Npc, t: number)
	local position = npc.Root.Position
	if t < npc.PauseUntil then
		stop(npc)
		local near = nearestPlayer(position, NPC.FaceRadius)
		if near then
			face(npc, near)
		end
		return
	end
	local point = npc.Route[npc.Leg]
	local distance = flatDistance(position, point)
	if distance <= ARRIVE_DISTANCE then
		stop(npc)
		npc.Leg = npc.Leg % #npc.Route + 1
		npc.PauseUntil = t + (npc.Def.PauseSeconds or 0)
		npc.BestDistance = math.huge
		npc.ProgressAt = t
		return
	end
	if distance < npc.BestDistance - 0.5 then
		npc.BestDistance = distance
		npc.ProgressAt = t
	elseif t - npc.ProgressAt > NPC.StuckSeconds then
		-- Blocked (a player's cart, a door): skip ahead to the point it was heading for.
		stop(npc)
		npc.Model:PivotTo(CFrame.new(point + Vector3.new(0, npc.Height, 0)) * npc.Root.CFrame.Rotation)
		npc.BestDistance = math.huge
		npc.ProgressAt = t
		return
	end
	goTo(npc, point, t)
end

local function respawn(npc: Npc)
	despawn(npc)
	local folder = markerFolder()
	local route = if folder then routeOf(folder, npc.Id) else npc.Route
	npcs[npc.Id] = nil
	if npc.Marker.Parent then
		local ok, result = pcall(spawnNpc, npc.Id, npc.Def, npc.Marker, route)
		if ok then
			npcs[npc.Id] = result
		else
			log:Warn(`NPC {npc.Id} failed to respawn: {tostring(result)}`)
		end
	end
end

local function think(npc: Npc, t: number)
	if not npc.Model.Parent or npc.Humanoid.Health <= 0 then
		npc.DeadSince = npc.DeadSince or t
		if t - (npc.DeadSince :: number) >= RESPAWN_SECONDS then
			respawn(npc)
		end
		return
	end
	if npc.Root.Position.Y < npc.Home.Position.Y - FALL_DEPTH then
		npc.Model:PivotTo(npc.Home)
		stop(npc)
		return
	end
	local speaker = npc.HoldPlayer
	if speaker and t < npc.HoldUntil then
		local root = rootOf(speaker)
		if root and (root.Position - npc.Root.Position).Magnitude <= Config.Quests.TalkRadius * 2 then
			stop(npc)
			face(npc, root.Position)
			return
		end
	end
	npc.HoldPlayer = nil
	if #npc.Route >= 2 then
		walk(npc, t)
	else
		stand(npc, t)
	end
end

local function build()
	local folder = markerFolder()
	if not folder then
		log:Warn(`Workspace.Floor{FloorService.GetFloorId()}.Npcs is missing (run Tools.Floor1Npcs); no town NPCs`)
		return
	end
	local floor = FloorService.GetFloorId()
	local seen: { [string]: boolean } = {}
	for _, marker in folder:GetChildren() do
		if not marker:IsA("BasePart") then
			continue
		end
		local value = marker:GetAttribute(A.NpcId)
		local id = if type(value) == "string" and value ~= "" then value else marker.Name
		local def = Npcs.Get(id)
		if not def then
			log:Warn(`NPC marker {marker:GetFullName()} names unknown NPC '{id}'`)
			continue
		end
		if def.Floor ~= floor or seen[id] then
			continue
		end
		seen[id] = true
		local route = if def.Behaviour == "Route" then routeOf(folder, id) else {}
		if def.Behaviour == "Route" and #route < 2 then
			log:Warn(`NPC {id} walks a route but {ROUTE_PREFIX}{id} has fewer than 2 points; it stands`)
		end
		local ok, result = pcall(spawnNpc, id, def, marker, route)
		if ok then
			npcs[id] = result
		else
			log:Warn(`NPC {id} failed to build: {tostring(result)}`)
		end
	end
	for id, def in Npcs.All() do
		if def.Floor == floor and not seen[id] then
			log:Warn(`NPC {id} has no marker in {folder:GetFullName()}`)
		end
	end
end

-- PUBLIC API ---------------------------------------------------------------------------------

-- Is `player` (alive) within Config.Quests.TalkRadius of NPC `npcId`'s body?
function NpcService.IsNear(player: Player, npcId: string): boolean
	local npc = npcs[npcId]
	local root = rootOf(player)
	if not npc or not root or not npc.Model.Parent then
		return false
	end
	return (root.Position - npc.Root.Position).Magnitude <= Config.Quests.TalkRadius
end

-- Where NPC `npcId` is right now (its marker if the body is gone); nil if it isn't on this floor.
function NpcService.Position(npcId: string): Vector3?
	local npc = npcs[npcId]
	if not npc then
		return nil
	end
	return if npc.Model.Parent then npc.Root.Position else npc.Marker.Position
end

-- `player` is talking to NPC `npcId`: it stops and faces them for Config.Quests.Npcs.TalkHoldSeconds.
-- Stops a walking NPC to talk. A hold is set once per conversation: another player can't extend
-- someone else's hold, and the same player can't renew it before it runs out (no freezing an NPC
-- by spamming Talk).
function NpcService.Hold(npcId: string, player: Player)
	local npc = npcs[npcId]
	if npc and now() >= npc.HoldUntil then
		npc.HoldPlayer = player
		npc.HoldUntil = now() + NPC.TalkHoldSeconds
	end
end

function NpcService.Init()
	if not PhysicsService:IsCollisionGroupRegistered(PLAYER_GROUP) then
		PhysicsService:RegisterCollisionGroup(PLAYER_GROUP)
	end
	if not PhysicsService:IsCollisionGroupRegistered(GROUP) then
		PhysicsService:RegisterCollisionGroup(GROUP)
	end
	PhysicsService:CollisionGroupSetCollidable(GROUP, PLAYER_GROUP, false)
	local existing = Workspace:FindFirstChild(MODEL_FOLDER)
	if existing and existing:IsA("Folder") then
		modelFolder = existing
	else
		local folder = Instance.new("Folder")
		folder.Name = MODEL_FOLDER
		folder.Parent = Workspace
		modelFolder = folder
	end
end

function NpcService.Start()
	-- Building bodies can yield (HumanoidDescription), so it doesn't hold up the systems after this one.
	task.spawn(build)
	Players.PlayerRemoving:Connect(function(player: Player)
		for _, npc in npcs do
			if npc.HoldPlayer == player then
				npc.HoldPlayer = nil
			end
		end
	end)
	local accumulator = 0
	RunService.Heartbeat:Connect(function(dt: number)
		accumulator += dt
		if accumulator < NPC.ThinkSeconds then
			return
		end
		accumulator = 0
		local t = now()
		-- A copy: a respawn replaces its entry while we walk the list.
		for _, npc in table.clone(npcs) do
			think(npc, t)
		end
	end)
end

return NpcService
