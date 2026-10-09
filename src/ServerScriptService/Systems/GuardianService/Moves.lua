--!strict
--[[
	Moves (GuardianService)
	The Warden's moves, one runner per Kind in Shared/Data/Guardians. A move runs in its own thread
	and owns the Warden until it ends: wind-up (MobBlow tells clients which animation, when it
	lands and whether it glints red; area moves also draw a ground Telegraph for the party), the
	blow, then the Recovery window. Every blow lands through CombatService (NpcSwing / NpcHit), so
	dodge i-frames, parries and blocks work exactly as against any enemy.

	Moves.Cancel stops a move from outside (a posture break, a phase change, the fight ending) and
	always runs its cleanups: a player held in the claw is let go on every exit path.

	Some effects outlive the move that made them (whirlpools, the travelling tidal wave): they run
	as hazards until they finish, a phase changes or the fight ends.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Attributes = require(Shared.Attributes)
local Guardians = require(Shared.Data.Guardians)
local Net = require(Shared.Net)
local Log = require(Shared.Util.Log)

local CombatService = require(script.Parent.Parent.CombatService)
local MobService = require(script.Parent.Parent.MobService)
local StatusService = require(script.Parent.Parent.StatusService)
local AntiExploitService = require(script.Parent.Parent.AntiExploitService)
local Types = require(script.Parent.Types)
local Rules = require(script.Parent.Rules)
local Arena = require(script.Parent.Arena)
local Fight = require(script.Parent.Fight)

local A = Attributes.Names
local FREED_STAGGER = 0.25 -- seconds a player freed from the claw early still staggers
local MOVE = Config.Mobs.Movement
local PAD = Config.Combat.HitValidation.TargetRadius -- blows land on a body, not a point
local STEP = 1 / 30 -- seconds between checks while a move is live
local BUSY_PAD = 0.25 -- the attack state outlasts the last blow by this much (as Brain does)
local FLAG_UNPARRYABLE = 1 -- Telegraph flags bit: drawn red (Net Definitions)

local log = Log.new("GuardianService")

local Moves = {}

-- pcall for functions that return nothing; the error message on failure.
local function protect(fn: () -> ()): (boolean, string?)
	local ok, err = pcall(function(): string?
		fn()
		return nil
	end)
	return ok, if ok then nil else tostring(err)
end

local now = Fight.Now
local flat = Fight.Flat

type Fight = Types.Fight
type MoveRun = Types.MoveRun
type GuardianMove = Guardians.GuardianMove

-- CORE -----------------------------------------------------------------------------------------

-- True while the Warden may keep acting: fighting, alive and not kneeling from a posture break.
function Moves.CanAct(fight: Fight): boolean
	local mob = fight.Mob
	if fight.State ~= "Active" or not mob or mob.Dead or not mob.Model.Parent then
		return false
	end
	return CombatService.GetAction(mob.Model) ~= "Broken"
end

-- Waits until server time `t`, calling `onStep(remaining)` meanwhile. False if the move must stop.
local function waitUntil(fight: Fight, t: number, onStep: ((number) -> ())?): boolean
	while true do
		if not Moves.CanAct(fight) then
			return false
		end
		local remaining = t - now()
		if remaining <= 0 then
			return true
		end
		if onStep then
			onStep(remaining)
		end
		task.wait(math.min(remaining, STEP))
	end
end

-- Ends `run` (from inside its thread or from outside). Idempotent.
local function finish(fight: Fight, run: MoveRun)
	if fight.Move ~= run then
		return
	end
	fight.Move = nil
	local thread = run.Thread
	run.Thread = nil
	if thread and thread ~= coroutine.running() and coroutine.status(thread) ~= "dead" then
		task.cancel(thread)
	end
	for index = #run.Cleanups, 1, -1 do
		local ok, err = protect(run.Cleanups[index])
		if not ok then
			log:Error(`{run.Id} cleanup failed: {tostring(err)}`)
		end
	end
	table.clear(run.Cleanups)
	local model = fight.Model
	if model then
		CombatService.NpcEndAttack(model)
	end
	Fight.Stop(fight)
	Fight.Face(fight, nil)
	if fight.State == "Active" then
		Fight.SetMobState(fight, "Chase")
	end
	local gap = Rules.MoveGap(fight.Def, fight.Phase, fight.Random:NextNumber())
	fight.NextMoveAt = math.max(fight.NextMoveAt, now() + gap)
end

-- Stops the running move, if any (its cleanups run: a held player is let go).
function Moves.Cancel(fight: Fight)
	local run = fight.Move
	if run then
		finish(fight, run)
	end
end

-- The Warden starts its attack: Attacking for `busyFor` seconds, standing still.
local function begin(fight: Fight, busyFor: number): boolean
	local model = fight.Model
	if not model or not CombatService.NpcBeginAttack(model, busyFor, false) then
		return false
	end
	Fight.Stop(fight)
	Fight.SetMobState(fight, "Attack")
	return true
end

-- The punish window after a move.
local function recover(fight: Fight, run: MoveRun)
	local model = fight.Model
	if model then
		CombatService.NpcEndAttack(model)
	end
	Fight.SetMobState(fight, "Recover")
	waitUntil(fight, now() + run.Move.Recovery)
end

-- Keeps facing the target until TrackCutoff before contact (so a late dodge works).
local function tracker(fight: Fight, target: Player): (number) -> ()
	return function(remaining: number)
		if remaining > MOVE.TrackCutoff then
			local root = Fight.RootOf(target)
			if root then
				Fight.Face(fight, root.Position)
			end
		end
	end
end

-- Direction to the target (flat unit), or straight ahead.
local function aimAt(fight: Fight, target: Player): Vector3
	local root = fight.Root
	local targetRoot = Fight.RootOf(target)
	if root and targetRoot then
		local offset = flat(targetRoot.Position - root.Position)
		if offset.Magnitude > 1e-3 then
			return offset.Unit
		end
	end
	return Fight.Look(fight)
end

local function telegraphFlags(move: GuardianMove, index: number): number
	return if Guardians.BlowUnparryable(move, index) then FLAG_UNPARRYABLE else 0
end

-- Runs `fn` as a hazard: it outlives the move, but not a phase change or the fight.
local function hazard(fight: Fight, fn: () -> ())
	local thread: thread? = nil
	thread = task.spawn(function()
		local ok, err = protect(fn)
		if not ok then
			log:Error(`hazard failed: {tostring(err)}`)
		end
		if thread then
			fight.Hazards[thread] = nil
		end
	end)
	if thread and coroutine.status(thread) ~= "dead" then
		fight.Hazards[thread] = true
	end
end

function Moves.ClearHazards(fight: Fight)
	for thread in fight.Hazards do
		if thread ~= coroutine.running() and coroutine.status(thread) ~= "dead" then
			task.cancel(thread)
		end
	end
	table.clear(fight.Hazards)
end

-- ADDS -----------------------------------------------------------------------------------------

function Moves.AddsAlive(fight: Fight): number
	local count = 0
	for model in fight.Adds do
		local mob = MobService.GetMob(model)
		if mob and not mob.Dead then
			count += 1
		else
			fight.Adds[model] = nil
		end
	end
	return count
end

-- Bilgecrabs crawl out of the tide pools, up to the party's add count, and go for the nearest
-- member. They only ever fight this party (AllowedTargets is the live member set).
function Moves.SpawnAdds(fight: Fight)
	local def = fight.Def
	local living = Fight.Living(fight)
	if #living == 0 then
		return
	end
	local wanted = Rules.AddCount(def, #living) - Moves.AddsAlive(fight)
	local pools = fight.Arena.AddPools
	local leaveAt = now() + def.Adds.Lifetime
	for index = 1, wanted do
		local position = if #pools > 0 then pools[(index - 1) % #pools + 1] else fight.Arena.Origin.Position
		local mob = MobService.Spawn(def.Adds.MobId, position, false, nil, {
			AllowedTargets = fight.Members,
			OnDied = function(dead)
				fight.Adds[dead.Model] = nil
			end,
		})
		if mob then
			fight.Adds[mob.Model] = leaveAt
			local nearest: Player? = nil
			local best = math.huge
			for _, member in living do
				local distance = Rules.FlatDistance(position, member.Root.Position)
				if distance < best then
					nearest = member.Player
					best = distance
				end
			end
			if nearest then
				MobService.Engage(mob.Model, nearest)
			end
		end
	end
end

-- Adds past their Lifetime sink back into the pools.
function Moves.ExpireAdds(fight: Fight, t: number)
	for model, leaveAt in fight.Adds do
		if t >= leaveAt then
			fight.Adds[model] = nil
			MobService.Despawn(model, true)
		end
	end
end

function Moves.DespawnAdds(fight: Fight)
	for model in fight.Adds do
		MobService.Despawn(model, true)
	end
	table.clear(fight.Adds)
end

-- RUNNERS --------------------------------------------------------------------------------------

-- Sweep and Flurry: a string of swings checked at contact (Reach / Arc). Coral Sweep plays
-- mirrored on every other use, so it opens from alternating sides.
local function blowString(fight: Fight, run: MoveRun)
	local move = run.Move
	local def = fight.Def
	local model = fight.Model
	if not model then
		return
	end
	local blows = move.Blows
	if move.Kind == "Sweep" then
		blows = Rules.SweepBlows(move, fight.SweepMirrored)
		fight.SweepMirrored = not fight.SweepMirrored
	end
	local telegraph = Rules.Telegraph(def, move, fight.Phase)
	local interval = Rules.Interval(def, move, fight.Phase)
	if not begin(fight, telegraph + interval * (#blows - 1) + BUSY_PAD) then
		return
	end
	local track = tracker(fight, run.Target)
	for index, slot in blows do
		local windup = if index == 1 then telegraph else interval
		local contactAt = now() + windup
		Fight.Announce(fight, slot, windup, Rules.BlowFlag(move, index))
		if not waitUntil(fight, contactAt, track) then
			return
		end
		local spec: CombatService.SwingSpec = {
			Reach = move.Reach or 0,
			Arc = move.Arc or 0,
			Aim = Fight.Look(fight),
			Hit = Fight.HitSpec(move, index),
		}
		CombatService.NpcSwingVisual(model, spec, 0)
		CombatService.NpcSwing(model, spec)
	end
	recover(fight, run)
end

-- Cleave: a line slam toward the target; the line is fixed when the wind-up starts.
local function cleave(fight: Fight, run: MoveRun)
	local move = run.Move
	local def = fight.Def
	local root = fight.Root
	if not root then
		return
	end
	local telegraph = Rules.Telegraph(def, move, fight.Phase)
	if not begin(fight, telegraph + BUSY_PAD) then
		return
	end
	local direction = aimAt(fight, run.Target)
	Fight.Face(fight, root.Position + direction)
	local feet = Fight.Feet(fight)
	local length = move.Length or 0
	local width = move.Width or 0
	local contactAt = now() + telegraph
	Fight.Announce(fight, move.Blows[1], telegraph, Rules.BlowFlag(move, 1))
	Fight.Telegraph(fight, "Line", CFrame.lookAt(feet, feet + direction), length, width, telegraph, telegraphFlags(move, 1))
	if not waitUntil(fight, contactAt) then
		return
	end
	local spec = Fight.HitSpec(move, 1)
	for _, member in Fight.Living(fight) do
		if Rules.InLine(feet, direction, length, width, member.Root.Position, PAD) then
			Fight.Strike(fight, member.Player, spec, root.Position)
		end
	end
	recover(fight, run)
end

-- Stomp and Pulse: a circle around the Warden.
local function burst(fight: Fight, run: MoveRun)
	local move = run.Move
	local def = fight.Def
	local root = fight.Root
	if not root then
		return
	end
	local telegraph = Rules.Telegraph(def, move, fight.Phase)
	if not begin(fight, telegraph + BUSY_PAD) then
		return
	end
	local feet = Fight.Feet(fight)
	local radius = move.Radius or 0
	local contactAt = now() + telegraph
	Fight.Announce(fight, move.Blows[1], telegraph, Rules.BlowFlag(move, 1))
	Fight.Telegraph(fight, "Circle", CFrame.new(feet), radius, 0, telegraph, telegraphFlags(move, 1))
	if not waitUntil(fight, contactAt) then
		return
	end
	local spec = Fight.HitSpec(move, 1)
	for _, member in Fight.Living(fight) do
		if Rules.InCircle(feet, radius, member.Root.Position, PAD) then
			Fight.Strike(fight, member.Player, spec, root.Position)
		end
	end
	recover(fight, run)
end

-- GRAB -----------------------------------------------------------------------------------------

local function standHeight(root: BasePart): number
	local character = root.Parent
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return (if humanoid then humanoid.HipHeight else 0) + root.Size.Y / 2
end

-- Puts a held player down at `position` and hands their body back to them.
local function settle(victim: Player, root: BasePart, position: Vector3)
	if root.Parent then
		root.CFrame = CFrame.new(position) * root.CFrame.Rotation
		root.AssemblyLinearVelocity = Vector3.zero
		root.Anchored = false
		-- Anchoring cleared the character's owner: the player drives their body again.
		if victim.Parent and victim.Character == root.Parent then
			pcall(function()
				root:SetNetworkOwner(victim)
			end)
		end
	end
	AntiExploitService.ResetMovement(victim)
	task.defer(AntiExploitService.ResetMovement, victim)
end

-- Let go where they hang: they land on the floor below. The seizing blow stunned them for the
-- whole hold and throw; being freed early ends that stun (a short stagger replaces it) so breaking
-- the grip really frees them.
local function drop(fight: Fight, victim: Player, root: BasePart)
	local ground = Arena.Ground(fight.Arena, root.Position)
	settle(victim, root, ground + Vector3.new(0, standHeight(root), 0))
	local character = victim.Character
	if character and character == root.Parent then
		CombatService.Stun(character, FREED_STAGGER)
	end
end

-- Thrown `distance` studs along `direction`: a server-driven arc lasting `flight` seconds whose
-- height is that of a real throw of that length (gravity), then they land.
local function throw(fight: Fight, victim: Player, root: BasePart, direction: Vector3, distance: number, flight: number)
	local arena = fight.Arena
	local start = root.Position
	local landing = Arena.Ground(arena, Arena.Clamp(arena, start + direction * distance, PAD)) + Vector3.new(0, standHeight(root), 0)
	local apex = Workspace.Gravity * flight * flight / 8
	local rotation = root.CFrame.Rotation
	local began = os.clock()
	AntiExploitService.AllowBurst(victim, distance / math.max(flight, 1e-3), flight + 0.5)
	local connection: RBXScriptConnection? = nil
	connection = RunService.Heartbeat:Connect(function()
		if not root.Parent then
			if connection then
				connection:Disconnect()
			end
			return
		end
		local alpha = math.clamp((os.clock() - began) / math.max(flight, 1e-3), 0, 1)
		if alpha >= 1 then
			if connection then
				connection:Disconnect()
			end
			settle(victim, root, landing)
			return
		end
		root.CFrame = CFrame.new(start:Lerp(landing, alpha) + Vector3.new(0, apex * 4 * alpha * (1 - alpha), 0)) * rotation
	end)
end

-- Holds `victim` in the claw: anchored in front of the Warden, crushed `Crushes` times over
-- `Hold` seconds, then thrown. Allies free them by dealing BreakPosture posture to the Warden
-- meanwhile. Returns false if the move was stopped (its cleanup lets go).
local function hold(fight: Fight, run: MoveRun, victim: Player, victimRoot: BasePart, holdSeconds: number, flight: number): boolean
	local move = run.Move
	local def = fight.Def
	local model = fight.Model
	local wardenRoot = fight.Root
	if not model or not wardenRoot then
		return false
	end
	-- Out in the claw, half its reach in front of the body, at chest height, facing the Warden.
	local offset = CFrame.new(0, 0, -(def.HitRadius + (move.Reach or 0) / 2)) * CFrame.Angles(0, math.pi, 0)
	local breakAt = move.BreakPosture or math.huge
	local look = Fight.Look(fight)
	local connections: { RBXScriptConnection } = {}
	local released = false
	local dealt = 0
	local lastPosture = model:GetAttribute(A.Posture)
	local last = if type(lastPosture) == "number" then lastPosture else 0

	local record: Types.Grab
	local function release(thrown: boolean)
		if released then
			return
		end
		released = true
		for _, connection in connections do
			connection:Disconnect()
		end
		table.clear(connections)
		if fight.Grab == record then
			fight.Grab = nil
		end
		if not victimRoot.Parent then
			return
		end
		if thrown and Fight.RootOf(victim) == victimRoot then
			throw(fight, victim, victimRoot, look, move.Reach or 0, flight)
		else
			drop(fight, victim, victimRoot)
		end
	end
	record = { Victim = victim, Release = release }
	fight.Grab = record
	table.insert(run.Cleanups, function()
		release(false)
	end)

	victimRoot.Anchored = true
	victimRoot.CFrame = wardenRoot.CFrame * offset
	AntiExploitService.ResetMovement(victim)
	task.defer(AntiExploitService.ResetMovement, victim)
	table.insert(connections, RunService.Heartbeat:Connect(function()
		if victimRoot.Parent and wardenRoot.Parent then
			victimRoot.CFrame = wardenRoot.CFrame * offset
		end
	end))
	table.insert(connections, model:GetAttributeChangedSignal(A.Posture):Connect(function()
		local value = model:GetAttribute(A.Posture)
		local posture = if type(value) == "number" then value else 0
		if posture > last then
			dealt += posture - last
		end
		last = posture
		if dealt >= breakAt then
			release(false) -- broken free
		end
	end))
	Net.Fire("Notify", victim, "Guardians.Grabbed", {}, "Warning")

	local start = now()
	local crushes = move.Crushes or 0
	for index = 1, crushes do
		if not waitUntil(fight, start + holdSeconds * index / (crushes + 1)) then
			return false
		end
		if released or not Fight.RootOf(victim) then
			break
		end
		-- Each crush keeps them stunned until they land.
		local stun = math.max(0, start + holdSeconds - now()) + flight
		Fight.Strike(fight, victim, Fight.HitSpec(move, 1, stun), wardenRoot.Position)
	end
	if not released and not waitUntil(fight, start + holdSeconds) then
		return false
	end
	release(true)
	return true
end

-- Claw Grab: unparryable and unblockable; at contact it seizes the nearest member in its cone.
local function grab(fight: Fight, run: MoveRun)
	local move = run.Move
	local def = fight.Def
	local root = fight.Root
	if not root then
		return
	end
	local telegraph = Rules.Telegraph(def, move, fight.Phase)
	local holdSeconds = move.Hold or 0
	local flight = move.HitStun
	if not begin(fight, telegraph + holdSeconds + flight + BUSY_PAD) then
		return
	end
	local contactAt = now() + telegraph
	Fight.Announce(fight, move.Blows[1], telegraph, Rules.BlowFlag(move, 1))
	if not waitUntil(fight, contactAt, tracker(fight, run.Target)) then
		return
	end
	local look = Fight.Look(fight)
	local victim: Player? = nil
	local victimRoot: BasePart? = nil
	local best = math.huge
	for _, member in Fight.Living(fight) do
		if Rules.InCone(root.Position, look, move.Reach or 0, move.Arc or 0, member.Root.Position, PAD) then
			local distance = Rules.FlatDistance(root.Position, member.Root.Position)
			if distance < best then
				victim, victimRoot, best = member.Player, member.Root, distance
			end
		end
	end
	if victim and victimRoot then
		-- The seizing blow stuns for the whole hold and the throw (dodge i-frames still save you).
		local outcome = Fight.Strike(fight, victim, Fight.HitSpec(move, 1, holdSeconds + flight), root.Position)
		if outcome == "Hit" and Fight.RootOf(victim) == victimRoot and fight.Grab == nil then
			if not hold(fight, run, victim, victimRoot, holdSeconds, flight) then
				return
			end
		end
	end
	recover(fight, run)
end

-- Shell Rush: charges down a line toward a far target, hitting everyone it passes once.
local function rush(fight: Fight, run: MoveRun)
	local move = run.Move
	local def = fight.Def
	local mob = fight.Mob
	local root = fight.Root
	if not mob or not root then
		return
	end
	local telegraph = Rules.Telegraph(def, move, fight.Phase)
	local direction = aimAt(fight, run.Target)
	local feet = Fight.Feet(fight)
	-- The charge stops short of the wall.
	local length = Rules.ClipToCircle(feet, direction, move.Length or 0, fight.Arena.Origin.Position, math.max(0, fight.Arena.Radius - def.HitRadius))
	local speed = move.Speed or mob.Def.RunSpeed
	local travel = length / math.max(speed, 1e-3)
	if not begin(fight, telegraph + travel + BUSY_PAD) then
		return
	end
	Fight.Face(fight, root.Position + direction)
	local contactAt = now() + telegraph
	Fight.Announce(fight, move.Blows[1], telegraph, Rules.BlowFlag(move, 1))
	Fight.Telegraph(fight, "Line", CFrame.lookAt(feet, feet + direction), length, move.Width or 0, telegraph, telegraphFlags(move, 1))
	if not waitUntil(fight, contactAt) then
		return
	end
	local humanoid = mob.Humanoid
	local goal = root.Position + direction * length
	humanoid.WalkSpeed = speed * StatusService.SpeedMultiplier(mob.Model)
	humanoid:MoveTo(goal)
	table.insert(run.Cleanups, function()
		if not mob.Dead then
			humanoid:Move(Vector3.zero)
			humanoid.WalkSpeed = mob.Def.WalkSpeed
		end
	end)
	local spec = Fight.HitSpec(move, 1)
	local struck: { [Player]: boolean } = {}
	local halfWidth = (move.Width or 0) / 2 + PAD
	local arrive = MOVE.ArriveDistance * mob.Def.Body.Scale
	local last = root.Position
	-- A charge that is slowed or blocked still ends (twice its planned travel time at most).
	local deadline = now() + travel * 2
	while now() < deadline do
		if not Moves.CanAct(fight) then
			return
		end
		local current = root.Position
		for _, member in Fight.Living(fight) do
			if not struck[member.Player] and Rules.SegmentDistance(last, current, member.Root.Position) <= halfWidth then
				struck[member.Player] = true
				Fight.Strike(fight, member.Player, spec, current)
			end
		end
		last = current
		if Rules.FlatDistance(current, goal) <= arrive then
			break
		end
		task.wait(STEP)
	end
	humanoid:Move(Vector3.zero)
	humanoid.WalkSpeed = mob.Def.WalkSpeed
	Fight.Stop(fight)
	recover(fight, run)
end

-- Call of the Brine: a roar, then Bilgecrabs from the tide pools.
local function summon(fight: Fight, run: MoveRun)
	local move = run.Move
	local telegraph = Rules.Telegraph(fight.Def, move, fight.Phase)
	if not begin(fight, telegraph + BUSY_PAD) then
		return
	end
	local contactAt = now() + telegraph
	Fight.Announce(fight, move.Blows[1], telegraph, Rules.BlowFlag(move, 1))
	if not waitUntil(fight, contactAt) then
		return
	end
	Moves.SpawnAdds(fight)
	recover(fight, run)
end

-- Water-jet Lances: line telegraphs toward the party (more with 4+ players), then jets.
local function lances(fight: Fight, run: MoveRun)
	local move = run.Move
	local def = fight.Def
	local root = fight.Root
	if not root then
		return
	end
	local telegraph = Rules.Telegraph(def, move, fight.Phase)
	if not begin(fight, telegraph + BUSY_PAD) then
		return
	end
	Fight.Face(fight, root.Position + aimAt(fight, run.Target))
	local living = Fight.Living(fight)
	local feet = Fight.Feet(fight)
	local targets: { Vector3 } = {}
	for _, member in living do
		table.insert(targets, member.Root.Position)
	end
	local width = move.Width or 0
	local aims = Rules.LanceAims(feet, targets, Rules.LanceCount(move, #living), width, Fight.Look(fight))
	local flags = telegraphFlags(move, 1)
	local lines: { { Direction: Vector3, Length: number } } = {}
	for _, aim in aims do
		local length = Rules.ClipToCircle(feet, aim, move.Length or 0, fight.Arena.Origin.Position, fight.Arena.Radius)
		if length <= 0 then
			length = move.Length or 0
		end
		table.insert(lines, { Direction = aim, Length = length })
		Fight.Telegraph(fight, "Line", CFrame.lookAt(feet, feet + aim), length, width, telegraph, flags)
	end
	local contactAt = now() + telegraph
	Fight.Announce(fight, move.Blows[1], telegraph, Rules.BlowFlag(move, 1))
	if not waitUntil(fight, contactAt) then
		return
	end
	local spec = Fight.HitSpec(move, 1)
	for _, member in Fight.Living(fight) do
		for _, line in lines do
			if Rules.InLine(feet, line.Direction, line.Length, width, member.Root.Position, PAD) then
				Fight.Strike(fight, member.Player, spec, root.Position)
				break -- one jet per player
			end
		end
	end
	recover(fight, run)
end

-- Whirlpools at `spots`: damage every Tick and Soaked while inside, for Duration seconds.
local function whirlpools(fight: Fight, move: GuardianMove, spots: { Vector3 })
	local radius = move.Radius or 0
	local duration = move.Duration or 0
	local tick = move.Tick or duration
	local flags = telegraphFlags(move, 1)
	for _, spot in spots do
		Fight.Telegraph(fight, "Circle", CFrame.new(spot), radius, 0, duration, flags)
	end
	hazard(fight, function()
		local ends = now() + duration
		local spec = Fight.HitSpec(move, 1)
		while now() < ends and fight.State == "Active" do
			for _, member in Fight.Living(fight) do
				for _, spot in spots do
					if Rules.InCircle(spot, radius, member.Root.Position, PAD) then
						Fight.Strike(fight, member.Player, spec, spot)
						local character = member.Player.Character
						if character then
							StatusService.Apply(character, "Soaked")
						end
						break
					end
				end
			end
			task.wait(math.max(tick, STEP))
		end
	end)
end

-- Undertow: whirlpools open under up to Count players (one each).
local function undertow(fight: Fight, run: MoveRun)
	local move = run.Move
	local telegraph = Rules.Telegraph(fight.Def, move, fight.Phase)
	if not begin(fight, telegraph + BUSY_PAD) then
		return
	end
	local living = Fight.Living(fight)
	-- shuffled, so the pools pick different players each time when there are more than Count
	for index = #living, 2, -1 do
		local swap = fight.Random:NextInteger(1, index)
		living[index], living[swap] = living[swap], living[index]
	end
	local spots: { Vector3 } = {}
	local flags = telegraphFlags(move, 1)
	for index = 1, math.min(Rules.PoolCount(move, #living), #living) do
		local spot = Arena.Ground(fight.Arena, living[index].Root.Position)
		table.insert(spots, spot)
		Fight.Telegraph(fight, "Circle", CFrame.new(spot), move.Radius or 0, 0, telegraph, flags)
	end
	local contactAt = now() + telegraph
	Fight.Announce(fight, move.Blows[1], telegraph, Rules.BlowFlag(move, 1))
	if not waitUntil(fight, contactAt) then
		return
	end
	whirlpools(fight, move, spots)
	recover(fight, run)
end

-- Tide Surge: the sword raised to the sky turns the tide (its wind-up is the tide's tell).
local function surge(fight: Fight, run: MoveRun)
	local move = run.Move
	local def = fight.Def
	local telegraph = Rules.Telegraph(def, move, fight.Phase)
	if not begin(fight, telegraph + BUSY_PAD) then
		return
	end
	if Rules.ForceTide(def, fight.Tide, now(), telegraph) then
		Fight.TideWarning(fight)
	end
	local contactAt = now() + telegraph
	Fight.Announce(fight, move.Blows[1], telegraph, Rules.BlowFlag(move, 1))
	if not waitUntil(fight, contactAt) then
		return
	end
	recover(fight, run)
end

-- The travelling front of a tidal wave from `center`: every member is hit once as it passes them
-- (dodge i-frames are the only way through).
local function waveFront(fight: Fight, move: GuardianMove, center: Vector3)
	local radius = move.Radius or fight.Arena.Radius
	local speed = move.Speed or 1
	-- A Ring with inner radius 0 is the travelling front (TelegraphController).
	Fight.Telegraph(fight, "Ring", CFrame.new(center), radius, 0, Rules.WaveDelay(radius, speed), telegraphFlags(move, 1))
	hazard(fight, function()
		local began = now()
		local struck: { [Player]: boolean } = {}
		local spec = Fight.HitSpec(move, 1)
		while fight.State == "Active" do
			local front = (now() - began) * speed
			for _, member in Fight.Living(fight) do
				if not struck[member.Player] and Rules.FlatDistance(center, member.Root.Position) - PAD <= front then
					struck[member.Player] = true
					Fight.Strike(fight, member.Player, spec, center)
				end
			end
			if front >= radius then
				break
			end
			task.wait(STEP)
		end
	end)
end

-- Tidal Wave: water rises at its feet and a ring marks the walls, then the wave sweeps outward.
local function wave(fight: Fight, run: MoveRun)
	local move = run.Move
	local telegraph = Rules.Telegraph(fight.Def, move, fight.Phase)
	if not begin(fight, telegraph + BUSY_PAD) then
		return
	end
	local feet = Fight.Feet(fight)
	local radius = move.Radius or fight.Arena.Radius
	local speed = move.Speed or 1
	-- The tell: a ring at the walls as wide as the wave travels in the shortest readable wind-up.
	local inner = math.max(0.5, radius - speed * Rules.MinTelegraph)
	Fight.Telegraph(fight, "Ring", CFrame.new(feet), radius, inner, telegraph, telegraphFlags(move, 1))
	local contactAt = now() + telegraph
	Fight.Announce(fight, move.Blows[1], telegraph, Rules.BlowFlag(move, 1))
	if not waitUntil(fight, contactAt) then
		return
	end
	waveFront(fight, move, feet)
	recover(fight, run)
end

local RUNNERS: { [string]: (Fight, MoveRun) -> () } = {
	Sweep = blowString,
	Flurry = blowString,
	Cleave = cleave,
	Grab = grab,
	Rush = rush,
	Stomp = burst,
	Pulse = burst,
	Summon = summon,
	Lances = lances,
	Undertow = undertow,
	Surge = surge,
	Wave = wave,
}

-- Starts move `id` against `target` (the fight loop picked it with Rules.Choose).
function Moves.Start(fight: Fight, id: string, move: GuardianMove, target: Player)
	local runner = RUNNERS[move.Kind]
	if not runner then
		log:Warn(`no runner for move kind {move.Kind} ({id})`)
		return
	end
	local run: MoveRun = { Id = id, Move = move, Target = target, Thread = nil, Cleanups = {} }
	fight.Move = run
	fight.Cooldowns[id] = now() + move.Cooldown
	if fight.LastMove == id then
		fight.Repeats += 1
	else
		fight.LastMove = id
		fight.Repeats = 1
	end
	local thread = task.spawn(function()
		local ok, err = protect(function()
			runner(fight, run)
		end)
		if not ok then
			log:Error(`{id} failed: {tostring(err)}`)
		end
		finish(fight, run)
	end)
	if fight.Move == run then
		run.Thread = thread
	end
end

return Moves
