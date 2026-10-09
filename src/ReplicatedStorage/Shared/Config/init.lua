--!strict
--[[
	Config
	Single source of truth for every balance and tuning number in The Spire.
	Systems read from here and never hard-code numbers. All tables are
	deep-frozen so nothing can change balance at runtime by accident.

	Usage: local Config = require(Shared.Config); Config.Combat.Stamina.Max
]]

local Combat = require(script.Combat)
local Current = require(script.Current)
local Mobs = require(script.Mobs)
local Items = require(script.Items)
local Loot = require(script.Loot)
local Progression = require(script.Progression)
local Economy = require(script.Economy)
local World = require(script.World)
local Camera = require(script.Camera)
local Input = require(script.Input)
local Net = require(script.Net)
local Data = require(script.Data)
local Assets = require(script.Assets)
local Environment = require(script.Environment)
local Dungeons = require(script.Dungeons)
local Quests = require(script.Quests)

export type DungeonDef = Dungeons.DungeonDef

local Config = {
	Combat = Combat,
	Current = Current,
	Mobs = Mobs,
	Items = Items,
	Loot = Loot,
	Progression = Progression,
	Economy = Economy,
	World = World,
	Camera = Camera,
	Input = Input,
	Net = Net,
	Data = Data,
	Assets = Assets,
	Environment = Environment,
	Dungeons = Dungeons,
	Quests = Quests,
}

return table.freeze(Config)
