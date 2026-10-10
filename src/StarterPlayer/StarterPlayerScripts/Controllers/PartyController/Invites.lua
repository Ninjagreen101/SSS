--!strict
--[[
	Invites
	Party invites and Finder join requests (PartyInvite remote) as cards at the top centre of
	the screen: who, what, a draining time bar, and Accept / Decline buttons (at least
	Config.Input.MinTouchTarget px tall). A card closes when answered or when it expires; a newer
	invite from the same player replaces the old card.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Strings = require(Shared.Strings)
local Net = require(Shared.Net)

local UI = script.Parent.Parent.Parent.UI
local UITheme = require(UI.UITheme)
local Create = require(UI.Create)
local Layers = require(UI.Layers)
local Components = require(UI.Components)
local UISound = require(UI.UISound)
local Animator = require(UI.Animator)

local C = UITheme.Colors
local S = Strings.Party

local WIDTH = 340

type Card = {
	Frame: Frame,
	Timer: Frame,
	From: number,
	Expires: number,
	Total: number,
}

local Invites = {}

local holder: Frame
local cards: { Card } = {}

local function close(card: Card)
	local index = table.find(cards, card)
	if index then
		table.remove(cards, index)
	end
	card.Frame:Destroy()
end

local function answer(card: Card, accept: boolean)
	Net.FireServer("RequestParty", if accept then "Accept" else "Decline", tostring(card.From))
	UISound.Play(if accept then "UIConfirm" else "UIClick")
	close(card)
end

function Invites.Show(fromUserId: number, fromName: string, expiresAt: number, kind: string)
	for _, existing in table.clone(cards) do
		if existing.From == fromUserId then
			close(existing)
		end
	end
	local request = kind == "Request"
	local frame: Frame = Create.new("Frame", {
		Name = "PartyInvite",
		BackgroundColor3 = C.Panel,
		Size = UDim2.fromOffset(WIDTH, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = holder,
	})
	Create.Corner(frame)
	Create.Stroke(frame, C.Current, 1.5, 0.3)
	Create.Padding(frame, UITheme.Padding.Medium)
	Create.List(frame, Enum.FillDirection.Vertical, UITheme.Padding.Small)
	Create.Label({
		Text = if request then S.RequestTitle else S.InviteTitle,
		Font = UITheme.Fonts.Title,
		TextSize = UITheme.TextSize.Heading,
		Color = C.Current,
		LayoutOrder = 1,
		Parent = frame,
	})
	Create.Label({
		Text = Strings.Format(if request then S.RequestBody else S.InviteBody, { name = fromName }),
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
		BackgroundColor3 = C.Current,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Parent = track,
	})
	local buttons: Frame = Create.new("Frame", {
		Name = "Buttons",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, Config.Input.MinTouchTarget),
		LayoutOrder = 4,
		Parent = frame,
	})
	Create.List(buttons, Enum.FillDirection.Horizontal, UITheme.Padding.Small, Enum.HorizontalAlignment.Center)
	local card: Card = {
		Frame = frame,
		Timer = timer,
		From = fromUserId,
		Expires = expiresAt,
		Total = math.max(expiresAt - Workspace:GetServerTimeNow(), 1),
	}
	Components.Button.new({
		Text = S.Accept,
		Variant = "Primary",
		Size = UDim2.new(0.5, -4, 0, Config.Input.MinTouchTarget),
		LayoutOrder = 1,
		Parent = buttons,
		OnActivated = function()
			answer(card, true)
		end,
	})
	Components.Button.new({
		Text = S.Decline,
		Variant = "Secondary",
		Size = UDim2.new(0.5, -4, 0, Config.Input.MinTouchTarget),
		LayoutOrder = 2,
		Parent = buttons,
		OnActivated = function()
			answer(card, false)
		end,
	})
	table.insert(cards, card)
	UISound.Play("UIToast")
end

function Invites.Init()
	holder = Create.new("Frame", {
		Name = "PartyInvites",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 96),
		Size = UDim2.fromOffset(WIDTH, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = Layers.Get("Overlay"),
	})
	Create.List(holder, Enum.FillDirection.Vertical, UITheme.Padding.Small, Enum.HorizontalAlignment.Center)
	Animator.Add(function()
		if #cards == 0 then
			return
		end
		local time = Workspace:GetServerTimeNow()
		for _, card in table.clone(cards) do
			local left = card.Expires - time
			if left <= 0 then
				close(card)
			else
				card.Timer.Size = UDim2.fromScale(left / card.Total, 1)
			end
		end
	end)
end

return Invites
