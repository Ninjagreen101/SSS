--!strict
--[[
	TradeController
	Trade requests and the trade window (Phase 12; the server side is
	TradeService, which decides everything).

	- TradeController.RequestTrade(userId) asks another player to trade
	  (the Party menu, Inspect and others call it). Right-clicking another
	  player's character with a free cursor (hold Free Cursor), or a touch
	  long-press on one, opens a small menu with Trade.
	- An incoming request shows a card with Accept / Decline until it
	  expires.
	- The window: your offer on the left, theirs on the right, each with
	  rarity-coloured slots, full item tooltips (hover, gamepad selection or
	  long-press), an item list that names every item with its rarity and
	  count, and the gold offered. Your bag is below your offer: click an
	  item to offer it (stacks ask how many), click an offered item to take
	  it back. Lock, then CountdownSeconds after both lock, Confirm.
	- Anti-scam: whenever the other side's offer changes, their panel
	  flashes, its header says so and the changed slots are ringed; any
	  change also unlocks both sides on the server.
	- Closing the window cancels the trade.
]]

local Players = game:GetService("Players")
local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Strings = require(Shared.Strings)
local Types = require(Shared.Types)
local Net = require(Shared.Net)
local Items = require(Shared.Data.Items)
local Rules = require(Shared.Data.InventoryRules)
local Maid = require(Shared.Util.Maid)
local MathUtil = require(Shared.Util.MathUtil)

local UI = script.Parent.Parent.UI
local UITheme = require(UI.UITheme)
local Create = require(UI.Create)
local Layers = require(UI.Layers)
local Motion = require(UI.Motion)
local Device = require(UI.Device)
local UISound = require(UI.UISound)
local Icons = require(UI.Icons)
local ItemText = require(UI.ItemText)
local Components = require(UI.Components)

local UIController = require(script.Parent.UIController)
local DataController = require(script.Parent.DataController)
local InputController = require(script.Parent.InputController)

type ItemInstance = Types.ItemInstance
type PlayerData = Types.PlayerData

type OfferView = {
	UserId: number,
	Name: string,
	Items: { ItemInstance },
	Gold: number,
	Locked: boolean,
	Confirmed: boolean,
	Revision: number,
}

type TradeView = {
	Id: number,
	Phase: string,
	CountdownEndsAt: number,
	MaxItems: number,
	You: OfferView,
	Them: OfferView,
}

type OfferPanel = {
	Frame: Frame,
	Title: TextLabel,
	Badge: TextLabel,
	BadgeIcon: ImageLabel,
	Slots: { Components.ItemSlot },
	SlotItems: { [number]: ItemInstance },
	List: Components.ScrollList,
	Gold: TextLabel,
	Overlay: Frame,
}

local S = Strings.Trade
local T = Config.Social.Trade
local C = UITheme.Colors

local MENU_ID = "Trade"
local SLOT = 64
local GAP = 8
local COLUMNS = 4
local BUTTON_HEIGHT = 52 -- touch targets stay above UITheme.Size.MinTouchTarget
local GOLD_COLOR = C.Stamina
local FLASH_SECONDS = 4 -- how long a change by the other side stays highlighted
local PICK_RANGE = 250 -- studs a right-click / long-press looks along for a character
local OPEN_RETRIES = 8

local player = Players.LocalPlayer

local TradeController = {}

local current: TradeView? = nil
local dismissedId = 0 -- the trade this client closed (never reopened while the server ends it)
local changedUids: { [string]: boolean } = {}
local flashToken = 0
local openAttempts = 0
local requestMaid = Maid.new()
local requestCard: Frame? = nil -- the incoming request card while it shows
local requestAccept: GuiObject? = nil

-- Set by the window once it is built.
local renderWindow: (() -> ())? = nil
local flashWindow: (() -> ())? = nil

local function now(): number
	return Workspace:GetServerTimeNow()
end

local function send(action: string, text: string?, amount: number?)
	Net.FireServer("RequestTrade", action, text or "", amount or 0)
end

-- STATE --------------------------------------------------------------------------------

local function parseOffer(raw: any): OfferView?
	if type(raw) ~= "table" or type(raw.Items) ~= "table" then
		return nil
	end
	return {
		UserId = tonumber(raw.UserId) or 0,
		Name = tostring(raw.Name or ""),
		Items = raw.Items :: { ItemInstance },
		Gold = tonumber(raw.Gold) or 0,
		Locked = raw.Locked == true,
		Confirmed = raw.Confirmed == true,
		Revision = tonumber(raw.Revision) or 0,
	}
