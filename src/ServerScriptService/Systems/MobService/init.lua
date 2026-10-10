--!strict
--[[
	MobService
	Enemies (Spec Section 10): spawning, the think scheduler, damage and
	threat bookkeeping, death and rewards. Decisions live in Brain, movement
	in Navigator, bodies in Builder; bolts fly through ProjectileService.

	Spawn points
	  Parts inside Workspace.MobSpawns (Config.Mobs.Spawning.Folder) with:
	    MobId         which enemy (Shared.Data.Mobs), required
	    SpawnCount    how many live here at once (default 1)
	    Elite         spawn elite versions (3x health, 1.5x damage, gold glow)
	    RespawnTime   seconds before a dead one is replaced
	    PatrolRadius  how far they wander from the point (0 = stand guard)
	    Zone          loot zone for its drops (Config/Loot Zones; default Lowharbor)
	    NightOnly     only out between dusk and dawn; at dawn they sink back into the water
	                  (EnvironmentService.NightChanged)
	  The parts are hidden in game; move or copy them in Studio to lay out
	  encounters. Spawn points added while the server runs work too.

	Thinking
	  Each mob thinks TickRateNear times a second while a player is within
	  NearRadius, TickRateFar times a second within SleepRadius, and not at
	  all (asleep, standing still) beyond that. Moves run in their own
	  thread between thinks so their timing is exact.

	Mobs are server-owned physics (SetNetworkOwner(nil)), so no client can
	move them, and fight through CombatService like every other target.

	Scripted mobs (Spawn options, Types.SpawnOptions)
	  A Floor Guardian is spawned Scripted: Brain never thinks for it, its
	  death pays no kill rewards and never respawns (OnDied tells its owner,
	  which removes the body with Despawn). Threat and Contributors are still
	  kept from hits. Any mob can carry AllowedTargets (a Guardian's adds only
	  fight its party) and a per-mob WeakPoint / PostureTaken override.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Attributes = require(Shared.Attributes)
local Mobs = require(Shared.Data.Mobs)
local Log = require(Shared.Util.Log)

local TargetService = require(script.Parent.TargetService)
local CombatService = require(script.Parent.CombatService)
local CharacterService = require(script.Parent.CharacterService)
local ProgressionService = require(script.Parent.ProgressionService)
local LootService = require(script.Parent.LootService)
local GearService = require(script.Parent.GearService)
local EnvironmentService = require(script.Parent.EnvironmentService)
local VitalsService = require(script.Parent.VitalsService)
local GameEvents = require(script.Parent.GameEvents)
local Types = require(script.Types)
local Builder = require(script.Builder)
local Navigator = require(script.Navigator)
local Brain = require(script.Brain)

local A = Attributes.Names
local AI = Config.Mobs.AI
local SPAWN = Config.Mobs.Spawning
local ELITE = Config.Mobs.Elite
local SEE = Config.Mobs.Perception
local log = Log.new("MobService")

export type Mob = Types.Mob

local MobService = {}

local mobs: { [Model]: Types.Mob } = {}
local spawnPoints: { [BasePart]: Types.SpawnPoint } = {}
local mobFolder: Folder
local serial = 0
local random = Random.new()

local function now(): number
	return Workspace:GetServerTimeNow()
end

local function list(): { Types.Mob }
	local result = {}
	for _, mob in mobs do
		table.insert(result, mob)
	end
	return result
end

-- Raycasts for sight, walls and bolts skip every character and mob.
local function refreshIgnoreLists()
	local ignore: { Instance } = { mobFolder }
	for _, player in Players:GetPlayers() do
		if player.Character then
			table.insert(ignore, player.Character)
		end
	end
	Navigator.SetIgnored(ignore)
	Brain.SetIgnored(ignore)
end

-- Where to stand: the ground under `point`, found by a downward ray.
local function groundAt(point: Vector3): Vector3
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { mobFolder }
	local folder = Workspace:FindFirstChild(SPAWN.Folder)
	if folder then
		params.FilterDescendantsInstances = { mobFolder, folder }
	end
	local hit = Workspace:Raycast(point + Vector3.new(0, 20, 0), Vector3.new(0, -100, 0), params)
	return if hit then hit.Position else point
end

-- SPAWNING ---------------------------------------------------------------------

-- Tells a mob's owner it died (own thread: an owner's error can't break the death).
local function notifyDied(mob: Types.Mob)
	local callback = mob.OnDied
	if callback then
		task.spawn(callback, mob)
	end
end

local function onDied(mob: Types.Mob)
	if mob.Dead then
		return
	end
	mob.Dead = true
	Brain.CancelMove(mob)
	Brain.ReleaseSlot(mob)
	mob.Model:SetAttribute(A.MobState, "Dead")
	mob.State = "Dead"
	TargetService.Unregister(mob.Model)
	CollectionService:RemoveTag(mob.Model, Attributes.Tags.Mob)
	mob.Align.Enabled = false
	CharacterService.Ragdoll(mob.Model)

	if mob.Scripted then
		-- Its owner pays out and removes the body (MobService.Despawn) when it's done with it.
		notifyDied(mob)
		return
	end

	-- XP to everyone who helped, then each of them gets personal loot.
	local position = mob.Root.Position
	local earned = ProgressionService.KillEligible(mob.Contributors, position)
	ProgressionService.AwardKill(mob.Def, mob.Elite, earned)
	for _, player in earned do
		GameEvents.Fire(player, "Kill", mob.MobId)
	end
	local zone = if mob.Spawn then mob.Spawn.Part:GetAttribute(A.Zone) else nil
	LootService.AwardKill(mob.MobId, mob.Def, mob.Elite, earned, position, if type(zone) == "string" then zone else nil)
	notifyDied(mob)

	local model = mob.Model
	task.delay(Config.Mobs.Visual.DissolveDuration + 0.5, function()
		mobs[model] = nil
		model:Destroy()
	end)
	local point = mob.Spawn
	if point then
		point.Alive -= 1
		task.delay(point.RespawnTime, function()
			if spawnPoints[point.Part] == point then
				MobService.FillSpawn(point)
			end
		end)
	end
end

function MobService.Spawn(
	mobId: string,
	position: Vector3,
	elite: boolean,
	point: Types.SpawnPoint?,
	options: Types.SpawnOptions?
): Types.Mob?
	local opts: Types.SpawnOptions = options or {}
	mobId = Mobs.Resolve(mobId) -- pre-Phase 9 ids (e.g. SaltwornDrifter) become their successors
	local def = Mobs.Get(mobId)
	if not def then
		log:Warn(`Unknown mob id {mobId}`)
		return nil
	end
	local model = Builder.Build(mobId, def, elite)
	local humanoid = model:FindFirstChildOfClass("Humanoid") :: Humanoid
	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart
	local scale = def.Body.Scale * (if elite then ELITE.ScaleMultiplier else 1)

	local health = opts.MaxHealth or def.MaxHealth * (if elite then ELITE.HealthMultiplier else 1)
	humanoid.MaxHealth = health
	humanoid.Health = health
	humanoid.WalkSpeed = def.WalkSpeed

	local ground = groundAt(position)
	local height = humanoid.HipHeight + root.Size.Y / 2
	local standAt = ground + Vector3.new(0, height + 0.1, 0)
	local pivot = CFrame.new(standAt) * CFrame.Angles(0, random:NextNumber(0, math.pi * 2), 0)
	local facing = opts.Facing
	if facing and Vector3.new(facing.X, 0, facing.Z).Magnitude > 1e-3 then
		pivot = CFrame.lookAt(standAt, standAt + Vector3.new(facing.X, 0, facing.Z))
	end
	model:PivotTo(pivot)

	-- Turning to face things without fighting physics.
	local attachment = Instance.new("Attachment")
	attachment.Name = "FacingAttachment"
	attachment.Parent = root
	local align = Instance.new("AlignOrientation")
	align.Name = "Facing"
	align.Mode = Enum.OrientationAlignmentMode.OneAttachment
	align.Attachment0 = attachment
	align.Responsiveness = Config.Mobs.Movement.TurnResponsiveness
	align.MaxTorque = math.huge
	align.Enabled = false
	align.Parent = root

	model:SetAttribute(A.MobId, mobId)
	model:SetAttribute(A.Elite, elite)
	model:SetAttribute(A.MobState, "Idle")
	model:SetAttribute(A.NameKey, `Mobs.{mobId}`)
	model.Parent = mobFolder
	root:SetNetworkOwner(nil)

	serial += 1
	local mob: Types.Mob = {
		Serial = serial,
		MobId = mobId,
		Def = def,
		Elite = elite,
		Model = model,
		Humanoid = humanoid,
		Root = root,
		Align = align,
		Spawn = point,
		Home = ground,
		PatrolRadius = if point then point.PatrolRadius else SPAWN.DefaultPatrolRadius,
		DamageMultiplier = (if elite then ELITE.DamageMultiplier else 1) * math.max(0, opts.DamageMultiplier or 1),
		EmpowerUntil = 0,
		EmpowerBonus = 0,
		State = "Idle",
		Target = nil,
		Threat = {},
		TauntedBy = nil,
		TauntUntil = 0,
		Contributors = {},
		LastTargetAt = 0,
		NoticeUntil = 0,
		NextPatrolAt = now() + random:NextNumber(1, 4),
		Cooldowns = {},
		LastMove = nil,
		MoveRepeats = 0,
		NextMoveAt = 0,
		Acting = false,
		ActionThread = nil,
		Token = nil,
		NextThinkAt = now() + random:NextNumber(0, 0.2),
		LastThinkAt = now(),
		Asleep = false,
		Nav = Navigator.New(scale),
		Dead = false,
		Scripted = opts.Scripted == true,
		AllowedTargets = opts.AllowedTargets,
		WeakPoint = nil,
		PostureTaken = 1,
		TelegraphScale = math.max(0, opts.TelegraphScale or 1),
		OnDied = opts.OnDied,
	}
	mobs[model] = mob

	if not TargetService.Register(model, "Mob", "Enemies") then
		log:Warn(`Could not register {mobId} as a combat target`)
		mobs[model] = nil
		model:Destroy()
		return nil
	end
	CombatService.SetMaxPosture(model, opts.MaxPosture or def.MaxPosture * (if elite then ELITE.PostureMultiplier else 1))
	if opts.HitRadius or opts.HitHeight then
		TargetService.SetHitSize(model, opts.HitRadius or 0, opts.HitHeight or 0)
	end
	CollectionService:AddTag(model, Attributes.Tags.Mob)
	humanoid.Died:Connect(function()
		onDied(mob)
	end)
	if point then
		point.Alive += 1
	end
	return mob
end

-- Removes one mob without rewards or respawn (its body too, if it already died). With `fade`
-- clients dissolve it first.
local function despawn(model: Model, fade: boolean)
	local mob = mobs[model]
	if not mob then
		return
	end
	mobs[model] = nil
	if not mob.Dead then
		mob.Dead = true
		Brain.CancelMove(mob)
		Brain.ReleaseSlot(mob)
		TargetService.Unregister(model)
		CollectionService:RemoveTag(model, Attributes.Tags.Mob)
		local point = mob.Spawn
		if point then
			point.Alive -= 1
		end
	end
	if fade then
		model:SetAttribute(A.MobState, "Dead") -- clients dissolve it
		task.delay(Config.Mobs.Visual.DissolveDuration, function()
			model:Destroy()
		end)
	else
		model:Destroy()
	end
end

-- Removes the living mobs of one spawn point (dawn for night-only points, or the point was
-- deleted, e.g. a dungeon instance closing). Nobody gets rewards for these.
local function despawnPoint(point: Types.SpawnPoint, fade: boolean)
	for model, mob in mobs do
		if mob.Spawn == point and not mob.Dead then
			despawn(model, fade)
		end
	end
end

-- Tops a spawn point up to its SpawnCount.
function MobService.FillSpawn(point: Types.SpawnPoint)
	if point.NightOnly and not EnvironmentService.IsNight() then
		return -- refilled at dusk
	end
	while point.Alive < point.Count do
		local angle = random:NextNumber(0, math.pi * 2)
		local distance = if point.Count > 1 then random:NextNumber(0, SPAWN.ScatterRadius) else 0
		local position = point.Part.Position + Vector3.new(math.cos(angle), 0, math.sin(angle)) * distance
		if not MobService.Spawn(point.MobId, position, point.Elite, point) then
			return
		end
	end
end

local function addSpawnPoint(instance: Instance)
	if not instance:IsA("BasePart") or spawnPoints[instance] then
		return
	end
	local part = instance
	local mobId = part:GetAttribute(A.MobId)
	if type(mobId) ~= "string" or not Mobs.Get(mobId) then
		log:Warn(`Spawn point {part:GetFullName()} needs a MobId attribute naming an enemy in Shared.Data.Mobs`)
		return
	end
	local count = part:GetAttribute(A.SpawnCount)
	local respawn = part:GetAttribute(A.RespawnTime)
	local patrol = part:GetAttribute(A.PatrolRadius)
	local point: Types.SpawnPoint = {
		Part = part,
		MobId = mobId,
		Count = if type(count) == "number" then math.clamp(math.floor(count), 1, 12) else 1,
		Elite = part:GetAttribute(A.Elite) == true,
		RespawnTime = if type(respawn) == "number" then math.max(5, respawn) else SPAWN.DefaultRespawnTime,
		PatrolRadius = if type(patrol) == "number" then math.max(0, patrol) else SPAWN.DefaultPatrolRadius,
		Alive = 0,
		NightOnly = part:GetAttribute("NightOnly") == true,
	}
	part.Transparency = 1
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Anchored = true
	spawnPoints[part] = point
	MobService.FillSpawn(point)
end

-- COMBAT EVENTS ----------------------------------------------------------------

-- A Drain mob's blow that landed on a player heals it and drinks the player's Current.
local function onMobHit(attacker: Model, defender: Model, applied: number)
	local mob = mobs[attacker]
	local drain = mob and mob.Def.Drain
	if not mob or mob.Dead or not drain or applied <= 0 then
		return
	end
	local humanoid = mob.Humanoid
	humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + applied * drain.Heal)
	local player = Players:GetPlayerFromCharacter(defender)
	if player then
		VitalsService.AddCurrent(player, -drain.Current)
	end
end

-- Weak points: blows from within the weak point's Arc of a mob's back (or front, for a
-- per-mob override on its Front) hit harder. PostureTaken scales every blow's posture.
local function weakPoint(model: Model, source: Vector3): (number, number)
	local mob = mobs[model]
	if not mob then
		return 1, 1
	end
	local taken = mob.PostureTaken
	local arc, damage, posture = 0, 1, 1
	local side: "Back" | "Front" = "Back"
	local override = mob.WeakPoint
	local spot = mob.Def.WeakPoint
	if override then
		arc, damage, posture, side = override.Arc, override.Damage, override.Posture, override.Side
	elseif spot then
		arc, damage, posture = spot.Arc, spot.Damage, spot.Posture
	else
		return 1, taken
	end
	local look = mob.Root.CFrame.LookVector
	local toward = if side == "Front" then look else -look
	local toSource = source - mob.Root.Position
	local flatToward = Vector3.new(toward.X, 0, toward.Z)
	local flatTo = Vector3.new(toSource.X, 0, toSource.Z)
	if flatToward.Magnitude < 1e-3 or flatTo.Magnitude < 1e-3 then
		return 1, taken
	end
	local angle = math.deg(math.acos(math.clamp(flatToward.Unit:Dot(flatTo.Unit), -1, 1)))
	if angle <= arc / 2 then
		return damage, posture * taken
	end
	return 1, taken
end

local function onHitLanded(attacker: Model?, defender: Model, _outcome: string, applied: number, _kind: string)
	if attacker and mobs[attacker] then
		onMobHit(attacker, defender, applied)
	end
	local mob = mobs[defender]
	if not mob or mob.Dead or not attacker then
		return
	end
	local player = Players:GetPlayerFromCharacter(attacker)
	if not player then
		return
	end
	if applied > 0 then
		mob.Contributors[player] = (mob.Contributors[player] or 0) + applied
	end
	if mob.State == "Return" then
		return -- leashed: it ignores you until it's home
	end
	-- Vanguard tree: Threat makes your damage draw more attention.
	local threat = math.max(1, applied) * SEE.DamageThreat * Config.Mobs.Threat.DamageMultiplier * (1 + GearService.Bonus(player, "Threat"))
	Brain.AddThreat(mob, player, threat)
	if not mob.Scripted then
		Brain.Engage(mob, player, list())
	end
end

-- SCHEDULER --------------------------------------------------------------------

local function nearestPlayerDistance(position: Vector3): number
	local best = math.huge
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			best = math.min(best, (root.Position - position).Magnitude)
		end
	end
	return best
end

local function schedule()
	local t = now()
	local others: { Types.Mob }? = nil
	for _, mob in mobs do
		if not mob.Dead and not mob.Scripted and t >= mob.NextThinkAt then
			local distance = nearestPlayerDistance(mob.Root.Position)
			if distance > AI.SleepRadius then
				-- Nobody around: stand still and check again in a second.
				if not mob.Asleep and not mob.Acting then
					mob.Asleep = true
					Navigator.Stop(mob)
				end
				mob.NextThinkAt = t + 1
				mob.LastThinkAt = t
			else
				mob.Asleep = false
				local rate = if distance <= AI.NearRadius then AI.TickRateNear else AI.TickRateFar
				mob.NextThinkAt = t + 1 / rate
				local dt = t - mob.LastThinkAt
				mob.LastThinkAt = t
				others = others or list()
				local thinkWith = others :: { Types.Mob }
				local ok, err = pcall(function(): string?
					Brain.Think(mob, dt, thinkWith)
					return nil
				end)
				if not ok then
					log:Error(`{mob.MobId} think failed: {err}`)
				end
			end
		end
	end
end

-- PUBLIC API -------------------------------------------------------------------

function MobService.GetMob(model: Model): Types.Mob?
	return mobs[model]
end

function MobService.GetAll(): { [Model]: Types.Mob }
	return mobs
end

-- A Taunt step (Harbor Bell): every living enemy within `radius` turns on
-- `player` and stays on them for `duration` s (if they stay in its leash).
-- Returns the models taunted.
function MobService.Taunt(player: Player, center: Vector3, radius: number, duration: number): { Model }
	local taunted = {}
	local until_ = Workspace:GetServerTimeNow() + duration
	for model, mob in mobs do
		local allowed = mob.AllowedTargets == nil or mob.AllowedTargets[player] == true
		if not mob.Dead and allowed and mob.State ~= "Return" and (mob.Root.Position - center).Magnitude <= radius then
			Brain.AddThreat(mob, player, Config.Mobs.Threat.TauntBonus)
			mob.TauntedBy = player
			mob.TauntUntil = until_
			if not mob.Scripted then
				-- (a scripted mob's owner reads TauntedBy / Threat itself)
				mob.Target = player
				Brain.Engage(mob, player, nil)
			end
			table.insert(taunted, model)
		end
	end
	return taunted
end

-- Removes a mob without rewards or respawn (a Guardian's adds and body when its fight ends).
function MobService.Despawn(model: Model, fade: boolean)
	despawn(model, fade)
end

-- Makes a (non-scripted) mob turn on `player` at once, e.g. adds summoned mid-fight.
function MobService.Engage(model: Model, player: Player)
	local mob = mobs[model]
	if mob and not mob.Dead and not mob.Scripted then
		Brain.Engage(mob, player, nil)
	end
end

-- Removes every live mob (Studio testing). Spawn points refill after their respawn time.
-- Scripted mobs (Floor Guardians) belong to their fight and are left alone.
function MobService.Clear()
	for model, mob in mobs do
		if mob.Scripted then
			continue
		end
		if not mob.Dead then
			mob.Dead = true
			Brain.CancelMove(mob)
			Brain.ReleaseSlot(mob)
			if mob.Spawn then
				mob.Spawn.Alive -= 1
				local point = mob.Spawn
				task.delay(point.RespawnTime, function()
					if spawnPoints[point.Part] == point then
						MobService.FillSpawn(point)
					end
				end)
			end
		end
		mobs[model] = nil
		model:Destroy()
	end
end

function MobService.Init()
	local folder = Workspace:FindFirstChild("Mobs")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Mobs"
		folder.Parent = Workspace
	end
	mobFolder = folder :: Folder
end

function MobService.Start()
	refreshIgnoreLists()
	Brain.SetMobProvider(list)
	Players.PlayerAdded:Connect(function(player: Player)
		player.CharacterAdded:Connect(refreshIgnoreLists)
	end)
	for _, player in Players:GetPlayers() do
		player.CharacterAdded:Connect(refreshIgnoreLists)
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		Brain.ForgetPlayer(player)
		for _, mob in mobs do
			mob.Threat[player] = nil
			mob.Contributors[player] = nil
			if mob.Target == player then
				mob.Target = nil
			end
		end
		task.defer(refreshIgnoreLists)
	end)

	CombatService.HitLanded:Connect(onHitLanded)
	CombatService.SetWeakPointResolver(weakPoint)

	task.spawn(function()
		local folder = Workspace:WaitForChild(SPAWN.Folder, 10)
		if not folder then
			log:Info(`No Workspace.{SPAWN.Folder} folder: no enemies on this map`)
			return
		end
		for _, child in folder:GetChildren() do
			addSpawnPoint(child)
		end
		folder.ChildAdded:Connect(addSpawnPoint)
		folder.ChildRemoved:Connect(function(child: Instance)
			if child:IsA("BasePart") then
				local point = spawnPoints[child]
				spawnPoints[child] = nil
				if point then
					despawnPoint(point, false)
				end
			end
		end)
		-- night-only points: fill at dusk, sink back at dawn
		EnvironmentService.NightChanged:Connect(function(isNight: boolean)
			for _, point in spawnPoints do
				if point.NightOnly then
					if isNight then
						MobService.FillSpawn(point)
					else
						despawnPoint(point, true)
					end
				end
			end
		end)
	end)

	RunService.Heartbeat:Connect(schedule)
end

return MobService
