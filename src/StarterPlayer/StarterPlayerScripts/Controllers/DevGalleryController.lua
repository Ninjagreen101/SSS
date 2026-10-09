--!strict
--[[
	DevGalleryController (Studio only)
	A full-screen menu that renders every UI component from UITheme so the
	style guide can be reviewed and tested with mouse, touch and gamepad.
	Its inputs are wired to real settings (Reduced Motion, Camera Shake,
	Graphics Quality, the Dodge keybind), so it also exercises the
	settings save path end to end. Toggle with F8 or the menu hub.

	Also creates LocalPlayer.ClientDevHooks (Studio only), a BindableFunction
	test scripts use to drive the UI without keyboard focus:
		ClientDevHooks:Invoke("Open", "Inventory")    opens a menu, returns the open id
		ClientDevHooks:Invoke("Close")                closes the open menu
		ClientDevHooks:Invoke("Action", "Consumable1") presses and releases an input action
		ClientDevHooks:Invoke("Menu")                 the open menu id (or nil)
		ClientDevHooks:Invoke("Station", "Harbor_Forge") opens a station's window, wherever you stand
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Enums = require(Shared.Enums)
local Strings = require(Shared.Strings)
local Maid = require(Shared.Util.Maid)
local Promise = require(Shared.Util.Promise)

local UI = script.Parent.Parent.UI
local UITheme = require(UI.UITheme)
local Create = require(UI.Create)
local Components = require(UI.Components)

local DataController = require(script.Parent.DataController)
local InputController = require(script.Parent.InputController)
local UIController = require(script.Parent.UIController)
local StationController = require(script.Parent.StationController)

local G = Strings.Gallery

local DevGalleryController = {}

local ROW_HEIGHT = 46

-- A labelled row: text on the left, control area on the right.
local function row(parent: Instance, label: string, order: number): Frame
	local frame: Frame = Create.new("Frame", {
		Name = label,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, ROW_HEIGHT),
		LayoutOrder = order,
		Parent = parent,
	})
	Create.Label({
		Text = label,
		Color = UITheme.Colors.TextMuted,
		Size = UDim2.new(0.4, 0, 1, 0),
		Parent = frame,
	})
	local control: Frame = Create.new("Frame", {
		Name = "Control",
		BackgroundTransparency = 1,
		Position = UDim2.fromScale(0.4, 0),
		Size = UDim2.new(0.6, 0, 1, 0),
		Parent = frame,
	})
	local list = Create.List(control, Enum.FillDirection.Horizontal, UITheme.Padding.Small)
	list.VerticalAlignment = Enum.VerticalAlignment.Center
	return control
end

local function sectionTitle(parent: Instance, text: string, order: number)
	Create.Label({
		Text = text,
		Font = UITheme.Fonts.Title,
		TextSize = UITheme.TextSize.BodyLarge,
		Color = UITheme.Colors.Accent,
		Size = UDim2.new(1, 0, 0, 30),
		LayoutOrder = order,
		Parent = parent,
	})
end

local function buildButtons(page: Components.ScrollList)
	local parent = page.Instance
	sectionTitle(parent, G.TabButtons, 1)
	local buttons = row(parent, Strings.Gallery.TabButtons, 2)
	Components.Button.new({ Text = G.Primary, Variant = "Primary", LayoutOrder = 1, Parent = buttons })
	Components.Button.new({ Text = G.Secondary, Variant = "Secondary", LayoutOrder = 2, Parent = buttons })
	Components.Button.new({ Text = G.Danger, Variant = "Danger", LayoutOrder = 3, Parent = buttons })
	local disabled = row(parent, G.Disabled, 3)
	Components.Button.new({ Text = G.Disabled, Variant = "Primary", Enabled = false, Parent = disabled })

	local icons = row(parent, "IconButton", 4)
	for index, glyph in { "+", "-", "?", "×", "!" } do
		Components.IconButton.new({
			Glyph = glyph,
			Tooltip = `IconButton {glyph}`,
			LayoutOrder = index,
			Parent = icons,
		})
	end

	local panels = row(parent, "Panel", 5)
	local panelRow = panels.Parent :: Frame
	panelRow.Size = UDim2.new(1, 0, 0, 140)
	Components.Panel.new({
		Title = Strings.Game.Title,
		Size = UDim2.fromOffset(260, 130),
		Parent = panels,
	})
end

local function buildInputs(page: Components.ScrollList, maid: Maid.Maid)
	local parent = page.Instance
	sectionTitle(parent, G.TabInputs, 1)

	local toggleRow = row(parent, G.ToggleLabel, 2)
	local toggle = Components.Toggle.new({ Value = DataController.GetSetting("ReducedMotion"), Parent = toggleRow })
	toggle.Changed:Connect(function(value: boolean)
		DataController.SetSetting("ReducedMotion", value)
	end)

	local sliderRow = row(parent, G.SliderLabel, 3)
	local slider = Components.Slider.new({
		Min = 0,
		Max = 1,
		Step = 0.05,
		Value = DataController.GetSetting("CameraShake"),
		Size = UDim2.fromOffset(300, 28),
		Parent = sliderRow,
	})
	slider.Committed:Connect(function(value: number)
		DataController.SetSetting("CameraShake", value)
	end)

	local dropdownRow = row(parent, G.DropdownLabel, 4)
	local options = {}
	for _, quality in Enums.GraphicsQuality do
		table.insert(options, { Id = quality, Text = quality })
	end
	local dropdown = Components.Dropdown.new({
		Options = options,
		Selected = DataController.GetSetting("GraphicsQuality"),
		Parent = dropdownRow,
	})
	dropdown.Changed:Connect(function(value: string)
		DataController.SetSetting("GraphicsQuality", value)
	end)

	local keybindRow = row(parent, G.KeybindLabel, 5)
	type BindDevice = Enums.BindingDevice
	local function bindingFor(device: BindDevice): string
		return InputController.GetBindings("Dodge", device)[1] or ""
	end
	local devices: { BindDevice } = { "Keyboard", "Gamepad" }
	for index = 1, #devices do
		local device: BindDevice = devices[index]
		local field = Components.KeybindField.new({
			Binding = bindingFor(device),
			LayoutOrder = index,
			Parent = keybindRow,
			Capture = function(): Promise.Promise<string?>
				return InputController.CaptureNext(device)
			end,
		})
		field.Changed:Connect(function(binding: string)
			local ok, message = InputController.SetBinding("Dodge", device, 1, binding)
			if message then
				UIController.Toast({
					Title = message,
					Color = if ok then UITheme.Colors.Parry else UITheme.Colors.Danger,
				})
			end
			field:SetBinding(bindingFor(device))
		end)
		maid:Add(InputController.BindingsChanged:Connect(function()
			field:SetBinding(bindingFor(device))
		end))
	end

	-- Search filtering a scroll list.
	local searchRow = row(parent, G.SearchLabel, 6)
	local search = Components.SearchBox.new({ Size = UDim2.fromOffset(300, UITheme.Size.InputHeight), Parent = searchRow })
	local listHolder: Frame = Create.new("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 180),
		LayoutOrder = 7,
		Parent = parent,
	})
	local list = Components.ScrollList.new({ Size = UDim2.new(0.6, 0, 1, 0), Position = UDim2.fromScale(0.4, 0), Parent = listHolder })
	local rows: { TextLabel } = {}
	for index = 1, 20 do
		local label = Create.Label({
			Text = Strings.Format(G.ScrollItem, { index = index }),
			Size = UDim2.new(1, 0, 0, 26),
			LayoutOrder = index,
		})
		list:Add(label)
		table.insert(rows, label)
	end
	search.Changed:Connect(function(text: string)
		local query = string.lower(text)
		for _, label in rows do
			label.Visible = query == "" or string.find(string.lower(label.Text), query, 1, true) ~= nil
		end
	end)
