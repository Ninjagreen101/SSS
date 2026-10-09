--!strict
--[[
	StationController
	Every station in town opens one window, laid out for what it does
	(Spec Section 12, menus 7 and 8):

	  Forge          Craft | Upgrade | Repair | Salvage
	  Armorer        Craft | Repair
	  Alchemy, Loom, Altar   Craft
	  Shop, TokenShop        Buy | Sell | Buy back
	  Bank           your bag and the vault side by side

	Craft: the recipe book on the left (greyed out until you have the
	materials, "Track" pins the missing ones to the HUD), the recipe's
	materials and fee in the middle, the item on the right with a big Craft
	button that fills a progress ring, then reveals the item in its rarity
	colour.

	Prompts: each station gets a "Use" ProximityPrompt in The Spire's style
	(InteractionController draws it). The window closes if you walk away;
	the server checks distance on every request anyway.
]]

local CollectionService = game:GetService("CollectionService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Attributes = require(Shared.Attributes)
local Strings = require(Shared.Strings)
local Types = require(Shared.Types)
local Net = require(Shared.Net)
local Maid = require(Shared.Util.Maid)
local TweenUtil = require(Shared.Util.TweenUtil)
local Items = require(Shared.Data.Items)
local Recipes = require(Shared.Data.Recipes)
local Shops = require(Shared.Data.Shops)
local GearStats = require(Shared.Data.GearStats)
local Rules = require(Shared.Data.InventoryRules)

local UI = script.Parent.Parent.UI
local UITheme = require(UI.UITheme)
local Create = require(UI.Create)
local Device = require(UI.Device)
local UISound = require(UI.UISound)
local Components = require(UI.Components)
local ItemText = require(UI.ItemText)
local ItemIcon = require(UI.ItemIcon)

local DataController = require(script.Parent.DataController)
local UIController = require(script.Parent.UIController)

type ItemInstance = Types.ItemInstance
type PlayerData = Types.PlayerData

local A = Attributes.Names
local S = Strings.Stations
local I = Strings.Inventory
local MENU_ID = "Station"
local ROW_HEIGHT = 56
local player = Players.LocalPlayer

local TABS: { [string]: { string } } = {
	Forge = { "Craft", "Upgrade", "Repair", "Salvage" },
	Armorer = { "Craft", "Repair" },
	Alchemy = { "Craft" },
	Loom = { "Craft" },
	Altar = { "Craft" },
	Shop = { "Buy", "Sell", "Buyback" },
	TokenShop = { "Buy", "Sell", "Buyback" },
	Bank = { "Bank" },
}
local TAB_TEXT: { [string]: string } = {
	Craft = S.TabCraft,
	Upgrade = S.TabUpgrade,
	Repair = S.TabRepair,
	Salvage = S.TabSalvage,
	Buy = S.TabBuy,
	Sell = S.TabSell,
	Buyback = S.TabBuyback,
	Bank = S.TabDeposit,
}

local StationController = {}

local station: Instance? = nil
local craftJob: { Recipe: string, EndsAt: number }? = nil
local refreshCurrent: (() -> ())? = nil
local revealCurrent: ((defId: string, rarity: string?, count: number?) -> ())? = nil
local craftProgress: ((alpha: number) -> ())? = nil

local function data(): PlayerData?
	return DataController.GetData()
end

local function stationAttribute(name: string): string
	local value = if station then station:GetAttribute(name) else nil
	return if type(value) == "string" then value else ""
end

local function kind(): string
	return stationAttribute(A.StationKind)
end

local function request(action: string, id: string, count: number?)
	if station then
		Net.FireServer("RequestStation", stationAttribute(A.StationId), action, id, count or 1)
	end
end

local function positionOf(instance: Instance): Vector3?
	if instance:IsA("Model") then
		return instance:GetPivot().Position
	elseif instance:IsA("BasePart") then
		return instance.Position
	end
	return nil
end

local function currencyName(currency: string, floor: string?): string
	if currency == "Gold" then
		return I.Gold
	elseif currency == "Shards" then
		return I.Shards
	end
	return Strings.Format(I.FloorTokens, { floor = floor or "1" })
end

-- ROWS --------------------------------------------------------------------------------

type RowProps = {
	Key: string, -- stable id (recipe id, item uid...) used to keep gamepad selection across rebuilds
	DefId: string,
	Rarity: string,
	Title: string,
	Subtitle: string?,
	Right: string?,
	RightColor: Color3?,
	Dim: boolean?,
	Selected: boolean?,
	Order: number,
	OnSelect: () -> (),
}

-- Gamepad selection across rebuilds. Lists are rebuilt after every change
-- (a purchase, an upgrade...), which destroys the selected row; without
-- this a controller player would lose their place after every press.
-- Call rememberSelection(container) before clearing, restoreSelection()
-- after rebuilding: the row with the same key is selected again, or the
-- first row if that one is gone.
local reselectKey: string? = nil
local reselectFallback: GuiObject? = nil
local reselectActive = false
local restoreSelection: () -> ()

local function rememberSelection(container: Instance)
	local selected = GuiService.SelectedObject
	reselectActive = selected ~= nil and selected:IsDescendantOf(container)
	local key = if reselectActive and selected then selected:GetAttribute("RowKey") else nil
	reselectKey = if type(key) == "string" then key else nil
	reselectFallback = nil
	if reselectActive then
		-- Rebuilds are synchronous, so this runs right after the list is rebuilt.
		task.defer(restoreSelection)
	end
end

local function offerSelection(row: GuiObject, key: string)
	row:SetAttribute("RowKey", key)
	if not reselectActive then
		return
	end
	if reselectFallback == nil then
		reselectFallback = row
	end
	if key == reselectKey then
		reselectKey = nil
		reselectActive = false
		GuiService.SelectedObject = row
	end
end

function restoreSelection()
	if reselectActive and reselectFallback and reselectFallback.Parent then
		GuiService.SelectedObject = reselectFallback
	end
	reselectActive = false
	reselectKey = nil
	reselectFallback = nil
end

-- A selectable list row: icon, name (rarity colour), detail line, value on the right.
local function itemRow(list: Components.ScrollList, maid: Maid.Maid, props: RowProps): TextButton
	local row: TextButton = Create.new("TextButton", {
		Name = props.Title,
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = if props.Selected then UITheme.Colors.PanelHover else UITheme.Colors.PanelRaised,
		BackgroundTransparency = if props.Selected then 0.05 else 0.35,
		Size = UDim2.new(1, -8, 0, ROW_HEIGHT),
		LayoutOrder = props.Order,
		SelectionImageObject = Create.SelectionImage(),
	})
	Create.Corner(row, UITheme.CornerSmall)
	if props.Selected then
		Create.Stroke(row, UITheme.Colors.Current, 1.5, 0.2)
	end
	local icon = ItemIcon.new({ Size = UDim2.fromOffset(44, 44), Position = UDim2.fromOffset(6, 6), Parent = row })
	icon:Set(props.DefId, props.Rarity)
	local fade = if props.Dim then 0.45 else 0
	local title = Create.Label({
		Text = props.Title,
		Font = UITheme.Fonts.BodyBold,
		TextSize = UITheme.TextSize.Body,
		Color = UITheme.RarityColor(props.Rarity),
		Position = UDim2.fromOffset(58, 6),
		Size = UDim2.new(1, -150, 0, 22),
		Parent = row,
	})
	title.TextTransparency = fade
	title.TextTruncate = Enum.TextTruncate.AtEnd
	if props.Subtitle then
		local sub = Create.Label({
			Text = props.Subtitle,
			TextSize = UITheme.TextSize.Caption,
			Color = UITheme.Colors.TextMuted,
			RichText = true,
			Position = UDim2.fromOffset(58, 30),
			Size = UDim2.new(1, -150, 0, 18),
			Parent = row,
		})
		sub.TextTransparency = fade
		sub.TextTruncate = Enum.TextTruncate.AtEnd
	end
	if props.Right then
		local right = Create.Label({
			Text = props.Right,
			Font = UITheme.Fonts.Numbers,
			TextSize = UITheme.TextSize.Body,
			RichText = true,
			Color = props.RightColor or UITheme.Colors.Stamina,
			XAlignment = Enum.TextXAlignment.Right,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -10, 0, 0),
			Size = UDim2.new(0, 90, 1, 0),
			Parent = row,
		})
		right.TextTransparency = fade
	end
	maid:Add(row.Activated:Connect(function()
		UISound.Play("UIClick")
		props.OnSelect()
	end))
	list:Add(row)
	offerSelection(row, props.Key)
	return row
