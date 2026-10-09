--!strict
--[[
	ItemModels
	Small 3D models of items, built from parts, for inventory icons
	(ItemIcon) and loot on the ground (LootController).

	Weapons use their Model description (the same numbers WeaponService
	uses for the blade in your hand); everything else uses its Look
	(Shared/Data/Items): a shape Kind plus a main and accent colour. A
	model is built once per item id and rarity, then cloned.

	All models are centred on the origin, roughly 3 studs across, anchored,
	with no collisions or shadows. Rare-and-better weapons get a glowing
	edge in the rarity colour, like in the hand.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Items = require(Shared.Data.Items)

local UITheme = require(script.Parent.UITheme)

local ItemModels = {}

local templates: { [string]: Model } = {}

local METAL = Enum.Material.Metal
local SMOOTH = Enum.Material.SmoothPlastic
local NEON = Enum.Material.Neon
local FABRIC = Enum.Material.Fabric
local WOOD = Enum.Material.Wood

local function part(model: Model, shape: Enum.PartType?, size: Vector3, cframe: CFrame, color: Color3, material: Enum.Material?): Part
	local p = Instance.new("Part")
	p.Shape = shape or Enum.PartType.Block
	p.Size = size
	p.CFrame = cframe
	p.Color = color
	p.Material = material or SMOOTH
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = model
	return p
end

local function wedge(model: Model, size: Vector3, cframe: CFrame, color: Color3, material: Enum.Material?): WedgePart
	local p = Instance.new("WedgePart")
	p.Size = size
	p.CFrame = cframe
	p.Color = color
	p.Material = material or SMOOTH
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Parent = model
	return p
end

-- A ring of `count` small blocks in the XY plane.
local function hoop(model: Model, radius: number, thickness: number, count: number, center: CFrame, color: Color3, material: Enum.Material?)
	for index = 1, count do
		local angle = (index / count) * math.pi * 2
		local length = 2 * radius * math.sin(math.pi / count) + thickness * 0.4
		part(
			model,
			nil,
			Vector3.new(length, thickness, thickness),
			center * CFrame.Angles(0, 0, angle) * CFrame.new(0, radius, 0),
			color,
			material
		)
	end
end

-- WEAPONS ------------------------------------------------------------------------

local function blade(model: Model, look: Items.WeaponModel, origin: CFrame, glow: Color3?)
	-- Points up +Y: pommel at the bottom, then grip, guard, blade.
	local scale = 3.2 / (look.BladeLength + look.GripLength + 0.4)
	local grip = look.GripLength * scale
	local length = look.BladeLength * scale
	local width = math.max(0.12, look.BladeWidth * scale * 1.4)
	local base = -(grip + length) / 2
	part(model, Enum.PartType.Ball, Vector3.one * 0.26, origin * CFrame.new(0, base - 0.08, 0), look.GuardColor or Color3.fromHex("#A88A4F"), METAL)
	part(model, Enum.PartType.Cylinder, Vector3.new(grip, 0.16, 0.16), origin * CFrame.new(0, base + grip / 2, 0) * CFrame.Angles(0, 0, math.rad(90)), Color3.fromHex("#3B2A1E"), WOOD)
	part(model, nil, Vector3.new(math.max(0.5, look.GuardWidth * scale * 1.2), 0.14, 0.22), origin * CFrame.new(0, base + grip, 0), look.GuardColor or Color3.fromHex("#A88A4F"), METAL)
	local bladeCenter = origin * CFrame.new(0, base + grip + 0.07 + length / 2, 0)
	part(model, nil, Vector3.new(width, length, 0.07), bladeCenter, look.BladeColor, METAL)
	-- Tip
	wedge(model, Vector3.new(0.07, width * 0.9, width / 2), bladeCenter * CFrame.new(width / 4, length / 2 + width * 0.45, 0) * CFrame.Angles(0, math.rad(90), 0), look.BladeColor, METAL)
	wedge(model, Vector3.new(0.07, width * 0.9, width / 2), bladeCenter * CFrame.new(-width / 4, length / 2 + width * 0.45, 0) * CFrame.Angles(0, math.rad(-90), 0), look.BladeColor, METAL)
	if glow then
		part(model, nil, Vector3.new(math.max(0.04, width * 0.22), length * 0.9, 0.09), bladeCenter, glow, NEON)
	end
end

local function buildWeapon(model: Model, def: Items.WeaponDef, rarity: string)
	local glow = def.Model.EdgeGlow
	if Items.RarityRank(rarity) >= Items.RarityRank("Rare") then
		glow = glow or UITheme.RarityColor(rarity)
	end
	if def.Model.Twin then
		blade(model, def.Model, CFrame.Angles(0, 0, math.rad(-22)) * CFrame.new(-0.35, 0, 0), glow)
		blade(model, def.Model, CFrame.Angles(0, 0, math.rad(22)) * CFrame.new(0.35, 0, 0.1), glow)
	else
		blade(model, def.Model, CFrame.new(), glow)
	end
end

-- EVERYTHING ELSE ------------------------------------------------------------------

type Builder = (model: Model, look: Items.Look) -> ()

local function accentMaterial(look: Items.Look): Enum.Material
	return if look.Glow then NEON else METAL
end

local BUILDERS: { [string]: Builder } = {
	Helm = function(model, look)
		part(model, Enum.PartType.Ball, Vector3.new(2, 2, 2), CFrame.new(0, 0.2, 0), look.Color, METAL)
		part(model, Enum.PartType.Cylinder, Vector3.new(0.3, 2.3, 2.3), CFrame.new(0, -0.55, 0) * CFrame.Angles(0, 0, math.rad(90)), look.Color, METAL)
		part(model, nil, Vector3.new(1.1, 0.16, 0.3), CFrame.new(0, 0.05, -0.92), look.Accent or look.Color, accentMaterial(look))
		part(model, nil, Vector3.new(0.18, 0.9, 1.4), CFrame.new(0, 1.15, 0.1), look.Accent or look.Color, METAL)
	end,
	Chest = function(model, look)
		part(model, nil, Vector3.new(2, 2.3, 1), CFrame.new(0, 0, 0), look.Color, FABRIC)
		part(model, Enum.PartType.Ball, Vector3.new(0.95, 0.95, 0.95), CFrame.new(-1.15, 0.85, 0), look.Color, METAL)
		part(model, Enum.PartType.Ball, Vector3.new(0.95, 0.95, 0.95), CFrame.new(1.15, 0.85, 0), look.Color, METAL)
		part(model, nil, Vector3.new(2.06, 0.28, 1.06), CFrame.new(0, -0.7, 0), look.Accent or look.Color, METAL)
		part(model, nil, Vector3.new(0.5, 0.9, 1.06), CFrame.new(0, 0.45, 0), look.Accent or look.Color, accentMaterial(look))
	end,
	Legs = function(model, look)
		part(model, nil, Vector3.new(0.85, 2.4, 0.9), CFrame.new(-0.48, -0.2, 0) * CFrame.Angles(0, 0, math.rad(-4)), look.Color, FABRIC)
		part(model, nil, Vector3.new(0.85, 2.4, 0.9), CFrame.new(0.48, -0.2, 0) * CFrame.Angles(0, 0, math.rad(4)), look.Color, FABRIC)
		part(model, nil, Vector3.new(2, 0.4, 1), CFrame.new(0, 1.1, 0), look.Accent or look.Color, METAL)
		part(model, nil, Vector3.new(0.9, 0.5, 0.95), CFrame.new(-0.5, 0.1, 0), look.Accent or look.Color, METAL)
		part(model, nil, Vector3.new(0.9, 0.5, 0.95), CFrame.new(0.5, 0.1, 0), look.Accent or look.Color, METAL)
	end,
	Gloves = function(model, look)
		part(model, nil, Vector3.new(1.3, 1.5, 0.6), CFrame.new(0, 0.2, 0), look.Color, FABRIC)
		part(model, nil, Vector3.new(1.3, 0.7, 0.55), CFrame.new(0, 1.15, 0.05), look.Color, FABRIC)
		part(model, nil, Vector3.new(0.4, 0.8, 0.5), CFrame.new(-0.8, 0.35, 0) * CFrame.Angles(0, 0, math.rad(30)), look.Color, FABRIC)
		part(model, Enum.PartType.Cylinder, Vector3.new(0.6, 1.6, 1.6), CFrame.new(0, -0.75, 0) * CFrame.Angles(0, 0, math.rad(90)), look.Accent or look.Color, METAL)
	end,
	Cloak = function(model, look)
		part(model, nil, Vector3.new(2.2, 2.8, 0.15), CFrame.new(0, -0.2, 0.2) * CFrame.Angles(math.rad(8), 0, 0), look.Color, FABRIC)
		wedge(model, Vector3.new(0.15, 2.8, 0.7), CFrame.new(-1.2, -0.2, 0.05) * CFrame.Angles(0, math.rad(90), 0), look.Color, FABRIC)
		wedge(model, Vector3.new(0.15, 2.8, 0.7), CFrame.new(1.2, -0.2, 0.05) * CFrame.Angles(0, math.rad(-90), 0), look.Color, FABRIC)
		part(model, nil, Vector3.new(2.3, 0.35, 0.5), CFrame.new(0, 1.25, 0), look.Color, FABRIC)
		part(model, Enum.PartType.Ball, Vector3.one * 0.45, CFrame.new(0, 1.15, -0.3), look.Accent or look.Color, accentMaterial(look))
	end,
	Ring = function(model, look)
		hoop(model, 1, 0.3, 10, CFrame.new(0, -0.3, 0), look.Color, METAL)
		part(model, Enum.PartType.Ball, Vector3.one * 0.75, CFrame.new(0, 0.85, 0), look.Accent or look.Color, if look.Glow then NEON else Enum.Material.Glass)
		part(model, nil, Vector3.new(0.6, 0.25, 0.4), CFrame.new(0, 0.55, 0), look.Color, METAL)
	end,
	Amulet = function(model, look)
		hoop(model, 1.1, 0.1, 12, CFrame.new(0, 0.55, 0) * CFrame.Angles(math.rad(70), 0, 0), Color3.fromHex("#8C7A55"), METAL)
		part(model, Enum.PartType.Cylinder, Vector3.new(0.25, 1.2, 1.2), CFrame.new(0, -0.55, 0) * CFrame.Angles(0, math.rad(90), 0), look.Color, METAL)
		part(model, Enum.PartType.Ball, Vector3.one * 0.6, CFrame.new(0, -0.55, -0.15), look.Accent or look.Color, if look.Glow then NEON else Enum.Material.Glass)
	end,
	Flask = function(model, look)
		part(model, Enum.PartType.Ball, Vector3.one * 1.9, CFrame.new(0, -0.45, 0), look.Color, if look.Glow then NEON else Enum.Material.Glass)
		part(model, Enum.PartType.Cylinder, Vector3.new(1, 0.65, 0.65), CFrame.new(0, 0.85, 0) * CFrame.Angles(0, 0, math.rad(90)), Color3.fromHex("#D7E3E6"), Enum.Material.Glass)
		part(model, Enum.PartType.Cylinder, Vector3.new(0.4, 0.75, 0.75), CFrame.new(0, 1.45, 0) * CFrame.Angles(0, 0, math.rad(90)), Color3.fromHex("#6B4A2C"), WOOD)
		part(model, Enum.PartType.Ball, Vector3.one * 0.5, CFrame.new(-0.4, -0.15, -0.65), look.Accent or Color3.new(1, 1, 1), NEON)
	end,
	Bowl = function(model, look)
		part(model, Enum.PartType.Cylinder, Vector3.new(0.9, 2.4, 2.4), CFrame.new(0, -0.3, 0) * CFrame.Angles(0, 0, math.rad(90)), look.Color, WOOD)
		part(model, Enum.PartType.Cylinder, Vector3.new(0.3, 1.4, 1.4), CFrame.new(0, -0.85, 0) * CFrame.Angles(0, 0, math.rad(90)), look.Color, WOOD)
		part(model, Enum.PartType.Cylinder, Vector3.new(0.12, 2.15, 2.15), CFrame.new(0, 0.18, 0) * CFrame.Angles(0, 0, math.rad(90)), look.Accent or look.Color, SMOOTH)
		part(model, Enum.PartType.Ball, Vector3.one * 0.5, CFrame.new(0.35, 0.3, 0.2), Color3.fromHex("#E9C25B"), SMOOTH)
	end,
	Bomb = function(model, look)
		part(model, Enum.PartType.Ball, Vector3.one * 2, CFrame.new(0, -0.2, 0), look.Color, METAL)
		part(model, Enum.PartType.Cylinder, Vector3.new(0.25, 2.05, 2.05), CFrame.new(0, -0.2, 0) * CFrame.Angles(0, 0, math.rad(90)), look.Accent or look.Color, accentMaterial(look))
		part(model, Enum.PartType.Cylinder, Vector3.new(0.5, 0.35, 0.35), CFrame.new(0, 0.95, 0) * CFrame.Angles(0, 0, math.rad(90)), Color3.fromHex("#6B5A44"), FABRIC)
		part(model, Enum.PartType.Ball, Vector3.one * 0.3, CFrame.new(0, 1.25, 0), Color3.fromHex("#FFD25A"), NEON)
	end,
	Scrap = function(model, look)
		part(model, nil, Vector3.new(1.6, 0.4, 1), CFrame.new(-0.3, -0.4, 0) * CFrame.Angles(0.2, 0.4, 0.1), look.Color, Enum.Material.CorrodedMetal)
		part(model, nil, Vector3.new(0.9, 1.2, 0.3), CFrame.new(0.5, 0.2, 0.1) * CFrame.Angles(0.3, -0.2, 0.5), look.Color, Enum.Material.CorrodedMetal)
		part(model, nil, Vector3.new(0.7, 0.5, 0.7), CFrame.new(-0.4, 0.45, -0.2) * CFrame.Angles(0.5, 0.2, 0.3), look.Accent or look.Color, Enum.Material.CorrodedMetal)
	end,
	Pearl = function(model, look)
		part(model, Enum.PartType.Ball, Vector3.one * 1.8, CFrame.new(), look.Color, Enum.Material.Pebble)
		part(model, Enum.PartType.Ball, Vector3.one * 0.6, CFrame.new(-0.35, 0.4, -0.6), Color3.new(1, 1, 1), NEON)
		if look.Accent then
			hoop(model, 1.15, 0.08, 14, CFrame.Angles(math.rad(75), 0, 0), look.Accent, NEON)
		end
	end,
	Fiber = function(model, look)
		for index = -1, 1 do
			part(model, Enum.PartType.Cylinder, Vector3.new(2.8, 0.3, 0.3), CFrame.new(index * 0.28, 0, index * 0.1) * CFrame.Angles(0, 0, math.rad(90 + index * 9)), look.Color, FABRIC)
		end
		part(model, Enum.PartType.Cylinder, Vector3.new(0.3, 1.05, 1.05), CFrame.new(0, 0, 0) * CFrame.Angles(0, 0, math.rad(90)), look.Accent or look.Color, FABRIC)
	end,
	Log = function(model, look)
		part(model, Enum.PartType.Cylinder, Vector3.new(2.8, 1.2, 1.2), CFrame.Angles(0, 0, math.rad(60)), look.Color, WOOD)
		part(model, Enum.PartType.Cylinder, Vector3.new(0.06, 1.0, 1.0), CFrame.Angles(0, 0, math.rad(60)) * CFrame.new(1.41, 0, 0), look.Accent or look.Color, WOOD)
	end,
	Shell = function(model, look)
		for index = -2, 2 do
			wedge(model, Vector3.new(0.2, 1.8, 0.7), CFrame.Angles(0, 0, math.rad(index * 22)) * CFrame.new(0, 0.6, 0), if index % 2 == 0 then look.Color else (look.Accent or look.Color), Enum.Material.Pebble)
		end
		part(model, Enum.PartType.Ball, Vector3.new(0.8, 0.6, 0.6), CFrame.new(0, -0.4, 0), look.Color, Enum.Material.Pebble)
	end,
	Wisp = function(model, look)
		part(model, Enum.PartType.Ball, Vector3.one * 1.5, CFrame.new(), look.Color, NEON)
		part(model, Enum.PartType.Ball, Vector3.one * 0.45, CFrame.new(0.95, 0.8, 0), look.Accent or look.Color, NEON)
		part(model, Enum.PartType.Ball, Vector3.one * 0.3, CFrame.new(-0.9, -0.7, 0.2), look.Accent or look.Color, NEON)
		part(model, Enum.PartType.Ball, Vector3.one * 2, CFrame.new(), look.Color, Enum.Material.ForceField)
	end,
	Ingot = function(model, look)
		part(model, nil, Vector3.new(2.4, 0.7, 1.1), CFrame.new(0, -0.15, 0), look.Color, METAL)
		part(model, nil, Vector3.new(2, 0.3, 0.8), CFrame.new(0, 0.33, 0), look.Color, METAL)
		part(model, nil, Vector3.new(2.42, 0.12, 0.3), CFrame.new(0, -0.1, -0.42), look.Accent or look.Color, accentMaterial(look))
	end,
	Core = function(model, look)
		part(model, Enum.PartType.Ball, Vector3.one * 1.1, CFrame.new(), look.Color, NEON)
		hoop(model, 1, 0.12, 12, CFrame.new(), look.Accent or look.Color, METAL)
		hoop(model, 1, 0.12, 12, CFrame.Angles(0, math.rad(90), 0), look.Accent or look.Color, METAL)
		hoop(model, 1, 0.12, 12, CFrame.Angles(math.rad(90), 0, 0), Color3.fromHex("#A88A4F"), METAL)
	end,
	Scroll = function(model, look)
		part(model, nil, Vector3.new(2, 1.6, 0.06), CFrame.new(0, -0.15, 0) * CFrame.Angles(math.rad(-10), 0, 0), look.Color, Enum.Material.Fabric)
		part(model, Enum.PartType.Cylinder, Vector3.new(2.3, 0.4, 0.4), CFrame.new(0, 0.7, 0), look.Color, Enum.Material.Fabric)
		part(model, Enum.PartType.Cylinder, Vector3.new(2.3, 0.4, 0.4), CFrame.new(0, -1, 0.1), look.Color, Enum.Material.Fabric)
		part(model, nil, Vector3.new(1.2, 0.08, 0.08), CFrame.new(0, 0, -0.08), look.Accent or look.Color, SMOOTH)
		part(model, nil, Vector3.new(0.8, 0.08, 0.08), CFrame.new(-0.2, -0.35, -0.06), look.Accent or look.Color, SMOOTH)
	end,
	Sigil = function(model, look)
		part(model, Enum.PartType.Cylinder, Vector3.new(0.35, 2.4, 2.4), CFrame.Angles(0, math.rad(90), 0), look.Color, Enum.Material.Slate)
		part(model, Enum.PartType.Cylinder, Vector3.new(0.4, 1.2, 1.2), CFrame.Angles(0, math.rad(90), 0), look.Accent or look.Color, accentMaterial(look))
		for index = 0, 3 do
			part(model, nil, Vector3.new(0.18, 0.5, 0.4), CFrame.Angles(0, 0, math.rad(index * 90)) * CFrame.new(0, 0.95, 0), look.Accent or look.Color, accentMaterial(look))
		end
	end,
	Coin = function(model, look)
		for index = 0, 2 do
			part(model, Enum.PartType.Cylinder, Vector3.new(0.22, 1.4, 1.4), CFrame.new(index * 0.12 - 0.12, -0.6 + index * 0.24, 0) * CFrame.Angles(0, 0, math.rad(90)), look.Color, METAL)
		end
		part(model, Enum.PartType.Cylinder, Vector3.new(0.22, 1.4, 1.4), CFrame.new(0.5, 0.5, 0) * CFrame.Angles(0, math.rad(15), math.rad(10)), look.Color, METAL)
		part(model, Enum.PartType.Cylinder, Vector3.new(0.24, 0.7, 0.7), CFrame.new(0.5, 0.5, 0) * CFrame.Angles(0, math.rad(15), math.rad(10)), look.Accent or look.Color, METAL)
	end,
}

local function finish(model: Model): Model
	-- An invisible centre part makes pivoting, spinning and framing easy.
	local center = Instance.new("Part")
	center.Name = "Center"
	center.Size = Vector3.one * 0.1
	center.Transparency = 1
	center.Anchored = true
	center.CanCollide = false
	center.CanQuery = false
	center.CanTouch = false
	center.Parent = model
	model.PrimaryPart = center
	return model
end

-- A fresh model for an item at a rarity (rarity changes weapon glow).
function ItemModels.Build(defId: string, rarity: string?): Model
	local def = Items.Get(defId)
	local key = `{defId}:{rarity or ""}`
	local template = templates[key]
	if not template then
		local model = Instance.new("Model")
		model.Name = defId
		local weapon = Items.GetWeapon(defId)
		if weapon then
			buildWeapon(model, weapon, rarity or weapon.Rarity)
		elseif def and def.Look then
			local builder = BUILDERS[def.Look.Kind]
			if builder then
				builder(model, def.Look)
			end
		end
		if #model:GetChildren() == 0 then
			part(model, Enum.PartType.Ball, Vector3.one * 1.6, CFrame.new(), UITheme.RarityColor(rarity or "Common"), SMOOTH)
		end
		local built = finish(model)
		templates[key] = built
		return built:Clone()
	end
	return template:Clone()
end

-- A pile of gold coins.
function ItemModels.BuildGold(): Model
	local template = templates.__Gold
	if not template then
		local model = Instance.new("Model")
		model.Name = "Gold"
		BUILDERS.Coin(model, Items.GoldLook)
		local built = finish(model)
		templates.__Gold = built
		return built:Clone()
	end
	return template:Clone()
end

return ItemModels
