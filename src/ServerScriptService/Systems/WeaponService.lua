--!strict
--[[
	WeaponService
	Which weapon each player wields, and the weapon model in their hand.

	- The equipped weapon comes from the profile (Equipped.Weapon -> an item
	  Uid in the inventory -> its DefId). An empty slot falls back to
	  Items.DefaultWeapon, so every Climber always has a blade.
	- The character carries WeaponId / WeaponClass attributes so clients
	  know which timings and animations to use.
	- GetWeapon returns the equipped copy's numbers: rarity, upgrade level
	  and wear scale the definition's damage and posture (GearStats).
	- Until real weapon meshes exist, the model is a blade built from parts
	  (grip, guard, blade, and a glowing edge on Rare-and-better copies)
	  using the item's Model description, welded to the right hand
	  (Twinfangs get a second blade in the left).
	- In Studio, SetDevOverride swaps weapons for testing (DevHooks).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Attributes)
local Items = require(Shared.Data.Items)
local GearStats = require(Shared.Data.GearStats)
local Config = require(Shared.Config)
local Signal = require(Shared.Util.Signal)
local Types = require(Shared.Types)
local WeaponGrip = require(Shared.Util.WeaponGrip)

local DataService = require(script.Parent.DataService)

local A = Attributes.Names
local MODEL_NAME = "SpireWeapon"

local WeaponService = {}

-- Fired when a player's wielded weapon changes: (player, defId)
WeaponService.Changed = Signal.new() :: Signal.Signal<Player, string>

local devOverride: { [Player]: string } = {}
local attachedLook: { [Player]: string } = {}

local glowFor: (def: Items.WeaponDef) -> Color3?
local lookKey: (player: Player) -> string

-- PUBLIC API -----------------------------------------------------------------

function WeaponService.GetWeaponId(player: Player): string
	local override = devOverride[player]
	if override then
		return override
	end
	local data = DataService.GetData(player)
	if data then
		local uid = data.Equipped.Weapon
		local item = if uid ~= "" then data.Inventory.Items[uid] else nil
		if item and Items.GetWeapon(item.DefId) then
			return item.DefId
		end
	end
	return Items.DefaultWeapon
end

-- The equipped weapon copy, if the Weapon slot holds one.
local function equippedCopy(player: Player, id: string): Types.ItemInstance?
	if devOverride[player] then
		return nil
	end
	local data = DataService.GetData(player)
	local item = if data then GearStats.EquippedItem(data, "Weapon") else nil
	return if item and item.DefId == id then item else nil
end

-- The wielded weapon's id and numbers (this copy's rarity, upgrades and wear applied).
function WeaponService.GetWeapon(player: Player): (string, Items.WeaponDef)
	local id = WeaponService.GetWeaponId(player)
	local def = Items.GetWeapon(id)
	if def then
		return id, GearStats.Weapon(def, equippedCopy(player, id))
	end
	return Items.DefaultWeapon, Items.GetWeapon(Items.DefaultWeapon) :: Items.WeaponDef
end

-- MODEL ----------------------------------------------------------------------

local function part(name: string, size: Vector3, color: Color3, material: Enum.Material, cframe: CFrame, parent: Instance): BasePart
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Color = color
	p.Material = material
	p.CFrame = cframe
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Massless = true
	p.CastShadow = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

-- Builds one blade in `hand`. The blade points along the hand's forward axis,
-- which is where a sword points when the arm hangs at rest. With an
-- `offHand`, the grip reaches back far enough to fit both hands (the
-- two-handed guard, GuardPoseController).
local function buildBlade(model: Model, hand: BasePart, look: Items.WeaponModel, offHand: BasePart?, glow: Color3?)
	local grip = hand.CFrame * WeaponGrip.Offset(hand)
	local front = -look.GripLength / 2
	local back = look.GripLength / 2
	if offHand then
		back = math.max(back, WeaponGrip.TwoHandedReach(hand, offHand))
	end
	local gripPart = part(
		"Grip",
		Vector3.new(0.22, 0.22, back - front),
		Color3.fromHex("#3B2A1E"),
		Enum.Material.Wood,
		grip * CFrame.new(0, 0, (front + back) / 2),
		model
	)
	local guardCFrame = grip * CFrame.new(0, 0, front)
	local guard = part("Guard", Vector3.new(look.GuardWidth, 0.2, 0.22), look.GuardColor or Color3.fromHex("#A88A4F"), Enum.Material.Metal, guardCFrame, model)
	local bladeCFrame = guardCFrame * CFrame.new(0, 0, -look.BladeLength / 2 - 0.1)
	local blade = part("Blade", Vector3.new(look.BladeWidth, 0.08, look.BladeLength), look.BladeColor, Enum.Material.Metal, bladeCFrame, model)
	local pieces = { gripPart, guard, blade }
	if glow then
		-- A thin neon line down the blade's centre.
		local edge = part(
			"Edge",
			Vector3.new(math.max(0.04, look.BladeWidth * 0.22), 0.1, look.BladeLength * 0.92),
			glow,
			Enum.Material.Neon,
			bladeCFrame,
			model
		)
		table.insert(pieces, edge)
	end
	for _, piece in pieces do
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = hand
		weld.Part1 = piece
		weld.Parent = piece
	end