end

-- PREVIEW PANEL (right side of most tabs) -----------------------------------------------------

type Preview = {
	Frame: Frame,
	Show: (item: ItemInstance?, extra: { Components.TooltipLine }?) -> (),
	Button: Components.Button,
	SecondButton: Components.Button,
	Ring: Components.RadialProgress,
	Reveal: (defId: string, rarity: string?, count: number?) -> (),
}

local function buildPreview(parent: Instance, maid: Maid.Maid, position: UDim2, size: UDim2): Preview
	local frame: Frame = Create.new("Frame", {
		Name = "Preview",
		BackgroundColor3 = UITheme.Colors.PanelSunken,
		BackgroundTransparency = UITheme.SunkenTransparency,
		Position = position,
		Size = size,
		Parent = parent,
	})
	Create.Corner(frame)
	Create.Padding(frame, UITheme.Padding.Medium)
	local iconHolder: Frame = Create.new("Frame", {
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0),
		Size = UDim2.fromOffset(120, 120),
		Parent = frame,
	})
	local glow: Frame = Create.new("Frame", {
		Name = "Glow",
		BackgroundColor3 = UITheme.Colors.Current,
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.9, 0.9),
		Parent = iconHolder,
	})
	Create.Corner(glow, UITheme.CornerPill)
	local icon = ItemIcon.new({ Size = UDim2.fromScale(1, 1), Parent = iconHolder })
	local ring = Components.RadialProgress.new({
		Color = UITheme.Colors.Current,
		Thickness = 5,
		Size = UDim2.fromScale(1.1, 1.1),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = 5,
		Parent = iconHolder,
	})
	ring.Instance.Visible = false
	maid:Add(ring)
	local title = Create.Label({
		Text = "",
		Font = UITheme.Fonts.Title,
		TextSize = UITheme.TextSize.Heading,
		XAlignment = Enum.TextXAlignment.Center,
		Wrapped = true,
		Position = UDim2.fromOffset(0, 126),
		Size = UDim2.new(1, 0, 0, 28),
		Parent = frame,
	})
	local subtitle = Create.Label({
		Text = "",
		TextSize = UITheme.TextSize.Small,
		Color = UITheme.Colors.TextMuted,
		XAlignment = Enum.TextXAlignment.Center,
		Position = UDim2.fromOffset(0, 156),
		Size = UDim2.new(1, 0, 0, 18),
		Parent = frame,
	})
	local lines = Components.ScrollList.new({
		Position = UDim2.fromOffset(0, 180),
		Size = UDim2.new(1, 0, 1, -(180 + UITheme.Size.ButtonHeight * 2 + UITheme.Padding.Small * 2)),
		Spacing = 2,
		Parent = frame,
	})
	maid:Add(lines)
	local buttons: Frame = Create.new("Frame", {
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, UITheme.Size.ButtonHeight * 2 + UITheme.Padding.Small),
		Parent = frame,
	})
	Create.List(buttons, Enum.FillDirection.Vertical, UITheme.Padding.Small)
	local button = Components.Button.new({ Text = "", Variant = "Primary", Size = UDim2.new(1, 0, 0, UITheme.Size.ButtonHeight), LayoutOrder = 2, Parent = buttons })
	local second = Components.Button.new({ Text = "", Size = UDim2.new(1, 0, 0, UITheme.Size.ButtonHeight), LayoutOrder = 1, Parent = buttons })
	maid:Add(button)
	maid:Add(second)

	local function show(item: ItemInstance?, extra: { Components.TooltipLine }?)
		lines:Clear()
		local current = data()
		if not item then
			icon:Set(nil)
			title.Text = ""
			subtitle.Text = ""
			button.Instance.Visible = false
			second.Instance.Visible = false
			return
		end
		local tooltip = ItemText.Tooltip(item, current)
		icon:Set(item.DefId, item.Rarity)
		title.Text = if tooltip then tooltip.Title else ItemText.Name(item.DefId)
		title.TextColor3 = UITheme.RarityColor(item.Rarity)
		subtitle.Text = if tooltip then tooltip.Subtitle or "" else ""
		local order = 0
		local function add(line: Components.TooltipLine)
			order += 1
			lines:Add(Create.Label({
				Text = line.Text,
				Font = if line.Bold then UITheme.Fonts.BodyBold else UITheme.Fonts.Body,
				TextSize = UITheme.TextSize.Small,
				Color = line.Color,
				RichText = true,
				Wrapped = true,
				AutomaticSize = Enum.AutomaticSize.Y,
				Size = UDim2.new(1, -8, 0, 20),
				LayoutOrder = order,
			}))
		end
		local before: { Components.TooltipLine } = extra or {}
		for _, line in before do
			add(line)
		end
		if tooltip then
			local tooltipLines: { Components.TooltipLine } = tooltip.Lines or {}
			for _, line in tooltipLines do
				add(line)
			end
		end
	end

	-- The crafted / bought item pops in its rarity colour.
	local function reveal(defId: string, rarity: string?, count: number?)
		local item = ItemText.Preview(defId, count)
		if rarity then
			item.Rarity = rarity :: any
		end
		icon:Set(defId, item.Rarity)
		local color = UITheme.RarityColor(item.Rarity)
		glow.BackgroundColor3 = color
		glow.BackgroundTransparency = 0.35
		glow.Size = UDim2.fromScale(0.3, 0.3)
		TweenUtil.Play(glow, 0.5, { Size = UDim2.fromScale(1.3, 1.3), BackgroundTransparency = 1 }, Enum.EasingStyle.Quad)
		iconHolder.Size = UDim2.fromOffset(80, 80)
		TweenUtil.Play(iconHolder, 0.35, { Size = UDim2.fromOffset(120, 120) }, Enum.EasingStyle.Back)
		title.Text = ItemText.Name(defId) .. (if count and count > 1 then `  x{count}` else "")
		title.TextColor3 = color
	end

	show(nil)
	return { Frame = frame, Show = show, Button = button, SecondButton = second, Ring = ring, Reveal = reveal }
