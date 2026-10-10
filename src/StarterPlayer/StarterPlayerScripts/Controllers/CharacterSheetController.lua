--!strict
--[[
	CharacterSheetController
	The Character page of the Character window (TAB).

	  Left    Attributes: points to spend, - / + per stat, Confirm / Reset
	          (shared StatAllocator; staged points are shared with the Skill
	          Tree). Below it, the Current: your Attunements and what your
	          Draw / Density / Control do for your spells.
	  Centre  Your Climber on a pool of light, rotatable (drag, or the right
	          stick), with the equipment arranged around it: armour on the
	          left, jewellery and cloak on the right, weapon and Beacon core
	          below. Empty slots show their category; hover for the item,
	          click an item for its actions, click an empty slot to see what
	          fits it in your bag.
	  Right   Character details (level and archetype, Position, time climbed,
	          enemies defeated, XP) and build stats. "View all stats" swaps in
	          every bonus from gear and the skill tree and every unique effect.

	Every request goes to the server; this only draws from your profile.
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Strings = require(Shared.Strings)
local Types = require(Shared.Types)
local Net = require(Shared.Net)
local Maid = require(Shared.Util.Maid)
local Items = require(Shared.Data.Items)
local GearStats = require(Shared.Data.GearStats)
local Formulas = require(Shared.Data.Formulas)
local ProgressionRules = require(Shared.Data.ProgressionRules)
local Positions = require(Shared.Data.Positions)

local UI = script.Parent.Parent.UI
local UITheme = require(UI.UITheme)
local Create = require(UI.Create)
local Device = require(UI.Device)
local Animator = require(UI.Animator)
local Icons = require(UI.Icons)
local StatDraft = require(UI.StatDraft)
local StatAllocator = require(UI.StatAllocator)
local Components = require(UI.Components)
local ItemText = require(UI.ItemText)
local ProgressionText = require(UI.ProgressionText)

local DataController = require(script.Parent.DataController)
local UIController = require(script.Parent.UIController)
local ProgressionController = require(script.Parent.ProgressionController)
local InventoryController = require(script.Parent.InventoryController)
local AchievementController = require(script.Parent.AchievementController)

type ItemInstance = Types.ItemInstance
type PlayerData = Types.PlayerData

local C = UITheme.Colors
local S = Strings.Inventory
local SH = Strings.CharacterSheet
local player = Players.LocalPlayer

local MENU_ID = "Character"
local SLOT_SIZE = 60
local SLOT_LABEL = 16
local SLOT_STEP = SLOT_SIZE + SLOT_LABEL + 10
local ROW = 30

-- Paper-doll arrangement around the preview.
local LEFT_SLOTS = { "Head", "Chest", "Hands", "Legs" }
local RIGHT_SLOTS = { "Amulet", "Cloak", "Ring1", "Ring2" }
local BOTTOM_SLOTS = { "Weapon", "BeaconCore" }

-- Inventory filter that lists what can go in each slot.
local SLOT_FILTER: { [string]: string } = {
	Weapon = "Weapon",
	Head = "Armor",
	Chest = "Armor",
	Legs = "Armor",
	Hands = "Armor",
	Cloak = "Armor",
	Ring1 = "Accessory",
	Ring2 = "Accessory",
	Amulet = "Accessory",
	BeaconCore = "Other",
}

local CharacterSheetController = {}

local function data(): PlayerData?
	return DataController.GetData()
end

local function slotName(slot: string): string
	if slot == "BeaconCore" then
		return SH.BeaconCore
	end
	return S.SlotNames[slot] or slot
end

-- "2h 05m" from seconds.
local function formatPlaytime(seconds: number): string
	local minutes = math.floor(seconds / 60)
	return Strings.Format(SH.PlaytimeFormat, { hours = math.floor(minutes / 60), minutes = string.format("%02d", minutes % 60) })
end

-- A titled card: dark glass with a heading row (icon + caps title).
local function card(parent: Instance, title: string, icon: string, order: number): Frame
	local frame: Frame = Create.new("Frame", {
		Name = `Card_{icon}`,
		BackgroundColor3 = C.Panel,
		BackgroundTransparency = 0.25,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.fromScale(1, 0),
		LayoutOrder = order,
		Parent = parent,
	})
	Create.Corner(frame)
	Create.Stroke(frame, C.Edge, 1, 0.3)
	Create.Padding(frame, UITheme.Padding.Medium)
	Create.List(frame, Enum.FillDirection.Vertical, 4)
	local header: Frame = Create.new("Frame", { Name = "Header", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 28), LayoutOrder = 0, Parent = frame })
	Icons.new(icon, { Size = UDim2.fromOffset(20, 20), Position = UDim2.fromOffset(0, 4), Color = C.Aqua, Parent = header })
	Create.Label({
		Text = string.upper(title),
		Font = UITheme.Fonts.Title,
		TextSize = 18,
		Color = C.Accent,
		Position = UDim2.fromOffset(28, 0),
		Size = UDim2.new(1, -28, 1, 0),
		Parent = header,
	})
	Icons.Fx("Wave", {
		Name = "Underline",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 28, 1, 4),
		Size = UDim2.fromOffset(90, 10),
		Color = C.Aqua,
		Transparency = 0.6,
		Parent = header,
	})
	return frame