end

local function handOf(character: Model, side: "Right" | "Left"): BasePart?
	local r15 = character:FindFirstChild(`{side}Hand`)
	if r15 and r15:IsA("BasePart") then
		return r15
	end
	local r6 = character:FindFirstChild(`{side} Arm`)
	return if r6 and r6:IsA("BasePart") then r6 else nil
end

-- Builds a weapon model in a character's hands (players, and mobs that hold
-- blades). Replaces any weapon model already there.
function WeaponService.BuildModel(character: Model, look: Items.WeaponModel, glow: Color3?): Model
	local old = character:FindFirstChild(MODEL_NAME)
	if old then
		old:Destroy()
	end
	local model = Instance.new("Model")
	model.Name = MODEL_NAME
	local right = handOf(character, "Right")
	if right then
		buildBlade(model, right, look, if look.Twin then nil else handOf(character, "Left"), glow)
	end
	if look.Twin then
		local left = handOf(character, "Left")
		if left then
			buildBlade(model, left, look, nil, glow)
		end
	end
	model.Parent = character
	return model
end

-- Rare-and-better copies glow: the weapon's own edge colour, else the rarity colour.
local GLOW_FROM = table.find(Config.Items.RarityOrder, "Rare") :: number
local RARITY_GLOW: { [string]: Color3 } = {
	Rare = Color3.fromHex("#4FA3FF"),
	Epic = Color3.fromHex("#B36BFF"),
	Legendary = Color3.fromHex("#FFA53A"),
	Mythic = Color3.fromHex("#FF4F6D"),
	SpireForged = Color3.fromHex("#3FE0D0"),
}

function glowFor(def: Items.WeaponDef): Color3?
	if Items.RarityRank(def.Rarity) < GLOW_FROM then
		return def.Model.EdgeGlow
	end
	return def.Model.EdgeGlow or RARITY_GLOW[def.Rarity]
end

-- Identifies the wielded copy's look: item uid plus rarity.
function lookKey(player: Player): string
	local data = DataService.GetData(player)
	local item = if data then GearStats.EquippedItem(data, "Weapon") else nil
	return if item then `{item.Uid}:{item.Rarity}` else ""
end

-- (Re)builds the weapon model on a character and sets its attributes.
function WeaponService.Attach(player: Player, character: Model)
	local id, def = WeaponService.GetWeapon(player)
	character:SetAttribute(A.WeaponId, id)
	character:SetAttribute(A.WeaponClass, def.Class)
	WeaponService.BuildModel(character, def.Model, glowFor(def))
	attachedLook[player] = lookKey(player)
	WeaponService.Changed:Fire(player, id)
end

-- Rebuilds when the wielded item or its rarity changes (not on every bag change).
local function refresh(player: Player)
	local character = player.Character
	if character and (character:GetAttribute(A.WeaponId) ~= WeaponService.GetWeaponId(player) or attachedLook[player] ~= lookKey(player)) then
		WeaponService.Attach(player, character)
	end
end

-- Studio only: wield any weapon without owning it (testing classes).
function WeaponService.SetDevOverride(player: Player, defId: string): boolean
	if not RunService:IsStudio() or not Items.GetWeapon(defId) then
		return false
	end
	devOverride[player] = defId
	refresh(player)
	return true
end

function WeaponService.Start()
	DataService.Changed:Connect(function(player: Player, path: { string })
		local root = path[1]
		if root == "Equipped" or root == "Inventory" then
			refresh(player)
		end
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		devOverride[player] = nil
		attachedLook[player] = nil
	end)
end

return WeaponService
