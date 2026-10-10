--!strict
--[[
	ArtService
	The Weapon Art button (Spec Sections 7 and 8), decided on the server:

	  Tap, Resonance below max   -> the equipped weapon's Weapon Art
	                                (Shared/Data/Arts): costs Current, own cooldown.
	  Tap, Resonance at max      -> Confluence (Shared/Data/Confluences) for the
	                                weapon class x primary Attunement: costs
	                                Confluence.CurrentCost, consumes every stack,
	                                Confluence.Invulnerability s of invincibility,
	                                hyper armour, Confluence.Cooldown s cooldown.
	                                Without an Attunement (or on cooldown) the tap
	                                is a Weapon Art instead.
	  Hold (Infusion.HoldTime)   -> Infusion: the blade carries the primary
	                                Attunement for Infusion.Duration s (CurrentService).

	Moves run through CombatService.BeginMove and the Runner (every blow is a
	normal CombatService hit). Cooldowns are mirrored to the player's
	ArtReadyAt / ConfluenceReadyAt attributes for the HUD. Rejections go back
	as ActionRejected("WeaponArt", reason).

	StartMove is also how PositionService casts Position abilities (Kind
	"Ability", rejections as ActionRejected("Ability", reason)).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Attributes = require(Shared.Attributes)
local Net = require(Shared.Net)
local Strings = require(Shared.Strings)
local Arts = require(Shared.Data.Arts)
local Confluences = require(Shared.Data.Confluences)
local Formulas = require(Shared.Data.Formulas)
local Moves = require(Shared.Data.Moves)

local Systems = script.Parent
local DataService = require(Systems.DataService)
local GearService = require(Systems.GearService)
local VitalsService = require(Systems.VitalsService)
local TargetService = require(Systems.TargetService)
local CombatService = require(Systems.CombatService)
local CurrentService = require(Systems.CurrentService)
local WeaponService = require(Systems.WeaponService)
local AnalyticsService = require(Systems.AnalyticsService)
local GameEvents = require(Systems.GameEvents)
local Runner = require(script.Runner)

local A = Attributes.Names
local CF = Config.Current.Confluence

local ArtService = {}

type Timers = { Art: number, Confluence: number }
local timers: { [Player]: Timers } = {}

local function now(): number
	return Workspace:GetServerTimeNow()
end

local function timersOf(player: Player): Timers
	local entry = timers[player]
	if not entry then
		entry = { Art = 0, Confluence = 0 }
		timers[player] = entry
	end
	return entry
end

local function reject(player: Player, reason: string, action: string?)
	Net.Fire("ActionRejected", player, action or "WeaponArt", reason)
end

local function flatAim(aim: Vector3, root: BasePart): Vector3
	local horizontal = Vector3.new(aim.X, 0, aim.Z)
	if horizontal.Magnitude < 0.1 then
		horizontal = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z)
	end
	return if horizontal.Magnitude > 0.01 then horizontal.Unit else Vector3.new(0, 0, -1)
end

local function audience(position: Vector3): { Player }
	local list = {}
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") and (root.Position - position).Magnitude <= Config.Combat.FeedbackRadius then
			table.insert(list, player)
		end
	end
	return list
end

local function primaryOf(player: Player): string?
	local data = DataService.GetData(player)
	local primary = data and data.Attunements.Primary
	return if primary and primary ~= "" then primary else nil
end

-- Starts a move for `player`. Returns false (and refunds) if they can't act.
local function start(
	player: Player,
	character: Model,
	root: BasePart,
	kind: "Art" | "Confluence" | "Ability",
	key: string,
	move: Moves.Move,
	aim: Vector3,
	power: number,
	element: string?,
	cost: number
): boolean
	local _, postureBase, critChance = CombatService.GetWeaponPower(player)
	local ctx: Runner.Context = {
		Player = player,
		Caster = character,
		Root = root,
		Key = key,
		Move = move,
		Kind = kind,
		Aim = aim,
		Anchor = root.Position,
		Power = power,
		PostureBase = postureBase,
		CritChance = critChance,
		Element = element,
		Hit = {},
		HitSet = {},
		Dealt = 0,
	}
	local action = if kind == "Ability" then "Ability" else "WeaponArt"
	if not VitalsService.SpendCurrent(player, cost) then
		reject(player, "Current", action)
		return false
	end
	local started = CombatService.BeginMove(character, move.Duration, move.HyperArmor, function()
		Runner.Run(ctx)
	end)
	if not started then
		VitalsService.AddCurrent(player, cost)
		reject(player, "Busy", action)
		return false
	end
	Net.FireList("MoveStart", audience(root.Position), character, kind, key, aim, element or "")
	VitalsService.MarkCombat(player)
	return true
end

local function onWeaponArt(player: Player, aimInput: Vector3)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not character or not root or not root:IsA("BasePart") or not humanoid or humanoid.Health <= 0 then
		return
	end
	local t = now()
	local tolerance = Config.Combat.HitValidation.TimingTolerance
	local entry = timersOf(player)
	local aim = flatAim(aimInput, root)
	local _, weapon = WeaponService.GetWeapon(player)
	local class = weapon.Class
	local weaponDamage = CombatService.GetWeaponPower(player)

	-- Confluence: full Resonance, attuned, off cooldown.
	local primary = primaryOf(player)
	local confluence = if primary then Confluences.Get(class, primary) else nil
	if
		confluence
		and CurrentService.GetStacks(player) >= Config.Current.Resonance.MaxStacks
		and entry.Confluence <= t + tolerance
	then
		-- Density (with gear) feeds the magic share; "+x% <element> damage" gear applies to the whole blow.
		local spellPower = Formulas.SpellPower(GearService.GetStats(player).Density)
		local power = weaponDamage
			* (1 - CF.DensityShare + CF.DensityShare * spellPower)
			* (1 + GearService.Bonus(player, `{primary}Damage`))
		if start(player, character, root, "Confluence", confluence.Id, confluence.Move, aim, power, primary, CF.CurrentCost) then
			CurrentService.ConsumeStacks(player)
			CombatService.GrantIFrames(character, CF.Invulnerability)
			entry.Confluence = t + CF.Cooldown
			player:SetAttribute(A.ConfluenceReadyAt, entry.Confluence)
			AnalyticsService.Custom(player, "Confluence")
			GameEvents.Fire(player, "Confluence", confluence.Id)
		end
		return
	end

	-- Weapon Art.
	local art = Arts.ForClass(class)
	if not art then
		return
	end
	if entry.Art > t + tolerance then
		reject(player, "Cooldown")
		return
	end
	if start(player, character, root, "Art", class, art.Move, aim, weaponDamage, CurrentService.GetInfusion(player), art.Cost) then
		entry.Art = t + art.Cooldown
		player:SetAttribute(A.ArtReadyAt, entry.Art)
	end
end

-- Starts any move for a living player (PositionService uses this for
-- abilities). Returns false, with the rejection already sent, if it can't.
function ArtService.StartMove(
	player: Player,
	kind: "Art" | "Confluence" | "Ability",
	key: string,
	move: Moves.Move,
	aimInput: Vector3,
	power: number,
	element: string?,
	cost: number
): boolean
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not character or not root or not root:IsA("BasePart") or not humanoid or humanoid.Health <= 0 then
		return false
	end
	return start(player, character, root, kind, key, move, flatAim(aimInput, root), power, element, cost)
end

local function onInfuse(player: Player)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not character or not humanoid or humanoid.Health <= 0 then
		return
	end
	local primary = primaryOf(player)
	if not primary then
		Net.Fire("Notify", player, "Toasts.NeedAttunement", {}, "Info")
		reject(player, "NotAttuned")
		return
	end
	local infusion = Config.Current.Infusion
	if not VitalsService.SpendCurrent(player, infusion.Cost) then
		reject(player, "Current")
		return
	end
	CurrentService.Infuse(player, primary, infusion.Duration)
	local name = Strings.Attunements[primary]
	Net.Fire("Notify", player, "Toasts.Infused", { name = if name then name.Name else primary }, "Success")
	VitalsService.MarkCombat(player)
	AnalyticsService.Custom(player, "Infusion")
end

-- A marked enemy (Frostbloom) shatters on the marker's next blow.
local function onHitLanded(attacker: Model?, defender: Model, outcome: string, _applied: number, kind: string)
	local player = if attacker then Players:GetPlayerFromCharacter(attacker) else nil
	if player and attacker and kind ~= "Confluence" and outcome ~= "Dodge" and outcome ~= "PerfectDodge" and outcome ~= "Parry" then
		Runner.ShatterMark(player, attacker, defender)
	end
end

function ArtService.Init()
	Net.On("RequestWeaponArt", onWeaponArt)
	Net.On("RequestInfuse", onInfuse)
end

function ArtService.Start()
	Runner.RefreshWallFilter()
	TargetService.Registered:Connect(Runner.RefreshWallFilter)
	TargetService.Removed:Connect(function(target: TargetService.Target)
		Runner.Forget(target.Model)
		task.defer(Runner.RefreshWallFilter)
	end)
	CombatService.HitLanded:Connect(onHitLanded)
	local function reset(player: Player)
		player:SetAttribute(A.ArtReadyAt, 0)
		player:SetAttribute(A.ConfluenceReadyAt, 0)
	end
	Players.PlayerAdded:Connect(reset)
	for _, player in Players:GetPlayers() do
		reset(player)
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		timers[player] = nil
	end)
end

return ArtService
