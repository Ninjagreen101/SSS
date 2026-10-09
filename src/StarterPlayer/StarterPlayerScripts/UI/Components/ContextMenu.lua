--!strict
--[[
	ContextMenu
	A small floating list of actions for an item (right-click, touch
	long-press, or gamepad Y on a slot). Opens beside the anchor (or at the
	cursor), stays on screen, closes on any choice, a click outside, or Back.
	Only one is ever open.
]]

local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local UI = script.Parent.Parent
local UITheme = require(UI.UITheme)
local Create = require(UI.Create)
local Layers = require(UI.Layers)
local UISound = require(UI.UISound)
local Maid = require(ReplicatedStorage:WaitForChild("Shared").Util.Maid)

export type Option = {
	Text: string,
	Danger: boolean?,
	Enabled: boolean?, -- false shows it greyed out
	OnSelect: () -> (),
}

export type ShowProps = {
	Title: string?,
	TitleColor: Color3?,
	Options: { Option },
	Anchor: GuiObject?, -- open beside this; otherwise at the mouse
}

local ROW_HEIGHT = 36
local WIDTH = 220

local ContextMenu = {}

local openMaid = Maid.new()
local isOpen = false

function ContextMenu.IsOpen(): boolean
	return isOpen
end

function ContextMenu.Close()
	if not isOpen then
		return
	end
	isOpen = false
	openMaid:Clean()
end

function ContextMenu.Show(props: ShowProps)
	ContextMenu.Close()
	if #props.Options == 0 then
		return
	end
	isOpen = true
	local layer = Layers.Get("Modal")

	-- Full-screen catcher: a click anywhere else closes the menu.
	local catcher: TextButton = Create.new("TextButton", {
		Name = "ContextMenuCatcher",
		Text = "",
		BackgroundTransparency = 1,
		AutoButtonColor = false,
		Selectable = false,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 60,
		Parent = layer,
	})
	openMaid:Add(catcher)
	openMaid:Add(catcher.Activated:Connect(ContextMenu.Close))
	openMaid:Add(catcher.MouseButton2Click:Connect(ContextMenu.Close))

	local hasTitle = props.Title ~= nil
	local height = #props.Options * (ROW_HEIGHT + 2) + UITheme.Padding.Small * 2 + (if hasTitle then 28 else 0)
	local panel: Frame = Create.new("Frame", {
		Name = "ContextMenu",
		Size = UDim2.fromOffset(WIDTH, height),
		ZIndex = 61,
		Parent = layer,
	})
	Create.ApplyPanelStyle(panel, { Glow = false, Transparency = 0.04 })
	Create.Padding(panel, UITheme.Padding.Small)
	Create.List(panel, Enum.FillDirection.Vertical, 2)
	openMaid:Add(panel)

	if props.Title then
		local title = Create.Label({
			Text = props.Title,
			Font = UITheme.Fonts.BodyBold,
			TextSize = UITheme.TextSize.Small,
			Color = props.TitleColor or UITheme.Colors.Text,
			Size = UDim2.new(1, 0, 0, 26),
			Parent = panel,
		})
		title.ZIndex = 62
		title.TextTruncate = Enum.TextTruncate.AtEnd
	end

	local first: GuiObject? = nil
	for index, option in props.Options do
		local enabled = option.Enabled ~= false
		local row: TextButton = Create.new("TextButton", {
			Name = `Option{index}`,
			Text = option.Text,
			FontFace = UITheme.Fonts.BodyMedium,
			TextSize = UITheme.TextSize.Body,
			TextColor3 = if not enabled
				then UITheme.Colors.TextDim
				elseif option.Danger then UITheme.Colors.Danger
				else UITheme.Colors.Text,
			TextXAlignment = Enum.TextXAlignment.Left,
			BackgroundColor3 = UITheme.Colors.PanelHover,
			BackgroundTransparency = 1,
			AutoButtonColor = false,
			Active = enabled,
			Selectable = enabled,
			Size = UDim2.new(1, 0, 0, ROW_HEIGHT),
			LayoutOrder = index,
			ZIndex = 62,
			SelectionImageObject = Create.SelectionImage(),
			Parent = panel,
		})
		Create.Corner(row, UITheme.CornerSmall)
		Create.Padding(row, 0, UITheme.Padding.Small, 0)
		openMaid:Add(row.MouseEnter:Connect(function()
			row.BackgroundTransparency = if enabled then 0.2 else 1
		end))
		openMaid:Add(row.MouseLeave:Connect(function()
			row.BackgroundTransparency = 1
		end))
		openMaid:Add(row.Activated:Connect(function()
			if not enabled then
				return
			end
			UISound.Play("UIClick")
			ContextMenu.Close()
			option.OnSelect()
		end))
		if enabled and not first then
			first = row
		end
	end

	-- Position: right of the anchor (or the mouse), clamped to the screen.
	local scale = Layers.GetScale("Modal")
	local screen = layer.AbsoluteSize / scale
	local x, y
	local anchor = props.Anchor
	if anchor and anchor.Parent then
		-- AbsolutePosition is measured below the top-bar inset even in layers
		-- that ignore it, while the Modal layer's offsets start at the very top
		-- of the screen: add the inset back, then divide by the UIScale.
		local position = (anchor.AbsolutePosition + GuiService:GetGuiInset()) / scale
		x = position.X + anchor.AbsoluteSize.X / scale + 6
		y = position.Y
		if x + WIDTH > screen.X - 8 then
			x = position.X - WIDTH - 6
		end
	else
		local mouse = UserInputService:GetMouseLocation() / scale
		x, y = mouse.X + 4, mouse.Y + 4
	end
	x = math.clamp(x, 8, math.max(8, screen.X - WIDTH - 8))
	y = math.clamp(y, 8, math.max(8, screen.Y - height - 8))
	panel.Position = UDim2.fromOffset(x, y)

	if first and UserInputService.GamepadEnabled then
		GuiService.SelectedObject = first
	end
	openMaid:Add(UserInputService.InputBegan:Connect(function(input: InputObject)
		if input.KeyCode == Enum.KeyCode.ButtonB or input.KeyCode == Enum.KeyCode.Escape or input.KeyCode == Enum.KeyCode.Backspace then
			ContextMenu.Close()
		end
	end))
end

return ContextMenu
