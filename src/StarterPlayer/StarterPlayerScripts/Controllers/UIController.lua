--!strict
--[[
	UIController
	Opens and closes every menu, one at a time:
	- Menus register a definition (title, hotkey action, builder). A menu's
	  page is built once on first open and reused.
	- Windows wear the deep-ocean frame: layered navy glass, fine double
	  border, wave-curl corners and a wave crest under the bottom edge.
	- Navigation groups ("Journal": Character, Inventory, Spellbook, Skill
	  Tree, and Quests greyed out until quests exist) share ONE window with a
	  row of tabs across the top. Switching tabs swaps pages inside the open
	  window (a short slide) instead of closing and reopening it.
	- "Immersive" menus (the Skill Tree) fill the screen with their own
	  backdrop and header; they show the same tabs in a compact strip.
	- Open: 0.18 s scale+fade, world blur + darkening for full-screen menus,
	  mouse freed, input context -> "Menu", gamepad selection placed.
	  Full-screen menus also hide Roblox's chat window: idle, it is invisible
	  but still sits over the top-left of the screen and takes the clicks
	  meant for the equipment and bag slots underneath it.
	- Close: hotkey again, Back (Backspace / gamepad B) or the close button.
	  TAB (the group's toggle key) closes the whole window from any tab.
	- Q/E or LB/RB switch the open page's own tabs; LT/RT switch the window's
	  top tabs.
	- On touch devices windows are full-screen (Spec Section 12).
	- Roblox's player list is turned off: TAB belongs to the Character window.
	Also owns the menu hub (radial menu for touch/gamepad), toasts from the
	server (Notify remote) and applies UI-related settings.
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local TextChatService = game:GetService("TextChatService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Strings = require(Shared.Strings)
local Net = require(Shared.Net)
local Signal = require(Shared.Util.Signal)
local Maid = require(Shared.Util.Maid)
local TweenUtil = require(Shared.Util.TweenUtil)
local Promise = require(Shared.Util.Promise)

local UI = script.Parent.Parent.UI
local UITheme = require(UI.UITheme)
local Create = require(UI.Create)
local Layers = require(UI.Layers)
local Motion = require(UI.Motion)
local Blur = require(UI.Blur)
local Device = require(UI.Device)
local UISound = require(UI.UISound)
local Icons = require(UI.Icons)
local Components = require(UI.Components)

local DataController = require(script.Parent.DataController)
local InputController = require(script.Parent.InputController)

export type MenuContent = {
	TabBar: Components.TabBar?, -- enables Q/E and LB/RB tab switching
	OnOpen: (() -> ())?,
	OnClose: (() -> ())?,
}

export type MenuDefinition = {
	Id: string,
	Title: string,
	Action: string?, -- input action that toggles this menu
	FullScreen: boolean, -- blur + darken the world
	ShowInHub: boolean,
	Icon: string?, -- UI/Icons name for the hub and the navigation tabs
	HubGlyph: string?, -- text fallback when there's no icon
	Nav: string?, -- navigation group this menu is a tab of
	Layout: string?, -- "Window" (default) or "Immersive" (full screen, own header)
	Size: Vector2?, -- desktop window size (px at reference scale)
	Build: (content: Frame, maid: Maid.Maid) -> MenuContent,
}

export type NavEntry = {
	Menu: string?, -- menu id (nil for a disabled placeholder)
	Text: string,
	Icon: string,
	Action: string?, -- shortcut shown on the tab
	Disabled: boolean?,
	Tooltip: string?,
}

export type NavDefinition = {
	Id: string,
	ToggleAction: string, -- this key closes the window from any of its tabs
	Size: Vector2,
	Entries: { NavEntry },
}

-- One framed window: shared by every Window-layout menu of a navigation
-- group, or owned by a single menu.
type WindowState = {
	Root: Frame,
	Dim: Frame,
	Group: CanvasGroup,
	Scale: UIScale,
	Pages: Frame, -- where menu pages are parented
	Size: Vector2?,
	Immersive: boolean,
	Maid: Maid.Maid,
}

type MenuState = {
	Definition: MenuDefinition,
	Window: WindowState,
	Page: Frame,
	Content: MenuContent,
	Maid: Maid.Maid,
}

local HUB_ID = "__Hub"
local DEFAULT_SIZE = Vector2.new(1040, 680)
local SHADOW_MARGIN = 26 -- room around a desktop window for its soft shadow
local NAV_HEIGHT = 50
local PAGE_SLIDE = 18 -- px a page slides in from when switching tabs
local C = UITheme.Colors

local UIController = {}

UIController.MenuOpened = Signal.new() :: Signal.Signal<string>
UIController.MenuClosed = Signal.new() :: Signal.Signal<string>

local definitions: { [string]: MenuDefinition } = {}
local registrationOrder: { string } = {}
local navs: { [string]: NavDefinition } = {}
local navWindows: { [string]: WindowState } = {}
local states: { [string]: MenuState } = {}
local navBarRefreshers: { [Frame]: () -> () } = {}
local openId: string? = nil
local busy = false
local openMaid = Maid.new()

local function isImmersive(definition: MenuDefinition): boolean
	return definition.Layout == "Immersive"
end

local function windowSize(size: Vector2?, immersive: boolean): UDim2
	if immersive or Device.IsTouch() then
		return UDim2.fromScale(1, 1)
	end
	local s = size or DEFAULT_SIZE
	return UDim2.fromOffset(s.X + SHADOW_MARGIN * 2, s.Y + SHADOW_MARGIN * 2)
end

local function firstSelectable(root: Instance): GuiObject?
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("GuiObject") and descendant.Selectable and descendant.Visible then
			return descendant
		end
	end
	return nil
end

-- FRAME ----------------------------------------------------------------------------

-- The deep-ocean window: soft shadow, layered navy glass with a light-from-
-- the-surface glow, a fine double border, wave-curl corner ornaments and a
-- wave crest along the bottom edge. Returns the panel (content goes inside).
local function buildFrame(group: CanvasGroup): Frame
	local touch = Device.IsTouch()
	local shadow = Icons.Fx("Shadow", {
		Name = "Shadow",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, 8),
		Size = UDim2.new(1, 8, 1, 8),
		Color = Color3.new(0, 0, 0),
		Transparency = 0.25,
		Parent = group,
	})
	shadow.ScaleType = Enum.ScaleType.Slice
	shadow.SliceCenter = Rect.new(40, 40, 88, 88)

	local panel: Frame = Create.new("Frame", {
		Name = "Panel",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = if touch then UDim2.fromScale(1, 1) else UDim2.new(1, -SHADOW_MARGIN * 2, 1, -SHADOW_MARGIN * 2),
		BackgroundColor3 = C.Panel,
		BackgroundTransparency = 0.05,
		BorderSizePixel = 0,
		ClipsDescendants = true,
		Parent = group,
	})
	Create.Corner(panel, UDim.new(0, 12))
	Create.Stroke(panel, C.Edge, 2, 0.05)
	Create.new("UIGradient", {
		Rotation = 90,
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 255)),
			ColorSequenceKeypoint.new(0.35, Color3.fromRGB(205, 214, 230)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(150, 160, 182)),
		}),
		Parent = panel,
	})

	-- Light falling through the surface onto the top of the window.
	Icons.Fx("Glow", {
		Name = "SurfaceLight",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0),
		Size = UDim2.new(0.9, 0, 0, 320),
		Color = C.Aqua,
		Transparency = 0.9,
		Parent = panel,
	})

	-- Fine inner border, inset from the outer edge (double-rule frame).
	local inner: Frame = Create.new("Frame", {
		Name = "InnerBorder",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, -12, 1, -12),
		Parent = panel,
	})
	Create.Corner(inner, UDim.new(0, 8))
	Create.Stroke(inner, C.EdgeBright, 1, 0.72)

	-- Wave-curl ornaments in the four corners.
	local corners = {
		{ Anchor = Vector2.new(0, 0), Position = UDim2.fromScale(0, 0), Rotation = 0 },
		{ Anchor = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Rotation = 90 },
		{ Anchor = Vector2.new(1, 1), Position = UDim2.fromScale(1, 1), Rotation = 180 },
		{ Anchor = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Rotation = 270 },
	}
	for index, corner in corners do
		Icons.Fx("Corner", {
			Name = `Corner{index}`,
			AnchorPoint = corner.Anchor,
			Position = corner.Position,
			Size = UDim2.fromOffset(70, 70),
			Rotation = corner.Rotation,
			Color = C.Aqua,
			Transparency = 0.35,
			ZIndex = 2,
			Parent = panel,
		})
	end

	-- Wave crest centred on the bottom edge, with a glint at its middle.
	Icons.Fx("Wave", {
		Name = "BottomWave",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -2),
		Size = UDim2.fromOffset(240, 30),
		Color = C.Aqua,
		Transparency = 0.45,
		ZIndex = 2,
		Parent = panel,
	})
	Icons.Fx("Sparkle", {
		Name = "BottomGlint",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 1, -17),
		Size = UDim2.fromOffset(22, 22),
		Color = C.Foam,
		Transparency = 0.2,
		ZIndex = 3,
		Parent = panel,
	})
	return panel
