--!strict
--[[
	ArtVFXController
	Draws Weapon Arts, Confluences and Position abilities for everyone nearby. Nothing here
	affects gameplay: the server sends MoveStart (a move began) and MoveStep
	(one step happened, with the positions to draw) and this turns them into
	effects in the step's colour:

	  Confluence  the primary Attunement's colour; the caster sees the
	              Confluence's name as a banner with a screen flash, others
	              see it above the caster's head.
	  Weapon Art  the Infusion's colour, or bright steel.

	Each step is drawn by its kind (arc, ring, line, projectile, dash, leap,
	blink, lightning, chain, burst, field, pull, push, heal, mark) and
	flavoured by its Visual key (ice spikes, lightning, gravity, water,
	bloom...). Every effect is built from pooled-in-spirit, short-lived
	anchored parts in Workspace.SpellFX and fades out on its own; Effects
	Quality scales how many pieces each effect uses.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Strings = require(Shared.Strings)
local Net = require(Shared.Net)
local Spells = require(Shared.Data.Spells)
local Arts = require(Shared.Data.Arts)
local Confluences = require(Shared.Data.Confluences)
local Moves = require(Shared.Data.Moves)
local Abilities = require(Shared.Data.Abilities)
local Positions = require(Shared.Data.Positions)

local UI = script.Parent.Parent.UI
local UITheme = require(UI.UITheme)
local Create = require(UI.Create)
local Layers = require(UI.Layers)

local DataController = require(script.Parent.DataController)
local CameraController = require(script.Parent.CameraController)

local player = Players.LocalPlayer

local ArtVFXController = {}

local STEEL = Color3.fromHex("#E6ECF5")
local WHITE = Color3.new(1, 1, 1)

-- Which colour each running move uses, by caster.
local moveColors: { [Model]: Color3 } = {}

local folder: Folder? = nil

local function fx(): Folder
	local existing = folder
	if existing and existing.Parent then
		return existing
	end
	local found = Workspace:FindFirstChild("SpellFX")
	if found and found:IsA("Folder") then
		folder = found
		return found
	end
	local created = Instance.new("Folder")
	created.Name = "SpellFX"
	created.Parent = Workspace
	folder = created
	return created
end

-- How many pieces effects use (Settings > Effects Quality).
local function quality(): number
	local setting = DataController.GetSetting("EffectsQuality")
	return if setting == "Low" then 0.5 elseif setting == "Medium" then 0.75 else 1
end

local function count(base: number): number
	return math.max(2, math.floor(base * quality() + 0.5))
end

local function part(shape: Enum.PartType, size: Vector3, cframe: CFrame, color: Color3, transparency: number, material: Enum.Material?): Part
	local p = Instance.new("Part")
	p.Shape = shape
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = material or Enum.Material.Neon
	p.Color = color
	p.Size = size
	p.CFrame = cframe
	p.Transparency = transparency
	p.Parent = fx()
	return p
end

local function fade(p: BasePart, time: number, goal: { [string]: any }?, style: Enum.EasingStyle?)
	local properties: { [string]: any } = goal or {}
	properties.Transparency = 1
	local tween = TweenService:Create(p, TweenInfo.new(time, style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out), properties)
	tween:Play()
	tween.Completed:Once(function()
		p:Destroy()
	end)
end

local function light(p: BasePart, color: Color3, range: number)
	if quality() < 0.75 then
		return
	end
	local l = Instance.new("PointLight")
	l.Color = color
	l.Range = range
	l.Brightness = 2
	l.Shadows = false
	l.Parent = p
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

-- PRIMITIVES ---------------------------------------------------------------------

local function sphere(center: Vector3, radius: number, color: Color3, time: number, startTransparency: number?)
	local ball = part(Enum.PartType.Ball, Vector3.one * 0.5, CFrame.new(center), color, startTransparency or 0.25)
	light(ball, color, radius * 2)
	fade(ball, time, { Size = Vector3.one * radius * 2 })
end

local function ring(center: Vector3, radius: number, color: Color3, time: number, thickness: number?)
	local disc = part(
		Enum.PartType.Cylinder,
		Vector3.new(thickness or 0.4, 1, 1),
		CFrame.new(center + Vector3.new(0, 0.15, 0)) * CFrame.Angles(0, 0, math.rad(90)),
		color,
		0.15
	)
	fade(disc, time, { Size = Vector3.new(thickness or 0.4, radius * 2, radius * 2) })
end

local function beam(from: Vector3, to: Vector3, width: number, color: Color3, time: number, height: number?)
	local length = (to - from).Magnitude
	if length < 0.1 then
		return
	end
	local cframe = CFrame.lookAt(from, to) * CFrame.new(0, 0, -length / 2)
	local b = part(Enum.PartType.Block, Vector3.new(width, height or width, length), cframe, color, 0.15)
	fade(b, time, { Size = Vector3.new(0.05, 0.05, length) })
end

local function jagged(from: Vector3, to: Vector3, color: Color3, time: number, jitter: number)
	local points = { from }
	local pieces = count(6)
	for index = 1, pieces - 1 do
		local offset = Vector3.new(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5) * jitter
		table.insert(points, from:Lerp(to, index / pieces) + offset)
	end
	table.insert(points, to)
	for index = 1, #points - 1 do
		beam(points[index], points[index + 1], 0.3, color, time)
	end
end

local function spikes(center: Vector3, radius: number, color: Color3, time: number, number: number)
	for index = 1, count(number) do
		local angle = (index / number) * math.pi * 2 + math.random() * 0.4
		local distance = radius * (0.35 + math.random() * 0.65)
		local base = center + Vector3.new(math.cos(angle) * distance, 0, math.sin(angle) * distance)
		local height = 2 + math.random() * 2.5
		local spike = part(
			Enum.PartType.Wedge,
			Vector3.new(0.9, 0.2, 1.2),
			CFrame.new(base) * CFrame.Angles(0, -angle, 0),
			color,
			0.1,
			Enum.Material.Glass
		)
		TweenService:Create(spike, TweenInfo.new(0.12), { Size = Vector3.new(0.9, height, 1.2), CFrame = spike.CFrame * CFrame.new(0, height / 2, 0) }):Play()
		task.delay(0.15, function()
			fade(spike, time)
		end)
	end
end

local function arcFan(origin: Vector3, aim: Vector3, reach: number, arc: number, color: Color3, time: number, tilt: number?)
	local base = math.atan2(aim.X, aim.Z)
	local half = math.rad(arc / 2)
	local pieces = count(9)
	local stepAngle = half * 2 / pieces
	for index = 0, pieces - 1 do
		local angle = base - half + stepAngle * (index + 0.5)
		local direction = Vector3.new(math.sin(angle), 0, math.cos(angle))
		local tangent = Vector3.new(math.cos(angle), 0, -math.sin(angle))
		local position = origin + direction * reach + Vector3.new(0, 0.5, 0)
		local cframe = CFrame.lookAt(position, position + tangent) * CFrame.Angles(math.rad(tilt or 0), 0, 0)
		local segment = part(Enum.PartType.Block, Vector3.new(0.45, 0.25, reach * stepAngle * 1.2), cframe, color, 0.15)
		fade(segment, time, { Size = Vector3.new(0.1, 0.1, reach * stepAngle * 1.6) })
	end
end

local function lightning(point: Vector3, color: Color3)
	local top = point + Vector3.new(math.random() * 4 - 2, 40, math.random() * 4 - 2)
	jagged(top, point, color, 0.35, 3)
	jagged(top, point, WHITE, 0.2, 2)
	sphere(point, 4, color, 0.35)
end

local function vortex(center: Vector3, radius: number, color: Color3, duration: number)
	-- Rings closing in on the centre, plus a few streaks being drawn inward.
	for index = 0, count(3) - 1 do
		task.delay(index * duration / 3, function()
			local disc = part(
				Enum.PartType.Cylinder,
				Vector3.new(0.3, radius * 2, radius * 2),
				CFrame.new(center + Vector3.new(0, 0.2, 0)) * CFrame.Angles(0, 0, math.rad(90)),
				color,
				0.35
			)
			fade(disc, duration / 2, { Size = Vector3.new(0.3, 1, 1) }, Enum.EasingStyle.Quad)
		end)
	end
	for index = 1, count(8) do
		local angle = (index / 8) * math.pi * 2
		local from = center + Vector3.new(math.cos(angle), 0, math.sin(angle)) * radius + Vector3.new(0, 1, 0)
		beam(from, center + Vector3.new(0, 1, 0), 0.2, color, duration)
	end
end

local function sparkles(position: Vector3, color: Color3)
	for _ = 1, count(6) do
		local offset = Vector3.new(math.random() * 3 - 1.5, math.random() * 2, math.random() * 3 - 1.5)
		local spark = part(Enum.PartType.Ball, Vector3.one * 0.4, CFrame.new(position + offset), color, 0.1)
		fade(spark, 0.8, { CFrame = spark.CFrame + Vector3.new(0, 3, 0), Size = Vector3.one * 0.1 })
	end
end

local function travel(from: Vector3, to: Vector3, speed: number, makePart: () -> BasePart, trailColor: Color3?)
	local distance = (to - from).Magnitude
	local time = math.max(distance / math.max(speed, 1), 0.05)
	local piece = makePart()
	piece.CFrame = CFrame.lookAt(from, if distance > 0.1 then to else from + Vector3.new(0, 0, -1))
	local goal = CFrame.lookAt(to, to + (to - from).Unit)
	local tween = TweenService:Create(piece, TweenInfo.new(time, Enum.EasingStyle.Linear), { CFrame = goal })
	tween:Play()
	tween.Completed:Once(function()
		fade(piece, 0.2, { Size = piece.Size * 1.6 })
	end)
	if trailColor then
		task.delay(time * 0.5, function()
			beam(from, to, 0.25, trailColor, 0.3)
		end)
	end
end

local function field(center: Vector3, radius: number, duration: number, color: Color3, style: string?)
	local disc = part(
		Enum.PartType.Cylinder,
		Vector3.new(0.3, radius * 2, radius * 2),
		CFrame.new(center + Vector3.new(0, 0.15, 0)) * CFrame.Angles(0, 0, math.rad(90)),
		color,
		0.78 -- faint: the rings and swirls carry the look, the disc just marks the area
	)
	light(disc, color, radius * 1.5)
	if style == "Tanglewire" then
		-- A criss-cross of wire over the trap.
		for index = 1, count(4) do
			local angle = index / 4 * math.pi
			local offset = Vector3.new(math.cos(angle), 0, math.sin(angle)) * radius
			local wire = part(Enum.PartType.Block, Vector3.new(0.15, 0.15, radius * 2), CFrame.lookAt(center + Vector3.new(0, 0.4, 0), center + offset + Vector3.new(0, 0.4, 0)), color, 0.2)
			task.delay(duration, function()
				fade(wire, 0.4)
			end)
		end
	end
	task.spawn(function()
		local finish = os.clock() + duration
		while os.clock() < finish and disc.Parent do
			ring(center, radius, color, 0.8, 0.3)
			if style == "BloomCircle" or style == "Tidewell" then
				local sparkle = if style == "Tidewell" then UITheme.Colors.Heal else color
				for _ = 1, count(3) do
					local angle = math.random() * math.pi * 2
					sparkles(center + Vector3.new(math.cos(angle), 0, math.sin(angle)) * radius * math.random(), sparkle)
				end
			elseif style == "Maelstrom" then
				vortex(center, radius, color, 0.9)
			end
			task.wait(1)
		end
		fade(disc, 0.4)
	end)
end

-- STEP RENDERERS ---------------------------------------------------------------

type Renderer = (caster: Model, step: Moves.Step, data: { [string]: any }, color: Color3) -> ()
local RENDER: { [string]: Renderer } = {}

local function hitsFlash(data: { [string]: any }, color: Color3)
	local hits = data.Hits
	if type(hits) == "table" then
		for _, position in hits do
			if typeof(position) == "Vector3" then
				sphere(position, 2, color, 0.25)
			end
		end
	end
end

RENDER.Arc = function(_caster, step, data, color)
	local origin = data.Origin
	local aim = data.Aim
	if typeof(origin) ~= "Vector3" or typeof(aim) ~= "Vector3" then
		return
	end
	local reach = tonumber(data.Reach) or 7
	local arc = tonumber(data.Arc) or 90
	if step.Visual == "Thrust" or step.Visual == "Flurry" then
		local forward = flat(aim).Unit
		local side = Vector3.new(-forward.Z, 0, forward.X) * (math.random() - 0.5) * 1.5
		beam(origin + side + Vector3.new(0, 1, 0), origin + side + forward * reach + Vector3.new(0, 1, 0), 0.35, color, 0.2)
	else
		local tilt = if step.Visual == "Rise" or step.Visual == "RisingArc" then -55 else 0
		arcFan(origin, flat(aim).Unit, reach, arc, color, 0.35, tilt)
	end
	hitsFlash(data, color)
end

RENDER.Circle = function(_caster, step, data, color)
	local center = data.Center
	if typeof(center) ~= "Vector3" then
		return
	end
	local radius = tonumber(data.Radius) or 8
	local visual = step.Visual
	if visual == "Implode" then
		local ball = part(Enum.PartType.Ball, Vector3.one * radius * 2, CFrame.new(center + Vector3.new(0, 1, 0)), color, 0.6)
		TweenService:Create(ball, TweenInfo.new(0.18), { Size = Vector3.one * 0.5, Transparency = 0.1 }):Play()
		task.delay(0.18, function()
			ball:Destroy()
			sphere(center + Vector3.new(0, 1, 0), radius, WHITE, 0.3, 0)
			ring(center, radius * 1.2, color, 0.5)
		end)
	elseif visual == "IceRing" or visual == "IceSpikes" then
		ring(center, radius, color, 0.5)
		spikes(center, radius, color, 0.8, if visual == "IceSpikes" then 14 else 9)
	elseif visual == "Thunderclap" or visual == "LightningColumn" then
		lightning(center, color)
		if visual == "LightningColumn" then
			local column = part(Enum.PartType.Cylinder, Vector3.new(60, 3, 3), CFrame.new(center + Vector3.new(0, 30, 0)) * CFrame.Angles(0, 0, math.rad(90)), WHITE, 0.1)
			fade(column, 0.4, { Size = Vector3.new(60, radius * 2, radius * 2) })
		end
		ring(center, radius, color, 0.45)
	elseif visual == "Bloom" then
		ring(center, radius, color, 0.6)
		for _ = 1, count(5) do
			local angle = math.random() * math.pi * 2
			sparkles(center + Vector3.new(math.cos(angle), 0, math.sin(angle)) * radius * math.random(), color)
		end
	elseif visual == "Crater" then
		ring(center, radius, color, 0.45, 1)
		for _ = 1, count(8) do
			local angle = math.random() * math.pi * 2
			local chunk = part(Enum.PartType.Block, Vector3.one * (0.6 + math.random()), CFrame.new(center), UITheme.Colors.Stone, 0, Enum.Material.Slate)
			local goal = center + Vector3.new(math.cos(angle) * radius * 0.6, 2 + math.random() * 2, math.sin(angle) * radius * 0.6)
			fade(chunk, 0.6, { CFrame = CFrame.new(goal) * CFrame.Angles(math.random(), math.random(), math.random()) })
		end
	else
		ring(center, radius, color, 0.5)
		sphere(center + Vector3.new(0, 1, 0), radius * 0.6, color, 0.3)
	end
	hitsFlash(data, color)
end

RENDER.Line = function(_caster, step, data, color)
	local from, to = data.From, data.To
	if typeof(from) ~= "Vector3" or typeof(to) ~= "Vector3" then
		return
	end
	local width = tonumber(data.Width) or 3
	if step.Visual == "TidalWave" then
		-- A wall of water rolling along the line.
		local direction = (to - from).Unit
		local length = (to - from).Magnitude
		local wall = part(Enum.PartType.Block, Vector3.new(width, 5, 2), CFrame.lookAt(from + Vector3.new(0, 2.5, 0), from + Vector3.new(0, 2.5, 0) + direction), color, 0.2, Enum.Material.Glass)
		local goal = CFrame.lookAt(to + Vector3.new(0, 2.5, 0), to + Vector3.new(0, 2.5, 0) + direction)
		TweenService:Create(wall, TweenInfo.new(length / 40, Enum.EasingStyle.Linear), { CFrame = goal }):Play()
		task.delay(length / 40, function()
			fade(wall, 0.3, { Size = Vector3.new(width * 1.2, 0.2, 2) })
		end)
	elseif step.Visual == "RootLine" then
		local pieces = count(10)
		for index = 1, pieces do
			task.delay(index * 0.03, function()
				spikes(from:Lerp(to, index / pieces), width / 2, color, 0.7, 2)
			end)
		end
	else
		beam(from + Vector3.new(0, 1, 0), to + Vector3.new(0, 1, 0), width * 0.4, color, 0.35)
		beam(from + Vector3.new(0, 1, 0), to + Vector3.new(0, 1, 0), width * 0.12, WHITE, 0.2)
	end
	hitsFlash(data, color)
end

RENDER.Projectile = function(_caster, step, data, color)
	local paths = data.Paths
	if type(paths) ~= "table" then
		return
	end
	local speed = tonumber(data.Speed) or 70
	local radius = tonumber(data.Radius) or 1.5
	for _, path in paths do
		local from, to = path.From, path.To
		if typeof(from) == "Vector3" and typeof(to) == "Vector3" then
			if step.Visual == "Spear" then
				travel(from, to, speed, function(): BasePart
					local spear = part(Enum.PartType.Block, Vector3.new(0.3, 0.3, 6), CFrame.new(from), color, 0)
					light(spear, color, 10)
					return spear
				end, color)
			else
				-- A crescent: a wide, thin, curved-looking slab.
				travel(from, to, speed, function(): BasePart
					local crescent = part(Enum.PartType.Block, Vector3.new(radius * 2.2, 0.35, 1.2), CFrame.new(from), color, 0.1)
					light(crescent, color, 12)
					return crescent
				end, nil)
			end
		end
	end
end

RENDER.Dash = function(_caster, step, data, color)
	local from, to = data.From, data.To
	if typeof(from) ~= "Vector3" or typeof(to) ~= "Vector3" then
		return
	end
	local duration = tonumber(data.Duration) or 0.4
	task.delay(duration * 0.5, function()
		beam(from, to, if step.Visual == "Whirl" then 3 else 1.2, color, 0.35, 0.6)
	end)
	if step.Visual == "Whirl" then
		for index = 0, 3 do
			task.delay(index * duration / 4, function()
				ring(from:Lerp(to, index / 3), 3, color, 0.3, 0.3)
			end)
		end
	end
end

RENDER.Leap = function(_caster, _step, data, color)
	local from, to = data.From, data.To
	if typeof(from) ~= "Vector3" or typeof(to) ~= "Vector3" then
		return
	end
	local duration = tonumber(data.Duration) or 0.5
	local height = tonumber(data.Height) or 6
	-- A dotted arc tracing the jump.
	local dots = count(8)
	for index = 1, dots do
		local alpha = index / dots
		local position = from:Lerp(to, alpha) + Vector3.new(0, math.sin(alpha * math.pi) * height, 0)
		task.delay(alpha * duration, function()
			sphere(position, 0.8, color, 0.4)
		end)
	end
end

RENDER.Blink = function(_caster, _step, data, color)
	local from, to = data.From, data.To
	if typeof(from) ~= "Vector3" or typeof(to) ~= "Vector3" then
		return
	end
	sphere(from, 1.6, color, 0.3)
	jagged(from, to, color, 0.2, 1)
	local target = data.Target
	if typeof(target) == "Vector3" then
		local cross = (target - to).Unit:Cross(Vector3.yAxis)
		beam(target + cross * 2 + Vector3.new(0, 2, 0), target - cross * 2, 0.35, WHITE, 0.2)
		sphere(target, 2, color, 0.25)
	end
end

RENDER.Strikes = function(_caster, _step, data, color)
	local point = data.Point
	if typeof(point) == "Vector3" then
		lightning(point, color)
		ring(point, tonumber(data.Radius) or 4, color, 0.4)
	end
end

RENDER.Chain = function(_caster, _step, data, color)
	local links = data.Links
	if type(links) ~= "table" then
		return
	end
	for _, link in links do
		if typeof(link.From) == "Vector3" and typeof(link.To) == "Vector3" then
			jagged(link.From, link.To, color, 0.3, 2.5)
		end
	end
end

RENDER.Burst = function(_caster, step, data, color)
	local centers = data.Centers
	if type(centers) ~= "table" then
		return
	end
	local delay = tonumber(data.Delay) or 0
	local radius = tonumber(data.Radius) or 5
	for _, center in centers do
		if typeof(center) == "Vector3" then
			-- A small dark core that swells, then bursts.
			local core = part(Enum.PartType.Ball, Vector3.one * 0.8, CFrame.new(center + Vector3.new(0, 1, 0)), color, 0.2)
			TweenService:Create(core, TweenInfo.new(math.max(delay, 0.05)), { Size = Vector3.one * 2 }):Play()
			task.delay(delay, function()
				core:Destroy()
				if step.Visual == "IceShatter" then
					spikes(center, radius, color, 0.5, 8)
				end
				sphere(center + Vector3.new(0, 1, 0), radius, color, 0.35, 0.1)
			end)
		end
	end
end

RENDER.Field = function(_caster, step, data, color)
	local center = data.Center
	if typeof(center) == "Vector3" then
		field(center, tonumber(data.Radius) or 8, tonumber(data.Duration) or 4, color, step.Visual)
	end
end

RENDER.Pull = function(_caster, _step, data, color)
	local center = data.Center
	if typeof(center) == "Vector3" then
		vortex(center, tonumber(data.Radius) or 12, color, tonumber(data.Duration) or 0.4)
	end
end

RENDER.Push = function(_caster, _step, data, color)
	local center = data.Center
	if typeof(center) == "Vector3" then
		ring(center, (tonumber(data.Radius) or 12) * 1.2, color, 0.5, 1.2)
	end
end

RENDER.Heal = function(_caster, _step, data, _color)
	local healed = data.Healed
	if type(healed) == "table" then
		for _, position in healed do
			if typeof(position) == "Vector3" then
				sparkles(position, UITheme.Colors.Heal)
			end
		end
	end
end

RENDER.Leech = function(caster, _step, _data, _color)
	local root = caster:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		sparkles(root.Position, UITheme.Colors.Heal)
	end
end

RENDER.Mark = function(_caster, _step, data, color)
	local marked = data.Marked
	if type(marked) ~= "table" then
		return
	end
	local duration = tonumber(data.Duration) or 4
	for _, position in marked do
		if typeof(position) == "Vector3" then
			local diamond = part(Enum.PartType.Block, Vector3.one * 1.1, CFrame.new(position + Vector3.new(0, 4, 0)) * CFrame.Angles(math.rad(45), 0, math.rad(45)), color, 0.2)
			TweenService:Create(diamond, TweenInfo.new(duration, Enum.EasingStyle.Linear), { CFrame = diamond.CFrame * CFrame.Angles(0, math.pi * 4, 0) }):Play()
			task.delay(duration, function()
				fade(diamond, 0.2)
			end)
		end
	end
end

-- Taunt: a toll ring rolls out and every foe that answers flashes.
RENDER.Taunt = function(_caster, _step, data, color)
	local center = data.Center
	if typeof(center) == "Vector3" then
		local radius = tonumber(data.Radius) or 20
		ring(center, radius * 0.5, color, 0.4, 0.8)
		task.delay(0.12, function()
			ring(center, radius, color, 0.6, 0.6)
		end)
	end
	local targets = data.Targets
	if type(targets) == "table" then
		for _, position in targets do
			if typeof(position) == "Vector3" then
				local mark = part(Enum.PartType.Block, Vector3.new(0.5, 1.6, 0.5), CFrame.new(position + Vector3.new(0, 4.2, 0)), color, 0.1)
				fade(mark, 0.9, { CFrame = mark.CFrame + Vector3.new(0, 1.2, 0) })
			end
		end
	end
end

-- Buff: a rising spiral around everyone it touched.
RENDER.Buff = function(_caster, _step, data, color)
	local players = data.Players
	if type(players) ~= "table" then
		return
	end
	for _, position in players do
		if typeof(position) == "Vector3" then
			local feet = position - Vector3.new(0, 2.6, 0)
			ring(feet, 3, color, 0.6, 0.3)
			for index = 1, count(6) do
				local angle = index / 6 * math.pi * 2
				local start = feet + Vector3.new(math.cos(angle) * 1.8, 0.3, math.sin(angle) * 1.8)
				local mote = part(Enum.PartType.Ball, Vector3.one * 0.35, CFrame.new(start), color, 0.1)
				fade(mote, 0.8, { CFrame = CFrame.new(start + Vector3.new(0, 4.5, 0)) })
			end
		end
	end
end

-- Shield: a glassy shell forms around everyone it protects.
RENDER.Shield = function(_caster, _step, data, color)
	local players = data.Players
	if type(players) ~= "table" then
		return
	end
	for _, position in players do
		if typeof(position) == "Vector3" then
			local shell = part(Enum.PartType.Ball, Vector3.one * 2, CFrame.new(position), color, 0.55, Enum.Material.Glass)
			TweenService:Create(shell, TweenInfo.new(0.25, Enum.EasingStyle.Back), { Size = Vector3.one * 7 }):Play()
			task.delay(0.35, function()
				fade(shell, 0.6)
			end)
		end
	end
end

-- Refill: the Current rushes into the caster.
RENDER.Refill = function(_caster, _step, data, _color)
	local center = data.Center
	if typeof(center) ~= "Vector3" then
		return
	end
	local current = UITheme.Colors.Current
	local shell = part(Enum.PartType.Ball, Vector3.one * 10, CFrame.new(center), current, 0.7)
	fade(shell, 0.45, { Size = Vector3.one * 1 })
	sparkles(center, current)
end

-- MOVE EVENTS --------------------------------------------------------------------

local function stepOf(key: string, index: number): Moves.Step?
	local confluence = Confluences.All()[key]
	if confluence then
		return confluence.Move.Steps[index]
	end
	local ability = Abilities.Get(key)
	if ability then
		return ability.Move.Steps[index]
	end
	local art = Arts.ForClass(key)
	return if art then art.Move.Steps[index] else nil
end

local function colorFor(element: string?): Color3
	local def = if type(element) == "string" and element ~= "" then Spells.Attunement(element) else nil
	return if def then def.Color else STEEL
end

-- The caster's own Confluence: a banner with the name and a quick screen flash.
local function banner(name: string, color: Color3)
	local layer = Layers.Get("Overlay")
	local flash: Frame = Create.new("Frame", {
		Name = "ConfluenceFlash",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = color,
		BackgroundTransparency = 0.55,
		ZIndex = 50,
		Parent = layer,
	})
	TweenService:Create(flash, TweenInfo.new(0.35), { BackgroundTransparency = 1 }):Play()
	local label: TextLabel = Create.new("TextLabel", {
		Name = "ConfluenceBanner",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.3),
		Size = UDim2.fromOffset(700, 60),
		BackgroundTransparency = 1,
		FontFace = UITheme.Fonts.Display,
		TextSize = 44,
		TextColor3 = color,
		TextStrokeTransparency = 0.2,
		TextStrokeColor3 = UITheme.Colors.Overlay,
		Text = string.upper(name),
		ZIndex = 51,
		Parent = layer,
	})
	local scale: UIScale = Create.new("UIScale", { Scale = 1.4, Parent = label })
	TweenService:Create(scale, TweenInfo.new(0.25, Enum.EasingStyle.Back), { Scale = 1 }):Play()
	task.delay(Config.Current.Confluence.BannerTime, function()
		local tween = TweenService:Create(label, TweenInfo.new(0.3), { TextTransparency = 1, TextStrokeTransparency = 1 })
		tween:Play()
		tween.Completed:Once(function()
			label:Destroy()
			flash:Destroy()
		end)
	end)
end

-- Someone else's Confluence: its name floats above them for a moment.
local function nameplate(caster: Model, name: string, color: Color3)
	local head = caster:FindFirstChild("Head")
	if not head or not head:IsA("BasePart") then
		return
	end
	local gui: BillboardGui = Create.new("BillboardGui", {
		Name = "ConfluenceName",
		Size = UDim2.fromOffset(260, 30),
		StudsOffsetWorldSpace = Vector3.new(0, 3.5, 0),
		AlwaysOnTop = true,
		Adornee = head,
		Parent = head,
	})
	Create.new("TextLabel", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		FontFace = UITheme.Fonts.Display,
		TextSize = 20,
		TextColor3 = color,
		TextStrokeTransparency = 0.3,
		Text = name,
		Parent = gui,
	})
	task.delay(Config.Current.Confluence.BannerTime, function()
		gui:Destroy()
	end)
