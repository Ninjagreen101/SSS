--!strict
-- PlanApplier (edit time): turns a PlanNode tree into static Instances.
-- Every node becomes a Model (ModelStreamingMode from the plan: Atomic for
-- buildings, Persistent for waystones and quest-critical objects), kit pieces
-- become MeshParts (or blockouts), solids become Parts, lights become
-- PointLights (parented straight to their lantern part where possible),
-- emitters become ParticleEmitters and markers become invisible tagged parts
-- that runtime systems discover through CollectionService.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Types = require(Shared.Types)
local Config = require(Shared.Config)
local WorldFX = require(Shared.Util.WorldFX)
local AssetManifest = require(Shared.Data.AssetManifest)
local Strings = require(Shared.Strings)

local KitLibrary = require(script.Parent.KitLibrary)
local Plan = require(script.Parent.Plan.Plan)

type PlanNode = Types.PlanNode
type Frame = Plan.Frame

local Palette = Config.Palette

export type ApplyStats = {
	models: number,
	parts: number,
	lights: number,
	emitters: number,
	markers: number,
	blockouts: number,
}

export type ApplyOptions = {
	yieldEvery: number?,
	onProgress: ((done: number) -> ())?,
}

local PlanApplier = {}

-- Painted lettering (a Strings key) on a sign's front face, and optionally its back.
local function addSignText(part: BasePart, key: string, bothSides: boolean)
	local faces: { Enum.NormalId } = if bothSides then { Enum.NormalId.Front, Enum.NormalId.Back } else { Enum.NormalId.Front }
	for _, face in faces do
		local gui = Instance.new("SurfaceGui")
		gui.Face = face
		gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		gui.PixelsPerStud = 40
		gui.LightInfluence = 1
		gui.MaxDistance = 140
		gui.Parent = part
		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.Size = UDim2.fromScale(1, 1)
		label.Text = Strings.get(key)
		label.TextScaled = true
		label.FontFace = Font.new("rbxasset://fonts/families/Merriweather.json", Enum.FontWeight.Bold, Enum.FontStyle.Normal)
		label.TextColor3 = Palette.Gold
		label.TextStrokeTransparency = 0.6
		label.TextStrokeColor3 = Palette.StoneShadow
		local pad = Instance.new("UIPadding")
		pad.PaddingLeft = UDim.new(0.06, 0)
		pad.PaddingRight = UDim.new(0.06, 0)
		pad.PaddingTop = UDim.new(0.14, 0)
		pad.PaddingBottom = UDim.new(0.14, 0)
		pad.Parent = label
		label.Parent = gui
	end
end

local function frameCFrame(f: Frame): CFrame
	return CFrame.new(f.x, f.y, f.z) * CFrame.Angles(0, f.ry, 0)
end

local function placementCFrame(origin: CFrame, x: number, y: number, z: number, ry: number, rx: number?, rz: number?): CFrame
	local cf = origin * CFrame.new(x, y, z) * CFrame.Angles(0, ry, 0)
	if (rx and rx ~= 0) or (rz and rz ~= 0) then
		cf *= CFrame.Angles(rx or 0, 0, rz or 0)
	end
	return cf
end

local function setAttributes(inst: Instance, attrs: { [string]: any }?)
	if not attrs then
		return
	end
	for k, v in attrs do
		inst:SetAttribute(k, v)
	end
end

local function enumItem(enum: Enum, name: string): EnumItem?
	local ok, item = pcall(function(): EnumItem
		return (enum :: any)[name]
	end)
	if ok then
		return item
	end
	return nil
end

