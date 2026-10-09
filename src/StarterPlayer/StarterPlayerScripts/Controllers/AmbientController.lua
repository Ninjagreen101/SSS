--!strict
-- AmbientController: client-side ambient life. Townsfolk stroll the main
-- streets along WalkerNode routes, gulls wheel over the harbour and roost on
-- rooftops, fish school in the bay and canals, merchants call out to passers-by
-- and each zone plays its ambience loop. Everything here is cosmetic, local to
-- the player, distance-culled and scaled by EffectsQuality.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TextChatService = game:GetService("TextChatService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Strings = require(Shared.Strings)
local Rng = require(Shared.Util.Rng)
local AssetManifest = require(Shared.Data.AssetManifest)

local SettingsController = require(script.Parent.SettingsController)

local A = Config.World.Ambient
local Palette = Config.Palette

local AmbientController = {}

local folder: Folder
local rng = Rng.new(os.time())

-- ------------------------------------------------------------ templates

local function kitTemplate(id: string): BasePart?
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local kit = assets and assets:FindFirstChild("Kit")
	local t = kit and kit:FindFirstChild(id)
	return if t and t:IsA("BasePart") then t else nil
end

local function makeBody(id: string, fallbackSize: Vector3, color: Color3, material: Enum.Material): BasePart
	local t = kitTemplate(id)
	local p: BasePart
	if t then
		p = t:Clone()
	else
		local part = Instance.new("Part")
		part.Shape = Enum.PartType.Block
		part.Size = fallbackSize
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		p = part
	end
	p.Name = id
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Color = color
	p.Material = material
	p.Parent = folder
	return p
end

-- --------------------------------------------------------------- walkers

type Walker = {
	body: BasePart,
	route: { Vector3 },
	index: number,
	dir: number,
	pos: Vector3,
	speed: number,
	phase: number,
	pause: number,
}

local walkers: { Walker } = {}

local function collectRoutes(): { [string]: { Vector3 } }
	type Node = { index: number, pos: Vector3 }
	local byRoute: { [string]: { Node } } = {}
	for _, m in CollectionService:GetTagged("WalkerNode") do
		if m:IsA("BasePart") then
			local route = m:GetAttribute("Route")
			local index = m:GetAttribute("Index")
			if type(route) == "string" and type(index) == "number" then
				local list = byRoute[route]
				if not list then
					list = {}
					byRoute[route] = list
				end
				table.insert(list, { index = index, pos = (m :: BasePart).Position })
			end
		end
	end
	local out: { [string]: { Vector3 } } = {}
	for route, list in byRoute do
		table.sort(list, function(a: Node, b: Node): boolean
			return a.index < b.index
		end)
		local pts: { Vector3 } = {}
		for _, e in list do
			table.insert(pts, e.pos)
		end
		if #pts >= 2 then
			out[route] = pts
		end
	end
	return out
end

local CLOTHES = { "ClothRed", "ClothTeal", "ClothOchre", "ClothNavy", "Linen", "WoodLight", "Sail" }

local function spawnWalkers()
	local routes = collectRoutes()
	local names = {}
	for name in routes do
		table.insert(names, name)
	end
	table.sort(names)
	if #names == 0 then
		return
	end
	local count = math.floor(A.WalkerCount * SettingsController.QualityScale() + 0.5)
	for i = 1, count do
		local route = routes[names[(i - 1) % #names + 1]]
		local idx = rng:int(1, #route - 1)
		local body = makeBody(if i % 3 == 0 then "townsfolk_b" else "townsfolk_a", Vector3.new(2.2, 5.6, 2.2), Palette[rng:pick(CLOTHES)] or Palette.Linen, Enum.Material.Fabric)
		table.insert(walkers, {
			body = body,
			route = route,
			index = idx,
			dir = if rng:chance(0.5) then 1 else -1,
			pos = route[idx] + Vector3.new(rng:range(-2, 2), 0, rng:range(-2, 2)),
			speed = A.WalkerSpeed * rng:range(0.75, 1.15),
			phase = rng:range(0, 10),
			pause = 0,
		})
	end
end

local function stepWalkers(dt: number, camPos: Vector3)
	local far = A.WalkerRenderDistance
	for _, w in walkers do
		local nextIdx = w.index + w.dir
		if nextIdx < 1 or nextIdx > #w.route then
			w.dir = -w.dir
			nextIdx = w.index + w.dir
			w.pause = rng:range(1, 4)
		end
		if w.pause > 0 then
			w.pause -= dt
		else
			local target = w.route[nextIdx]
			local delta = Vector3.new(target.X - w.pos.X, 0, target.Z - w.pos.Z)
			local dist = delta.Magnitude
			if dist < 1 then
				w.index = nextIdx
			else
				local step = math.min(dist, w.speed * dt)
				w.pos += delta.Unit * step
				-- follow the street's height along the segment (stairs, ramps)
				local a = w.route[w.index]
				local seg = Vector3.new(target.X - a.X, 0, target.Z - a.Z)
				local t = if seg.Magnitude > 0 then math.clamp(Vector3.new(w.pos.X - a.X, 0, w.pos.Z - a.Z):Dot(seg) / seg.Magnitude ^ 2, 0, 1) else 1
				w.pos = Vector3.new(w.pos.X, a.Y + (target.Y - a.Y) * t, w.pos.Z)
			end
		end
		local visible = (w.pos - camPos).Magnitude < far
		w.body.LocalTransparencyModifier = if visible then 0 else 1
		if visible then
			w.phase += dt * (if w.pause > 0 then 1 else 7)
			local bob = if w.pause > 0 then 0 else math.abs(math.sin(w.phase)) * 0.25
			local sway = math.sin(w.phase * 0.5) * 0.05
			local target = w.route[math.clamp(w.index + w.dir, 1, #w.route)]
			local look = Vector3.new(target.X, w.pos.Y, target.Z)
			local base = if (look - w.pos).Magnitude > 0.1 then CFrame.lookAt(w.pos, look) else CFrame.new(w.pos)
			local h = w.body.Size.Y / 2
			w.body.CFrame = base * CFrame.new(0, h + bob, 0) * CFrame.Angles(0, 0, sway)
		end
	end
end

-- ------------------------------------------------------------ gulls & fish

type Circler = { body: BasePart, centre: Vector3, radius: number, angle: number, speed: number, height: number, flap: number, baseSize: Vector3 }

local gulls: { Circler } = {}
local fish: { Circler } = {}

-- fish that patrol up and down a canal segment just under the Current surface
type Swimmer = { body: BasePart, origin: CFrame, half: number, width: number, t: number, speed: number, lane: number }
local swimmers: { Swimmer } = {}

local function spawnCirclers()
	local scale = SettingsController.QualityScale()
	local circles = CollectionService:GetTagged("GullCircle")
	local perGroup = math.max(1, math.floor(A.GullCount * scale / math.max(1, #circles)))
	for _, m in circles do
		if m:IsA("BasePart") then
			local radius = (m:GetAttribute("Radius") :: number?) or 60
			for _ = 1, perGroup do
				local body = makeBody("gull", Vector3.new(5, 0.6, 3), Palette.Linen, Enum.Material.SmoothPlastic)
				table.insert(gulls, {
					body = body,
					centre = (m :: BasePart).Position,
					radius = radius * rng:range(0.5, 1.1),
					angle = rng:range(0, math.pi * 2),
					speed = rng:range(0.12, 0.25) * (if rng:chance(0.5) then 1 else -1),
					height = rng:range(-8, 12),
					flap = rng:range(0, 6),
					baseSize = body.Size,
				})
			end
		end
	end
	local schools = CollectionService:GetTagged("FishSchool")
	for _, m in schools do
		if m:IsA("BasePart") then
			for _ = 1, math.max(2, math.floor(A.FishPerCanal * scale)) do
				local body = makeBody("fish", Vector3.new(0.6, 0.8, 2.6), Palette.Steel, Enum.Material.SmoothPlastic)
				table.insert(fish, {
					body = body,
					centre = (m :: BasePart).Position,
					radius = ((m:GetAttribute("Radius") :: number?) or 30) * rng:range(0.2, 0.9),
					angle = rng:range(0, math.pi * 2),
					speed = rng:range(0.3, 0.6),
					height = rng:range(-2.5, -0.5),
					flap = rng:range(0, 6),
					baseSize = body.Size,
				})
			end
		end
	end
end

local swimmerMarkers: { [Instance]: boolean } = {}

-- canal markers stream in and out with their canal, so fish are added per marker
local function addSwimmers(m: Instance)
	if not m:IsA("BasePart") or swimmerMarkers[m] then
		return
	end
	swimmerMarkers[m] = true
	local scale = SettingsController.QualityScale()
	local length = (m:GetAttribute("Length") :: number?) or 40
	local width = (m:GetAttribute("Width") :: number?) or 12
	local count = math.max(1, math.floor(length / 30 * scale + 0.5))
	for _ = 1, count do
		local body = makeBody("fish", Vector3.new(0.6, 0.8, 2.6), Palette.CurrentTeal, Enum.Material.Neon)
		body.Size *= 0.7
		table.insert(swimmers, {
			body = body,
			origin = (m :: BasePart).CFrame,
			half = length / 2 - 2,
			width = width,
			t = rng:range(-1, 1),
			speed = rng:range(0.08, 0.16) * (if rng:chance(0.5) then 1 else -1),
			lane = rng:range(-0.35, 0.35),
		})
	end
end

local function spawnSwimmers()
	for _, m in CollectionService:GetTagged("CanalFlow") do
		addSwimmers(m)
	end
	CollectionService:GetInstanceAddedSignal("CanalFlow"):Connect(addSwimmers)
end

local function stepSwimmers(dt: number, camPos: Vector3)
	for _, s in swimmers do
		local pos = s.origin.Position
		if (pos - camPos).Magnitude > 300 then
			s.body.LocalTransparencyModifier = 1
			continue
		end
		s.body.LocalTransparencyModifier = 0
		s.t += s.speed * dt * 30 / math.max(s.half, 1)
		if s.t > 1 or s.t < -1 then
			s.speed = -s.speed
			s.t = math.clamp(s.t, -1, 1)
		end
		local wiggle = math.sin(os.clock() * 6 + s.lane * 10) * 0.25
		local local_ = Vector3.new(s.t * s.half, -1.2, s.lane * s.width + wiggle)
		local world = s.origin:PointToWorldSpace(local_)
		local ahead = s.origin:PointToWorldSpace(local_ + Vector3.new(math.sign(s.speed), 0, 0))
		s.body.CFrame = CFrame.lookAt(world, ahead)
	end
end

local function stepCirclers(list: { Circler }, dt: number, camPos: Vector3, flaps: boolean)
	for _, c in list do
		c.angle += c.speed * dt
		local pos = c.centre + Vector3.new(math.cos(c.angle) * c.radius, c.height + math.sin(c.angle * 2) * 1.5, math.sin(c.angle) * c.radius)
		if (pos - camPos).Magnitude > 600 then
			c.body.LocalTransparencyModifier = 1
			continue
		end
		c.body.LocalTransparencyModifier = 0
		local tangent = Vector3.new(-math.sin(c.angle), 0, math.cos(c.angle)) * (if c.speed > 0 then 1 else -1)
		local bank = if flaps then -0.35 * math.sign(c.speed) else 0
		c.body.CFrame = CFrame.lookAt(pos, pos + tangent) * CFrame.Angles(0, 0, bank)
		if flaps then
			c.flap += dt * 6
			local s = 0.55 + 0.45 * math.abs(math.sin(c.flap))
			c.body.Size = Vector3.new(c.baseSize.X * s, c.baseSize.Y, c.baseSize.Z)
		end
	end
end

-- ------------------------------------------------------- merchant calls

local function merchantCalls()
	while true do
		task.wait(rng:range(A.MerchantCallInterval[1], A.MerchantCallInterval[2]))
		local player = Players.LocalPlayer
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			local options: { BasePart } = {}
			for _, m in CollectionService:GetTagged("MerchantCall") do
				if m:IsA("BasePart") and ((m :: BasePart).Position - root.Position).Magnitude < A.MerchantCallRadius then
					table.insert(options, m :: BasePart)
				end
			end
			if #options > 0 then
				local m = rng:pick(options)
				local set = (m:GetAttribute("Lines") :: string?) or "Market"
				local lines = Strings.MerchantLines[set] or Strings.MerchantLines.Market
				pcall(function()
					TextChatService:DisplayBubble(m, rng:pick(lines))
				end)
			end
		end
	end
end

-- -------------------------------------------------------------- ambience

local ambience: Sound? = nil

local function setAmbience(name: string?)
	local id = if name then AssetManifest.Ambience[name] else nil
	local old = ambience
	if old then
		local fade = TweenService:Create(old, TweenInfo.new(2), { Volume = 0 })
		fade.Completed:Once(function()
			old:Destroy()
		end)
		fade:Play()
		ambience = nil
	end
	if id and id ~= "" then
		local s = Instance.new("Sound")
		s.Name = "Ambience_" .. (name :: string)
		s.SoundId = id
		s.Looped = true
		s.Volume = 0
		s.Parent = SoundService
		s:Play()
		TweenService:Create(s, TweenInfo.new(2), { Volume = 0.5 }):Play()
		ambience = s
	end
end

function AmbientController.Init()
	local f = Instance.new("Folder")
	f.Name = "AmbientLife"
	f.Parent = Workspace
	folder = f
end

function AmbientController.Start()
	local player = Players.LocalPlayer
	-- markers for routes and circles live in the persistent Markers model
	task.wait(2)
	if SettingsController.Get("AmbientLife") ~= false then
		spawnWalkers()
		spawnCirclers()
		spawnSwimmers()
	end
	task.spawn(merchantCalls)
	setAmbience(player:GetAttribute("ZoneAmbience") :: string?)
	player:GetAttributeChangedSignal("ZoneAmbience"):Connect(function()
		setAmbience(player:GetAttribute("ZoneAmbience") :: string?)
	end)
	RunService.RenderStepped:Connect(function(dt: number)
		local camera = Workspace.CurrentCamera
		if not camera then
			return
		end
		local camPos = camera.CFrame.Position
		stepWalkers(dt, camPos)
		stepCirclers(gulls, dt, camPos, true)
		stepCirclers(fish, dt, camPos, false)
		stepSwimmers(dt, camPos)
	end)
end

return AmbientController
