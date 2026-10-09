--!strict
--[[
	Dropdown
	Shows the selected option; clicking opens an option list on the Overlay
	layer (so it is never clipped by scrolling menus). Clicking outside,
	Backspace or gamepad B closes it.
]]

local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local UI = script.Parent.Parent
local UITheme = require(UI.UITheme)
local Create = require(UI.Create)
local Layers = require(UI.Layers)
local Motion = require(UI.Motion)
local Device = require(UI.Device)
local UISound = require(UI.UISound)
local Modal = require(script.Parent.Modal)
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Maid = require(Shared.Util.Maid)
local Signal = require(Shared.Util.Signal)

export type Option = {
	Id: string,
	Text: string,
}

export type DropdownProps = {
	Options: { Option },
	Selected: string,
	Size: UDim2?,
	Position: UDim2?,
	LayoutOrder: number?,
	Parent: Instance?,
}

export type Dropdown = {
	Instance: TextButton,
	Changed: Signal.Signal<string>,
	Maid: Maid.Maid,
	GetSelected: (self: Dropdown) -> string,
	SetSelected: (self: Dropdown, id: string, silent: boolean?) -> (),
	Close: (self: Dropdown) -> (),
	Destroy: (self: Dropdown) -> (),
}

local OPTION_HEIGHT = 36

local Dropdown = {}

local function drawChevron(parent: Instance): Frame
	local holder: Frame = Create.new("Frame", {
		Name = "Chevron",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -12, 0.5, 2),
		Size = UDim2.fromOffset(12, 8),
		Parent = parent,
	})
	for _, side in { -1, 1 } do
		Create.new("Frame", {
			BackgroundColor3 = UITheme.Colors.TextMuted,
			BorderSizePixel = 0,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, side * 3, 0, 0),
			Size = UDim2.fromOffset(8, 2),
			Rotation = side * -40,
			Parent = holder,
		})
	end
	return holder
end

-- AbsolutePosition is measured below the top-bar inset; the Overlay layer
-- ignores the inset, so add it back to land exactly under the button.
local function screenPosition(target: GuiObject): Vector2
	return target.AbsolutePosition + GuiService:GetGuiInset()
end