end

local function buildItems(page: Components.ScrollList)
	local parent = page.Instance
	sectionTitle(parent, G.TabItems, 1)
	Create.Label({
		Text = G.SlotTooltip,
		Color = UITheme.Colors.TextDim,
		TextSize = UITheme.TextSize.Small,
		Size = UDim2.new(1, 0, 0, 22),
		LayoutOrder = 2,
		Parent = parent,
	})

	local slots: Frame = Create.new("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 72),
		LayoutOrder = 3,
		Parent = parent,
	})
	Create.List(slots, Enum.FillDirection.Horizontal, UITheme.Padding.Small)
	type Sample = { Name: string, Count: number?, Upgrade: number?, Locked: boolean?, New: boolean? }
	local samples: { Sample } = {
		{ Name = "Brine Ore", Count = 37 },
		{ Name = "Rustwood Buckler", Upgrade = 2 },
		{ Name = "Tidewrought Longsword", Upgrade = 5, New = true },
		{ Name = "Cistern Lantern Core" },
		{ Name = "Coral Greatblade", Upgrade = 7, Locked = true },
		{ Name = "Penitent Halo" },
		{ Name = "Spireheart Needle", Upgrade = 10 },
	}
	for index, rarity in Enums.Rarity do
		local sample = samples[index]
		local slot = Components.ItemSlot.new({ LayoutOrder = index, Parent = slots })
		local item: Components.SlotItem = {
			Name = sample.Name,
			Rarity = rarity,
			Count = sample.Count,
			Upgrade = sample.Upgrade,
			Locked = sample.Locked,
			New = sample.New,
		}
		slot:SetItem(item)
		Components.Tooltip.Attach(slot.Instance, function(): Components.TooltipContent?
			return {
				Title = item.Name,
				TitleColor = UITheme.RarityColor(rarity),
				Subtitle = G.RarityNames[rarity],
				Lines = {
					{ Text = "+12% Tide damage", Color = UITheme.Colors.Heal },
					{ Text = "Siphon +15%", Color = UITheme.Colors.Heal },
				},
				Footer = Strings.Game.Tagline,
			}
		end)
	end
	local empty = Components.ItemSlot.new({ LayoutOrder = 99, Parent = slots })
	empty:SetItem(nil)

	-- Resource bars.
	local health = Components.ProgressBar.new({
		Color = UITheme.Colors.Health,
		TrailColor = UITheme.Colors.HealthTrail,
		ShowText = true,
		Size = UDim2.fromOffset(320, 18),
		Parent = row(parent, G.HealthBar, 4),
	})
	local current = Components.ProgressBar.new({
		Color = UITheme.Colors.Current,
		Flow = true,
		ShowText = true,
		Size = UDim2.fromOffset(320, 16),
		Parent = row(parent, G.CurrentBar, 5),
	})
	local stamina = Components.ProgressBar.new({
		Color = UITheme.Colors.Stamina,
		Size = UDim2.fromOffset(320, 6),
		Parent = row(parent, G.StaminaBar, 6),
	})
	local maxHealth, hp = 180, 180
	local maxCurrent, cur = 120, 120
	health:SetValue(hp, maxHealth, true)
	current:SetValue(cur, maxCurrent, true)
	stamina:SetValue(100, 100, true)

	local actions = row(parent, "", 7)
	Components.Button.new({
		Name = "Damage",
		Text = G.Damage,
		Variant = "Danger",
		LayoutOrder = 1,
		Parent = actions,
		OnActivated = function()
			hp = math.max(0, hp - 37)
			cur = math.max(0, cur - 25)
			health:SetValue(hp, maxHealth)
			current:SetValue(cur, maxCurrent)
			stamina:SetValue(math.random(10, 90), 100)
		end,
	})
	Components.Button.new({
		Name = "Heal",
		Text = G.Heal,
		Variant = "Primary",
		LayoutOrder = 2,
		Parent = actions,
		OnActivated = function()
			hp = maxHealth
			cur = maxCurrent
			health:SetValue(hp, maxHealth)
			current:SetValue(cur, maxCurrent)
			stamina:SetValue(100, 100)
		end,
	})