end

-- TABS ---------------------------------------------------------------------------------------------

type Page = { Render: () -> () }

local function materialsLines(current: PlayerData, materials: { [string]: number }): { Components.TooltipLine }
	local out: { Components.TooltipLine } = {}
	local ids = {}
	for id in materials do
		table.insert(ids, id)
	end
	table.sort(ids)
	for _, id in ids do
		local have = Rules.Count(current, id, true)
		local need = materials[id]
		table.insert(out, {
			Text = `{ItemText.Name(id)}   {Strings.Format(S.Have, { have = have, need = need })}`,
			Color = if have >= need then UITheme.Colors.Heal else UITheme.Colors.Danger,
		})
	end
	return out
end

-- Craft: recipe book | materials | preview.
local function craftPage(content: Frame, maid: Maid.Maid): Page
	local selected: string? = nil
	local list = Components.ScrollList.new({ Size = UDim2.new(0.42, -8, 1, 0), Spacing = 4, Parent = content })
	maid:Add(list)
	local preview = buildPreview(content, maid, UDim2.fromScale(0.42, 0), UDim2.new(0.58, 0, 1, 0))
	local listMaid = Maid.new()
	maid:Add(listMaid)
	local empty = Create.Label({ Text = S.NoRecipes, Color = UITheme.Colors.TextDim, Wrapped = true, XAlignment = Enum.TextXAlignment.Center, Size = UDim2.new(0.42, -8, 1, 0), Parent = content })

	preview.Button.Activated:Connect(function()
		if selected and not craftJob then
			request("Craft", selected)
		end
	end)
	preview.SecondButton.Activated:Connect(function()
		if selected then
			Net.FireServer("RequestItemAction", "Track", "", selected, 0)
		end
	end)

	local function render()
		rememberSelection(list.Instance)
		listMaid:Clean()
		list:Clear()
		local current = data()
		if not current then
			return
		end
		local known = {}
		for _, recipe in Recipes.ForStation(kind()) do
			if current.RecipesKnown[recipe.Id] then
				table.insert(known, recipe)
			end
		end
		empty.Visible = #known == 0
		if selected and not current.RecipesKnown[selected] then
			selected = nil
		end
		if not selected and known[1] then
			selected = known[1].Id
		end
		for index, recipe in known do
			local ready = Rules.CanCraft(current, recipe.Id)
			local def = Items.Get(recipe.Output)
			itemRow(list, listMaid, {
				Key = recipe.Id,
				DefId = recipe.Output,
				Rarity = if def then def.Rarity else "Common",
				Title = ItemText.Name(recipe.Output) .. (if recipe.Count > 1 then `  x{recipe.Count}` else ""),
				Subtitle = if current.ItemState.TrackedRecipe == recipe.Id then S.Tracking else nil,
				Right = if recipe.Gold > 0 then tostring(recipe.Gold) else nil,
				Dim = not ready,
				Selected = recipe.Id == selected,
				Order = index,
				OnSelect = function()
					selected = recipe.Id
					render()
				end,
			})
		end
		local recipe = if selected then Recipes.Get(selected) else nil
		if not recipe then
			preview.Show(nil)
			return
		end
		local extra: { Components.TooltipLine } = { { Text = S.Materials, Bold = true, Color = UITheme.Colors.Accent } }
		for _, line in materialsLines(current, recipe.Materials) do
			table.insert(extra, line)
		end
		if recipe.Gold > 0 then
			table.insert(extra, {
				Text = Strings.Format(S.Fee, { gold = recipe.Gold }),
				Color = if current.Currencies.Gold >= recipe.Gold then UITheme.Colors.Stamina else UITheme.Colors.Danger,
			})
		end
		table.insert(extra, { Text = " " })
		preview.Show(ItemText.Preview(recipe.Output, recipe.Count), extra)
		preview.Button.Instance.Visible = true
		preview.SecondButton.Instance.Visible = true
		local busy = craftJob ~= nil
		preview.Button:SetText(if busy then S.Crafting elseif recipe.Count > 1 then Strings.Format(S.CraftCount, { count = recipe.Count }) else S.Craft)
		preview.Button:SetEnabled(not busy and Rules.CanCraft(current, recipe.Id))
		preview.SecondButton:SetText(if current.ItemState.TrackedRecipe == recipe.Id then I.Untrack else S.Track)
	end

	revealCurrent = preview.Reveal
	craftProgress = function(alpha: number)
		preview.Ring.Instance.Visible = alpha > 0 and alpha < 1
		preview.Ring:SetValue(alpha)
	end
	return { Render = render }
end

