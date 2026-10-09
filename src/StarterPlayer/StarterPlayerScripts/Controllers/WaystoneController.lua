--!strict
-- WaystoneController: the fast-travel panel opened at a Waystone. Lists the
-- floor's Waystones in order: attuned ones with a Travel button, the one you
-- stand at marked "You are here", undiscovered ones greyed out. Works with
-- mouse, touch (full-width on phones) and gamepad (selection starts on the
-- first travel button; B closes).

local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Theme = require(Shared.UI.Theme)
local Components = require(Shared.UI.Components)
local Strings = require(Shared.Strings)
local Floors = require(Shared.Data.Floors)
local Net = require(Shared.Net)
local Maid = require(Shared.Util.Maid)

local WaystoneController = {}

local gui: ScreenGui
local panel: Frame
local list: ScrollingFrame
local blur: BlurEffect
local maid = Maid.new()
local isOpen = false
local discoveredCache: { string } = {}

local CLOSE_ACTION = "WaystonePanelClose"

local function isPhone(): boolean
	return UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
end

local function close()
	if not isOpen then
		return
	end
	isOpen = false
	maid:Clean()
	ContextActionService:UnbindAction(CLOSE_ACTION)
	GuiService.SelectedObject = nil
	TweenService:Create(blur, Theme.Tween.Close, { Size = 0 }):Play()
	Components.close(panel)
end

local function row(order: number, nameKey: string, id: string, state: string): Frame
	local r = Instance.new("Frame")
	r.Name = id
	r.LayoutOrder = order
	r.Size = UDim2.new(1, 0, 0, 52)
	r.BackgroundColor3 = Theme.Colors.Surface
	r.BackgroundTransparency = if state == "locked" then 0.6 else 0.2
	local c = Instance.new("UICorner")
	c.CornerRadius = Theme.CornerSmall
	c.Parent = r
	local dot = Instance.new("Frame")
	dot.Size = UDim2.fromOffset(10, 10)
	dot.Position = UDim2.new(0, 14, 0.5, -5)
	dot.BackgroundColor3 = if state == "locked" then Theme.Colors.TextDim else Theme.Colors.Current
	dot.BorderSizePixel = 0
	dot.Parent = r
	local dc = Instance.new("UICorner")
	dc.CornerRadius = UDim.new(1, 0)
	dc.Parent = dot
	Components.label({
		name = "Name",
		text = if state == "locked" then Strings.get("Waystone.Panel.Locked") else Strings.get(nameKey),
		font = Theme.Fonts.BodyBold,
		size = Theme.TextSize.Heading,
		color = if state == "locked" then Theme.Colors.TextDim else Theme.Colors.Text,
		frame = UDim2.new(1, -170, 1, 0),
		position = UDim2.fromOffset(34, 0),
		parent = r,
	})
	if state == "here" then
		Components.label({
			name = "Here",
			text = Strings.get("Waystone.Panel.Here"),
			font = Theme.Fonts.Body,
			size = Theme.TextSize.Small,
			color = Theme.Colors.Current,
			frame = UDim2.new(0, 120, 1, 0),
			position = UDim2.new(1, -130, 0, 0),
			alignX = Enum.TextXAlignment.Right,
			parent = r,
		})
	end
	return r
end

