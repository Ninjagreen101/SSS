--!strict
--[[
	CharacterService
	Owns the character lifecycle on the server.

	Spawn:   characters load only after the player's profile is ready, then
	         rise at their Waystone (FloorService). Roblox's default health
	         regen script is removed (health is ours), players stop colliding
	         with each other, and movement checks are reset.
	         It is then registered as a combat target and handed its weapon.
	Death:   the body ragdolls, deaths are counted, 10% of carried gold drops
	         as a Lost Current orb at the death spot (overwriting any older
	         orb), and RespawnAt tells the client when it may rise again.
	Respawn: RequestRespawn is honoured only while dead and after the delay.
	Lost Current: the owner recovers it by returning within the pickup radius
	         (checked on the server; the orb itself is drawn by that client).
]]

local Players = game:GetService("Players")
local PhysicsService = game:GetService("PhysicsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Attributes = require(Shared.Attributes)
local Net = require(Shared.Net)
local Log = require(Shared.Util.Log)

local DataService = require(script.Parent.DataService)
local VitalsService = require(script.Parent.VitalsService)
local FloorService = require(script.Parent.FloorService)
local AntiExploitService = require(script.Parent.AntiExploitService)
local AnalyticsService = require(script.Parent.AnalyticsService)
local TargetService = require(script.Parent.TargetService)
local WeaponService = require(script.Parent.WeaponService)

local A = Attributes.Names
local log = Log.new("CharacterService")

local PLAYER_GROUP = "Players"

local CharacterService = {}

local spawning: { [Player]: boolean } = {}
local deathConnections: { [Player]: RBXScriptConnection } = {}

local function now(): number
	return Workspace:GetServerTimeNow()
end

local function setCollisionGroup(character: Model)
	local function apply(part: Instance)
		if part:IsA("BasePart") then
			part.CollisionGroup = PLAYER_GROUP
		end
	end
	for _, descendant in character:GetDescendants() do
		apply(descendant)
	end
	character.DescendantAdded:Connect(apply)
end

-- A limited ball socket between two body parts at the joint's frames.
local function socket(part0: BasePart, part1: BasePart, frame0: CFrame, frame1: CFrame)
	local attachment0 = Instance.new("Attachment")
	attachment0.Name = "RagdollA"
	attachment0.CFrame = frame0
	attachment0.Parent = part0
	local attachment1 = Instance.new("Attachment")
	attachment1.Name = "RagdollB"
	attachment1.CFrame = frame1
	attachment1.Parent = part1
	local constraint = Instance.new("BallSocketConstraint")
	constraint.Attachment0 = attachment0
	constraint.Attachment1 = attachment1
	constraint.LimitsEnabled = true
	constraint.TwistLimitsEnabled = true
	constraint.UpperAngle = 45
	constraint.TwistLowerAngle = -30
	constraint.TwistUpperAngle = 30
	constraint.Parent = part1
end

-- Swaps joints for ball sockets so the body falls naturally. Handles both
-- Motor6D rigs and the newer AnimationConstraint rigs (Roblox avatars now
-- load with AnimationConstraints). The root joint stays rigid, and every
-- body part collides so the body lands on the ground instead of falling
-- through it.
function CharacterService.Ragdoll(character: Model)
	local body: { BasePart } = {}
	for _, joint in character:GetDescendants() do
		if joint:IsA("Motor6D") then
			local part0, part1 = joint.Part0, joint.Part1
			if joint.Name ~= "Root" and part0 and part1 then
				socket(part0, part1, joint.C0, joint.C1)
				joint.Enabled = false
				table.insert(body, part0)
				table.insert(body, part1)
			end
		elseif joint:IsA("AnimationConstraint") then
			local a0, a1 = joint.Attachment0, joint.Attachment1
			local part0 = a0 and a0.Parent
			local part1 = a1 and a1.Parent
			if a0 and a1 and part0 and part1 and part0:IsA("BasePart") and part1:IsA("BasePart") and part0.Name ~= "HumanoidRootPart" then
				socket(part0, part1, a0.CFrame, a1.CFrame)
				joint.Enabled = false
				table.insert(body, part0)
				table.insert(body, part1)
			end
		end
	end
	-- Limbs collide (so the body rests on the ground); the root and any
	-- decorations (accessories, weapons) are left as they were.
	for _, part in body do
		part.CanCollide = true
	end
	-- The root never collides, and on AnimationConstraint rigs its joint is
	-- switched off when the Humanoid dies, so on its own it would drop
	-- through the floor (taking the camera with it). Weld it to the body.
	local root = character:FindFirstChild("HumanoidRootPart")
	local hips = character:FindFirstChild("LowerTorso") or character:FindFirstChild("Torso")
	if root and root:IsA("BasePart") then
		root.CanCollide = false
		root.Massless = true
		if hips and hips:IsA("BasePart") then
			local weld = Instance.new("WeldConstraint")
			weld.Name = "RagdollRoot"
			weld.Part0 = root
			weld.Part1 = hips
			weld.Parent = root
		end
	end
end

local function dropLostCurrent(player: Player, position: Vector3)
	local data = DataService.GetData(player)
	if not data then
		return
	end
	local hadOrb = data.LostCurrent.Gold > 0
	local lost = math.floor(data.Currencies.Gold * Config.Economy.Death.GoldDropFraction)
	if hadOrb then
		Net.Fire("Notify", player, "Toasts.LostCurrentGone", {}, "Warning")
	end
	if lost <= 0 then
		if hadOrb then
			DataService.Set(player, { "LostCurrent" }, { Gold = 0, FloorId = "", Position = {} })
		end
		return
	end
	DataService.Increment(player, { "Currencies", "Gold" }, -lost, 0)
	DataService.Set(player, { "LostCurrent" }, {
		Gold = lost,
		FloorId = FloorService.GetFloorId(),
		Position = { position.X, position.Y, position.Z },
	})
	Net.Fire("Notify", player, "Toasts.LostCurrentDropped", { gold = lost }, "Warning")
	AnalyticsService.Economy(player, "Sink", "Gold", lost, data.Currencies.Gold, "LostCurrent")
end

local function onDied(player: Player, character: Model)
	local root = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	TargetService.Unregister(character)
	if Config.Combat.Death.Ragdoll then
		CharacterService.Ragdoll(character)
	end
	DataService.Increment(player, { "PlayStats", "Deaths" }, 1)
	if root then
		dropLostCurrent(player, root.Position)
	end
	player:SetAttribute(A.RespawnAt, now() + Config.Combat.Death.RespawnDelay)
	AnalyticsService.Custom(player, "Death")
end

local function stripDefaultScripts(character: Model)
	-- Roblox's "Health" script regenerates health; health is ours now.
	local healthScript = character:FindFirstChild("Health")
	if healthScript and healthScript:IsA("Script") then
		healthScript:Destroy()
	end
end

local function setupCharacter(player: Player, character: Model)
	stripDefaultScripts(character)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end
	humanoid.BreakJointsOnDeath = not Config.Combat.Death.Ragdoll
	humanoid.UseJumpPower = true
	humanoid.JumpPower = Config.Combat.Movement.JumpPower
	humanoid.WalkSpeed = Config.Combat.Movement.WalkSpeed
	if not Config.World.PlayerCollision then
		setCollisionGroup(character)
	end

	local connection = deathConnections[player]
	if connection then
		connection:Disconnect()
	end
	deathConnections[player] = humanoid.Died:Connect(function()
		onDied(player, character)
	end)

	character:PivotTo(FloorService.GetSpawnCFrame(player))
	AntiExploitService.ResetMovement(player)
	VitalsService.Bind(player, character)
	WeaponService.Attach(player, character)
	TargetService.Register(character, "Player", "Players", player)
	player:SetAttribute(A.RespawnAt, nil)
end

local function spawnCharacter(player: Player)
	if spawning[player] or player.Parent ~= Players or not DataService.IsLoaded(player) then
		return
	end
	spawning[player] = true
	local ok, err = pcall(function()
		player:LoadCharacterAsync()
	end)
	spawning[player] = nil
	if not ok then
		log:Warn(`LoadCharacterAsync failed for {player.Name}: {tostring(err)}`)
		return
	end
	local character = player.Character
	if character then
		setupCharacter(player, character)
	end
end

local function isDead(player: Player): boolean
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return humanoid == nil or humanoid.Health <= 0
end

local function onRespawnRequest(player: Player)
	if not isDead(player) then
		return
	end
	local respawnAt = player:GetAttribute(A.RespawnAt)
	if type(respawnAt) == "number" and now() < respawnAt - 0.1 then
		return
	end
	spawnCharacter(player)
end

local function checkLostCurrent()
	local radius = Config.Combat.Death.LostCurrentPickupRadius
	for _, player in Players:GetPlayers() do
		local data = DataService.GetData(player)
		if data and data.LostCurrent.Gold > 0 and data.LostCurrent.FloorId == FloorService.GetFloorId() then
			local character = player.Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
			local stored = data.LostCurrent.Position
			if humanoid and humanoid.Health > 0 and root and #stored == 3 then
				local orb = Vector3.new(stored[1], stored[2], stored[3])
				if (root.Position - orb).Magnitude <= radius then
					local gold = data.LostCurrent.Gold
					DataService.Set(player, { "LostCurrent" }, { Gold = 0, FloorId = "", Position = {} })
					DataService.Increment(player, { "Currencies", "Gold" }, gold, 0, Config.Economy.MaxGold)
					Net.Fire("Notify", player, "Toasts.LostCurrentRecovered", { gold = gold }, "Success")
					AnalyticsService.Economy(player, "Source", "Gold", gold, data.Currencies.Gold, "LostCurrent")
				end
			end
		end
	end
end

-- PUBLIC API -----------------------------------------------------------------

-- Teleports a living character (e.g. fast travel) with movement checks reset.
function CharacterService.Teleport(player: Player, cframe: CFrame)
	local character = player.Character
	if character then
		AntiExploitService.ResetMovement(player)
		character:PivotTo(cframe)
		AntiExploitService.ResetMovement(player)
	end
end

function CharacterService.Respawn(player: Player)
	spawnCharacter(player)
end

function CharacterService.Init()
	Players.CharacterAutoLoads = false
	PhysicsService:RegisterCollisionGroup(PLAYER_GROUP)
	PhysicsService:CollisionGroupSetCollidable(PLAYER_GROUP, PLAYER_GROUP, Config.World.PlayerCollision)
	Net.On("RequestRespawn", onRespawnRequest)
end

function CharacterService.Start()
	DataService.ProfileLoaded:Connect(function(player: Player)
		task.spawn(spawnCharacter, player)
	end)
	-- Profiles that finished loading before Start.
	for _, player in Players:GetPlayers() do
		if DataService.IsLoaded(player) and not player.Character then
			task.spawn(spawnCharacter, player)
		end
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		local connection = deathConnections[player]
		if connection then
			connection:Disconnect()
		end
		deathConnections[player] = nil
		spawning[player] = nil
	end)

	local accumulator = 0
	RunService.Heartbeat:Connect(function(dt: number)
		accumulator += dt
		if accumulator >= Config.Combat.Death.LostCurrentCheckInterval then
			accumulator = 0
			checkLostCurrent()
		end
	end)
end

return CharacterService
