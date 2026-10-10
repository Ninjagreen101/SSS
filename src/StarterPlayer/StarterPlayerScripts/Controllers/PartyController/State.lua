--!strict
--[[
	State
	The client's copy of its party (PartyState) and the Finder board (FinderListings), plus the
	vitals helpers the party frames and the Party menu share. Server payloads are trusted
	(server-made); they are only shape-checked so a missing field can't break the UI.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Signal = require(Shared.Util.Signal)
local Attributes = require(Shared.Attributes)

local A = Attributes.Names
local localPlayer = Players.LocalPlayer

export type Member = { UserId: number, Name: string }

export type Party = {
	Id: string,
	Leader: number,
	Raid: boolean,
	LootMode: string,
	Capacity: number,
	Members: { Member },
}

export type Listing = {
	Id: string,
	Owner: number,
	OwnerName: string,
	Activity: string,
	Note: string,
	Members: number,
	Capacity: number,
	Expires: number,
}

export type Vitals = {
	Present: boolean, -- their character is streamed in
	Health: number,
	MaxHealth: number,
	Current: number,
	MaxCurrent: number,
	Level: number,
}

local State = {}

State.Party = nil :: Party?
State.Listings = {} :: { Listing }
State.Changed = Signal.new() :: Signal.Signal<>
State.ListingsChanged = Signal.new() :: Signal.Signal<>

function State.SetParty(payload: any)
	if type(payload) ~= "table" or type(payload.Members) ~= "table" then
		State.Party = nil
	else
		local members: { Member } = {}
		for _, entry in payload.Members do
			if type(entry) == "table" and type(entry.UserId) == "number" then
				table.insert(members, { UserId = entry.UserId, Name = tostring(entry.Name) })
			end
		end
		State.Party = {
			Id = tostring(payload.Id),
			Leader = tonumber(payload.Leader) or 0,
			Raid = payload.Raid == true,
			LootMode = tostring(payload.LootMode),
			Capacity = tonumber(payload.Capacity) or #members,
			Members = members,
		}
	end
	State.Changed:Fire()
end

function State.SetListings(payload: any)
	local list: { Listing } = {}
	if type(payload) == "table" then
		for _, entry in payload do
			if type(entry) == "table" and type(entry.Id) == "string" then
				table.insert(list, {
					Id = entry.Id,
					Owner = tonumber(entry.Owner) or 0,
					OwnerName = tostring(entry.OwnerName),
					Activity = tostring(entry.Activity),
					Note = tostring(entry.Note or ""),
					Members = tonumber(entry.Members) or 1,
					Capacity = tonumber(entry.Capacity) or 1,
					Expires = tonumber(entry.Expires) or 0,
				})
			end
		end
	end
	State.Listings = list
	State.ListingsChanged:Fire()
end

function State.IsLeader(): boolean
	local party = State.Party
	return party ~= nil and party.Leader == localPlayer.UserId
end

function State.IsMember(userId: number): boolean
	local party = State.Party
	if not party then
		return false
	end
	for _, member in party.Members do
		if member.UserId == userId then
			return true
		end
	end
	return false
end

-- Party members in this server other than you, in party order.
function State.Others(): { Player }
	local list = {}
	local party = State.Party
	if party then
		for _, member in party.Members do
			local other = Players:GetPlayerByUserId(member.UserId)
			if other and other ~= localPlayer then
				table.insert(list, other)
			end
		end
	end
	return list
end

function State.RootOf(player: Player): BasePart?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

function State.Vitals(player: Player): Vitals
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local current = player:GetAttribute(A.Current)
	local maxCurrent = player:GetAttribute(A.MaxCurrent)
	local level = player:GetAttribute(A.Level)
	return {
		Present = humanoid ~= nil,
		Health = if humanoid then humanoid.Health else 0,
		MaxHealth = if humanoid then humanoid.MaxHealth else 1,
		Current = if type(current) == "number" then current else 0,
		MaxCurrent = if type(maxCurrent) == "number" and maxCurrent > 0 then maxCurrent else 1,
		Level = if type(level) == "number" then level else 1,
	}
end

return State