end

local function parse(raw: any): TradeView?
	if type(raw) ~= "table" then
		return nil
	end
	local you, them = parseOffer(raw.You), parseOffer(raw.Them)
	if not you or not them then
		return nil
	end
	return {
		Id = tonumber(raw.Id) or 0,
		Phase = tostring(raw.Phase or "Open"),
		CountdownEndsAt = tonumber(raw.CountdownEndsAt) or 0,
		MaxItems = tonumber(raw.MaxItems) or T.MaxItems,
		You = you,
		Them = them,
	}
end

local function offeredCount(uid: string): number
	local trade = current
	if trade then
		for _, item in trade.You.Items do
			if item.Uid == uid then
				return item.Count
			end
		end
	end
	return 0
end

local function canOffer(data: PlayerData, item: ItemInstance): boolean
	local def = Items.Get(item.DefId)
	return def ~= nil and def.Tradeable and not item.Locked and Rules.EquippedSlot(data, item.Uid) == nil
end

-- The other player's item for display: their uids mean nothing in your profile.
local function theirCopy(item: ItemInstance): ItemInstance
	local copy = table.clone(item)
	copy.Uid = `trade:{item.Uid}`
	copy.New = false
	copy.Locked = false
	return copy
end

local function sameItem(a: ItemInstance, b: ItemInstance): boolean
	if a.Count ~= b.Count or a.DefId ~= b.DefId or a.Rarity ~= b.Rarity or a.Upgrade ~= b.Upgrade or a.Durability ~= b.Durability then
		return false
	end
	if a.Unique ~= b.Unique or #a.Affixes ~= #b.Affixes then
		return false
	end
	for index, affix in a.Affixes do
		local other = b.Affixes[index]
		if affix.Id ~= other.Id or affix.Value ~= other.Value then
			return false
		end
	end
	return true
end

-- Uids of the other side's items that are new or different since `before`.
local function changesBetween(before: OfferView, after: OfferView): { [string]: boolean }
	local old: { [string]: ItemInstance } = {}
	for _, item in before.Items do
		old[item.Uid] = item
	end
	local changed: { [string]: boolean } = {}
	for _, item in after.Items do
		local was = old[item.Uid]
		if not was or not sameItem(was, item) then
			changed[item.Uid] = true
		end
	end
	return changed
end

local function confirmReady(trade: TradeView): boolean
	if trade.You.Confirmed then
		return false
	end
	return trade.Phase == "Confirm" or (trade.Phase == "Countdown" and now() >= trade.CountdownEndsAt)
end

-- WINDOW -------------------------------------------------------------------------------

local function sectionLabel(text: string, parent: Instance, position: UDim2?, size: UDim2?): TextLabel
	return Create.Label({
		Text = text,
		Font = UITheme.Fonts.BodyBold,
		TextSize = UITheme.TextSize.BodyLarge,
		Color = C.Accent,
		Position = position,
		Size = size or UDim2.new(1, 0, 0, 28),
		Parent = parent,
	})
end

