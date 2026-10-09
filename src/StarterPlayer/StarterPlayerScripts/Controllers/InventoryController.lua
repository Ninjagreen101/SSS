--!strict
--[[
	InventoryController
	The Inventory page of the Character window (I), and every item toast.
	(The Character page itself is CharacterSheetController.)

	Inventory (Spec Section 12, menu 2):
	  - equipment column | bag grid | details panel
	  - search, filter (type, rarity, new) and sort, slots used, a weight
	    bar and your currencies
	  - drag gear (mouse) onto an equipment slot to equip it; right-click,
	    touch long-press or gamepad Y opens the item's context menu (equip,
	    use, quick slot, split, lock, salvage...)
	  - tooltips compare with what you have equipped (green better, red worse)
	  The grid keeps one ItemSlot per item uid and only updates what
	  changed, so picking something up doesn't rebuild the whole bag.

	Every request goes to the server (RequestItemAction); this only draws.
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Strings = require(Shared.Strings)
local Types = require(Shared.Types)
local Net = require(Shared.Net)
local Maid = require(Shared.Util.Maid)
local Items = require(Shared.Data.Items)
local Recipes = require(Shared.Data.Recipes)
local GearStats = require(Shared.Data.GearStats)
local Rules = require(Shared.Data.InventoryRules)

local UI = script.Parent.Parent.UI
local UITheme = require(UI.UITheme)
local Create = require(UI.Create)
local Layers = require(UI.Layers)
local Device = require(UI.Device)
local UISound = require(UI.UISound)
local Components = require(UI.Components)
local ItemText = require(UI.ItemText)
local ItemIcon = require(UI.ItemIcon)
local Icons = require(UI.Icons)

local DataController = require(script.Parent.DataController)
local UIController = require(script.Parent.UIController)

type ItemInstance = Types.ItemInstance
type PlayerData = Types.PlayerData

local S = Strings.Inventory
local player = Players.LocalPlayer

local EQUIP_ORDER = { "Weapon", "Head", "Chest", "Legs", "Hands", "Cloak", "Ring1", "Ring2", "Amulet" }
local FILTERS = { "All", "New", "Weapon", "Armor", "Accessory", "Consumable", "Material", "Other" }
local SORTS = { "Rarity", "Type", "Name", "Newest" }
local TYPE_ORDER = { Weapon = 1, Armor = 2, Accessory = 3, BeaconCore = 4, Consumable = 5, Blueprint = 6, Material = 7, Quest = 8 }
local SLOT_SIZE = 64
local MENU_ID = "Inventory"
local DRAG_START = 8 -- pixels the mouse must move before a press becomes a drag

local InventoryController = {}

-- A filter asked for by another page, applied when the Inventory next opens.
local requestedFilter: string? = nil

local function send(action: string, uid: string, argument: string?, count: number?)
	Net.FireServer("RequestItemAction", action, uid, argument or "", count or 0)
end

local function data(): PlayerData?
	return DataController.GetData()
end

-- ITEM ACTIONS (shared by both menus and the context menu) ------------------------

local function confirmSalvage(item: ItemInstance)
	local parts = {}
	for id, count in Rules.SalvageYield(item) do
		table.insert(parts, `{count} {ItemText.Name(id)}`)
	end
	local yield = table.concat(parts, ", ")
	UIController.Confirm({
		Title = Strings.Stations.ConfirmSalvageTitle,
		Message = Strings.Format(Strings.Stations.ConfirmSalvage, { name = ItemText.FullName(item), yield = yield }),
		ConfirmText = S.Salvage,
		Danger = true,
	}):andThen(function(yes: boolean): any
		if yes then
			send("Salvage", item.Uid)
		end
		return nil
	end)
end

local function splitStack(item: ItemInstance)
	Components.CountDialog.Show({
		Title = S.Split,
		Min = 1,
		Max = item.Count - 1,
		Value = math.floor(item.Count / 2),
		ConfirmText = S.Split,
	}):andThen(function(count: number?): any
		if count then
			send("Split", item.Uid, "", count)
		end
		return nil
	end)
end

-- The main action for an item and its label (Equip / Use / Learn...).
local function primaryAction(item: ItemInstance, current: PlayerData): (string?, (() -> ())?)
	local def = Items.Get(item.DefId)
	if not def then
		return nil, nil
	end
	if Items.IsGear(def) then
		local slot = Rules.EquippedSlot(current, item.Uid)
		if slot then
			return S.Unequip, function()
				send("Unequip", item.Uid, slot)
			end
		end
		return S.Equip, function()
			send("Equip", item.Uid, "")
		end
	elseif def.Type == "Consumable" then
		return S.Use, function()
			send("Use", item.Uid)
		end
	elseif def.Type == "Blueprint" then
		return S.Learn, function()
			send("Use", item.Uid)
		end
	elseif def.Type == "BeaconCore" then
		return S.SlotCore, function()
			send("SlotCore", item.Uid)
		end
	end
	return nil, nil
end

local function contextOptions(item: ItemInstance, current: PlayerData): { Components.ContextOption }
	local def = Items.Get(item.DefId)
	if not def then
		return {}
	end
	local options: { Components.ContextOption } = {}
	local equippedSlot = Rules.EquippedSlot(current, item.Uid)
	if Items.IsGear(def) then
		if equippedSlot then
			table.insert(options, { Text = S.Unequip, OnSelect = function()
				send("Unequip", item.Uid, equippedSlot)
			end })
		elseif def.Slot == "Ring" then
			for _, slot in { "Ring1", "Ring2" } do
				table.insert(options, {
					Text = Strings.Format(S.EquipTo, { slot = `{S.SlotNames.Ring} {string.sub(slot, 5)}` }),
					Enabled = current.Level >= def.RequiredLevel,
					OnSelect = function()
						send("Equip", item.Uid, slot)
					end,
				})
			end
		else
			table.insert(options, { Text = S.Equip, Enabled = current.Level >= def.RequiredLevel, OnSelect = function()
				send("Equip", item.Uid, "")
			end })
		end
	else
		local label, run = primaryAction(item, current)
		if label and run then
			table.insert(options, { Text = label, Enabled = not item.Locked or def.Type ~= "Consumable", OnSelect = run })
		end
	end
	if def.Type == "Consumable" then
		table.insert(options, { Text = S.Quick1, OnSelect = function()
			send("QuickSlot", item.Uid, "1")
		end })
		table.insert(options, { Text = S.Quick2, OnSelect = function()
			send("QuickSlot", item.Uid, "2")
		end })
	end
	if item.Count > 1 then
		table.insert(options, { Text = S.Split, Enabled = not item.Locked, OnSelect = function()
			splitStack(item)
		end })
	end
	table.insert(options, { Text = if item.Locked then S.Unlock else S.Lock, OnSelect = function()
		send("Lock", item.Uid)
	end })
	if Items.IsGear(def) then
		table.insert(options, {
			Text = S.Salvage,
			Danger = true,
			Enabled = not item.Locked and equippedSlot == nil,
			OnSelect = function()
				confirmSalvage(item)
			end,
		})
	end
	return options
end

local function openContext(item: ItemInstance, anchor: GuiObject?)
	local current = data()
	if not current then
		return
	end
	Components.ContextMenu.Show({
		Title = ItemText.FullName(item),
		TitleColor = UITheme.RarityColor(item.Rarity),
		Options = contextOptions(item, current),
		Anchor = anchor,
	})
end

InventoryController.OpenContext = openContext

-- DETAILS PANEL -------------------------------------------------------------------------

type Details = {
	Frame: Frame,
	Show: (item: ItemInstance?) -> (),
}

local function buildDetails(parent: Frame, maid: Maid.Maid): Details
	local frame: Frame = Create.new("Frame", {
		Name = "Details",
		BackgroundColor3 = UITheme.Colors.PanelSunken,
		BackgroundTransparency = UITheme.SunkenTransparency,
		Size = UDim2.fromScale(1, 1),
		Parent = parent,
	})
	Create.Corner(frame)
	Create.Padding(frame, UITheme.Padding.Medium)

	local icon = ItemIcon.new({
		Size = UDim2.fromOffset(96, 96),
		Parent = frame,
	})
	local title = Create.Label({
		Text = "",
		Font = UITheme.Fonts.Title,
		TextSize = UITheme.TextSize.Heading,
		Wrapped = true,
		YAlignment = Enum.TextYAlignment.Top,
		Position = UDim2.fromOffset(108, 4),
		Size = UDim2.new(1, -108, 0, 56),
		Parent = frame,
	})
	local subtitle = Create.Label({
		Text = "",
		TextSize = UITheme.TextSize.Small,
		Color = UITheme.Colors.TextMuted,
		Position = UDim2.fromOffset(108, 62),
		Size = UDim2.new(1, -108, 0, 20),
		Parent = frame,
	})
	local lines = Components.ScrollList.new({
		Position = UDim2.fromOffset(0, 108),
		Size = UDim2.new(1, 0, 1, -(108 + UITheme.Size.ButtonHeight * 2 + UITheme.Padding.Small * 2)),
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
	local primary = Components.Button.new({ Text = "", Variant = "Primary", Size = UDim2.new(1, 0, 0, UITheme.Size.ButtonHeight), LayoutOrder = 1, Parent = buttons })
	local more = Components.Button.new({ Text = "...", Size = UDim2.new(1, 0, 0, UITheme.Size.ButtonHeight), LayoutOrder = 2, Parent = buttons })
	maid:Add(primary)
	maid:Add(more)
	local empty = Create.Label({
		Text = S.SelectHint,
		Color = UITheme.Colors.TextDim,
		Wrapped = true,
		XAlignment = Enum.TextXAlignment.Center,
		Size = UDim2.fromScale(1, 1),
		Parent = frame,
	})

	local shown: ItemInstance? = nil
	local primaryRun: (() -> ())? = nil
	primary.Activated:Connect(function()
		if primaryRun then
			primaryRun()
		end
	end)
	more.Activated:Connect(function()
		if shown then
			openContext(shown, more.Instance)
		end
	end)

	local function show(item: ItemInstance?)
		shown = item
		lines:Clear()
		local current = data()
		local visible = item ~= nil and current ~= nil
		local parts: { GuiObject } = { icon.Instance, title, subtitle, lines.Instance, buttons }
		for _, child in parts do
			child.Visible = visible
		end
		empty.Visible = not visible
		if not item or not current then
			icon:Set(nil)
			return
		end
		local tooltip = ItemText.Tooltip(item, current)
		if not tooltip then
			return
		end
		icon:Set(item.DefId, item.Rarity)
		title.Text = tooltip.Title
		title.TextColor3 = tooltip.TitleColor or UITheme.Colors.Text
		subtitle.Text = tooltip.Subtitle or ""
		local tooltipLines: { Components.TooltipLine } = tooltip.Lines or {}
		for index, line in tooltipLines do
			local label = Create.Label({
				Text = line.Text,
				Font = if line.Bold then UITheme.Fonts.BodyBold else UITheme.Fonts.Body,
				TextSize = UITheme.TextSize.Small,
				Color = line.Color,
				Wrapped = true,
				AutomaticSize = Enum.AutomaticSize.Y,
				Size = UDim2.new(1, -8, 0, 20),
				LayoutOrder = index,
			})
			lines:Add(label)
		end
		if tooltip.Footer then
			local flavor = Create.Label({
				Text = `<i>{tooltip.Footer}</i>`,
				RichText = true,
				TextSize = UITheme.TextSize.Small,
				Color = UITheme.Colors.TextDim,
				Wrapped = true,
				AutomaticSize = Enum.AutomaticSize.Y,
				Size = UDim2.new(1, -8, 0, 20),
				LayoutOrder = 1000,
			})
			lines:Add(flavor)
		end
		local label, run = primaryAction(item, current)
		primaryRun = run
		primary.Instance.Visible = label ~= nil
		primary:SetText(label or "")
		local def = Items.Get(item.DefId)
		primary:SetEnabled(def ~= nil and (current.Level >= def.RequiredLevel or Rules.EquippedSlot(current, item.Uid) ~= nil))
	end
	show(nil)
	return { Frame = frame, Show = show }
end

-- EQUIPMENT SLOTS ----------------------------------------------------------------------------

type EquipSlots = {
	Slots: { [string]: Components.ItemSlot },
	Refresh: () -> (),
}

-- One ItemSlot per equipment slot, with its name under it.
local function buildEquipSlots(parent: Frame, maid: Maid.Maid, onSelect: (item: ItemInstance?, slot: string) -> ()): EquipSlots
	local grid: Frame = Create.new("Frame", {
		Name = "Equipment",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = parent,
	})
	Create.new("UIGridLayout", {
		CellSize = UDim2.fromOffset(SLOT_SIZE, SLOT_SIZE + 18),
		CellPadding = UDim2.fromOffset(UITheme.Padding.Small, UITheme.Padding.Small),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = grid,
	})
	local slots: { [string]: Components.ItemSlot } = {}
	for index, slotName in EQUIP_ORDER do
		local cell: Frame = Create.new("Frame", {
			Name = slotName,
			BackgroundTransparency = 1,
			LayoutOrder = index,
			Parent = grid,
		})
		local slot = Components.ItemSlot.new({ Size = SLOT_SIZE, Name = `Equip_{slotName}`, Placeholder = Icons.ForSlot(slotName), Parent = cell })
		maid:Add(slot)
		Create.Label({
			Text = S.SlotNames[slotName] or slotName,
			TextSize = UITheme.TextSize.Caption,
			Color = UITheme.Colors.TextDim,
			XAlignment = Enum.TextXAlignment.Center,
			Position = UDim2.fromOffset(0, SLOT_SIZE),
			Size = UDim2.new(1, 0, 0, 16),
			Parent = cell,
		})
		slots[slotName] = slot
		slot.Activated:Connect(function()
			local current = data()
			onSelect(if current then GearStats.EquippedItem(current, slotName) else nil, slotName)
		end)
		slot.SecondaryActivated:Connect(function()
			local current = data()
			local item = if current then GearStats.EquippedItem(current, slotName) else nil
			if item then
				openContext(item, slot.Instance)
			end
		end)
		if not Device.IsTouch() then
			maid:Add(Components.Tooltip.Attach(slot.Instance, function(): Components.TooltipContent?
				local current = data()
				local item = if current then GearStats.EquippedItem(current, slotName) else nil
				if item and current then
					return ItemText.Tooltip(item, current)
				end
				return { Title = S.SlotNames[slotName] or slotName, Subtitle = S.Empty }
			end))
		end
	end
	local function refresh()
		local current = data()
		for slotName, slot in slots do
			local item = if current then GearStats.EquippedItem(current, slotName) else nil
			slot:SetItem(if item then ItemText.Slot(item) else nil)
		end
	end
	return { Slots = slots, Refresh = refresh }
end

-- DRAG AND DROP (mouse) -----------------------------------------------------------------------

type Drag = { Uid: string, Start: Vector2, Ghost: ItemIcon.ItemIcon?, Active: boolean }

local function slotUnder(slots: { [string]: Components.ItemSlot }, point: Vector2): string?
	for name, slot in slots do
		local frame = slot.Instance
		local position, size = frame.AbsolutePosition, frame.AbsoluteSize
		if point.X >= position.X and point.X <= position.X + size.X and point.Y >= position.Y and point.Y <= position.Y + size.Y then
			return name
		end
	end
	return nil
end

-- INVENTORY MENU --------------------------------------------------------------------------------

local function matchesFilter(item: ItemInstance, def: Items.ItemDef, filter: string): boolean
	if filter == "All" then
		return true
	elseif filter == "New" then
		return item.New
	elseif filter == "Other" then
		return def.Type == "BeaconCore" or def.Type == "Blueprint" or def.Type == "Quest"
	end
	return def.Type == filter
end

local function sortItems(list: { ItemInstance }, sort: string)
	table.sort(list, function(a: ItemInstance, b: ItemInstance): boolean
		local da, db = Items.Get(a.DefId), Items.Get(b.DefId)
		if not da or not db then
			return a.Uid < b.Uid
		end
		if sort == "Newest" and a.AcquiredAt ~= b.AcquiredAt then
			return a.AcquiredAt > b.AcquiredAt
		end
		if sort == "Rarity" then
			local ra, rb = Items.RarityRank(a.Rarity), Items.RarityRank(b.Rarity)
			if ra ~= rb then
				return ra > rb
			end
		end
		if sort == "Type" or sort == "Rarity" then
			local ta, tb = TYPE_ORDER[da.Type] or 99, TYPE_ORDER[db.Type] or 99
			if ta ~= tb then
				return ta < tb
			end
		end
		local na, nb = ItemText.Name(a.DefId), ItemText.Name(b.DefId)
		if na ~= nb then
			return na < nb
		end
		return (tonumber(a.Uid) or 0) < (tonumber(b.Uid) or 0)
	end)
end

local function buildInventory(content: Frame, maid: Maid.Maid): any
	local isOpen = false
	local query = ""
	local filter = "All"
	local sort = "Rarity"
	local selectedUid: string? = nil

	-- Top bar: search, filter, sort, currencies.
	local search = Components.SearchBox.new({ Placeholder = S.Search, Size = UDim2.fromOffset(240, UITheme.Size.InputHeight), Parent = content })
	maid:Add(search)
	local filterOptions = {}
	for _, id in FILTERS do
		table.insert(filterOptions, { Id = id, Text = S.Filters[id] or id })
	end
	local filterBox = Components.Dropdown.new({ Options = filterOptions, Selected = filter, Size = UDim2.fromOffset(170, UITheme.Size.InputHeight), Position = UDim2.fromOffset(252, 0), Parent = content })
	maid:Add(filterBox)
	local sortOptions = {}
	for _, id in SORTS do
		table.insert(sortOptions, { Id = id, Text = Strings.Format(S.Sort, { name = (S :: any)[`Sort{id}`] or id }) })
	end
	local sortBox = Components.Dropdown.new({ Options = sortOptions, Selected = sort, Size = UDim2.fromOffset(170, UITheme.Size.InputHeight), Position = UDim2.fromOffset(434, 0), Parent = content })
	maid:Add(sortBox)
	-- Currencies, right-aligned: [coin] Gold  [crystal] Shards  [token] Floor Tokens.
	local currencies: Frame = Create.new("Frame", {
		Name = "Currencies",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.new(1, -620, 0, UITheme.Size.InputHeight),
		Parent = content,
	})
	Create.List(currencies, Enum.FillDirection.Horizontal, 16, Enum.HorizontalAlignment.Right, Enum.VerticalAlignment.Center)
	local function currencyChip(icon: string, color: Color3, order: number): TextLabel
		local chip: Frame = Create.new("Frame", { Name = icon, BackgroundTransparency = 1, AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.new(0, 0, 1, 0), LayoutOrder = order, Parent = currencies })
		Create.List(chip, Enum.FillDirection.Horizontal, 6, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)
		Icons.new(icon, { Size = UDim2.fromOffset(20, 20), Color = color, LayoutOrder = 1, Parent = chip })
		return Create.Label({
			Text = "",
			RichText = true,
			Font = UITheme.Fonts.BodyBold,
			TextSize = UITheme.TextSize.Small,
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.new(0, 0, 1, 0),
			LayoutOrder = 2,
			Parent = chip,
		})
	end
	local goldLabel = currencyChip("Gold", UITheme.Colors.Stamina, 1)
	local shardsLabel = currencyChip("Shards", UITheme.Colors.Current, 2)
	local tokensLabel = currencyChip("Tokens", UITheme.Colors.Accent, 3)

	local top = UITheme.Size.InputHeight + UITheme.Padding.Medium
	local bottom = 44
	local equipWidth = SLOT_SIZE * 2 + UITheme.Padding.Small * 3
	local detailsWidth = 300

	-- Left: equipment.
	local equipHolder: Frame = Create.new("Frame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, top),
		Size = UDim2.new(0, equipWidth, 1, -(top + bottom)),
		Parent = content,
	})
	-- Middle: bag grid.
	local bag = Components.ScrollList.new({
		Name = "Bag",
		Position = UDim2.fromOffset(equipWidth + UITheme.Padding.Medium, top),
		Size = UDim2.new(1, -(equipWidth + detailsWidth + UITheme.Padding.Medium * 2), 1, -(top + bottom)),
		Grid = { CellSize = UDim2.fromOffset(SLOT_SIZE, SLOT_SIZE), CellPadding = UDim2.fromOffset(UITheme.Padding.Small, UITheme.Padding.Small) },
		Parent = content,
	})
	maid:Add(bag)
	local emptyLabel = Create.Label({
		Text = S.EmptyBag,
		Color = UITheme.Colors.TextDim,
		Wrapped = true,
		XAlignment = Enum.TextXAlignment.Center,
		Position = bag.Instance.Position,
		Size = bag.Instance.Size,
		Parent = content,
	})
	-- Right: details.
	local detailsHolder: Frame = Create.new("Frame", {
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, top),
		Size = UDim2.new(0, detailsWidth, 1, -(top + bottom)),
		Parent = content,
	})
	local details = buildDetails(detailsHolder, maid)

	-- Bottom: slots, weight, hint.
	local footer: Frame = Create.new("Frame", {
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, bottom - 8),
		Parent = content,
	})
	local slotsLabel = Create.Label({ Text = "", TextSize = UITheme.TextSize.Small, Color = UITheme.Colors.TextMuted, Size = UDim2.fromOffset(150, 36), Parent = footer })
	local weightBar = Components.ProgressBar.new({ Color = UITheme.Colors.Stamina, Size = UDim2.fromOffset(200, 10), Position = UDim2.fromOffset(150, 6), Parent = footer })
	maid:Add(weightBar)
	local weightLabel = Create.Label({ Text = "", TextSize = UITheme.TextSize.Caption, Color = UITheme.Colors.TextMuted, Position = UDim2.fromOffset(150, 18), Size = UDim2.fromOffset(260, 16), Parent = footer })
	Create.Label({
		Text = S.DragHint,
		TextSize = UITheme.TextSize.Caption,
		Color = UITheme.Colors.TextDim,
		XAlignment = Enum.TextXAlignment.Right,
		Wrapped = true,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.new(1, -420, 1, 0),
		Parent = footer,
	})

	local slotsByUid: { [string]: Components.ItemSlot } = {}
	local slotMaids: { [string]: Maid.Maid } = {}
	local drag: Drag? = nil

	local function select(uid: string?)
		if selectedUid and slotsByUid[selectedUid] then
			slotsByUid[selectedUid]:SetSelected(false)
		end
		selectedUid = uid
		local current = data()
		local item = if uid and current then current.Inventory.Items[uid] else nil
		if uid and slotsByUid[uid] then
			slotsByUid[uid]:SetSelected(true)
		end
		if item and item.New then
			send("Seen", item.Uid)
		end
		details.Show(item)
	end

	local equip = buildEquipSlots(equipHolder, maid, function(item: ItemInstance?)
		if item then
			select(item.Uid)
		end
	end)

	local function endDrag(point: Vector2?)
		local current = drag
		drag = nil
		if not current then
			return
		end
		if current.Ghost then
			current.Ghost:Destroy()
		end
		if current.Active and point then
			local target = slotUnder(equip.Slots, point)
			if target then
				send("Equip", current.Uid, target)
			end
		end
	end

	local function slotFor(uid: string): Components.ItemSlot
		local existing = slotsByUid[uid]
		if existing then
			return existing
		end
		local slotMaid = Maid.new()
		local slot = Components.ItemSlot.new({ Size = SLOT_SIZE, Name = `Item_{uid}` })
		slotMaid:Add(slot)
		slot.Activated:Connect(function()
			if drag and drag.Active then
				return
			end
			select(uid)
		end)
		slot.SecondaryActivated:Connect(function()
			local current = data()
			local item = if current then current.Inventory.Items[uid] else nil
			if item then
				select(uid)
				openContext(item, slot.Instance)
			end
		end)
		if not Device.IsTouch() then
			slotMaid:Add(Components.Tooltip.Attach(slot.Instance, function(): Components.TooltipContent?
				local current = data()
				local item = if current then current.Inventory.Items[uid] else nil
				return if item and current then ItemText.Tooltip(item, current) else nil
			end))
		end
		slotMaid:Add(slot.Instance.InputBegan:Connect(function(input: InputObject)
			if input.UserInputType == Enum.UserInputType.MouseButton1 then
				drag = { Uid = uid, Start = Vector2.new(input.Position.X, input.Position.Y), Ghost = nil, Active = false }
			end
		end))
		bag:Add(slot.Instance)
		slotsByUid[uid] = slot
		slotMaids[uid] = slotMaid
		return slot
	end

	local function render()
		if not isOpen then
			return
		end
		local current = data()
		if not current then
			return
		end
		-- Header and footer.
		local tokens = current.Currencies.FloorTokens[current.Floors.Current] or 0
		goldLabel.Text = `{current.Currencies.Gold} <font color="#9DB2CA">{S.Gold}</font>`
		shardsLabel.Text = `{current.Currencies.Shards} <font color="#9DB2CA">{S.Shards}</font>`
		tokensLabel.Text = `{tokens} <font color="#9DB2CA">{Strings.Format(S.FloorTokens, { floor = current.Floors.Current })}</font>`
		slotsLabel.Text = Strings.Format(S.Slots, { used = Rules.SlotsUsed(current.Inventory.Items), max = current.Inventory.Capacity })
		local summary = GearStats.Summarize(current)
		weightBar:SetValue(summary.Weight, summary.MaxWeight)
		weightBar:SetColor(if summary.Weight > summary.MaxWeight then UITheme.Colors.Danger else UITheme.Colors.Stamina)
		weightLabel.Text = Strings.Format(S.Weight, { weight = string.format("%.1f", summary.Weight), max = math.floor(summary.MaxWeight) })
			.. (if summary.Weight > summary.MaxWeight then `  {S.Overburdened}` else "")
		weightLabel.TextColor3 = if summary.Weight > summary.MaxWeight then UITheme.Colors.Danger else UITheme.Colors.TextMuted

		-- Bag: equipped items live in the equipment column, not the grid.
		local list: { ItemInstance } = {}
		local lowered = string.lower(query)
		for uid, item in current.Inventory.Items do
			local def = Items.Get(item.DefId)
			if def and not Rules.EquippedSlot(current, uid) and matchesFilter(item, def, filter) then
				if lowered == "" or string.find(string.lower(ItemText.Name(item.DefId)), lowered, 1, true) then
					table.insert(list, item)
				end
			end
		end
		sortItems(list, sort)
		local keep: { [string]: boolean } = {}
		for index, item in list do
			keep[item.Uid] = true
			local slot = slotFor(item.Uid)
			slot.Instance.LayoutOrder = index
			slot:SetItem(ItemText.Slot(item))
			slot:SetSelected(item.Uid == selectedUid)
		end
		for uid, slotMaid in slotMaids do
			if not keep[uid] then
				slotMaid:Clean()
				slotMaids[uid] = nil
				slotsByUid[uid] = nil
			end
		end
		emptyLabel.Visible = #list == 0
		emptyLabel.Text = if Rules.SlotsUsed(current.Inventory.Items) == 0 then S.EmptyBag else S.NoMatches
		equip.Refresh()
		-- Keep the details panel on the selected item (or clear it if it's gone).
		local selectedItem = if selectedUid then current.Inventory.Items[selectedUid] else nil
		if selectedUid and not selectedItem then
			selectedUid = nil
		end
		details.Show(selectedItem)
	end

	maid:Add(search.Changed:Connect(function(text: string)
		query = text
		render()
	end))
	maid:Add(filterBox.Changed:Connect(function(id: string)
		filter = id
		render()
	end))
	maid:Add(sortBox.Changed:Connect(function(id: string)
		sort = id
		render()
	end))

	-- Drag: follow the mouse with a ghost icon once it moves far enough.
	maid:Add(UserInputService.InputChanged:Connect(function(input: InputObject)
		local current = drag
		if not current or input.UserInputType ~= Enum.UserInputType.MouseMovement then
			return
		end
		local point = Vector2.new(input.Position.X, input.Position.Y)
		if not current.Active and (point - current.Start).Magnitude >= DRAG_START then
			local inventory = data()
			local item = if inventory then inventory.Inventory.Items[current.Uid] else nil
			if not item then
				drag = nil
				return
			end
			current.Active = true
			Components.Tooltip.Hide()
			local ghost = ItemIcon.new({ Size = UDim2.fromOffset(SLOT_SIZE, SLOT_SIZE), AnchorPoint = Vector2.new(0.5, 0.5), ZIndex = 80, Parent = Layers.Get("Tooltip") })
			ghost:Set(item.DefId, item.Rarity)
			current.Ghost = ghost
		end
		if current.Ghost then
			-- The Tooltip layer ignores the top-bar inset, input positions don't:
			-- use the full-screen mouse location so the ghost sits under the cursor.
			local mouse = Layers.ToLayerSpace("Tooltip", UserInputService:GetMouseLocation())
			current.Ghost.Instance.Position = UDim2.fromOffset(mouse.X, mouse.Y)
		end
	end))
	maid:Add(UserInputService.InputEnded:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1 and drag then
			endDrag(Vector2.new(input.Position.X, input.Position.Y))
		end
	end))
	-- Gamepad: Y on a selected slot opens its context menu.
	maid:Add(UserInputService.InputBegan:Connect(function(input: InputObject)
		if not isOpen or input.KeyCode ~= Enum.KeyCode.ButtonY or Components.ContextMenu.IsOpen() then
			return
		end
		local selected = GuiService.SelectedObject
		for uid, slot in slotsByUid do
			if slot.Instance == selected then
				local current = data()
				local item = if current then current.Inventory.Items[uid] else nil
				if item then
					openContext(item, slot.Instance)
				end
				return
			end
		end
	end))

	local function onChanged(path: { string })
		local root = path[1]
		if root == "Inventory" or root == "Equipped" or root == "Currencies" or root == "Level" or root == "Stats" then
			render()
		end
	end
	maid:Add(DataController.Changed:Connect(onChanged))

	return {
		OnOpen = function()
			isOpen = true
			local wanted = requestedFilter
			if wanted then
				requestedFilter = nil
				filter = wanted
				filterBox:SetSelected(wanted, true)
			end
			render()
		end,
		OnClose = function()
			isOpen = false
			endDrag(nil)
			Components.ContextMenu.Close()
		end,
	}
