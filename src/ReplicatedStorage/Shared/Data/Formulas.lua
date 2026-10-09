--!strict
--[[
	Formulas
	Pure functions that turn level, stats and gear into derived numbers.
	Shared so the HUD can preview exactly what the server will compute.
	Every constant comes from Config; nothing here is a magic number.
]]

local Shared = script.Parent.Parent
local Config = require(Shared.Config)

local Formulas = {}

-- Applies the stat soft caps (Spec Section 9): points past each threshold
-- count for less, so hybrid builds stay viable.
function Formulas.EffectivePoints(points: number): number
	local caps = Config.Progression.SoftCaps
	local remaining = math.max(0, points)
	local previousThreshold = 0
	local previousMultiplier = 1
	local total = 0
	for _, cap in caps do
		local band = math.min(remaining, cap.Threshold - previousThreshold)
		total += band * previousMultiplier
		remaining -= band
		previousThreshold = cap.Threshold
		previousMultiplier = cap.Multiplier
		if remaining <= 0 then
			return total
		end
	end
	return total + remaining * previousMultiplier
end

function Formulas.MaxHealth(level: number, vitality: number, gearBonus: number?): number
	local base = Config.Combat.Health.Base + Config.Combat.Health.PerLevel * (level - 1)
	local fromStat = Config.Progression.Stats.Vitality.HealthPerPoint * Formulas.EffectivePoints(vitality)
	return math.floor(base + fromStat + (gearBonus or 0))
end

-- Damage reduction from Vitality: +1% per 5 effective points.
function Formulas.VitalityReduction(vitality: number): number
	return Config.Progression.Stats.Vitality.DamageReductionPerFivePoints * (Formulas.EffectivePoints(vitality) / 5)
end

function Formulas.MaxStamina(endurance: number, gearBonus: number?): number
	local fromStat = Config.Progression.Stats.Endurance.StaminaPerPoint * Formulas.EffectivePoints(endurance)
	return math.floor(Config.Combat.Stamina.Max + fromStat + (gearBonus or 0))
end

function Formulas.StaminaRegen(endurance: number): number
	return Config.Combat.Stamina.RegenPerSecond
		+ Config.Progression.Stats.Endurance.StaminaRegenPerPoint * Formulas.EffectivePoints(endurance)
end

-- The Vessel: base 100, +2 per level, +3 per Draw point (Spec Section 6).
function Formulas.MaxCurrent(level: number, draw: number, gearBonus: number?): number
	local vessel = Config.Current.Vessel
	return math.floor(
		vessel.Base + vessel.PerLevel * (level - 1) + vessel.PerDrawPoint * Formulas.EffectivePoints(draw) + (gearBonus or 0)
	)
end

function Formulas.CurrentRegen(draw: number): number
	local regen = Config.Current.Regen
	return regen.BasePerSecond * (1 + regen.DrawScalingPerPoint * Formulas.EffectivePoints(draw))
end

-- WEAPONS -------------------------------------------------------------------
-- `scaling` weights come from the weapon definition (Shared.Data.Items).

-- Damage multiplier from Strength and Finesse for a weapon's scaling weights.
function Formulas.WeaponScaling(strength: number, finesse: number, scaling: { Strength: number, Finesse: number }): number
	local stats = Config.Progression.Stats
	return 1
		+ stats.Strength.ScalingPerPoint * Formulas.EffectivePoints(strength) * scaling.Strength
		+ stats.Finesse.ScalingPerPoint * Formulas.EffectivePoints(finesse) * scaling.Finesse
end

function Formulas.PostureScaling(strength: number): number
	return 1 + Config.Progression.Stats.Strength.PosturePerPoint * Formulas.EffectivePoints(strength)
end

function Formulas.CritChance(finesse: number): number
	return Config.Combat.Damage.BaseCritChance
		+ Config.Progression.Stats.Finesse.CritChancePerPoint * Formulas.EffectivePoints(finesse)
end

-- Swing speed multiplier (1 = class base speed).
function Formulas.AttackSpeed(classSpeed: number, finesse: number): number
	return classSpeed * (1 + Config.Progression.Stats.Finesse.AttackSpeedPerPoint * Formulas.EffectivePoints(finesse))
end

-- Light combo multiplier for hit `index` (1-based; clamps to the table).
function Formulas.ComboMultiplier(index: number): number
	local list = Config.Combat.Damage.ComboMultipliers
	return list[math.clamp(index, 1, #list)]
end

-- Fraction of incoming damage a defender ignores (stats + armour), capped.
function Formulas.DamageReduction(vitality: number, armourReduction: number?): number
	return math.min(Config.Combat.Damage.DefenseCap, Formulas.VitalityReduction(vitality) + (armourReduction or 0))
end

-- SPELLS (Density and Control) ------------------------------------------------

-- Spell damage multiplier from Density.
function Formulas.SpellPower(density: number): number
	return 1 + Config.Progression.Stats.Density.SpellDamagePerPoint * Formulas.EffectivePoints(density)
end

-- Ward shield multiplier from Density.
function Formulas.ShieldPower(density: number): number
	return 1 + Config.Progression.Stats.Density.ShieldPerPoint * Formulas.EffectivePoints(density)
end

-- Spell posture damage multiplier from Density.
function Formulas.SpellPosture(density: number): number
	return 1 + Config.Progression.Stats.Density.SpellPosturePerPoint * Formulas.EffectivePoints(density)
end

-- Cast time multiplier from Control (smaller = faster).
function Formulas.CastTime(control: number): number
	return 1 / (1 + Config.Progression.Stats.Control.CastSpeedPerPoint * Formulas.EffectivePoints(control))
end

-- Area multiplier (radius) from Control.
function Formulas.SpellArea(control: number): number
	return 1 + Config.Progression.Stats.Control.AreaPerPoint * Formulas.EffectivePoints(control)
end

-- Siphon (Current per weapon hit) multiplier from Draw.
function Formulas.SiphonPower(draw: number): number
	return 1 + Config.Progression.Stats.Draw.SiphonPerPoint * Formulas.EffectivePoints(draw)
end

-- Beacon slots from Control: StartSlots, plus one at each Control threshold.
function Formulas.BeaconSlots(control: number): number
	local beacons = Config.Current.Beacons
	local slots = beacons.StartSlots
	for _, threshold in beacons.ControlThresholds do
		if control >= threshold then
			slots += 1
		end
	end
	return math.min(slots, beacons.MaxSlots)
end

-- Current cost multiplier from Control.
function Formulas.SpellCost(control: number): number
	return math.max(0.5, 1 - Config.Progression.Stats.Control.CostReductionPerPoint * Formulas.EffectivePoints(control))
end

-- XP needed to go from `level` to `level + 1`.
function Formulas.XPToNext(level: number): number
	return math.floor(Config.Progression.XP.Base * level ^ Config.Progression.XP.Exponent)
end

return table.freeze(Formulas)