local function offerPanel(parent: Frame, position: UDim2, size: UDim2, maid: Maid.Maid, mine: boolean): OfferPanel
	local frame: Frame = Create.new("Frame", {
		Name = if mine then "YourOffer" else "TheirOffer",
		Position = position,
		Size = size,
		Parent = parent,
	})
	Create.ApplyPanelStyle(frame, { Glow = false })
	Create.Padding(frame, UITheme.Padding.Medium)

	local title = sectionLabel(if mine then S.YourOffer else "", frame, UDim2.new(), UDim2.new(1, -150, 0, 28))
	title.TextTruncate = Enum.TextTruncate.AtEnd

	-- Lock state badge (top right): icon + text, so it never relies on colour alone.
	local badgeRow: Frame = Create.new("Frame", {
		Name = "Badge",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.fromOffset(146, 28),
		Parent = frame,
	})
	Create.List(badgeRow, Enum.FillDirection.Horizontal, 6, Enum.HorizontalAlignment.Right, Enum.VerticalAlignment.Center)
	local badgeIcon = Icons.new("Lock", { Size = UDim2.fromOffset(18, 18), Color = C.TextDim, LayoutOrder = 1, Parent = badgeRow })
	local badge = Create.Label({
		Text = S.NotLocked,
		Font = UITheme.Fonts.BodyBold,
		Color = C.TextDim,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.new(0, 0, 1, 0),
		LayoutOrder = 2,
		Parent = badgeRow,
	})

	local rows = math.max(1, math.ceil(T.MaxItems / COLUMNS))
	local gridWidth = COLUMNS * SLOT + (COLUMNS - 1) * GAP
	local gridHeight = rows * SLOT + (rows - 1) * GAP
	local grid: Frame = Create.new("Frame", {
		Name = "Slots",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 36),
		Size = UDim2.fromOffset(gridWidth, gridHeight),
		Parent = frame,
	})
	Create.new("UIGridLayout", {
		CellSize = UDim2.fromOffset(SLOT, SLOT),
		CellPadding = UDim2.fromOffset(GAP, GAP),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = grid,
	})

	local list = Components.ScrollList.new({
		Position = UDim2.fromOffset(gridWidth + UITheme.Padding.Medium, 36),
		Size = UDim2.new(1, -(gridWidth + UITheme.Padding.Medium), 0, gridHeight),
		Spacing = 2,
		Parent = frame,
	})
	maid:Add(list)

	-- Gold row along the bottom.
	local goldRow: Frame = Create.new("Frame", {
		Name = "GoldRow",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, BUTTON_HEIGHT),
		Parent = frame,
	})
	Create.List(goldRow, Enum.FillDirection.Horizontal, UITheme.Padding.Small, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)
	Icons.new("Gold", { Size = UDim2.fromOffset(26, 26), Color = GOLD_COLOR, LayoutOrder = 1, Parent = goldRow })
	Create.Label({
		Text = S.Gold,
		Font = UITheme.Fonts.BodyBold,
		Color = C.TextMuted,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.new(0, 0, 1, 0),
		LayoutOrder = 2,
		Parent = goldRow,
	})
	local gold = Create.Label({
		Name = "GoldValue",
		Text = "0",
		Font = UITheme.Fonts.Numbers,
		TextSize = UITheme.TextSize.Heading,
		Color = GOLD_COLOR,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.new(0, 0, 1, 0),
		LayoutOrder = 3,
		Parent = goldRow,
	})

	-- Change flash (their side).
	local overlay: Frame = Create.new("Frame", {
		Name = "Flash",
		BackgroundColor3 = C.Parry,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(-UITheme.Padding.Medium, -UITheme.Padding.Medium),
		Size = UDim2.new(1, UITheme.Padding.Medium * 2, 1, UITheme.Padding.Medium * 2),
		ZIndex = 8,
		Parent = frame,
	})
	Create.Corner(overlay)
	overlay.Active = false

	local panel: OfferPanel = {
		Frame = frame,
		Title = title,
		Badge = badge,
		BadgeIcon = badgeIcon,
		Slots = {},
		SlotItems = {},
		List = list,
		Gold = gold,
		Overlay = overlay,
	}
	for index = 1, T.MaxItems do
		local slot = Components.ItemSlot.new({ Size = SLOT, LayoutOrder = index, Parent = grid })
		maid:Add(slot)
		table.insert(panel.Slots, slot)
		if mine then
			slot.Activated:Connect(function()
				local item = panel.SlotItems[index]
				local trade = current
				if not item or not trade then
					return
				end
				if trade.You.Locked then
					UISound.Play("UIError")
					return
				end
				send("RemoveItem", item.Uid)
			end)
		end
		-- Your own items: a touch tap takes the item back, so tooltips there are hover/gamepad only.
		if not mine or not Device.IsTouch() then
			maid:Add(Components.Tooltip.Attach(slot.Instance, function(): Components.TooltipContent?
				local item = panel.SlotItems[index]
				if not item then
					return nil
				end
				return ItemText.Tooltip(if mine then item else theirCopy(item), DataController.GetData())
			end))
		end
	end
	return panel
end

local function setBadge(panel: OfferPanel, offer: OfferView)
	local text, color, icon = S.NotLocked, C.TextDim, "Lock"
	if offer.Confirmed then
		text, color, icon = S.Confirmed, C.Heal, "Check"
	elseif offer.Locked then
		text, color = S.Locked, C.Heal
	end
	panel.Badge.Text = text
	panel.Badge.TextColor3 = color
	panel.BadgeIcon.ImageColor3 = color
	Icons.Apply(panel.BadgeIcon, icon)
end