-- Gear in the bag (equipped first), for upgrade / repair / salvage lists.
local function gearList(current: PlayerData, keep: (item: ItemInstance, def: Items.ItemDef) -> boolean): { ItemInstance }
	local list = {}
	for _, item in current.Inventory.Items do
		local def = Items.Get(item.DefId)
		if def and Items.IsGear(def) and keep(item, def) then
			table.insert(list, item)
		end
	end
	table.sort(list, function(a: ItemInstance, b: ItemInstance): boolean
		local ea, eb = Rules.EquippedSlot(current, a.Uid) ~= nil, Rules.EquippedSlot(current, b.Uid) ~= nil
		if ea ~= eb then
			return ea
		end
		local ra, rb = Items.RarityRank(a.Rarity), Items.RarityRank(b.Rarity)
		if ra ~= rb then
			return ra > rb
		end
		return ItemText.Name(a.DefId) < ItemText.Name(b.DefId)
	end)
	return list
end

-- Upgrade: gear list | preview with the next level's numbers, cost and chance.
local function upgradePage(content: Frame, maid: Maid.Maid): Page
	local selected: string? = nil
	local list = Components.ScrollList.new({ Size = UDim2.new(0.42, -8, 1, 0), Spacing = 4, Parent = content })
	maid:Add(list)
	local preview = buildPreview(content, maid, UDim2.fromScale(0.42, 0), UDim2.new(0.58, 0, 1, 0))
	local listMaid = Maid.new()
	maid:Add(listMaid)

	preview.Button.Activated:Connect(function()
		local current = data()
		local item = if current and selected then current.Inventory.Items[selected] else nil
		if not item then
			return
		end
		local step = Rules.UpgradeStep(item.Upgrade + 1)
		if step and step.FailChance > 0 then
			UIController.Confirm({
				Title = S.ConfirmUpgradeTitle,
				Message = Strings.Format(S.ConfirmUpgrade, { chance = math.floor((1 - step.FailChance) * 100 + 0.5), name = ItemText.Name(item.DefId), level = item.Upgrade }),
				ConfirmText = Strings.Format(S.UpgradeTo, { level = item.Upgrade + 1 }),
			}):andThen(function(yes: boolean): any
				if yes then
					request("Upgrade", item.Uid)
				end
				return nil
			end)
		else
			request("Upgrade", item.Uid)
		end
	end)

	local function render()
		rememberSelection(list.Instance)
		listMaid:Clean()
		list:Clear()
		local current = data()
		if not current then
			return
		end
		local gear = gearList(current, function(): boolean
			return true
		end)
		if selected and not current.Inventory.Items[selected] then
			selected = nil
		end
		if not selected and gear[1] then
			selected = gear[1].Uid
		end
		for index, item in gear do
			itemRow(list, listMaid, {
				Key = item.Uid,
				DefId = item.DefId,
				Rarity = item.Rarity,
				Title = ItemText.FullName(item),
				Subtitle = if Rules.EquippedSlot(current, item.Uid) then I.Equipped else ItemText.RarityName(item.Rarity),
				Right = if item.Upgrade >= Config.Items.Upgrade.MaxLevel then "MAX" else `+{item.Upgrade + 1}`,
				RightColor = UITheme.Colors.Parry,
				Selected = item.Uid == selected,
				Order = index,
				OnSelect = function()
					selected = item.Uid
					render()
				end,
			})
		end
		local item = if selected then current.Inventory.Items[selected] else nil
		if not item then
			preview.Show(nil)
			return
		end
		local extra: { Components.TooltipLine } = {}
		local maxed = item.Upgrade >= Config.Items.Upgrade.MaxLevel
		local step = Rules.UpgradeStep(item.Upgrade + 1)
		if not maxed and step then
			-- What the next level changes, using the real numbers.
			local nextCopy = table.clone(item)
			nextCopy.Upgrade += 1
			local now, after = GearStats.ItemNumbers(item), GearStats.ItemNumbers(nextCopy)
			if now and after then
				if now.Damage and after.Damage then
					table.insert(extra, {
						Text = Strings.Format(S.NextDamage, { from = string.format("%.1f", now.Damage), to = string.format("%.1f", after.Damage) }),
						Bold = true,
					})
				end
				if now.Armor > 0 then
					table.insert(extra, {
						Text = Strings.Format(S.NextArmor, { from = string.format("%.1f", now.Armor * 100), to = string.format("%.1f", after.Armor * 100) }),
						Bold = true,
					})
				end
			end
			for _, line in materialsLines(current, step.Materials) do
				table.insert(extra, line)
			end
			table.insert(extra, {
				Text = Strings.Format(S.Fee, { gold = step.Gold }),
				Color = if current.Currencies.Gold >= step.Gold then UITheme.Colors.Stamina else UITheme.Colors.Danger,
			})
			local chance = math.floor((1 - step.FailChance) * 100 + 0.5)
			table.insert(extra, { Text = Strings.Format(S.Chance, { chance = chance }), Color = if step.FailChance > 0 then UITheme.Colors.Stamina else UITheme.Colors.Heal, Bold = true })
			if step.FailChance > 0 then
				table.insert(extra, { Text = S.FailNote, Color = UITheme.Colors.TextMuted })
			end
			table.insert(extra, { Text = " " })
		end
		preview.Show(item, extra)
		preview.Button.Instance.Visible = true
		preview.SecondButton.Instance.Visible = false
		preview.Button:SetText(if maxed then I.Errors.Maximum else Strings.Format(S.UpgradeTo, { level = item.Upgrade + 1 }))
		local affordable = step ~= nil and current.Currencies.Gold >= step.Gold and Rules.HasMaterials(current, step.Materials)
		preview.Button:SetEnabled(not maxed and affordable)
	end
	return { Render = render }
end

