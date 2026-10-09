--!strict
-- KitLibrary (edit time): turns kit piece ids into Instances.
--
-- After importing assets/kit/fbx/*.fbx with Studio's 3D Importer into
-- ReplicatedStorage/Assets/Kit, run KitLibrary.fixupImported() once: it
-- renames, sizes and configures every MeshPart from the KitManifest.
-- Pieces whose mesh has not been imported yet fall back to a blockout built
-- from the manifest's bounding box / collider boxes, so a floor can be built
-- and walked before the art pass lands.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Types = require(Shared.Types)
local Config = require(Shared.Config)
local KitManifest = require(Shared.Data.KitManifest)

type KitPiece = Types.KitPiece

local Palette = Config.Palette

local KitLibrary = {}

local templates: { [string]: MeshPart? } = {}
local scanned = false

local function kitFolder(): Instance?
	local node: Instance? = ReplicatedStorage
	for _, name in Config.World.Kit.TemplateFolderPath do
		if not node then
			return nil
		end
		node = (node :: Instance):FindFirstChild(name)
	end
	return node
end

local function scan()
	scanned = true
	table.clear(templates)
	local folder = kitFolder()
	if not folder then
		return
	end
	for _, d in folder:GetDescendants() do
		if d:IsA("MeshPart") and KitManifest[d.Name] then
			templates[d.Name] = d
		end
	end
end

function KitLibrary.refresh()
	scan()
end

function KitLibrary.hasMesh(id: string): boolean
	if not scanned then
		scan()
	end
	return templates[id] ~= nil
end

function KitLibrary.material(name: string): Enum.Material
	local ok, m = pcall(function(): Enum.Material
		return (Enum.Material :: any)[name]
	end)
	if ok and m then
		return m
	end
	return Enum.Material.SmoothPlastic
end

function KitLibrary.color(key: string): Color3
	return Palette[key] or Color3.fromRGB(128, 128, 128)
end

local function collisionFidelity(m: KitPiece): Enum.CollisionFidelity
	if m.collision == "Hull" then
		return Enum.CollisionFidelity.Hull
	end
	return Enum.CollisionFidelity.Box
end

-- Normalise meshes imported from the FBX kit (names may carry importer suffixes).
function KitLibrary.fixupImported(): (number, { string })
	local folder = kitFolder()
	assert(folder, "ReplicatedStorage/Assets/Kit is missing")
	local fixed = 0
	local warnings: { string } = {}
	for _, d in folder:GetDescendants() do
		if d:IsA("MeshPart") then
			local id = d.Name
			if not KitManifest[id] then
				local stripped = string.gsub(id, "[%._]?%d+$", "")
				if KitManifest[stripped] then
					id = stripped
				elseif d.Parent and KitManifest[d.Parent.Name] then
					id = d.Parent.Name
				end
			end
			local m = KitManifest[id]
			if m then
				d.Name = id
				d.Parent = folder
				local want = Vector3.new(m.size[1], m.size[2], m.size[3])
				local have = d.Size
				-- detect axis swaps from the importer by comparing proportions
				local function ratio(v: Vector3): (number, number)
					return v.X / math.max(v.Y, 1e-3), v.Z / math.max(v.Y, 1e-3)
				end
				local rx1, rz1 = ratio(want)
				local rx2, rz2 = ratio(have)
				if math.abs(rx1 - rx2) / math.max(rx1, 1e-3) > 0.2 or math.abs(rz1 - rz2) / math.max(rz1, 1e-3) > 0.2 then
					table.insert(warnings, string.format("%s: imported proportions %s differ from manifest %s (check importer axis settings)", id, tostring(have), tostring(want)))
				end
				d.Size = want
				d.Anchored = true
				d.CanTouch = false
				d.CollisionFidelity = collisionFidelity(m)
				d.RenderFidelity = Enum.RenderFidelity.Automatic
				d.Material = KitLibrary.material(m.material)
				d.Color = KitLibrary.color(m.color)
				d.CastShadow = m.category ~= "trim" or m.material ~= "Glass"
				d.DoubleSided = false
				fixed += 1
			end
		end
	end
	for _, d in folder:GetChildren() do
		if d:IsA("Model") and #d:GetChildren() == 0 then
			d:Destroy()
		end
	end
	scan()
	return fixed, warnings
end

export type Built = {
	visual: BasePart?, -- the MeshPart (nil in blockout mode for collider-only pieces)
	colliders: { BasePart },
}

-- Create the instances for one placement. `cf` is the piece origin; `scale`
-- is the per-axis scale (uniform scale multiplied into each component).
function KitLibrary.create(id: string, cf: CFrame, scale: Vector3, material: string?, color: string?, noCollide: boolean): Built
	local m = KitManifest[id]
	assert(m, "unknown kit piece " .. id)
	if not scanned then
		scan()
	end
	local mat = KitLibrary.material(material or m.material)
	local col = KitLibrary.color(color or m.color)
	local size = Vector3.new(m.size[1] * scale.X, m.size[2] * scale.Y, m.size[3] * scale.Z)
	local centre = cf * CFrame.new(m.center[1] * scale.X, m.center[2] * scale.Y, m.center[3] * scale.Z)
	local built: Built = { visual = nil, colliders = {} }
	local template = templates[id]
	local useColliders = m.collision == "Colliders" and not noCollide

	if template then
		local p = template:Clone()
		p.Size = size
		p.CFrame = centre
		p.Material = mat
		p.Color = col
		p.Anchored = true
		p.CanTouch = false
		p.CanCollide = (m.collision == "Box" or m.collision == "Hull") and not noCollide
		p.CanQuery = p.CanCollide or useColliders
		if m.material == "Glass" then
			p.Transparency = 0.3
			p.CastShadow = false
		end
		built.visual = p
	elseif not useColliders then
		-- blockout: the piece's bounding box
		local p = Instance.new("Part")
		p.Name = id
		p.Size = Vector3.new(math.max(size.X, 0.05), math.max(size.Y, 0.05), math.max(size.Z, 0.05))
		p.CFrame = centre
		p.Material = mat
		p.Color = col
		p.Anchored = true
		p.CanTouch = false
		p.CanCollide = (m.collision == "Box" or m.collision == "Hull") and not noCollide
		p.CanQuery = p.CanCollide
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		if m.material == "Glass" then
			p.Transparency = 0.3
		end
		built.visual = p
	end

	if useColliders then
		for _, c in m.colliders do
			local part: BasePart = if c.shape == "Wedge" then Instance.new("WedgePart") else Instance.new("Part")
			part.Name = id .. "_Collider"
			part.Size = Vector3.new(c.s[1] * scale.X, c.s[2] * scale.Y, c.s[3] * scale.Z)
			part.CFrame = cf * CFrame.new(c.c[1] * scale.X, c.c[2] * scale.Y, c.c[3] * scale.Z) * CFrame.Angles(0, math.rad(c.ry), 0)
			part.Anchored = true
			part.CanTouch = false
			part.CastShadow = template == nil
			part.TopSurface = Enum.SurfaceType.Smooth
			part.BottomSurface = Enum.SurfaceType.Smooth
			if template then
				part.Transparency = 1
				part.Material = Enum.Material.SmoothPlastic
			else
				-- blockout mode: the colliders are the visible shape
				part.Material = mat
				part.Color = col
			end
			table.insert(built.colliders, part)
		end
	end
	return built
end

return KitLibrary
