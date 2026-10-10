--!strict
--[[
	Emotes
	Every emote the wheel can play (Phase 12; design in docs/PHASE12_MULTIPLAYER.md). Pure data,
	shared: the server checks emote ids against it, the client plays and lists them.

	All twelve use Roblox's own default R15 character animations (the ids the stock Animate script
	loads: wave, point, cheer, laugh and the three dance sets), so they are free to play on any
	character. Animation ids are "rbxassetid://<number>".

	Fields: Id, Key (Strings.Emotes.Names[Key]), Animation, Looped (plays until cancelled),
	Category (Strings.Emotes.Categories[Category]).

	The wheel has Config.Social.Emotes.Slots slots. Saved slots live in Data.Social.Emotes as
	{ ["1"] = id, ... }; an empty table means "use the first emotes in order" (Resolve).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)

export type EmoteDef = {
	Id: string,
	Key: string,
	Animation: string,
	Looped: boolean,
	Category: string,
}

local function emote(id: string, animation: number, looped: boolean, category: string): EmoteDef
	return {
		Id = id,
		Key = id,
		Animation = `rbxassetid://{animation}`,
		Looped = looped,
		Category = category,
	}
end

local ORDERED: { EmoteDef } = {
	emote("Wave", 507770239, false, "Greeting"),
	emote("Point", 507770453, false, "Greeting"),
	emote("Cheer", 507770677, false, "Joy"),
	emote("Laugh", 507770818, false, "Joy"),
	emote("ShoreSway", 507771019, true, "Dance"),
	emote("TideStep", 507771955, true, "Dance"),
	emote("LanternSpin", 507776043, true, "Dance"),
	emote("HarborJig", 507776720, true, "Dance"),
	emote("WakeShuffle", 507776879, true, "Dance"),
	emote("BrineStrut", 507777268, true, "Dance"),
	emote("CurrentFlow", 507777451, true, "Dance"),
	emote("SpireStomp", 507777623, true, "Dance"),
}

local BY_ID: { [string]: EmoteDef } = {}
for _, def in ORDERED do
	BY_ID[def.Id] = def
end

local Emotes = {}

function Emotes.Ordered(): { EmoteDef }
	return ORDERED
end

function Emotes.Get(id: string): EmoteDef?
	return BY_ID[id]
end

-- The slot list with every slot filled in: `saved` ("1".."N" -> emote id, "" = empty) when the
-- player has saved anything, otherwise the first N emotes in order. Unknown ids read as empty.
function Emotes.Resolve(saved: { [string]: string }?): { string }
	local slots: number = Config.Social.Emotes.Slots
	local out: { string } = {}
	if saved == nil or next(saved) == nil then
		for index = 1, slots do
			out[index] = if ORDERED[index] then ORDERED[index].Id else ""
		end
		return out
	end
	for index = 1, slots do
		local id = saved[tostring(index)]
		out[index] = if type(id) == "string" and BY_ID[id] then id else ""
	end
	return out
end

return table.freeze(Emotes)