-- Repair: damaged gear, each with its cost, plus Repair all.
local function repairPage(content: Frame, maid: Maid.Maid): Page
	local list = Components.ScrollList.new({ Size = UDim2.new(1, 0, 1, -(UITheme.Size.ButtonHeight + UITheme.Padding.Medium)), Spacing = 4, Parent = content })
	maid:Add(list)
	local listMaid = Maid.new()
	maid:Add(listMaid)
	local all = Components.Button.new({ Text = "", Variant = "Primary", AnchorPoint = Vector2.new(1, 1), Position = UDim2.fromScale(1, 1), Size = UDim2.fromOffset(260, UITheme.Size.ButtonHeight), Parent = content })
	maid:Add(all)
	all.Activated:Connect(function()
		request("RepairAll", "")
	end)
	local empty = Create.Label({ Text = S.NothingHere, Color = UITheme.Colors.TextDim, XAlignment = Enum.TextXAlignment.Center, Size = UDim2.new(1, 0, 0, 60), Parent = content })

	local function render()
		rememberSelection(list.Instance)
		listMaid:Clean()
		list:Clear()
		local current = data()
		if not current then
			return
		end
		local damaged = gearList(current, function(item: ItemInstance): boolean
			return item.Durability < Config.Items.Durability.Max
		end)
		empty.Visible = #damaged == 0
		local total = 0
		for index, item in damaged do
			local cost = Rules.RepairCost(item)
			total += cost
			itemRow(list, listMaid, {
				Key = item.Uid,
				DefId = item.DefId,
				Rarity = item.Rarity,
				Title = ItemText.FullName(item),
				Subtitle = Strings.Format(I.Durability, { value = item.Durability, max = Config.Items.Durability.Max }),
				Right = tostring(cost),
				Order = index,
				OnSelect = function()
					request("Repair", item.Uid)
				end,
			})
		end
		all:SetText(Strings.Format(S.RepairAll, { gold = total }))
		all:SetEnabled(total > 0 and current.Currencies.Gold >= total)
	end
	return { Render = render }
end

-- Salvage: unequipped, unlocked gear and what each breaks into.
local function salvagePage(content: Frame, maid: Maid.Maid): Page
	local list = Components.ScrollList.new({ Size = UDim2.fromScale(1, 1), Spacing = 4, Parent = content })
	maid:Add(list)
	local listMaid = Maid.new()
	maid:Add(listMaid)
	local empty = Create.Label({ Text = S.NothingHere, Color = UITheme.Colors.TextDim, XAlignment = Enum.TextXAlignment.Center, Size = UDim2.new(1, 0, 0, 60), Parent = content })
	local function render()
		rememberSelection(list.Instance)
		listMaid:Clean()
		list:Clear()
		local current = data()
		if not current then
			return
		end
		local gear = gearList(current, function(item: ItemInstance): boolean
			return not item.Locked and Rules.EquippedSlot(current, item.Uid) == nil
		end)
		empty.Visible = #gear == 0
		for index, item in gear do
			local parts = {}
			for id, count in Rules.SalvageYield(item) do
				table.insert(parts, `{count} {ItemText.Name(id)}`)
			end
			local yield = table.concat(parts, ", ")
			itemRow(list, listMaid, {
				Key = item.Uid,
				DefId = item.DefId,
				Rarity = item.Rarity,
				Title = ItemText.FullName(item),
				Subtitle = Strings.Format(S.SalvageFor, { yield = yield }),
				Order = index,
				OnSelect = function()
					UIController.Confirm({
						Title = S.ConfirmSalvageTitle,
						Message = Strings.Format(S.ConfirmSalvage, { name = ItemText.FullName(item), yield = yield }),
						ConfirmText = I.Salvage,
						Danger = true,
					}):andThen(function(yes: boolean): any
						if yes then
							request("Salvage", item.Uid)
						end
						return nil
					end)
				end,
			})
		end
	end
	return { Render = render }
end

-- Buy: stock list | preview (compared with what you wear).
local function buyPage(content: Frame, maid: Maid.Maid): Page
	local selected: string? = nil
	local list = Components.ScrollList.new({ Size = UDim2.new(0.42, -8, 1, 0), Spacing = 4, Parent = content })
	maid:Add(list)
	local preview = buildPreview(content, maid, UDim2.fromScale(0.42, 0), UDim2.new(0.58, 0, 1, 0))
	local listMaid = Maid.new()
	maid:Add(listMaid)

	preview.Button.Activated:Connect(function()
		local shop = Shops.Get(stationAttribute(A.ShopId))
		local def = if selected then Items.Get(selected) else nil
		local price = if shop and selected then Shops.Price(shop, selected) else nil
		local current = data()
		if not shop or not def or not price or not selected or not current then
			return
		end
		local id = selected
		if def.StackSize > 1 then
			local affordable = math.max(1, math.floor(Rules.Balance(current, shop.Currency, shop.Floor) / math.max(1, price)))
			Components.CountDialog.Show({
				Title = ItemText.Name(id),
				Min = 1,
				Max = math.min(def.StackSize, affordable, 99),
				Value = 1,
				ConfirmText = S.Buy,
				Describe = function(count: number): string
					return `{price * count} {currencyName(shop.Currency, shop.Floor)}`
				end,
			}):andThen(function(count: number?): any
				if count then
					request("Buy", id, count)
				end
				return nil
			end)
		else
			request("Buy", id, 1)
		end
	end)

	local function render()
		rememberSelection(list.Instance)
		listMaid:Clean()
		list:Clear()
		local current = data()
		local shop = Shops.Get(stationAttribute(A.ShopId))
		if not current or not shop then
			return
		end
		if not selected and shop.Stock[1] then
			selected = shop.Stock[1].Id
		end
		local balance = Rules.Balance(current, shop.Currency, shop.Floor)
		for index, entry in shop.Stock do
			local def = Items.Get(entry.Id)
			itemRow(list, listMaid, {
				Key = entry.Id,
				DefId = entry.Id,
				Rarity = if def then def.Rarity else "Common",
				Title = ItemText.Name(entry.Id),
				Subtitle = if def then ItemText.Subtitle(def, def.Rarity) else nil,
				Right = tostring(entry.Price),
				RightColor = if balance >= entry.Price then UITheme.Colors.Stamina else UITheme.Colors.Danger,
				Selected = entry.Id == selected,
				Order = index,
				OnSelect = function()
					selected = entry.Id
					render()
				end,
			})
		end
		local price = if selected then Shops.Price(shop, selected) else nil
		if not selected or not price then
			preview.Show(nil)
			return
		end
		preview.Show(ItemText.Preview(selected), {
			{ Text = `{price} {currencyName(shop.Currency, shop.Floor)}`, Bold = true, Color = if balance >= price then UITheme.Colors.Stamina else UITheme.Colors.Danger },
		})
		preview.Button.Instance.Visible = true
		preview.SecondButton.Instance.Visible = false
		preview.Button:SetText(S.Buy)
		preview.Button:SetEnabled(balance >= price)
	end
	return { Render = render }
end

