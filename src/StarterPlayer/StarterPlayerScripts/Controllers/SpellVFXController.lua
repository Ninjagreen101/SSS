--!strict
--[[
	SpellVFXController
	Draws the Current on every client. Nothing here affects gameplay.

	- Projectiles (players' Bolts and mobs' brine bolts) from the Projectile
	  remote: a glowing ball flying the server's path in the bolt's colour.
	- One-off spell shapes from SpellVisual: Wave (arcs fanning out), Lance
	  (a beam), Well (a pulsing pool), Step (a streak and a burst), Chain
	  (Tempest lightning jumping between enemies).
	- Ward bubbles around any Climber whose Shield attribute is above 0.
	- Resonance: at Resonance.GlowStacks or more, a Climber's blade glows in
	  their Attunement's colour.
	All parts live in a local Workspace folder and are cleaned up as they fade.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Attributes = require(Shared.Attributes)
local Net = require(Shared.Net)
local Spells = require(Shared.Data.Spells)

local A = Attributes.Names

local SpellVFXController = {}

local folder: Folder? = nil

local function fx(): Folder
	local existing = folder
	if existing and existing.Parent then
		return existing
	end
	local created = Instance.new("Folder")
	created.Name = "SpellFX"
	created.Parent = Workspace
	folder = created
	return created
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

local function fade(p: BasePart, time: number, goal: { [string]: any }?)
	local properties: { [string]: any } = goal or {}
	properties.Transparency = 1
	local tween = TweenService:Create(p, TweenInfo.new(time, Enum.EasingStyle.Quad, Enum.EasingDirection.In), properties)
	tween:Play()
	tween.Completed:Once(function()
		p:Destroy()
	end)
end

local function burst(position: Vector3, color: Color3, radius: number)
	local ball = part(Enum.PartType.Ball, Vector3.one * 1, CFrame.new(position), color, 0.3)
	fade(ball, 0.35, { Size = Vector3.one * radius * 2 })
end

-- PROJECTILES --------------------------------------------------------------------

type Bolt = { Part: BasePart, Velocity: Vector3, Remaining: number }
local bolts: { [number]: Bolt } = {}

local function endBolt(id: number, position: Vector3?)
	local bolt = bolts[id]
	if not bolt then
		return
	end
	bolts[id] = nil
	if position then
		bolt.Part.Position = position
	end
	fade(bolt.Part, 0.25, { Size = bolt.Part.Size * 2.5 })
end

local function onProjectile(kind: string, id: number, a: any, b: any, c: any, d: any, e: any)
	if type(id) ~= "number" then
		return
	end
	if kind == "Spawn" and typeof(a) == "Vector3" and typeof(b) == "Vector3" and type(c) == "number" and type(d) == "number" then
		local color = if typeof(e) == "Color3" then e else Color3.fromHex("#4FE0D2")
		local ball = part(Enum.PartType.Ball, Vector3.one * c * 2, CFrame.new(a), color, 0.15)
		ball.Name = "Bolt"
		local light = Instance.new("PointLight")
		light.Color = color
		light.Range = 10
		light.Brightness = 1.5
		light.Shadows = false
		light.Parent = ball
		bolts[id] = { Part = ball, Velocity = b, Remaining = d }
	elseif kind == "End" then
		endBolt(id, if typeof(a) == "Vector3" then a else nil)
	end
end

local function stepBolts(dt: number)
	for id, bolt in bolts do
		local travel = bolt.Velocity * dt
		bolt.Part.Position += travel
		bolt.Remaining -= travel.Magnitude
		if bolt.Remaining <= 0 then
			endBolt(id, nil)
		end
	end
end

-- SPELL SHAPES -------------------------------------------------------------------

local function rootOf(model: Model): BasePart?
	local root = model:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function wave(caster: Model, color: Color3, aim: Vector3, reach: number, arc: number)
	local root = rootOf(caster)
	if not root then
		return
	end
	local flatAim = Vector3.new(aim.X, 0, aim.Z)
	if flatAim.Magnitude < 0.01 then
		return
	end
	local base = math.atan2(flatAim.X, flatAim.Z)
	local half = math.rad(arc / 2)
	local centre = root.Position - Vector3.new(0, 1.5, 0)
	for ring, fraction in { 0.35, 0.65, 1 } do
		task.delay(ring * 0.05, function()
			local radius = reach * fraction
			local count = 8
			local step = half * 2 / count
			for index = 0, count - 1 do
				local angle = base - half + step * (index + 0.5)
				local direction = Vector3.new(math.sin(angle), 0, math.cos(angle))
				local tangent = Vector3.new(math.cos(angle), 0, -math.sin(angle))
				local position = centre + direction * radius
				local segment = part(Enum.PartType.Block, Vector3.new(0.5, 0.35, radius * step * 1.15), CFrame.lookAt(position, position + tangent), color, 0.2)
				fade(segment, 0.4)
			end
		end)
	end
end

local function lance(color: Color3, from: Vector3, to: Vector3)
	local length = (to - from).Magnitude
	if length < 0.1 then
		return
	end
	local cframe = CFrame.lookAt(from, to) * CFrame.new(0, 0, -length / 2)
	local beam = part(Enum.PartType.Block, Vector3.new(1.1, 1.1, length), cframe, color, 0.1)
	fade(beam, 0.4, { Size = Vector3.new(0.05, 0.05, length) })
	local core = part(Enum.PartType.Block, Vector3.new(0.35, 0.35, length), cframe, Color3.new(1, 1, 1), 0)
	fade(core, 0.25)
	burst(to, color, 2.5)
end

local function well(color: Color3, position: Vector3, radius: number, duration: number)
	local disc = part(Enum.PartType.Cylinder, Vector3.new(0.3, radius * 2, radius * 2), CFrame.new(position + Vector3.new(0, 0.2, 0)) * CFrame.Angles(0, 0, math.rad(90)), color, 0.55)
	local light = Instance.new("PointLight")
	light.Color = color
	light.Range = radius * 1.5
	light.Brightness = 1
	light.Shadows = false
	light.Parent = disc
	task.spawn(function()
		local finish = os.clock() + duration
		while os.clock() < finish and disc.Parent do
			local ring = part(Enum.PartType.Cylinder, Vector3.new(0.35, 1, 1), disc.CFrame, color, 0.2)
			fade(ring, 0.8, { Size = Vector3.new(0.35, radius * 2, radius * 2) })
			task.wait(1)
		end
		fade(disc, 0.4)
	end)
end

local function step(color: Color3, from: Vector3, to: Vector3, radius: number)
	local length = (to - from).Magnitude
	if length > 0.1 then
		local streak = part(Enum.PartType.Block, Vector3.new(0.6, 2.5, length), CFrame.lookAt(from, to) * CFrame.new(0, 0, -length / 2), color, 0.3)
		fade(streak, 0.35, { Size = Vector3.new(0.05, 0.4, length) })
	end
	burst(to, color, radius)
end

local function chain(color: Color3, from: Vector3, to: Vector3)
	local points = { from }
	local pieces = 5
	for index = 1, pieces - 1 do
		local jitter = Vector3.new(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5) * 2.5
		table.insert(points, from:Lerp(to, index / pieces) + jitter)
	end
	table.insert(points, to)
	for index = 1, #points - 1 do
		local a, b = points[index], points[index + 1]
		local length = (b - a).Magnitude
		local bolt = part(Enum.PartType.Block, Vector3.new(0.25, 0.25, length), CFrame.lookAt(a, b) * CFrame.new(0, 0, -length / 2), color, 0)
		fade(bolt, 0.3)
	end
end

-- A thrown flask (quick items): arcs to the aim point, then bursts.
local function throw(color: Color3, from: Vector3, to: Vector3, radius: number)
	local flask = part(Enum.PartType.Ball, Vector3.one * 0.6, CFrame.new(from), color, 0)
	local duration = Config.Items.Consumables.ThrowTime
	local started = os.clock()
	local connection: RBXScriptConnection? = nil
	connection = RunService.RenderStepped:Connect(function()
		local alpha = math.clamp((os.clock() - started) / duration, 0, 1)
		local height = 4 * 3 * alpha * (1 - alpha)
		flask.CFrame = CFrame.new(from:Lerp(to, alpha) + Vector3.new(0, height, 0))
		if alpha >= 1 then
			if connection then
				connection:Disconnect()
			end
			flask:Destroy()
			burst(to, color, radius)
		end
	end)
end

local function onSpellVisual(caster: Model, spellId: string, kind: string, data: any)
	if typeof(caster) ~= "Instance" or type(spellId) ~= "string" or type(data) ~= "table" then
		return
	end
	local spell = Spells.Get(spellId)
	local color = if typeof(data.Color) == "Color3" then data.Color elseif spell then spell.Element.Color else Color3.new(1, 1, 1)
	if kind == "Wave" and typeof(data.Aim) == "Vector3" then
		wave(caster, color, data.Aim, tonumber(data.Reach) or 12, tonumber(data.Arc) or 90)
	elseif kind == "Lance" and typeof(data.From) == "Vector3" and typeof(data.To) == "Vector3" then
		lance(color, data.From, data.To)
	elseif kind == "Well" and typeof(data.Position) == "Vector3" then
		well(color, data.Position, tonumber(data.Radius) or 8, tonumber(data.Duration) or 5)
	elseif kind == "Step" and typeof(data.From) == "Vector3" and typeof(data.To) == "Vector3" then
		step(color, data.From, data.To, tonumber(data.Radius) or 6)
	elseif kind == "Chain" and typeof(data.From) == "Vector3" and typeof(data.To) == "Vector3" then
		chain(color, data.From, data.To)
	elseif kind == "Throw" and typeof(data.From) == "Vector3" and typeof(data.To) == "Vector3" then
		throw(color, data.From, data.To, tonumber(data.Radius) or 6)
	elseif kind == "Burst" and typeof(data.Position) == "Vector3" then
		burst(data.Position, color, tonumber(data.Radius) or 6)
	end
end

-- WARDS AND BLADE GLOW -----------------------------------------------------------

type Look = { Bubble: Part?, Blade: { [BasePart]: Color3 } }
local looks: { [Player]: Look } = {}

local function attunementColor(player: Player): Color3
	local attunement = player:GetAttribute(A.Attunement)
	local element = if type(attunement) == "string" then Spells.Attunement(attunement) else nil
	return if element then element.Color else Color3.fromHex("#3FE0D0")
end

local function updateLooks()
	for _, player in Players:GetPlayers() do
		local look = looks[player]
		if not look then
			look = { Bubble = nil, Blade = {} }
			looks[player] = look
		end
		local character = player.Character
		local root = character and rootOf(character)
		local color = attunementColor(player)

		-- Ward bubble.
		local shield = player:GetAttribute(A.Shield)
		local warded = type(shield) == "number" and shield > 0 and root ~= nil
		local bubble = look.Bubble
		if warded and root then
			if not bubble or not bubble.Parent then
				bubble = part(Enum.PartType.Ball, Vector3.one * 7, root.CFrame, color, 0.55, Enum.Material.ForceField)
				look.Bubble = bubble
			end
			(bubble :: Part).CFrame = root.CFrame
		elseif bubble then
			look.Bubble = nil
			fade(bubble, 0.2)
		end

		-- Resonance blade glow: the blade takes on the Attunement colour a
		-- little more with every stack and turns Neon at GlowStacks. While
		-- Infused it glows fully in the Infusion's element colour.
		local R = Config.Current.Resonance
		local rawStacks = player:GetAttribute(A.Resonance)
		local stacks = if type(rawStacks) == "number" then rawStacks else 0
		local infusion = player:GetAttribute(A.Infusion)
		local infusedUntil = player:GetAttribute(A.InfusedUntil)
		local infused = type(infusion) == "string"
			and infusion ~= ""
			and type(infusedUntil) == "number"
			and infusedUntil > Workspace:GetServerTimeNow()
		local infusionElement = if infused then Spells.Attunement(infusion :: string) else nil
		local glowColor = if infusionElement then infusionElement.Color else color
		local alpha = if infusionElement then 1 else math.clamp(stacks / R.MaxStacks, 0, 1)
		local glowing = alpha > 0
		local neon = infusionElement ~= nil or stacks >= R.GlowStacks
		local weapon = character and character:FindFirstChild("SpireWeapon")
		if weapon then
			for _, piece in weapon:GetChildren() do
				if piece:IsA("BasePart") and piece.Name == "Blade" then
					if glowing then
						if not look.Blade[piece] then
							look.Blade[piece] = piece.Color
						end
						piece.Color = look.Blade[piece]:Lerp(glowColor, alpha)
						piece.Material = if neon then Enum.Material.Neon else Enum.Material.Metal
					elseif look.Blade[piece] then
						piece.Color = look.Blade[piece]
						piece.Material = Enum.Material.Metal
						look.Blade[piece] = nil
					end
				end
			end
		end
	end
end

function SpellVFXController.Start()
	Net.OnClient("Projectile", onProjectile)
	Net.OnClient("SpellVisual", onSpellVisual)
	Players.PlayerRemoving:Connect(function(player: Player)
		local look = looks[player]
		if look and look.Bubble then
			look.Bubble:Destroy()
		end
		looks[player] = nil
	end)
	RunService.RenderStepped:Connect(function(dt: number)
		stepBolts(dt)
		updateLooks()
	end)
end

return SpellVFXController
