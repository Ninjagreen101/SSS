--!strict
--[[
	Modal
	A centred dialog on the Modal layer: dims and blurs the world, animates
	open/close, traps gamepad selection inside itself and closes with the
	close button, Backspace or gamepad B (only the top-most modal reacts).
]]

local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local UI = script.Parent.Parent
local UITheme = require(UI.UITheme)
local Create = require(UI.Create)
local Layers = require(UI.Layers)
local Motion = require(UI.Motion)
local Blur = require(UI.Blur)
local Device = require(UI.Device)
local UISound = require(UI.UISound)
local IconButton = require(script.Parent.IconButton)
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Maid = require(Shared.Util.Maid)
local Signal = require(Shared.Util.Signal)
local Strings = require(Shared.Strings)
local TweenUtil = require(Shared.Util.TweenUtil)

export type ModalProps = {
	Title: string,
	Size: UDim2?,
	Dismissable: boolean?, -- backdrop click / back button closes (default true)
	ShowClose: boolean?, -- show the X button (default true)
}

export type Modal = {
	Instance: Frame,
	Content: Frame,
	Closed: Signal.Signal<>,
	Maid: Maid.Maid,
	Open: (self: Modal) -> (),
	Close: (self: Modal) -> (),
	IsOpen: (self: Modal) -> boolean,
	Destroy: (self: Modal) -> (),
}

local Modal = {}

local stack: { Modal } = {}
local lastBackConsumed = 0

function Modal.IsAnyOpen(): boolean
	return #stack > 0
end

-- True while a modal is open, or for a moment after a modal/popup used the
-- back button, so the same press doesn't also close the menu underneath.
function Modal.IsBlockingBack(): boolean
	return #stack > 0 or os.clock() - lastBackConsumed < 0.2
end

function Modal.NoteBackConsumed()
	lastBackConsumed = os.clock()
end

local function firstSelectable(root: Instance): GuiObject?
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("GuiObject") and descendant.Selectable and descendant.Visible then
			return descendant
		end
	end
	return nil
end

function Modal.new(props: ModalProps): Modal
	local maid = Maid.new()
	local closed = Signal.new() :: Signal.Signal<>
	maid:Add(closed)
	local dismissable = if props.Dismissable == nil then true else props.Dismissable
	local isOpen = false
	local closing = false

	local root: Frame = Create.new("Frame", {
		Name = "Modal",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		Parent = Layers.Get("Modal"),
	})
	maid:Add(root)

	local backdrop: TextButton = Create.new("TextButton", {
		Name = "Backdrop",
		Text = "",
		AutoButtonColor = false,
		Selectable = false,
		BackgroundColor3 = UITheme.Colors.Overlay,
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = root,
	})

	local group: CanvasGroup = Create.new("CanvasGroup", {
		Name = "Window",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = props.Size or UDim2.fromOffset(460, 260),
		GroupTransparency = 1,
		SelectionGroup = true,
		SelectionBehaviorUp = Enum.SelectionBehavior.Stop,
		SelectionBehaviorDown = Enum.SelectionBehavior.Stop,
		SelectionBehaviorLeft = Enum.SelectionBehavior.Stop,
		SelectionBehaviorRight = Enum.SelectionBehavior.Stop,
		Parent = root,
	})
	local scale: UIScale = Create.new("UIScale", { Parent = group })

	-- Inset so the panel's outer stroke isn't clipped by the CanvasGroup.
	local panel: Frame = Create.new("Frame", {
		Name = "Panel",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, -4, 1, -4),
		Parent = group,
	})
	Create.ApplyPanelStyle(panel, { Transparency = 0.05 })
	Create.Padding(panel, UITheme.Padding.Large)

	Create.Label({
		Name = "Title",
		Text = props.Title,
		Font = UITheme.Fonts.Title,
		TextSize = UITheme.TextSize.Heading,
		Size = UDim2.new(1, -44, 0, 30),
		Parent = panel,
	})
	Create.new("Frame", {
		Name = "Divider",
		BackgroundColor3 = UITheme.Colors.Edge,
		BackgroundTransparency = 0.3,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(0, 38),
		Size = UDim2.new(1, 0, 0, 1),
		Parent = panel,
	})
	local content: Frame = Create.new("Frame", {
		Name = "Content",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 50),
		Size = UDim2.new(1, 0, 1, -50),
		Parent = panel,
	})

	local self = {
		Instance = root,
		Content = content,
		Closed = closed,
		Maid = maid,
	}

	function self.IsOpen(_self: Modal): boolean
		return isOpen
	end

	function self.Close(_self: Modal)
		if not isOpen or closing then
			return
		end
		closing = true
		local index = table.find(stack, self :: any)
		if index then
			table.remove(stack, index)
		end
		maid:Set("blur", nil)
		maid:Set("input", nil)
		UISound.Play("UIClose")
		task.spawn(function()
			TweenUtil.Play(backdrop, UITheme.Motion.CloseTime, { BackgroundTransparency = 1 })
			Motion.Close(group, scale)
			root.Visible = false
			isOpen = false
			closing = false
			if GuiService.SelectedObject and GuiService.SelectedObject:IsDescendantOf(root) then
				GuiService.SelectedObject = nil
			end
			closed:Fire()
		end)
	end

	function self.Open(_self: Modal)
		if isOpen then
			return
		end
		isOpen = true
		table.insert(stack, self :: any)
		root.Visible = true
		maid:Set("blur", Blur.Push())
		UISound.Play("UIOpen")
		TweenUtil.Play(backdrop, UITheme.Motion.OpenTime, { BackgroundTransparency = UITheme.OverlayTransparency })
		Motion.Open(group, scale)
		if Device.IsGamepad() then
			local target = firstSelectable(content) or firstSelectable(group)
			if target then
				GuiService.SelectedObject = target
			end
		end
		maid:Set("input", UserInputService.InputBegan:Connect(function(input: InputObject)
			if stack[#stack] ~= (self :: any) or not dismissable then
				return
			end
			if input.KeyCode == Enum.KeyCode.ButtonB or input.KeyCode == Enum.KeyCode.Backspace then
				if UserInputService:GetFocusedTextBox() == nil then
					lastBackConsumed = os.clock()
					self.Close(self :: any)
				end
			end
		end))
	end

	function self.Destroy(_self: Modal)
		local index = table.find(stack, self :: any)
		if index then
			table.remove(stack, index)
		end
		maid:Clean()
	end

	if dismissable then
		maid:Add(backdrop.Activated:Connect(function()
			self.Close(self :: any)
		end))
	end

	if props.ShowClose ~= false then
		local closeButton = IconButton.new({
			Name = "Close",
			Glyph = "×",
			Size = 32,
			Tooltip = Strings.UI.Close,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, 0, 0, 0),
			Parent = panel,
			OnActivated = function()
				self.Close(self :: any)
			end,
		})
		maid:Add(closeButton)
	end

	return self :: Modal
end

return Modal
