--!strict
--[[
	DungeonBuilder (edit-time tool)
	Builds dungeon templates into ServerStorage.Dungeons. DungeonService clones a template for
	each group that enters (instanced per group), far outside the floor.

	The Sunken Cistern (Floor 1), template space: origin = the arrival point, +Z = deeper in.
	  Entry vault    z 0..32     the arrival point and the way out (ExitPortal)
	  Gallery        z 32..96    a vaulted corridor; leeches in the drains
	  Flooded Hall   z 96..160   a pillared reservoir; two sluice levers (DungeonLever) in the far
	                             corners; leech packs and a Lantern Acolyte
	  Sluice         z 160       the gate (SluiceGate) that opens when both levers are pulled
	  Altar Chamber  z 160..208  the elite acolyte's guard; the reward chest (DungeonChest) and a
	                             second ExitPortal

	Named parts DungeonService looks for: Arrival, ExitPortal (any number), SluiceGate,
	DungeonChest (a Model), DungeonLever (Models, tagged), and the Spawns folder (spawn points
	with MobService attributes, moved into Workspace.MobSpawns while the instance runs).
	Usage: require(game.ServerStorage.Tools.DungeonBuilder).SunkenCistern()
]]

local CollectionService = game:GetService("CollectionService")
local ServerStorage = game:GetService("ServerStorage")

local Kit = require(script.Parent.KitLibrary)

local DungeonBuilder = {}

local HALF_PI = math.pi / 2
local CURRENT = Color3.fromHex("#3FE0D0")
local DARK = Color3.fromHex("#1D2124")

local function part(parent: Instance, name: string, size: Vector3, cf: CFrame, props: { [string]: any }?): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.Size = size
	p.CFrame = cf
	p.Material = Enum.Material.Slate
	p.Color = DARK
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	if props then
		for k, v in props do
			(p :: any)[k] = v
		end
	end
	p.Parent = parent
	return p
end

local function put(parent: Instance, piece: string, cf: CFrame, opts: Kit.PlaceOptions?)
	local o: Kit.PlaceOptions = opts or {}
	if o.Flatten == nil then
		o.Flatten = true
	end
	Kit.Place(piece, cf, parent, o)
end

-- A straight wall from x0 to x1 (or along z) out of 16-wide panels, decorated face toward `inward`.
local function wallRun(parent: Instance, from: Vector3, to: Vector3, inward: Vector3, scaleY: number?)
	local len = (to - from).Magnitude
	local n = math.max(1, math.ceil(len / 16))
	local seg = len / n
	for k = 0, n - 1 do
		local pos = from:Lerp(to, (k + 0.5) / n)
		put(parent, "Cistern_Wall_16", CFrame.lookAt(pos, pos - inward), { Scale = Vector3.new(seg / 16 + 0.02, scaleY or 1, 1) })
	end
end

local function floorTiles(parent: Instance, x0: number, x1: number, z0: number, z1: number, y: number)
	local x = x0 + 8
	while x < x1 do
		local z = z0 + 8
		while z < z1 do
			put(parent, "Cistern_Floor_16", CFrame.new(x, y, z))
			z += 16
		end
		x += 16
	end
end

local function spawnPoint(folder: Folder, mob: string, at: Vector3, count: number, patrol: number, elite: boolean?)
	local p = part(folder, mob, Vector3.new(4, 1, 4), CFrame.new(at + Vector3.new(0, 1, 0)), {
		Transparency = 1,
		CanCollide = false,
		CanQuery = false,
		CanTouch = false,
	})
	p:SetAttribute("MobId", mob)
	p:SetAttribute("SpawnCount", count)
	p:SetAttribute("PatrolRadius", patrol)
	p:SetAttribute("RespawnTime", 99999) -- a dungeon does not refill
	p:SetAttribute("Zone", "SunkenCistern")
	if elite then
		p:SetAttribute("Elite", true)
	end
end

local function portal(parent: Instance, cf: CFrame)
	local sheet = part(parent, "ExitPortal", Vector3.new(10, 14, 0.6), cf * CFrame.new(0, 7, 0), {
		Material = Enum.Material.Neon,
		Color = CURRENT,
		Transparency = 0.35,
		CanCollide = false,
		CanQuery = false,
		CastShadow = false,
	})
	local light = Instance.new("PointLight")
	light.Color = CURRENT
	light.Range = 22
	light.Brightness = 1.5
	light.Parent = sheet
	local swirl = Instance.new("ParticleEmitter")
	swirl.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	swirl.Color = ColorSequence.new(CURRENT)
	swirl.LightEmission = 1
	swirl.Size = NumberSequence.new(0.4)
	swirl.Rate = 14
	swirl.Lifetime = NumberRange.new(1.2, 2)
	swirl.Speed = NumberRange.new(1, 3)
	swirl.SpreadAngle = Vector2.new(180, 180)
	swirl.Parent = sheet
	return sheet
