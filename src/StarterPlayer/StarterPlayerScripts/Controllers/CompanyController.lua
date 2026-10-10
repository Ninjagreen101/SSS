--!strict
--[[
	CompanyController
	The Company menu (Phase 12; CompanyService on the server decides everything):

	- No Company: a create form (name and an emblem picked from Config.Social.Company.Emblems
	  preset icons, founding costs CreateCost gold; locked below UnlockLevel) and the invitations
	  you hold, each with Join / Decline.
	- In a Company: a header (emblem, name, member count, your rank, Change Emblem / Leave /
	  Disband by rank) and three tabs:
	    Members  ranks, who is online (on any server), Promote / Demote / Remove where your rank
	             allows, and an invite field (player name or UserId)
	    Chest    the shared storage grid (rarity slots with full item tooltips; click to
	             withdraw) beside your bag (click to deposit; stacks ask how many)
	    Weekly   the two weekly Company quests with progress, rewards and the reset timer
	- Incoming invitations also show as a card with a draining timer (CompanyInvite).
	- Opening the menu asks the server for fresh state (Refresh).
	- CompanyController.EmblemIcon(index) maps an emblem index to its icon (nameplates use it).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Strings = require(Shared.Strings)
local Types = require(Shared.Types)
local Net = require(Shared.Net)
local Items = require(Shared.Data.Items)
local InventoryRules = require(Shared.Data.InventoryRules)
local Maid = require(Shared.Util.Maid)
local MathUtil = require(Shared.Util.MathUtil)

local UI = script.Parent.Parent.UI
local UITheme = require(UI.UITheme)
local Create = require(UI.Create)
local Layers = require(UI.Layers)
local UISound = require(UI.UISound)
local Icons = require(UI.Icons)
local ItemText = require(UI.ItemText)
local Device = require(UI.Device)
local Animator = require(UI.Animator)
local Components = require(UI.Components)

local UIController = require(script.Parent.UIController)
local DataController = require(script.Parent.DataController)

type ItemInstance = Types.ItemInstance
type PlayerData = Types.PlayerData

type MemberView = { UserId: number, Name: string, Rank: string, Online: boolean }
type QuestView = { Id: string, Progress: number, Count: number, Done: boolean, Gold: number, Shards: number }
type CompanyView = {
	Id: string,
	Name: string,
	Emblem: number,
	MyRank: string,
	Permissions: { [string]: boolean },
	Members: { MemberView },
	MaxMembers: number,
	Storage: { ItemInstance },
	StorageSlots: number,
	Quests: { QuestView },
	ResetsAt: number,
}
type InviteView = { CompanyId: string, Name: string, From: string, ExpiresAt: number }
type Card = { Frame: Frame, Timer: Frame, CompanyId: string, Expires: number, Total: number }

type Page = {
	None: Frame,
	Inside: Frame,
	-- no Company
	Locked: TextLabel,
	Form: Frame,
	NameBox: TextBox,
	CreateButton: Components.Button,
	SetCreateEmblem: (number) -> (),
	InviteList: Components.ScrollList,
	-- in a Company
	Emblem: ImageLabel,
	Title: TextLabel,
	Subtitle: TextLabel,
	EmblemButton: Components.Button,
	LeaveButton: Components.Button,
	DisbandButton: Components.Button,
	Tabs: Components.TabBar,
	Pages: { [string]: Frame },
	InviteRow: Frame,
	InviteBox: TextBox,
	MemberList: Components.ScrollList,
	ChestCount: TextLabel,
	ChestHint: TextLabel,
	ChestGrid: Components.ScrollList,
	BagHint: TextLabel,
	BagGrid: Components.ScrollList,
	ResetLabel: TextLabel,
	QuestList: Components.ScrollList,
	EmblemOverlay: Frame,
	SetOverlayEmblem: (number) -> (),
	RowMaid: Maid.Maid,
	ChestMaid: Maid.Maid,
	BagMaid: Maid.Maid,
}

local C = UITheme.Colors
local S = Strings.Company
local K = Config.Social.Company
local localPlayer = Players.LocalPlayer

local MENU_ID = "Company"
local SLOT = 56
local ROW = 52
local CARD_WIDTH = 340
local BUTTON_HEIGHT = Config.Input.MinTouchTarget

-- The preset emblem icons (UI/Icons), by emblem index 1..Config.Social.Company.Emblems.
local EMBLEMS: { string } = {
	"Beacon", "Seawall", "HarborBell", "Keelbreaker", "Glintstorm", "RiptideLunge",
	"Severance", "Floodtide", "Maelstrom", "Kindle", "Tidewell", "GuidingLantern",
	"Windstep", "Vanguard", "Lancer", "Tidecaller", "Beaconkeeper", "Pathfinder",
	"Tide", "Rime", "Tempest", "Abyss", "Bloom", "Keystone",
}

local CompanyController = {}

local state: CompanyView? = nil
local invites: { InviteView } = {}
local page: Page? = nil
local pageOpen = false
local createEmblem = 1
local cards: { Card } = {}
local cardHolder: Frame

-- HELPERS ------------------------------------------------------------------------------------

function CompanyController.EmblemIcon(index: number): string
	if #EMBLEMS == 0 or type(index) ~= "number" or index < 1 then
		return "Guard"
	end
	local name = EMBLEMS[(math.floor(index) - 1) % #EMBLEMS + 1]
	return if Icons.Has(name) then name else "Guard"
end

function CompanyController.GetState(): CompanyView?
	return state
end

local function send(action: string, text: string?, number: number?)
	Net.FireServer("RequestCompany", action, text or "", number or 0)
end

local function now(): number
	return Workspace:GetServerTimeNow()
end

local function rankIndex(rank: string): number
	return table.find(K.Ranks, rank) or (#K.Ranks + 1)
end

local function rankName(rank: string): string
	return S.Ranks[rank] or rank
end

-- Mirrors the server's rank rules for which buttons to show (the server re-checks).
local function allowed(view: CompanyView, action: string, target: MemberView): boolean
	if not view.Permissions[action] or target.UserId == localPlayer.UserId then
		return false
	end
	local mine, theirs = rankIndex(view.MyRank), rankIndex(target.Rank)
	if theirs <= mine or theirs > #K.Ranks then
		return false
	end
	if action == "Promote" then
		return theirs - 1 > mine or mine == 1
	elseif action == "Demote" then
		return theirs < #K.Ranks
	end
	return true
end

local function number(value: any, default: number): number
	return if type(value) == "number" and value == value then value else default
end

-- CompanyState payload -> view (nil = not in a Company).
local function parseState(payload: any): CompanyView?
	if type(payload) ~= "table" or type(payload.Id) ~= "string" or type(payload.Name) ~= "string" then
		return nil
	end
	local members: { MemberView } = {}
	if type(payload.Members) == "table" then
		for _, entry in payload.Members do
			if type(entry) == "table" and type(entry.Name) == "string" and type(entry.Rank) == "string" then
				table.insert(members, {
					UserId = number(entry.UserId, 0),
					Name = entry.Name,
					Rank = entry.Rank,
					Online = entry.Online == true,
				})
			end
		end
	end
	local storage: { ItemInstance } = {}
	if type(payload.Storage) == "table" then
		for _, item in payload.Storage do
			if type(item) == "table" and type(item.Uid) == "string" and type(item.DefId) == "string" and Items.Get(item.DefId) then
				table.insert(storage, item)
			end
		end
	end
	local quests: { QuestView } = {}
	if type(payload.Quests) == "table" then
		for _, entry in payload.Quests do
			if type(entry) == "table" and type(entry.Id) == "string" then
				table.insert(quests, {
					Id = entry.Id,
					Progress = number(entry.Progress, 0),
					Count = math.max(1, number(entry.Count, 1)),
					Done = entry.Done == true,
					Gold = number(entry.Gold, 0),
					Shards = number(entry.Shards, 0),
				})
			end
		end
	end
	local permissions: { [string]: boolean } = {}
	if type(payload.Permissions) == "table" then
		for action, value in payload.Permissions do
			if type(action) == "string" then
				permissions[action] = value == true
			end
		end
	end
	return {
		Id = payload.Id,
		Name = payload.Name,
		Emblem = number(payload.Emblem, 1),
		MyRank = if type(payload.MyRank) == "string" then payload.MyRank else "",
		Permissions = permissions,
		Members = members,
		MaxMembers = number(payload.MaxMembers, K.MaxMembers),
		Storage = storage,
		StorageSlots = number(payload.StorageSlots, K.StorageSlots),
		Quests = quests,
		ResetsAt = number(payload.ResetsAt, 0),
	}
end

local function canStore(data: PlayerData, item: ItemInstance): boolean
	local def = Items.Get(item.DefId)
	return def ~= nil and def.Tradeable and not item.Locked and InventoryRules.EquippedSlot(data, item.Uid) == nil
end

-- A chest item for display: its storage uid means nothing in your bag.
local function chestCopy(item: ItemInstance): ItemInstance
	local copy = table.clone(item)
	copy.Uid = `company:{item.Uid}`
	copy.New = false
	copy.Locked = false
	return copy
end

local function textBox(placeholder: string, maxLength: number, props: { [string]: any }): TextBox
	local box: TextBox = Create.new("TextBox", {
		Name = "Input",
		Text = "",
		PlaceholderText = placeholder,
		ClearTextOnFocus = false,
		FontFace = UITheme.Fonts.Body,
		TextSize = UITheme.TextSize.Body,
		TextColor3 = C.Text,
		PlaceholderColor3 = C.TextDim,
		TextXAlignment = Enum.TextXAlignment.Left,
		BackgroundColor3 = C.PanelSunken,
		BackgroundTransparency = UITheme.SunkenTransparency,
		BorderSizePixel = 0,
		SelectionImageObject = Create.SelectionImage(),
	})
	for key, value in props do
		(box :: any)[key] = value
	end
	Create.Corner(box, UITheme.CornerSmall)
	Create.Stroke(box, C.Edge, 1, 0.3)
	Create.Padding(box, 0, UITheme.Padding.Small, 0)
	box:GetPropertyChangedSignal("Text"):Connect(function()
		if #box.Text > maxLength then
			box.Text = string.sub(box.Text, 1, maxLength)
		end
	end)
	return box
end

local function trim(text: string): string
	return (string.gsub(string.gsub(text, "%s+", " "), "^%s*(.-)%s*$", "%1"))
end

-- A grid of emblem buttons. Returns a function that marks one selected.
local function emblemGrid(parent: Instance, onPick: (number) -> ()): (number) -> ()
	local grid: Frame = Create.new("Frame", {
		Name = "Emblems",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 10,
		Parent = parent,
	})
	Create.new("UIGridLayout", {
		CellSize = UDim2.fromOffset(BUTTON_HEIGHT, BUTTON_HEIGHT),
		CellPadding = UDim2.fromOffset(6, 6),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = grid,
	})
	local strokes: { UIStroke } = {}
	for index = 1, K.Emblems do
		local button: TextButton = Create.new("TextButton", {
			Name = `Emblem{index}`,
			Text = "",
			AutoButtonColor = false,
			BackgroundColor3 = C.PanelSunken,
			BackgroundTransparency = UITheme.SunkenTransparency,
			BorderSizePixel = 0,
			LayoutOrder = index,
			SelectionImageObject = Create.SelectionImage(),
			Parent = grid,
		})
		Create.Corner(button, UITheme.CornerSmall)
		strokes[index] = Create.Stroke(button, C.Edge, 1.5, 0.4)
		Icons.new(CompanyController.EmblemIcon(index), {
			Size = UDim2.fromScale(0.7, 0.7),
			Position = UDim2.fromScale(0.5, 0.5),
			AnchorPoint = Vector2.new(0.5, 0.5),
			Color = C.Foam,
			Parent = button,
		})
		button.Activated:Connect(function()
			UISound.Play("UIClick")
			onPick(index)
		end)
	end
	return function(selected: number)
		for index, stroke in strokes do
			stroke.Color = if index == selected then C.Aqua else C.Edge
			stroke.Transparency = if index == selected then 0 else 0.4
			stroke.Thickness = if index == selected then 2.5 else 1.5
		end
	end
end

local function confirm(title: string, message: string, confirmText: string, danger: boolean, onYes: () -> ())
	UIController.Confirm({
		Title = title,
		Message = message,
		ConfirmText = confirmText,
		CancelText = S.Cancel,
		Danger = danger,
	}):andThen(function(yes: boolean): any
		if yes then
			onYes()
		end
		return nil
	end)
end

local function formatReset(resetsAt: number): string
	local left = math.max(0, resetsAt - now())
	if left >= 86400 then
		return Strings.Format(Strings.QuestUI.ResetDays, { days = math.floor(left / 86400), hours = math.floor(left % 86400 / 3600) })
	end
	return MathUtil.FormatDuration(left)
end

-- INVITE CARDS -------------------------------------------------------------------------------

local function closeCard(card: Card)
	local index = table.find(cards, card)
	if index then
		table.remove(cards, index)
	end
	card.Frame:Destroy()
end

local function forgetInvite(companyId: string)
	for index = #invites, 1, -1 do
		if invites[index].CompanyId == companyId then
			table.remove(invites, index)
		end
	end
	for _, card in table.clone(cards) do
		if card.CompanyId == companyId then
			closeCard(card)
		end
	end
end

local render: () -> ()

local function answer(companyId: string, accept: boolean)
	send(if accept then "Accept" else "Decline", companyId, 0)
	UISound.Play(if accept then "UIConfirm" else "UIClick")
	forgetInvite(companyId)
	render()
end

local function showCard(offer: InviteView)
	local frame: Frame = Create.new("Frame", {
		Name = "CompanyInvite",
		BackgroundColor3 = C.Panel,
		Size = UDim2.fromOffset(CARD_WIDTH, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = cardHolder,
	})
	Create.Corner(frame)
	Create.Stroke(frame, C.Parry, 1.5, 0.3)
	Create.Padding(frame, UITheme.Padding.Medium)
	Create.List(frame, Enum.FillDirection.Vertical, UITheme.Padding.Small)
	Create.Label({
		Text = S.InviteTitle,
		Font = UITheme.Fonts.Title,
		TextSize = UITheme.TextSize.Heading,
		Color = C.Parry,
		LayoutOrder = 1,
		Parent = frame,
	})
	Create.Label({
		Text = Strings.Format(S.InviteBody, { from = offer.From, name = offer.Name }),
		Wrapped = true,
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 2,
		Parent = frame,
	})
	local track: Frame = Create.new("Frame", {
		Name = "Time",
		BackgroundColor3 = C.PanelSunken,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 4),
		LayoutOrder = 3,
		Parent = frame,
	})
	local timer: Frame = Create.new("Frame", {
		Name = "Fill",
		BackgroundColor3 = C.Parry,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Parent = track,
	})
	local buttons: Frame = Create.new("Frame", {
		Name = "Buttons",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, BUTTON_HEIGHT),
		LayoutOrder = 4,
		Parent = frame,
	})
	Create.List(buttons, Enum.FillDirection.Horizontal, UITheme.Padding.Small, Enum.HorizontalAlignment.Center)
	Components.Button.new({
		Text = S.Accept,
		Variant = "Primary",
		Size = UDim2.new(0.5, -4, 0, BUTTON_HEIGHT),
		LayoutOrder = 1,
		Parent = buttons,
		OnActivated = function()
			answer(offer.CompanyId, true)
		end,
	})
	Components.Button.new({
		Text = S.Decline,
		Variant = "Secondary",
		Size = UDim2.new(0.5, -4, 0, BUTTON_HEIGHT),
		LayoutOrder = 2,
		Parent = buttons,
		OnActivated = function()
			answer(offer.CompanyId, false)
		end,
	})
	table.insert(cards, {
		Frame = frame,
		Timer = timer,
		CompanyId = offer.CompanyId,
		Expires = offer.ExpiresAt,
		Total = math.max(offer.ExpiresAt - now(), 1),
	})
	UISound.Play("UIToast")
end

local function onInvite(companyId: any, name: any, from: any, expiresAt: any)
	if type(companyId) ~= "string" or type(name) ~= "string" or type(from) ~= "string" or type(expiresAt) ~= "number" then
		return
	end
	if expiresAt <= now() then
		return
	end
	forgetInvite(companyId)
	local offer: InviteView = { CompanyId = companyId, Name = name, From = from, ExpiresAt = expiresAt }
	table.insert(invites, offer)
	if not (pageOpen and state == nil) then
		showCard(offer)
	end
	render()
end

-- PAGE: NO COMPANY ---------------------------------------------------------------------------

local function renderNone(p: Page)
	local data = DataController.GetData()
	local level = if data then data.Level else 0
	local gold = if data then data.Currencies.Gold else 0
	local unlocked = level >= K.UnlockLevel
	p.Locked.Visible = not unlocked
	p.Form.Visible = unlocked
	p.CreateButton:SetEnabled(unlocked and gold >= K.CreateCost)
	p.SetCreateEmblem(createEmblem)

	p.InviteList:Clear()
	local time = now()
	local shown = 0
	for _, offer in invites do
		if offer.ExpiresAt > time then
			shown += 1
			local row: Frame = Create.new("Frame", {
				Name = `Invite_{offer.CompanyId}`,
				BackgroundColor3 = C.PanelRaised,
				BackgroundTransparency = 0.3,
				Size = UDim2.new(1, -8, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				LayoutOrder = shown,
			})
			Create.Corner(row, UITheme.CornerSmall)
			Create.Padding(row, UITheme.Padding.Small)
			Create.List(row, Enum.FillDirection.Vertical, UITheme.Padding.Tiny)
			Create.Label({
				Text = Strings.Format(S.InviteBody, { from = offer.From, name = offer.Name }),
				Wrapped = true,
				AutomaticSize = Enum.AutomaticSize.Y,
				LayoutOrder = 1,
				Parent = row,
			})
			local buttons: Frame = Create.new("Frame", {
				BackgroundTransparency = 1,
				Size = UDim2.new(1, 0, 0, BUTTON_HEIGHT),
				LayoutOrder = 2,
				Parent = row,
			})
			Create.List(buttons, Enum.FillDirection.Horizontal, UITheme.Padding.Small)
			Components.Button.new({
				Text = S.Accept,
				Variant = "Primary",
				Size = UDim2.new(0.5, -4, 0, BUTTON_HEIGHT),
				Enabled = unlocked,
				LayoutOrder = 1,
				Parent = buttons,
				OnActivated = function()
					answer(offer.CompanyId, true)
				end,
			})
			Components.Button.new({
				Text = S.Decline,
				Variant = "Secondary",
				Size = UDim2.new(0.5, -4, 0, BUTTON_HEIGHT),
				LayoutOrder = 2,
				Parent = buttons,
				OnActivated = function()
					answer(offer.CompanyId, false)
				end,
			})
			p.InviteList:Add(row)
		end
	end
	if shown == 0 then
		p.InviteList:Add(Create.Label({
			Text = S.NoInvites,
			Color = C.TextDim,
			Wrapped = true,
			AutomaticSize = Enum.AutomaticSize.Y,
		}))
	end
end

-- PAGE: IN A COMPANY -------------------------------------------------------------------------

local function memberRow(p: Page, view: CompanyView, member: MemberView, order: number): Frame
	local row: Frame = Create.new("Frame", {
		Name = `Member_{member.UserId}`,
		BackgroundColor3 = C.PanelRaised,
		BackgroundTransparency = if member.UserId == localPlayer.UserId then 0.1 else 0.45,
		Size = UDim2.new(1, -8, 0, ROW),
		LayoutOrder = order,
	})
	Create.Corner(row, UITheme.CornerSmall)
	Create.Padding(row, 0, UITheme.Padding.Medium, 0)
	local dot: Frame = Create.new("Frame", {
		Name = "Online",
		BackgroundColor3 = if member.Online then C.Heal else C.TextDim,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.fromScale(0, 0.5),
		Size = UDim2.fromOffset(10, 10),
		Parent = row,
	})
	Create.Corner(dot, UDim.new(1, 0))
	Create.Label({
		Text = if member.UserId == localPlayer.UserId then Strings.Format(S.You, { name = member.Name }) else member.Name,
		Font = UITheme.Fonts.BodyBold,
		Position = UDim2.new(0, 20, 0, 6),
		Size = UDim2.new(0.4, -20, 0, 22),
		Parent = row,
	})
	Create.Label({
		Text = `{rankName(member.Rank)} · {if member.Online then S.Online else S.Offline}`,
		TextSize = UITheme.TextSize.Small,
		Color = if rankIndex(member.Rank) <= 2 then C.Parry else C.TextMuted,
		Position = UDim2.new(0, 20, 0, 28),
		Size = UDim2.new(0.4, -20, 0, 18),
		Parent = row,
	})
	local actions: Frame = Create.new("Frame", {
		Name = "Actions",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.fromScale(1, 0.5),
		Size = UDim2.new(0.6, 0, 0, 40),
		Parent = row,
	})
	Create.List(actions, Enum.FillDirection.Horizontal, UITheme.Padding.Small, Enum.HorizontalAlignment.Right, Enum.VerticalAlignment.Center)
	local target = tostring(member.UserId)
	if allowed(view, "Promote", member) then
		local handover = rankIndex(member.Rank) == 2
		p.RowMaid:Add(Components.Button.new({
			Text = S.Promote,
			Variant = "Secondary",
			Size = UDim2.fromOffset(104, 40),
			LayoutOrder = 1,
			Parent = actions,
			OnActivated = function()
				if handover then
					confirm(Strings.Format(S.LeaderConfirmTitle, { name = member.Name }), S.LeaderConfirmBody, S.Promote, true, function()
						send("Promote", target, 0)
					end)
				else
					send("Promote", target, 0)
				end
			end,
		}))
	end
	if allowed(view, "Demote", member) then
		p.RowMaid:Add(Components.Button.new({
			Text = S.Demote,
			Variant = "Secondary",
			Size = UDim2.fromOffset(104, 40),
			LayoutOrder = 2,
			Parent = actions,
			OnActivated = function()
				send("Demote", target, 0)
			end,
		}))
	end
	if allowed(view, "Kick", member) then
		p.RowMaid:Add(Components.Button.new({
			Text = S.Kick,
			Variant = "Danger",
			Size = UDim2.fromOffset(104, 40),
			LayoutOrder = 3,
			Parent = actions,
			OnActivated = function()
				confirm(Strings.Format(S.KickConfirmTitle, { name = member.Name }), S.KickConfirmBody, S.Kick, true, function()
					send("Kick", target, 0)
				end)
			end,
		}))
	end
	return row
end

local function renderMembers(p: Page, view: CompanyView)
	p.RowMaid:Clean()
	p.MemberList:Clear()
	p.InviteRow.Visible = view.Permissions.Invite == true
	for index, member in view.Members do
		p.MemberList:Add(memberRow(p, view, member, index))
	end
end

local function withdraw(item: ItemInstance)
	local view = state
	if not view or not view.Permissions.Withdraw then
		UISound.Play("UIError")
		return
	end
	if item.Count <= 1 then
		send("Withdraw", item.Uid, 0)
		return
	end
	Components.CountDialog.Show({
		Title = S.WithdrawCountTitle,
		Min = 1,
		Max = item.Count,
		Value = item.Count,
		ConfirmText = S.Withdraw,
	}):andThen(function(count: number?): any
		if count then
			send("Withdraw", item.Uid, count)
		end
		return nil
	end)
end

local function deposit(item: ItemInstance)
	if item.Count <= 1 then
		send("Deposit", item.Uid, 0)
		return
	end
	Components.CountDialog.Show({
		Title = S.DepositCountTitle,
		Min = 1,
		Max = item.Count,
		Value = item.Count,
		ConfirmText = S.Deposit,
	}):andThen(function(count: number?): any
		if count then
			send("Deposit", item.Uid, count)
		end
		return nil
	end)
end

local function attachTooltip(maid: Maid.Maid, target: GuiObject, item: ItemInstance)
	if Device.IsTouch() then
		return
	end
	maid:Add(Components.Tooltip.Attach(target, function(): Components.TooltipContent?
		return ItemText.Tooltip(item, DataController.GetData())
	end))
end

local function renderChest(p: Page, view: CompanyView)
	p.ChestMaid:Clean()
	p.ChestGrid:Clear()
	p.ChestCount.Text = Strings.Format(S.StorageCount, { used = #view.Storage, max = view.StorageSlots })
	p.ChestHint.Text = if #view.Storage == 0
		then S.StorageEmpty
		elseif view.Permissions.Withdraw then S.StorageHint
		else S.StorageNoWithdraw
	for index = 1, math.max(view.StorageSlots, #view.Storage) do
		local slot = Components.ItemSlot.new({ Size = SLOT, LayoutOrder = index })
		p.ChestMaid:Add(slot)
		local item = view.Storage[index]
		if item then
			local shown = chestCopy(item)
			slot:SetItem(ItemText.Slot(shown))
			slot.Activated:Connect(function()
				withdraw(item)
			end)
			attachTooltip(p.ChestMaid, slot.Instance, shown)
		end
		p.ChestGrid:Add(slot.Instance)
	end
end

local function renderBag(p: Page, view: CompanyView?)
	p.BagMaid:Clean()
	p.BagGrid:Clear()
	local data = DataController.GetData()
	if not data or not view then
		return
	end
	local list: { ItemInstance } = {}
	for _, item in data.Inventory.Items do
		if canStore(data, item) then
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
	p.BagHint.Text = if #list == 0 then S.BagEmpty else S.BagHint
	for index, item in list do
		local slot = Components.ItemSlot.new({ Size = SLOT, LayoutOrder = index })
		p.BagMaid:Add(slot)
		slot:SetItem(ItemText.Slot(item))
		slot.Activated:Connect(function()
			deposit(item)
		end)
		attachTooltip(p.BagMaid, slot.Instance, item)
		p.BagGrid:Add(slot.Instance)
	end
end

local function renderQuests(p: Page, view: CompanyView)
	p.QuestList:Clear()
	p.ResetLabel.Text = Strings.Format(S.QuestsReset, { time = formatReset(view.ResetsAt) })
	for index, quest in view.Quests do
		local text = S.Quests[quest.Id]
		local card: Frame = Create.new("Frame", {
			Name = quest.Id,
			BackgroundColor3 = C.PanelRaised,
			BackgroundTransparency = 0.3,
			Size = UDim2.new(1, -8, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			LayoutOrder = index,
		})
		Create.Corner(card, UITheme.CornerSmall)
		Create.Stroke(card, if quest.Done then C.Heal else C.Edge, 1, 0.3)
		Create.Padding(card, UITheme.Padding.Medium)
		Create.List(card, Enum.FillDirection.Vertical, UITheme.Padding.Tiny)
		Create.Label({
			Text = if text then text.Name else quest.Id,
			Font = UITheme.Fonts.BodyBold,
			TextSize = UITheme.TextSize.BodyLarge,
			Color = if quest.Done then C.Heal else C.Text,
			LayoutOrder = 1,
			Parent = card,
		})
		Create.Label({
			Text = if text then text.Summary else "",
			Color = C.TextMuted,
			Wrapped = true,
			AutomaticSize = Enum.AutomaticSize.Y,
			LayoutOrder = 2,
			Parent = card,
		})
		local bar = Components.ProgressBar.new({
			Color = if quest.Done then C.Heal else C.Current,
			Size = UDim2.new(1, 0, 0, 12),
			LayoutOrder = 3,
			Parent = card,
		})
		bar:SetValue(math.min(quest.Progress, quest.Count), quest.Count, true)
		Create.Label({
			Text = if quest.Done
				then S.QuestDone
				else Strings.Format(S.QuestProgress, { progress = math.min(quest.Progress, quest.Count), count = quest.Count }),
			Font = UITheme.Fonts.Numbers,
			TextSize = UITheme.TextSize.Small,
			Color = if quest.Done then C.Heal else C.Text,
			LayoutOrder = 4,
			Parent = card,
		})
		Create.Label({
			Text = Strings.Format(S.QuestReward, { gold = quest.Gold, shards = quest.Shards }),
			TextSize = UITheme.TextSize.Small,
			Color = C.Parry,
			LayoutOrder = 5,
			Parent = card,
		})
		p.QuestList:Add(card)
	end
end

local function renderInside(p: Page, view: CompanyView)
	Icons.Apply(p.Emblem, CompanyController.EmblemIcon(view.Emblem))
	p.Title.Text = view.Name
	p.Subtitle.Text = `{Strings.Format(S.MemberCount, { count = #view.Members, max = view.MaxMembers })}   {Strings.Format(
		S.YourRank,
		{ rank = rankName(view.MyRank) }
	)}`
	local leader = rankIndex(view.MyRank) == 1
	p.EmblemButton.Instance.Visible = view.Permissions.SetEmblem == true
	p.LeaveButton.Instance.Visible = not leader
	p.DisbandButton.Instance.Visible = view.Permissions.Disband == true
	p.SetOverlayEmblem(view.Emblem)
	renderMembers(p, view)
	renderChest(p, view)
	renderBag(p, view)
	renderQuests(p, view)
end

render = function()
	local p = page
	if not p then
		return
	end
	local view = state
	p.None.Visible = view == nil
	p.Inside.Visible = view ~= nil
	if view then
		renderInside(p, view)
	else
		p.EmblemOverlay.Visible = false
		renderNone(p)
	end
end

-- PAGE BUILD ---------------------------------------------------------------------------------

local function buildNone(content: Frame, maid: Maid.Maid): (Frame, { [string]: any })
	local none: Frame = Create.new("Frame", {
		Name = "None",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = content,
	})
	local createPanel = Components.Panel.new({
		Title = S.CreateHeader,
		Size = UDim2.new(0.6, -6, 1, 0),
		Parent = none,
	})
	maid:Add(createPanel)
	Create.List(createPanel.Content, Enum.FillDirection.Vertical, UITheme.Padding.Small)
	Create.Label({
		Text = S.NoneBody,
		Color = C.TextMuted,
		Wrapped = true,
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 1,
		Parent = createPanel.Content,
	})
	local locked = Create.Label({
		Text = Strings.Format(S.LockedBody, { level = K.UnlockLevel }),
		Color = C.Parry,
		Wrapped = true,
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 2,
		Parent = createPanel.Content,
	})
	local form: Frame = Create.new("Frame", {
		Name = "Form",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 3,
		Parent = createPanel.Content,
	})
	Create.List(form, Enum.FillDirection.Vertical, UITheme.Padding.Small)
	Create.Label({ Text = S.NameLabel, Font = UITheme.Fonts.BodyBold, Color = C.Accent, LayoutOrder = 1, Parent = form })
	local nameBox = textBox(Strings.Format(S.NamePlaceholder, { min = K.NameMin, max = K.NameMax }), K.NameMax + 4, {
		Size = UDim2.new(1, 0, 0, BUTTON_HEIGHT),
		LayoutOrder = 2,
		Parent = form,
	})
	Create.Label({ Text = S.EmblemLabel, Font = UITheme.Fonts.BodyBold, Color = C.Accent, LayoutOrder = 3, Parent = form })
	local setEmblem: (number) -> () = function(_: number) end
	setEmblem = emblemGrid(form, function(index: number)
		createEmblem = index
		setEmblem(index)
	end)
	local createButton = Components.Button.new({
		Text = Strings.Format(S.CreateButton, { cost = K.CreateCost }),
		Variant = "Primary",
		Size = UDim2.new(1, 0, 0, BUTTON_HEIGHT),
		LayoutOrder = 20,
		Parent = form,
	})
	maid:Add(createButton)
	createButton.Activated:Connect(function()
		local name = trim(nameBox.Text)
		if #name < K.NameMin or #name > K.NameMax then
			UISound.Play("UIError")
			UIController.Toast({ Title = S.Errors.NameLength, Color = C.Parry })
			return
		end
		confirm(
			Strings.Format(S.CreateConfirmTitle, { name = name }),
			Strings.Format(S.CreateConfirmBody, { cost = K.CreateCost }),
			Strings.Format(S.CreateButton, { cost = K.CreateCost }),
			false,
			function()
				send("Create", name, createEmblem)
			end
		)
	end)

	local invitePanel = Components.Panel.new({
		Title = S.InvitesHeader,
		Size = UDim2.new(0.4, -6, 1, 0),
		Position = UDim2.new(0.6, 6, 0, 0),
		Parent = none,
	})
	maid:Add(invitePanel)
	local inviteList = Components.ScrollList.new({ Size = UDim2.fromScale(1, 1), Spacing = UITheme.Padding.Small, Parent = invitePanel.Content })
	maid:Add(inviteList)

	return none,
		{
			Locked = locked,
			Form = form,
			NameBox = nameBox,
			CreateButton = createButton,
			SetCreateEmblem = setEmblem,
			InviteList = inviteList,
		}
end

local function buildPage(content: Frame, maid: Maid.Maid): UIController.MenuContent
	local none, noneRefs = buildNone(content, maid)

	local inside: Frame = Create.new("Frame", {
		Name = "Inside",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		Parent = content,
	})

	-- Header: emblem, name, members and rank, rank-gated buttons.
	local header: Frame = Create.new("Frame", {
		Name = "Header",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 60),
		Parent = inside,
	})
	local emblemBack: Frame = Create.new("Frame", {
		Name = "EmblemBack",
		BackgroundColor3 = C.PanelSunken,
		BackgroundTransparency = UITheme.SunkenTransparency,
		Size = UDim2.fromOffset(56, 56),
		Parent = header,
	})
	Create.Corner(emblemBack, UITheme.CornerSmall)
	Create.Stroke(emblemBack, C.Parry, 1.5, 0.2)
	local emblem = Icons.new("Guard", {
		Size = UDim2.fromScale(0.72, 0.72),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Color = C.Parry,
		Parent = emblemBack,
	})
	local title = Create.Label({
		Text = "",
		Font = UITheme.Fonts.Title,
		TextSize = UITheme.TextSize.Heading,
		Position = UDim2.fromOffset(68, 2),
		Size = UDim2.new(0.5, -68, 0, 28),
		Parent = header,
	})
	local subtitle = Create.Label({
		Text = "",
		TextSize = UITheme.TextSize.Small,
		Color = C.TextMuted,
		Position = UDim2.fromOffset(68, 32),
		Size = UDim2.new(0.5, -68, 0, 20),
		Parent = header,
	})
	local headerButtons: Frame = Create.new("Frame", {
		Name = "Buttons",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.new(0.5, 0, 0, BUTTON_HEIGHT),
		Parent = header,
	})
	Create.List(headerButtons, Enum.FillDirection.Horizontal, UITheme.Padding.Small, Enum.HorizontalAlignment.Right, Enum.VerticalAlignment.Center)
	local emblemButton = Components.Button.new({
		Text = S.ChangeEmblem,
		Variant = "Secondary",
		Size = UDim2.fromOffset(150, BUTTON_HEIGHT),
		LayoutOrder = 1,
		Parent = headerButtons,
	})
	local leaveButton = Components.Button.new({
		Text = S.Leave,
		Variant = "Secondary",
		Size = UDim2.fromOffset(110, BUTTON_HEIGHT),
		LayoutOrder = 2,
		Parent = headerButtons,
	})
	local disbandButton = Components.Button.new({
		Text = S.Disband,
		Variant = "Danger",
		Size = UDim2.fromOffset(110, BUTTON_HEIGHT),
		LayoutOrder = 3,
		Parent = headerButtons,
	})
	maid:Add(emblemButton)
	maid:Add(leaveButton)
	maid:Add(disbandButton)

	local tabs = Components.TabBar.new({
		Tabs = {
			{ Id = "Members", Text = S.TabMembers },
			{ Id = "Chest", Text = S.TabStorage },
			{ Id = "Weekly", Text = S.TabQuests },
		},
		Selected = "Members",
		Position = UDim2.fromOffset(0, 68),
		Parent = inside,
	})
	maid:Add(tabs)
	local top = 68 + UITheme.Size.TabHeight + UITheme.Padding.Small
	local pages: { [string]: Frame } = {}
	for _, id in { "Members", "Chest", "Weekly" } do
		pages[id] = Create.new("Frame", {
			Name = id,
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(0, top),
			Size = UDim2.new(1, 0, 1, -top),
			Visible = id == "Members",
			Parent = inside,
		})
	end
	maid:Add(tabs.Changed:Connect(function(id: string)
		for key, frame in pages do
			frame.Visible = key == id
		end
	end))

	-- Members: invite row and the list.
	local inviteRow: Frame = Create.new("Frame", {
		Name = "InviteRow",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, BUTTON_HEIGHT),
		Parent = pages.Members,
	})
	Create.List(inviteRow, Enum.FillDirection.Horizontal, UITheme.Padding.Small, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)
	local inviteBox = textBox(S.InvitePlaceholder, 48, {
		Size = UDim2.new(1, -150, 0, BUTTON_HEIGHT),
		LayoutOrder = 1,
		Parent = inviteRow,
	})
	local inviteButton = Components.Button.new({
		Text = S.InviteButton,
		Variant = "Primary",
		Size = UDim2.fromOffset(140, BUTTON_HEIGHT),
		LayoutOrder = 2,
		Parent = inviteRow,
	})
	maid:Add(inviteButton)
	local function sendInvite()
		local target = trim(inviteBox.Text)
		if target == "" then
			UISound.Play("UIError")
			return
		end
		send("Invite", target, 0)
		inviteBox.Text = ""
	end
	inviteButton.Activated:Connect(sendInvite)
	inviteBox.FocusLost:Connect(function(enterPressed: boolean)
		if enterPressed then
			sendInvite()
		end
	end)
	local memberList = Components.ScrollList.new({
		Position = UDim2.fromOffset(0, BUTTON_HEIGHT + UITheme.Padding.Small),
		Size = UDim2.new(1, 0, 1, -(BUTTON_HEIGHT + UITheme.Padding.Small)),
		Spacing = UITheme.Padding.Tiny,
		Parent = pages.Members,
	})
	maid:Add(memberList)

	-- Chest: the shared grid beside your bag.
	local chestPanel = Components.Panel.new({ Title = S.TabStorage, Size = UDim2.new(0.55, -6, 1, 0), Parent = pages.Chest })
	maid:Add(chestPanel)
	local chestCount = Create.Label({
		Text = "",
		Font = UITheme.Fonts.Numbers,
		TextSize = UITheme.TextSize.Small,
		Color = C.Accent,
		Size = UDim2.new(1, 0, 0, 18),
		Parent = chestPanel.Content,
	})
	local chestHint = Create.Label({
		Text = "",
		TextSize = UITheme.TextSize.Small,
		Color = C.TextDim,
		Position = UDim2.fromOffset(0, 20),
		Size = UDim2.new(1, 0, 0, 18),
		Parent = chestPanel.Content,
	})
	local gridOptions = { CellSize = UDim2.fromOffset(SLOT, SLOT), CellPadding = UDim2.fromOffset(6, 6) }
	local chestGrid = Components.ScrollList.new({
		Position = UDim2.fromOffset(0, 44),
		Size = UDim2.new(1, 0, 1, -44),
		Grid = gridOptions,
		Parent = chestPanel.Content,
	})
	maid:Add(chestGrid)
	local bagPanel = Components.Panel.new({
		Title = S.BagHeader,
		Size = UDim2.new(0.45, -6, 1, 0),
		Position = UDim2.new(0.55, 6, 0, 0),
		Parent = pages.Chest,
	})
	maid:Add(bagPanel)
	local bagHint = Create.Label({
		Text = "",
		TextSize = UITheme.TextSize.Small,
		Color = C.TextDim,
		Wrapped = true,
		Size = UDim2.new(1, 0, 0, 38),
		YAlignment = Enum.TextYAlignment.Top,
		Parent = bagPanel.Content,
	})
	local bagGrid = Components.ScrollList.new({
		Position = UDim2.fromOffset(0, 44),
		Size = UDim2.new(1, 0, 1, -44),
		Grid = gridOptions,
		Parent = bagPanel.Content,
	})
	maid:Add(bagGrid)

	-- Weekly quests.
	Create.Label({
		Text = S.QuestsHeader,
		Font = UITheme.Fonts.Title,
		TextSize = UITheme.TextSize.BodyLarge,
		Color = C.Accent,
		Size = UDim2.new(0.6, 0, 0, 24),
		Parent = pages.Weekly,
	})
	local resetLabel = Create.Label({
		Text = "",
		TextSize = UITheme.TextSize.Small,
		Color = C.TextMuted,
		XAlignment = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.new(0.4, 0, 0, 24),
		Parent = pages.Weekly,
	})
	Create.Label({
		Text = S.QuestsHint,
		TextSize = UITheme.TextSize.Small,
		Color = C.TextDim,
		Wrapped = true,
		Position = UDim2.fromOffset(0, 26),
		Size = UDim2.new(1, 0, 0, 36),
		YAlignment = Enum.TextYAlignment.Top,
		Parent = pages.Weekly,
	})
	local questList = Components.ScrollList.new({
		Position = UDim2.fromOffset(0, 66),
		Size = UDim2.new(1, 0, 1, -66),
		Spacing = UITheme.Padding.Small,
		Parent = pages.Weekly,
	})
	maid:Add(questList)

	-- Emblem picker over the page (Change Emblem).
	local overlay: Frame = Create.new("Frame", {
		Name = "EmblemOverlay",
		BackgroundColor3 = C.Overlay,
		BackgroundTransparency = 0.35,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		ZIndex = 20,
		Active = true,
		Parent = inside,
	})
	local overlayPanel = Components.Panel.new({
		Title = S.ChangeEmblem,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(8 * (BUTTON_HEIGHT + 6) + 40, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = overlay,
	})
	maid:Add(overlayPanel)
	Create.List(overlayPanel.Content, Enum.FillDirection.Vertical, UITheme.Padding.Medium, Enum.HorizontalAlignment.Center)
	local setOverlayEmblem = emblemGrid(overlayPanel.Content, function(index: number)
		overlay.Visible = false
		local view = state
		if view and view.Emblem ~= index then
			send("SetEmblem", "", index)
		end
	end)
	maid:Add(Components.Button.new({
		Text = S.Cancel,
		Variant = "Secondary",
		Size = UDim2.fromOffset(160, BUTTON_HEIGHT),
		LayoutOrder = 30,
		Parent = overlayPanel.Content,
		OnActivated = function()
			overlay.Visible = false
		end,
	}))

	emblemButton.Activated:Connect(function()
		overlay.Visible = true
	end)
	leaveButton.Activated:Connect(function()
		local view = state
		if view then
			confirm(Strings.Format(S.LeaveConfirmTitle, { name = view.Name }), S.LeaveConfirmBody, S.Leave, true, function()
				send("Leave", "", 0)
			end)
		end
	end)
	disbandButton.Activated:Connect(function()
		local view = state
		if view then
			confirm(Strings.Format(S.DisbandConfirmTitle, { name = view.Name }), S.DisbandConfirmBody, S.Disband, true, function()
				send("Disband", "", 0)
			end)
		end
	end)

	page = {
		None = none,
		Inside = inside,
		Locked = noneRefs.Locked,
		Form = noneRefs.Form,
		NameBox = noneRefs.NameBox,
		CreateButton = noneRefs.CreateButton,
		SetCreateEmblem = noneRefs.SetCreateEmblem,
		InviteList = noneRefs.InviteList,
		Emblem = emblem,
		Title = title,
		Subtitle = subtitle,
		EmblemButton = emblemButton,
		LeaveButton = leaveButton,
		DisbandButton = disbandButton,
		Tabs = tabs,
		Pages = pages,
		InviteRow = inviteRow,
		InviteBox = inviteBox,
		MemberList = memberList,
		ChestCount = chestCount,
		ChestHint = chestHint,
		ChestGrid = chestGrid,
		BagHint = bagHint,
		BagGrid = bagGrid,
		ResetLabel = resetLabel,
		QuestList = questList,
		EmblemOverlay = overlay,
		SetOverlayEmblem = setOverlayEmblem,
		RowMaid = maid:Add(Maid.new()),
		ChestMaid = maid:Add(Maid.new()),
		BagMaid = maid:Add(Maid.new()),
	}
	render()

	return {
		TabBar = tabs,
		OnOpen = function()
			pageOpen = true
			send("Refresh", "", 0)
			render()
		end,
		OnClose = function()
			pageOpen = false
			local p = page
			if p then
				p.EmblemOverlay.Visible = false
			end
		end,
	}
end

-- LIFECYCLE ----------------------------------------------------------------------------------

function CompanyController.Init()
	UIController.RegisterMenu({
		Id = MENU_ID,
		Title = S.Title,
		FullScreen = false,
		ShowInHub = true,
		Icon = "Keystone",
		Size = Vector2.new(940, 640),
		Build = buildPage,
	})
	Net.OnClient("CompanyState", function(payload: any)
		state = parseState(payload)
		render()
	end)
	Net.OnClient("CompanyInvite", onInvite)
end

function CompanyController.Start()
	cardHolder = Create.new("Frame", {
		Name = "CompanyInvites",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -16, 0, 160),
		Size = UDim2.fromOffset(CARD_WIDTH, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = Layers.Get("Overlay"),
	})
	Create.List(cardHolder, Enum.FillDirection.Vertical, UITheme.Padding.Small, Enum.HorizontalAlignment.Right)
	Animator.Add(function()
		if #cards == 0 then
			return
		end
		local time = now()
		for _, card in table.clone(cards) do
			local left = card.Expires - time
			if left <= 0 then
				closeCard(card)
			else
				card.Timer.Size = UDim2.fromScale(left / card.Total, 1)
			end
		end
	end)
	-- The bag, level and gold shown on the page follow your data while it's open.
	DataController.Observe({ "Inventory" }, function()
		local p = page
		if p and pageOpen then
			renderBag(p, state)
		end
	end)
	DataController.Observe({ "Equipped" }, function()
		local p = page
		if p and pageOpen then
			renderBag(p, state)
		end
	end)
	for _, path in { { "Level" }, { "Currencies", "Gold" } } do
		DataController.Observe(path, function()
			local p = page
			if p and pageOpen and state == nil then
				renderNone(p)
			end
		end)
	end
	-- The weekly reset timer ticks while the page is open.
	task.spawn(function()
		while true do
			task.wait(1)
			local p, view = page, state
			if p and view and pageOpen then
				p.ResetLabel.Text = Strings.Format(S.QuestsReset, { time = formatReset(view.ResetsAt) })
			end
		end
	end)
end

return CompanyController
