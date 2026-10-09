--!strict
--[[
	GearEffectsService
	The unique named effects Legendary-and-above gear carries (Spec
	Section 11). Numbers live in Shared/Data/Affixes (Params), text in
	Strings.Inventory.Uniques.

	  Undertow       every Nth weapon hit on the same foe bursts around it
	  Brineward      a shield when health drops low (cooldown)
	  RiptideReflex  parries grant Resonance and refill Current
	  Lanternwake    a Perfect Dodge heals
	Deepglass (spell damage) lives in SpellService and Spireheart (Resonance
	hold) in CurrentService, where those numbers are computed.

	Effects listen to CombatService's HitLanded / Parried signals and ask
	GearService whether the player has the effect equipped.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Net = require(Shared.Net)
local Affixes = require(Shared.Data.Affixes)
local Spells = require(Shared.Data.Spells)

local GearService = require(script.Parent.GearService)
local CombatService = require(script.Parent.CombatService)
local VitalsService = require(script.Parent.VitalsService)
local CurrentService = require(script.Parent.CurrentService)
local TargetService = require(script.Parent.TargetService)

local GearEffectsService = {}

-- Undertow counters: attacker -> target -> hits.
local undertow: { [Player]: { [Model]: number } } = {}
-- Per-player cooldowns by effect id (server time ready).
local cooldowns: { [Player]: { [string]: number } } = {}

local function now(): number
	return Workspace:GetServerTimeNow()
end

local function params(id: string): { [string]: number }
	local def = Affixes.GetUnique(id)
	return if def then def.Params else {}
end

local function ready(player: Player, id: string, cooldown: number): boolean
	local list = cooldowns[player]
	if not list then
		list = {}
		cooldowns[player] = list
	end
	local t = now()
	if (list[id] or 0) > t then
		return false
	end
	list[id] = t + cooldown
	return true
end

local function playersNear(position: Vector3): { Player }
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

local function healthFraction(player: Player): number
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.MaxHealth <= 0 then
		return 1
	end
	return humanoid.Health / humanoid.MaxHealth
end

-- A tidal burst around `center` hitting every enemy within the radius.
local function undertowBurst(player: Player, attacker: Model, center: Vector3)
	local p = params("Undertow")
	local weaponDamage = CombatService.GetWeaponPower(player)
	local tide = Spells.Attunement("Tide")
	Net.FireList("SpellVisual", playersNear(center), attacker, "", "Burst", {
		Position = center,
		Radius = p.Radius,
		Color = if tide then tide.Color else Color3.fromHex("#3FE0D0"),
	})
	for model, target in TargetService.GetAll() do
		if target.Team ~= "Players" and TargetService.IsAlive(target) and TargetService.DistanceTo(target, center) <= p.Radius then
			CombatService.SpellHit(attacker, model, {
				Damage = weaponDamage * p.DamageFraction,
				Posture = 0,
				Kind = "Spell",
				Parryable = false,
				Blockable = true,
				HitStun = Config.Combat.HitStun.Light,
				CritChance = 0,
				CritMultiplier = 1,
				Element = "Tide",
			}, center)
		end
	end
end

local function onHitLanded(attacker: Model?, defender: Model, outcome: string, _amount: number, kind: string)
	-- Attacker effects (weapon blows that connected).
	local attackerPlayer = if attacker then Players:GetPlayerFromCharacter(attacker) else nil
	if attacker and attackerPlayer and CombatService.IsWeaponKind(kind) and (outcome == "Hit" or outcome == "Broken" or outcome == "GuardBreak" or outcome == "Riposte" or outcome == "Finisher") then
		if GearService.HasUnique(attackerPlayer, "Undertow") then
			local counts = undertow[attackerPlayer]
			if not counts then
				counts = {}
				undertow[attackerPlayer] = counts
			end
			local hits = (counts[defender] or 0) + 1
			if hits >= params("Undertow").Every then
				hits = 0
				local target = TargetService.Get(defender)
				if target then
					undertowBurst(attackerPlayer, attacker, target.Root.Position)
				end
			end
			counts[defender] = hits
			-- Forget foes that have despawned.
			for model in counts do
				if model.Parent == nil then
					counts[model] = nil
				end
			end
		end
	end

	-- Defender effects.
	local defenderPlayer = Players:GetPlayerFromCharacter(defender)
	if not defenderPlayer then
		return
	end
	if outcome == "PerfectDodge" and GearService.HasUnique(defenderPlayer, "Lanternwake") then
		local p = params("Lanternwake")
		if ready(defenderPlayer, "Lanternwake", p.Cooldown) then
			VitalsService.Heal(defenderPlayer, VitalsService.GetMaxHealth(defenderPlayer) * p.HealFraction)
		end
	end
	if GearService.HasUnique(defenderPlayer, "Brineward") then
		local p = params("Brineward")
		if healthFraction(defenderPlayer) < p.Threshold and ready(defenderPlayer, "Brineward", p.Cooldown) then
			VitalsService.SetShield(defenderPlayer, VitalsService.GetMaxHealth(defenderPlayer) * p.ShieldFraction, p.Duration)
		end
	end
end

local function onParried(parrier: Model, _attacker: Model?)
	local player = Players:GetPlayerFromCharacter(parrier)
	if player and GearService.HasUnique(player, "RiptideReflex") then
		local p = params("RiptideReflex")
		CurrentService.AddStacks(player, p.Stacks)
		VitalsService.AddCurrent(player, VitalsService.GetMaxCurrent(player) * p.CurrentFraction)
	end
end

function GearEffectsService.Start()
	CombatService.HitLanded:Connect(onHitLanded)
	CombatService.Parried:Connect(onParried)
	Players.PlayerRemoving:Connect(function(player: Player)
		undertow[player] = nil
		cooldowns[player] = nil
	end)
end

return GearEffectsService