end

-- FEEDBACK (toasts and sounds for every item result) -----------------------------------------------

local STATION_ACTIONS = { Buy = true, Sell = true, Buyback = true, Upgrade = true, Repair = true, RepairAll = true, Deposit = true, Withdraw = true, Craft = true }

local function toast(title: string, color: Color3?, key: string?, defId: string?)
	Components.Toast.Push({ Title = title, Color = color or UITheme.Colors.Current, Key = key, Item = defId })
end

local function onItemResult(ok: boolean, reason: string, payload: { [string]: any })
	if type(payload) ~= "table" then
		payload = {}
	end
	local action = payload.Action
	if reason == "Pickup" or payload.DropId ~= nil then
		return -- LootController shows pickups and bag-full on its own
	end
	if not ok then
		if reason == "Cooldown" and payload.Quick then
			return
		end
		UISound.Play("UIError")
		toast(S.Errors[reason] or S.Errors.Invalid, UITheme.Colors.Danger, `error:{reason}`)
		return
	end
	if reason == "RecipeLearned" and type(payload.Recipes) == "table" then
		UISound.Play("UIConfirm")
		local list = payload.Recipes :: { string }
		if #list == 1 then
			local recipe = Recipes.Get(list[1])
			local name = if recipe then ItemText.Name(recipe.Output) else list[1]
			toast(Strings.Format(Strings.Toasts.RecipeLearned, { name = name }), UITheme.Colors.Current, nil, if recipe then recipe.Output else nil)
		else
			toast(Strings.Format(Strings.Toasts.RecipesLearned, { count = #list }), UITheme.Colors.Current)
		end
		return
	end
	if reason == "Broken" and type(payload.DefId) == "string" then
		UISound.Play("UIError")
		toast(Strings.Format(Strings.Toasts.Broken, { name = ItemText.Name(payload.DefId) }), UITheme.Colors.Danger, nil, payload.DefId)
		return
	end
	if action and STATION_ACTIONS[action] then
		return -- StationController handles its own feedback
	end
	if action == "Equip" then
		UISound.Play("ItemEquip")
	elseif action == "Use" then
		UISound.Play("ItemUse")
	elseif action == "Salvage" and type(payload.Yield) == "table" then
		local parts = {}
		for id, count in payload.Yield do
			table.insert(parts, `{count} {ItemText.Name(id)}`)
		end
		toast(Strings.Format(Strings.Stations.Salvaged, { yield = table.concat(parts, ", ") }), UITheme.Colors.TextMuted)
	elseif action == "SlotCore" or (action == "Use" and payload.DefId and Items.Get(payload.DefId) and (Items.Get(payload.DefId) :: Items.ItemDef).Type == "BeaconCore") then
		UISound.Play("ItemEquip")
		toast(Strings.Format(Strings.Toasts.CoreSlotted, { name = ItemText.Name(payload.DefId or "") }), UITheme.Colors.Current, nil, payload.DefId)
	elseif action == "UnslotCore" then
		toast(Strings.Toasts.CoreRemoved, UITheme.Colors.TextMuted)
	end
end

-- The item's actions (equip, use, lock, salvage...) as a context menu.
function InventoryController.OpenItemContext(item: ItemInstance, anchor: GuiObject?)
	openContext(item, anchor)
end

-- Opens the Inventory page with the bag filtered (an empty equipment slot
-- on the Character page shows what fits it).
function InventoryController.ShowFiltered(filter: string)
	requestedFilter = if table.find(FILTERS, filter) then filter else "All"
	UIController.Open(MENU_ID)
end

function InventoryController.Init()
	UIController.RegisterMenu({
		Id = MENU_ID,
		Title = S.InventoryTitle,
		Action = "OpenInventory",
		FullScreen = true,
		ShowInHub = true,
		Icon = "Inventory",
		Nav = "Journal",
		Build = buildInventory,
	})
	Net.OnClient("ItemResult", onItemResult)
end

function InventoryController.Start()
	-- Overburdened warning once each time it starts.
	player:GetAttributeChangedSignal("Overburdened"):Connect(function()
		if player:GetAttribute("Overburdened") == true then
			toast(Strings.Toasts.Overburdened, UITheme.Colors.Stamina, "overburdened")
		end
	end)
end

return InventoryController
