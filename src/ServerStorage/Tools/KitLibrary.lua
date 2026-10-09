--!strict
--[[
	KitLibrary (edit-time tool; never runs during play)
	Turns the imported Blender kit (SpireKit_Architecture / _World / _Nature) into clean, reusable
	templates and places them.

	How the import is understood
	  Each FBX carries four calibration cubes (Calib_<File>__O/X/Y/Z) at Blender (0,0,0) and 32 studs along
	  +X, +Y and +Z. Wherever the 3D Importer put them tells us its exact scale and axis mapping, so the
	  kit works with any importer unit or axis setting. Pieces are found by their MeshPart names
	  (<Piece>__<Channel>) and the manifest (KitManifest) says where each piece's origin was.

	Template space (every piece)
	  +Y up, the piece's FRONT (outside face of a wall, the usable side of a prop) faces +Z,
	  1 unit = 1 stud, origin = the piece's origin from Blender (usually its bottom centre).
	  Blender (x, y, z) maps to template (x, z, -y).

	What a template contains
	  * One MeshPart per material channel, with the channel's Roblox Material and Color
	    (Channels below; a piece may tint channels via Meta.tint). Visual MeshParts never collide
	    (CanCollide/CanQuery/CanTouch off, Box fidelity) so physics stays cheap.
	  * Invisible "Collision" Parts from the manifest boxes (Anchored, CanCollide, CanQuery so the camera
	    and raycasts hit them, CanTouch off).
	  * Night lighting: Light channel parts get a warm PointLight and the tag SpireNightLight; Window
	    parts get the tag SpireWindow (EnvironmentController lights them after dusk).

	Usage (Command Bar, Edit mode):
	    local Kit = require(game.ServerStorage.Tools.KitLibrary)
	    Kit.Prepare()                                       -- builds ServerStorage.SpireKit.Templates
	    Kit.Place("Wall_Stone_Window_12", CFrame.new(0, 2, 0), workspace)
]]

local CollectionService = game:GetService("CollectionService")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local Manifest = require(script.Parent.KitManifest)

export type PieceInfo = typeof(Manifest.Pieces.Crate)

export type PlaceOptions = {
	Scale: Vector3?, -- per-axis scale in template space (non-uniform allowed for axis-aligned pieces)
	Tint: { [string]: Color3 }?, -- channel -> colour override for this placement
	Collision: boolean?, -- false = skip collision boxes (decor that sits inside other collision)
	Flatten: boolean?, -- true = parts go straight into `parent` (no per-piece Model)
	Name: string?,
	Lit: boolean?, -- windows of this placement light up at night (default true)
	Shadows: boolean?, -- false = no shadows from this placement (small clutter)
}

type Channel = {
	Material: Enum.Material,
	Color: Color3,
	Transparency: number?,
	Reflectance: number?,
	Shadow: boolean?,
}

local KitLibrary = {}

KitLibrary.Version = 1
KitLibrary.Tags = {
	NightLight = "SpireNightLight",
	Window = "SpireWindow",
	KitPart = "SpireKitPart",
}

