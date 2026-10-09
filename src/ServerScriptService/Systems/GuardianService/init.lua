--!strict
--[[
	GuardianService
	Floor Guardian fights (Spec Section 10; docs/PHASE10_GUARDIAN.md). The Brinewarden guards the
	First Gate of Floor 1.

	Entry
	  Parts tagged SpireGuardianGate (attributes GuardianId, GatherRadius) get a server prompt. The
	  first challenger opens a gathering of Config GatherSeconds; anyone else who uses the gate in
	  that window joins, up to MaxPlayers. Players below the Guardian's level are warned but may
	  join. Dead players and players already in a fight or a dungeon run are ignored. When the
	  window closes, everyone still within GatherRadius of the gate goes in.

	The arena
	  ServerStorage.GuardianArenas.<Arena> is cloned into a free slot beyond the Spire wall
	  (ArenaOrigin + ArenaSpacing along +Z, MaxArenas slots), sealed, and the party is streamed in
	  and moved to its PlayerSpawns. The Warden spawns through MobService as a scripted mob (no
	  Brain): health scaled by the party size at the start, unflinching, a big body for hit checks,
	  lock points on its head, claw, back seam and (phase 3) core.

	The fight (Rules holds every pure decision; Moves runs the moves; Fight has shared helpers)
	  Intro: every member sees it (skippable after their first view, Floors.IntrosSeen); the
	  Warden is dormant until it ends for everyone. Then a 10 Hz loop picks the target (highest
	  threat, a live Taunt wins, else the nearest), walks to it and chooses moves (phase, range,
	  cooldown, condition, no move three times in a row, weighted). Health is clamped at each phase
	  threshold until the transition starts: the running move is cancelled, the Warden is immune
	  for Transition seconds, and the arena follows the phase (flood, Pressure, the tide cycle,
	  weak point side, the shell breaking in phase 3).

	The end
	  Victory: everyone who took part and earned a share (ContributionDamage of its health dealt, or
	  ContributionSeconds alive in the arena) gets XP, +1 GuardianKills and, on their first clear,
	  the next floor, Spire Shards and bonus skill points. The first clear of a floor on a server
	  is announced to everyone, and to other servers through MessagingService (rate-limited). After
	  CloseAfterSeconds the living are returned to the gate, receive their personal loot there, and
	  the arena is destroyed. Wipe: when every member is dead or gone the Warden fades, the party is
	  told, and the arena closes after CloseAfterSeconds (the dead rise at their Waystone as usual).
]]