end

local function buildFeedback(page: Components.ScrollList)
	local parent = page.Instance
	sectionTitle(parent, G.TabFeedback, 1)
	local buttons = row(parent, "", 2)
	Components.Button.new({
		Name = "ShowToast",
		Text = G.ShowToast,
		LayoutOrder = 1,
		Parent = buttons,
		OnActivated = function()
			UIController.Toast({
				Title = G.ToastTitle,
				Body = G.ToastBody,
				Color = UITheme.Rarity.Epic,
				Key = "gallery-toast",
			})
		end,
	})
	Components.Button.new({
		Name = "ShowConfirm",
		Text = G.ShowConfirm,
		LayoutOrder = 2,
		Parent = buttons,
		OnActivated = function()
			UIController.Confirm({
				Title = G.ConfirmTitle,
				Message = G.ConfirmBody,
				Danger = true,
			}):andThen(function(confirmed: boolean)
				UIController.Toast({
					Title = if confirmed then G.ConfirmResultYes else G.ConfirmResultNo,
					Color = if confirmed then UITheme.Colors.Danger else UITheme.Colors.TextMuted,
				})
				return nil
			end)
		end,
	})
	Components.Button.new({
		Name = "ShowModal",
		Text = G.ShowModal,
		LayoutOrder = 3,
		Parent = buttons,
		OnActivated = function()
			local modal = Components.Modal.new({ Title = G.ModalTitle, Size = UDim2.fromOffset(480, 220) })
			Create.Label({
				Text = G.ModalBody,
				Color = UITheme.Colors.TextMuted,
				Wrapped = true,
				YAlignment = Enum.TextYAlignment.Top,
				Size = UDim2.fromScale(1, 1),
				Parent = modal.Content,
			})
			modal.Closed:Once(function()
				modal:Destroy()
			end)
			modal:Open()
		end,
	})