-- Roblox look of each material channel (Spec Section 4 palette).
KitLibrary.Channels = {
	Stone = { Material = Enum.Material.Limestone, Color = Color3.fromHex("#6E6A63") },
	StoneDark = { Material = Enum.Material.Slate, Color = Color3.fromHex("#2B2A28") },
	Brick = { Material = Enum.Material.Brick, Color = Color3.fromHex("#6B4436") },
	Plaster = { Material = Enum.Material.Plaster, Color = Color3.fromHex("#B5A88E") },
	Wood = { Material = Enum.Material.WoodPlanks, Color = Color3.fromHex("#6B4C35") },
	WoodDark = { Material = Enum.Material.Wood, Color = Color3.fromHex("#4A3426") },
	Roof = { Material = Enum.Material.Slate, Color = Color3.fromHex("#3B424E") },
	Metal = { Material = Enum.Material.Metal, Color = Color3.fromHex("#3D4045") },
	Brass = { Material = Enum.Material.Metal, Color = Color3.fromHex("#A88A4F") },
	Cloth = { Material = Enum.Material.Fabric, Color = Color3.fromHex("#6E2620") },
	ClothAlt = { Material = Enum.Material.Fabric, Color = Color3.fromHex("#1F5B5E") },
	Moss = { Material = Enum.Material.Grass, Color = Color3.fromHex("#4D6134") },
	Leaf = { Material = Enum.Material.LeafyGrass, Color = Color3.fromHex("#4A6B38") },
	Bark = { Material = Enum.Material.Wood, Color = Color3.fromHex("#4D3A2C") },
	Rock = { Material = Enum.Material.Rock, Color = Color3.fromHex("#6A6862") },
	Sand = { Material = Enum.Material.Sand, Color = Color3.fromHex("#A99572") },
	Coral = { Material = Enum.Material.Pebble, Color = Color3.fromHex("#C46A5E") },
	Bone = { Material = Enum.Material.Marble, Color = Color3.fromHex("#C9BFA8") },
	Window = { Material = Enum.Material.Glass, Color = Color3.fromHex("#141A22"), Transparency = 0.1, Reflectance = 0.15, Shadow = false },
	Glass = { Material = Enum.Material.Glass, Color = Color3.fromHex("#6E8A93"), Transparency = 0.45, Shadow = false },
	Glow = { Material = Enum.Material.Neon, Color = Color3.fromHex("#3FE0D0"), Shadow = false },
	Light = { Material = Enum.Material.Neon, Color = Color3.fromHex("#FFB45A"), Shadow = false },
	Water = { Material = Enum.Material.Glass, Color = Color3.fromHex("#1F6E78"), Transparency = 0.3, Shadow = false },
	Crystal = { Material = Enum.Material.Glass, Color = Color3.fromHex("#8FF5EC"), Transparency = 0.1, Shadow = false },
	Rope = { Material = Enum.Material.Fabric, Color = Color3.fromHex("#8C7853") },
	Paper = { Material = Enum.Material.SmoothPlastic, Color = Color3.fromHex("#DCD3B8") },
} :: { [string]: Channel }

KitLibrary.WarmLight = Color3.fromHex("#FFB45A")
KitLibrary.CurrentLight = Color3.fromHex("#3FE0D0")

type Calib = {
	Origin: Vector3,
	Basis: CFrame, -- maps template-oriented local axes (x, z, -y in Blender terms) to world, at Origin
	Scale: number, -- studs in the import per Blender unit
}

-- HELPERS -----------------------------------------------------------------------

local function folder(parent: Instance, name: string): Folder
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA("Folder") then
		return existing
	end
	local f = Instance.new("Folder")
	f.Name = name
	f.Parent = parent
	return f
end

local function root(): Folder
	return folder(ServerStorage, "SpireKit")
end

-- Blender piece space -> template space.
local function toLocal(x: number, y: number, z: number): Vector3
	return Vector3.new(x, z, -y)
end

local function vec(list: { any }): Vector3
	return toLocal(list[1] :: number, list[2] :: number, list[3] :: number)
end

-- Finds the imported MeshPart named `name` under Workspace or ServerStorage.
local function findPart(name: string): MeshPart?
	for _, container in { Workspace :: Instance, ServerStorage :: Instance } do
		local found = container:FindFirstChild(name, true)
		if found and found:IsA("MeshPart") then
			return found
		end
	end
	return nil
end

-- The top-level imported model that holds this calibration part.
local function sourceModelOf(part: Instance): Instance
	local node: Instance = part
	while node.Parent and node.Parent ~= Workspace and node.Parent ~= ServerStorage and node.Parent ~= root()
		and node.Parent.Name ~= "Source" do
		node = node.Parent
	end
	return node
end

