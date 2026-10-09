--!strict
--[[
	Spells
	The Current's spells (Spec Sections 6 and 8): every spell is an
	Attunement (the element) shaping a Form (what the spell does), so the 30
	spells come from two small tables. Spell ids are "<Attunement>_<Form>",
	e.g. "Tide_Bolt". Names are built from Strings.Attunements and
	Strings.Forms ("Tide Bolt").

	Forms
	  UnlockLevel  level at which an attuned Climber learns the Form
	  Cost         Current spent (Control lowers it)
	  Cooldown     seconds before it can be cast again
	  CastTime     seconds from pressing to the spell going off (Control
	               speeds it up; Burnout slows it down); a hit in that time
	               cancels the cast and refunds nothing
	  Recovery     seconds after release before you can act again
	  Damage / Posture   base values (Density scales them)
	  Shape fields per Form: Speed/Radius/Range (Bolt), Length/Width
	  (Lance), Reach/Arc (Wave), Shield/Duration (Ward), Radius/Duration/
	  TickInterval/Range (Well), Distance/IFrames/Radius (Step)
	  Animation    casting animation slot (Config.Assets.Animations.Casting);
	               FallbackAnimation is the sword clip used until it's uploaded
	  Reticle      what Aimed cast draws while the key is held: "Line",
	               "Cone", "Circle", "Arrow" or "Self" (casts on press)
	  Charge       (Lance) hold to charge: damage scales from MinMultiplier
	               to MaxMultiplier over Max seconds

	Attunements
	  Color        spell colour (bolts, beams, pools, blade glow); matches
	               UITheme.Colors (Spec Section 6 palette)
	  Status       status every hit applies (Config.Current.Status)
	  Detonates    a status that, if the target already has it, this
	               Attunement consumes for a Reaction (x ReactionDamageMultiplier)
	  Reaction     the Reaction's name (Strings.Combat.Reactions), e.g. "Shatter"
	  Heals        Ward and Well also heal you and allies (Renewing)
]]

local Enums = require(script.Parent.Parent.Enums)

export type Status = "Soaked" | "Chilled" | "Frozen" | "Shocked" | "Heavy" | "Rooted" | "Renewing"

export type Reticle = "Line" | "Cone" | "Circle" | "Arrow" | "Self"

export type ChargeDef = {
	Max: number,
	MinMultiplier: number,
	MaxMultiplier: number,
}

export type FormDef = {
	UnlockLevel: number,
	Cost: number,
	Cooldown: number,
	CastTime: number,
	Recovery: number,
	Damage: number,
	Posture: number,
	Animation: string,
	FallbackAnimation: string,
	Reticle: Reticle,
	Charge: ChargeDef?,
	Speed: number?,
	Radius: number?,
	Range: number?,
	Length: number?,
	Width: number?,
	Reach: number?,
	Arc: number?,
	Shield: number?,
	Duration: number?,
	TickInterval: number?,
	Distance: number?,
	IFrames: number?,
}

export type AttunementDef = {
	Color: Color3,
	Status: Status,
	Detonates: Status?,
	Reaction: string?,
	Heals: boolean,
}

export type SpellDef = {
	Id: string,
	Attunement: Enums.Attunement,
	Form: Enums.Form,
	Shape: FormDef,
	Element: AttunementDef,
}