-- Sell: bag items a shop buys.
local function sellPage(content: Frame, maid: Maid.Maid): Page
	local selected: string? = nil
	local list = Components.ScrollList.new({ Size = UDim2.new(0.42, -8, 1, 0), Spacing = 4, Parent = content })
	maid:Add(list)
	local preview = buildPreview(content, maid, UDim2.fromScale(0.42, 0), UDim2.new(0.58, 0, 1, 0))
	local listMaid = Maid.new()
	maid:Add(listMaid)
	local empty = Create.Label({ Text = S.NothingHere, Color = UITheme.Colors.TextDim, XAlignment = Enum.TextXAlignment.Center, Size = UDim2.new(0.42, -8, 0, 60), Parent = content })

	preview.Button.Activated:Connect(function()
		local current = data()
		local item = if current and selected then current.Inventory.Items[selected] else nil
		if not item then
			return
		end
		local unit = Rules.SellPrice(item)
		local uid = item.Uid
		if item.Count > 1 then
			Components.CountDialog.Show({
				Title = ItemText.Name(item.DefId),
				Min = 1,
				Max = math.min(item.Count, 99),
				Value = item.Count,
				ConfirmText = S.Sell,
				Describe = function(count: number): string
					return Strings.Format(S.SellFor, { gold = unit * count })
				end,
			}):andThen(function(count: number?): any
				if count then
					request("Sell", uid, count)
				end
				return nil
			end)
		elseif Items.RarityRank(item.Rarity) >= Items.RarityRank("Rare") or item.Upgrade > 0 then
			UIController.Confirm({
				Title = S.ConfirmSellTitle,
				Message = Strings.Format(S.ConfirmSell, { name = ItemText.FullName(item), gold = unit }),
				ConfirmText = S.Sell,
			}):andThen(function(yes: boolean): any
				if yes then
					request("Sell", uid, 1)
				end
				return nil
			end)
		else
			request("Sell", uid, 1)
		end
	end)

	local function render()
		rememberSelection(list.Instance)
		listMaid:Clean()
		list:Clear()
		local current = data()
		if not current then
			return
		end
		local sellable = {}
		for uid, item in current.Inventory.Items do
			if not item.Locked and Rules.EquippedSlot(current, uid) == nil and Rules.SellPrice(item) > 0 then
				table.insert(sellable, item)
			end
		end
		table.sort(sellable, function(a: ItemInstance, b: ItemInstance): boolean
			return Rules.SellPrice(a) * a.Count > Rules.SellPrice(b) * b.Count
		end)
		empty.Visible = #sellable == 0
		if selected and not current.Inventory.Items[selected] then
			selected = nil
		end
		if not selected and sellable[1] then
			selected = sellable[1].Uid
		end
		for index, item in sellable do
			itemRow(list, listMaid, {
				Key = item.Uid,
				DefId = item.DefId,
				Rarity = item.Rarity,
				Title = ItemText.FullName(item) .. (if item.Count > 1 then `  x{item.Count}` else ""),
				Subtitle = ItemText.RarityName(item.Rarity),
				Right = tostring(Rules.SellPrice(item)),
				Selected = item.Uid == selected,
				Order = index,
				OnSelect = function()
					selected = item.Uid
					render()
				end,
			})
		end
		local item = if selected then current.Inventory.Items[selected] else nil
		if not item then
			preview.Show(nil)
			return
		end
		preview.Show(item, { { Text = Strings.Format(S.SellFor, { gold = Rules.SellPrice(item) }), Bold = true, Color = UITheme.Colors.Stamina } })
		preview.Button.Instance.Visible = true
		preview.SecondButton.Instance.Visible = false
		preview.Button:SetText(S.Sell)
		preview.Button:SetEnabled(true)
	end
	return { Render = render }
end

local function buybackPage(content: Frame, maid: Maid.Maid): Page
	local list = Components.ScrollList.new({ Size = UDim2.fromScale(1, 1), Spacing = 4, Parent = content })
	maid:Add(list)
	local listMaid = Maid.new()
	maid:Add(listMaid)
	local empty = Create.Label({ Text = S.BuybackEmpty, Color = UITheme.Colors.TextDim, Wrapped = true, XAlignment = Enum.TextXAlignment.Center, Size = UDim2.new(1, 0, 0, 60), Parent = content })
	local function render()
		rememberSelection(list.Instance)
		listMaid:Clean()
		list:Clear()
		local current = data()
		if not current then
			return
		end
		local entries = current.ItemState.Buyback
		empty.Visible = #entries == 0
		for index = #entries, 1, -1 do
			local entry = entries[index]
			itemRow(list, listMaid, {
				Key = entry.Id,
				DefId = entry.Item.DefId,
				Rarity = entry.Item.Rarity,
				Title = ItemText.FullName(entry.Item) .. (if entry.Item.Count > 1 then `  x{entry.Item.Count}` else ""),
				Subtitle = S.TabBuyback,
				Right = tostring(entry.Price),
				RightColor = if current.Currencies.Gold >= entry.Price then UITheme.Colors.Stamina else UITheme.Colors.Danger,
				Order = #entries - index + 1,
				OnSelect = function()
					request("Buyback", entry.Id)
				end,
			})
		end
	end
	return { Render = render }
end

