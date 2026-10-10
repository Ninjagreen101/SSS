--!strict
--[[
	PartyController
	The client side of parties (Phase 12, docs/PHASE12_MULTIPLAYER.md):
	- State: your party (PartyState) and the Finder board (FinderListings).
	- Menu: the Party menu (P, in the menu hub): members, invites, the Finder.
	- Frames: compact party frames at the bottom left.
	- Invites: Accept / Decline cards for party invites and Finder join requests.
	- Pings: G / the PING button to mark a spot for the party; received pings as world markers.
	Party members and pings also show on the minimap and the Map (MapController.SetExtraMarkers),
	and party chat: messages in your party's TextChannel get a teal prefix, and "/p <message>"
	sends to it.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Strings = require(Shared.Strings)
local Net = require(Shared.Net)
local Signal = require(Shared.Util.Signal)

local UI = script.Parent.Parent.UI
local UITheme = require(UI.UITheme)

local UIController = require(script.Parent.UIController)
local MapController = require(script.Parent.MapController)

local State = require(script.State)
local Menu = require(script.Menu)
local Frames = require(script.Frames)
local Invites = require(script.Invites)
local Pings = require(script.Pings)

local S = Strings.Party
local CHANNEL_WAIT = 10

local PartyController = {}

PartyController.MenuId = Menu.Id
-- Fires whenever your party changes (joined, left, members, leader, raid, loot mode).
PartyController.Changed = State.Changed :: Signal.Signal<>

function PartyController.GetParty(): State.Party?
	return State.Party
end

-- Invites a player to your party (the server checks every rule). Used by InspectController.
function PartyController.Invite(userId: number)
	Net.FireServer("RequestParty", "Invite", tostring(userId))
end

function PartyController.IsMember(userId: number): boolean
	return State.IsMember(userId)
end

-- PARTY CHAT ----------------------------------------------------------------------------------

local channel: TextChannel? = nil
local channelFor = ""

local function prefixIncoming(message: TextChatMessage): TextChatMessageProperties?
	local properties = Instance.new("TextChatMessageProperties")
	properties.PrefixText = `<font color="#{UITheme.Colors.Current:ToHex()}">{S.ChatPrefix}</font> {message.PrefixText}`
	return properties
end

local function hookChannel()
	local party = State.Party
	local id = if party then party.Id else ""
	if id == channelFor then
		return
	end
	channelFor = id
	channel = nil
	if id == "" then
		return
	end
	task.spawn(function()
		local root = TextChatService:WaitForChild("PartyChannels", CHANNEL_WAIT)
		local folder = root and root:WaitForChild(id, CHANNEL_WAIT)
		local found = folder and folder:WaitForChild("Party", CHANNEL_WAIT)
		if channelFor == id and found and found:IsA("TextChannel") then
			found.OnIncomingMessage = prefixIncoming
			channel = found
		end
	end)
end

local function stripAlias(text: string): string
	local rest = string.match(text, "^%s*/%S+%s+(.+)$")
	return rest or ""
end

-- "/p <message>" (or "/party") sends to your party's channel. Created on this client, so it
-- triggers here only; the server gates who can post (only members have a TextSource).
local function setUpChatCommand()
	pcall(function()
		local command = Instance.new("TextChatCommand")
		command.Name = "PartyChat"
		command.PrimaryAlias = S.ChatAlias
		command.SecondaryAlias = S.ChatAliasLong
		command.Parent = TextChatService
		command.Triggered:Connect(function(_source: TextSource, text: string)
			local target = channel
			local message = stripAlias(text)
			if target and message ~= "" then
				target:SendAsync(message)
			end
		end)
	end)
end

-- MAP MARKERS ---------------------------------------------------------------------------------

local function mapMarkers(): { MapController.ExtraMarker }
	local list: { MapController.ExtraMarker } = {}
	for _, other in State.Others() do
		local root = State.RootOf(other)
		if root then
			table.insert(list, { World = root.Position, Color = UITheme.Colors.Current, Size = 9 })
		end
	end
	for _, ping in Pings.Markers() do
		table.insert(list, ping)
	end
	return list
end

function PartyController.Init()
	UIController.RegisterMenu({
		Id = Menu.Id,
		Title = S.Title,
		Action = "OpenParty",
		FullScreen = false,
		ShowInHub = true,
		Icon = "Guard",
		Size = Vector2.new(780, 560),
		Build = Menu.Build,
	})
	Frames.Init()
	Invites.Init()
	Pings.Init()
	Net.OnClient("PartyState", function(payload: any)
		State.SetParty(payload)
		if not State.Party then
			Pings.Clear()
		end
	end)
	Net.OnClient("PartyInvite", function(fromUserId: any, fromName: any, expiresAt: any, kind: any)
		if type(fromUserId) == "number" and type(expiresAt) == "number" then
			Invites.Show(fromUserId, tostring(fromName), expiresAt, if kind == "Request" then "Request" else "Invite")
		end
	end)
	Net.OnClient("Ping", function(fromUserId: any, position: any, kind: any, expiresAt: any)
		if type(fromUserId) == "number" and State.Party then
			Pings.Show(fromUserId, position, tostring(kind), expiresAt)
		end
	end)
	Net.OnClient("FinderListings", function(listings: any)
		State.SetListings(listings)
	end)
	State.Changed:Connect(hookChannel)
end

function PartyController.Start()
	Frames.Start()
	setUpChatCommand()
	MapController.SetExtraMarkers("Party", mapMarkers)
end

return PartyController
