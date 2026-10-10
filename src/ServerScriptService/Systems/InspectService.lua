--!strict
--[[
	InspectService (Phase 12)
	Two small social requests, both validated here and nothing else trusted from the client:

	- RequestInspect(userId): another player's equipped gear, level, Position and title, sent back as
	  InspectResult(userId, payload | nil). The target must be in this server and within
	  Config.Social.Inspect.MaxDistance of the asker, and each asker waits Cooldown between requests.
	  Gear is copied item by item (full instances, so the client can draw the usual tooltips) with the
	  bookkeeping fields blanked. nil means "can't inspect" (gone, too far, or yourself).
	- RequestSetEmoteSlot(slot, emoteId): puts an emote ("" = none) in one wheel slot. The id must exist
	  in Data/Emotes. If the emote already sits in another slot the two swap, so an emote is never on
	  the wheel twice. An empty saved wheel is first filled with the defaults, so the player's edit is
	  relative to what they were looking at. Saved in Data.Social.Emotes.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Attributes)
local Config = require(Shared.Config)
local Enums = require(Shared.Enums)
local Net = require(Shared.Net)
local Types = require(Shared.Types)
local Log = require(Shared.Util.Log)
local TableUtil = require(Shared.Util.TableUtil)
local Emotes = require(Shared.Data.Emotes)
local GearStats = require(Shared.Data.GearStats)

local DataService = require(script.Parent.DataService)

local A = Attributes.Names
local log = Log.new("InspectService")

type ItemInstance = Types.ItemInstance

local InspectService = {}

local lastInspect: { [Player]: number } = {}

-- A tooltip-ready copy of an equipped item: same stats, nothing that identifies the owner's bag.
local function snapshot(item: ItemInstance, slot: string): ItemInstance
	return {
		Uid = `inspect:{slot}`,
		DefId = item.DefId,
		Count = 1,
		Rarity = item.Rarity,
		Upgrade = item.Upgrade,
		Durability = item.Durability,
		Affixes = TableUtil.DeepCopy(item.Affixes),
		Locked = false,
		New = false,
		AcquiredAt = 0,
		Unique = item.Unique,
	}
end

local function rootOf(player: Player): BasePart?
	local character = player.Character
	return if character then character:FindFirstChild("HumanoidRootPart") :: BasePart? else nil
end

local function withinReach(asker: Player, target: Player): boolean
	local a, b = rootOf(asker), rootOf(target)
	if not a or not b then
		return false
	end
	return (a.Position - b.Position).Magnitude <= Config.Social.Inspect.MaxDistance
end

local function buildPayload(target: Player, data: Types.PlayerData): { [string]: any }
	local gear: { [string]: ItemInstance } = {}
	for _, slot in Enums.EquipSlot do
		local item = GearStats.EquippedItem(data, slot)
		if item then
			gear[slot] = snapshot(item, slot)
		end
	end
	local company = target:GetAttribute(A.CompanyName)
	local title = target:GetAttribute(A.Title)
	return {
		UserId = target.UserId,
		Name = target.Name,
		DisplayName = target.DisplayName,
		Level = data.Level,
		Position = data.Position,
		Title = if type(title) == "string" then title else "",
		Company = if type(company) == "string" then company else "",
		Gear = gear,
	}
end

local function onInspect(player: Player, userId: number)
	local now = os.clock()
	local last = lastInspect[player]
	if last and now - last < Config.Social.Inspect.Cooldown then
		return
	end
	lastInspect[player] = now

	local target = Players:GetPlayerByUserId(userId)
	if not target or target == player or not withinReach(player, target) then
		Net.Fire("InspectResult", player, userId, nil)
		return
	end
	local data = DataService.GetData(target)
	if not data then
		Net.Fire("InspectResult", player, userId, nil)
		return
	end
	Net.Fire("InspectResult", player, userId, buildPayload(target, data))
end

local function onSetEmoteSlot(player: Player, slot: number, emoteId: string)
	local data = DataService.GetData(player)
	if not data or not data.Social then
		return
	end
	if slot < 1 or slot > Config.Social.Emotes.Slots then
		return
	end
	if emoteId ~= "" and not Emotes.Get(emoteId) then
		return
	end
	local list = Emotes.Resolve(data.Social.Emotes)
	local previous = list[slot]
	if emoteId ~= "" then
		local at = table.find(list, emoteId)
		if at and at ~= slot then
			list[at] = previous
		end
	end
	list[slot] = emoteId
	local saved: { [string]: string } = {}
	for index, id in list do
		saved[tostring(index)] = id
	end
	DataService.Set(player, { "Social", "Emotes" }, saved)
end

function InspectService.Init()
	Net.On("RequestInspect", onInspect)
	Net.On("RequestSetEmoteSlot", onSetEmoteSlot)
end

function InspectService.Start()
	Players.PlayerRemoving:Connect(function(player: Player)
		lastInspect[player] = nil
	end)
	log:Debug("ready")
end

return InspectService