-- Bank: bag on the left, vault on the right; click an item to move it across.
local function bankPage(content: Frame, maid: Maid.Maid): Page
	local function column(position: UDim2, title: string): (TextLabel, Components.ScrollList)
		local label = Create.Label({ Text = title, Font = UITheme.Fonts.BodyBold, Color = UITheme.Colors.Accent, Position = position, Size = UDim2.new(0.5, -8, 0, 26), Parent = content })
		local grid = Components.ScrollList.new({
			Position = position + UDim2.fromOffset(0, 32),
			Size = UDim2.new(0.5, -8, 1, -32),
			Grid = { CellSize = UDim2.fromOffset(64, 64), CellPadding = UDim2.fromOffset(8, 8) },
			Parent = content,
		})
		maid:Add(grid)
		return label, grid
	end
	local bagLabel, bagGrid = column(UDim2.fromScale(0, 0), I.InventoryTitle)
	local vaultLabel, vaultGrid = column(UDim2.new(0.5, 8, 0, 0), S.Names.Bank)
	local cellsMaid = Maid.new()
	maid:Add(cellsMaid)

	local function fill(grid: Components.ScrollList, items: { [string]: ItemInstance }, current: PlayerData, action: string)
		local list = {}
		for uid, item in items do
			if action ~= "Deposit" or Rules.EquippedSlot(current, uid) == nil then
				table.insert(list, item)
			end
		end
		table.sort(list, function(a: ItemInstance, b: ItemInstance): boolean
			local ra, rb = Items.RarityRank(a.Rarity), Items.RarityRank(b.Rarity)
			if ra ~= rb then
				return ra > rb
			end
			return ItemText.Name(a.DefId) < ItemText.Name(b.DefId)
		end)
		for index, item in list do
			local slot = Components.ItemSlot.new({ Size = 64, LayoutOrder = index })
			cellsMaid:Add(slot)
			slot:SetItem(ItemText.Slot(item))
			slot.Activated:Connect(function()
				request(action, item.Uid)
			end)
			if not Device.IsTouch() then
				cellsMaid:Add(Components.Tooltip.Attach(slot.Instance, function(): Components.TooltipContent?
					return ItemText.Tooltip(item, data())
				end))
			end
			grid:Add(slot.Instance)
			offerSelection(slot.Instance, `{action}:{item.Uid}`)
		end
	end

	local function render()
		rememberSelection(content)
		cellsMaid:Clean()
		bagGrid:Clear()
		vaultGrid:Clear()
		local current = data()
		if not current then
			return
		end
		bagLabel.Text = `{I.InventoryTitle}  ({Strings.Format(I.Slots, { used = Rules.SlotsUsed(current.Inventory.Items), max = current.Inventory.Capacity })})`
		vaultLabel.Text = Strings.Format(S.VaultSlots, { used = Rules.SlotsUsed(current.Bank.Items), max = current.Bank.Capacity })
		fill(bagGrid, current.Inventory.Items, current, "Deposit")
		fill(vaultGrid, current.Bank.Items, current, "Withdraw")
	end
	return { Render = render }
end

local PAGE_BUILDERS: { [string]: (Frame, Maid.Maid) -> Page } = {
	Craft = craftPage,
	Upgrade = upgradePage,
	Repair = repairPage,
	Salvage = salvagePage,
	Buy = buyPage,
	Sell = sellPage,
	Buyback = buybackPage,
	Bank = bankPage,
}

-- THE WINDOW -------------------------------------------------------------------------------------

local function build(content: Frame, maid: Maid.Maid): any
	local isOpen = false
	local openMaid = Maid.new()
	maid:Add(openMaid)
	local pages: { [string]: Page } = {}
	local frames: { [string]: Frame } = {}
	local currentTab = ""

	local header = Create.Label({
		Text = "",
		RichText = true,
		Font = UITheme.Fonts.BodyBold,
		XAlignment = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.new(0.5, 0, 0, UITheme.Size.TabHeight),
		Parent = content,
	})

	local function renderHeader()
		local current = data()
		if not current then
			return
		end
		local shop = Shops.Get(stationAttribute(A.ShopId))
		if shop and shop.Currency == "FloorTokens" then
			header.Text = `{Rules.Balance(current, "FloorTokens", shop.Floor)} {currencyName("FloorTokens", shop.Floor)}`
		else
			header.Text = `<font color="#E9C25B">{current.Currencies.Gold}</font> {I.Gold}`
		end
	end

	local function renderCurrent()
		renderHeader()
		local page = pages[currentTab]
		if page then
			page.Render()
		end
	end
	refreshCurrent = function()
		if isOpen then
			renderCurrent()
		end
	end

	local function open()
		openMaid:Clean()
		table.clear(pages)
		table.clear(frames)
		isOpen = true
		local tabs: { string } = TABS[kind()] or { "Craft" }
		local tabList = {}
		for _, id in tabs do
			table.insert(tabList, { Id = id, Text = TAB_TEXT[id] or id })
		end
		local top = UITheme.Size.TabHeight + UITheme.Padding.Medium
		local tabBar: Components.TabBar? = nil
		if #tabs > 1 then
			local bar = Components.TabBar.new({ Tabs = tabList, Size = UDim2.new(0.5, 0, 0, UITheme.Size.TabHeight), Parent = content })
			openMaid:Add(bar)
			tabBar = bar
		end
		for _, id in tabs do
			local frame: Frame = Create.new("Frame", {
				Name = id,
				BackgroundTransparency = 1,
				Position = UDim2.fromOffset(0, top),
				Size = UDim2.new(1, 0, 1, -top),
				Visible = false,
				Parent = content,
			})
			openMaid:Add(frame)
			frames[id] = frame
			pages[id] = PAGE_BUILDERS[id](frame, openMaid)
		end
		local function selectTab(id: string)
			currentTab = id
			for pageId, frame in frames do
				frame.Visible = pageId == id
			end
			renderCurrent()
		end
		if tabBar then
			openMaid:Add(tabBar.Changed:Connect(selectTab))
		end
		selectTab(tabs[1])

		-- Close if you walk away from the station.
		openMaid:Add(RunService.Heartbeat:Connect(function()
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			local point = if station then positionOf(station) else nil
			if not root or not root:IsA("BasePart") or not point or (root.Position - point).Magnitude > Config.Items.Stations.InteractRadius + 2 then
				UIController.Close()
			end
		end))
		openMaid:Add(DataController.Changed:Connect(function(path: { string })
			local root = path[1]
			if root == "Inventory" or root == "Bank" or root == "Currencies" or root == "RecipesKnown" or root == "ItemState" or root == "Equipped" then
				renderCurrent()
			end
		end))
		return tabBar
	end

	local content2 = {
		OnOpen = function()
			open()
		end,
		OnClose = function()
			isOpen = false
			openMaid:Clean()
			revealCurrent = nil
			craftProgress = nil
			Components.ContextMenu.Close()
		end,
	}
	return content2
end

-- RESULTS ------------------------------------------------------------------------------------------

local function toast(title: string, color: Color3?, defId: string?, rarity: string?)
	Components.Toast.Push({ Title = title, Color = color or UITheme.Colors.Current, Item = defId, ItemRarity = rarity })
end