function PlanApplier.apply(root: PlanNode, parent: Instance, opts: ApplyOptions?): (Model, ApplyStats)
	local o: ApplyOptions = opts or {}
	local yieldEvery = o.yieldEvery or 600
	local stats: ApplyStats = { models = 0, parts = 0, lights = 0, emitters = 0, markers = 0, blockouts = 0 }
	local created = 0
	local function tick()
		created += 1
		if created % yieldEvery == 0 then
			if o.onProgress then
				(o.onProgress :: (number) -> ())(created)
			end
			task.wait()
		end
	end

	local function build(node: PlanNode, parentInst: Instance, parentFrame: Frame): Model
		local world = Plan.compose(parentFrame, Plan.frame(node.x, node.y, node.z, node.ry, 1))
		local origin = frameCFrame(world)
		local model = Instance.new("Model")
		model.Name = node.name
		local mode = enumItem(Enum.ModelStreamingMode, node.streaming)
		if mode then
			model.ModelStreamingMode = mode :: Enum.ModelStreamingMode
		end
		for k, v in node.attributes do
			if k == "LOD" then
				if v == "StreamingMesh" then
					model.LevelOfDetail = Enum.ModelLevelOfDetail.StreamingMesh
				end
			else
				model:SetAttribute(k, v)
			end
		end
		for _, tag in node.tags do
			CollectionService:AddTag(model, tag)
		end
		local skybox = table.find(node.tags, "Skybox") ~= nil
		stats.models += 1

		local anchor: Part? = nil
		local function getAnchor(): Part
			if anchor then
				return anchor
			end
			local a = Instance.new("Part")
			a.Name = "Anchor"
			a.Size = Vector3.new(0.2, 0.2, 0.2)
			a.CFrame = origin
			a.Transparency = 1
			a.Anchored = true
			a.CanCollide = false
			a.CanQuery = false
			a.CanTouch = false
			a.CastShadow = false
			a.Parent = model
			anchor = a
			return a
		end

		-- pieces
		local pieceParts: { [number]: BasePart } = {}
		for i, p in node.pieces do
			local s = p.s or 1
			local scale = Vector3.new((p.sx or 1) * s, (p.sy or 1) * s, (p.sz or 1) * s)
			local cf = placementCFrame(origin, p.x, p.y, p.z, p.ry, p.rx, p.rz)
			local built = KitLibrary.create(p.kit, cf, scale, p.material, p.color, p.noCollide == true or skybox)
			if built.visual then
				local v = built.visual :: BasePart
				v.Name = p.kit
				if p.text then
					addSignText(v, p.text, true)
				end
				if p.tag then
					CollectionService:AddTag(v, p.tag)
					v:SetAttribute("BaseMaterial", v.Material.Name)
					v:SetAttribute("BaseColor", v.Color)
					v:SetAttribute("BaseTransparency", v.Transparency)
				end
				if skybox then
					v.CastShadow = false
					v.CanCollide = false
					v.CanQuery = false
				end
				if not KitLibrary.hasMesh(p.kit) then
					stats.blockouts += 1
				end
				v.Parent = model
				pieceParts[i] = v
				stats.parts += 1
				tick()
			end
			for _, c in built.colliders do
				c.Parent = model
				stats.parts += 1
				tick()
			end
		end

		-- solids
		for _, sd in node.solids do
			local part: BasePart
			if sd.shape == "Wedge" then
				part = Instance.new("WedgePart")
			else
				local pp = Instance.new("Part")
				if sd.shape == "Cylinder" then
					pp.Shape = Enum.PartType.Cylinder
				end
				part = pp
			end
			part.Name = sd.name or sd.kind
			part.Size = Vector3.new(math.max(sd.sx, 0.05), math.max(sd.sy, 0.05), math.max(sd.sz, 0.05))
			part.CFrame = placementCFrame(origin, sd.x, sd.y, sd.z, sd.ry, sd.rx, sd.rz)
			part.Anchored = true
			part.CanTouch = false
			part.TopSurface = Enum.SurfaceType.Smooth
			part.BottomSurface = Enum.SurfaceType.Smooth
			part.Material = KitLibrary.material(sd.material or "SmoothPlastic")
			part.Color = Palette[sd.color or "Stone"] or Palette.Stone
			part.Transparency = sd.transparency or 0
			if sd.kind == "Collider" then
				part.Transparency = 1
				part.CastShadow = false
			elseif sd.kind == "Current" or sd.kind == "Falls" then
				part.CanCollide = false
				part.CanQuery = false
				part.CastShadow = false
				CollectionService:AddTag(part, "CurrentSurface")
				local texId = if sd.kind == "Falls" then AssetManifest.Textures.CurrentFalls else AssetManifest.Textures.CurrentFlow
				if texId ~= "" then
					local tex = Instance.new("Texture")
					tex.Texture = texId
					tex.Face = if sd.kind == "Falls" then Enum.NormalId.Front else Enum.NormalId.Top
					tex.StudsPerTileU = 24
					tex.StudsPerTileV = 24
					tex.Transparency = 0.35
					tex.Color3 = Palette.CurrentTeal
					tex.Parent = part
					CollectionService:AddTag(tex, "CurrentFlowTexture")
				end
			elseif sd.kind == "Trigger" then
				part.Transparency = 1
				part.CanCollide = false
				part.CastShadow = false
			elseif sd.kind == "Barrier" then
				part.CanCollide = true
				part.CastShadow = false
			end
			if skybox then
				part.CanCollide = false
				part.CanQuery = false
				part.CastShadow = false
			end
			if sd.text then
				addSignText(part, sd.text, false)
			end
			if sd.tag then
				CollectionService:AddTag(part, sd.tag)
				part:SetAttribute("BaseTransparency", part.Transparency)
				part:SetAttribute("BaseColor", part.Color)
			end
			part.Parent = model
			stats.parts += 1
			tick()
		end

		-- lights
		for _, l in node.lights do
			local light = Instance.new("PointLight")
			light.Color = Palette[l.color] or Palette.LanternGlow
			light.Range = math.clamp(l.range, 4, 60)
			light.Brightness = l.brightness
			light.Shadows = false
			light:SetAttribute("BaseBrightness", l.brightness)
			if l.night then
				CollectionService:AddTag(light, "NightLight")
			end
			CollectionService:AddTag(light, "WorldLight")
			local host = if l.piece then pieceParts[l.piece :: number] else nil
			if host then
				light.Parent = host
			else
				local att = Instance.new("Attachment")
				att.Name = "Light"
				att.Parent = getAnchor()
				att.Position = Vector3.new(l.x, l.y, l.z) -- the anchor sits at the node origin
				light.Parent = att
				tick()
			end
			stats.lights += 1
			tick()
		end

		-- emitters
		for _, e in node.emitters do
			local emitter = WorldFX.emitter(e.preset, 1)
			local isNight = emitter:GetAttribute("NightOnly") == true
			if isNight then
				emitter.Enabled = false
				CollectionService:AddTag(emitter, "NightEmitter")
			end
			CollectionService:AddTag(emitter, "WorldEmitter")
			if WorldFX.isArea(e.preset) and e.sx then
				local vol = Instance.new("Part")
				vol.Name = e.preset .. "Volume"
				vol.Size = Vector3.new(math.max(e.sx or 1, 0.2), math.max(e.sy or 1, 0.2), math.max(e.sz or 1, 0.2))
				vol.CFrame = placementCFrame(origin, e.x, e.y, e.z, e.ry or 0, nil, nil)
				vol.Transparency = 1
				vol.Anchored = true
				vol.CanCollide = false
				vol.CanQuery = false
				vol.CanTouch = false
				vol.CastShadow = false
				emitter.Parent = vol
				vol.Parent = model
			else
				local att = Instance.new("Attachment")
				att.Name = e.preset
				att.Parent = getAnchor()
				att.Position = Vector3.new(e.x, e.y, e.z)
				emitter.Parent = att
			end
			stats.emitters += 1
			tick()
		end

		-- markers
		for _, mk in node.markers do
			local m = Instance.new("Part")
			m.Name = mk.kind .. "_" .. mk.id
			m.Size = Vector3.new(1, 1, 1)
			m.CFrame = placementCFrame(origin, mk.x, mk.y, mk.z, mk.ry, nil, nil)
			m.Transparency = 1
			m.Anchored = true
			m.CanCollide = false
			m.CanQuery = false
			m.CanTouch = false
			m.CastShadow = false
			m:SetAttribute("MarkerKind", mk.kind)
			m:SetAttribute("MarkerId", mk.id)
			setAttributes(m, mk.attributes)
			CollectionService:AddTag(m, mk.kind)
			m.Parent = model
			stats.markers += 1
			tick()
		end

		for _, child in node.children do
			build(child, model, world)
		end
		if node.pieces[1] or node.solids[1] then
			model.WorldPivot = origin
		end
		model.Parent = parentInst
		return model
	end

	local model = build(root, parent, Plan.frame(0, 0, 0, 0, 1))
	return model, stats
end

return PlanApplier