local function fillOffer(panel: OfferPanel, offer: OfferView, mine: boolean)
	table.clear(panel.SlotItems)
	for index, slot in panel.Slots do
		local item = offer.Items[index]
		if item then
			panel.SlotItems[index] = item
			slot:SetItem(ItemText.Slot(if mine then item else theirCopy(item)))
			slot:SetSelected(not mine and changedUids[item.Uid] == true)
		else
			slot:SetItem(nil)
			slot:SetSelected(false)
		end
	end

	panel.List:Clear()
	local order = 0
	local function line(text: string, color: Color3)
		order += 1
		local label = Create.Label({
			Text = text,
			Font = UITheme.Fonts.BodyMedium,
			TextSize = UITheme.TextSize.Small,
			Color = color,
			Size = UDim2.new(1, -6, 0, 20),
			LayoutOrder = order,
		})
		label.TextTruncate = Enum.TextTruncate.AtEnd
		panel.List:Add(label)
	end
	for _, item in offer.Items do
		line(Strings.Format(S.ItemLine, {
			name = ItemText.FullName(item),
			rarity = ItemText.RarityName(item.Rarity),
			count = item.Count,
		}), UITheme.RarityColor(item.Rarity))
	end
	if offer.Gold > 0 then
		line(Strings.Format(S.GoldLine, { gold = MathUtil.FormatNumber(offer.Gold) }), GOLD_COLOR)
	end
	if order == 0 then
		line(S.Nothing, C.TextDim)
	end
	panel.Gold.Text = MathUtil.FormatNumber(offer.Gold)
end

local function promptCount(item: ItemInstance)
	local offered = offeredCount(item.Uid)
	Components.CountDialog.Show({
		Title = S.CountTitle,
		Min = 1,
		Max = item.Count,
		Value = if offered > 0 then offered else item.Count,
		ConfirmText = S.CountConfirm,
	}):andThen(function(count: number?): any
		if count and current then
			send("SetItem", item.Uid, count)
		end
		return nil
	end)
end

local function offerFromBag(item: ItemInstance)
	local trade = current
	if not trade then
		return
	end
	if trade.You.Locked then
		UISound.Play("UIError")
		return
	end
	if item.Count > 1 then
		promptCount(item)
	elseif offeredCount(item.Uid) > 0 then
		send("RemoveItem", item.Uid)
	else
		send("SetItem", item.Uid, 1)
	end
end

