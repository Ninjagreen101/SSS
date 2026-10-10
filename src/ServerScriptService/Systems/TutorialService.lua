--!strict
--[[
	TutorialService
	The onboarding on the Floor 1 docks (docs/PHASE11_QUESTS.md section 5) for every profile
	whose Tutorial.Done ~= true. The step machine itself is TutorialSteps (pure, Lune-tested);
	this service owns the world side:

	- Placement: the player starts at QuestPoint TutorialStart (Workspace.Floor1.QuestPoints, a
	  Part with PointId; fallback the Climbers' Rest Waystone). A rejoin resumes at the saved
	  Tutorial.Step, placed at that step's anchor point.
	- Actions: GameEvents (Reach, Dodge, PerfectDodge, Parry, Cast, Resonance) drive the
	  machine. Reach is also checked here every Config.Quests.ReachCheckSeconds against the
	  step's point (with VitalsService.IsSprinting for the sprint step), Resonance also from the
	  player's Resonance attribute, and Kill comes from the tutorial mobs' own OnDied, so only
	  this player's crab and tutor count.
	- Mobs: the crab (step 3) and the Drowned Sailor tutor (steps 4-8) spawn at TutorialArena
	  through MobService.Spawn with AllowedTargets = this player, DamageMultiplier and
	  TelegraphScale from Config.Quests.Tutorial. The tutor can't drop below TutorHealthFloor
	  before step 8 (it is respawned if a big blow still kills it) and starts step 8 there.
	  A crab someone else killed is replaced.
	- Safety: while in the tutorial the player's health is topped back up to HealthFloor of max,
	  so the tutor (a quarter of its damage) can never kill a new player.
	- Step 6 grants the preview Tide Bolt (SpellService.SetPreviewSpell) and fills Current; it is
	  cleared when the step ends, on skip, on finish and on leave.
	- Every change is saved to Tutorial.Step and sent as TutorialStep(step, payload) (step 0 once
	  finished or skipped). RequestTutorial "Skip" (after SkipAfterSeconds) and "Continue"
	  (closes the Resonance card).
	- Finish or skip: mobs removed, Done (and Skipped) saved, quest F1_M01 given through
	  QuestService.Give, and a toast.
	Players not in the tutorial are ignored everywhere.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Attributes = require(Shared.Attributes)
local Net = require(Shared.Net)
local Log = require(Shared.Util.Log)
local Maid = require(Shared.Util.Maid)

local GameEvents = require(script.Parent.GameEvents)
local DataService = require(script.Parent.DataService)
local FloorService = require(script.Parent.FloorService)
local CharacterService = require(script.Parent.CharacterService)
local VitalsService = require(script.Parent.VitalsService)
local TargetService = require(script.Parent.TargetService)
local MobService = require(script.Parent.MobService)
local SpellService = require(script.Parent.SpellService)
local Steps = require(script.Parent.TutorialSteps)

local A = Attributes.Names
local TUT = Config.Quests.Tutorial
local log = Log.new("TutorialService")

local FIRST_QUEST = "F1_M01" -- given when the tutorial ends (finished or skipped)
local FALLBACK_WAYSTONE = "F1_ClimbersRest" -- the docks Waystone, if the quest points are missing
local STAND_HEIGHT = 3 -- studs above a point's top surface to place a character
local SETUP_TIMEOUT = 10 -- seconds to wait for CharacterService to finish a new character
local MOB_RESPAWN_DELAY = 1.5 -- seconds before a lost tutorial mob is replaced

local RULES: Steps.Rules = {
	ParriesNeeded = TUT.ParriesNeeded,
	SkipAfterSeconds = TUT.SkipAfterSeconds,
	CrabMob = TUT.CrabMob,
	TutorMob = TUT.TutorMob,
}

type Role = Steps.MobRole

type Session = {
	Player: Player,
	State: Steps.State,
	Mobs: { [Role]: Model? },
	PreviewGranted: boolean,
	LastResonance: number,
	StepOrigin: Vector3?, -- where the player stood when the step began (missing-point fallback)
	Maid: Maid.Maid, -- session-long connections and character watchers (key "Character")
}

export type Payload = {
	Kind: "Step" | "Progress" | "Finished" | "Skipped",
	Name: string, -- Steps.Names entry ("" once over)
	Point: Vector3?, -- where the waypoint goes (the mob, when Target is set, takes priority)
	Target: Model?, -- the tutorial mob this step is about
	Count: number, -- parries so far (step 5)
	Needed: number,
	CardOpen: boolean, -- step 7: show the big Resonance card
	SkipAt: number, -- server time the Skip button may appear
}

local TutorialService = {}

local sessions: { [Player]: Session } = {}

local function now(): number
	return Workspace:GetServerTimeNow()
end

-- WORLD --------------------------------------------------------------------------------------

local function findPoint(pointId: string): BasePart?
	for _, instance in CollectionService:GetTagged(Attributes.Tags.QuestPoint) do
		if instance:IsA("BasePart") and instance:GetAttribute(A.PointId) == pointId then
			return instance
		end
	end
	local floor = Workspace:FindFirstChild("Floor1")
	local folder = floor and floor:FindFirstChild("QuestPoints")
	if folder then
		for _, instance in folder:GetDescendants() do
			if instance:IsA("BasePart") and instance:GetAttribute(A.PointId) == pointId then
				return instance
			end
		end
	end
	return nil
end

local function pointRadius(part: BasePart): number
	local radius = part:GetAttribute(A.Radius)
	return if type(radius) == "number" and radius > 0 then radius else TUT.PointRadius
end

local function rootOf(player: Player): BasePart?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

-- Where to stand for a step: on its anchor point facing the step's point, else the docks Waystone.
local function anchorCFrame(step: number): CFrame?
	local anchor = findPoint(Steps.Anchor(step))
	if anchor then
		local at = anchor.Position + Vector3.new(0, anchor.Size.Y / 2 + STAND_HEIGHT, 0)
		local goal = findPoint(Steps.Points[math.clamp(step, 1, Steps.Count)])
		if goal then
			local flat = Vector3.new(goal.Position.X, at.Y, goal.Position.Z)
			if (flat - at).Magnitude > 0.5 then
				return CFrame.lookAt(at, flat)
			end
		end
		return CFrame.new(at)
	end
	return FloorService.GetWaystoneCFrame(FALLBACK_WAYSTONE)
end

-- Where tutorial mobs appear: the arena point, else a few strides in front of the player.
local function arenaPosition(player: Player): Vector3?
	local arena = findPoint("TutorialArena")
	if arena then
		return arena.Position
	end
	local root = rootOf(player)
	if root then
		return root.Position + root.CFrame.LookVector * TUT.PointRadius * 1.5
	end
	return nil
end

-- PROFILE AND CLIENT -------------------------------------------------------------------------

local function persist(session: Session)
	local player = session.Player
	local state = session.State
	DataService.Set(player, { "Tutorial", "Step" }, state.Step)
	DataService.Set(player, { "Tutorial", "Done" }, state.Done)
	DataService.Set(player, { "Tutorial", "Skipped" }, state.Skipped)
end

local function liveMob(session: Session, role: Role): Model?
	local model = session.Mobs[role]
	if not model or not model.Parent then
		return nil
	end
	local mob = MobService.GetMob(model)
	return if mob and not mob.Dead then model else nil
end

local function send(session: Session, kind: "Step" | "Progress")
	local state = session.State
	local step = state.Step
	local pointId = Steps.Points[step]
	local point = if pointId then findPoint(pointId) else nil
	local role: Role? = Steps.MobFor(step)
	local payload: Payload = {
		Kind = kind,
		Name = Steps.Names[step] or "",
		Point = if point then point.Position else nil,
		Target = if role then liveMob(session, role) else nil,
		Count = state.Count,
		Needed = if step == 5 then RULES.ParriesNeeded else 0,
		CardOpen = state.CardOpen,
		SkipAt = Steps.SkipAt(state, RULES),
	}
	Net.Fire("TutorialStep", session.Player, step, payload)
end

local function sendOver(player: Player, skipped: boolean)
	local payload: Payload = {
		Kind = if skipped then "Skipped" else "Finished",
		Name = "",
		Point = nil,
		Target = nil,
		Count = 0,
		Needed = 0,
		CardOpen = false,
		SkipAt = 0,
	}
	Net.Fire("TutorialStep", player, 0, payload)
end

-- PREVIEW SPELL ------------------------------------------------------------------------------

local function setPreview(session: Session, granted: boolean)
	if session.PreviewGranted == granted then
		return
	end
	session.PreviewGranted = granted
	SpellService.SetPreviewSpell(session.Player, if granted then TUT.PreviewSpell else nil)
	if granted then
		VitalsService.AddCurrent(session.Player, VitalsService.GetMaxCurrent(session.Player))
	end
end

-- MOBS ---------------------------------------------------------------------------------------

local ensureMobs: (session: Session) -> ()
local feed: (session: Session, event: Steps.Event) -> ()

local function despawnMob(session: Session, role: Role)
	local model = session.Mobs[role]
	session.Mobs[role] = nil
	if model and MobService.GetMob(model) then
		MobService.Despawn(model, true)
	end
end

local function onMobDied(session: Session, role: Role, mob: MobService.Mob)
	if sessions[session.Player] ~= session or session.Mobs[role] ~= mob.Model then
		return
	end
	session.Mobs[role] = nil
	local player = session.Player
	local step = session.State.Step
	local counts = if role == "Crab" then step == 3 and (mob.Contributors[player] or 0) > 0 else step == Steps.Count
	if counts then
		feed(session, { Kind = "Kill", Key = mob.MobId, Amount = 1 })
		return
	end
	-- Killed out of turn (someone else's crab kill, a huge blow on the tutor): bring it back.
	task.delay(MOB_RESPAWN_DELAY, function()
		if sessions[player] == session then
			ensureMobs(session)
			send(session, "Progress")
		end
	end)
end

-- Keeps the tutor above its floor until the last step.
local function guardTutor(session: Session, humanoid: Humanoid)
	session.Maid:Set(
		"TutorHealth",
		humanoid.HealthChanged:Connect(function(health: number)
			if session.State.Step < Steps.Count and health > 0 and health < humanoid.MaxHealth * TUT.TutorHealthFloor then
				humanoid.Health = humanoid.MaxHealth
			end
		end)
	)
end

local function spawnMob(session: Session, role: Role)
	local player = session.Player
	local position = arenaPosition(player)
	if not position then
		return
	end
	local root = rootOf(player)
	local facing = if root then root.Position - position else nil
	local allowed: { [Player]: boolean } = { [player] = true }
	local mob = MobService.Spawn(if role == "Crab" then TUT.CrabMob else TUT.TutorMob, position, false, nil, {
		AllowedTargets = allowed,
		Facing = facing,
		DamageMultiplier = TUT.TutorDamageScale,
		TelegraphScale = TUT.TutorTelegraphScale,
		OnDied = function(dead: MobService.Mob)
			onMobDied(session, role, dead)
		end,
	})
	if not mob then
		log:Warn(`Could not spawn the tutorial {role} for {player.Name}`)
		return
	end
	session.Mobs[role] = mob.Model
	if role == "Tutor" then
		guardTutor(session, mob.Humanoid)
		if session.State.Step == Steps.Count then
			mob.Humanoid.Health = mob.Humanoid.MaxHealth * TUT.TutorHealthFloor
		end
	end
	MobService.Engage(mob.Model, player)
end

ensureMobs = function(session: Session)
	local need = Steps.MobFor(session.State.Step)
	for _, role: Role in { "Crab", "Tutor" } :: { Role } do
		if need == role then
			if not liveMob(session, role) then
				spawnMob(session, role)
			end
		elseif session.Mobs[role] then
			despawnMob(session, role)
		end
	end
end

-- STEPS --------------------------------------------------------------------------------------

-- Side effects of being in the current step (on entry and on resume).
local function enterStep(session: Session)
	local step = session.State.Step
	local root = rootOf(session.Player)
	session.StepOrigin = if root then root.Position else nil
	setPreview(session, step == 6)
	if step == 7 and not session.State.CardOpen then
		-- A stack already showing on the HUD counts as the first one.
		local stacks = session.Player:GetAttribute(A.Resonance)
		if type(stacks) == "number" and stacks > 0 then
			Steps.Feed(session.State, { Kind = "Resonance", Key = "", Amount = stacks }, RULES)
		end
	end
	ensureMobs(session)
	if step == Steps.Count then
		local tutor = liveMob(session, "Tutor")
		local mob = tutor and MobService.GetMob(tutor)
		if mob then
			mob.Humanoid.Health = math.min(mob.Humanoid.Health, mob.Humanoid.MaxHealth * TUT.TutorHealthFloor)
		end
	end
end

local function giveFirstQuest(player: Player)
	local module = script.Parent:FindFirstChild("QuestService")
	if not module or not module:IsA("ModuleScript") then
		log:Warn("QuestService is missing; F1_M01 was not given")
		return
	end
	local ok, QuestService = pcall(require, module)
	local give = ok and type(QuestService) == "table" and (QuestService :: any).Give
	if type(give) ~= "function" then
		log:Warn("QuestService.Give is missing; F1_M01 was not given")
		return
	end
	local success, err = pcall(give, player, FIRST_QUEST)
	if not success then
		log:Warn(`QuestService.Give failed for {player.Name}: {tostring(err)}`)
	end
end

-- Tears a session down (mobs, preview spell, connections). The profile is left as it is.
local function cleanup(session: Session)
	if sessions[session.Player] == session then
		sessions[session.Player] = nil
	end
	setPreview(session, false)
	despawnMob(session, "Crab")
	despawnMob(session, "Tutor")
	session.Maid:Clean()
end

local function finish(session: Session)
	local player = session.Player
	local skipped = session.State.Skipped
	cleanup(session)
	persist(session)
	sendOver(player, skipped)
	giveFirstQuest(player)
	Net.Fire("Notify", player, if skipped then "Tutorial.Skipped" else "Tutorial.Finished", {}, "Success")
end

local function apply(session: Session, result: Steps.Result)
	if result == "Finished" then
		finish(session)
	elseif result == "Advanced" then
		enterStep(session)
		persist(session)
		send(session, "Step")
	elseif result == "Progress" then
		send(session, "Progress")
	end
end

feed = function(session: Session, event: Steps.Event)
	if sessions[session.Player] == session then
		apply(session, Steps.Feed(session.State, event, RULES))
	end
end

-- CHARACTER ----------------------------------------------------------------------------------

-- Health floor: tutorial blows can never take the player below HealthFloor of max.
local function guardPlayer(session: Session, humanoid: Humanoid): RBXScriptConnection
	return humanoid.HealthChanged:Connect(function(health: number)
		local floor = humanoid.MaxHealth * TUT.HealthFloor
		if sessions[session.Player] == session and health > 0 and health < floor then
			humanoid.Health = floor
		end
	end)
end

-- Waits for CharacterService to finish setting the character up (it registers the target
-- last), then places it at the step's anchor and re-sends the step.
local function onCharacter(session: Session, character: Model)
	local player = session.Player
	session.Maid:Set(
		"Character",
		task.spawn(function()
			local deadline = os.clock() + SETUP_TIMEOUT
			while os.clock() < deadline do
				local target = TargetService.GetForPlayer(player)
				if target and target.Model == character then
					break
				end
				task.wait()
			end
			if sessions[player] ~= session or player.Character ~= character then
				return
			end
			local cframe = anchorCFrame(session.State.Step)
			if cframe then
				CharacterService.Teleport(player, cframe)
			end
			local root = rootOf(player)
			session.StepOrigin = if root then root.Position else nil
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			if humanoid then
				session.Maid:Set("Health", guardPlayer(session, humanoid))
			end
			ensureMobs(session)
			send(session, "Step")
		end)
	)
end

-- SESSIONS -----------------------------------------------------------------------------------

local function start(player: Player)
	if sessions[player] or player.Parent ~= Players or FloorService.GetFloorId() ~= TUT.Floor then
		return
	end
	local tutorial = DataService.Get(player, { "Tutorial" })
	if type(tutorial) ~= "table" or tutorial.Done == true then
		return
	end
	local saved = tutorial.Step
	local session: Session = {
		Player = player,
		State = Steps.New(if type(saved) == "number" then saved else nil, now()),
		Mobs = {},
		PreviewGranted = false,
		LastResonance = 0,
		StepOrigin = nil,
		Maid = Maid.new(),
	}
	sessions[player] = session
	persist(session)

	session.Maid:Add(player:GetAttributeChangedSignal(A.Resonance):Connect(function()
		local stacks = player:GetAttribute(A.Resonance)
		local value = if type(stacks) == "number" then stacks else 0
		local rose = value > session.LastResonance
		session.LastResonance = value
		if rose then
			feed(session, { Kind = "Resonance", Key = "", Amount = value })
		end
	end))
	session.Maid:Add(player.CharacterAdded:Connect(function(character: Model)
		onCharacter(session, character)
	end))

	enterStep(session)
	local character = player.Character
	if character then
		onCharacter(session, character)
	else
		send(session, "Step")
	end
end

local function onRequest(player: Player, action: string)
	local session = sessions[player]
	if not session then
		return
	end
	if action == "Skip" then
		if Steps.Skip(session.State, now(), RULES) then
			finish(session)
		end
	elseif action == "Continue" then
		apply(session, Steps.Continue(session.State))
	end
end

-- Movement steps (1, 2). Without the quest points (world tool not run yet) moving a couple of
-- point radii from where the step began counts instead, so the tutorial can't get stuck.
local function checkPoints()
	for player, session in sessions do
		local step = session.State.Step
		local role: Role? = Steps.MobFor(step)
		local model = if role then session.Mobs[role] else nil
		local mob = if model then MobService.GetMob(model) else nil
		if role and model and not (mob and mob.Dead) and not liveMob(session, role) then
			-- Removed without dying (a dev clear; a death is OnDied's to handle): put it back.
			session.Mobs[role] = nil
			ensureMobs(session)
			send(session, "Progress")
		end
		local pointId = Steps.Points[step]
		local root = rootOf(player)
		if step > 2 or not pointId or not root then
			continue
		end
		local point = findPoint(pointId)
		local reached = false
		if point then
			reached = (root.Position - point.Position).Magnitude <= pointRadius(point)
		else
			local origin = session.StepOrigin
			if not origin then
				session.StepOrigin = root.Position
			else
				reached = (root.Position - origin).Magnitude >= TUT.PointRadius * 2
			end
		end
		if reached then
			feed(session, { Kind = "Reach", Key = pointId, Amount = 1, Sprinting = VitalsService.IsSprinting(player) })
		end
	end
end

-- PUBLIC API ---------------------------------------------------------------------------------

-- True while `player` is in the tutorial.
function TutorialService.IsActive(player: Player): boolean
	return sessions[player] ~= nil
end

function TutorialService.Init()
	Net.On("RequestTutorial", onRequest)
end

function TutorialService.Start()
	GameEvents.Fired:Connect(function(player: Player, kind: GameEvents.Kind, key: string, amount: number)
		local session = sessions[player]
		-- Kills come from the tutorial mobs' own OnDied (only this player's crab and tutor count).
		if not session or kind == "Kill" then
			return
		end
		local sprinting = if kind == "Reach" then VitalsService.IsSprinting(player) else nil
		feed(session, { Kind = kind, Key = key, Amount = amount, Sprinting = sprinting })
	end)

	DataService.ProfileLoaded:Connect(function(player: Player)
		start(player)
	end)
	for _, player in Players:GetPlayers() do
		if DataService.IsLoaded(player) then
			task.spawn(start, player)
		end
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		local session = sessions[player]
		if session then
			cleanup(session)
		end
	end)

	local accumulator = 0
	RunService.Heartbeat:Connect(function(dt: number)
		accumulator += dt
		if accumulator >= Config.Quests.ReachCheckSeconds then
			accumulator = 0
			checkPoints()
		end
	end)
end

return TutorialService