end

local function lever(parent: Instance, name: string, cf: CFrame)
	local model = Instance.new("Model")
	model.Name = name
	local post = part(model, "Post", Vector3.new(1.2, 4.5, 1.2), cf * CFrame.new(0, 2.25, 0), { Material = Enum.Material.Metal,
		Color = Color3.fromHex("#3D4045") })
	part(model, "Handle", Vector3.new(0.5, 3.2, 0.5), cf * CFrame.new(0, 4.4, -0.8) * CFrame.Angles(math.rad(-35), 0, 0),
		{ Material = Enum.Material.Metal, Color = Color3.fromHex("#A88A4F") })
	part(model, "Rune", Vector3.new(0.9, 0.9, 0.1), cf * CFrame.new(0, 3.2, -0.66), { Material = Enum.Material.Neon,
		Color = Color3.fromHex("#C0503A"), CanCollide = false })
	model.PrimaryPart = post
	model.Parent = parent
	CollectionService:AddTag(model, "DungeonLever")
end

function DungeonBuilder.SunkenCistern(): Model
	local root = ServerStorage:FindFirstChild("Dungeons")
	if not root then
		local f = Instance.new("Folder")
		f.Name = "Dungeons"
		f.Parent = ServerStorage
		root = f
	end
	assert(root, "Dungeons folder")
	local old = root:FindFirstChild("SunkenCistern")
	if old then
		old:Destroy()
	end
	local model = Instance.new("Model")
	model.Name = "SunkenCistern"
	model:SetAttribute("DungeonId", "SunkenCistern")
	local geo = Instance.new("Folder")
	geo.Name = "Geometry"
	geo.Parent = model
	local spawns = Instance.new("Folder")
	spawns.Name = "Spawns"
	spawns.Parent = model

	-- ENTRY VAULT (x +-16, z 0..32)
	floorTiles(geo, -16, 16, 0, 32, 0)
	wallRun(geo, Vector3.new(-16, 0, 0), Vector3.new(-16, 0, 32), Vector3.xAxis)
	wallRun(geo, Vector3.new(16, 0, 0), Vector3.new(16, 0, 32), -Vector3.xAxis)
	wallRun(geo, Vector3.new(-16, 0, -0.5), Vector3.new(16, 0, -0.5), Vector3.zAxis)
	wallRun(geo, Vector3.new(-16, 0, 32), Vector3.new(-8, 0, 32), -Vector3.zAxis)
	wallRun(geo, Vector3.new(8, 0, 32), Vector3.new(16, 0, 32), -Vector3.zAxis)
	part(geo, "Ceiling", Vector3.new(34, 2, 34), CFrame.new(0, 17, 16))
	put(geo, "Cistern_Arch", CFrame.new(0, 0, 1.5) * CFrame.Angles(0, math.pi, 0))
	portal(model, CFrame.new(0, 0, 1.2))
	for _, x in { -12, 12 } do
		put(geo, "Cistern_Brazier", CFrame.new(x, 0, 8))
	end
	local arrival = part(model, "Arrival", Vector3.new(4, 1, 4), CFrame.new(0, 0.5, 10), {
		Transparency = 1,
		CanCollide = false,
		CanQuery = false,
		CanTouch = false,
	})
	arrival:SetAttribute("Facing", "+Z")

	-- GALLERY (x +-8, z 32..96)
	floorTiles(geo, -8, 8, 32, 96, 0)
	wallRun(geo, Vector3.new(-8, 0, 32), Vector3.new(-8, 0, 96), Vector3.xAxis)
	wallRun(geo, Vector3.new(8, 0, 32), Vector3.new(8, 0, 96), -Vector3.xAxis)
	for k = 0, 3 do
		put(geo, "Cistern_Vault_16", CFrame.new(0, 16, 40 + 16 * k))
	end
	for k = 0, 1 do
		put(geo, "Cistern_Pipe", CFrame.new(-6.6, 12, 48 + 32 * k) * CFrame.Angles(0, HALF_PI, 0))
	end
	put(geo, "Cistern_Brazier", CFrame.new(5.5, 0, 64))
	spawnPoint(spawns, "CisternLeech", Vector3.new(0, 0, 70), 2, 10)

	-- FLOODED HALL (x +-32, z 96..160), walls 20 tall
	floorTiles(geo, -32, 32, 96, 160, 0)
	wallRun(geo, Vector3.new(-32, 0, 96), Vector3.new(-32, 0, 160), Vector3.xAxis, 1.25)
	wallRun(geo, Vector3.new(32, 0, 96), Vector3.new(32, 0, 160), -Vector3.xAxis, 1.25)
	wallRun(geo, Vector3.new(-32, 0, 96), Vector3.new(-8, 0, 96), Vector3.zAxis, 1.25)
	wallRun(geo, Vector3.new(8, 0, 96), Vector3.new(32, 0, 96), Vector3.zAxis, 1.25)
	wallRun(geo, Vector3.new(-32, 0, 160), Vector3.new(-8, 0, 160), -Vector3.zAxis, 1.25)
	wallRun(geo, Vector3.new(8, 0, 160), Vector3.new(32, 0, 160), -Vector3.zAxis, 1.25)
	part(geo, "Ceiling", Vector3.new(66, 2, 66), CFrame.new(0, 21, 128))
	for _, x in { -24, -8, 8, 24 } do
		for _, z in { 104, 120, 136, 152 } do
			put(geo, "Cistern_Pillar", CFrame.new(x, 0, z))
		end
	end
	part(geo, "Floodwater", Vector3.new(64, 0.3, 64), CFrame.new(0, 0.55, 128), {
		Material = Enum.Material.Glass,
		Color = Color3.fromHex("#1F6E78"),
		Transparency = 0.35,
		CanCollide = false,
		CanQuery = false,
		CastShadow = false,
	})
	for _, s in { -1, 1 } do
		put(geo, "Cistern_Pipe", CFrame.new(s * 30.4, 15, 112) * CFrame.Angles(0, HALF_PI, 0))
		put(geo, "Cistern_Pipe", CFrame.new(s * 30.4, 15, 144) * CFrame.Angles(0, HALF_PI, 0))
		put(geo, "Cistern_Brazier", CFrame.new(s * 16, 0, 100))
		lever(model, "DungeonLever", CFrame.new(s * 28, 0, 156) * CFrame.Angles(0, math.pi, 0))
	end
	spawnPoint(spawns, "CisternLeech", Vector3.new(-20, 0, 112), 2, 10)
	spawnPoint(spawns, "CisternLeech", Vector3.new(20, 0, 130), 2, 10)
	spawnPoint(spawns, "CisternLeech", Vector3.new(-16, 0, 150), 2, 8)
	spawnPoint(spawns, "LanternAcolyte", Vector3.new(16, 0, 150), 1, 6)

	-- SLUICE GATE at z = 160
	put(geo, "Cistern_Sluice", CFrame.new(0, 0, 160), { Scale = Vector3.new(1.3, 1.3, 1) })
	local gate = part(model, "SluiceGate", Vector3.new(16, 16, 1), CFrame.new(0, 8, 160), {
		Material = Enum.Material.Metal,
		Color = Color3.fromHex("#3D4045"),
	})
	gate:SetAttribute("OpenOffset", 15) -- studs it rises when opened

	-- ALTAR CHAMBER (x +-16, z 160..208)
	floorTiles(geo, -16, 16, 160, 208, 0)
	wallRun(geo, Vector3.new(-16, 0, 160), Vector3.new(-16, 0, 208), Vector3.xAxis, 1.25)
	wallRun(geo, Vector3.new(16, 0, 160), Vector3.new(16, 0, 208), -Vector3.xAxis, 1.25)
	wallRun(geo, Vector3.new(-16, 0, 208), Vector3.new(16, 0, 208), -Vector3.zAxis, 1.25)
	wallRun(geo, Vector3.new(-16, 0, 160), Vector3.new(-8, 0, 160), -Vector3.zAxis, 1.25)
	wallRun(geo, Vector3.new(8, 0, 160), Vector3.new(16, 0, 160), -Vector3.zAxis, 1.25)
	part(geo, "Ceiling", Vector3.new(34, 2, 50), CFrame.new(0, 21, 184))
	put(geo, "Cistern_Altar", CFrame.new(0, 0, 196) * CFrame.Angles(0, math.pi, 0), { Flatten = false, Name = "Altar" })
	for _, x in { -10, 10 } do
		put(geo, "Cistern_Brazier", CFrame.new(x, 0, 190))
		put(geo, "Current_Crystal_M", CFrame.new(x * 1.2, 0, 204))
	end
	spawnPoint(spawns, "LanternAcolyte", Vector3.new(0, 0, 186), 1, 4, true)
	spawnPoint(spawns, "CisternLeech", Vector3.new(0, 0, 176), 2, 8)
	local _, chest = Kit.Place("Chest", CFrame.new(0, 0, 202) * CFrame.Angles(0, math.pi, 0), model, { Name = "DungeonChest" })
	if chest then
		chest:SetAttribute("Locked", true) -- DungeonService unlocks it when the chamber is cleared
	end
	portal(model, CFrame.new(0, 0, 206.8))

	model.PrimaryPart = arrival
	model.WorldPivot = CFrame.new()
	model.ModelStreamingMode = Enum.ModelStreamingMode.Default
	model.Parent = root
	return model
end

return DungeonBuilder