end

local function onMoveStart(caster: Model, kind: string, key: string, _aim: Vector3, element: string)
	if typeof(caster) ~= "Instance" or not caster:IsA("Model") or type(key) ~= "string" then
		return
	end
	local color = colorFor(element)
	if kind == "Ability" then
		-- Abilities without an element glow in their Position's colour.
		local ability = Abilities.Get(key)
		local position = if ability then Positions.Get(ability.Position) else nil
		if position and (type(element) ~= "string" or element == "") then
			color = position.Color
		end
		moveColors[caster] = color
		local strings = Strings.Abilities[key]
		if strings and caster ~= player.Character then
			nameplate(caster, strings.Name, color)
		end
		return
	end
	moveColors[caster] = color
	if kind ~= "Confluence" then
		return
	end
	local strings = Strings.Confluences[key]
	local name = if strings then strings.Name else key
	if caster == player.Character then
		banner(name, color)
	else
		nameplate(caster, name, color)
	end
	local root = caster:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		sphere(root.Position, 5, color, 0.4)
		ring(root.Position - Vector3.new(0, 2.5, 0), 10, color, 0.6)
	end
end

local function onMoveStep(caster: Model, key: string, index: number, data: any)
	if typeof(caster) ~= "Instance" or type(key) ~= "string" or type(data) ~= "table" then
		return
	end
	if key == "Shatter" then
		local center = data.Center
		if typeof(center) == "Vector3" then
			spikes(center, 4, colorFor("Rime"), 0.5, 10)
			sphere(center, 4, WHITE, 0.3, 0.1)
		end
		return
	end
	local step = if type(index) == "number" then stepOf(key, index) else nil
	if not step then
		return
	end
	local color = moveColors[caster] or STEEL
	local renderer = RENDER[step.Do]
	if renderer then
		renderer(caster, step, data, color)
	end
	if caster == player.Character then
		if step.Camera == "Punch" then
			CameraController.Punch(Config.Camera.PunchDegrees * 0.6)
			CameraController.Shake(Config.Combat.CameraShake.Heavy)
		elseif step.Camera == "Shake" then
			CameraController.Shake(Config.Combat.CameraShake.Slam)
		end
	end
end

function ArtVFXController.Start()
	Net.OnClient("MoveStart", onMoveStart)
	Net.OnClient("MoveStep", onMoveStep)
	Players.PlayerRemoving:Connect(function(leaving: Player)
		local character = leaving.Character
		if character then
			moveColors[character] = nil
		end
	end)
end

return ArtVFXController