end

-- One aligned "icon  label ........ value" row.
local function statRow(parent: Instance, icon: string, label: string, order: number, iconColor: Color3?): TextLabel
	local row: Frame = Create.new("Frame", { Name = `Row_{icon}`, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, ROW), LayoutOrder = order, Parent = parent })
	Icons.new(icon, {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 0, 0.5, 0),
		Size = UDim2.fromOffset(18, 18),
		Color = iconColor or C.Accent,
		Parent = row,
	})
	Create.Label({
		Text = label,
		TextSize = UITheme.TextSize.Small,
		Color = C.TextMuted,
		Position = UDim2.fromOffset(28, 0),
		Size = UDim2.new(0.6, -28, 1, 0),
		Parent = row,
	})
	-- Hairline under the row.
	Create.new("Frame", {
		Name = "Rule",
		BorderSizePixel = 0,
		BackgroundColor3 = C.Edge,
		BackgroundTransparency = 0.6,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 28, 1, 0),
		Size = UDim2.new(1, -28, 0, 1),
		Parent = row,
	})
	return Create.Label({
		Name = "Value",
		Text = "",
		RichText = true,
		Font = UITheme.Fonts.BodyBold,
		TextSize = UITheme.TextSize.Small,
		XAlignment = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.new(0.55, 0, 1, 0),
		Parent = row,
	})
end

local function column(parent: Instance, name: string, x: UDim, width: UDim): ScrollingFrame
	local frame: ScrollingFrame = Create.new("ScrollingFrame", {
		Name = name,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.new(x, UDim.new(0, 0)),
		Size = UDim2.new(width, UDim.new(1, 0)),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = C.Edge,
		Parent = parent,
	})
	Create.List(frame, Enum.FillDirection.Vertical, UITheme.Padding.Medium)
	Create.new("UIPadding", { PaddingRight = UDim.new(0, 6), Parent = frame })
	return frame
end

-- BUILD ------------------------------------------------------------------------------

