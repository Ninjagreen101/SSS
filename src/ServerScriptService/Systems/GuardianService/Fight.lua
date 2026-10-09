--!strict
--[[
	Fight (GuardianService)
	Small helpers every part of a Guardian fight shares: who is still fighting, telling the party
	(GuardianEvent, Telegraph), steering and facing the Warden, building and landing its blows, and
	pushing the tide's state to the arena, the model's attributes and the clients.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Attributes)
local Enums = require(Shared.Enums)
local Guardians = require(Shared.Data.Guardians)
local Net = require(Shared.Net)

local CombatService = require(script.Parent.Parent.CombatService)
local Types = require(script.Parent.Types)
local Rules = require(script.Parent.Rules)
local Arena = require(script.Parent.Arena)

local A = Attributes.Names

local Fight = {}

function Fight.Now(): number
	return Workspace:GetServerTimeNow()
end

function Fight.Flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

-- A living character's root.
function Fight.RootOf(player: Player): BasePart?
	local character = player.Character
	if not character or player.Parent ~= Players then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if humanoid and humanoid.Health > 0 and root and root:IsA("BasePart") then
		return root
	end
	return nil
end

-- Members still fighting, with their roots (stable order: by UserId).
function Fight.Living(fight: Types.Fight): { { Player: Player, Root: BasePart } }
	local list = {}
	for player in fight.Members do
		local root = Fight.RootOf(player)
		if root then
			table.insert(list, { Player = player, Root = root })
		end
	end
	table.sort(list, function(a, b): boolean
		return a.Player.UserId < b.Player.UserId
	end)
	return list
end

function Fight.MemberList(fight: Types.Fight): { Player }
	local list = {}
	for player in fight.Members do
		if player.Parent == Players then
			table.insert(list, player)
		end
	end
	return list
end

-- Everyone who entered the fight and is still in the server.
function Fight.ParticipantList(fight: Types.Fight): { Player }
	local list = {}
	for player in fight.Participants do
		if player.Parent == Players then
			table.insert(list, player)
		end
	end
	return list
end

function Fight.Fire(fight: Types.Fight, kind: string, payload: { [string]: any })
	Net.FireList("GuardianEvent", Fight.MemberList(fight), kind, payload)
end

-- A ground telegraph for the party (shape, placement, sizes, seconds, flags: 1 = unparryable).
function Fight.Telegraph(fight: Types.Fight, shape: string, cframe: CFrame, a: number, b: number, duration: number, flags: number)
	Net.FireList("Telegraph", Fight.MemberList(fight), shape, cframe, a, b, duration, flags)
end

-- Where the Warden stands, on the arena floor.
function Fight.Feet(fight: Types.Fight): Vector3
	local root = fight.Root
	if not root then
		return fight.Arena.Origin.Position
	end
	return Arena.Ground(fight.Arena, root.Position)
end

function Fight.Look(fight: Types.Fight): Vector3
	local root = fight.Root
	local look = if root then Fight.Flat(root.CFrame.LookVector) else Vector3.new(0, 0, -1)
	return if look.Magnitude > 1e-3 then look.Unit else Vector3.new(0, 0, -1)
end

function Fight.SetMobState(fight: Types.Fight, state: Enums.MobState)
	local mob = fight.Mob
	if mob and not mob.Dead and mob.State ~= state then
		mob.State = state
		mob.Model:SetAttribute(A.MobState, state)
	end
end

-- Turn toward a point (nil: face where it walks).
function Fight.Face(fight: Types.Fight, point: Vector3?)
	local mob = fight.Mob
	if not mob or mob.Dead then
		return
	end
	if point then
		local look = Fight.Flat(point - mob.Root.Position)
		if look.Magnitude > 0.1 then
			mob.Humanoid.AutoRotate = false
			mob.Align.CFrame = CFrame.lookAt(Vector3.zero, look)
			mob.Align.Enabled = true
		end
	else
		mob.Humanoid.AutoRotate = true
		mob.Align.Enabled = false
	end
end

function Fight.Stop(fight: Types.Fight)
	local mob = fight.Mob
	if mob and not mob.Dead then
		mob.Humanoid:Move(Vector3.zero)
		mob.Humanoid:MoveTo(mob.Root.Position)
		mob.Humanoid.WalkSpeed = mob.Def.WalkSpeed
	end
end

-- Tells clients a blow is coming (MobBlow "slot;windup;serverTime;flag", MobController format).
function Fight.Announce(fight: Types.Fight, slot: string, windup: number, flag: number)
	local model = fight.Model
	if model then
		model:SetAttribute(A.MobBlow, string.format("%s;%.3f;%.3f;%d", slot, windup, Fight.Now(), flag))
	end
end

-- One blow of `move` (Kind "Npc": no crits; damage is the same whatever the party size).
function Fight.HitSpec(move: Guardians.GuardianMove, index: number, hitStun: number?): CombatService.HitSpec
	return {
		Damage = move.Damage,
		Posture = move.Posture,
		Kind = "Npc",
		Parryable = not Guardians.BlowUnparryable(move, index),
		Blockable = move.Blockable,
		HitStun = hitStun or move.HitStun,
		CritChance = 0,
		CritMultiplier = 1,
	}
end

-- Lands a blow on a member (dodge, parry and block are honoured by CombatService).
function Fight.Strike(fight: Types.Fight, player: Player, spec: CombatService.HitSpec, source: Vector3): CombatService.Outcome?
	local character = player.Character
	if not character or not fight.Members[player] then
		return nil
	end
	return CombatService.NpcHit(fight.Model, character, spec, source)
end

-- TIDE -----------------------------------------------------------------------------------------

-- The tide just turned (or the fight set it): arena, Pressure, posture taken, attributes, clients.
-- `seconds` is how long the water takes to move.
function Fight.TideChanged(fight: Types.Fight, seconds: number)
	local def = fight.Def
	local tide = fight.Tide
	local arena = fight.Arena
	Arena.SetWater(arena, Rules.WaterLevel(def, fight.Phase, tide.State), seconds)
	Arena.SetTideLines(arena, tide.State == "High", seconds)
	Arena.SetPressure(arena, Rules.TidePressure(def, fight.Phase, tide.State))
	local mob = fight.Mob
	if mob then
		mob.PostureTaken = Rules.PostureTaken(def, tide.State)
	end
	local model = fight.Model
	if model then
		model:SetAttribute(A.GuardianTide, tide.State)
		model:SetAttribute(A.GuardianTideEndsAt, tide.EndsAt)
		Fight.Fire(fight, "Tide", { Model = model, State = tide.State, EndsAt = tide.EndsAt, Warning = false })
	end
end

-- The tell before a change: the water starts moving so it arrives as the tide turns. The event
-- names the coming state and when it arrives (Warning = true).
function Fight.TideWarning(fight: Types.Fight)
	local def = fight.Def
	local tide = fight.Tide
	local coming: Rules.TideName = Rules.NextTide(tide.State)
	local seconds = math.max(0, tide.EndsAt - Fight.Now())
	Arena.SetWater(fight.Arena, Rules.WaterLevel(def, fight.Phase, coming), seconds)
	Arena.SetTideLines(fight.Arena, coming == "High", seconds)
	local model = fight.Model
	if model then
		model:SetAttribute(A.GuardianTideEndsAt, tide.EndsAt)
		Fight.Fire(fight, "Tide", { Model = model, State = coming, EndsAt = tide.EndsAt, Warning = true })
	end
end

return Fight