local function solveCalibration(file: string): (Calib?, string?)
	local o = findPart(`Calib_{file}__O`)
	local x = findPart(`Calib_{file}__X`)
	local y = findPart(`Calib_{file}__Y`)
	local z = findPart(`Calib_{file}__Z`)
	if not (o and x and y and z) then
		return nil, `SpireKit_{file} not found (import SpireKit_{file}.fbx with the 3D Importer)`
	end
	local c = Manifest.Calib
	local vx = (x.Position - o.Position) / c
	local vy = (y.Position - o.Position) / c
	local vz = (z.Position - o.Position) / c
	local scale = vx.Magnitude
	if scale < 1e-4 then
		return nil, `{file}: calibration cubes overlap; the import looks broken`
	end
	local ux, uy, uz = vx.Unit, vy.Unit, vz.Unit
	if math.abs(vy.Magnitude - scale) > scale * 0.02 or math.abs(vz.Magnitude - scale) > scale * 0.02 then
		return nil, `{file}: the importer scaled the axes differently ({vx.Magnitude}, {vy.Magnitude}, {vz.Magnitude})`
	end
	if math.abs(ux:Dot(uy)) > 0.02 or math.abs(ux:Dot(uz)) > 0.02 or math.abs(uy:Dot(uz)) > 0.02 then
		return nil, `{file}: the imported axes are not perpendicular`
	end
	if ux:Cross(uy):Dot(uz) < 0 then
		return nil, `{file}: the import is mirrored; re-import without flipping any axis`
	end
	-- template axes: X = Blender x, Y = Blender z (up), Z = -Blender y (front)
	local basis = CFrame.fromMatrix(o.Position, ux, uz, -uy)
	return { Origin = o.Position, Basis = basis, Scale = scale }, nil
end

local function applyChannel(part: BasePart, channel: string, tint: Color3?)
	local spec = KitLibrary.Channels[channel] or KitLibrary.Channels.Stone
	part.Material = spec.Material
	part.Color = tint or spec.Color
	part.Transparency = spec.Transparency or 0
	part.Reflectance = spec.Reflectance or 0
	part.CastShadow = spec.Shadow ~= false
end

local function makeCollision(model: Model, entry: { any })
	local centre = vec(entry[1] :: { any })
	local raw = entry[2] :: { any }
	local size = Vector3.new(raw[1] :: number, raw[3] :: number, raw[2] :: number)
	local yaw = math.rad(entry[3] :: number)
	local pitch = math.rad(entry[4] :: number)
	local box = Instance.new("Part")
	box.Name = "Collision"
	box.Anchored = true
	box.CanCollide = true
	box.CanQuery = true
	box.CanTouch = false
	box.CastShadow = false
	box.Transparency = 1
	box.Size = Vector3.new(math.max(size.X, 0.05), math.max(size.Y, 0.05), math.max(size.Z, 0.05))
	box.CFrame = CFrame.new(centre) * CFrame.Angles(0, yaw, 0) * CFrame.Angles(pitch, 0, 0)
	box.Parent = model
end

local function addLights(model: Model, info: PieceInfo)
	local anchors = info.Anchors :: { [string]: { number } }
	local lightPart: BasePart? = nil
	local color = KitLibrary.WarmLight
	for _, child in model:GetChildren() do
		if child:IsA("BasePart") and child:GetAttribute("Channel") == "Light" then
			lightPart = child
		end
	end
	if not lightPart and anchors.Light then
		for _, child in model:GetChildren() do
			if child:IsA("BasePart") and child:GetAttribute("Channel") == "Glow" then
				lightPart = child
				color = KitLibrary.CurrentLight
			end
		end
	end
	if lightPart then
		local light = Instance.new("PointLight")
		light.Color = color
		light.Range = if info.Category == "Landmark" then 40 else 16
		light.Brightness = if color == KitLibrary.WarmLight then 1.3 else 0.9
		light.Shadows = false
		light.Parent = lightPart
		CollectionService:AddTag(lightPart, KitLibrary.Tags.NightLight)
	end
end

-- BUILD TEMPLATES -----------------------------------------------------------------