local function build(content: Frame, maid: Maid.Maid): UIController.MenuContent
	local half = UITheme.Padding.Small / 2
	local your = offerPanel(content, UDim2.new(), UDim2.new(0.5, -half, 0.5, -half), maid, true)
	local their = offerPanel(content, UDim2.new(0.5, half, 0, 0), UDim2.new(0.5, -half, 0.5, -half), maid, false)

	-- Your gold: a number field and a Set button (the label shows what is offered now).
	local goldRow = your.Gold.Parent :: Frame
	local goldBox: TextBox = Create.new("TextBox", {
		Name = "GoldInput",
		Text = "",
		PlaceholderText = "0",
		ClearTextOnFocus = false,
		FontFace = UITheme.Fonts.Numbers,
		TextSize = UITheme.TextSize.Body,
		TextColor3 = C.Text,
		PlaceholderColor3 = C.TextDim,
		BackgroundColor3 = C.PanelSunken,
		BackgroundTransparency = UITheme.SunkenTransparency,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(150, 44),
		LayoutOrder = 4,
		SelectionImageObject = Create.SelectionImage(),
		Parent = goldRow,
	})
	Create.Corner(goldBox, UITheme.CornerSmall)
	Create.Stroke(goldBox, C.Edge, 1, 0.3)
	Create.Padding(goldBox, 0, UITheme.Padding.Small, 0)
	local function submitGold()
		local trade = current
		if not trade then
			return
		end
		local digits = string.gsub(goldBox.Text, "[^%d]", "")
		local value = math.clamp(tonumber(digits) or 0, 0, Config.Economy.MaxGold)
		goldBox.Text = ""
		if trade.You.Locked then
			UISound.Play("UIError")
			return
		end
		if value ~= trade.You.Gold then
			send("SetGold", nil, value)
		end
	end
	maid:Add(goldBox.FocusLost:Connect(function(enterPressed: boolean)
		if enterPressed then
			submitGold()
		end
	end))
	local setGold = Components.Button.new({
		Text = S.SetGold,
		Size = UDim2.fromOffset(90, 44),
		LayoutOrder = 5,
		Parent = goldRow,
		OnActivated = submitGold,
	})
	maid:Add(setGold)

	-- Bag (bottom left).
	local bagFrame: Frame = Create.new("Frame", {
		Name = "Bag",
		Position = UDim2.new(0, 0, 0.5, half),
		Size = UDim2.new(0.5, -half, 0.5, -half),
		Parent = content,
	})
	Create.ApplyPanelStyle(bagFrame, { Glow = false })
	Create.Padding(bagFrame, UITheme.Padding.Medium)
	sectionLabel(S.Bag, bagFrame)
	local bagHint = Create.Label({
		Text = S.BagHint,
		TextSize = UITheme.TextSize.Caption,
		Color = C.TextDim,
		Wrapped = true,
		Position = UDim2.fromOffset(0, 28),
		Size = UDim2.new(1, 0, 0, 34),
		Parent = bagFrame,
	})
	local bagGrid = Components.ScrollList.new({
		Position = UDim2.fromOffset(0, 66),
		Size = UDim2.new(1, 0, 1, -66),
		Grid = { CellSize = UDim2.fromOffset(SLOT, SLOT), CellPadding = UDim2.fromOffset(GAP, GAP) },
		Parent = bagFrame,
	})
	maid:Add(bagGrid)
	local bagMaid = Maid.new()
	maid:Add(bagMaid)

	-- Status and buttons (bottom right).
	local statusFrame: Frame = Create.new("Frame", {
		Name = "Status",
		Position = UDim2.new(0.5, half, 0.5, half),
		Size = UDim2.new(0.5, -half, 0.5, -half),
		Parent = content,
	})
	Create.ApplyPanelStyle(statusFrame, { Glow = false })
	Create.Padding(statusFrame, UITheme.Padding.Medium)
	local status = Create.Label({
		Text = "",
		TextSize = UITheme.TextSize.BodyLarge,
		Font = UITheme.Fonts.BodyMedium,
		Wrapped = true,
		XAlignment = Enum.TextXAlignment.Center,
		Size = UDim2.new(1, 0, 0, 56),
		Parent = statusFrame,
	})
	local countdown = Create.Label({
		Text = "",
		Font = UITheme.Fonts.Title,
		TextSize = UITheme.TextSize.Hero,
		Color = C.Parry,
		XAlignment = Enum.TextXAlignment.Center,
		Position = UDim2.fromOffset(0, 60),
		Size = UDim2.new(1, 0, 0, 56),
		Parent = statusFrame,
	})

	local buttons: Frame = Create.new("Frame", {
		Name = "Buttons",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, BUTTON_HEIGHT),
		Parent = statusFrame,
	})
	Create.List(buttons, Enum.FillDirection.Horizontal, UITheme.Padding.Small, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
	local width = UDim2.new(1 / 3, -6, 0, BUTTON_HEIGHT)
	local lock = Components.Button.new({ Text = S.Lock, Icon = "Lock", Variant = "Primary", Size = width, LayoutOrder = 1, Parent = buttons })
	local unlock = Components.Button.new({ Text = S.Unlock, Variant = "Secondary", Size = width, LayoutOrder = 1, Parent = buttons })
	local confirm = Components.Button.new({ Text = S.Confirm, Icon = "Check", Variant = "Primary", Size = width, LayoutOrder = 2, Parent = buttons })
	local cancel = Components.Button.new({ Text = S.Cancel, Variant = "Danger", Size = width, LayoutOrder = 3, Parent = buttons })
	maid:Add(lock)
	maid:Add(unlock)
	maid:Add(confirm)
	maid:Add(cancel)
	lock.Activated:Connect(function()
		send("Lock")
	end)
	unlock.Activated:Connect(function()
		send("Unlock")
	end)
	confirm.Activated:Connect(function()
		local trade = current
		if trade and confirmReady(trade) then
			UISound.Play("UIConfirm")
			send("Confirm")
		end
	end)
	cancel.Activated:Connect(function()
		UIController.Close()
	end)

	local function renderBag(trade: TradeView, data: PlayerData?)
		bagMaid:Clean()
		bagGrid:Clear()
		bagHint.Text = if trade.You.Locked then S.UnlockToEdit else S.BagHint
		bagHint.TextColor3 = if trade.You.Locked then C.Parry else C.TextDim
		if not data then
			return
		end
		local list: { ItemInstance } = {}
		for _, item in data.Inventory.Items do
			if canOffer(data, item) then
				table.insert(list, item)
			end
		end
		table.sort(list, function(a: ItemInstance, b: ItemInstance): boolean
			local ra, rb = Items.RarityRank(a.Rarity), Items.RarityRank(b.Rarity)
			if ra ~= rb then
				return ra > rb
			end
			local na, nb = ItemText.Name(a.DefId), ItemText.Name(b.DefId)
			return if na ~= nb then na < nb else a.Uid < b.Uid
		end)
		if #list == 0 then
			bagHint.Text = S.BagEmpty
		end
		for index, item in list do
			local slot = Components.ItemSlot.new({ Size = SLOT, LayoutOrder = index })
			bagMaid:Add(slot)
			slot:SetItem(ItemText.Slot(item))
			slot:SetSelected(offeredCount(item.Uid) > 0)
			slot.Instance.BackgroundTransparency = if trade.You.Locked then 0.6 else UITheme.SunkenTransparency
			slot.Activated:Connect(function()
				offerFromBag(item)
			end)
			if not Device.IsTouch() then
				bagMaid:Add(Components.Tooltip.Attach(slot.Instance, function(): Components.TooltipContent?
					return ItemText.Tooltip(item, DataController.GetData())
				end))
			end
			bagGrid:Add(slot.Instance)
		end
	end

	local function statusText(trade: TradeView): string
		local args = { name = trade.Them.Name, seconds = math.max(0, math.ceil(trade.CountdownEndsAt - now())) }
		if trade.You.Confirmed then
			return Strings.Format(S.StatusConfirmed, args)
		elseif confirmReady(trade) then
			return S.StatusConfirm
		elseif trade.Phase == "Countdown" then
			return Strings.Format(S.StatusCountdown, args)
		elseif trade.You.Locked then
			return Strings.Format(S.StatusWaitingThem, args)
		elseif trade.Them.Locked then
			return Strings.Format(S.StatusTheyLocked, args)
		end
		return S.StatusOpen
	end

	-- Per-frame bits: the countdown and when Confirm becomes available.
	local function tick()
		local trade = current
		if not trade then
			return
		end
		local counting = trade.Phase == "Countdown" and now() < trade.CountdownEndsAt
		countdown.Visible = counting
		countdown.Text = if counting then tostring(math.max(1, math.ceil(trade.CountdownEndsAt - now()))) else ""
		status.Text = statusText(trade)
		local ready = confirmReady(trade)
		if confirm:IsEnabled() ~= ready then
			confirm:SetEnabled(ready)
		end
	end

	local function render()
		local trade = current
		if not trade then
			return
		end
		if flashToken == 0 or next(changedUids) == nil then
			their.Title.Text = Strings.Format(S.TheirOffer, { name = trade.Them.Name })
			their.Title.TextColor3 = C.Accent
		end
		setBadge(your, trade.You)
		setBadge(their, trade.Them)
		fillOffer(your, trade.You, true)
		fillOffer(their, trade.Them, false)
		setGold:SetEnabled(not trade.You.Locked)
		goldBox.TextEditable = not trade.You.Locked
		-- Lock and Unlock share a spot; keep gamepad selection on whichever shows.
		local selected = GuiService.SelectedObject
		lock.Instance.Visible = not trade.You.Locked
		unlock.Instance.Visible = trade.You.Locked
		if selected == lock.Instance and trade.You.Locked then
			GuiService.SelectedObject = unlock.Instance
		elseif selected == unlock.Instance and not trade.You.Locked then
			GuiService.SelectedObject = lock.Instance
		end
		renderBag(trade, DataController.GetData())
		tick()
	end

	-- Their offer changed: pulse the panel, say so in its header, ring the changed slots.
	local function flash()
		local trade = current
		if not trade then
			return
		end
		flashToken += 1
		local token = flashToken
		UISound.Play("UIError")
		their.Title.Text = Strings.Format(S.Changed, { name = trade.Them.Name })
		their.Title.TextColor3 = C.Parry
		local overlay = their.Overlay
		if Motion.IsReduced() then
			overlay.BackgroundTransparency = 0.8
		else
			overlay.BackgroundTransparency = 1
			TweenService:Create(overlay, TweenInfo.new(0.35, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, 3, true), {
				BackgroundTransparency = 0.55,
			}):Play()
		end
		task.delay(FLASH_SECONDS, function()
			if token ~= flashToken then
				return
			end
			table.clear(changedUids)
			overlay.BackgroundTransparency = 1
			local latest = current
			if latest then
				their.Title.Text = Strings.Format(S.TheirOffer, { name = latest.Them.Name })
				their.Title.TextColor3 = C.Accent
			end
			render()
		end)
	end

	renderWindow = render
	flashWindow = flash

	return {
		OnOpen = function()
			render()
			maid:Set("tick", RunService.RenderStepped:Connect(tick))
			maid:Set("data", DataController.Changed:Connect(function(path: { string })
				local root = path[1]
				if (root == "Inventory" or root == "Equipped") and current then
					renderBag(current :: TradeView, DataController.GetData())
				end
			end))
		end,
		OnClose = function()
			maid:Set("tick", nil)
			maid:Set("data", nil)
			Components.Tooltip.Hide()
			local trade = current
			if trade and trade.Id ~= dismissedId then
				-- Closing the window (X, Back, Cancel or another menu) cancels the trade.
				dismissedId = trade.Id
				send("Cancel")
			end
		end,
	}
end

local function ensureOpen()
	local trade = current
	if not trade or trade.Id == dismissedId or UIController.GetOpen() == MENU_ID then
		openAttempts = 0
		return
	end
	UIController.Open(MENU_ID)
	if UIController.GetOpen() ~= MENU_ID and openAttempts < OPEN_RETRIES then
		-- UIController was mid-animation; try again shortly.
		openAttempts += 1
		task.delay(0.25, ensureOpen)
	else
		openAttempts = 0
	end
end

-- REQUEST CARD -------------------------------------------------------------------------

local function hideRequest()
	requestMaid:Clean()
end

local function showRequest(fromUserId: number, fromName: string, expiresAt: number)
	requestMaid:Clean()
	local card: Frame = Create.new("Frame", {
		Name = "TradeRequest",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 96),
		Size = UDim2.fromOffset(400, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = Layers.Get("Overlay"),
	})
	requestMaid:Add(card)
	Create.ApplyPanelStyle(card)
	Create.Padding(card, UITheme.Padding.Medium)
	Create.List(card, Enum.FillDirection.Vertical, UITheme.Padding.Small, Enum.HorizontalAlignment.Center)

	Create.Label({
		Text = Strings.Format(S.RequestTitle, { name = fromName }),
		Font = UITheme.Fonts.Title,
		TextSize = UITheme.TextSize.Heading,
		Color = C.Accent,
		XAlignment = Enum.TextXAlignment.Center,
		LayoutOrder = 1,
		Parent = card,
	}).TextTruncate = Enum.TextTruncate.AtEnd
	Create.Label({
		Text = S.RequestBody,
		Color = C.TextMuted,
		XAlignment = Enum.TextXAlignment.Center,
		LayoutOrder = 2,
		Parent = card,
	})
	local hint = ""
	if Device.IsGamepad() then
		hint = S.GamepadHint
	elseif not Device.IsTouch() and UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter then
		hint = Strings.Format(S.CursorHint, { key = InputController.GetPrompt("FreeCursor") })
	end
	if hint ~= "" then
		Create.Label({
			Text = hint,
			TextSize = UITheme.TextSize.Caption,
			Color = C.TextDim,
			XAlignment = Enum.TextXAlignment.Center,
			LayoutOrder = 3,
			Parent = card,
		})
	end

	local track: Frame = Create.new("Frame", {
		Name = "Time",
		BackgroundColor3 = C.Track,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 4),
		LayoutOrder = 4,
		Parent = card,
	})
	local fill: Frame = Create.new("Frame", {
		BackgroundColor3 = C.Current,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Parent = track,
	})

	local row: Frame = Create.new("Frame", {
		Name = "Buttons",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, BUTTON_HEIGHT),
		LayoutOrder = 5,
		Parent = card,
	})
	Create.List(row, Enum.FillDirection.Horizontal, UITheme.Padding.Small, Enum.HorizontalAlignment.Center)
	local text = tostring(fromUserId)
	local acceptButton = Components.Button.new({
		Text = S.Accept,
		Variant = "Primary",
		Size = UDim2.new(0.5, -4, 1, 0),
		LayoutOrder = 1,
		Parent = row,
		OnActivated = function()
			send("Accept", text)
			hideRequest()
		end,
	})
	requestMaid:Add(acceptButton)
	requestMaid:Add(Components.Button.new({
		Text = S.Decline,
		Variant = "Secondary",
		Size = UDim2.new(0.5, -4, 1, 0),
		LayoutOrder = 2,
		Parent = row,
		OnActivated = function()
			send("Decline", text)
			hideRequest()
		end,
	}))

	local total = math.max(1, expiresAt - now())
	requestMaid:Add(RunService.RenderStepped:Connect(function()
		local left = expiresAt - now()
		if left <= 0 then
			hideRequest()
			return
		end
		fill.Size = UDim2.fromScale(math.clamp(left / total, 0, 1), 1)
	end))
	requestMaid:Add(function()
		local selected = GuiService.SelectedObject
		if selected and selected:IsDescendantOf(card) then
			GuiService.SelectedObject = nil
		end
	end)
	UISound.Play("UIToast")
