--!strict
--[[
	Icons
	The game's icon set and water-effect textures. Both live on two uploaded
	sprite sheets (Config.Assets.UI): white shapes on transparency, tinted in
	game with ImageColor3, so one icon serves every state (default, hover,
	selected, disabled) by colour and transparency alone.

	Icons: 96 px cells on a 1024 px sheet, drawn from game-icons.net
	(CC BY 3.0, credited in the menu hub), plus a few plain geometric glyphs
	(Close, Plus, Minus, chevrons) drawn to the same weight.
	Effects: glow, ripple ring, vortex swirl, wave strip, frame corner, light
	ray, particle, bubble, sparkle, nebula, panel shadow and a right triangle
	(used to fill polygons such as the stat radar).

	Helpers map game ids to icons: stats, equipment slots, bonus ids (skill
	tree nodes, gear bonuses), abilities, Positions and Attunements.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared").Config)
local Create = require(script.Parent.Create)

local CELL = 96

-- Top-left of each icon's cell on the icon sheet.
local ICONS: { [string]: Vector2 } = {
	Character = Vector2.new(0, 0),
	Inventory = Vector2.new(96, 0),
	Quests = Vector2.new(192, 0),
	Current = Vector2.new(288, 0),
	SkillTree = Vector2.new(384, 0),
	Close = Vector2.new(480, 0),
	Plus = Vector2.new(576, 0),
	Minus = Vector2.new(672, 0),
	Lock = Vector2.new(768, 0),
	Check = Vector2.new(864, 0),
	Reset = Vector2.new(0, 96),
	Info = Vector2.new(96, 96),
	Level = Vector2.new(192, 96),
	Gold = Vector2.new(288, 96),
	Time = Vector2.new(384, 96),
	SkillPoint = Vector2.new(480, 96),
	StatPoint = Vector2.new(576, 96),
	Recenter = Vector2.new(672, 96),
	Weapon = Vector2.new(768, 96),
	Head = Vector2.new(864, 96),
	Chest = Vector2.new(0, 192),
	Legs = Vector2.new(96, 192),
	Hands = Vector2.new(192, 192),
	Cloak = Vector2.new(288, 192),
	Ring = Vector2.new(384, 192),
	Amulet = Vector2.new(480, 192),
	BeaconCore = Vector2.new(576, 192),
	Vitality = Vector2.new(672, 192),
	Endurance = Vector2.new(768, 192),
	Strength = Vector2.new(864, 192),
	Finesse = Vector2.new(0, 288),
	Draw = Vector2.new(96, 288),
	Density = Vector2.new(192, 288),
	Control = Vector2.new(288, 288),
	Health = Vector2.new(384, 288),
	CurrentDrop = Vector2.new(480, 288),
	Stamina = Vector2.new(576, 288),
	Armor = Vector2.new(672, 288),
	Crit = Vector2.new(768, 288),
	Damage = Vector2.new(864, 288),
	SpellPower = Vector2.new(0, 384),
	Speed = Vector2.new(96, 384),
	Dodge = Vector2.new(192, 384),
	Heal = Vector2.new(288, 384),
	Guard = Vector2.new(384, 384),
	CritDamage = Vector2.new(480, 384),
	SpellArea = Vector2.new(576, 384),
	CastSpeed = Vector2.new(672, 384),
	Reaction = Vector2.new(768, 384),
	AbilityPower = Vector2.new(864, 384),
	Execute = Vector2.new(0, 480),
	Threat = Vector2.new(96, 480),
	Posture = Vector2.new(192, 480),
	Riposte = Vector2.new(288, 480),
	Siphon = Vector2.new(384, 480),
	Loot = Vector2.new(480, 480),
	Mark = Vector2.new(576, 480),
	Overflow = Vector2.new(672, 480),
	Resonance = Vector2.new(768, 480),
	Beacon = Vector2.new(864, 480),
	Seawall = Vector2.new(0, 576),
	HarborBell = Vector2.new(96, 576),
	Keelbreaker = Vector2.new(192, 576),
	Glintstorm = Vector2.new(288, 576),
	RiptideLunge = Vector2.new(384, 576),
	Severance = Vector2.new(480, 576),
	Floodtide = Vector2.new(576, 576),
	Maelstrom = Vector2.new(672, 576),
	CatalystPulse = Vector2.new(768, 576),
	Kindle = Vector2.new(864, 576),
	Tidewell = Vector2.new(0, 672),
	GuidingLantern = Vector2.new(96, 672),
	Windstep = Vector2.new(192, 672),
	Tanglewire = Vector2.new(288, 672),
	ExposeWeakness = Vector2.new(384, 672),
	Vanguard = Vector2.new(480, 672),
	Lancer = Vector2.new(576, 672),
	Tidecaller = Vector2.new(672, 672),
	Beaconkeeper = Vector2.new(864, 480),
	Pathfinder = Vector2.new(768, 672),
	Tide = Vector2.new(672, 480),
	Rime = Vector2.new(864, 672),
	Tempest = Vector2.new(0, 768),
	Abyss = Vector2.new(96, 768),
	Bloom = Vector2.new(192, 768),
	Kills = Vector2.new(864, 288),
	Keystone = Vector2.new(288, 768),
	Search = Vector2.new(384, 768),
	ChevronLeft = Vector2.new(480, 768),
	ChevronRight = Vector2.new(576, 768),
	Weight = Vector2.new(672, 768),
	Shards = Vector2.new(768, 768),
	Tokens = Vector2.new(864, 768),
	XP = Vector2.new(0, 864),
	Deaths = Vector2.new(96, 864),
	Rotate = Vector2.new(192, 864),
	Arts = Vector2.new(288, 864),
	Settings = Vector2.new(384, 864),
}

export type FxRect = { Offset: Vector2, Size: Vector2 }

local FX: { [string]: FxRect } = {
	Glow = { Offset = Vector2.new(0, 256), Size = Vector2.new(128, 128) },
	Ring = { Offset = Vector2.new(256, 0), Size = Vector2.new(256, 256) },
	Swirl = { Offset = Vector2.new(0, 0), Size = Vector2.new(256, 256) },
	Nebula = { Offset = Vector2.new(128, 256), Size = Vector2.new(128, 128) },
	Triangle = { Offset = Vector2.new(256, 256), Size = Vector2.new(128, 128) },
	Corner = { Offset = Vector2.new(384, 256), Size = Vector2.new(128, 128) },
	Wave = { Offset = Vector2.new(0, 384), Size = Vector2.new(384, 48) },
	Ray = { Offset = Vector2.new(0, 432), Size = Vector2.new(256, 32) },
	Dot = { Offset = Vector2.new(256, 432), Size = Vector2.new(32, 32) },
	Shadow = { Offset = Vector2.new(384, 384), Size = Vector2.new(128, 128) },
	Bubble = { Offset = Vector2.new(288, 432), Size = Vector2.new(32, 32) },
	Sparkle = { Offset = Vector2.new(320, 432), Size = Vector2.new(64, 64) },
}

-- Game ids -> icon names.
local STAT_ICONS: { [string]: string } = {
	Vitality = "Vitality",
	Endurance = "Endurance",
	Strength = "Strength",
	Finesse = "Finesse",
	Draw = "Draw",
	Density = "Density",
	Control = "Control",
}

local SLOT_ICONS: { [string]: string } = {
	Weapon = "Weapon",
	Head = "Head",
	Chest = "Chest",
	Legs = "Legs",
	Hands = "Hands",
	Cloak = "Cloak",
	Ring1 = "Ring",
	Ring2 = "Ring",
	Amulet = "Amulet",
	BeaconCore = "BeaconCore",
}

local BONUS_ICONS: { [string]: string } = {
	MaxHealth = "Health",
	HealthRegen = "Health",
	HealPower = "Heal",
	Armor = "Armor",
	GuardPosture = "Guard",
	BlockCost = "Guard",
	CritChance = "Crit",
	CritDamage = "CritDamage",
	WeaponDamage = "Damage",
	PostureDamage = "Posture",
	RiposteDamage = "Riposte",
	ParryWindow = "Riposte",
	ExecuteDamage = "Execute",
	Threat = "Threat",
	MaxStamina = "Stamina",
	StaminaRegen = "Stamina",
	DodgeCost = "Dodge",
	MoveSpeed = "Speed",
	MaxCurrent = "CurrentDrop",
	CurrentRegen = "Draw",
	Siphon = "Siphon",
	SpellDamage = "SpellPower",
	SpellArea = "SpellArea",
	CastSpeed = "CastSpeed",
	ReactionDamage = "Reaction",
	OverflowDuration = "Overflow",
	ResonanceDecay = "Resonance",
	AbilityPower = "AbilityPower",
	AbilityCooldown = "Time",
	SentryDamage = "Beacon",
	AegisRecharge = "Beacon",
	RelayCooldown = "Beacon",
	BeaconSlots = "Beacon",
	LootLuck = "Loot",
	GoldFind = "Gold",
	MarkPower = "Mark",
}

local Icons = {}

Icons.CellSize = CELL

local function iconSheet(): string
	return Config.Assets.UI.IconSheet
end

local function fxSheet(): string
	return Config.Assets.UI.FxSheet
end

function Icons.Has(name: string): boolean
	local offset: Vector2? = ICONS[name]
	return offset ~= nil
end

-- Points an ImageLabel / ImageButton at an icon (empty image if unknown).
function Icons.Apply(image: GuiObject, name: string?)
	local target = image :: any
	local offset = if name then ICONS[name] else nil
	if offset then
		target.Image = iconSheet()
		target.ImageRectOffset = offset
		target.ImageRectSize = Vector2.new(CELL, CELL)
	else
		target.Image = ""
	end
end

export type IconProps = {
	Name: string?, -- instance name
	Size: UDim2?,
	Position: UDim2?,
	AnchorPoint: Vector2?,
	Color: Color3?,
	Transparency: number?,
	Rotation: number?,
	ZIndex: number?,
	LayoutOrder: number?,
	Parent: any, -- Instance? (any, so a Frame or a button can be passed in a literal)
}

-- A tinted icon. `icon` is a name from the sheet ("Inventory", "Head"...).
function Icons.new(icon: string, props: IconProps?): ImageLabel
	local p: IconProps = props or {}
	local label: ImageLabel = Create.new("ImageLabel", {
		Name = p.Name or `Icon_{icon}`,
		BackgroundTransparency = 1,
		Size = p.Size or UDim2.fromOffset(24, 24),
		Position = p.Position or UDim2.new(),
		AnchorPoint = p.AnchorPoint or Vector2.zero,
		ImageColor3 = p.Color or Color3.new(1, 1, 1),
		ImageTransparency = p.Transparency or 0,
		Rotation = p.Rotation or 0,
		ScaleType = Enum.ScaleType.Fit,
		ZIndex = p.ZIndex or 1,
		LayoutOrder = p.LayoutOrder or 0,
	})
	Icons.Apply(label, icon)
	label.Parent = p.Parent
	return label
end

function Icons.FxRect(name: string): FxRect?
	return FX[name]
end

-- Points an image at one of the water-effect textures.
function Icons.ApplyFx(image: GuiObject, name: string)
	local target = image :: any
	local rect = FX[name]
	if rect then
		target.Image = fxSheet()
		target.ImageRectOffset = rect.Offset
		target.ImageRectSize = rect.Size
	else
		target.Image = ""
	end
end

-- A tinted water-effect image ("Glow", "Ring", "Swirl", "Wave"...).
function Icons.Fx(name: string, props: IconProps?): ImageLabel
	local p: IconProps = props or {}
	local label: ImageLabel = Create.new("ImageLabel", {
		Name = p.Name or `Fx_{name}`,
		BackgroundTransparency = 1,
		Size = p.Size or UDim2.fromOffset(64, 64),
		Position = p.Position or UDim2.new(),
		AnchorPoint = p.AnchorPoint or Vector2.zero,
		ImageColor3 = p.Color or Color3.new(1, 1, 1),
		ImageTransparency = p.Transparency or 0,
		Rotation = p.Rotation or 0,
		ScaleType = Enum.ScaleType.Stretch,
		ZIndex = p.ZIndex or 1,
		LayoutOrder = p.LayoutOrder or 0,
	})
	Icons.ApplyFx(label, name)
	label.Parent = p.Parent
	return label
end

function Icons.ForStat(stat: string): string
	return STAT_ICONS[stat] or "StatPoint"
end

function Icons.ForSlot(slot: string): string
	return SLOT_ICONS[slot] or "Inventory"
end

function Icons.ForBonus(id: string): string
	return BONUS_ICONS[id] or STAT_ICONS[id] or "SkillPoint"
end

-- Abilities, Positions and Attunements are named after their ids.
function Icons.ForAbility(id: string): string
	return if ICONS[id] then id else "AbilityPower"
end

function Icons.ForPosition(id: string): string
	return if ICONS[id] then id else "SkillTree"
end

function Icons.ForAttunement(id: string): string
	return if ICONS[id] then id else "Current"
end

-- The icon for a bonus table: its alphabetically first bonus id, so a
-- node's icon never changes between sessions.
function Icons.ForBonuses(bonuses: { [string]: number }): string
	local best: string? = nil
	for id in bonuses do
		if not best or id < best then
			best = id
		end
	end
	return if best then Icons.ForBonus(best) else "SkillPoint"
end

return table.freeze(Icons)
