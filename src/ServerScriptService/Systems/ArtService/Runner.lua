--!strict
--[[
	Runner
	Plays one Weapon Art, Confluence or Position ability timeline
	(Shared/Data/Moves) on the server. Run() is called inside CombatService.BeginMove, so it yields
	between steps and a stagger (for moves without hyper armour) cancels
	whatever hasn't happened yet. Fields, delayed bursts and projectiles in
	flight are scheduled separately and finish even if the caster is hit.

	Every blow goes through CombatService.NpcHit, so dodges, blocks, posture,
	finishers and damage numbers work exactly like sword hits. Each step is
	broadcast as MoveStep with the positions clients need to draw it.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Net = require(Shared.Net)
local Moves = require(Shared.Data.Moves)
local Mobs = require(Shared.Data.Mobs)
local Spells = require(Shared.Data.Spells)
local Attributes = require(Shared.Attributes)

local Systems = script.Parent.Parent
local TargetService = require(Systems.TargetService)
local CombatService = require(Systems.CombatService)
local StatusService = require(Systems.StatusService)
local VitalsService = require(Systems.VitalsService)
local CharacterService = require(Systems.CharacterService)
local AntiExploitService = require(Systems.AntiExploitService)
local GearService = require(Systems.GearService)
local MobService = require(Systems.MobService)

local C = Config.Combat
local A = Attributes.Names

local Runner = {}

export type Context = {
	Player: Player,
	Caster: Model,
	Root: BasePart,
	Key: string, -- what clients look the move up by: weapon class (Art), Confluence id or ability id
	Move: Moves.Move,
	Kind: "Art" | "Confluence" | "Ability",
	Aim: Vector3, -- flat unit vector, fixed when the move starts
	Anchor: Vector3,
	Power: number, -- damage of a 1.0 step
	PostureBase: number,
	CritChance: number,
	Element: string?, -- Attunement for statuses and colours (Confluence, or Infusion for Arts)
	Hit: { Model }, -- every enemy the move has hit, in order
	HitSet: { [Model]: boolean },
	Dealt: number, -- damage dealt so far (Leech)
}

-- Marks left by Mark steps: the caster's next hit on the target adds Bonus.
type Mark = { Player: Player, Until: number, Bonus: number, Element: string? }
local marks: { [Model]: Mark } = {}

local LANDED: { [string]: boolean } = {
	Hit = true,
	Blocked = true,
	GuardBreak = true,
	Riposte = true,
	Finisher = true,
	Broken = true,
	Reaction = true,
}

local wallParams = RaycastParams.new()
wallParams.FilterType = Enum.RaycastFilterType.Exclude
wallParams.IgnoreWater = true

local function now(): number
	return Workspace:GetServerTimeNow()
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function rootOf(model: Model): BasePart?
	local root = model:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

-- Walls only: characters and mobs never block line checks.
function Runner.RefreshWallFilter()
	local ignore: { Instance } = {}
	for model in TargetService.GetAll() do
		table.insert(ignore, model)
	end
	local fx = Workspace:FindFirstChild("SpellFX")
	if fx then
		table.insert(ignore, fx)
	end
	wallParams.FilterDescendantsInstances = ignore
end

local function audience(position: Vector3): { Player }
	local list = {}
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and rootOf(character)
		if root and (root.Position - position).Magnitude <= C.FeedbackRadius then
			table.insert(list, player)
		end
	end
	return list
end

local function visual(ctx: Context, index: number, data: { [string]: any })
	Net.FireList("MoveStep", audience(ctx.Root.Position), ctx.Caster, ctx.Key, index, data)
end

-- Living enemies within `radius` of `position`, nearest first (measured to
-- their body, so big bodies count from their surface).
local function enemiesNear(position: Vector3, radius: number): { Model }
	local list: { { Model: Model, Distance: number } } = {}
	for model, target in TargetService.GetAll() do
		if target.Team ~= "Players" and TargetService.IsAlive(target) then
			local distance = TargetService.DistanceTo(target, position)
			if distance <= radius then
				table.insert(list, { Model = model, Distance = distance })
			end
		end
	end
	table.sort(list, function(a, b): boolean
		return a.Distance < b.Distance
	end)
	local models = {}
	for _, entry in list do
		table.insert(models, entry.Model)
	end
	return models
end

local function wherePosition(ctx: Context, step: Moves.Step): Vector3
	if step.Where == "Anchor" then
		return ctx.Anchor
	end
	return ctx.Root.Position
end

-- Distance from a target to the move's line, and how far along it the target is.
local function alongLine(origin: Vector3, direction: Vector3, length: number, point: Vector3): (number, number)
	local along = math.clamp((point - origin):Dot(direction), 0, length)
	return (point - (origin + direction * along)).Magnitude, along
end

local function lineLength(origin: Vector3, direction: Vector3, length: number): number
	local hit = Workspace:Raycast(origin + Vector3.new(0, 1, 0), direction * length, wallParams)
	return if hit then hit.Distance else length
end

local function groundBelow(position: Vector3): Vector3
	local hit = Workspace:Raycast(position + Vector3.new(0, 6, 0), Vector3.new(0, -40, 0), wallParams)
	return if hit then hit.Position else position
end

local function rotate(direction: Vector3, degrees: number): Vector3
	return (CFrame.Angles(0, math.rad(degrees), 0) * CFrame.new(direction)).Position
end

-- DISPLACEMENT -------------------------------------------------------------------

-- Light enemies only (not bosses or big brutes) can be thrown around.
local function movable(model: Model): BasePart?
	local root = rootOf(model)
	if not root or root.Anchored or Players:GetPlayerFromCharacter(model) then
		return nil
	end
	local target = TargetService.Get(model)
	if not target or target.Kind ~= "Mob" then
		return nil
	end
	-- Floor Guardians are scripted and immovable: pulls and pushes don't move them.
	if model:GetAttribute(A.GuardianId) ~= nil then
		return nil
	end
	return root
end

local function isLight(model: Model): boolean
	local mobId = model:GetAttribute(A.MobId)
	local def = if type(mobId) == "string" then Mobs.Get(mobId) else nil
	return def ~= nil and def.Body.Scale <= 1.15 and model:GetAttribute(A.Elite) ~= true
end

-- Slides an enemy to `goal` over `duration` (it can't act meanwhile).
local function displace(model: Model, goal: Vector3, duration: number)
	local root = movable(model)
	if not root then
		return
	end
	CombatService.Stun(model, duration + 0.2)
	local start = root.Position
	local ground = groundBelow(start)
	local height = start.Y - ground.Y
	local target = groundBelow(Vector3.new(goal.X, start.Y, goal.Z)) + Vector3.new(0, height, 0)
	-- Don't drag anything through a wall.
	local path = target - start
	local wall = Workspace:Raycast(start, path, wallParams)
	if wall then
		target = start + path.Unit * math.max(0, wall.Distance - 2)
	end
	local elapsed = 0
	local connection: RBXScriptConnection? = nil
	connection = RunService.Heartbeat:Connect(function(dt: number)
		elapsed += dt
		local alpha = math.clamp(elapsed / math.max(duration, 0.05), 0, 1)
		local eased = 1 - (1 - alpha) * (1 - alpha)
		if not model.Parent or not root.Parent then
			if connection then
				connection:Disconnect()
			end
			return
		end
		local position = start:Lerp(target, eased)
		model:PivotTo(CFrame.new(position) * root.CFrame.Rotation)
		root.AssemblyLinearVelocity = Vector3.zero
		if alpha >= 1 and connection then
			connection:Disconnect()
		end
	end)
end

local function launch(model: Model, height: number)
	local root = movable(model)
	if not root or not isLight(model) then
		return
	end
	local speed = math.sqrt(2 * Workspace.Gravity * height)
	root.AssemblyLinearVelocity = Vector3.new(0, speed, 0)
	CombatService.Stun(model, speed / Workspace.Gravity * 2 + 0.3)
end

-- HITS ---------------------------------------------------------------------------

local function applyStatus(ctx: Context, step: Moves.Step, model: Model)
	if step.Apply then
		StatusService.Apply(model, step.Apply)
	end
	local element = if ctx.Element then Spells.Attunement(ctx.Element) else nil
	if not element then
		return
	end
	-- Confluences carry their element (Stacks times, default once). Arts
	-- carry it only through Infusion, which CurrentService applies.
	-- Abilities carry it only on steps that set Stacks.
	local stacks = if ctx.Kind == "Confluence"
		then step.Stacks or (if step.Apply then 0 else 1)
		elseif ctx.Kind == "Ability" then step.Stacks or 0
		else 0
	for _ = 1, stacks do
		StatusService.Apply(model, element.Status)
	end
end

-- One blow of `step` on `model` from `source`. Returns true if it landed.
local function strike(ctx: Context, step: Moves.Step, model: Model, source: Vector3, scale: number?): boolean
	if not ctx.Caster.Parent then
		return false
	end
	local damage = ctx.Power * (step.Damage or 0) * (scale or 1)
	if step.Execute then
		-- Severance: bonus on foes close to death.
		local target = TargetService.Get(model)
		local humanoid = target and target.Humanoid
		if humanoid and humanoid.MaxHealth > 0 and humanoid.Health / humanoid.MaxHealth <= Config.Progression.ExecuteThreshold then
			damage *= 1 + step.Execute
		end
	end
	local critChance = if step.Crit then 1 else ctx.CritChance + (step.CritBonus or 0)
	local outcome = CombatService.NpcHit(ctx.Caster, model, {
		Damage = damage,
		Posture = ctx.PostureBase * (step.Posture or 1),
		Kind = ctx.Kind,
		Parryable = false,
		Blockable = true,
		HitStun = if ctx.Kind == "Confluence" then C.HitStun.Heavy else C.HitStun.Light,
		CritChance = critChance,
		CritMultiplier = C.Damage.CritMultiplier,
		Element = ctx.Element,
	}, source)
	if not outcome or not LANDED[outcome] then
		return false
	end
	ctx.Dealt += damage
	if not ctx.HitSet[model] then
		ctx.HitSet[model] = true
		table.insert(ctx.Hit, model)
	end
	applyStatus(ctx, step, model)
	if step.Launch then
		launch(model, step.Launch)
	end
	return true
end

local function strikeAll(ctx: Context, step: Moves.Step, models: { Model }, source: Vector3): { Vector3 }
	local positions = {}
	for _, model in models do
		local root = rootOf(model)
		if root and strike(ctx, step, model, source) then
			table.insert(positions, root.Position)
		end
	end
	return positions
end

local function repeated(step: Moves.Step, each: (number) -> ())
	local hits = math.max(1, step.Hits or 1)
	for index = 1, hits do
		if index > 1 then
			task.wait(step.Interval or 0.15)
		end
		each(index)
	end
end

-- STEPS --------------------------------------------------------------------------

type Handler = (Context, Moves.Step, number) -> ()
local STEPS: { [string]: Handler } = {}

STEPS.Arc = function(ctx, step, index)
	repeated(step, function()
		local origin = wherePosition(ctx, step)
		local reach = (step.Reach or 7) + C.HitValidation.TargetRadius
		local halfArc = math.rad((step.Arc or 90) / 2)
		local hits = {}
		for _, model in enemiesNear(origin, reach) do
			local root = rootOf(model)
			local target = TargetService.Get(model)
			if root and target then
				-- A big body's width widens the arc it fills.
				local offset = flat(root.Position - origin)
				local distance = offset.Magnitude
				local inside = distance < C.HitValidation.TargetRadius + target.HitRadius
					or math.acos(math.clamp(ctx.Aim:Dot(offset.Unit), -1, 1)) <= halfArc + math.asin(math.min(1, target.HitRadius / distance))
				if inside then
					table.insert(hits, model)
					if step.Single then
						break
					end
				end
			end
		end
		local positions = strikeAll(ctx, step, hits, origin)
		if step.SetAnchor and positions[1] then
			ctx.Anchor = positions[1]
		end
		visual(ctx, index, { Origin = origin, Aim = ctx.Aim, Reach = step.Reach, Arc = step.Arc, Hits = positions })
	end)
end

STEPS.Circle = function(ctx, step, index)
	repeated(step, function()
		local center = wherePosition(ctx, step)
		local radius = (step.Radius or 8) + C.HitValidation.TargetRadius
		local positions = strikeAll(ctx, step, enemiesNear(center, radius), center)
		visual(ctx, index, { Center = groundBelow(center), Radius = step.Radius, Hits = positions })
	end)
end

STEPS.Line = function(ctx, step, index)
	local origin = wherePosition(ctx, step)
	local length = lineLength(origin, ctx.Aim, step.Length or 20)
	local width = (step.Width or 3) / 2 + C.HitValidation.TargetRadius
	repeated(step, function()
		local hits = {}
		for _, model in enemiesNear(origin, length + width) do
			local root = rootOf(model)
			local target = TargetService.Get(model)
			if root and target then
				local distance = alongLine(origin, ctx.Aim, length, flat(root.Position - origin) + origin)
				if distance - target.HitRadius <= width then
					table.insert(hits, model)
				end
			end
		end
		local positions = strikeAll(ctx, step, hits, origin)
		visual(ctx, index, { From = groundBelow(origin), To = groundBelow(origin + ctx.Aim * length), Width = step.Width, Hits = positions })
	end)
end

STEPS.Projectile = function(ctx, step, index)
	local origin = ctx.Root.Position + Vector3.new(0, 0.5, 0)
	local speed = step.Speed or 70
	local radius = (step.Radius or 1.5) + C.HitValidation.TargetRadius
	local paths = {}
	local angles: { number } = step.Angles or { 0 }
	for angleIndex, degrees in angles do
		local direction = rotate(ctx.Aim, degrees)
		local length = lineLength(origin, direction, step.Range or 36)
		-- Every enemy close to the path, in the order the projectile reaches them.
		local along: { { Model: Model, Distance: number } } = {}
		for _, model in enemiesNear(origin, length + radius) do
			local root = rootOf(model)
			local target = TargetService.Get(model)
			if root and target then
				local point = TargetService.AxisPointToSegment(target, origin, origin + direction * length, root.Position)
				local offset, distance = alongLine(origin, direction, length, point)
				if offset - target.HitRadius <= radius then
					table.insert(along, { Model = model, Distance = distance })
				end
			end
		end
		table.sort(along, function(a, b): boolean
			return a.Distance < b.Distance
		end)
		if not step.Pierce and along[1] then
			length = along[1].Distance
			along = { along[1] }
		end
		local endPoint = origin + direction * length
		if step.SetAnchor and angleIndex == math.ceil(#angles / 2) then
			ctx.Anchor = groundBelow(endPoint)
		end
		table.insert(paths, { From = origin, To = endPoint })
		for _, entry in along do
			task.delay(entry.Distance / speed, function()
				if TargetService.Get(entry.Model) then
					strike(ctx, step, entry.Model, origin)
				end
			end)
		end
	end
	visual(ctx, index, { Paths = paths, Speed = speed, Radius = step.Radius })
end

-- Moves the caster along the aim (the client animates the motion; the
-- server checks the path and tells movement checks the burst is legal).
local function travel(ctx: Context, step: Moves.Step): (Vector3, Vector3)
	local from = ctx.Root.Position
	local distance = step.Distance or 10
	local wall = Workspace:Raycast(from, ctx.Aim * distance, wallParams)
	if wall then
		distance = math.max(0, wall.Distance - Config.Current.Casting.StepWallMargin)
	end
	local to = from + ctx.Aim * distance
	local duration = math.max(step.Duration or 0.4, 0.05)
	AntiExploitService.AllowBurst(ctx.Player, distance / duration + 4, duration + 0.4)
	return from, to
end

STEPS.Dash = function(ctx, step, index)
	local from, to = travel(ctx, step)
	ctx.Anchor = groundBelow(to)
	visual(ctx, index, { From = from, To = to, Duration = step.Duration })
	local width = (step.Width or 3) / 2 + C.HitValidation.TargetRadius
	local direction = ctx.Aim
	local length = (to - from).Magnitude
	local hits = math.max(1, step.Hits or 1)
	local gap = (step.Duration or 0.4) / hits
	for hitIndex = 1, hits do
		task.wait(if hitIndex == 1 then gap * 0.6 else (step.Interval or gap))
		local struck = {}
		for _, model in enemiesNear(from, length + width) do
			local root = rootOf(model)
			local target = TargetService.Get(model)
			local point = root and target and TargetService.AxisPointToSegment(target, from, from + direction * length, root.Position)
			if target and point and alongLine(from, direction, length, point) - target.HitRadius <= width then
				table.insert(struck, model)
			end
		end
		strikeAll(ctx, step, struck, from)
	end
end

STEPS.Leap = function(ctx, step, index)
	local from, to = travel(ctx, step)
	ctx.Anchor = groundBelow(to)
	visual(ctx, index, { From = from, To = ctx.Anchor, Duration = step.Duration, Height = step.Height })
end

STEPS.Blink = function(ctx, step, index)
	local targets = enemiesNear(ctx.Root.Position, step.Range or 20)
	local hops = math.min(#targets, step.MaxTargets or 4)
	for hop = 1, hops do
		if hop > 1 then
			task.wait(step.Interval or 0.2)
		end
		local model = targets[hop]
		local root = rootOf(model)
		local target = TargetService.Get(model)
		if root and target and TargetService.IsAlive(target) then
			local from = ctx.Root.Position
			local away = flat(from - root.Position)
			away = if away.Magnitude > 0.1 then away.Unit else -ctx.Aim
			local landing = groundBelow(root.Position + away * 2.5)
			local position = landing + Vector3.new(0, ctx.Root.Position.Y - groundBelow(from).Y, 0)
			CharacterService.Teleport(ctx.Player, CFrame.lookAt(position, Vector3.new(root.Position.X, position.Y, root.Position.Z)))
			strike(ctx, step, model, position)
			ctx.Anchor = landing
			visual(ctx, index, { From = from, To = position, Target = root.Position, Hop = hop })
		end
	end
end

STEPS.Strikes = function(ctx, step, index)
	local center = wherePosition(ctx, step)
	local candidates = enemiesNear(center, step.Radius or 15)
	local strikeRadius = (step.StrikeRadius or 4) + C.HitValidation.TargetRadius
	for count = 1, step.Count or 3 do
		if count > 1 then
			task.wait(step.Interval or 0.2)
		end
		local model = candidates[(count - 1) % math.max(1, #candidates) + 1]
		local root = model and rootOf(model)
		local point: Vector3
		if root then
			point = root.Position
		else
			local angle = math.random() * math.pi * 2
			point = center + Vector3.new(math.cos(angle), 0, math.sin(angle)) * math.random() * (step.Radius or 15)
		end
		local positions = strikeAll(ctx, step, enemiesNear(point, strikeRadius), point)
		visual(ctx, index, { Point = groundBelow(point), Radius = step.StrikeRadius, Hits = positions })
	end
end

STEPS.Chain = function(ctx, step, index)
	local sources = table.clone(ctx.Hit)
	local chained: { [Model]: boolean } = {}
	for _, model in sources do
		chained[model] = true
	end
	local links = {}
	for _, source in sources do
		local sourceRoot = rootOf(source)
		if sourceRoot then
			local jumps = 0
			for _, other in enemiesNear(sourceRoot.Position, step.Range or 14) do
				if jumps >= (step.Count or 2) then
					break
				end
				if not chained[other] then
					local otherRoot = rootOf(other)
					if otherRoot then
						chained[other] = true
						jumps += 1
						strike(ctx, step, other, sourceRoot.Position)
						table.insert(links, { From = sourceRoot.Position, To = otherRoot.Position })
					end
				end
			end
		end
	end
	visual(ctx, index, { Links = links })
end

STEPS.Burst = function(ctx, step, index)
	local centers = {}
	for _, model in ctx.Hit do
		local root = rootOf(model)
		if root then
			table.insert(centers, root.Position)
		end
	end
	if #centers == 0 then
		table.insert(centers, wherePosition(ctx, step))
	end
	local delay = step.Delay or 0
	visual(ctx, index, { Centers = centers, Radius = step.Radius, Delay = delay })
	task.delay(delay, function()
		local struck: { [Model]: boolean } = {}
		for _, center in centers do
			for _, model in enemiesNear(center, (step.Radius or 5) + C.HitValidation.TargetRadius) do
				if not struck[model] then
					struck[model] = true
					strike(ctx, step, model, center)
				end
			end
		end
	end)
end

STEPS.Field = function(ctx, step, index)
	local center = groundBelow(wherePosition(ctx, step))
	local duration = step.Duration or 4
	local interval = step.Interval or 1
	local radius = step.Radius or 8
	visual(ctx, index, { Center = center, Radius = radius, Duration = duration })
	task.spawn(function()
		local finish = now() + duration
		while now() < finish and ctx.Player.Parent do
			for _, model in enemiesNear(center, radius + C.HitValidation.TargetRadius) do
				strike(ctx, step, model, center)
			end
			if step.HealFraction then
				local power = 1 + GearService.Bonus(ctx.Player, "HealPower")
				for _, other in Players:GetPlayers() do
					local character = other.Character
					local root = character and rootOf(character)
					if root and (root.Position - center).Magnitude <= radius then
						VitalsService.Heal(other, VitalsService.GetMaxHealth(other) * step.HealFraction * power)
					end
				end
			end
			task.wait(interval)
		end
	end)
end

STEPS.Pull = function(ctx, step, index)
	local center = wherePosition(ctx, step)
	local targets: { Model } = if step.OnlyHit then table.clone(ctx.Hit) else enemiesNear(center, step.Radius or 12)
	local duration = step.Duration or 0.4
	local moved = {}
	for _, model in targets do
		local root = rootOf(model)
		if root then
			local offset = flat(center - root.Position)
			local distance = offset.Magnitude
			if distance > 3 then
				-- Pulled toward the centre, stopping a little short of it.
				local goal = root.Position + offset.Unit * math.min(step.Strength or 10, distance - 2.5)
				displace(model, goal, duration)
				table.insert(moved, root.Position)
			end
		end
	end
	visual(ctx, index, { Center = groundBelow(center), Radius = step.Radius, Duration = duration, Targets = moved })
end

STEPS.Push = function(ctx, step, index)
	local center = wherePosition(ctx, step)
	local targets: { Model } = if step.OnlyHit then table.clone(ctx.Hit) else enemiesNear(center, step.Radius or 12)
	local duration = step.Duration or 0.35
	for _, model in targets do
		local root = rootOf(model)
		if root then
			local direction: Vector3
			if step.Direction == "Aim" then
				direction = ctx.Aim
			else
				local away = flat(root.Position - center)
				direction = if away.Magnitude > 0.1 then away.Unit else ctx.Aim
			end
			displace(model, root.Position + direction * (step.Strength or 10), duration)
		end
	end
	visual(ctx, index, { Center = groundBelow(center), Radius = step.Radius, Aim = ctx.Aim })
end

STEPS.Heal = function(ctx, step, index)
	local healed = {}
	local fraction = (step.Fraction or 0.1) * (1 + GearService.Bonus(ctx.Player, "HealPower"))
	for _, other in Players:GetPlayers() do
		local character = other.Character
		local root = character and rootOf(character)
		local inRange = other == ctx.Player
			or (step.Allies ~= nil and root ~= nil and (root.Position - ctx.Root.Position).Magnitude <= step.Allies)
		if character and root and inRange then
			VitalsService.Heal(other, VitalsService.GetMaxHealth(other) * fraction)
			if step.Renewing then
				StatusService.Apply(character, "Renewing")
			end
			table.insert(healed, root.Position)
		end
	end
	visual(ctx, index, { Healed = healed })
end

STEPS.Leech = function(ctx, step, index)
	local amount = ctx.Dealt * (step.Fraction or 0.3)
	VitalsService.Heal(ctx.Player, amount)
	visual(ctx, index, { Amount = amount })
end

STEPS.Mark = function(ctx, step, index)
	local positions = {}
	for _, model in ctx.Hit do
		local root = rootOf(model)
		if root then
			marks[model] = {
				Player = ctx.Player,
				Until = now() + (step.Duration or 4),
				Bonus = ctx.Power * (step.Bonus or 1) * (1 + GearService.Bonus(ctx.Player, "MarkPower")),
				Element = ctx.Element,
			}
			table.insert(positions, root.Position)
		end
	end
	visual(ctx, index, { Marked = positions, Duration = step.Duration })
end

-- Players a support step reaches: the caster, plus everyone within `allies` studs.
local function alliesOf(ctx: Context, allies: number?): { Player }
	local list = { ctx.Player }
	if allies then
		for _, other in Players:GetPlayers() do
			local character = other.Character
			local root = character and rootOf(character)
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			if other ~= ctx.Player and root and humanoid and humanoid.Health > 0 and (root.Position - ctx.Root.Position).Magnitude <= allies then
				table.insert(list, other)
			end
		end
	end
	return list
end

local function positionsOf(players: { Player }): { Vector3 }
	local positions = {}
	for _, other in players do
		local character = other.Character
		local root = character and rootOf(character)
		if root then
			table.insert(positions, root.Position)
		end
	end
	return positions
end

STEPS.Taunt = function(ctx, step, index)
	local center = wherePosition(ctx, step)
	local taunted = MobService.Taunt(ctx.Player, center, step.Radius or 20, step.Duration or 6)
	local positions = {}
	for _, model in taunted do
		local root = rootOf(model)
		if root then
			table.insert(positions, root.Position)
		end
	end
	visual(ctx, index, { Center = groundBelow(center), Radius = step.Radius, Targets = positions })
end

-- Timed bonuses (same ids as gear) on the caster and nearby allies. Buffs
-- are keyed by the move, so casting again refreshes rather than stacks.
STEPS.Buff = function(ctx, step, index)
	local bonuses = step.Bonuses
	if not bonuses then
		return
	end
	local players = alliesOf(ctx, step.Allies)
	for _, other in players do
		GearService.AddBuff(other, ctx.Key, bonuses, step.Duration or 8)
	end
	visual(ctx, index, { Players = positionsOf(players), Duration = step.Duration })
end

STEPS.Shield = function(ctx, step, index)
	local players = alliesOf(ctx, step.Allies)
	for _, other in players do
		VitalsService.SetShield(other, VitalsService.GetMaxHealth(other) * (step.Fraction or 0.2), step.Duration or 6)
	end
	visual(ctx, index, { Players = positionsOf(players), Duration = step.Duration })
end

STEPS.Refill = function(ctx, step, index)
	VitalsService.AddCurrent(ctx.Player, VitalsService.GetMaxCurrent(ctx.Player) * (step.Fraction or 0.25))
	visual(ctx, index, { Center = ctx.Root.Position })
end

-- Runs every step of the move in order (yields; cancellable by a stagger).
function Runner.Run(ctx: Context)
	local started = os.clock()
	for index, step in ctx.Move.Steps do
		local wait = step.At - (os.clock() - started)
		if wait > 0 then
			task.wait(wait)
		end
		if not ctx.Caster.Parent then
			return
		end
		if step.IFrames and step.IFrames > 0 then
			CombatService.GrantIFrames(ctx.Caster, step.IFrames)
		end
		local handler = STEPS[step.Do]
		if handler then
			handler(ctx, step, index)
		end
	end
end

-- If `attacker` (a player) marked `defender`, the mark shatters for its bonus.
function Runner.ShatterMark(player: Player, attacker: Model, defender: Model)
	local mark = marks[defender]
	if not mark or mark.Player ~= player then
		return
	end
	marks[defender] = nil
	if now() > mark.Until then
		return
	end
	local root = rootOf(defender)
	CombatService.NpcHit(attacker, defender, {
		Damage = mark.Bonus,
		Posture = 0,
		Kind = "Confluence",
		Parryable = false,
		Blockable = false,
		HitStun = C.HitStun.Light,
		CritChance = 0,
		CritMultiplier = 1,
		Element = mark.Element,
	}, if root then root.Position else attacker:GetPivot().Position)
	if root then
		Net.FireList("MoveStep", audience(root.Position), attacker, "Shatter", 0, { Center = root.Position })
	end
end

function Runner.Forget(model: Model)
	marks[model] = nil
end

return Runner