local function open(currentId: string, discovered: { string })
	discoveredCache = discovered
	if isOpen then
		maid:Clean()
	end
	isOpen = true
	for _, ch in list:GetChildren() do
		if ch:IsA("Frame") then
			ch:Destroy()
		end
	end
	local floorId = Workspace:GetAttribute("FloorId")
	local floor = if type(floorId) == "string" then Floors.ById[floorId] else Floors.ByIndex[1]
	local firstButton: GuiObject? = nil
	if floor then
		for i, w in floor.waystones do
			local known = table.find(discovered, w.id) ~= nil
			local state = if w.id == currentId then "here" elseif known then "travel" else "locked"
			local r = row(i, w.nameKey, w.id, state)
			if state == "travel" then
				local b = Components.button({
					name = "Travel",
					text = Strings.get("Waystone.Panel.Travel"),
					variant = "primary",
					frame = UDim2.fromOffset(110, Theme.Touch),
					position = UDim2.new(1, -118, 0.5, -Theme.Touch / 2),
					parent = r,
					onActivated = function()
						Net.send("RequestWaystoneTravel", w.id)
						close()
					end,
				})
				firstButton = firstButton or b
			end
			r.Parent = list
		end
	end
	panel.Size = if isPhone() then UDim2.fromScale(0.94, 0.8) else UDim2.fromOffset(460, 520)
	Components.open(panel)
	TweenService:Create(blur, Theme.Tween.Open, { Size = Theme.BlurSize }):Play()
	ContextActionService:BindAction(CLOSE_ACTION, function(_: string, state: Enum.UserInputState): Enum.ContextActionResult
		if state == Enum.UserInputState.Begin then
			close()
			return Enum.ContextActionResult.Sink
		end
		return Enum.ContextActionResult.Pass
	end, false, Enum.KeyCode.Escape, Enum.KeyCode.ButtonB)
	if UserInputService.GamepadEnabled and firstButton then
		GuiService.SelectedObject = firstButton
	end
	-- walking away closes the panel
	maid:Give(task.spawn(function()
		while isOpen do
			task.wait(0.5)
			local character = Players.LocalPlayer.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if not root then
				close()
				break
			end
		end
	end))
end

function WaystoneController.Init()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	gui = Components.screen("WaystonePanel", playerGui, 30)
	panel = Components.panel({
		name = "Panel",
		size = UDim2.fromOffset(460, 520),
		position = UDim2.fromScale(0.5, 0.5),
		parent = gui,
	})
	panel.Visible = false
	Components.label({
		name = "Title",
		text = Strings.get("Waystone.Panel.Title"),
		font = Theme.Fonts.Display,
		size = Theme.TextSize.Title,
		frame = UDim2.new(1, -60, 0, 34),
		parent = panel,
	})
	Components.label({
		name = "Subtitle",
		text = Strings.get("Waystone.Panel.Subtitle"),
		font = Theme.Fonts.DisplayItalic,
		size = Theme.TextSize.Small,
		color = Theme.Colors.TextDim,
		frame = UDim2.new(1, -60, 0, 20),
		position = UDim2.fromOffset(0, 36),
		parent = panel,
	})
	Components.button({
		name = "Close",
		text = "✕",
		variant = "secondary",
		frame = UDim2.fromOffset(Theme.Touch, Theme.Touch),
		position = UDim2.new(1, -Theme.Touch, 0, -4),
		parent = panel,
		onActivated = close,
	})
	local l = Instance.new("ScrollingFrame")
	l.Name = "List"
	l.Position = UDim2.fromOffset(0, 70)
	l.Size = UDim2.new(1, 0, 1, -70)
	l.BackgroundTransparency = 1
	l.BorderSizePixel = 0
	l.ScrollBarThickness = 4
	l.ScrollBarImageColor3 = Theme.Colors.Border
	l.AutomaticCanvasSize = Enum.AutomaticSize.Y
	l.CanvasSize = UDim2.new()
	l.Parent = panel
	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 8)
	layout.Parent = l
	list = l
	local b = Instance.new("BlurEffect")
	b.Name = "WaystoneBlur"
	b.Size = 0
	b.Parent = Lighting
	blur = b
end

function WaystoneController.Start()
	Net.connect("WaystoneMenu", function(currentId: string, discovered: { string })
		open(currentId, discovered)
	end)
	Net.connect("WaystoneDiscovered", function(id: string)
		if not table.find(discoveredCache, id) then
			table.insert(discoveredCache, id)
		end
	end)
	task.spawn(function()
		local ok, state = pcall(Net.invoke, "RequestWorldState")
		if ok and type(state) == "table" and type(state.waystones) == "table" then
			discoveredCache = state.waystones
		end
	end)
end

function WaystoneController.Discovered(): { string }
	return discoveredCache
end

return WaystoneController