local function build(content: Frame, maid: Maid.Maid): any
	local isOpen = false
	local render: () -> ()

	local LEFT_WIDTH = UDim.new(0.25, 0)
	local RIGHT_WIDTH = UDim.new(0.27, 0)
	local GAP = UITheme.Padding.Large

	-- LEFT: attributes and the Current -------------------------------------------
	local left = column(content, "Left", UDim.new(0, 0), LEFT_WIDTH)
	local attributesCard = card(left, S.Sheet.Stats, "StatPoint", 1)
	local allocator = StatAllocator.new({
		Data = data,
		Confirm = function(points: { [string]: number })
			Net.FireServer("RequestAllocateStats", points)
		end,
		LayoutOrder = 1,
		Parent = attributesCard,
	})
	maid:Add(allocator)

	local currentCard = card(left, SH.TheCurrent, "Current", 2)
	local attunementRow: Frame = Create.new("Frame", { Name = "Attunements", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 34), LayoutOrder = 1, Parent = currentCard })
	Create.List(attunementRow, Enum.FillDirection.Horizontal, 6, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)
	local regenValue = statRow(currentCard, "Draw", SH.CurrentRegen, 2)
	local powerValue = statRow(currentCard, "SpellPower", SH.SpellPower, 3)
	local castValue = statRow(currentCard, "CastSpeed", SH.CastSpeed, 4)
	local areaValue = statRow(currentCard, "SpellArea", SH.SpellArea, 5)

	-- CENTRE: the Climber and the equipment -----------------------------------------
	local centre: Frame = Create.new("Frame", {
		Name = "Centre",
		BackgroundColor3 = C.PanelSunken,
		BackgroundTransparency = 0.35,
		ClipsDescendants = true,
		Position = UDim2.new(LEFT_WIDTH.Scale, GAP, 0, 0),
		Size = UDim2.new(1 - LEFT_WIDTH.Scale - RIGHT_WIDTH.Scale, -GAP * 2, 1, 0),
		Parent = content,
	})
	Create.Corner(centre, UDim.new(0, 10))
	Create.Stroke(centre, C.Edge, 1, 0.35)
	Create.new("UIGradient", {
		Rotation = 90,
		Color = ColorSequence.new(Color3.fromRGB(150, 175, 210), Color3.fromRGB(255, 255, 255)),
		Parent = centre,
	})

	-- Light from above and a pool of light the Climber stands in.
	Icons.Fx("Glow", {
		Name = "Backlight",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.42),
		Size = UDim2.fromScale(0.95, 0.85),
		Color = C.Aqua,
		Transparency = 0.82,
		Parent = centre,
	})
	local pool: Frame = Create.new("Frame", { Name = "Pool", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.8), Size = UDim2.fromOffset(280, 80), Parent = centre })
	Icons.Fx("Glow", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(1.2, 1), Color = C.Aqua, Transparency = 0.6, Parent = pool })
	local ripples: { ImageLabel } = {}
	for index = 1, 3 do
		table.insert(ripples, Icons.Fx("Ring", {
			Name = `Ripple{index}`,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(0.3, 0.3),
			Color = C.Foam,
			Transparency = 1,
			Parent = pool,
		}))
	end
	-- Ripples spread outward from under the Climber, one after another.
	maid:Add(Animator.Add(function(time: number)
		for index, ripple in ripples do
			local phase = ((time / 3.6) + (index - 1) / 3) % 1
			ripple.Size = UDim2.fromScale(0.25 + phase * 0.95, 0.25 + phase * 0.95)
			ripple.ImageTransparency = 0.35 + phase * 0.65
		end
	end, MENU_ID))

	-- Name plate.
	local nameLabel = Create.Label({
		Text = player.DisplayName,
		Font = UITheme.Fonts.Title,
		TextSize = 26,
		Color = C.Foam,
		XAlignment = Enum.TextXAlignment.Center,
		Position = UDim2.fromOffset(0, 10),
		Size = UDim2.new(1, 0, 0, 30),
		Parent = centre,
	})
	nameLabel.ZIndex = 3
	local subLabel = Create.Label({
		Text = "",
		TextSize = UITheme.TextSize.Small,
		Color = C.TextMuted,
		XAlignment = Enum.TextXAlignment.Center,
		Position = UDim2.fromOffset(0, 40),
		Size = UDim2.new(1, 0, 0, 18),
		Parent = centre,
	})
	subLabel.ZIndex = 3

	local viewport: ViewportFrame = Create.new("ViewportFrame", {
		Name = "Preview",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 62),
		Size = UDim2.new(1, -(SLOT_SIZE * 2 + 60), 1, -(62 + SLOT_STEP + 10)),
		Ambient = Color3.fromRGB(120, 140, 175),
		LightColor = Color3.fromRGB(225, 240, 255),
		LightDirection = Vector3.new(-0.4, -1, -0.7),
		ZIndex = 2,
		Parent = centre,
	})
	-- Under the name plate, clear of the pool of light at the Climber's feet.
	local rotateHint: Frame = Create.new("Frame", { Name = "RotateHint", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 60), Size = UDim2.fromOffset(160, 18), ZIndex = 3, Parent = centre })
	Create.List(rotateHint, Enum.FillDirection.Horizontal, 6, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
	Icons.new("Rotate", { Size = UDim2.fromOffset(14, 14), Color = C.TextDim, LayoutOrder = 1, Parent = rotateHint })
	Create.Label({ Text = S.Sheet.Rotate, TextSize = UITheme.TextSize.Caption, Color = C.TextDim, AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.new(0, 0, 1, 0), LayoutOrder = 2, Parent = rotateHint })

	local camera = Instance.new("Camera")
	camera.FieldOfView = 30
	camera.Parent = viewport
	viewport.CurrentCamera = camera
	local world = Instance.new("WorldModel")
	world.Parent = viewport
	local preview: Model? = nil
	-- The camera sits on the -Z side, so angle 0 (the default facing, -Z)
	-- shows the Climber's front.
	local angle = 0
	local frameSize = Vector3.zero -- measured once per preview, so rotating doesn't zoom

	local function placePreview()
		if not preview then
			return
		end
		preview:PivotTo(CFrame.Angles(0, angle, 0))
		-- Fit the whole Climber: height against the vertical field of view and
		-- width against the horizontal one.
		local halfFov = math.tan(math.rad(camera.FieldOfView / 2))
		local aspect = if viewport.AbsoluteSize.Y > 0 then viewport.AbsoluteSize.X / viewport.AbsoluteSize.Y else 0.7
		local width = math.max(frameSize.X, frameSize.Z)
		local fitHeight = (frameSize.Y / 2) / halfFov
		local fitWidth = (width / 2) / (halfFov * aspect)
		local distance = math.max(fitHeight, fitWidth) * 1.08 + width / 2
		local pivot = preview:GetPivot().Position
		local centrePoint = Vector3.new(pivot.X, pivot.Y + frameSize.Y * 0.03, pivot.Z)
		camera.CFrame = CFrame.lookAt(centrePoint + Vector3.new(0, 0.4, -distance), centrePoint)
	end
	maid:Add(viewport:GetPropertyChangedSignal("AbsoluteSize"):Connect(placePreview))

	local function rebuildPreview()
		if preview then
			preview:Destroy()
			preview = nil
		end
		local character = player.Character
		if not character then
			return
		end
		local archivable = character.Archivable
		character.Archivable = true
		local clone = character:Clone()
		character.Archivable = archivable
		if not clone then
			return
		end
		for _, descendant in clone:GetDescendants() do
			if descendant:IsA("Script") or descendant:IsA("LocalScript") or descendant:IsA("Sound") or descendant:IsA("BillboardGui") then
				descendant:Destroy()
			elseif descendant:IsA("BasePart") then
				descendant.Anchored = true
			end
		end
		local humanoid = clone:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		end
		clone.Parent = world
		preview = clone
		clone:PivotTo(CFrame.new())
		local _, size = clone:GetBoundingBox()
		frameSize = size
		placePreview()
	end

	local rotating = false
	maid:Add(viewport.InputBegan:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			rotating = true
		end
	end))
	maid:Add(UserInputService.InputChanged:Connect(function(input: InputObject)
		if rotating and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			angle += input.Delta.X * 0.012
			placePreview()
		elseif isOpen and input.KeyCode == Enum.KeyCode.Thumbstick2 and math.abs(input.Position.X) > 0.2 then
			angle += input.Position.X * 0.06
			placePreview()
		end
	end))
	maid:Add(UserInputService.InputEnded:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			rotating = false
		end
	end))

	-- Equipment slots ---------------------------------------------------------------
	local slots: { [string]: Components.ItemSlot } = {}
	local selectedSlot: string? = nil

	local function equippedIn(slot: string): ItemInstance?
		local current = data()
		if not current then
			return nil
		end
		if slot == "BeaconCore" then
			return nil -- the core isn't an equipped item instance (see coreItem)
		end
		return GearStats.EquippedItem(current, slot)
	end

	local function selectSlot(slot: string?)
		if selectedSlot and slots[selectedSlot] then
			slots[selectedSlot]:SetSelected(false)
		end
		selectedSlot = slot
		if slot and slots[slot] then
			slots[slot]:SetSelected(true)
		end
	end

	local function onSlotActivated(slot: string)
		selectSlot(slot)
		local current = data()
		if not current then
			return
		end
		local instance = slots[slot].Instance
		if slot == "BeaconCore" then
			if Items.Get(current.Beacons.Skin) then
				Components.ContextMenu.Show({
					Title = ItemText.Name(current.Beacons.Skin),
					Options = { { Text = S.UnslotCore, OnSelect = function()
						Net.FireServer("RequestItemAction", "UnslotCore", "", "", 0)
					end } },
					Anchor = instance,
				})
			else
				InventoryController.ShowFiltered(SLOT_FILTER[slot])
			end
			return
		end
		local item = equippedIn(slot)
		if item then
			InventoryController.OpenItemContext(item, instance)
		else
			-- Empty: jump to the bag, filtered to what fits here.
			InventoryController.ShowFiltered(SLOT_FILTER[slot] or "All")
		end
	end

	local function makeSlot(slot: string, position: UDim2, anchor: Vector2)
		local holder: Frame = Create.new("Frame", {
			Name = `Slot_{slot}`,
			BackgroundTransparency = 1,
			AnchorPoint = anchor,
			Position = position,
			Size = UDim2.fromOffset(SLOT_SIZE + 24, SLOT_SIZE + SLOT_LABEL),
			ZIndex = 3,
			Parent = centre,
		})
		local itemSlot = Components.ItemSlot.new({
			Size = SLOT_SIZE,
			Name = `Equip_{slot}`,
			Placeholder = Icons.ForSlot(slot),
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.fromScale(0.5, 0),
			Parent = holder,
		})
		maid:Add(itemSlot)
		Create.Label({
			Text = slotName(slot),
			TextSize = UITheme.TextSize.Caption,
			Color = C.TextMuted,
			XAlignment = Enum.TextXAlignment.Center,
			Position = UDim2.fromOffset(0, SLOT_SIZE + 1),
			Size = UDim2.new(1, 0, 0, SLOT_LABEL),
			Parent = holder,
		})
		slots[slot] = itemSlot
		itemSlot.Activated:Connect(function()
			onSlotActivated(slot)
		end)
		itemSlot.SecondaryActivated:Connect(function()
			onSlotActivated(slot)
		end)
		maid:Add(Components.Tooltip.Attach(itemSlot.Instance, function(): Components.TooltipContent?
			local current = data()
			if not current then
				return nil
			end
			if slot == "BeaconCore" then
				local core = Items.Get(current.Beacons.Skin)
				if core then
					return { Title = ItemText.Name(core.Id), TitleColor = UITheme.RarityColor(core.Rarity :: string), Icon = "BeaconCore", Subtitle = SH.BeaconCore }
				end
				return { Title = SH.BeaconCore, Icon = "BeaconCore", Subtitle = S.Empty, Lines = { { Text = SH.EmptyCoreHint, Color = C.TextMuted } } }
			end
			local item = GearStats.EquippedItem(current, slot)
			if item then
				return ItemText.Tooltip(item, current)
			end
			return {
				Title = slotName(slot),
				Icon = Icons.ForSlot(slot),
				Subtitle = S.Empty,
				Lines = { { Text = Strings.Format(SH.EmptySlotHint, { slot = string.lower(slotName(slot)) }), Color = C.TextMuted } },
			}
		end))
	end

	for index, slot in LEFT_SLOTS do
		makeSlot(slot, UDim2.new(0, 10, 0, 64 + (index - 1) * SLOT_STEP), Vector2.new(0, 0))
	end
	for index, slot in RIGHT_SLOTS do
		makeSlot(slot, UDim2.new(1, -10, 0, 64 + (index - 1) * SLOT_STEP), Vector2.new(1, 0))
	end
	for index, slot in BOTTOM_SLOTS do
		local offset = (index - 1.5) * (SLOT_SIZE + 44)
		makeSlot(slot, UDim2.new(0.5, offset, 1, -8), Vector2.new(0.5, 1))
	end

	-- Gamepad: Y on an equipment slot opens its actions.
	maid:Add(UserInputService.InputBegan:Connect(function(input: InputObject)
		if not isOpen or input.KeyCode ~= Enum.KeyCode.ButtonY or Components.ContextMenu.IsOpen() then
			return
		end
		local selected = GuiService.SelectedObject
		for slot, itemSlot in slots do
			if itemSlot.Instance == selected then
				onSlotActivated(slot)
				return
			end
		end
	end))

	-- RIGHT: details and build stats ---------------------------------------------------
	local right = column(content, "Right", UDim.new(1 - RIGHT_WIDTH.Scale, 0), RIGHT_WIDTH)
	local detailsCard = card(right, SH.Details, "Character", 1)
	local levelValue = statRow(detailsCard, "Level", SH.LevelLabel, 1)
	local positionValue = statRow(detailsCard, "SkillTree", SH.PositionLabel, 2)
	local timeValue = statRow(detailsCard, "Time", SH.TimeClimbed, 3)
	local killsValue = statRow(detailsCard, "Kills", SH.Kills, 4)
	-- XP: a thin bar with the numbers above it.
	local xpRow: Frame = Create.new("Frame", { Name = "XP", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 34), LayoutOrder = 5, Parent = detailsCard })
	Icons.new("XP", { Size = UDim2.fromOffset(18, 18), Position = UDim2.fromOffset(0, 2), Color = C.Accent, Parent = xpRow })
	local xpLabel = Create.Label({ Text = "", TextSize = UITheme.TextSize.Caption, Color = C.TextMuted, Position = UDim2.fromOffset(28, 0), Size = UDim2.new(1, -28, 0, 20), Parent = xpRow })
	local xpBar = Components.ProgressBar.new({ Color = C.Aqua, Size = UDim2.new(1, -28, 0, 6), Position = UDim2.fromOffset(28, 24), Parent = xpRow })
	maid:Add(xpBar)
	-- Title shown under the name (unlocked by achievements).
	local titlePicker = AchievementController.CreateTitlePicker({ Size = UDim2.new(1, 0, 0, 44), Parent = detailsCard }, maid)
	titlePicker.LayoutOrder = 6

	local buildCard = card(right, SH.BuildStats, "Damage", 2)
	local healthValue = statRow(buildCard, "Health", S.Sheet.Health, 1, C.Health:Lerp(Color3.new(1, 1, 1), 0.25))
	local currentValue = statRow(buildCard, "CurrentDrop", S.Sheet.Current, 2, C.Current)
	local staminaValue = statRow(buildCard, "Stamina", S.Sheet.Stamina, 3, C.Stamina)
	local armorValue = statRow(buildCard, "Armor", S.Sheet.Armor, 4)
	local critValue = statRow(buildCard, "Crit", S.Sheet.Crit, 5)
	local damageValue = statRow(buildCard, "Damage", S.Sheet.WeaponDamage, 6)

	local allButton = Components.Button.new({
		Name = "ViewAllStats",
		Text = SH.ViewAll,
		Icon = "Info",
		TextSize = UITheme.TextSize.Small,
		Size = UDim2.new(1, 0, 0, 36),
		LayoutOrder = 3,
		Parent = right,
	})
	maid:Add(allButton)

	-- "View all stats": every bonus and unique effect, replacing the cards.
	local allStats: Frame = Create.new("Frame", { Name = "AllStats", BackgroundTransparency = 1, Size = UDim2.new(RIGHT_WIDTH, UDim.new(1, 0)), Position = UDim2.new(1 - RIGHT_WIDTH.Scale, 0, 0, 0), Visible = false, Parent = content })
	local allCard = card(allStats, SH.AllStats, "Info", 1)
	allCard.AutomaticSize = Enum.AutomaticSize.None
	allCard.Size = UDim2.new(1, 0, 1, -46)
	local allList = Components.ScrollList.new({ Name = "Bonuses", Spacing = 2, Size = UDim2.new(1, 0, 1, -34), LayoutOrder = 1, Parent = allCard })
	maid:Add(allList)
	local backButton = Components.Button.new({
		Name = "BackToSummary",
		Text = SH.BackToSummary,
		Icon = "ChevronLeft",
		TextSize = UITheme.TextSize.Small,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, 36),
		Parent = allStats,
	})
	maid:Add(backButton)
	local showingAll = false
	local function setShowingAll(value: boolean)
		showingAll = value
		allStats.Visible = value
		right.Visible = not value
		render()
		if Device.IsGamepad() then
			GuiService.SelectedObject = if value then backButton.Instance else allButton.Instance
		end
	end
	allButton.Activated:Connect(function()
		setShowingAll(true)
	end)
	backButton.Activated:Connect(function()
		setShowingAll(false)
	end)

	-- RENDER ----------------------------------------------------------------------------

	local function attunementChip(attunement: string, order: number)
		local info = Strings.Attunements[attunement]
		local color = UITheme.AttunementColor(attunement)
		local chip: Frame = Create.new("Frame", {
			Name = `Attunement_{attunement}`,
			BackgroundColor3 = color,
			BackgroundTransparency = 0.82,
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.fromOffset(0, 28),
			LayoutOrder = order,
			Parent = attunementRow,
		})
		Create.Corner(chip, UITheme.CornerPill)
		Create.Stroke(chip, color, 1, 0.35)
		Create.new("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 10), Parent = chip })
		Create.List(chip, Enum.FillDirection.Horizontal, 6, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)
		Icons.new(Icons.ForAttunement(attunement), { Size = UDim2.fromOffset(16, 16), Color = color, LayoutOrder = 1, Parent = chip })
		Create.Label({
			Text = if info then info.Name else attunement,
			Font = UITheme.Fonts.BodyBold,
			TextSize = UITheme.TextSize.Small,
			Color = color:Lerp(Color3.new(1, 1, 1), 0.35),
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.new(0, 0, 1, 0),
			LayoutOrder = 2,
			Parent = chip,
		})
	end

	local function renderAllStats(current: PlayerData, summary: GearStats.Summary)
		allList:Clear()
		local order = 0
		local function nextOrder(): number
			order += 1
			return order
		end
		local function heading(text: string)
			allList:Add(Create.Label({ Text = string.upper(text), Font = UITheme.Fonts.Title, TextSize = 15, Color = C.Accent, Size = UDim2.new(1, -6, 0, 26), LayoutOrder = nextOrder() }))
		end
		heading(S.Sheet.Bonuses)
		local ids = {}
		for id in summary.Bonuses do
			table.insert(ids, id)
		end
		table.sort(ids)
		if #ids == 0 then
			allList:Add(Create.Label({ Text = S.Sheet.NoBonuses, TextSize = UITheme.TextSize.Small, Color = C.TextDim, Wrapped = true, AutomaticSize = Enum.AutomaticSize.Y, Size = UDim2.new(1, -6, 0, 20), LayoutOrder = nextOrder() }))
		end
		for _, id in ids do
			local row: Frame = Create.new("Frame", { Name = id, BackgroundTransparency = 1, Size = UDim2.new(1, -6, 0, 24), LayoutOrder = nextOrder() })
			Icons.new(Icons.ForBonus(id), { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromScale(0, 0.5), Size = UDim2.fromOffset(16, 16), Color = C.Aqua, Parent = row })
			Create.Label({ Text = ItemText.AffixLine(id, summary.Bonuses[id]), TextSize = UITheme.TextSize.Small, Color = C.Text, Position = UDim2.fromOffset(24, 0), Size = UDim2.new(1, -24, 1, 0), Parent = row })
			allList:Add(row)
		end
		local uniques = {}
		for id in summary.Uniques do
			table.insert(uniques, id)
		end
		table.sort(uniques)
		if #uniques > 0 then
			heading(S.Sheet.Effects)
			for _, id in uniques do
				allList:Add(Create.Label({ Text = ItemText.UniqueName(id), Font = UITheme.Fonts.BodyBold, TextSize = UITheme.TextSize.Small, Color = UITheme.Rarity.Legendary, Size = UDim2.new(1, -6, 0, 22), LayoutOrder = nextOrder() }))
				allList:Add(Create.Label({ Text = ItemText.UniqueDescription(id), TextSize = UITheme.TextSize.Small, Color = C.TextMuted, Wrapped = true, AutomaticSize = Enum.AutomaticSize.Y, Size = UDim2.new(1, -6, 0, 20), LayoutOrder = nextOrder() }))
			end
		end
		-- Base attributes with their gear and skill parts, for completeness.
		heading(S.Sheet.Stats)
		for _, stat in GearStats.StatNames do
			local base = (current.Stats :: any)[stat] :: number
			local gear = summary.GearStats[stat] or 0
			local tree = summary.TreeStats[stat] or 0
			local row: Frame = Create.new("Frame", { Name = stat, BackgroundTransparency = 1, Size = UDim2.new(1, -6, 0, 24), LayoutOrder = nextOrder() })
			Icons.new(Icons.ForStat(stat), { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromScale(0, 0.5), Size = UDim2.fromOffset(16, 16), Color = C.Accent, Parent = row })
			Create.Label({ Text = S.StatNames[stat] or stat, TextSize = UITheme.TextSize.Small, Color = C.TextMuted, Position = UDim2.fromOffset(24, 0), Size = UDim2.new(0.5, -24, 1, 0), Parent = row })
			Create.Label({
				Text = Strings.Format(SH.StatBreakdown, { base = base, gear = gear, tree = tree, total = summary.Stats[stat] }),
				Font = UITheme.Fonts.BodyBold,
				TextSize = UITheme.TextSize.Caption,
				Color = C.Text,
				XAlignment = Enum.TextXAlignment.Right,
				Position = UDim2.fromScale(0.5, 0),
				Size = UDim2.new(0.5, 0, 1, 0),
				Parent = row,
			})
			allList:Add(row)
		end
	end

	function render()
		if not isOpen then
			return
		end
		local current = data()
		if not current then
			return
		end
		allocator:Refresh()
		local summary = GearStats.Summarize(current)
		local stats = summary.Stats
		local bonuses = summary.Bonuses

		-- Equipment.
		for slot, itemSlot in slots do
			if slot == "BeaconCore" then
				local core = Items.Get(current.Beacons.Skin)
				itemSlot:SetItem(if core then { Name = ItemText.Name(core.Id), Rarity = core.Rarity :: string, DefId = core.Id } else nil)
			else
				local item = GearStats.EquippedItem(current, slot)
				itemSlot:SetItem(if item then ItemText.Slot(item) else nil)
			end
		end

		-- Name plate: level and archetype under your name.
		local character = player.Character
		local class = character and character:GetAttribute("WeaponClass")
		local archetype = ProgressionRules.Archetype(current, if type(class) == "string" then class else nil)
		local archetypeName = Strings.Progression.Archetypes[archetype] or archetype
		subLabel.Text = `@{player.Name}  ·  {Strings.Format(S.Sheet.Level, { level = current.Level })}  ·  {archetypeName}`

		-- Details.
		levelValue.Text = `{current.Level}  <font color="#9DB2CA">{archetypeName}</font>`
		local position = Positions.Get(current.Position)
		if position then
			positionValue.Text = `<font color="#{position.Color:ToHex()}">{ProgressionText.PositionName(position.Id)}</font>  <font color="#9DB2CA">{Strings.Positions.Roles[position.Id] or ""}</font>`
		else
			positionValue.Text = `<font color="#62809F">{S.Sheet.NoPosition}</font>`
		end
		timeValue.Text = formatPlaytime(current.PlayStats.PlaySeconds)
		killsValue.Text = tostring(current.PlayStats.Kills)
		local capped = current.Level >= Config.Progression.LevelCap
		local needed = Formulas.XPToNext(current.Level)
		xpLabel.Text = if capped then Strings.HUD.XPMax else Strings.Format(Strings.Progression.XPTooltip, { xp = current.XP, next = needed, level = current.Level + 1 })
		xpBar:SetValue(if capped then 1 else current.XP, if capped then 1 else math.max(needed, 1))

		-- Build stats.
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local maxHealth = if humanoid then humanoid.MaxHealth else Formulas.MaxHealth(current.Level, stats.Vitality, bonuses.MaxHealth)
		healthValue.Text = tostring(math.floor(maxHealth))
		local maxCurrent = player:GetAttribute("MaxCurrent")
		currentValue.Text = tostring(math.floor(if type(maxCurrent) == "number" then maxCurrent else Formulas.MaxCurrent(current.Level, stats.Draw, bonuses.MaxCurrent)))
		local maxStamina = player:GetAttribute("MaxStamina")
		staminaValue.Text = tostring(math.floor(if type(maxStamina) == "number" then maxStamina else Formulas.MaxStamina(stats.Endurance, bonuses.MaxStamina)))
		armorValue.Text = string.format("%.1f%%", Formulas.DamageReduction(stats.Vitality, summary.Armor + (bonuses.Armor or 0)) * 100)
		critValue.Text = string.format("%.1f%%", (Formulas.CritChance(stats.Finesse) + (bonuses.CritChance or 0)) * 100)
		local weaponItem = GearStats.EquippedItem(current, "Weapon")
		local weaponDef = Items.GetWeapon(if weaponItem then weaponItem.DefId else Items.DefaultWeapon)
		if weaponDef then
			local copy = GearStats.Weapon(weaponDef, weaponItem)
			damageValue.Text = string.format("%.1f", copy.Damage * Formulas.WeaponScaling(stats.Strength, stats.Finesse, copy.Scaling) * (1 + (bonuses.WeaponDamage or 0)))
		else
			damageValue.Text = "-"
		end

		-- The Current.
		for _, child in attunementRow:GetChildren() do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
		local attunements = current.Attunements
		if attunements.Primary ~= "" then
			attunementChip(attunements.Primary, 1)
			if attunements.Secondary ~= "" then
				attunementChip(attunements.Secondary, 2)
			end
		else
			Create.Label({ Text = SH.NoAttunement, TextSize = UITheme.TextSize.Caption, Color = C.TextDim, Wrapped = true, Size = UDim2.new(1, 0, 1, 0), Parent = attunementRow })
		end
		regenValue.Text = Strings.Format(SH.PerSecond, { value = string.format("%.1f", Formulas.CurrentRegen(stats.Draw) * (1 + (bonuses.CurrentRegen or 0))) })
		powerValue.Text = string.format("+%d%%", math.floor((Formulas.SpellPower(stats.Density) * (1 + (bonuses.SpellDamage or 0)) - 1) * 100 + 0.5))
		castValue.Text = string.format("+%d%%", math.floor(((1 / Formulas.CastTime(stats.Control)) * (1 + (bonuses.CastSpeed or 0)) - 1) * 100 + 0.5))
		areaValue.Text = string.format("+%d%%", math.floor((Formulas.SpellArea(stats.Control) * (1 + (bonuses.SpellArea or 0)) - 1) * 100 + 0.5))

		if showingAll then
			renderAllStats(current, summary)
		end
	end

	maid:Add(StatDraft.Changed:Connect(function()
		render()
	end))
	-- A confirmed allocation empties the staged points.
	maid:Add(ProgressionController.Result:Connect(function(ok: boolean, action: string)
		if ok and (action == "Stats" or action == "Respec") then
			StatDraft.Clear()
		end
	end))
	for _, attribute in { "MaxCurrent", "MaxStamina", "WeaponClass" } do
		maid:Add(player:GetAttributeChangedSignal(attribute):Connect(render))
	end
	maid:Add(DataController.Changed:Connect(function(path: { string })
		local root = path[1]
		if
			root == "Inventory"
			or root == "Equipped"
			or root == "Stats"
			or root == "Level"
			or root == "Beacons"
			or root == "StatPoints"
			or root == "XP"
			or root == "Position"
			or root == "SkillTree"
			or root == "Attunements"
			or root == "PlayStats"
		then
			render()
			if root == "Equipped" and isOpen then
				-- The weapon model on your character is rebuilt by the server a moment later.
				task.delay(0.35, function()
					if isOpen then
						rebuildPreview()
					end
				end)
			end
		end
	end))

	return {
		OnOpen = function()
			isOpen = true
			Animator.SetPaused(MENU_ID, false)
			rebuildPreview()
			render()
		end,
		OnClose = function()
			isOpen = false
			Animator.SetPaused(MENU_ID, true)
			selectSlot(nil)
			if preview then
				preview:Destroy()
				preview = nil
			end
			-- Staged points survive switching tabs (the Skill Tree shows them
			-- too) but not closing the window.
			task.defer(function()
				if not UIController.IsMenuOpen() then
					StatDraft.Clear()
				end
			end)
		end,
	}
end

function CharacterSheetController.Init()
	UIController.RegisterMenu({
		Id = MENU_ID,
		Title = S.CharacterTitle,
		Action = "OpenCharacter",
		FullScreen = true,
		ShowInHub = true,
		Icon = "Character",
		Nav = "Journal",
		Build = build,
	})
end

return CharacterSheetController
