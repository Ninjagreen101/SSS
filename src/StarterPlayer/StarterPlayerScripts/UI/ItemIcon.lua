--!strict
--[[
	ItemIcon
	A still 3D render of an item (ItemModels) in a ViewportFrame, framed to
	fit: weapons on a diagonal, Terraria-style; everything else in a
	three-quarter view. Used by ItemSlot, the pickup feed, tooltips, the
	crafting preview and the item reveal.

	Cheap on phones: the model is static (no WorldModel, no animation), so
	the engine only re-renders a viewport when its contents change, and a
	slot reuses its viewport when the item changes.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Items = require(Shared.Data.Items)

local Create = require(script.Parent.Create)
local ItemModels = require(script.Parent.ItemModels)

export type ItemIcon = {
	Instance: ViewportFrame,
	Set: (self: ItemIcon, defId: string?, rarity: string?) -> (),
	Destroy: (self: ItemIcon) -> (),
}

export type Props = {
	Size: UDim2?,
	Position: UDim2?,
	AnchorPoint: Vector2?,
	ZIndex: number?,
	Parent: Instance?,
}

local FOV = 30
local WEAPON_TILT = CFrame.Angles(0, 0, math.rad(-45))
local VIEW_DIRECTION = Vector3.new(0.45, 0.35, -1).Unit -- camera sits in front (-Z), a little up and right

local ItemIcon = {}

-- Places `model` (centred on the origin) and points `camera` at it so it fills the frame.
local function frame(model: Model, camera: Camera, weapon: boolean)
	local pivot = if weapon then WEAPON_TILT else CFrame.Angles(0, math.rad(-20), 0)
	model:PivotTo(pivot)
	local box, size = model:GetBoundingBox()
	local radius = size.Magnitude / 2
	local distance = radius / math.tan(math.rad(FOV / 2)) * 1.02
	local direction = if weapon then Vector3.new(0, 0, -1) else VIEW_DIRECTION
	camera.FieldOfView = FOV
	camera.CFrame = CFrame.lookAt(box.Position + direction * distance, box.Position)
end

function ItemIcon.new(props: Props): ItemIcon
	local viewport: ViewportFrame = Create.new("ViewportFrame", {
		Name = "ItemIcon",
		BackgroundTransparency = 1,
		Size = props.Size or UDim2.fromScale(1, 1),
		Position = props.Position or UDim2.new(),
		AnchorPoint = props.AnchorPoint or Vector2.zero,
		ZIndex = props.ZIndex or 2,
		Ambient = Color3.fromRGB(170, 170, 180),
		LightColor = Color3.fromRGB(255, 246, 228),
		LightDirection = Vector3.new(-0.6, -1, 0.5),
		Parent = props.Parent,
	})
	local camera = Instance.new("Camera")
	camera.Parent = viewport
	viewport.CurrentCamera = camera

	local currentKey = ""
	local model: Model? = nil

	local self = { Instance = viewport }

	function self.Set(_self: ItemIcon, defId: string?, rarity: string?)
		local key = `{defId or ""}:{rarity or ""}`
		if key == currentKey then
			return
		end
		currentKey = key
		if model then
			model:Destroy()
			model = nil
		end
		if not defId then
			return
		end
		local built = if defId == "Gold" then ItemModels.BuildGold() else ItemModels.Build(defId, rarity)
		frame(built, camera, Items.GetWeapon(defId) ~= nil)
		built.Parent = viewport
		model = built
	end

	function self.Destroy(_self: ItemIcon)
		viewport:Destroy()
	end

	return self :: ItemIcon
end

return ItemIcon