local Forms: { [string]: FormDef } = {
	-- A fast bolt at whatever you aim at. Cheap, quick, single target.
	Bolt = {
		UnlockLevel = 8,
		Cost = 12,
		Cooldown = 1.2,
		CastTime = 0.25,
		Recovery = 0.2,
		Damage = 18,
		Posture = 8,
		Animation = "Cast1H",
		FallbackAnimation = "Light4",
		Reticle = "Line",
		Speed = 85,
		Radius = 1,
		Range = 90,
	},
	-- A cone of the element in front of you. Hits everything close.
	Wave = {
		UnlockLevel = 10,
		Cost = 18,
		Cooldown = 4,
		CastTime = 0.35,
		Recovery = 0.3,
		Damage = 16,
		Posture = 14,
		Animation = "Cast1H",
		FallbackAnimation = "Light5",
		Reticle = "Cone",
		Reach = 14,
		Arc = 100,
	},
	-- A shield that absorbs damage. Hitting a warded Climber marks the attacker.
	Ward = {
		UnlockLevel = 12,
		Cost = 20,
		Cooldown = 10,
		CastTime = 0.2,
		Recovery = 0.1,
		Damage = 0,
		Posture = 0,
		Animation = "Cast1H",
		FallbackAnimation = "Block",
		Reticle = "Self",
		Shield = 40,
		Duration = 5,
	},
	-- Hold to charge, release to fire an instant beam that pierces every
	-- enemy along it (walls stop it). CastTime is the release after the charge.
	Lance = {
		UnlockLevel = 15,
		Cost = 22,
		Cooldown = 5,
		CastTime = 0.15,
		Recovery = 0.3,
		Damage = 30,
		Posture = 20,
		Animation = "Cast2H",
		FallbackAnimation = "Heavy",
		Reticle = "Line",
		Charge = { Max = 1.2, MinMultiplier = 0.6, MaxMultiplier = 1.8 },
		Length = 45,
		Width = 2.5,
	},
	-- A pool at the aimed spot that pulses damage (or healing, for Bloom).
	Well = {
		UnlockLevel = 18,
		Cost = 26,
		Cooldown = 12,
		CastTime = 0.4,
		Recovery = 0.3,
		Damage = 7,
		Posture = 4,
		Animation = "Cast2H",
		FallbackAnimation = "Heavy",
		Reticle = "Circle",
		Radius = 9,
		Duration = 5,
		TickInterval = 1,
		Range = 60,
	},
	-- A blink-dash: brief invincibility, and a burst where you arrive.
	Step = {
		UnlockLevel = 22,
		Cost = 15,
		Cooldown = 6,
		CastTime = 0,
		Recovery = 0.15,
		Damage = 12,
		Posture = 10,
		Animation = "Dodge",
		FallbackAnimation = "Dodge",
		Reticle = "Arrow",
		Distance = 16,
		IFrames = 0.35,
		Radius = 6,
	},
}

local Attunements: { [string]: AttunementDef } = {
	-- Colours match UITheme.Colors (Spec Section 6: teal, ice white-blue,
	-- electric violet, deep indigo, soft green-gold).
	Tide = { Color = Color3.fromHex("#3FE0D0"), Status = "Soaked", Detonates = "Rooted", Reaction = "Crush", Heals = false },
	Rime = { Color = Color3.fromHex("#CFEFFF"), Status = "Chilled", Detonates = nil, Reaction = nil, Heals = false },
	Tempest = { Color = Color3.fromHex("#A274FF"), Status = "Shocked", Detonates = "Soaked", Reaction = "Surge", Heals = false },
	Abyss = { Color = Color3.fromHex("#5B4BD6"), Status = "Heavy", Detonates = "Chilled", Reaction = "Shatter", Heals = false },
	Bloom = { Color = Color3.fromHex("#C3E27A"), Status = "Rooted", Detonates = nil, Reaction = nil, Heals = true },
}

-- Freeze the shared definitions once; every spell points at them.
for _, shape in Forms do
	table.freeze(shape)
end
for _, element in Attunements do
	table.freeze(element)
end

local spells: { [string]: SpellDef } = {}
for attunementName, element in Attunements do
	for formName, shape in Forms do
		local id = `{attunementName}_{formName}`
		spells[id] = table.freeze({
			Id = id,
			Attunement = attunementName :: Enums.Attunement,
			Form = formName :: Enums.Form,
			Shape = shape,
			Element = element,
		})
	end
end

local Spells = {}

function Spells.Get(id: string): SpellDef?
	return spells[id]
end

function Spells.Id(attunement: string, form: string): string
	return `{attunement}_{form}`
end

function Spells.Form(form: string): FormDef?
	return Forms[form]
end

function Spells.Attunement(attunement: string): AttunementDef?
	return Attunements[attunement]
end

-- Forms in unlock order.
function Spells.FormsByLevel(): { string }
	local list = {}
	for name in Forms do
		table.insert(list, name)
	end
	table.sort(list, function(a: string, b: string): boolean
		return Forms[a].UnlockLevel < Forms[b].UnlockLevel
	end)
	return list
end

return table.freeze(Spells)