local function onItemResult(ok: boolean, reason: string, payload: { [string]: any })
	if type(payload) ~= "table" or not ok then
		return -- errors are shown by InventoryController
	end
	local action = payload.Action
	local defId = if type(payload.DefId) == "string" then payload.DefId else nil
	local name = if defId then ItemText.Name(defId) else ""
	if action == "Craft" and defId then
		UISound.Play("CraftDone")
		if revealCurrent then
			revealCurrent(defId, payload.Rarity, payload.Count)
		end
		toast(Strings.Format(S.Crafted, { name = name .. (if (payload.Count or 1) > 1 then ` x{payload.Count}` else "") }), UITheme.RarityColor(payload.Rarity or "Common"), defId, payload.Rarity)
	elseif action == "Upgrade" and defId then
		if reason == "UpgradeFailed" then
			UISound.Play("UpgradeFail")
			toast(Strings.Format(S.UpgradeFailed, { name = name, level = payload.Level or 0 }), UITheme.Colors.Danger, defId, payload.Rarity)
		else
			UISound.Play("UpgradeSuccess")
			toast(Strings.Format(S.UpgradeSuccess, { name = name, level = payload.Level or 0 }), UITheme.Colors.Parry, defId, payload.Rarity)
		end
	elseif action == "Buy" and defId then
		UISound.Play("UIConfirm")
		toast(Strings.Format(S.Bought, { name = name .. (if (payload.Count or 1) > 1 then ` x{payload.Count}` else "") }), UITheme.Colors.Current, defId)
	elseif action == "Buyback" and defId then
		UISound.Play("UIConfirm")
		toast(Strings.Format(S.Bought, { name = name }), UITheme.Colors.Current, defId)
	elseif action == "Sell" then
		UISound.Play("GoldPickup")
		toast(Strings.Format(S.Sold, { gold = payload.Gold or 0 }), UITheme.Colors.Stamina, defId)
	elseif action == "Repair" or action == "RepairAll" then
		UISound.Play("ItemEquip")
		toast(S.Repaired, UITheme.Colors.Heal, defId)
	elseif action == "Deposit" or action == "Withdraw" then
		UISound.Play("UIClick")
	end
end

-- PROMPTS ----------------------------------------------------------------------------------------

local prompts: { [Instance]: ProximityPrompt } = {}
local watching: { [Instance]: RBXScriptConnection } = {}

-- With StreamingEnabled a station model can reach the client before its
-- parts, and its parts can stream out and back in. So each station is
-- watched: whenever a part arrives and the prompt is missing, it's added.
local addPrompt: (instance: Instance) -> ()

function addPrompt(instance: Instance)
	if not watching[instance] then
		watching[instance] = instance.DescendantAdded:Connect(function(descendant: Instance)
			if descendant:IsA("BasePart") then
				task.defer(addPrompt, instance)
			end
		end)
	end
	local existing = prompts[instance]
	if existing and existing.Parent then
		return
	end
	local host: BasePart? = nil
	if instance:IsA("BasePart") then
		host = instance
	elseif instance:IsA("Model") then
		local primary = instance.PrimaryPart
		host = primary or instance:FindFirstChildWhichIsA("BasePart", true)
	end
	if not host then
		return
	end
	local stationKind = instance:GetAttribute(A.StationKind)
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "StationPrompt"
	prompt.Style = Enum.ProximityPromptStyle.Custom
	prompt.ActionText = S.Open
	prompt.ObjectText = if type(stationKind) == "string" then S.Names[stationKind] or stationKind else ""
	prompt.MaxActivationDistance = Config.Items.Stations.InteractRadius - 2
	prompt.RequiresLineOfSight = false
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.GamepadKeyCode = Enum.KeyCode.ButtonX
	prompt.Parent = host
	prompt.Triggered:Connect(function()
		StationController.Open(instance)
	end)
	prompts[instance] = prompt
end

local titleSetter: ((string) -> ())? = nil
local currentTitle = ""

-- The window title is the station's name. The window is only built the first
-- time it opens, so the name is remembered and applied when the title exists.
function StationController.SetTitle(text: string)
	currentTitle = text
	if titleSetter then
		titleSetter(text)
	end
end

-- Station kinds another controller opens itself (the Hall of Positions
-- opens the Skill Tree menu), registered by that controller.
local kindHandlers: { [string]: (Instance) -> () } = {}

function StationController.SetKindHandler(kind: string, handler: (Instance) -> ())
	kindHandlers[kind] = handler
end

-- Opens the window for a station (its prompt calls this; so can Studio test hooks).
function StationController.Open(instance: Instance)
	local stationKind = instance:GetAttribute(A.StationKind)
	local handler = if type(stationKind) == "string" then kindHandlers[stationKind] else nil
	if handler then
		handler(instance)
		return
	end
	station = instance
	local title = if type(stationKind) == "string" then S.Names[stationKind] or stationKind else ""
	UIController.Close()
	task.defer(function()
		StationController.SetTitle(title)
		UIController.Open(MENU_ID)
		StationController.SetTitle(title)
	end)
end

function StationController.Init()
	UIController.RegisterMenu({
		Id = MENU_ID,
		Title = S.TabCraft,
		FullScreen = true,
		ShowInHub = false,
		Size = Vector2.new(1040, 680),
		Build = function(content: Frame, maid: Maid.Maid): any
			-- The window title is the station's name; find the label UIController made.
			local panel = content.Parent
			local title = if panel then panel:FindFirstChild("Title") else nil
			titleSetter = function(text: string)
				if title and title:IsA("TextLabel") then
					title.Text = text
				end
			end
			if currentTitle ~= "" then
				(titleSetter :: (string) -> ())(currentTitle)
			end
			return build(content, maid)
		end,
	})
	Net.OnClient("ItemResult", onItemResult)
	Net.OnClient("CraftState", function(state: string, recipeId: string, endsAt: number)
		if state == "Start" and type(endsAt) == "number" then
			craftJob = { Recipe = recipeId, EndsAt = endsAt }
		else
			craftJob = nil
			if craftProgress then
				craftProgress(0)
			end
		end
		if refreshCurrent then
			refreshCurrent()
		end
	end)
end

function StationController.Start()
	local tag = Attributes.Tags.ItemStation
	CollectionService:GetInstanceAddedSignal(tag):Connect(addPrompt)
	CollectionService:GetInstanceRemovedSignal(tag):Connect(function(instance: Instance)
		local prompt = prompts[instance]
		if prompt then
			prompt:Destroy()
			prompts[instance] = nil
		end
		local connection = watching[instance]
		if connection then
			connection:Disconnect()
			watching[instance] = nil
		end
	end)
	for _, instance in CollectionService:GetTagged(tag) do
		addPrompt(instance)
	end
	-- Crafting progress ring.
	RunService.RenderStepped:Connect(function()
		local job = craftJob
		if job and craftProgress then
			local alpha = 1 - math.clamp((job.EndsAt - Workspace:GetServerTimeNow()) / Config.Items.Crafting.Seconds, 0, 1)
			craftProgress(alpha)
		end
	end)
end

return StationController
