--!strict
--[[
	ItemHUDController
	The item pieces of the HUD:

	  - Quick items: two slots left of the spell bar (Z / X, gamepad Y,
	    or tap them on touch) showing the consumable, how many you carry and
	    the shared cooldown. Throwables land where you aim.
	  - Tracked recipe: pinned under the Pressure gauge, listing the
	    materials still missing (have / need) until you craft it or untrack.
	  - Food buffs: small timers under the vitals while they last.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Attributes = require(Shared.Attributes)
local Strings = require(Shared.Strings)
local Net = require(Shared.Net)
local Items = require(Shared.Data.Items)
local Recipes = require(Shared.Data.Recipes)
local Rules = require(Shared.Data.InventoryRules)

local UI = script.Parent.Parent.UI
local UITheme = require(UI.UITheme)
local Create = require(UI.Create)
local Layers = require(UI.Layers)
local Device = require(UI.Device)
local Components = require(UI.Components)
local ItemText = require(UI.ItemText)

local DataController = require(script.Parent.DataController)
local InputController = require(script.Parent.InputController)
local SpellController = require(script.Parent.SpellController)
local UIController = require(script.Parent.UIController)

local A = Attributes.Names
local S = Strings.Inventory
local QUICK_SIZE = 52
local QUICK_ACTIONS = { "Consumable1", "Consumable2" }
local player = Players.LocalPlayer

local ItemHUDController = {}

type Quick = {
	Slot: Components.ItemSlot,
	Key: TextLabel,
	Shade: Frame,
}

local quick: { Quick } = {}
local tracker: Frame? = nil
local trackerList: Frame? = nil
local buffBar: Frame? = nil

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

local function useQuick(index: number)
	if UIController.IsMenuOpen() then
		return
	end
	local aim = SpellController.AimPoint()
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	if not aim and root and root:IsA("BasePart") then
		aim = root.Position + root.CFrame.LookVector * 12
	end
	Net.FireServer("RequestQuickItem", index, aim or Vector3.zero)
end

-- QUICK ITEMS ------------------------------------------------------------------------------

local function buildQuick()
	local layer = Layers.Get("HUD")
	-- Sits left of the spell bar (SpellController: 4 x 58 + gaps + Art = ~330 wide).
	local holder: Frame = Create.new("Frame", {
		Name = "QuickItems",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(0.5, -186, 1, -22),
		Size = UDim2.fromOffset(QUICK_SIZE * 2 + 8, QUICK_SIZE + 18),
		Parent = layer,
	})
	for index = 1, 2 do
		local slot = Components.ItemSlot.new({
			Size = QUICK_SIZE,
			Name = `Quick{index}`,
			Position = UDim2.fromOffset((index - 1) * (QUICK_SIZE + 8), 16),
			Parent = holder,
		})
		local key = Create.Label({
			Text = "",
			Font = UITheme.Fonts.BodyBold,
			TextSize = UITheme.TextSize.Caption,
			Color = UITheme.Colors.TextMuted,
			XAlignment = Enum.TextXAlignment.Center,
			Position = UDim2.fromOffset((index - 1) * (QUICK_SIZE + 8), 0),
			Size = UDim2.fromOffset(QUICK_SIZE, 14),
			Parent = holder,
		})
		local shade: Frame = Create.new("Frame", {
			Name = "Cooldown",
			BackgroundColor3 = Color3.new(0, 0, 0),
			BackgroundTransparency = 0.45,
			BorderSizePixel = 0,
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.fromScale(0, 1),
			Size = UDim2.fromScale(1, 0),
			ZIndex = 6,
			Parent = slot.Instance,
		})
		Create.Corner(shade, UITheme.CornerSmall)
		slot.Activated:Connect(function()
			useQuick(index)
		end)
		Components.Tooltip.Attach(slot.Instance, function(): Components.TooltipContent?
			local data = DataController.GetData()
			local defId = if data then data.Hotbar.Consumables[index] else nil
			if not defId or defId == "" then
				return { Title = Strings.Actions[QUICK_ACTIONS[index]] or "", Subtitle = S.QuickEmpty }
			end
			return { Title = ItemText.Name(defId), Lines = { { Text = ItemText.Description(defId) } } }
		end)
		quick[index] = { Slot = slot, Key = key, Shade = shade }
	end
end

local function refreshQuick()
	local data = DataController.GetData()
	for index, entry in quick do
		local defId = if data then data.Hotbar.Consumables[index] else nil
		local def = if defId then Items.Get(defId) else nil
		if data and defId and def then
			local count = Rules.Count(data, defId)
			entry.Slot:SetItem({ Name = ItemText.Name(defId), Rarity = def.Rarity :: string, DefId = defId, Count = count })
			entry.Slot.Instance.BackgroundTransparency = if count == 0 then 0.6 else UITheme.SunkenTransparency
		else
			entry.Slot:SetItem(nil)
		end
		entry.Key.Text = if Device.IsTouch() then "" else InputController.GetPrompt(QUICK_ACTIONS[index])
	end
end

-- TRACKED RECIPE -------------------------------------------------------------------------------

local function buildTracker()
	local frame: Frame = Create.new("Frame", {
		Name = "RecipeTracker",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -16, 0, 56),
		Size = UDim2.fromOffset(250, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Visible = false,
		Parent = Layers.Get("HUD"),
	})
	Create.ApplyPanelStyle(frame, { Glow = false, Transparency = 0.25, Color = UITheme.Colors.HudPanel, StrokeColor = UITheme.Colors.Brass, StrokeTransparency = 0.6 })
	Create.Padding(frame, UITheme.Padding.Small)
	local list: Frame = Create.new("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = frame,
	})
	Create.List(list, Enum.FillDirection.Vertical, 2)
	tracker = frame
	trackerList = list
end

local function refreshTracker()
	local frame, list = tracker, trackerList
	local data = DataController.GetData()
	if not frame or not list then
		return
	end
	local recipe = if data then Recipes.Get(data.ItemState.TrackedRecipe) else nil
	frame.Visible = recipe ~= nil
	for _, child in list:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	if not recipe or not data then
		return
	end
	Create.Label({
		Text = `{Strings.Stations.Tracking}: {ItemText.Name(recipe.Output)}`,
		Font = UITheme.Fonts.BodyBold,
		TextSize = UITheme.TextSize.Small,
		Color = UITheme.Colors.Brass,
		Size = UDim2.new(1, 0, 0, 20),
		LayoutOrder = 0,
		Parent = list,
	})
	local order = 0
	local ids = {}
	for id in recipe.Materials do
		table.insert(ids, id)
	end
	table.sort(ids)
	for _, id in ids do
		order += 1
		local have, need = Rules.Count(data, id, true), recipe.Materials[id]
		Create.Label({
			Text = `{ItemText.Name(id)}  {math.min(have, need)} / {need}`,
			TextSize = UITheme.TextSize.Small,
			Color = if have >= need then UITheme.Colors.Heal else UITheme.Colors.Text,
			Size = UDim2.new(1, 0, 0, 18),
			LayoutOrder = order,
			Parent = list,
		})
	end
end

-- FOOD BUFFS ----------------------------------------------------------------------------------------

local function buildBuffs()
	local H = UITheme.HUD
	local bar: Frame = Create.new("Frame", {
		Name = "Buffs",
		BackgroundTransparency = 1,
		-- Below the vitals cluster (its XP bar ends just above this).
		Position = UDim2.fromOffset(H.Margin.X + H.BarsX, H.Margin.Y + H.PortraitSize + H.RingThickness * 2 + 14),
		Size = UDim2.fromOffset(300, 24),
		Parent = Layers.Get("HUD"),
	})
	Create.List(bar, Enum.FillDirection.Horizontal, 6)
	buffBar = bar
end

local function refreshBuffs()
	local bar = buffBar
	if not bar then
		return
	end
	local text = player:GetAttribute(A.Buffs)
	local t = serverNow()
	local active: { [string]: number } = {}
	if type(text) == "string" and text ~= "" then
		for _, part in string.split(text, ",") do
			local id, ends = string.match(part, "^(%w+):(%d+)$")
			if id and ends then
				active[id] = tonumber(ends) :: number
			end
		end
	end
	for _, child in bar:GetChildren() do
		if child:IsA("Frame") and not active[child.Name] then
			child:Destroy()
		end
	end
	for id, ends in active do
		local chip = bar:FindFirstChild(id) :: Frame?
		if not chip then
			local created: Frame = Create.new("Frame", {
				Name = id,
				BackgroundColor3 = UITheme.Colors.HudRaised,
				BackgroundTransparency = 0.25,
				Size = UDim2.fromOffset(92, 22),
				Parent = bar,
			})
			Create.Corner(created, UITheme.CornerPill)
			Create.Label({
				Name = "Text",
				Text = "",
				TextSize = UITheme.TextSize.Caption,
				Color = UITheme.Colors.Heal,
				XAlignment = Enum.TextXAlignment.Center,
				Size = UDim2.fromScale(1, 1),
				Parent = created,
			})
			chip = created
		end
		local remaining = math.max(0, ends - t)
		local label = (chip :: Frame):FindFirstChild("Text") :: TextLabel?
		if label then
			-- Buffs come from food (item ids) and Position abilities (ability ids).
			local ability = Strings.Abilities[id]
			local name = if ability then ability.Name else ItemText.Name(id)
			label.Text = `{name} {math.floor(remaining / 60)}:{string.format("%02d", math.floor(remaining % 60))}`
			label.TextTruncate = Enum.TextTruncate.AtEnd
		end
	end
end

function ItemHUDController.Init()
	InputController.ActionBegan:Connect(function(action: string)
		local index = table.find(QUICK_ACTIONS, action)
		if index then
			useQuick(index)
		end
	end)
end

function ItemHUDController.Start()
	buildQuick()
	buildTracker()
	buildBuffs()
	local function refreshAll()
		refreshQuick()
		refreshTracker()
	end
	DataController.Ready:Connect(refreshAll)
	DataController.Changed:Connect(function(path: { string })
		local root = path[1]
		if root == "Inventory" or root == "Hotbar" or root == "ItemState" then
			refreshAll()
		end
	end)
	InputController.BindingsChanged:Connect(refreshQuick)
	if DataController.IsReady() then
		refreshAll()
	end

	-- Cooldown shades and buff timers.
	local accumulator = 0
	RunService.RenderStepped:Connect(function(dt: number)
		local ready = player:GetAttribute(A.QuickItemReadyAt)
		local left = if type(ready) == "number" then math.max(0, ready - serverNow()) else 0
		local fraction = math.clamp(left / Config.Items.Consumables.SharedCooldown, 0, 1)
		for _, entry in quick do
			entry.Shade.Size = UDim2.fromScale(1, fraction)
		end
		accumulator += dt
		if accumulator >= 0.5 then
			accumulator = 0
			refreshBuffs()
		end
	end)
end

return ItemHUDController