end

-- PLAYER MENU (right-click / long-press a character) -----------------------------------

local function playerAt(position: Vector2, viewport: boolean): Player?
	local camera = Workspace.CurrentCamera
	if not camera then
		return nil
	end
	local ray = if viewport then camera:ViewportPointToRay(position.X, position.Y) else camera:ScreenPointToRay(position.X, position.Y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = if player.Character then { player.Character :: Instance } else {}
	local result = Workspace:Raycast(ray.Origin, ray.Direction * PICK_RANGE, params)
	if not result then
		return nil
	end
	local model = result.Instance:FindFirstAncestorOfClass("Model")
	while model do
		local owner = Players:GetPlayerFromCharacter(model)
		if owner then
			return if owner ~= player then owner else nil
		end
		model = model:FindFirstAncestorOfClass("Model")
	end
	return nil
end

local function openPlayerMenu(target: Player)
	Components.ContextMenu.Show({
		Title = target.DisplayName,
		Options = {
			{
				Text = S.MenuTrade,
				Enabled = current == nil,
				OnSelect = function()
					TradeController.RequestTrade(target.UserId)
				end,
			},
		},
	})
end

-- PUBLIC API ---------------------------------------------------------------------------

-- Asks another player in this server to trade (the server checks range, town, combat...).
function TradeController.RequestTrade(userId: number)
	if type(userId) ~= "number" or userId <= 0 or userId % 1 ~= 0 or userId == player.UserId then
		return
	end
	send("Request", tostring(userId))
end

function TradeController.IsTrading(): boolean
	return current ~= nil
end

-- LIFECYCLE ----------------------------------------------------------------------------

local function onTradeState(raw: any)
	local trade = parse(raw)
	local previous = current
	current = trade
	if not trade then
		table.clear(changedUids)
		flashToken = 0
		if UIController.GetOpen() == MENU_ID then
			UIController.Close()
		end
		return
	end
	hideRequest()
	if previous and previous.Id == trade.Id and trade.Them.Revision > previous.Them.Revision then
		for uid in changesBetween(previous.Them, trade.Them) do
			changedUids[uid] = true
		end
		if flashWindow and UIController.GetOpen() == MENU_ID then
			(flashWindow :: () -> ())()
		end
	elseif not previous or previous.Id ~= trade.Id then
		table.clear(changedUids)
	end
	ensureOpen()
	if renderWindow and UIController.GetOpen() == MENU_ID then
		(renderWindow :: () -> ())()
	end
end

local function onTradeRequest(fromUserId: any, fromName: any, expiresAt: any)
	if type(fromUserId) ~= "number" or type(expiresAt) ~= "number" or current ~= nil then
		return
	end
	showRequest(fromUserId, tostring(fromName), expiresAt)
end

function TradeController.Init()
	UIController.RegisterMenu({
		Id = MENU_ID,
		Title = S.Title,
		FullScreen = true,
		ShowInHub = false,
		Size = Vector2.new(1100, 700),
		Build = build,
	})
	Net.OnClient("TradeState", onTradeState)
	Net.OnClient("TradeRequest", onTradeRequest)
end

function TradeController.Start()
	-- Right-click another player's character while the cursor is free.
	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if processed or input.UserInputType ~= Enum.UserInputType.MouseButton2 then
			return
		end
		if UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter or UIController.IsMenuOpen() then
			return
		end
		local target = playerAt(UserInputService:GetMouseLocation(), true)
		if target then
			openPlayerMenu(target)
		end
	end)
	-- Long-press another player's character on touch.
	UserInputService.TouchLongPress:Connect(function(positions: { any }, state: Enum.UserInputState, processed: boolean)
		if processed or state ~= Enum.UserInputState.Begin or UIController.IsMenuOpen() then
			return
		end
		local position = positions[1]
		if typeof(position) ~= "Vector2" then
			return
		end
		local target = playerAt(position, false)
		if target then
			openPlayerMenu(target)
		end
	end)
end

return TradeController