end

local function closeButton(parent: Instance, maid: Maid.Maid)
	maid:Add(Components.IconButton.new({
		Name = "Close",
		Icon = "Close",
		Size = 40,
		Tooltip = Strings.UI.Close,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 5),
		Parent = parent,
		OnActivated = function()
			UIController.Close()
		end,
	}))
end

-- NAVIGATION TABS --------------------------------------------------------------------

-- Builds a navigation tab strip for `navId` inside `parent`. Full tabs show
-- an icon, a label and the shortcut; compact tabs are icon squares with a
-- tooltip (the Skill Tree's header). Returns the strip's frame.
local function buildNavBar(navId: string, parent: Instance, compact: boolean, maid: Maid.Maid): Frame
	local nav = navs[navId]
	local bar: Frame = Create.new("Frame", {
		Name = "NavBar",
		BackgroundTransparency = 1,
		Size = if compact then UDim2.fromOffset(0, 46) else UDim2.new(1, -56, 0, NAV_HEIGHT),
		AutomaticSize = if compact then Enum.AutomaticSize.X else Enum.AutomaticSize.None,
		Parent = parent,
	})
	local list = Create.List(bar, Enum.FillDirection.Horizontal, if compact then 6 else 8)
	list.VerticalAlignment = Enum.VerticalAlignment.Center

	type TabView = {
		Entry: NavEntry,
		Button: TextButton,
		Stroke: UIStroke,
		Icon: ImageLabel,
		Label: TextLabel?,
		Key: TextLabel?,
		Mark: Frame,
		Hover: boolean,
	}
	local views: { TabView } = {}
	local count = #nav.Entries

	local function paint(view: TabView)
		local entry = view.Entry
		local selected = entry.Menu ~= nil and entry.Menu == openId
		local disabled = entry.Disabled == true
		local button = view.Button
		if disabled then
			button.BackgroundColor3 = C.PanelSunken
			button.BackgroundTransparency = 0.45
			view.Stroke.Color = C.Edge
			view.Stroke.Transparency = 0.6
			view.Icon.ImageColor3 = C.TextDim
			view.Icon.ImageTransparency = 0.35
		elseif selected then
			button.BackgroundColor3 = C.PanelHover:Lerp(C.Aqua, 0.18)
			button.BackgroundTransparency = 0
			view.Stroke.Color = C.Aqua
			view.Stroke.Transparency = 0
			view.Icon.ImageColor3 = C.Foam
			view.Icon.ImageTransparency = 0
		elseif view.Hover then
			button.BackgroundColor3 = C.PanelHover
			button.BackgroundTransparency = 0.1
			view.Stroke.Color = C.EdgeBright
			view.Stroke.Transparency = 0.1
			view.Icon.ImageColor3 = C.Text
			view.Icon.ImageTransparency = 0
		else
			button.BackgroundColor3 = C.PanelRaised
			button.BackgroundTransparency = 0.25
			view.Stroke.Color = C.Edge
			view.Stroke.Transparency = 0.15
			view.Icon.ImageColor3 = C.TextMuted
			view.Icon.ImageTransparency = 0
		end
		view.Mark.Visible = selected
		local label = view.Label
		if label then
			label.TextColor3 = if disabled then C.TextDim elseif selected then C.Foam elseif view.Hover then C.Text else C.TextMuted
			label.TextTransparency = if disabled then 0.35 else 0
		end
		local key = view.Key
		if key then
			local prompt = if entry.Action and not disabled then InputController.GetPrompt(entry.Action :: any) else ""
			key.Text = prompt
			key.Visible = prompt ~= "" and Device.Current() == "KeyboardMouse"
			key.TextColor3 = if selected then C.Aqua else C.TextDim
		end
	end

	for index, entry in nav.Entries do
		local button: TextButton = Create.new("TextButton", {
			Name = entry.Menu or `Tab{index}`,
			Text = "",
			AutoButtonColor = false,
			LayoutOrder = index,
			BorderSizePixel = 0,
			Size = if compact then UDim2.fromOffset(46, 46) else UDim2.new(1 / count, -8 * (count - 1) / count, 1, 0),
			Selectable = not entry.Disabled,
			SelectionImageObject = Create.SelectionImage(),
			Parent = bar,
		})
		Create.Corner(button, UDim.new(0, 8))
		local stroke = Create.Stroke(button, C.Edge, 1.3, 0.15)
		Create.new("UIGradient", {
			Rotation = 90,
			Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(165, 180, 205)),
			Parent = button,
		})
		-- Soft underglow and a bright rule along the bottom of the selected tab.
		local mark: Frame = Create.new("Frame", {
			Name = "SelectedMark",
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			Visible = false,
			Parent = button,
		})
		Icons.Fx("Glow", {
			Name = "Glow",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 1),
			Size = UDim2.new(0.9, 0, 0, 34),
			Color = C.Aqua,
			Transparency = 0.45,
			Parent = mark,
		})
		Create.new("Frame", {
			Name = "Rule",
			BorderSizePixel = 0,
			BackgroundColor3 = C.Aqua,
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, -1),
			Size = UDim2.new(0.62, 0, 0, 2),
			Parent = mark,
		})
		local icon: ImageLabel
		local label: TextLabel? = nil
		local key: TextLabel? = nil
		if compact then
			icon = Icons.new(entry.Icon, {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromOffset(24, 24),
				Parent = button,
			})
		else
			local row: Frame = Create.new("Frame", {
				Name = "Row",
				BackgroundTransparency = 1,
				AutomaticSize = Enum.AutomaticSize.X,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.new(0, 0, 1, 0),
				Parent = button,
			})
			Create.List(row, Enum.FillDirection.Horizontal, 8, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
			icon = Icons.new(entry.Icon, { Size = UDim2.fromOffset(24, 24), LayoutOrder = 1, Parent = row })
			label = Create.new("TextLabel", {
				Name = "Label",
				BackgroundTransparency = 1,
				Text = string.upper(entry.Text),
				FontFace = UITheme.Fonts.Title,
				TextSize = 18,
				AutomaticSize = Enum.AutomaticSize.X,
				Size = UDim2.new(0, 0, 1, 0),
				LayoutOrder = 2,
				Parent = row,
			})
			key = Create.new("TextLabel", {
				Name = "Key",
				BackgroundTransparency = 1,
				Text = "",
				FontFace = UITheme.Fonts.BodyBold,
				TextSize = 12,
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.new(1, -7, 0, 4),
				Size = UDim2.fromOffset(40, 14),
				TextXAlignment = Enum.TextXAlignment.Right,
				Parent = button,
			})
			if entry.Disabled then
				Icons.new("Lock", {
					Name = "Lock",
					AnchorPoint = Vector2.new(1, 0),
					Position = UDim2.new(1, -6, 0, 5),
					Size = UDim2.fromOffset(13, 13),
					Color = C.TextDim,
					Parent = button,
				})
			end
		end
		local view: TabView = { Entry = entry, Button = button, Stroke = stroke, Icon = icon, Label = label, Key = key, Mark = mark, Hover = false }
		table.insert(views, view)
		maid:Add(Motion.AttachButtonFeedback(button))
		maid:Add(button.MouseEnter:Connect(function()
			view.Hover = true
			paint(view)
		end))
		maid:Add(button.MouseLeave:Connect(function()
			view.Hover = false
			paint(view)
		end))
		local tooltip = if entry.Disabled then entry.Tooltip elseif compact then entry.Text else nil
		if tooltip then
			local title = entry.Text
			local body = if entry.Disabled then entry.Tooltip else nil
			maid:Add(Components.Tooltip.Attach(button, function(): Components.TooltipContent?
				return {
					Title = title,
					Icon = entry.Icon,
					Lines = if body then { { Text = body, Color = C.TextMuted } } else nil,
				}
			end))
		end
		maid:Add(button.Activated:Connect(function()
			if entry.Disabled then
				UISound.Play("UIError")
				return
			end
			local menu = entry.Menu
			if menu and menu ~= openId then
				UISound.Play("UIClick")
				UIController.Open(menu)
			end
		end))
	end

	local function refresh()
		for _, view in views do
			paint(view)
		end
	end
	navBarRefreshers[bar] = refresh
	maid:Add(function()
		navBarRefreshers[bar] = nil
	end)
	maid:Add(InputController.BindingsChanged:Connect(refresh))
	maid:Add(Device.Changed:Connect(refresh))
	refresh()
	return bar
end

local function refreshNavBars()
	for _, refresh in navBarRefreshers do
		refresh()
	end
end

-- Gamepad LT / RT: the next enabled tab of the open window.
local function stepNav(delta: number)
	local id = openId
	local definition = id and definitions[id]
	local nav = definition and definition.Nav and navs[definition.Nav]
	if not nav or not id then
		return
	end
	local enabled: { string } = {}
	for _, entry in nav.Entries do
		if entry.Menu and not entry.Disabled and definitions[entry.Menu] then
			table.insert(enabled, entry.Menu)
		end
	end
	local index = table.find(enabled, id)
	if not index or #enabled < 2 then
		return
	end
	UIController.Open(enabled[(index - 1 + delta) % #enabled + 1])
end

-- WINDOWS --------------------------------------------------------------------------

local function newWindow(name: string, size: Vector2?, immersive: boolean): (WindowState, Frame)
	local maid = Maid.new()
	local layer = Layers.Get("Menu")

	local root: Frame = Create.new("Frame", {
		Name = `Menu_{name}`,
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		Parent = layer,
	})
	maid:Add(root)

	-- Darkens the world behind full-screen menus.
	local dim: Frame = Create.new("Frame", {
		Name = "Dim",
		BackgroundColor3 = C.Overlay,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Parent = root,
	})

	-- A Modal button frees the mouse even if the camera has locked it.
	Create.new("TextButton", {
		Name = "MouseRelease",
		Text = "",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(0, 0),
		Modal = true,
		Selectable = false,
		Parent = root,
	})

	local group: CanvasGroup = Create.new("CanvasGroup", {
		Name = "Window",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = windowSize(size, immersive),
		GroupTransparency = 1,
		Visible = false,
		Parent = root,
	})
	local scale: UIScale = Create.new("UIScale", { Parent = group })

	local pages: Frame
	if immersive then
		pages = Create.new("Frame", { Name = "Pages", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = group })
	else
		local panel = buildFrame(group)
		local inside: Frame = Create.new("Frame", { Name = "Inside", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = panel })
		local padding = Create.Padding(inside, UITheme.Padding.Large)
		if Device.IsTouch() then
			-- Full screen on touch: keep the tabs below Roblox's top-bar buttons.
			local function clearTopbar()
				local height = GuiService.TopbarInset.Height / Layers.GetScale("Menu")
				padding.PaddingTop = UDim.new(0, UITheme.Padding.Large + math.ceil(height))
			end
			clearTopbar()
			maid:Add(GuiService:GetPropertyChangedSignal("TopbarInset"):Connect(clearTopbar))
			maid:Add(root:GetPropertyChangedSignal("AbsoluteSize"):Connect(clearTopbar))
		end
		pages = inside
	end
	local window: WindowState = {
		Root = root,
		Dim = dim,
		Group = group,
		Scale = scale,
		Pages = pages,
		Size = size,
		Immersive = immersive,
		Maid = maid,
	}
	return window, pages
end

-- The shared window of a navigation group: tabs across the top, close on
-- the right, pages below.
local function navWindow(navId: string): WindowState
	local existing = navWindows[navId]
	if existing then
		return existing
	end
	local nav = navs[navId]
	local window, inside = newWindow(navId, nav.Size, false)
	buildNavBar(navId, inside, false, window.Maid)
	closeButton(inside, window.Maid)
	local pages: Frame = Create.new("Frame", {
		Name = "Pages",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, NAV_HEIGHT + UITheme.Padding.Medium),
		Size = UDim2.new(1, 0, 1, -(NAV_HEIGHT + UITheme.Padding.Medium)),
		ClipsDescendants = true,
		Parent = inside,
	})
	window.Pages = pages
	navWindows[navId] = window
	return window
end

local function buildState(definition: MenuDefinition): MenuState
	local maid = Maid.new()
	local window: WindowState
	local page: Frame
	if isImmersive(definition) then
		window = newWindow(definition.Id, nil, true)
		page = Create.new("Frame", { Name = definition.Id, BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = window.Pages })
	elseif definition.Nav and navs[definition.Nav] then
		window = navWindow(definition.Nav)
		page = Create.new("Frame", {
			Name = definition.Id,
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			Visible = false,
			Parent = window.Pages,
		})
	else
		local inside: Frame
		window, inside = newWindow(definition.Id, definition.Size, false)
		maid:Add(window.Maid)
		if definition.Id ~= HUB_ID then
			Create.Label({
				Name = "Title",
				Text = string.upper(definition.Title),
				Font = UITheme.Fonts.Title,
				TextSize = UITheme.TextSize.Title,
				Color = C.Foam,
				Size = UDim2.new(1, -60, 0, 40),
				Parent = inside,
			})
			Icons.Fx("Wave", {
				Name = "TitleWave",
				Position = UDim2.fromOffset(0, 42),
				Size = UDim2.fromOffset(150, 14),
				Color = C.Aqua,
				Transparency = 0.5,
				Parent = inside,
			})
			closeButton(inside, maid)
		end
		page = Create.new("Frame", {
			Name = definition.Id,
			BackgroundTransparency = 1,
			Position = if definition.Id ~= HUB_ID then UDim2.fromOffset(0, 62) else UDim2.new(),
			Size = if definition.Id ~= HUB_ID then UDim2.new(1, 0, 1, -62) else UDim2.fromScale(1, 1),
			Parent = inside,
		})
	end
	maid:Add(page)
	local menuContent = definition.Build(page, maid)
	return {
		Definition = definition,
		Window = window,
		Page = page,
		Content = menuContent,
		Maid = maid,
	}
end

-- HUB --------------------------------------------------------------------------

local function buildHub(content: Frame, maid: Maid.Maid): MenuContent
	local ring: Frame = Create.new("Frame", {
		Name = "Ring",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = content,
	})
	Icons.Fx("Ring", {
		Name = "HubRing",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(280, 280),
		Color = C.Aqua,
		Transparency = 0.6,
		Parent = ring,
	})
	Create.Label({
		Text = string.upper(Strings.Actions.OpenMenuHub),
		Font = UITheme.Fonts.Title,
		TextSize = UITheme.TextSize.Heading,
		Color = C.Foam,
		XAlignment = Enum.TextXAlignment.Center,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(160, 30),
		Parent = content,
	})
	-- Icon credit (game-icons.net, CC BY 3.0).
	Create.Label({
		Text = Strings.UI.IconCredit,
		TextSize = UITheme.TextSize.Caption - 2,
		Color = C.TextDim,
		XAlignment = Enum.TextXAlignment.Center,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, 2),
		Size = UDim2.new(1, 0, 0, 14),
		Parent = content,
	})

	local itemMaid = Maid.new()
	maid:Add(itemMaid)

	local function populate()
		itemMaid:Clean()
		local entries: { MenuDefinition } = {}
		for _, id in registrationOrder do
			local definition = definitions[id]
			if definition and definition.ShowInHub then
				table.insert(entries, definition)
			end
		end
		local count = #entries
		local radius = 140
		for index, definition in entries do
			-- Evenly around the circle, first item at the top.
			local angle = -math.pi / 2 + (index - 1) * (2 * math.pi / math.max(1, count))
			local holder: Frame = itemMaid:Add(Create.new("Frame", {
				Name = definition.Id,
				BackgroundTransparency = 1,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.new(0.5, math.cos(angle) * radius, 0.5, math.sin(angle) * radius),
				Size = UDim2.fromOffset(104, 84),
				Parent = ring,
			}))
			local menuId = definition.Id
			itemMaid:Add(Components.IconButton.new({
				Icon = definition.Icon,
				Glyph = if definition.Icon then nil else definition.HubGlyph or string.sub(definition.Title, 1, 1),
				Size = 58,
				AnchorPoint = Vector2.new(0.5, 0),
				Position = UDim2.fromScale(0.5, 0),
				Parent = holder,
				OnActivated = function()
					UIController.Open(menuId)
				end,
			}))
			Create.Label({
				Text = definition.Title,
				TextSize = UITheme.TextSize.Small,
				Color = C.TextMuted,
				XAlignment = Enum.TextXAlignment.Center,
				AnchorPoint = Vector2.new(0.5, 1),
				Position = UDim2.fromScale(0.5, 1),
				Size = UDim2.new(1, 20, 0, 20),
				Parent = holder,
			})
		end
	end

	return {
		OnOpen = populate,
	}
end

-- OPEN / CLOSE -------------------------------------------------------------------

-- Hides the chat window and input bar; returns a function that puts back
-- exactly what was there (so a game that turned chat off keeps it off).
local function hideChat(): () -> ()
	local window = TextChatService:FindFirstChildOfClass("ChatWindowConfiguration")
	local bar = TextChatService:FindFirstChildOfClass("ChatInputBarConfiguration")
	local windowWas = if window then window.Enabled else false
	local barWas = if bar then bar.Enabled else false
	if window then
		window.Enabled = false
	end
	if bar then
		bar.Enabled = false
	end
	return function()
		if window and window.Parent then
			window.Enabled = windowWas
		end
		if bar and bar.Parent then
			bar.Enabled = barWas
		end
	end
end

local function clearSelection(window: WindowState)
	local selected = GuiService.SelectedObject
	if selected and selected:IsDescendantOf(window.Root) then
		GuiService.SelectedObject = nil
	end
end

local function placeGamepadSelection(state: MenuState)
	if Device.IsGamepad() then
		local target = firstSelectable(state.Page)
		if target then
			GuiService.SelectedObject = target
		end
	end
end

local function closeCurrent(animated: boolean)
	local id = openId
	if not id then
		return
	end
	local state = states[id]
	local window = state.Window
	openId = nil
	openMaid:Clean()
	InputController.SetContext("Gameplay")
	clearSelection(window)
	if state.Content.OnClose then
		state.Content.OnClose()
	end
	UISound.Play("UIClose")
	TweenUtil.Play(window.Dim, UITheme.Motion.CloseTime, { BackgroundTransparency = 1 })
	if animated then
		Motion.Close(window.Group, window.Scale)
	else
		window.Group.Visible = false
	end
	window.Root.Visible = false
	UIController.MenuClosed:Fire(id)
	refreshNavBars()
end

-- Swaps pages inside an already-open navigation window.
local function switchPage(fromId: string, toId: string, state: MenuState)
	local old = states[fromId]
	clearSelection(old.Window)
	if old.Content.OnClose then
		old.Content.OnClose()
	end
	old.Page.Visible = false
	UIController.MenuClosed:Fire(fromId)

	openId = toId
	local page = state.Page
	page.Visible = true
	if not Motion.IsReduced() then
		-- Slide in from the side of the tab we came from.
		local fromIndex, toIndex = 0, 0
		local nav = state.Definition.Nav and navs[state.Definition.Nav]
		if nav then
			for index, entry in nav.Entries do
				if entry.Menu == fromId then
					fromIndex = index
				elseif entry.Menu == toId then
					toIndex = index
				end
			end
		end
		local direction = if toIndex >= fromIndex then 1 else -1
		page.Position = UDim2.fromOffset(PAGE_SLIDE * direction, 0)
		TweenUtil.Play(page, 0.16, { Position = UDim2.new() }, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	end
	UISound.Play("UIOpen")
	if state.Content.OnOpen then
		state.Content.OnOpen()
	end
	refreshNavBars()
	placeGamepadSelection(state)
	UIController.MenuOpened:Fire(toId)
end

function UIController.Open(id: string)
	if busy or openId == id then
		return
	end
	local definition = definitions[id]
	if not definition then
		return
	end
	busy = true

	local state = states[id]
	if not state then
		state = buildState(definition)
		states[id] = state
	end
	local window = state.Window

	-- Same window already open (another tab of it): just swap pages.
	local fromId = openId
	if fromId and states[fromId] and states[fromId].Window == window then
		switchPage(fromId, id, state)
		busy = false
		return
	end
	if fromId then
		closeCurrent(false)
	end

	for _, child in window.Pages:GetChildren() do
		if child:IsA("Frame") and child ~= state.Page and definitions[child.Name] then
			child.Visible = false
		end
	end
	state.Page.Visible = true
	state.Page.Position = UDim2.new()
	window.Group.Size = windowSize(window.Size, window.Immersive)
	window.Root.Visible = true
	openId = id
	InputController.SetContext("Menu")

	if definition.FullScreen then
		openMaid:Add(Blur.Push())
		openMaid:Add(hideChat())
		TweenUtil.Play(window.Dim, UITheme.Motion.OpenTime, {
			BackgroundTransparency = if window.Immersive then 0.2 else UITheme.OverlayTransparency,
		})
	end
	if state.Content.OnOpen then
		state.Content.OnOpen()
	end
	refreshNavBars()
	UISound.Play("UIOpen")
	Motion.Open(window.Group, window.Scale)
	placeGamepadSelection(state)
	busy = false
	UIController.MenuOpened:Fire(id)
end

function UIController.Close()
	if busy or not openId then
		return
	end
	busy = true
	closeCurrent(true)
	busy = false
end

function UIController.Toggle(id: string)
	if openId == id then
		UIController.Close()
	else
		UIController.Open(id)
	end
end

function UIController.GetOpen(): string?
	return openId
end

function UIController.IsMenuOpen(): boolean
	return openId ~= nil
end

function UIController.RegisterMenu(definition: MenuDefinition)
	assert(definitions[definition.Id] == nil, `Menu '{definition.Id}' registered twice`)
	definitions[definition.Id] = definition
	table.insert(registrationOrder, definition.Id)
end

function UIController.RegisterNav(definition: NavDefinition)
	assert(navs[definition.Id] == nil, `Navigation '{definition.Id}' registered twice`)
	navs[definition.Id] = definition
end

-- A compact strip of a navigation group's tabs, for immersive menus that
-- draw their own header (the Skill Tree).
function UIController.CreateNavStrip(navId: string, parent: Instance, maid: Maid.Maid): Frame
	assert(navs[navId], `Unknown navigation '{navId}'`)
	return buildNavBar(navId, parent, true, maid)
end

-- A close button matching the window frames, for immersive menus.
function UIController.CreateCloseButton(parent: Instance, maid: Maid.Maid)
	closeButton(parent, maid)
end

-- FEEDBACK ---------------------------------------------------------------------

function UIController.Toast(data: Components.ToastData)
	Components.Toast.Push(data)
end

function UIController.Confirm(props: Components.ConfirmProps): Promise.Promise<boolean>
	return Components.ConfirmDialog.Show(props)
end

local STYLE_COLORS: { [string]: Color3 } = {
	Info = C.Current,
	Success = C.Heal,
	Warning = C.Parry,
	Danger = C.Danger,
}

-- Resolves "Toasts.Welcome" to a string in the Strings tree.
local function lookupString(path: string): string?
	local node: any = Strings
	for _, key in string.split(path, ".") do
		if type(node) ~= "table" then
			return nil
		end
		node = node[key]
	end
	return if type(node) == "string" then node else nil
end

local function onNotify(key: string, args: { [string]: any }?, style: string?)
	if type(key) ~= "string" then
		return
	end
	local template = lookupString(key)
	if not template then
		return
	end
	Components.Toast.Push({
		Title = Strings.Format(template, args or {}),
		Color = STYLE_COLORS[style or "Info"] or C.Current,
	})
end

local function applyDeviceLayout()
	Components.Toast.SetBottomOffset(if Device.IsTouch() then Config.Input.TouchToastOffset else 24)
	local id = openId
	if id then
		local window = states[id].Window
		window.Group.Size = windowSize(window.Size, window.Immersive)
	end
end

-- Roblox's player list also opens on TAB; the Character window owns TAB, so
-- the default list is switched off (SetCoreGuiEnabled can fail for a moment
-- while the CoreGui loads, so it retries).
local function disablePlayerList()
	task.spawn(function()
		for _ = 1, 20 do
			local ok = pcall(function()
				StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, false)
			end)
			if ok then
				return
			end
			task.wait(0.5)
		end
	end)
end

-- LIFECYCLE ----------------------------------------------------------------------

function UIController.Init()
	UIController.RegisterMenu({
		Id = HUB_ID,
		Title = Strings.Actions.OpenMenuHub,
		Action = "OpenMenuHub",
		FullScreen = true,
		ShowInHub = false,
		Size = Vector2.new(440, 440),
		Build = buildHub,
	})
	-- The Character window: TAB opens it on Character and closes it from any tab.
	UIController.RegisterNav({
		Id = "Journal",
		ToggleAction = "OpenCharacter",
		Size = Vector2.new(1180, 720),
		Entries = {
			{ Menu = "Character", Text = Strings.Actions.OpenCharacter, Icon = "Character", Action = "OpenCharacter" },
			{ Menu = "Inventory", Text = Strings.Actions.OpenInventory, Icon = "Inventory", Action = "OpenInventory" },
			{ Menu = "Spellbook", Text = Strings.Actions.OpenSpellbook, Icon = "Current", Action = "OpenSpellbook" },
			{ Menu = "SkillTree", Text = Strings.Actions.OpenSkillTree, Icon = "SkillTree", Action = "OpenSkillTree" },
			{ Text = Strings.Actions.OpenQuestLog, Icon = "Quests", Disabled = true, Tooltip = Strings.UI.QuestsLater },
		},
	})
	Net.OnClient("Notify", onNotify)
end

function UIController.Start()
	-- Pre-create layers so they exist in a stable order.
	for _, name in { "HUD", "Touch", "Menu", "Overlay", "Modal", "Tooltip" } do
		Layers.Get(name :: any)
	end
	disablePlayerList()

	InputController.ActionBegan:Connect(function(action: string)
		if action == "CloseMenu" then
			if not Components.Modal.IsBlockingBack() then
				UIController.Close()
			end
			return
		end
		if action == "TabLeft" or action == "TabRight" then
			local id = openId
			local tabBar = id and states[id] and states[id].Content.TabBar
			if tabBar and not Components.Modal.IsAnyOpen() then
				if action == "TabLeft" then
					tabBar:Prev()
				else
					tabBar:Next()
				end
			end
			return
		end
		if action == "NavPrev" or action == "NavNext" then
			if not Components.Modal.IsAnyOpen() then
				stepNav(if action == "NavPrev" then -1 else 1)
			end
			return
		end
		for _, id in registrationOrder do
			local definition = definitions[id]
			if definition.Action == action then
				-- The group's toggle key (TAB) closes its window from any tab.
				local open = openId and definitions[openId]
				local nav = definition.Nav and navs[definition.Nav]
				if nav and nav.ToggleAction == action and open and open.Nav == definition.Nav then
					UIController.Close()
				else
					UIController.Toggle(id)
				end
				return
			end
		end
	end)

	Device.Changed:Connect(applyDeviceLayout)
	applyDeviceLayout()

	-- Settings that affect the UI layer.
	DataController.Observe({ "Settings" }, function()
		Layers.SetUserScale(DataController.GetSetting("HudScale"))
		Motion.SetReducedMotion(DataController.GetSetting("ReducedMotion"))
		UISound.SetVolume(DataController.GetSetting("UiVolume") * DataController.GetSetting("MasterVolume"))
	end)

	DataController.Ready:Connect(function()
		Components.Toast.Push({
			Title = Strings.Format(Strings.Toasts.Welcome, { name = Players.LocalPlayer.DisplayName }),
			Body = Strings.Toasts.DataReady,
			Color = C.Current,
		})
	end)
end

return UIController