local CollectionService = game:GetService("CollectionService")
local MessagingService = game:GetService("MessagingService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Attributes = require(Shared.Attributes)
local Strings = require(Shared.Strings)
local Net = require(Shared.Net)
local Log = require(Shared.Util.Log)
local Maid = require(Shared.Util.Maid)
local Guardians = require(Shared.Data.Guardians)
local Mobs = require(Shared.Data.Mobs)

local DataService = require(script.Parent.DataService)
local FloorService = require(script.Parent.FloorService)
local CombatService = require(script.Parent.CombatService)
local StatusService = require(script.Parent.StatusService)
local MobService = require(script.Parent.MobService)
local ProgressionService = require(script.Parent.ProgressionService)
local LootService = require(script.Parent.LootService)
local DungeonService = require(script.Parent.DungeonService)
local AntiExploitService = require(script.Parent.AntiExploitService)
local AnalyticsService = require(script.Parent.AnalyticsService)

local Types = require(script.Types)
local Rules = require(script.Rules)
local Arena = require(script.Arena)
local Fight = require(script.Fight)
local Moves = require(script.Moves)

local A = Attributes.Names
local G = Config.Mobs.Guardian
local AI = Config.Mobs.AI
local log = Log.new("GuardianService")

-- Teleports mirror DungeonService: stream the destination in (with this timeout), then arrive a
-- little above the marker so nobody spawns inside the floor; a party spreads out along X.
local STREAM_TIMEOUT = 5
local ARRIVE_HEIGHT = 3
local RETURN_SPACING = 3
-- Brain's approach rule: walk in to this fraction of the shortest melee move's MaxRange.
local APPROACH_FRACTION = 0.75
-- Validation of cross-server announcements (they come from our own servers, but are still checked).
local MAX_NAME_LENGTH = 32
local MAX_FLOOR_LENGTH = 8

type Fight = Types.Fight
type GuardianDef = Guardians.GuardianDef

type Gathering = {
	Gate: BasePart,
	GuardianId: string,
	Def: GuardianDef,
	Players: { Player },
	EndsAt: number,
}

local GuardianService = {}

local gates: { [BasePart]: ProximityPrompt } = {}
local gatherings: { [BasePart]: Gathering } = {}
local playerGathering: { [Player]: Gathering } = {}
local playerFight: { [Player]: Fight } = {}
local fights: { [number]: Fight } = {}
local slotsUsed: { [number]: boolean } = {}
local serverCleared: { [string]: boolean } = {}
local warnedOnce: { [string]: boolean } = {}
local lastPublish = -math.huge
local lastGlobalBanner = -math.huge
local serial = 0
local folder: Folder

local now = Fight.Now

-- pcall for functions that return nothing; the error message on failure.
local function protect(fn: () -> ()): (boolean, string?)
	local ok, err = pcall(function(): string?
		fn()
		return nil
	end)
	return ok, if ok then nil else tostring(err)
end

-- Defined below; the fight's end paths call each other.
local wipe: (Fight) -> ()
local close: (Fight) -> ()

local function errorOnce(key: string, message: string)
	if not warnedOnce[key] then
		warnedOnce[key] = true
		log:Error(message)
	end
end

local function notify(players: { Player }, key: string, args: { [string]: any }?, style: string)
	for _, player in players do
		Net.Fire("Notify", player, key, args or {}, style)
	end
end

local function bodyPart(model: Model, name: string): BasePart?
	local part = model:FindFirstChild(name)
	return if part and part:IsA("BasePart") then part else nil
end

-- Streams the destination in, then moves the character there (movement checks reset around it).
local function teleport(player: Player, cframe: CFrame)
	local character = player.Character
	if not character then
		return
	end
	pcall(function()
		player:RequestStreamAroundAsync(cframe.Position, STREAM_TIMEOUT)
	end)
	if player.Character ~= character or not character.Parent then
		return
	end
	AntiExploitService.ResetMovement(player)
	character:PivotTo(cframe + Vector3.new(0, ARRIVE_HEIGHT, 0))
	task.defer(AntiExploitService.ResetMovement, player)
end

-- Teleports everyone at once and waits until they have all arrived (each stream request times out).
local function teleportAll(moves: { { Player: Player, CFrame: CFrame } })
	local pending = #moves
	for _, entry in moves do
		task.spawn(function()
			local ok, err = protect(function()
				teleport(entry.Player, entry.CFrame)
			end)
			if not ok then
				log:Warn(`teleport of {entry.Player.Name} failed: {tostring(err)}`)
			end
			pending -= 1
		end)
	end
	while pending > 0 do
		task.wait()
	end
end

local function freeSlot(): number?
	for slot = 1, G.MaxArenas do
		if not slotsUsed[slot] then
			return slot
		end
	end
	return nil
end

-- MEMBERSHIP -----------------------------------------------------------------------------------

-- A member is out of the fight (died, left the server, or left the arena some other way).
local function removeMember(fight: Fight, player: Player)
	if not fight.Members[player] then
		return
	end
	fight.Members[player] = nil
	if playerFight[player] == fight then
		playerFight[player] = nil
	end
	local grab = fight.Grab
	if grab and grab.Victim == player then
		grab.Release(false)
	end
	local mob = fight.Mob
	if mob then
		mob.Threat[player] = nil
		if mob.Target == player then
			mob.Target = nil
		end
	end
	local model = fight.Model
	if model then
		pcall(function()
			model:RemovePersistentPlayer(player)
		end)
	end
	if next(fight.Members) == nil then
		wipe(fight)
	end
end

-- Drops members who died, left or are no longer in the arena; counts time alive inside.
local function updateMembers(fight: Fight, dt: number)
	for player in fight.Members do
		local root = Fight.RootOf(player)
		if not root or not Arena.Inside(fight.Arena, root.Position, fight.Arena.Radius) then
			removeMember(fight, player)
		else
			local participant = fight.Participants[player]
			if participant and Arena.Inside(fight.Arena, root.Position, 0) then
				participant.Inside += dt
			end
		end
	end
end

-- THE WARDEN -----------------------------------------------------------------------------------

local function setLockPoint(fight: Fight, name: string, enabled: boolean)
	local point = fight.LockPoints[name]
	if point then
		point:SetAttribute(A.Enabled, enabled)
	end
end

local function addLockPoint(fight: Fight, name: string, host: BasePart?, cframe: CFrame, enabled: boolean)
	if not host then
		return
	end
	local attachment = Instance.new("Attachment")
	attachment.Name = "LockPoint"
	attachment.CFrame = cframe
	attachment:SetAttribute(A.LockName, name)
	attachment:SetAttribute(A.Enabled, enabled)
	attachment.Parent = host
	fight.LockPoints[name] = attachment
end

local function setCoreVisible(model: Model, visible: boolean)
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") and part.Name == "Core" then
			part.Transparency = if visible then 0 else 1
			for _, child in part:GetChildren() do
				if child:IsA("Light") then
					child.Enabled = visible
				end
			end
		end
	end
end

-- Phase 3: the shell plates come loose and fade as they fall; the core shows.
local function breakShell(fight: Fight, seconds: number)
	local model = fight.Model
	if not model then
		return
	end
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") and part.Name == "Shell" then
			for _, joint in part:GetChildren() do
				if joint:IsA("WeldConstraint") then
					joint:Destroy()
				end
			end
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
			part.Anchored = false
			TweenService:Create(part, TweenInfo.new(seconds), { Transparency = 1 }):Play()
			task.delay(seconds, function()
				part:Destroy()
			end)
		end
	end
	setCoreVisible(model, true)
	setLockPoint(fight, "Back", false)
	setLockPoint(fight, "Core", true)
end

-- The arena and the Warden follow the tide (calm water and the phase's Pressure in phase 1).
local function applyTide(fight: Fight, seconds: number, announce: boolean)
	if announce then
		Fight.TideChanged(fight, seconds)
		return
	end
	local def = fight.Def
	local tide = fight.Tide
	Arena.SetWater(fight.Arena, Rules.WaterLevel(def, fight.Phase, tide.State), seconds)
	Arena.SetTideLines(fight.Arena, tide.State == "High", seconds)
	Arena.SetPressure(fight.Arena, Rules.TidePressure(def, fight.Phase, tide.State))
	local mob = fight.Mob
	if mob then
		mob.PostureTaken = Rules.PostureTaken(def, tide.State)
	end
	local model = fight.Model
	if model then
		model:SetAttribute(A.GuardianTide, tide.State)
		model:SetAttribute(A.GuardianTideEndsAt, tide.EndsAt)
	end
end

-- Crossing a health threshold: cancel the move, go immune for the transition, and change phase.
local function beginPhase(fight: Fight, phase: number)
	local def = fight.Def
	local model = fight.Model
	local mob = fight.Mob
	if not model or not mob then
		return
	end
	fight.Phase = phase
	Moves.Cancel(fight)
	Moves.ClearHazards(fight)
	local t = now()
	CombatService.GrantIFrames(model, def.Transition)
	fight.DormantUntil = t + def.Transition
	fight.NextMoveAt = math.max(fight.NextMoveAt, fight.DormantUntil)
	model:SetAttribute(A.GuardianPhase, phase)
	mob.WeakPoint = Rules.WeakPoint(def, phase)
	Fight.Fire(fight, "Phase", { Model = model, Phase = phase, Duration = def.Transition })

	-- The tide cycle starts with the first phase that has no fixed Pressure, and stops in one that has.
	local wasCalm = fight.Tide.State == "Calm"
	if Rules.TideRuns(def, phase) then
		if wasCalm then
			fight.Tide = Rules.StartTide(def, t, def.Transition)
			applyTide(fight, def.Transition, true)
		end
	elseif not wasCalm then
		fight.Tide = Rules.CalmTide()
		applyTide(fight, def.Transition, true)
	else
		applyTide(fight, def.Transition, false)
	end

	if Rules.IsLastPhase(phase) then
		-- From here its health is not clamped: it can die.
		mob.Humanoid:SetStateEnabled(Enum.HumanoidStateType.Dead, true)
		breakShell(fight, def.Transition)
	end
	Fight.Stop(fight)
	Fight.Face(fight, nil)
	Fight.SetMobState(fight, "Idle")
	log:Info(`fight {fight.Id}: phase {phase}`)
end

-- Health never drops past the next phase's threshold until that phase begins.
local function onHealthChanged(fight: Fight)
	local humanoid = fight.Humanoid
	if not humanoid or (fight.State ~= "Intro" and fight.State ~= "Active") then
		return
	end
	local floor = Rules.HealthFloor(fight.Phase, fight.MaxHealth)
	if humanoid.Health < floor then
		humanoid.Health = floor
	end
	local nextPhase = Rules.NextPhase(humanoid.Health, fight.Phase, fight.MaxHealth)
	if nextPhase then
		beginPhase(fight, nextPhase)
	end
end

-- PAYOUT ---------------------------------------------------------------------------------------

local function grantShards(player: Player, amount: number)
	if amount <= 0 then
		return
	end
	local balance = DataService.Increment(player, { "Currencies", "Shards" }, amount, 0, Config.Economy.MaxShards)
	if balance then
		AnalyticsService.Economy(player, "Source", "Shards", amount, balance, "Gameplay", "Guardian")
	end
end

-- XP and the kill count for everyone with a share; the first clear adds the next floor, Shards
-- and skill points. Returns true for a first clear.
local function payOut(fight: Fight, player: Player): boolean
	local def = fight.Def
	local data = DataService.GetData(player)
	if not data then
		return false
	end
	ProgressionService.AwardGuardianKill(player, def.Rewards.XP)
	local first = data.Floors.GuardiansCleared[def.Floor] == nil
	if first then
		-- Marked cleared before anything is granted, so the first-clear rewards can't repeat.
		DataService.Set(player, { "Floors", "GuardiansCleared", def.Floor }, os.time())
		DataService.Set(player, { "Floors", "Unlocked", def.NextFloor }, true)
		grantShards(player, def.Rewards.Shards)
		ProgressionService.AwardSkillPoints(player, Config.Progression.GuardianBonusSkillPoints)
		DataService.SaveNow(player)
	end
	AnalyticsService.Progression(player, "Guardian", "Complete", tonumber(def.Floor) or 0, fight.GuardianId)
	-- No floor beyond this one is reachable yet: the way is open, its stair comes later.
	Net.Fire("Notify", player, "Guardians.NextFloorPending", { name = Strings.Guardians.Floors[def.NextFloor] or def.NextFloor }, "Info")
	return first
end

-- The Guardian's body with its gold range, for LootService's personal roll from its loot table.
local function lootBody(def: GuardianDef): Mobs.MobDef?
	local body = Mobs.Get(def.MobId)
	if not body then
		return nil
	end
	local copy = table.clone(body)
	copy.Rewards = { XP = 0, GoldMin = def.Rewards.GoldMin, GoldMax = def.Rewards.GoldMax }
	return copy
end

-- ANNOUNCEMENTS --------------------------------------------------------------------------------

local function publish(floor: string, names: { string })
	local t = os.clock()
	if t - lastPublish < G.AnnounceCooldown then
		return
	end
	lastPublish = t
	task.spawn(function()
		local ok, err = pcall(function()
			MessagingService:PublishAsync(G.AnnounceTopic, { Floor = floor, Names = names, JobId = game.JobId })
		end)
		if not ok then
			log:Warn(`announce publish failed: {tostring(err)}`)
		end
	end)
end

-- Another server cleared a floor first on that server: a smaller "Across the Spire" toast here.
local function onAnnouncement(message: any)
	local data = if type(message) == "table" then message.Data else nil
	if type(data) ~= "table" then
		return
	end
	local jobId, floor, names = data.JobId, data.Floor, data.Names
	if type(jobId) ~= "string" or jobId == game.JobId then
		return
	end
	if type(floor) ~= "string" or #floor == 0 or #floor > MAX_FLOOR_LENGTH or type(names) ~= "table" then
		return
	end
	local t = os.clock()
	if t - lastGlobalBanner < G.AnnounceCooldown then
		return
	end
	local clean: { string } = {}
	for index = 1, math.min(#names, G.MaxPlayers) do
		local name = names[index]
		if type(name) == "string" and #name > 0 and #name <= MAX_NAME_LENGTH then
			table.insert(clean, name)
		end
	end
	if #clean == 0 then
		return
	end
	lastGlobalBanner = t
	Net.FireAll("GuardianEvent", "Banner", { Scope = "Global", Floor = floor, Names = clean })
end

local function announceClear(fight: Fight)
	local floor = fight.Def.Floor
	if serverCleared[floor] then
		return
	end
	serverCleared[floor] = true
	Net.FireAll("GuardianEvent", "Banner", { Scope = "Server", Floor = floor, Names = fight.Names })
	publish(floor, fight.Names)
end

-- THE END --------------------------------------------------------------------------------------

local function returnCFrame(fight: Fight, player: Player): CFrame
	local holder = fight.Gate.Parent
	local marker = holder and holder:FindFirstChild("Return")
	if marker and marker:IsA("BasePart") then
		return marker.CFrame
	end
	return FloorService.GetSpawnCFrame(player)
end

-- After a victory or wipe: the living go back to the gate (victors get their loot there), then
-- the arena closes.
local function returnAndClose(fight: Fight)
	if fight.State ~= "Victory" and fight.State ~= "Wipe" then
		return
	end
	local moves = {}
	for index, player in Fight.MemberList(fight) do
		if Fight.RootOf(player) then
			local base = returnCFrame(fight, player)
			table.insert(moves, { Player = player, CFrame = base * CFrame.new((index - 1) * RETURN_SPACING - RETURN_SPACING, 0, 0) })
		end
	end
	teleportAll(moves)
	if fight.State == "Victory" then
		local def = fight.Def
		local body = lootBody(def)
		for _, player in fight.Eligible do
			if body and player.Parent == Players then
				local root = Fight.RootOf(player)
				local position = if root then root.Position else returnCFrame(fight, player).Position
				local ok, err = protect(function()
					LootService.AwardKill(def.Rewards.LootTable, body, false, { player }, position, nil)
				end)
				if not ok then
					log:Error(`loot for {player.Name} failed: {tostring(err)}`)
				end
			end
		end
	end
	close(fight)
end

local function victory(fight: Fight)
	if fight.State ~= "Active" then
		return
	end
	fight.State = "Victory"
	Moves.Cancel(fight)
	Moves.ClearHazards(fight)
	Moves.DespawnAdds(fight)
	local def = fight.Def
	local mob = fight.Mob
	local seconds = math.max(0, now() - fight.StartedAt)
	local firstClears: { [Player]: boolean } = {}
	for player, participant in fight.Participants do
		if player.Parent == Players then
			local damage = if mob then mob.Contributors[player] or 0 else 0
			if Rules.Eligible(damage, fight.MaxHealth, participant.Inside) then
				table.insert(fight.Eligible, player)
				local ok, result = pcall(payOut, fight, player)
				if ok then
					firstClears[player] = result == true
				else
					log:Error(`payout for {player.Name} failed: {tostring(result)}`)
				end
			end
		end
	end
	for _, player in Fight.ParticipantList(fight) do
		local first = firstClears[player] == true
		Net.Fire("GuardianEvent", player, "Victory", {
			Model = fight.Model,
			Seconds = seconds,
			Names = fight.Names,
			FirstClear = first,
			Unlocked = if first then def.NextFloor else nil,
		})
	end
	announceClear(fight)
	log:Info(`fight {fight.Id}: {fight.GuardianId} felled in {string.format("%.0f", seconds)}s ({#fight.Eligible} rewarded)`)
	fight.Maid:Add(task.delay(G.CloseAfterSeconds, returnAndClose, fight))
end

wipe = function(fight: Fight)
	if fight.State ~= "Intro" and fight.State ~= "Active" then
		return
	end
	fight.State = "Wipe"
	Moves.Cancel(fight)
	Moves.ClearHazards(fight)
	Moves.DespawnAdds(fight)
	local model = fight.Model
	if model then
		MobService.Despawn(model, true) -- the Warden resets: it fades away
	end
	for _, player in Fight.ParticipantList(fight) do
		Net.Fire("GuardianEvent", player, "Wipe", {})
		AnalyticsService.Progression(player, "Guardian", "Fail", tonumber(fight.Def.Floor) or 0, fight.GuardianId)
	end
	log:Info(`fight {fight.Id}: wipe`)
	fight.Maid:Add(task.delay(G.CloseAfterSeconds, returnAndClose, fight))
end

close = function(fight: Fight)
	if fight.State == "Closed" then
		return
	end
	fight.State = "Closed"
	Moves.Cancel(fight)
	Moves.ClearHazards(fight)
	Moves.DespawnAdds(fight)
	local grab = fight.Grab
	if grab then
		grab.Release(false)
	end
	local model = fight.Model
	if model then
		MobService.Despawn(model, false)
	end
	for player in fight.Participants do
		if playerFight[player] == fight then
			playerFight[player] = nil
		end
	end
	table.clear(fight.Members)
	fights[fight.Id] = nil
	slotsUsed[fight.Slot] = nil
	Arena.Destroy(fight.Arena)
	fight.Maid:Clean()
	log:Info(`fight {fight.Id}: closed (slot {fight.Slot})`)
end

-- THE LOOP -------------------------------------------------------------------------------------

-- Highest threat among living members (a live Taunt wins); the nearest if nobody has hurt it.
local function pickTarget(fight: Fight): (Player?, BasePart?)
	local mob = fight.Mob
	if not mob then
		return nil, nil
	end
	local t = now()
	local taunter = mob.TauntedBy
	if taunter then
		local root = if t < mob.TauntUntil and fight.Members[taunter] then Fight.RootOf(taunter) else nil
		if root then
			return taunter, root
		end
		mob.TauntedBy = nil
	end
	local best: Player? = nil
	local bestRoot: BasePart? = nil
	local bestThreat = 0
	for player, threat in mob.Threat do
		local root = if fight.Members[player] then Fight.RootOf(player) else nil
		if not root then
			mob.Threat[player] = nil
		elseif threat > bestThreat then
			best, bestRoot, bestThreat = player, root, threat
		end
	end
	if best and bestRoot then
		return best, bestRoot
	end
	local distance = math.huge
	for _, member in Fight.Living(fight) do
		local d = Rules.FlatDistance(mob.Root.Position, member.Root.Position)
		if d < distance then
			best, bestRoot, distance = member.Player, member.Root, d
		end
	end
	return best, bestRoot
end

local function context(fight: Fight, target: Player, distance: number, t: number): Rules.Context
	local def = fight.Def
	local root = fight.Root :: BasePart
	local look = Fight.Look(fight)
	local living = Fight.Living(fight)
	local behind: { number } = {}
	for _, member in living do
		if Rules.IsBehind(root.Position, look, member.Root.Position) then
			table.insert(behind, Rules.FlatDistance(root.Position, member.Root.Position))
		end
	end
	local blockedAt = fight.BlockedAt[target]
	return {
		Phase = fight.Phase,
		Now = t,
		Distance = distance,
		Cooldowns = fight.Cooldowns,
		LastMove = fight.LastMove,
		Repeats = fight.Repeats,
		TargetBlocking = blockedAt ~= nil and t - blockedAt <= G.BlockingMemory,
		Behind = behind,
		TideRunning = fight.Tide.State ~= "Calm",
		TideChanging = Rules.TideChanging(def, fight.Tide, t, 0),
		AddsAlive = Moves.AddsAlive(fight),
		AddsWanted = Rules.AddCount(def, #living),
	}
end

-- How close it walks in: within reach of its shortest melee move this phase.
local function approachRange(fight: Fight): number
	local want = math.huge
	for _, move in fight.Def.Moves do
		if move.MinRange <= 0 and move.MaxRange < want and Rules.InPhase(move, fight.Phase) then
			want = move.MaxRange
		end
	end
	return if want == math.huge then fight.Def.HitRadius * 2 else want * APPROACH_FRACTION
end

local function approach(fight: Fight, targetRoot: BasePart, distance: number)
	local mob = fight.Mob
	if not mob then
		return
	end
	Fight.SetMobState(fight, "Chase")
	if distance > approachRange(fight) then
		Fight.Face(fight, nil)
		mob.Humanoid.WalkSpeed = mob.Def.RunSpeed * StatusService.SpeedMultiplier(mob.Model)
		mob.Humanoid:MoveTo(Arena.Clamp(fight.Arena, targetRoot.Position, fight.Def.HitRadius))
	else
		Fight.Stop(fight)
		Fight.Face(fight, targetRoot.Position)
	end
end

local function think(fight: Fight, dt: number)
	if fight.State ~= "Intro" and fight.State ~= "Active" then
		return
	end
	local mob = fight.Mob
	if not mob or mob.Dead or not mob.Model.Parent then
		wipe(fight) -- the Warden is gone: the fight resets
		return
	end
	updateMembers(fight, dt)
	if fight.State ~= "Intro" and fight.State ~= "Active" then
		return
	end
	local t = now()
	if fight.State == "Intro" then
		if t < fight.StartedAt then
			return
		end
		fight.State = "Active"
		fight.NextMoveAt = t + Rules.MoveGap(fight.Def, fight.Phase, fight.Random:NextNumber())
	end

	-- the tide, the adds, fading threat and who has been blocking
	local event = Rules.TickTide(fight.Def, fight.Tide, t)
	if event == "Warn" then
		Fight.TideWarning(fight)
	elseif event == "Change" then
		Fight.TideChanged(fight, fight.Def.Tide.WarnSeconds)
	end
	Moves.ExpireAdds(fight, t)
	local keep = math.max(0, 1 - Config.Mobs.Threat.DecayPerSecond * dt)
	for player, threat in mob.Threat do
		mob.Threat[player] = threat * keep
	end
	for _, member in Fight.Living(fight) do
		local character = member.Player.Character
		if character and character:GetAttribute(A.CombatState) == "Blocking" then
			fight.BlockedAt[member.Player] = t
		end
	end

	-- knocked out of the arena somehow: back to its spawn
	if not Arena.Inside(fight.Arena, mob.Root.Position, fight.Def.HitRadius) then
		Moves.Cancel(fight)
		local height = mob.Humanoid.HipHeight + mob.Root.Size.Y / 2
		mob.Model:PivotTo(fight.Arena.BossSpawn + Vector3.new(0, height, 0))
	end

	local action = CombatService.GetAction(mob.Model)
	if action == "Broken" then
		Moves.Cancel(fight)
		Fight.Stop(fight)
		Fight.SetMobState(fight, "Broken")
		return
	elseif action == "Staggered" then
		Fight.SetMobState(fight, "Staggered") -- rising from a finisher
		return
	end
	if fight.Move then
		return
	end
	if t < fight.DormantUntil then
		Fight.Stop(fight)
		Fight.SetMobState(fight, "Idle")
		return
	end
	local target, targetRoot = pickTarget(fight)
	if not target or not targetRoot then
		Fight.Stop(fight)
		Fight.SetMobState(fight, "Idle")
		return
	end
	mob.Target = target
	local distance = Rules.FlatDistance(mob.Root.Position, targetRoot.Position)
	if t >= fight.NextMoveAt then
		local option = Rules.Choose(fight.Def, context(fight, target, distance, t), fight.Random:NextNumber())
		if option then
			Moves.Start(fight, option.Id, option.Move, target)
			return
		end
	end
	approach(fight, targetRoot, distance)
end

local function runLoop(fight: Fight)
	local last = os.clock()
	while fight.State ~= "Closed" do
		task.wait(1 / AI.TickRateNear)
		local clock = os.clock()
		local dt = clock - last
		last = clock
		local ok, err = protect(function()
			think(fight, dt)
		end)
		if not ok then
			log:Error(`fight {fight.Id} think failed: {tostring(err)}`)
		end
	end
end

-- STARTING A FIGHT -----------------------------------------------------------------------------

local function spawnWarden(fight: Fight): boolean
	local def = fight.Def
	local arena = fight.Arena
	local mob = MobService.Spawn(def.MobId, arena.BossSpawn.Position, false, nil, {
		Scripted = true,
		MaxHealth = fight.MaxHealth,
		MaxPosture = def.MaxPosture,
		HitRadius = def.HitRadius,
		HitHeight = def.HitHeight,
		Facing = arena.BossSpawn.LookVector,
		AllowedTargets = fight.Members,
		OnDied = function()
			victory(fight)
		end,
	})
	if not mob then
		return false
	end
	local model = mob.Model
	fight.Mob = mob
	fight.Model = model
	fight.Humanoid = mob.Humanoid
	fight.Root = mob.Root

	CombatService.SetUnflinching(model, true)
	CombatService.SetBrokenDuration(model, def.BrokenDuration)
	-- Health clamps at each threshold; until the last phase a single huge blow can't kill it either.
	mob.Humanoid:SetStateEnabled(Enum.HumanoidStateType.Dead, false)
	mob.WeakPoint = Rules.WeakPoint(def, 1)
	model:SetAttribute(A.GuardianId, fight.GuardianId)
	model:SetAttribute(A.GuardianPhase, 1)
	model:SetAttribute(A.MobState, "Idle")
	CollectionService:AddTag(model, Attributes.Tags.Guardian)

	local torso = bodyPart(model, "UpperTorso")
	local seam = bodyPart(model, "Seam")
	local core = bodyPart(model, "Core")
	local depth = if torso then torso.Size.Z / 2 else 0
	addLockPoint(fight, "Head", bodyPart(model, "Head"), CFrame.identity, true)
	addLockPoint(fight, "RightClaw", bodyPart(model, "RightClaw") or bodyPart(model, "RightHand"), CFrame.identity, true)
	addLockPoint(fight, "Back", seam or torso, if seam then CFrame.identity else CFrame.new(0, 0, depth), true)
	addLockPoint(fight, "Core", core or torso, if core then CFrame.identity else CFrame.new(0, 0, -depth), false)
	setCoreVisible(model, false)

	-- Members always have the Warden streamed in, so payloads naming it resolve on their clients.
	pcall(function()
		model.ModelStreamingMode = Enum.ModelStreamingMode.PersistentPerPlayer
	end)
	for player in fight.Members do
		pcall(function()
			model:AddPersistentPlayer(player)
		end)
	end

	fight.Maid:Add(mob.Humanoid.HealthChanged:Connect(function()
		onHealthChanged(fight)
	end))
	return true
end

-- Builds the arena, spawns the Warden, moves the party in and plays the intro.
local function enterFight(fight: Fight, group: { Player })
	local def = fight.Def
	local arena = fight.Arena
	Arena.SetSealed(arena, true)
	if not spawnWarden(fight) then
		error(`could not spawn {def.MobId}`)
	end
	applyTide(fight, 0, false)

	local moves = {}
	local spawns = arena.PlayerSpawns
	for index, player in group do
		local cframe = if #spawns > 0
			then spawns[(index - 1) % #spawns + 1]
			else arena.Origin * CFrame.new(0, 0, arena.Radius / 2)
		table.insert(moves, { Player = player, CFrame = cframe })
	end
	teleportAll(moves)
	-- anyone who died or left on the way is out
	for _, player in group do
		local root = Fight.RootOf(player)
		if not root or not Arena.Inside(arena, root.Position, arena.Radius) then
			removeMember(fight, player)
		end
	end
	if fight.State ~= "Starting" or next(fight.Members) == nil then
		close(fight)
		return
	end

	local model = fight.Model :: Model
	local intro = if def.Intro > 0 then def.Intro else G.IntroDuration
	local t = now()
	fight.StartedAt = t + intro
	fight.DormantUntil = fight.StartedAt
	fight.NextMoveAt = fight.StartedAt
	CombatService.GrantIFrames(model, intro)
	model:SetAttribute(A.FightStartedAt, fight.StartedAt)
	for player in fight.Members do
		local data = DataService.GetData(player)
		local seen = data ~= nil and data.Floors.IntrosSeen[fight.GuardianId] == true
		Net.Fire("GuardianEvent", player, "Intro", { Model = model, Duration = intro, Skippable = seen })
		if data and not seen then
			DataService.Set(player, { "Floors", "IntrosSeen", fight.GuardianId }, true)
		end
		AnalyticsService.Progression(player, "Guardian", "Start", tonumber(def.Floor) or 0, fight.GuardianId)
	end
	fight.State = "Intro"
	fight.Maid:Add(task.spawn(runLoop, fight))
	log:Info(`fight {fight.Id}: {fight.GuardianId} for {#group} in slot {fight.Slot}`)
end

local function startFight(gate: BasePart, guardianId: string, def: GuardianDef, group: { Player })
	local template = Arena.Template(def.Arena)
	if not template then
		errorOnce(`template:{def.Arena}`, `no arena template ServerStorage.GuardianArenas.{def.Arena} (run Tools.Floor1GuardianArena)`)
		notify(group, "Guardians.ArenaBusy", nil, "Warning")
		return
	end
	if not Mobs.Get(def.MobId) then
		errorOnce(`body:{def.MobId}`, `no body {def.MobId} in Shared.Data.Mobs`)
		notify(group, "Guardians.ArenaBusy", nil, "Warning")
		return
	end
	local slot = freeSlot()
	if not slot then
		notify(group, "Guardians.ArenaBusy", nil, "Warning")
		return
	end
	slotsUsed[slot] = true
	serial += 1
	local built, arena = pcall(Arena.Create, template, slot, folder, `{guardianId}_{serial}`)
	if not built then
		slotsUsed[slot] = nil
		errorOnce(`arena:{def.Arena}`, `could not build arena {def.Arena}: {tostring(arena)}`)
		notify(group, "Guardians.ArenaBusy", nil, "Warning")
		return
	end
	local fight: Fight = {
		Id = serial,
		GuardianId = guardianId,
		Def = def,
		Gate = gate,
		Arena = arena,
		Slot = slot,
		State = "Starting",
		Mob = nil,
		Model = nil,
		Humanoid = nil,
		Root = nil,
		MaxHealth = Rules.MaxHealth(def, #group),
		LockPoints = {},
		Members = {},
		Participants = {},
		Names = {},
		StartCount = #group,
		Phase = 1,
		Tide = Rules.CalmTide(),
		StartedAt = math.huge,
		DormantUntil = math.huge,
		NextMoveAt = math.huge,
		Move = nil,
		Cooldowns = {},
		LastMove = nil,
		Repeats = 0,
		SweepMirrored = false,
		BlockedAt = {},
		Adds = {},
		Hazards = {},
		Grab = nil,
		Eligible = {},
		Random = Random.new(),
		Maid = Maid.new(),
	}
	fight.SweepMirrored = fight.Random:NextNumber() < 0.5 -- the first Coral Sweep opens from a random side
	fights[fight.Id] = fight
	for _, player in group do
		fight.Members[player] = true
		fight.Participants[player] = { Player = player, Name = player.DisplayName, Inside = 0 }
		table.insert(fight.Names, player.DisplayName)
		playerFight[player] = fight
	end
	local ok, err = protect(function()
		enterFight(fight, group)
	end)
	if not ok then
		log:Error(`fight {fight.Id} failed to start: {tostring(err)}`)
		notify(Fight.MemberList(fight), "Guardians.ArenaBusy", nil, "Warning")
		-- whoever was already moved in goes back to the gate
		local moves = {}
		for _, player in Fight.MemberList(fight) do
			if Fight.RootOf(player) then
				table.insert(moves, { Player = player, CFrame = returnCFrame(fight, player) })
			end
		end
		teleportAll(moves)
		close(fight)
	end
end

-- THE GATE -------------------------------------------------------------------------------------

local function gatherRadius(gate: BasePart): number
	local radius = gate:GetAttribute("GatherRadius")
	return if type(radius) == "number" and radius > 0 then radius else G.GatherRadius
end

local function fireGather(gathering: Gathering, only: Player?)
	local payload = { EndsAt = gathering.EndsAt, Count = #gathering.Players, Max = G.MaxPlayers }
	if only then
		Net.Fire("GuardianEvent", only, "Gather", payload)
	else
		Net.FireList("GuardianEvent", gathering.Players, "Gather", payload)
	end
end

local function leaveGathering(gathering: Gathering, player: Player)
	local index = table.find(gathering.Players, player)
	if index then
		table.remove(gathering.Players, index)
		fireGather(gathering)
	end
	if playerGathering[player] == gathering then
		playerGathering[player] = nil
	end
end

local function finishGathering(gathering: Gathering)
	if gatherings[gathering.Gate] ~= gathering then
		return
	end
	gatherings[gathering.Gate] = nil
	local radius = gatherRadius(gathering.Gate)
	local group: { Player } = {}
	for _, player in gathering.Players do
		if playerGathering[player] == gathering then
			playerGathering[player] = nil
		end
		local root = Fight.RootOf(player)
		local free = playerFight[player] == nil and DungeonService.GetRun(player) == nil
		if root and free and (root.Position - gathering.Gate.Position).Magnitude <= radius then
			table.insert(group, player)
		end
	end
	if #group > 0 then
		task.spawn(startFight, gathering.Gate, gathering.GuardianId, gathering.Def, group)
	end
end

local function onChallenge(gate: BasePart, player: Player)
	local id = gate:GetAttribute(A.GuardianId)
	local def = if type(id) == "string" then Guardians.Get(id) else nil
	if not def or type(id) ~= "string" then
		return
	end
	local root = Fight.RootOf(player)
	if not root or playerFight[player] or DungeonService.GetRun(player) ~= nil then
		return
	end
	local prompt = gates[gate]
	local reach = (if prompt then prompt.MaxActivationDistance else Config.World.Waystones.InteractDistance)
		+ Config.Combat.HitValidation.ReachTolerance
	if (root.Position - gate.Position).Magnitude > reach then
		return
	end
	local data = DataService.GetData(player)
	if not data then
		return
	end
	local gathering = gatherings[gate]
	if gathering and table.find(gathering.Players, player) then
		fireGather(gathering, player)
		return
	end
	local other = playerGathering[player]
	if other and other ~= gathering then
		leaveGathering(other, player)
	end
	if not gathering then
		local created: Gathering = { Gate = gate, GuardianId = id, Def = def, Players = {}, EndsAt = now() + G.GatherSeconds }
		gatherings[gate] = created
		gathering = created
		task.delay(G.GatherSeconds, finishGathering, created)
	end
	local current = gathering :: Gathering
	if #current.Players >= G.MaxPlayers then
		return
	end
	table.insert(current.Players, player)
	playerGathering[player] = current
	if data.Level < def.Level then
		Net.Fire("Notify", player, "Guardians.BelowLevel", { level = def.Level }, "Warning")
	end
	fireGather(current)
	if #current.Players >= G.MaxPlayers then
		task.defer(finishGathering, current)
	end
end

local function registerGate(instance: Instance)
	if not instance:IsA("BasePart") or gates[instance] then
		return
	end
	local gate = instance
	local id = gate:GetAttribute(A.GuardianId)
	if type(id) ~= "string" or not Guardians.Get(id) then
		log:Warn(`Guardian gate {gate:GetFullName()} needs a GuardianId attribute naming a Guardian`)
		return
	end
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "GuardianPrompt"
	prompt.Style = Enum.ProximityPromptStyle.Custom
	prompt.ActionText = Strings.Guardians.Prompt
	prompt.ObjectText = Strings.Guardians.PromptObject
	prompt.HoldDuration = Config.World.Waystones.RestHoldDuration
	prompt.MaxActivationDistance = Config.World.Waystones.InteractDistance
	prompt.RequiresLineOfSight = false
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.GamepadKeyCode = Enum.KeyCode.ButtonX
	prompt.Parent = gate
	prompt.Triggered:Connect(function(player: Player)
		onChallenge(gate, player)
	end)
	gates[gate] = prompt
end

-- PUBLIC API -----------------------------------------------------------------------------------

-- True while the player is fighting a Guardian (or being moved into one).
function GuardianService.IsInFight(player: Player): boolean
	return playerFight[player] ~= nil
end

function GuardianService.Init()
	local existing = Workspace:FindFirstChild("GuardianArenas")
	if existing and existing:IsA("Folder") then
		folder = existing
	else
		local created = Instance.new("Folder")
		created.Name = "GuardianArenas"
		created.Parent = Workspace
		folder = created
	end
end

function GuardianService.Start()
	for _, instance in CollectionService:GetTagged(Attributes.Tags.GuardianGate) do
		registerGate(instance)
	end
	CollectionService:GetInstanceAddedSignal(Attributes.Tags.GuardianGate):Connect(registerGate)
	CollectionService:GetInstanceRemovedSignal(Attributes.Tags.GuardianGate):Connect(function(instance: Instance)
		if instance:IsA("BasePart") then
			local prompt = gates[instance]
			gates[instance] = nil
			if prompt then
				prompt:Destroy()
			end
		end
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		local gathering = playerGathering[player]
		if gathering then
			leaveGathering(gathering, player)
		end
		local fight = playerFight[player]
		if fight then
			removeMember(fight, player)
		end
		playerFight[player] = nil
		playerGathering[player] = nil
		for _, other in fights do
			other.BlockedAt[player] = nil
		end
	end)

	task.spawn(function()
		local ok, err = pcall(function()
			MessagingService:SubscribeAsync(G.AnnounceTopic, onAnnouncement)
		end)
		if not ok then
			log:Warn(`cross-server announcements unavailable: {tostring(err)}`)
		end
	end)
end

return GuardianService
