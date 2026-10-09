--!strict
--[[
	Npcs
	Town characters (Phase 11; roster in docs/PHASE11_QUESTS.md section 3). NpcService builds each
	one at its marker (Workspace.Floor1.Npcs, attribute NpcId = the id); text lives in
	Strings.Npcs[<id>] = { Name, Role, Greetings = { lines }, Idle = { lines } }.

	Fields:
	  Floor      floor id
	  Look       body: skin / torso / arm / leg colours (an R15 HumanoidDescription like mobs), Scale,
	             and Extras (welded detail parts, same format as Shared.Data.Mobs BodyPart)
	  Behaviour  "Stand" (idle at the marker, turns to face nearby players), "Work" (idle at a task
	             spot), "Route" (walks the points in Workspace.Floor1.Npcs.Route_<id> in a loop,
	             pausing PauseSeconds at each)
	  PauseSeconds  Route only
	  Gives      quest ids this NPC offers (QuestService still checks each quest's Giver)
	  Voice      dialogue blip pitch (0.8 deep .. 1.3 high) for the typewriter "voice"
]]

local Mobs = require(script.Parent.Mobs)

export type Behaviour = "Stand" | "Work" | "Route"

export type NpcDef = {
	Floor: string,
	Look: {
		Scale: number,
		Skin: Color3,
		Torso: Color3,
		Arms: Color3,
		Legs: Color3,
		Extras: { Mobs.BodyPart },
	},
	Behaviour: Behaviour,
	PauseSeconds: number?,
	Gives: { string },
	Voice: number,
}

local Npcs: { [string]: NpcDef } = {}

local NpcsModule = {}

function NpcsModule.Get(id: string): NpcDef?
	return Npcs[id]
end

function NpcsModule.All(): { [string]: NpcDef }
	return Npcs
end

return table.freeze(NpcsModule)