local function buildTemplate(name: string, info: PieceInfo, calib: Calib, source: Instance): (Model?, string?)
	local parts: { MeshPart } = {}
	for _, d in source:GetDescendants() do
		if d:IsA("MeshPart") then
			local piece, channel = string.match(d.Name, "^(.-)__(%w+)$")
			if piece == name and channel then
				d:SetAttribute("Channel", channel)
				table.insert(parts, d)
			end
		end
	end
	if #parts == 0 then
		return nil, `{name}: no MeshParts found in SpireKit_{info.File}`
	end
	local model = Instance.new("Model")
	model.Name = name
	local pos = info.Position :: { number }
	local originLocal = toLocal(pos[1], pos[2], pos[3])
	local tints = (info.Meta :: { [string]: any }).tint :: { [string]: { number } }?
	local s = calib.Scale
	for _, mp in parts do
		local clone = mp:Clone()
		local channel = mp:GetAttribute("Channel") :: string
		local localPos = calib.Basis:PointToObjectSpace(mp.Position) / s
		local localRot = calib.Basis.Rotation:ToObjectSpace(mp.CFrame.Rotation)
		clone.Size = mp.Size / s
		clone.CFrame = CFrame.new(localPos - originLocal) * localRot
		clone.Name = channel
		clone.Anchored = true
		clone.CanCollide = false
		clone.CanQuery = false
		clone.CanTouch = false
		clone.Massless = true
		pcall(function()
			clone.CollisionFidelity = Enum.CollisionFidelity.Box
		end)
		local tint: Color3? = nil
		if tints and tints[channel] then
			local t = tints[channel]
			tint = Color3.fromRGB(t[1], t[2], t[3])
		end
		applyChannel(clone, channel, tint)
		for _, tag in CollectionService:GetTags(clone) do
			CollectionService:RemoveTag(clone, tag)
		end
		CollectionService:AddTag(clone, KitLibrary.Tags.KitPart)
		if channel == "Window" then
			CollectionService:AddTag(clone, KitLibrary.Tags.Window)
		end
		clone.Parent = model
	end
	for _, entry in info.Collision :: { { any } } do
		makeCollision(model, entry)
	end
	addLights(model, info)
	model.WorldPivot = CFrame.identity
	model:SetAttribute("Category", info.Category)
	return model, nil
end

-- Builds every template (ServerStorage.SpireKit.Templates) from the imported kit. Safe to re-run.
function KitLibrary.Prepare(): { built: number, problems: { string } }
	local problems: { string } = {}
	local kitRoot = root()
	local sources = folder(kitRoot, "Source")
	local templates = folder(kitRoot, "Templates")
	local calibs: { [string]: Calib } = {}
	local sourceOf: { [string]: Instance } = {}
	for file in Manifest.Files do
		local calib, err = solveCalibration(file)
		if calib then
			calibs[file] = calib
			local marker = findPart(`Calib_{file}__O`) :: MeshPart
			local src = sourceModelOf(marker)
			-- a re-import lands in Workspace (searched first); retire the previous copy so the kit
			-- never holds two sources for one file
			local previous = sources:FindFirstChild(`SpireKit_{file}`)
			if previous and previous ~= src then
				previous:Destroy()
			end
			src.Name = `SpireKit_{file}`
			src.Parent = sources -- out of Workspace: the raw import never renders or collides in play
			sourceOf[file] = src
			if math.abs(calib.Scale - 1) > 0.01 then
				table.insert(problems, `{file}: importer scale {string.format("%.4f", calib.Scale)} corrected`)
			end
		else
			table.insert(problems, err :: string)
		end
	end
	local built = 0
	for name, info in Manifest.Pieces do
		local calib = calibs[info.File]
		if calib then
			local existing = templates:FindFirstChild(name)
			if existing then
				existing:Destroy()
			end
			local model, err = buildTemplate(name, info, calib, sourceOf[info.File])
			if model then
				model.Parent = templates
				built += 1
			else
				table.insert(problems, err :: string)
			end
		end
	end
	kitRoot:SetAttribute("KitVersion", KitLibrary.Version)
	return { built = built, problems = problems }
end

function KitLibrary.Info(name: string): PieceInfo?
	return Manifest.Pieces[name]
end

function KitLibrary.Has(name: string): boolean
	local templates = root():FindFirstChild("Templates")
	return templates ~= nil and templates:FindFirstChild(name) ~= nil
end