function Dropdown.new(props: DropdownProps): Dropdown
	assert(#props.Options > 0, "Dropdown needs options")
	local maid = Maid.new()
	local listMaid = Maid.new()
	maid:Add(listMaid)
	local changed = Signal.new() :: Signal.Signal<string>
	maid:Add(changed)
	local selected = props.Selected
	local isOpen = false

	local function textFor(id: string): string
		for _, option in props.Options do
			if option.Id == id then
				return option.Text
			end
		end
		return id
	end

	local button: TextButton = Create.new("TextButton", {
		Name = "Dropdown",
		Text = textFor(selected),
		FontFace = UITheme.Fonts.BodyMedium,
		TextSize = UITheme.TextSize.Body,
		TextColor3 = UITheme.Colors.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		BackgroundColor3 = UITheme.Colors.PanelSunken,
		BackgroundTransparency = UITheme.SunkenTransparency,
		AutoButtonColor = false,
		Size = props.Size or UDim2.fromOffset(200, UITheme.Size.InputHeight),
		Position = props.Position or UDim2.new(),
		LayoutOrder = props.LayoutOrder or 0,
		SelectionImageObject = Create.SelectionImage(),
	})
	Create.Corner(button)
	Create.Stroke(button)
	Create.new("UIPadding", { PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 30), Parent = button })
	local chevron = drawChevron(button)
	chevron.Position = UDim2.new(1, 18, 0.5, 2)
	maid:Add(button)
	maid:Add(Motion.AttachButtonFeedback(button))

	local self = {
		Instance = button,
		Changed = changed,
		Maid = maid,
	}

	function self.GetSelected(_self: Dropdown): string
		return selected
	end

	function self.SetSelected(_self: Dropdown, id: string, silent: boolean?)
		selected = id
		button.Text = textFor(id)
		if not silent then
			changed:Fire(id)
		end
	end

	function self.Close(_self: Dropdown)
		if not isOpen then
			return
		end
		isOpen = false
		listMaid:Clean()
		if Device.IsGamepad() then
			GuiService.SelectedObject = button
		end
	end

	local function open()
		if isOpen then
			self.Close(self :: any)
			return
		end
		isOpen = true
		local layer = Layers.Get("Overlay")
		local layerScale = Layers.GetScale("Overlay")

		-- Full-screen catcher closes the list when clicking elsewhere.
		local catcher: TextButton = listMaid:Add(Create.new("TextButton", {
			Name = "DropdownCatcher",
			Text = "",
			BackgroundTransparency = 1,
			Selectable = false,
			Size = UDim2.fromScale(1, 1),
			ZIndex = 60,
			Parent = layer,
		}))
		listMaid:Add(catcher.Activated:Connect(function()
			self.Close(self :: any)
		end))

		local origin = screenPosition(button) / layerScale
		local width = button.AbsoluteSize.X / layerScale
		local height = button.AbsoluteSize.Y / layerScale
		local list: Frame = listMaid:Add(Create.new("Frame", {
			Name = "DropdownList",
			Position = UDim2.fromOffset(origin.X, origin.Y + height + 4),
			Size = UDim2.fromOffset(width, #props.Options * (OPTION_HEIGHT + 2) + 8),
			ZIndex = 61,
			SelectionGroup = true,
			SelectionBehaviorUp = Enum.SelectionBehavior.Stop,
			SelectionBehaviorDown = Enum.SelectionBehavior.Stop,
			Parent = layer,
		}))
		Create.ApplyPanelStyle(list, { Glow = false, Transparency = 0.04 })
		Create.Padding(list, 4)
		Create.List(list, Enum.FillDirection.Vertical, 2)

		local firstOption: TextButton? = nil
		for index, option in props.Options do
			local isSelected = option.Id == selected
			local item: TextButton = Create.new("TextButton", {
				Name = option.Id,
				Text = option.Text,
				FontFace = if isSelected then UITheme.Fonts.BodyBold else UITheme.Fonts.Body,
				TextSize = UITheme.TextSize.Body,
				TextColor3 = if isSelected then UITheme.Colors.Current else UITheme.Colors.Text,
				TextXAlignment = Enum.TextXAlignment.Left,
				BackgroundColor3 = UITheme.Colors.PanelHover,
				BackgroundTransparency = 1,
				AutoButtonColor = false,
				Size = UDim2.new(1, 0, 0, OPTION_HEIGHT),
				LayoutOrder = index,
				ZIndex = 62,
				SelectionImageObject = Create.SelectionImage(),
				Parent = list,
			})
			Create.Corner(item, UITheme.CornerSmall)
			Create.new("UIPadding", { PaddingLeft = UDim.new(0, 10), Parent = item })
			listMaid:Add(item.MouseEnter:Connect(function()
				item.BackgroundTransparency = 0.2
			end))
			listMaid:Add(item.MouseLeave:Connect(function()
				item.BackgroundTransparency = 1
			end))
			local id = option.Id
			listMaid:Add(item.Activated:Connect(function()
				UISound.Play("UIClick")
				self.Close(self :: any)
				if id ~= selected then
					self.SetSelected(self :: any, id)
				end
			end))
			if isSelected or not firstOption then
				firstOption = item
			end
		end

		listMaid:Add(UserInputService.InputBegan:Connect(function(input: InputObject)
			if input.KeyCode == Enum.KeyCode.ButtonB or input.KeyCode == Enum.KeyCode.Backspace then
				Modal.NoteBackConsumed()
				self.Close(self :: any)
			end
		end))

		if Device.IsGamepad() and firstOption then
			GuiService.SelectedObject = firstOption
		end
	end

	maid:Add(button.Activated:Connect(function()
		UISound.Play("UIClick")
		open()
	end))

	function self.Destroy(_self: Dropdown)
		maid:Clean()
	end

	button.Parent = props.Parent
	return self :: Dropdown
end

return Dropdown
