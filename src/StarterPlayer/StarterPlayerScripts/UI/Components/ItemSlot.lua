--!strict
--[[
	ItemSlot
	A square inventory/equipment slot. The border and bottom wash take the
	item's rarity colour (Terraria-style); Mythic borders rotate a two-tone
	gradient and Spire-Forged borders shimmer like flowing Current.
	Shows the item (a 3D render via ItemIcon when DefId is set, an uploaded
	Icon image, or name initials), stack count, upgrade level, lock and
	"new" markers. Right-click or a touch long-press fires SecondaryActivated
	(context menus); a broken item's slot is tinted red.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UI = script.Parent.Parent
local UITheme = require(UI.UITheme)
local Create = require(UI.Create)
local Motion = require(UI.Motion)
local Animator = require(UI.Animator)
local ItemIcon = require(UI.ItemIcon)
local UISound = require(UI.UISound)
local Icons = require(UI.Icons)
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Maid = require(Shared.Util.Maid)
local Signal = require(Shared.Util.Signal)
local MathUtil = require(Shared.Util.MathUtil)

export type SlotItem = {
	Name: string,
	Rarity: string,
	DefId: string?, -- shows a 3D render of the item (ItemIcon)
	Icon: string?,
	Broken: boolean?,
	Count: number?,
	Upgrade: number?,
	Locked: boolean?,
	New: boolean?,
}

export type ItemSlotProps = {
	Size: number?,
	Placeholder: string?, -- icon shown faintly while the slot is empty (equipment category)
	Position: UDim2?,
	AnchorPoint: Vector2?,
	LayoutOrder: number?,
	Name: string?,
	Parent: Instance?,
}

export type ItemSlot = {
	Instance: TextButton,
	Activated: Signal.Signal<>,
	SecondaryActivated: Signal.Signal<>,
	Maid: Maid.Maid,
	SetItem: (self: ItemSlot, item: SlotItem?) -> (),
	GetItem: (self: ItemSlot) -> SlotItem?,
	SetSelected: (self: ItemSlot, selected: boolean) -> (),
	Destroy: (self: ItemSlot) -> (),
}

local LONG_PRESS = 0.45

local ItemSlot = {}

-- "Tidewrought Longsword" -> "TL"
local function initials(name: string): string
	local letters = {}
	for word in string.gmatch(name, "%a+") do
		table.insert(letters, string.upper(string.sub(word, 1, 1)))
		if #letters == 2 then
			break
		end
	end
	return table.concat(letters)
end

local function buildLock(parent: Instance): ImageLabel
	local lock = Icons.new("Lock", {
		Name = "Lock",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -3, 0, 3),
		Size = UDim2.fromOffset(14, 14),
		Color = UITheme.Colors.Accent,
		ZIndex = 4,
		Parent = parent,
	})
	lock.Visible = false
	return lock
end

function ItemSlot.new(props: ItemSlotProps): ItemSlot
	local maid = Maid.new()
	local size = props.Size or UITheme.Size.Slot
	local currentItem: SlotItem? = nil
	local effectMaid = Maid.new()
	maid:Add(effectMaid)

	local button: TextButton = Create.new("TextButton", {
		Name = props.Name or "ItemSlot",
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = UITheme.Colors.PanelSunken,
		BackgroundTransparency = UITheme.SunkenTransparency,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(size, size),
		Position = props.Position or UDim2.new(),
		AnchorPoint = props.AnchorPoint or Vector2.zero,
		LayoutOrder = props.LayoutOrder or 0,
		SelectionImageObject = Create.SelectionImage(),
	})
	Create.Corner(button, UITheme.CornerSmall)
	local stroke = Create.Stroke(button, UITheme.Colors.Edge, 1.5, 0.25)
	-- Faint category icon (helmet, gauntlet...) while the slot is empty.
	local placeholder = Icons.new(props.Placeholder or "Inventory", {
		Name = "Placeholder",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.52, 0.52),
		Color = UITheme.Colors.EdgeBright,
		Transparency = 0.55,
		Parent = button,
	})
	placeholder.Visible = props.Placeholder ~= nil
	maid:Add(button)
	maid:Add(Motion.AttachButtonFeedback(button))

	-- Rarity wash rising from the bottom of the slot.
	local wash: Frame = Create.new("Frame", {
		Name = "Wash",
		BackgroundColor3 = UITheme.Rarity.Common,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		Parent = button,
	})
	Create.Corner(wash, UITheme.CornerSmall)
	Create.new("UIGradient", {
		Rotation = -90,
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.6),
			NumberSequenceKeypoint.new(0.55, 0.92),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Parent = wash,
	})

	local icon: ImageLabel = Create.new("ImageLabel", {
		Name = "Icon",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.78, 0.78),
		ScaleType = Enum.ScaleType.Fit,
		ZIndex = 2,
		Visible = false,
		Parent = button,
	})

	local render: ItemIcon.ItemIcon? = nil

	local glyph: TextLabel = Create.Label({
		Name = "Glyph",
		Text = "",
		Font = UITheme.Fonts.Title,
		TextSize = math.floor(size * 0.36),
		XAlignment = Enum.TextXAlignment.Center,
		Size = UDim2.fromScale(1, 1),
		Parent = button,
	})
	glyph.ZIndex = 2

	local count: TextLabel = Create.Label({
		Name = "Count",
		Text = "",
		Font = UITheme.Fonts.Numbers,
		TextSize = UITheme.TextSize.Small,
		XAlignment = Enum.TextXAlignment.Right,
		YAlignment = Enum.TextYAlignment.Bottom,
		Size = UDim2.new(1, -5, 1, -3),
		Parent = button,
	})
	count.ZIndex = 3
	count.TextStrokeTransparency = 0.35

	local upgrade: TextLabel = Create.Label({
		Name = "Upgrade",
		Text = "",
		Font = UITheme.Fonts.Numbers,
		TextSize = UITheme.TextSize.Caption,
		Color = UITheme.Colors.Parry,
		YAlignment = Enum.TextYAlignment.Top,
		Position = UDim2.fromOffset(5, 3),
		Size = UDim2.new(1, -5, 0, 16),
		Parent = button,
	})
	upgrade.ZIndex = 3
	upgrade.TextStrokeTransparency = 0.35

	local lock = buildLock(button)

	local newDot: Frame = Create.new("Frame", {
		Name = "NewDot",
		BackgroundColor3 = UITheme.Colors.Current,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -5, 0, 5),
		Size = UDim2.fromOffset(8, 8),
		Visible = false,
		ZIndex = 4,
		Parent = button,
	})
	Create.Corner(newDot, UITheme.CornerPill)

	local selectedRing: Frame = Create.new("Frame", {
		Name = "SelectedRing",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 6, 1, 6),
		Position = UDim2.fromOffset(-3, -3),
		Visible = false,
		ZIndex = 5,
		Parent = button,
	})
	Create.Corner(selectedRing, UDim.new(0, 9))
	Create.Stroke(selectedRing, UITheme.Colors.Foam, 2, 0)

	-- Hover on an empty slot: its edge and category icon brighten.
	maid:Add(button.MouseEnter:Connect(function()
		if not currentItem then
			stroke.Color = UITheme.Colors.EdgeBright
			stroke.Transparency = 0
			placeholder.ImageTransparency = 0.25
		end
	end))
	maid:Add(button.MouseLeave:Connect(function()
		if not currentItem then
			stroke.Color = UITheme.Colors.Edge
			stroke.Transparency = 0.25
			placeholder.ImageTransparency = 0.55
		end
	end))

	local activated = Signal.new() :: Signal.Signal<>
	local secondary = Signal.new() :: Signal.Signal<>
	maid:Add(activated)
	maid:Add(secondary)
	maid:Add(button.Activated:Connect(function()
		UISound.Play("UIClick")
		activated:Fire()
	end))
	maid:Add(button.MouseButton2Click:Connect(function()
		secondary:Fire()
	end))
	-- Touch: hold to open the context menu (a short tap still activates).
	local pressToken = 0
	maid:Add(button.InputBegan:Connect(function(input: InputObject)
		if input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end
		pressToken += 1
		local token = pressToken
		task.delay(LONG_PRESS, function()
			if token == pressToken and input.UserInputState ~= Enum.UserInputState.End then
				pressToken += 1
				secondary:Fire()
			end
		end)
	end))
	maid:Add(button.InputEnded:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.Touch then
			pressToken += 1
		end
	end))

	local brokenTint: Frame = Create.new("Frame", {
		Name = "Broken",
		BackgroundColor3 = UITheme.Colors.Danger,
		BackgroundTransparency = 0.72,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		ZIndex = 3,
		Parent = button,
	})
	Create.Corner(brokenTint, UITheme.CornerSmall)

	local function applyRarityEffect(rarity: string)
		effectMaid:Clean()
		local color = UITheme.RarityColor(rarity)
		stroke.Color = color
		stroke.Transparency = 0.1
		wash.BackgroundColor3 = color
		local accent = UITheme.RarityAccent[rarity]
		if accent then
			-- Animated border: white stroke tinted by a moving two-colour gradient.
			stroke.Color = Color3.new(1, 1, 1)
			local gradient: UIGradient = effectMaid:Add(Create.new("UIGradient", {
				Color = ColorSequence.new({
					ColorSequenceKeypoint.new(0, color),
					ColorSequenceKeypoint.new(0.5, accent),
					ColorSequenceKeypoint.new(1, color),
				}),
				Parent = stroke,
			}))
			if rarity == "Mythic" then
				effectMaid:Add(Animator.Spin(gradient, 120))
			else
				effectMaid:Add(Animator.Flow(gradient, UITheme.Motion.ShimmerSpeed))
			end
			effectMaid:Add(function()
				stroke.Color = color
			end)
		end
	end

	local self = {
		Instance = button,
		Activated = activated,
		SecondaryActivated = secondary,
		Maid = maid,
	}

	function self.SetItem(_self: ItemSlot, item: SlotItem?)
		currentItem = item
		if not item then
			effectMaid:Clean()
			stroke.Color = UITheme.Colors.Edge
			stroke.Transparency = 0.25
			placeholder.Visible = props.Placeholder ~= nil
			wash.Visible = false
			icon.Visible = false
			if render then
				render:Set(nil)
			end
			brokenTint.Visible = false
			glyph.Text = ""
			count.Text = ""
			upgrade.Text = ""
			lock.Visible = false
			newDot.Visible = false
			return
		end
		applyRarityEffect(item.Rarity)
		placeholder.Visible = false
		wash.Visible = true
		local hasIcon = item.Icon ~= nil and item.Icon ~= ""
		icon.Visible = hasIcon
		icon.Image = item.Icon or ""
		local hasModel = not hasIcon and item.DefId ~= nil
		if hasModel then
			if not render then
				render = ItemIcon.new({
					Size = UDim2.fromScale(0.86, 0.86),
					Position = UDim2.fromScale(0.5, 0.5),
					AnchorPoint = Vector2.new(0.5, 0.5),
					Parent = button,
				})
				maid:Add(function()
					if render then
						render:Destroy()
					end
				end)
			end
			(render :: ItemIcon.ItemIcon):Set(item.DefId, item.Rarity)
		elseif render then
			render:Set(nil)
		end
		brokenTint.Visible = item.Broken == true
		glyph.Text = if hasIcon or hasModel then "" else initials(item.Name)
		glyph.TextColor3 = UITheme.RarityColor(item.Rarity)
		local stack = item.Count or 1
		count.Text = if stack > 1 then MathUtil.FormatNumber(stack, true) else ""
		local level = item.Upgrade or 0
		upgrade.Text = if level > 0 then `+{level}` else ""
		lock.Visible = item.Locked == true
		newDot.Visible = item.New == true and item.Locked ~= true
	end

	function self.GetItem(_self: ItemSlot): SlotItem?
		return currentItem
	end

	function self.SetSelected(_self: ItemSlot, selected: boolean)
		selectedRing.Visible = selected
	end

	function self.Destroy(_self: ItemSlot)
		maid:Clean()
	end

	button.Parent = props.Parent
	return self :: ItemSlot
end

return ItemSlot