-- Size of a piece in template space (x, y up, z front).
function KitLibrary.Size(name: string): Vector3
	local info = Manifest.Pieces[name]
	if not info then
		return Vector3.zero
	end
	local s = info.Size :: { number }
	return Vector3.new(s[1], s[3], s[2])
end

-- Bounds (min, max) in template space.
function KitLibrary.Bounds(name: string): (Vector3, Vector3)
	local info = Manifest.Pieces[name]
	if not info then
		return Vector3.zero, Vector3.zero
	end
	local b = info.Bounds :: { { number } }
	local a = vec(b[1])
	local c = vec(b[2])
	return a:Min(c), a:Max(c)
end

-- A named anchor in template space: position and yaw (radians).
function KitLibrary.Anchor(name: string, anchor: string): (Vector3?, number)
	local info = Manifest.Pieces[name]
	local list = info and (info.Anchors :: { [string]: { number } })[anchor]
	if not list then
		return nil, 0
	end
	return toLocal(list[1], list[2], list[3]), math.rad(list[4] or 0)
end

function KitLibrary.Meta(name: string): { [string]: any }
	local info = Manifest.Pieces[name]
	return if info then info.Meta :: { [string]: any } else {}
end

local function axisScale(direction: Vector3, scale: Vector3): number
	return math.abs(direction.X) * scale.X + math.abs(direction.Y) * scale.Y + math.abs(direction.Z) * scale.Z
end

-- Places a piece. Returns the created parts (and the Model unless Flatten).
function KitLibrary.Place(name: string, at: CFrame, parent: Instance, options: PlaceOptions?): ({ BasePart }, Model?)
	local templates = root():FindFirstChild("Templates")
	local template = templates and templates:FindFirstChild(name)
	if not template or not template:IsA("Model") then
		warn(`[KitLibrary] missing template {name} (run KitLibrary.Prepare() after importing the kit)`)
		return {}, nil
	end
	local opts: PlaceOptions = options or {}
	local scale = opts.Scale or Vector3.one
	local uniform = math.abs(scale.X - scale.Y) < 1e-4 and math.abs(scale.Y - scale.Z) < 1e-4
	local lit = opts.Lit ~= false
	local placed: { BasePart } = {}
	local holder: Instance = parent
	local model: Model? = nil
	if not opts.Flatten then
		local m = Instance.new("Model")
		m.Name = opts.Name or name
		m.WorldPivot = at
		m.Parent = parent
		holder = m
		model = m
	end
	for _, child in template:GetChildren() do
		if not child:IsA("BasePart") then
			continue
		end
		if child.Name == "Collision" and opts.Collision == false then
			continue
		end
		local part = child:Clone()
		local rel = child.CFrame
		local rot = rel.Rotation
		if uniform then
			part.Size = child.Size * scale.X
		else
			part.Size = Vector3.new(
				child.Size.X * axisScale(rot.XVector, scale),
				child.Size.Y * axisScale(rot.YVector, scale),
				child.Size.Z * axisScale(rot.ZVector, scale)
			)
		end
		part.CFrame = at * CFrame.new(rel.Position * scale) * rot
		if opts.Tint then
			local channel = part:GetAttribute("Channel")
			local tint = if type(channel) == "string" then opts.Tint[channel] else nil
			if tint then
				part.Color = tint
			end
		end
		if opts.Shadows == false then
			part.CastShadow = false
		end
		if not lit and CollectionService:HasTag(part, KitLibrary.Tags.Window) then
			part:SetAttribute("Unlit", true)
		end
		if uniform and math.abs(scale.X - 1) > 1e-3 then
			for _, light in part:GetChildren() do
				if light:IsA("PointLight") then
					light.Range *= scale.X
				end
			end
		end
		part.Parent = holder
		table.insert(placed, part)
	end
	return placed, model
end

-- Every piece name in a category (e.g. "Wall", "Tree"), sorted.
function KitLibrary.Category(category: string): { string }
	local out = {}
	for name, info in Manifest.Pieces do
		if info.Category == category then
			table.insert(out, name)
		end
	end
	table.sort(out)
	return out
end

return KitLibrary