end

local function build(content: Frame, maid: Maid.Maid): any
	Create.Label({
		Text = G.Subtitle,
		Color = UITheme.Colors.TextDim,
		TextSize = UITheme.TextSize.Small,
		Size = UDim2.new(1, 0, 0, 20),
		Parent = content,
	})
	local tabs = Components.TabBar.new({
		Tabs = {
			{ Id = "Buttons", Text = G.TabButtons },
			{ Id = "Inputs", Text = G.TabInputs },
			{ Id = "Items", Text = G.TabItems },
			{ Id = "Feedback", Text = G.TabFeedback },
		},
		Position = UDim2.fromOffset(0, 24),
		Parent = content,
	})
	maid:Add(tabs)

	local pages: { [string]: Components.ScrollList } = {}
	for _, id in { "Buttons", "Inputs", "Items", "Feedback" } do
		local page = Components.ScrollList.new({
			Name = id,
			Position = UDim2.fromOffset(0, 24 + UITheme.Size.TabHeight + UITheme.Padding.Medium),
			Size = UDim2.new(1, 0, 1, -(24 + UITheme.Size.TabHeight + UITheme.Padding.Medium)),
			Spacing = UITheme.Padding.Small,
			Parent = content,
		})
		page.Instance.Visible = id == "Buttons"
		pages[id] = page
		maid:Add(page)
	end
	buildButtons(pages.Buttons)
	buildInputs(pages.Inputs, maid)
	buildItems(pages.Items)
	buildFeedback(pages.Feedback)

	tabs.Changed:Connect(function(id: string)
		for pageId, page in pages do
			page.Instance.Visible = pageId == id
		end
	end)

	return { TabBar = tabs }
end

function DevGalleryController.Init()
	if not RunService:IsStudio() then
		return
	end
	UIController.RegisterMenu({
		Id = "DevGallery",
		Title = G.Title,
		Action = "DevGallery",
		FullScreen = true,
		ShowInHub = true,
		HubGlyph = "UI",
		Build = build,
	})
end

function DevGalleryController.Start()
	if not RunService:IsStudio() then
		return
	end
	local hook = Instance.new("BindableFunction")
	hook.Name = "ClientDevHooks"
	hook.OnInvoke = function(command: string, value: any): any
		if command == "Open" and type(value) == "string" then
			UIController.Open(value)
			return UIController.GetOpen()
		elseif command == "Close" then
			UIController.Close()
			return true
		elseif command == "Action" and type(value) == "string" then
			local action = value :: Enums.Action
			local began = InputController.BeginAction(action)
			InputController.EndAction(action)
			return began
		elseif command == "Menu" then
			return UIController.GetOpen()
		elseif command == "Station" and type(value) == "string" then
			for _, instance in CollectionService:GetTagged("ItemStation") do
				if instance:GetAttribute("StationId") == value then
					StationController.Open(instance)
					return true
				end
			end
			return false
		end
		return nil
	end
	hook.Parent = Players.LocalPlayer
end

return DevGalleryController
