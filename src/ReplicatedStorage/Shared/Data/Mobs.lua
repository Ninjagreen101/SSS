--!strict
--[[
	Mobs
	Enemy definitions (what each enemy IS). Adding an enemy is a new entry
	here plus its name in Strings.Mobs; MobService and MobController read
	everything else from this table.

	Mob fields:
	  Level        shown on the nameplate
	  MaxHealth / MaxPosture
	  WalkSpeed    patrolling and circling; RunSpeed when chasing
	  AggroRadius  how far it spots players (needs line of sight)
	  KeepAway     ranged mobs: back off from players closer than this
	  Rewards      XP and a gold range for everyone who helped kill it
	  Body         look of the placeholder body (colours, size, extra parts)
	  Weapon       the blade it holds (same look format as player weapons)
	  Moves        what it can do (see below)
	  WeakPoint    optional: blows landing from behind (within Arc degrees of its back) deal
	               Damage x and Posture x (the Brinehulk's exposed back)
	  Drain        optional: its blows heal it by Heal x damage dealt and drain Current from
	               players (the Cistern Leech)
	  Stealth      optional: clients fade it out while it lurks (Idle / Patrol) until close

	Move fields:
	  Kind          "Melee" (a swing checked at contact) or "Projectile"
	  Weight        how often it's picked compared with the other moves
	  MinRange / MaxRange   only used when the target is this far away
	  Telegraph     red warning glow before the first blow (>= Mobs.AI.MinTelegraph)
	  Blows         animation slot for each blow in the string, e.g. { "Light2", "Light3" }
	  BlowInterval  seconds between blows in a string
	  Reach / Arc   swing size (melee) | Speed / Radius / Range (projectile)
	  Damage / Posture / HitStun
	  Parryable / Blockable
	  HyperArmor    hits don't interrupt it once it starts
	  Lunge         studs it steps forward just before each blow
	  Recovery      seconds it stands open after the move
	  Cooldown      seconds before the move can be used again
	  Kind "Buff"   empowers allies within Radius: +Bonus damage for Duration seconds
	                (needs an engaged ally nearby that isn't already empowered)
]]

local Items = require(script.Parent.Items)

export type MoveKind = "Melee" | "Projectile" | "Buff"

export type MoveDef = {
	Kind: MoveKind,
	Weight: number,
	MinRange: number,
	MaxRange: number,
	Telegraph: number,
	Blows: { string },
	BlowInterval: number?,
	Reach: number?,
	Arc: number?,
	Speed: number?,
	Radius: number?,
	Range: number?,
	Damage: number,
	Posture: number,
	HitStun: number,
	Parryable: boolean,
	Blockable: boolean,
	HyperArmor: boolean?,
	Lunge: number?,
	Recovery: number,
	Cooldown: number,
	Bonus: number?, -- Buff: extra damage fraction for allies
	Duration: number?, -- Buff: seconds
}

export type BodyPart = {
	Attach: string, -- body part it sits on, e.g. "Head"
	Size: Vector3,
	Offset: CFrame, -- relative to the body part
	Color: Color3,
	Material: Enum.Material,
	Shape: Enum.PartType?,
	Glow: boolean?, -- neon, with a small light
	Role: string?, -- part name (e.g. "Shell", "Claw"); default "Detail"
}

export type BodyDef = {
	Scale: number,
	Skin: Color3,
	Torso: Color3,
	Arms: Color3,
	Legs: Color3,
	Extras: { BodyPart },
	Creature: boolean?, -- hide the humanoid limbs: the Extras ARE the body (crabs, wisps, leeches)
	Hover: number?, -- studs added to HipHeight (floating wisps)
	-- Blender-made body (SpireKit_Guardians pieces with this Body name, MobService/Builder); the
	-- Extras are the fallback until that kit is imported and prepared.
	MeshBody: string?,
}

export type MobDef = {
	Level: number,
	MaxHealth: number,
	MaxPosture: number,
	WalkSpeed: number,
	RunSpeed: number,
	AggroRadius: number,
	KeepAway: number?,
	Rewards: { XP: number, GoldMin: number, GoldMax: number },
	Body: BodyDef,
	Weapon: Items.WeaponModel?,
	Moves: { [string]: MoveDef },
	WeakPoint: { Arc: number, Damage: number, Posture: number }?,
	Drain: { Heal: number, Current: number }?,
	Stealth: boolean?,
}


local function color(hex: string): Color3
	return Color3.fromHex(hex)
end

-- THE BRINEWARDEN'S PLACEHOLDER BODY -------------------------------------------------------------
-- Used until SpireKit_Guardians is imported (Body.MeshBody, MobService/Builder). Built in each
-- limb's space at body scale 1: x right, y up, front -z; the boss's left (-x) carries the pincer.
-- Role names matter to the fight: every "Shell" part falls away in phase 3, "Core" shows then,
-- "Seam" is the back weak point, "Claw" is the grabbing pincer, "Helm" the head.

local WARDEN = {
	Chitin = color("#3E4A4D"),
	ChitinLight = color("#56656A"),
	ChitinDark = color("#2B3436"),
	Shell = color("#8A4A36"),
	Rust = color("#A4553A"),
	Bone = color("#C9C0A8"),
	Coral = color("#C4706A"),
	Glow = color("#3FE0D0"),
	Brass = color("#A88A4F"),
	Iron = color("#3D4045"),
	Cloth = color("#5E5A4C"),
	Kelp = color("#34452F"),
	Rope = color("#8C7853"),
}

local SLATE = Enum.Material.Slate
local PEBBLE = Enum.Material.Pebble
local METAL = Enum.Material.Metal
local NEON = Enum.Material.Neon
local FABRIC = Enum.Material.Fabric
local BALL = Enum.PartType.Ball
local CYLINDER = Enum.PartType.Cylinder
local WEDGE = Enum.PartType.Wedge

local function rot(x: number, y: number, z: number): CFrame
	return CFrame.Angles(math.rad(x), math.rad(y), math.rad(z))
end

local function at(x: number, y: number, z: number): CFrame
	return CFrame.new(x, y, z)
end

-- One part.
local function bp(attach: string, role: string, size: Vector3, offset: CFrame, tint: Color3, material: Enum.Material, shape: Enum.PartType?): BodyPart
	return { Attach = attach, Role = role, Size = size, Offset = offset, Color = tint, Material = material, Shape = shape }
end

-- A square bar from a to b (spikes, horns, crab legs, coral).
local function bar(attach: string, role: string, a: Vector3, b: Vector3, thickness: number, tint: Color3, material: Enum.Material): BodyPart
	return bp(attach, role, Vector3.new(thickness, thickness, (b - a).Magnitude), CFrame.lookAt((a + b) / 2, b), tint, material)
end

local function v(x: number, y: number, z: number): Vector3
	return Vector3.new(x, y, z)
end

local function size(x: number, y: number, z: number): Vector3
	return Vector3.new(x, y, z)
end

local BRINEWARDEN_EXTRAS: { BodyPart } = {}

local function add(list: { BodyPart })
	for _, item in list do
		table.insert(BRINEWARDEN_EXTRAS, item)
	end
end

-- Helm: a low crab carapace with a crest, angry teal eye slits and eye-stalk horns.
add({
	bp("Head", "Helm", size(1.65, 1.0, 1.6), at(0, 0.22, 0.05), WARDEN.Shell, PEBBLE, BALL),
	bp("Head", "HelmRim", size(0.22, 1.62, 1.62), at(0, -0.05, 0.05) * rot(0, 0, 90), WARDEN.Chitin, SLATE, CYLINDER),
	bp("Head", "Visor", size(0.95, 0.55, 0.22), at(0, -0.05, -0.62), WARDEN.ChitinDark, SLATE),
	bp("Head", "Eyes", size(0.32, 0.07, 0.05), at(0.2, 0.07, -0.74) * rot(0, 0, 14), WARDEN.Glow, NEON),
	bp("Head", "Eyes", size(0.32, 0.07, 0.05), at(-0.2, 0.07, -0.74) * rot(0, 0, -14), WARDEN.Glow, NEON),
	bp("Head", "Brow", size(1.15, 0.2, 0.32), at(0, 0.27, -0.7), WARDEN.Rust, PEBBLE, WEDGE),
	bar("Head", "Spike", v(0.1, 0.3, -0.75), v(0.12, 0.33, -1.08), 0.1, WARDEN.Rust, PEBBLE),
	bar("Head", "Spike", v(-0.1, 0.3, -0.75), v(-0.12, 0.33, -1.08), 0.1, WARDEN.Rust, PEBBLE),
	bp("Head", "Crest", size(0.1, 0.45, 1.15), at(0, 0.85, 0.12), WARDEN.Rust, PEBBLE, WEDGE),
	bp("Head", "Helm", size(0.16, 0.55, 0.7), at(0.76, -0.12, -0.12) * rot(0, 0, 8), WARDEN.Shell, PEBBLE),
	bp("Head", "Helm", size(0.16, 0.55, 0.7), at(-0.76, -0.12, -0.12) * rot(0, 0, -8), WARDEN.Shell, PEBBLE),
	bar("Head", "Horn", v(0.32, 0.55, -0.4), v(0.5, 1.05, -0.38), 0.16, WARDEN.Rust, PEBBLE),
	bar("Head", "Horn", v(0.5, 1.05, -0.38), v(0.82, 1.35, -0.15), 0.13, WARDEN.Rust, PEBBLE),
	bar("Head", "Horn", v(-0.32, 0.55, -0.4), v(-0.5, 1.05, -0.38), 0.16, WARDEN.Rust, PEBBLE),
	bar("Head", "Horn", v(-0.5, 1.05, -0.38), v(-0.82, 1.35, -0.15), 0.13, WARDEN.Rust, PEBBLE),
	bp("Head", "Horn", size(0.13, 0.13, 0.13), at(0.84, 1.37, -0.12), WARDEN.Bone, PEBBLE, BALL),
	bp("Head", "Horn", size(0.13, 0.13, 0.13), at(-0.84, 1.37, -0.12), WARDEN.Bone, PEBBLE, BALL),
	bar("Head", "Mandible", v(0.14, -0.4, -0.6), v(0.1, -0.75, -0.66), 0.09, WARDEN.ChitinDark, SLATE),
	bar("Head", "Mandible", v(-0.14, -0.4, -0.6), v(-0.1, -0.75, -0.66), 0.09, WARDEN.ChitinDark, SLATE),
	bp("Head", "Barnacle", size(0.18, 0.18, 0.18), at(0.5, 0.6, 0.35), WARDEN.Bone, PEBBLE, BALL),
})

-- Chest: dark body, banded breastplate, the core in its brass socket behind a red shell plate.
add({
	bp("UpperTorso", "Body", size(1.9, 1.6, 0.98), at(0, 0, 0), WARDEN.ChitinDark, SLATE),
	bp("UpperTorso", "Carapace", size(1.95, 0.5, 0.3), at(0, 0.55, -0.48) * rot(-8, 0, 0), WARDEN.Chitin, SLATE),
	bp("UpperTorso", "Carapace", size(1.9, 0.26, 0.3), at(0, -0.1, -0.5) * rot(12, 0, 0), WARDEN.Chitin, SLATE),
	bp("UpperTorso", "Carapace", size(1.86, 0.26, 0.3), at(0, -0.35, -0.48) * rot(12, 0, 0), WARDEN.Chitin, SLATE),
	bp("UpperTorso", "Carapace", size(1.82, 0.26, 0.3), at(0, -0.6, -0.46) * rot(12, 0, 0), WARDEN.Chitin, SLATE),
	bp("UpperTorso", "Trim", size(1.92, 0.05, 0.32), at(0, -0.22, -0.52), WARDEN.Brass, METAL),
	bp("UpperTorso", "Trim", size(1.88, 0.05, 0.32), at(0, -0.47, -0.5), WARDEN.Brass, METAL),
	bp("UpperTorso", "Trim", size(1.84, 0.05, 0.32), at(0, -0.72, -0.48), WARDEN.Brass, METAL),
	bp("UpperTorso", "Socket", size(0.12, 0.62, 0.62), at(0, 0.25, -0.5) * rot(0, 90, 0), WARDEN.Brass, METAL, CYLINDER),
	{ Attach = "UpperTorso", Role = "Core", Size = size(0.42, 0.42, 0.42), Offset = at(0, 0.25, -0.56), Color = WARDEN.Glow, Material = NEON, Shape = BALL, Glow = true },
	bp("UpperTorso", "Shell", size(0.75, 0.85, 0.32), at(0, 0.22, -0.66), WARDEN.Shell, PEBBLE, BALL),
	bp("UpperTorso", "Shell", size(0.1, 0.7, 0.12), at(0, 0.22, -0.82), WARDEN.Rust, PEBBLE),
	bp("UpperTorso", "Collar", size(1.5, 0.45, 0.22), at(0, 0.92, 0.48) * rot(25, 0, 0), WARDEN.Chitin, SLATE),
	bar("UpperTorso", "Spike", v(-0.45, 1.05, 0.55), v(-0.5, 1.35, 0.7), 0.08, WARDEN.Rust, PEBBLE),
	bar("UpperTorso", "Spike", v(0, 1.08, 0.55), v(0, 1.42, 0.72), 0.08, WARDEN.Rust, PEBBLE),
	bar("UpperTorso", "Spike", v(0.45, 1.05, 0.55), v(0.5, 1.35, 0.7), 0.08, WARDEN.Rust, PEBBLE),
})

-- Back: three overlapping red plates a side, the glowing seam between them.
for _, sx in { -1, 1 } do
	for k = 0, 2 do
		add({ bp("UpperTorso", "Shell", size(0.85, 0.52, 0.22), at(sx * 0.48, 0.55 - 0.5 * k, 0.6 + 0.02 * k) * rot(-14, sx * 15, 0), WARDEN.Shell, PEBBLE) })
	end
	add({
		bar("UpperTorso", "Shell", v(sx * 0.82, 0.45, 0.6), v(sx * 1.1, 0.62, 0.8), 0.08, WARDEN.Rust, PEBBLE),
		bar("UpperTorso", "Shell", v(sx * 0.82, -0.05, 0.62), v(sx * 1.12, 0.05, 0.84), 0.08, WARDEN.Rust, PEBBLE),
		bp("UpperTorso", "Shell", size(0.16, 0.16, 0.16), at(sx * 0.45, sx * 0.3, 0.76), WARDEN.Bone, PEBBLE, BALL),
	})
end
add({ bp("UpperTorso", "Seam", size(0.1, 1.3, 0.1), at(0, 0.05, 0.64), WARDEN.Glow, NEON) })

-- Hips: brass belt, tassets, a torn sail-cloth tabard and four folded crab legs behind.
add({
	bp("LowerTorso", "Belt", size(2.05, 0.32, 1.1), at(0, 0, 0), WARDEN.Brass, METAL),
	bp("LowerTorso", "Belt", size(0.1, 0.42, 0.42), at(0, 0, -0.58) * rot(0, 90, 0), WARDEN.Brass, METAL, CYLINDER),
	bp("LowerTorso", "Belt", size(0.14, 0.14, 0.14), at(0, 0, -0.64), WARDEN.Bone, PEBBLE, BALL),
	bp("LowerTorso", "Tabard", size(0.75, 1.3, 0.06), at(0, -0.8, -0.62) * rot(6, 0, 0), WARDEN.Cloth, FABRIC),
	bp("LowerTorso", "Tabard", size(0.9, 1.5, 0.06), at(0, -0.9, 0.6) * rot(-6, 0, 0), WARDEN.Cloth, FABRIC),
	bp("LowerTorso", "Kelp", size(0.12, 1.1, 0.04), at(0.3, -0.7, -0.66) * rot(6, 0, 5), WARDEN.Kelp, FABRIC),
	bp("LowerTorso", "Kelp", size(0.12, 1.25, 0.04), at(-0.55, -0.8, 0.64) * rot(-6, 0, -4), WARDEN.Kelp, FABRIC),
})
for _, sx in { -1, 1 } do
	add({
		bp("LowerTorso", "Tasset", size(0.55, 0.6, 0.12), at(sx * 0.72, -0.4, -0.5) * rot(8, 0, 0), WARDEN.Chitin, SLATE),
		bp("LowerTorso", "Tasset", size(0.55, 0.6, 0.12), at(sx * 0.72, -0.4, 0.5) * rot(-8, 0, 0), WARDEN.Chitin, SLATE),
		bp("LowerTorso", "Tasset", size(0.12, 0.6, 0.7), at(sx * 1.02, -0.4, 0) * rot(0, 0, sx * 8), WARDEN.Chitin, SLATE),
	})
	local legs = {
		{ v(0.74, 0.11, 0.4), v(1.47, 0.64, 0.81), v(2.06, -0.07, 1.01), v(2.13, -0.75, 0.88) },
		{ v(0.71, -0.04, 0.5), v(1.38, 0.28, 0.97), v(1.91, -0.45, 1.19), v(1.96, -1.1, 1.06) },
	}
	for _, leg in legs do
		local p = table.create(4, Vector3.zero)
		for i, point in leg do
			p[i] = Vector3.new(point.X * sx, point.Y, point.Z)
		end
		add({
			bar("LowerTorso", "Leg", p[1], p[2], 0.15, WARDEN.Shell, PEBBLE),
			bar("LowerTorso", "Leg", p[2], p[3], 0.13, WARDEN.Shell, PEBBLE),
			bar("LowerTorso", "Leg", p[3], p[4], 0.1, WARDEN.ChitinDark, SLATE),
			bp("LowerTorso", "Leg", size(0.17, 0.17, 0.17), CFrame.new(p[2]), WARDEN.Rust, PEBBLE, BALL),
		})
	end
end

-- Shoulders: a huge spined crab shell on the pincer side, a smaller forged one on the sword side.
add({
	bp("LeftUpperArm", "Shell", size(1.75, 1.05, 1.65), at(-0.15, 0.62, 0) * rot(0, 0, 22), WARDEN.Shell, PEBBLE, BALL),
	bp("LeftUpperArm", "Shell", size(0.14, 1.95, 1.95), at(-0.18, 0.4, 0) * rot(0, 0, 112), WARDEN.Chitin, SLATE, CYLINDER),
	bar("LeftUpperArm", "Shell", v(-0.3, 1.0, 0.05), v(-0.5, 1.6, 0.1), 0.16, WARDEN.Rust, PEBBLE),
	bar("LeftUpperArm", "Shell", v(-0.65, 0.9, -0.1), v(-1.1, 1.45, -0.15), 0.15, WARDEN.Rust, PEBBLE),
	bar("LeftUpperArm", "Shell", v(-0.95, 0.75, 0.15), v(-1.5, 1.05, 0.25), 0.14, WARDEN.Rust, PEBBLE),
	bp("LeftUpperArm", "Shell", size(0.11, 0.11, 0.11), at(-0.5, 1.62, 0.1), WARDEN.Bone, PEBBLE, BALL),
	bp("LeftUpperArm", "Shell", size(0.11, 0.11, 0.11), at(-1.12, 1.47, -0.15), WARDEN.Bone, PEBBLE, BALL),
	bp("LeftUpperArm", "Shell", size(0.11, 0.11, 0.11), at(-1.52, 1.06, 0.25), WARDEN.Bone, PEBBLE, BALL),
	bp("LeftUpperArm", "Shell", size(0.18, 0.18, 0.18), at(-0.2, 1.05, -0.35), WARDEN.Bone, PEBBLE, BALL),
	bp("LeftUpperArm", "Shell", size(0.15, 0.15, 0.15), at(0.15, 0.97, 0.3), WARDEN.Bone, PEBBLE, BALL),
	bar("LeftUpperArm", "Shell", v(0.0, 1.0, 0.35), v(0.05, 1.42, 0.5), 0.1, WARDEN.Coral, PEBBLE),
	bp("RightUpperArm", "Shell", size(1.35, 0.85, 1.3), at(0.12, 0.6, 0) * rot(0, 0, -22), WARDEN.Shell, PEBBLE, BALL),
	bp("RightUpperArm", "Shell", size(0.12, 1.5, 1.5), at(0.14, 0.42, 0) * rot(0, 0, 68), WARDEN.Shell, PEBBLE, CYLINDER),
	bp("RightUpperArm", "Shell", size(0.1, 0.12, 1.2), at(0.12, 0.98, 0) * rot(0, 0, -22), WARDEN.Brass, METAL),
	bar("RightUpperArm", "Shell", v(0.35, 0.95, -0.15), v(0.62, 1.35, -0.2), 0.13, WARDEN.Rust, PEBBLE),
	bar("RightUpperArm", "Shell", v(0.55, 0.85, 0.2), v(0.92, 1.15, 0.25), 0.12, WARDEN.Rust, PEBBLE),
})
for _, side in { "Left", "Right" } do
	add({
		bp(`{side}UpperArm`, "Armor", size(1.15, 1.1, 1.1), at(0, -0.05, 0) * rot(0, 0, 90), WARDEN.Chitin, SLATE, CYLINDER),
		bp(`{side}UpperArm`, "Trim", size(0.1, 1.16, 1.16), at(0, -0.3, 0) * rot(0, 0, 90), WARDEN.Brass, METAL, CYLINDER),
	})
end

-- Forearms: a spiny red crab merus on the pincer side, a finned vambrace on the sword side.
add({
	bp("LeftLowerArm", "Armor", size(1.3, 1.35, 1.3), at(0, 0, 0), WARDEN.Shell, PEBBLE, BALL),
	bp("LeftLowerArm", "Armor", size(0.12, 1.3, 1.3), at(0, 0.2, 0) * rot(0, 0, 90), WARDEN.ChitinDark, SLATE, CYLINDER),
	bar("LeftLowerArm", "Spike", v(0, 0.3, -0.62), v(0, 0.42, -0.88), 0.1, WARDEN.Rust, PEBBLE),
	bar("LeftLowerArm", "Spike", v(0, -0.1, -0.65), v(0, 0, -0.92), 0.1, WARDEN.Rust, PEBBLE),
	bar("LeftLowerArm", "Spike", v(-0.62, 0.2, 0), v(-0.9, 0.32, 0.02), 0.1, WARDEN.Rust, PEBBLE),
	bar("LeftLowerArm", "Spike", v(-0.65, -0.2, 0), v(-0.92, -0.1, 0.05), 0.1, WARDEN.Rust, PEBBLE),
	bp("LeftLowerArm", "Barnacle", size(0.15, 0.15, 0.15), at(-0.4, -0.3, 0.45), WARDEN.Bone, PEBBLE, BALL),
	bp("RightLowerArm", "Armor", size(1.05, 1.1, 1.05), at(0, 0, 0), WARDEN.Chitin, SLATE),
	bp("RightLowerArm", "Trim", size(1.1, 0.08, 1.1), at(0, 0.35, 0), WARDEN.Brass, METAL),
	bp("RightLowerArm", "Trim", size(1.1, 0.08, 1.1), at(0, -0.45, 0), WARDEN.Brass, METAL),
	bp("RightLowerArm", "Fin", size(0.1, 0.5, 0.7), at(0.58, 0, 0.1), WARDEN.Rust, PEBBLE, WEDGE),
	bar("RightLowerArm", "Spike", v(0, 0.35, 0.5), v(0, 0.25, 0.85), 0.12, WARDEN.Rust, PEBBLE),
})

-- The pincer: a big palm reaching forward and down, two serrated fingers, barnacle crust.
add({
	bp("LeftHand", "Claw", size(1.05, 1.45, 2.0), at(0, -0.46, -0.65) * rot(-42, 0, 0), WARDEN.Shell, PEBBLE, BALL),
	bp("LeftHand", "Trim", size(0.12, 1.15, 1.15), at(0, 0.12, 0) * rot(0, 0, 90), WARDEN.Brass, METAL, CYLINDER),
	bar("LeftHand", "Pincer", v(0, -1.18, -1.03), v(0, -1.75, -1.7), 0.4, WARDEN.Shell, PEBBLE),
	bar("LeftHand", "Pincer", v(0, -1.75, -1.7), v(0, -1.85, -2.3), 0.26, WARDEN.ChitinDark, SLATE),
	bar("LeftHand", "Pincer", v(0, -0.71, -1.46), v(0, -0.85, -2.0), 0.36, WARDEN.Shell, PEBBLE),
	bar("LeftHand", "Pincer", v(0, -0.85, -2.0), v(0, -1.35, -2.35), 0.24, WARDEN.ChitinDark, SLATE),
	bp("LeftHand", "Pincer", size(0.3, 0.3, 0.3), at(0, -0.71, -1.42), WARDEN.ChitinDark, SLATE, BALL),
	bar("LeftHand", "Teeth", v(0, -1.38, -1.3), v(0, -1.22, -1.4), 0.07, WARDEN.Bone, PEBBLE),
	bar("LeftHand", "Teeth", v(0, -1.6, -1.55), v(0, -1.44, -1.64), 0.07, WARDEN.Bone, PEBBLE),
	bar("LeftHand", "Teeth", v(0, -0.86, -1.75), v(0, -1.02, -1.7), 0.07, WARDEN.Bone, PEBBLE),
	bar("LeftHand", "Teeth", v(0, -1.0, -2.05), v(0, -1.16, -2.0), 0.07, WARDEN.Bone, PEBBLE),
	bar("LeftHand", "Spike", v(0, 0.07, -1.13), v(0, 0.27, -1.31), 0.1, WARDEN.Rust, PEBBLE),
	bar("LeftHand", "Spike", v(0, -0.25, -1.45), v(0, -0.06, -1.63), 0.1, WARDEN.Rust, PEBBLE),
	bp("LeftHand", "Barnacle", size(0.16, 0.16, 0.16), at(-0.5, -0.4, -0.55), WARDEN.Bone, PEBBLE, BALL),
	bp("LeftHand", "Barnacle", size(0.14, 0.14, 0.14), at(-0.45, -0.7, -0.9), WARDEN.Bone, PEBBLE, BALL),
	bp("LeftHand", "Barnacle", size(0.15, 0.15, 0.15), at(-0.5, -0.2, -0.3), WARDEN.Bone, PEBBLE, BALL),
})

-- Sword hand: an iron gauntlet round the two-handed coral greatsword (blade along -z like every R15
-- weapon, edge down; the grip runs through the hand a little below its centre).
add({
	bp("RightHand", "Gauntlet", size(1.05, 0.62, 1.1), at(0, 0.02, 0), WARDEN.Iron, METAL),
	bp("RightHand", "Gauntlet", size(0.2, 0.45, 1.0), at(0.5, 0.05, 0), WARDEN.Chitin, SLATE),
	bar("RightHand", "Spike", v(0.6, 0.15, -0.25), v(0.82, 0.2, -0.25), 0.08, WARDEN.Rust, PEBBLE),
	bar("RightHand", "Spike", v(0.6, 0.15, 0.2), v(0.82, 0.2, 0.2), 0.08, WARDEN.Rust, PEBBLE),
	-- a two-handed grip and a heavy bone pommel behind the hand
	bp("RightHand", "Grip", size(1.45, 0.24, 0.24), at(0, -0.095, 0.4) * rot(0, 90, 0), WARDEN.Rope, FABRIC, CYLINDER),
	bp("RightHand", "Pommel", size(0.48, 0.44, 0.48), at(0, -0.095, 1.2), WARDEN.Bone, PEBBLE, BALL),
	bp("RightHand", "Pommel", size(0.5, 0.12, 0.12), at(0, -0.095, 1.0) * rot(0, 90, 0), WARDEN.Brass, METAL, CYLINDER),
	bp("RightHand", "Pommel", size(0.16, 0.16, 0.16), at(0, -0.095, 1.44), WARDEN.Glow, NEON, BALL),
	-- heavy brass and bone crossguard, quillons curling forward
	bp("RightHand", "Guard", size(0.42, 0.78, 0.32), at(0, -0.095, -0.59), WARDEN.Brass, METAL),
	bp("RightHand", "Guard", size(0.3, 0.98, 0.24), at(0, -0.095, -0.8), WARDEN.Bone, PEBBLE),
	bar("RightHand", "Guard", v(0, 0.25, -0.59), v(0.01, 0.9, -0.75), 0.15, WARDEN.Brass, METAL),
	bar("RightHand", "Guard", v(0.01, 0.9, -0.75), v(0.02, 0.88, -1.2), 0.11, WARDEN.Brass, METAL),
	bar("RightHand", "Guard", v(0, -0.44, -0.59), v(-0.01, -1.09, -0.75), 0.15, WARDEN.Brass, METAL),
	bar("RightHand", "Guard", v(-0.01, -1.09, -0.75), v(-0.02, -1.07, -1.2), 0.11, WARDEN.Brass, METAL),
	-- the blade: about 4.7 long (16 studs on the Warden), 0.85 wide (2.9 studs) at the base, edge down
	bp("RightHand", "Blade", size(0.2, 0.85, 1.6), at(0, -0.095, -1.7), WARDEN.Coral, PEBBLE),
	bp("RightHand", "Blade", size(0.19, 0.78, 1.5), at(0, -0.095, -3.2), WARDEN.Coral, PEBBLE),
	bp("RightHand", "Blade", size(0.18, 0.62, 1.0), at(0, -0.095, -4.4), WARDEN.Coral, PEBBLE),
	bp("RightHand", "Blade", size(0.17, 0.5, 0.7), at(0, -0.095, -5.25), WARDEN.Coral, PEBBLE, WEDGE),
	bp("RightHand", "Blade", size(0.14, 0.2, 0.35), at(0, 0.36, -2.4), WARDEN.Coral, PEBBLE, WEDGE),
	bp("RightHand", "Spine", size(0.28, 0.16, 3.9), at(0, -0.095, -2.75), WARDEN.Bone, PEBBLE),
	bp("RightHand", "Vein", size(0.3, 0.05, 3.6), at(0, -0.095, -2.8), WARDEN.Glow, NEON),
	bp("RightHand", "Vein", size(0.22, 0.04, 0.5), at(0, 0.12, -1.6) * rot(35, 0, 0), WARDEN.Glow, NEON),
	bp("RightHand", "Vein", size(0.22, 0.04, 0.5), at(0, -0.3, -2.9) * rot(-35, 0, 0), WARDEN.Glow, NEON),
	bp("RightHand", "Vein", size(0.21, 0.04, 0.45), at(0, 0.1, -3.9) * rot(35, 0, 0), WARDEN.Glow, NEON),
	bp("RightHand", "Edge", size(0.21, 0.07, 4.6), at(0, -0.53, -2.95), WARDEN.Bone, PEBBLE),
	-- coral branches and barnacle clusters grown along the blade
	bar("RightHand", "Coral", v(0, 0.3, -1.3), v(0.03, 0.62, -1.5), 0.12, WARDEN.Coral, PEBBLE),
	bar("RightHand", "Coral", v(0.03, 0.62, -1.5), v(0.05, 0.72, -1.78), 0.09, WARDEN.Coral, PEBBLE),
	bar("RightHand", "Coral", v(0.03, 0.55, -1.45), v(0.12, 0.82, -1.38), 0.07, WARDEN.Coral, PEBBLE),
	bar("RightHand", "Coral", v(0, -0.5, -2.1), v(-0.03, -0.82, -2.35), 0.11, WARDEN.Coral, PEBBLE),
	bar("RightHand", "Coral", v(-0.03, -0.82, -2.35), v(-0.05, -0.9, -2.62), 0.08, WARDEN.Coral, PEBBLE),
	bar("RightHand", "Coral", v(0, 0.25, -3.4), v(0.02, 0.52, -3.65), 0.1, WARDEN.Coral, PEBBLE),
	bar("RightHand", "Coral", v(0.08, 0.0, -2.0), v(0.3, 0.12, -2.15), 0.08, WARDEN.Coral, PEBBLE),
	bar("RightHand", "Coral", v(-0.08, -0.2, -3.0), v(-0.3, -0.12, -3.2), 0.08, WARDEN.Coral, PEBBLE),
	bp("RightHand", "Barnacle", size(0.14, 0.14, 0.14), at(0.11, 0.15, -1.2), WARDEN.Bone, PEBBLE, BALL),
	bp("RightHand", "Barnacle", size(0.12, 0.12, 0.12), at(0.11, 0.22, -1.38), WARDEN.Bone, PEBBLE, BALL),
	bp("RightHand", "Barnacle", size(0.13, 0.13, 0.13), at(-0.11, -0.3, -2.5), WARDEN.Bone, PEBBLE, BALL),
	bp("RightHand", "Barnacle", size(0.11, 0.11, 0.11), at(-0.11, -0.18, -2.66), WARDEN.Bone, PEBBLE, BALL),
	bp("RightHand", "Barnacle", size(0.12, 0.12, 0.12), at(0.1, 0.05, -3.7), WARDEN.Bone, PEBBLE, BALL),
})

-- Legs: dark cuisses, red knee shells with forward spikes, spined greaves, clawed sabatons.
for _, sx in { -1, 1 } do
	local side = if sx < 0 then "Left" else "Right"
	add({
		bp(`{side}UpperLeg`, "Armor", size(1.0, 1.3, 1.0), at(0, 0, 0), WARDEN.ChitinDark, SLATE),
		bp(`{side}UpperLeg`, "Armor", size(0.9, 0.95, 0.16), at(0, 0.12, -0.52) * rot(-6, 0, 0), WARDEN.Chitin, SLATE),
		bp(`{side}UpperLeg`, "Armor", size(0.14, 0.85, 0.8), at(sx * 0.55, 0.15, 0), WARDEN.Chitin, SLATE),
		bp(`{side}UpperLeg`, "Knee", size(0.65, 0.55, 0.45), at(0, -0.5, -0.48), WARDEN.Shell, PEBBLE, BALL),
		bar(`{side}UpperLeg`, "Spike", v(0, -0.48, -0.66), v(0, -0.35, -0.98), 0.12, WARDEN.Rust, PEBBLE),
		bp(`{side}LowerLeg`, "Armor", size(0.95, 1.25, 0.95), at(0, 0, 0), WARDEN.ChitinDark, SLATE),
		bp(`{side}LowerLeg`, "Armor", size(0.88, 1.05, 0.15), at(0, 0.05, -0.5) * rot(8, 0, 0), WARDEN.Chitin, SLATE),
		bp(`{side}LowerLeg`, "Armor", size(0.9, 0.3, 0.17), at(0, 0.05, -0.52) * rot(8, 0, 0), WARDEN.Shell, PEBBLE),
		bar(`{side}LowerLeg`, "Spike", v(0, 0.35, -0.58), v(0, 0.5, -0.82), 0.1, WARDEN.Rust, PEBBLE),
		bar(`{side}LowerLeg`, "Spike", v(0, -0.1, -0.6), v(0, 0.03, -0.85), 0.1, WARDEN.Rust, PEBBLE),
		bar(`{side}LowerLeg`, "Spike", v(0, -0.05, 0.45), v(0, -0.25, 0.95), 0.14, WARDEN.Rust, PEBBLE),
		bp(`{side}Foot`, "Foot", size(1.0, 0.32, 1.3), at(0, 0, -0.18), WARDEN.ChitinDark, SLATE),
		bp(`{side}Foot`, "Foot", size(0.95, 0.25, 0.5), at(0, 0.2, -0.45), WARDEN.Chitin, SLATE, WEDGE),
		bar(`{side}Foot`, "Talon", v(-0.3, -0.05, -0.8), v(-0.4, -0.12, -1.25), 0.12, WARDEN.Bone, PEBBLE),
		bar(`{side}Foot`, "Talon", v(0, -0.05, -0.8), v(0, -0.12, -1.3), 0.12, WARDEN.Bone, PEBBLE),
		bar(`{side}Foot`, "Talon", v(0.3, -0.05, -0.8), v(0.4, -0.12, -1.25), 0.12, WARDEN.Bone, PEBBLE),
		bar(`{side}Foot`, "Spike", v(0, 0, 0.45), v(0, -0.05, 0.75), 0.1, WARDEN.Bone, PEBBLE),
	})
end

local NPC_STUN = 0.3

local Mobs: { [string]: MobDef } = {
	-- FLOOR 1: LOWHARBOR ------------------------------------------------------------------

	-- Shore scavengers the size of a dog. Quick pinches, weak to everything; the first thing a
	-- new Climber fights on the Old Wharf. Its shell and legs ride the hidden rig's limbs.
	Bilgecrab = {
		Level = 2,
		MaxHealth = 70,
		MaxPosture = 50,
		WalkSpeed = 9,
		RunSpeed = 16,
		AggroRadius = 30,
		Rewards = { XP = 22, GoldMin = 1, GoldMax = 4 },
		Body = {
			Scale = 0.75,
			Skin = color("#8A4A36"),
			Torso = color("#8A4A36"),
			Arms = color("#8A4A36"),
			Legs = color("#8A4A36"),
			Creature = true,
			Extras = {
				{ Attach = "LowerTorso", Role = "Shell", Size = Vector3.new(3.6, 1.6, 3.0), Offset = CFrame.new(0, 0.6, 0), Color = color("#A4553A"), Material = Enum.Material.Pebble, Shape = Enum.PartType.Ball },
				{ Attach = "LowerTorso", Role = "Belly", Size = Vector3.new(3.0, 0.6, 2.4), Offset = CFrame.new(0, 0.05, 0), Color = color("#D8B48E"), Material = Enum.Material.SmoothPlastic, Shape = Enum.PartType.Ball },
				{ Attach = "LowerTorso", Role = "Eye", Size = Vector3.new(0.35, 0.35, 0.35), Offset = CFrame.new(-0.45, 1.2, -1.2), Color = color("#111111"), Material = Enum.Material.SmoothPlastic, Shape = Enum.PartType.Ball },
				{ Attach = "LowerTorso", Role = "Eye", Size = Vector3.new(0.35, 0.35, 0.35), Offset = CFrame.new(0.45, 1.2, -1.2), Color = color("#111111"), Material = Enum.Material.SmoothPlastic, Shape = Enum.PartType.Ball },
				{ Attach = "RightHand", Role = "Claw", Size = Vector3.new(0.9, 0.7, 1.5), Offset = CFrame.new(0, -0.2, -0.5), Color = color("#B45F3E"), Material = Enum.Material.Pebble },
				{ Attach = "LeftHand", Role = "Claw", Size = Vector3.new(0.9, 0.7, 1.5), Offset = CFrame.new(0, -0.2, -0.5), Color = color("#B45F3E"), Material = Enum.Material.Pebble },
				{ Attach = "LeftUpperLeg", Role = "Leg", Size = Vector3.new(2.2, 0.35, 0.35), Offset = CFrame.new(-0.9, 0, 0) * CFrame.Angles(0, 0, math.rad(-25)), Color = color("#7A3E2C"), Material = Enum.Material.SmoothPlastic },
				{ Attach = "RightUpperLeg", Role = "Leg", Size = Vector3.new(2.2, 0.35, 0.35), Offset = CFrame.new(0.9, 0, 0) * CFrame.Angles(0, 0, math.rad(25)), Color = color("#7A3E2C"), Material = Enum.Material.SmoothPlastic },
				{ Attach = "LeftLowerLeg", Role = "Leg", Size = Vector3.new(2.0, 0.3, 0.3), Offset = CFrame.new(-0.9, 0, 0.5) * CFrame.Angles(0, math.rad(20), math.rad(-30)), Color = color("#7A3E2C"), Material = Enum.Material.SmoothPlastic },
				{ Attach = "RightLowerLeg", Role = "Leg", Size = Vector3.new(2.0, 0.3, 0.3), Offset = CFrame.new(0.9, 0, 0.5) * CFrame.Angles(0, math.rad(-20), math.rad(30)), Color = color("#7A3E2C"), Material = Enum.Material.SmoothPlastic },
			},
		},
		Moves = {
			Pinch = {
				Kind = "Melee",
				Weight = 3,
				MinRange = 0,
				MaxRange = 6,
				Telegraph = 0.45,
				Blows = { "Light1" },
				Reach = 5,
				Arc = 100,
				Damage = 8,
				Posture = 8,
				HitStun = NPC_STUN,
				Parryable = true,
				Blockable = true,
				Lunge = 2,
				Recovery = 0.6,
				Cooldown = 0,
			},
			Snap = {
				Kind = "Melee",
				Weight = 1.5,
				MinRange = 5,
				MaxRange = 11,
				Telegraph = 0.5,
				Blows = { "Light4" },
				Reach = 5,
				Arc = 80,
				Damage = 10,
				Posture = 10,
				HitStun = NPC_STUN,
				Parryable = true,
				Blockable = true,
				Lunge = 7,
				Recovery = 0.8,
				Cooldown = 4,
			},
		},
	},

	-- Sailors the bay took and gave back. Balanced cutlass play: parry the slashes, punish the
	-- recovery. More of them walk the Old Wharf after dark.
	DrownedSailor = {
		Level = 4,
		MaxHealth = 140,
		MaxPosture = 80,
		WalkSpeed = 8,
		RunSpeed = 15,
		AggroRadius = 40,
		Rewards = { XP = 48, GoldMin = 4, GoldMax = 9 },
		Body = {
			Scale = 1,
			Skin = color("#8FA79C"),
			Torso = color("#2C3A4A"),
			Arms = color("#34465A"),
			Legs = color("#2A3138"),
			Extras = {
				{ Attach = "Head", Role = "Hat", Size = Vector3.new(1.6, 0.35, 1.5), Offset = CFrame.new(0, 0.55, 0), Color = color("#1E242A"), Material = Enum.Material.Fabric },
				{ Attach = "Head", Role = "Hat", Size = Vector3.new(1.0, 0.5, 1.0), Offset = CFrame.new(0, 0.85, 0), Color = color("#1E242A"), Material = Enum.Material.Fabric },
				{ Attach = "UpperTorso", Role = "Coat", Size = Vector3.new(2.15, 0.55, 1.2), Offset = CFrame.new(0, 0.5, 0), Color = color("#3D5266"), Material = Enum.Material.Fabric },
				{ Attach = "LowerTorso", Role = "Coat", Size = Vector3.new(2.1, 1.6, 1.25), Offset = CFrame.new(0, -0.8, 0.05), Color = color("#2C3A4A"), Material = Enum.Material.Fabric },
				{ Attach = "UpperTorso", Role = "Weed", Size = Vector3.new(0.4, 1.4, 0.2), Offset = CFrame.new(0.5, -0.1, -0.62), Color = color("#4D6134"), Material = Enum.Material.Grass },
			},
		},
		Weapon = { BladeLength = 3.0, BladeWidth = 0.4, GripLength = 0.8, GuardWidth = 1.0, BladeColor = color("#8C7A62") },
		Moves = {
			Slash = {
				Kind = "Melee",
				Weight = 3,
				MinRange = 0,
				MaxRange = 8,
				Telegraph = 0.5,
				Blows = { "Light1" },
				Reach = 7,
				Arc = 110,
				Damage = 13,
				Posture = 11,
				HitStun = NPC_STUN,
				Parryable = true,
				Blockable = true,
				Lunge = 2.5,
				Recovery = 0.7,
				Cooldown = 0,
			},
			TwinSlash = {
				Kind = "Melee",
				Weight = 2,
				MinRange = 0,
				MaxRange = 8,
				Telegraph = 0.55,
				Blows = { "Light2", "Light3" },
				BlowInterval = 0.42,
				Reach = 7,
				Arc = 120,
				Damage = 11,
				Posture = 10,
				HitStun = NPC_STUN,
				Parryable = true,
				Blockable = true,
				Lunge = 2,
				Recovery = 0.9,
				Cooldown = 3,
			},
			Lunge = {
				Kind = "Melee",
				Weight = 1.5,
				MinRange = 8,
				MaxRange = 15,
				Telegraph = 0.6,
				Blows = { "Light4" },
				Reach = 6,
				Arc = 70,
				Damage = 15,
				Posture = 13,
				HitStun = NPC_STUN,
				Parryable = true,
				Blockable = true,
				Lunge = 9,
				Recovery = 1.0,
				Cooldown = 5,
			},
		},
	},

	-- A mote of marsh light with a mind. Keeps its distance and spits Current; when cornered it
	-- flares outward. Floats, so it crosses pools freely.
	MarshWisp = {
		Level = 5,
		MaxHealth = 75,
		MaxPosture = 40,
		WalkSpeed = 10,
		RunSpeed = 14,
		AggroRadius = 48,
		KeepAway = 14,
		Rewards = { XP = 55, GoldMin = 3, GoldMax = 8 },
		Body = {
			Scale = 0.8,
			Skin = color("#3FE0D0"),
			Torso = color("#3FE0D0"),
			Arms = color("#3FE0D0"),
			Legs = color("#3FE0D0"),
			Creature = true,
			Hover = 3,
			Extras = {
				{ Attach = "UpperTorso", Role = "Core", Size = Vector3.new(1.6, 1.6, 1.6), Offset = CFrame.new(0, 0.2, 0), Color = color("#9FF7EE"), Material = Enum.Material.Neon, Shape = Enum.PartType.Ball, Glow = true },
				{ Attach = "UpperTorso", Role = "Halo", Size = Vector3.new(2.8, 2.8, 2.8), Offset = CFrame.new(0, 0.2, 0), Color = color("#3FE0D0"), Material = Enum.Material.ForceField, Shape = Enum.PartType.Ball },
				{ Attach = "LeftHand", Role = "Mote", Size = Vector3.new(0.6, 0.6, 0.6), Offset = CFrame.new(0, 0, 0), Color = color("#6FF0E2"), Material = Enum.Material.Neon, Shape = Enum.PartType.Ball },
				{ Attach = "RightHand", Role = "Mote", Size = Vector3.new(0.6, 0.6, 0.6), Offset = CFrame.new(0, 0, 0), Color = color("#6FF0E2"), Material = Enum.Material.Neon, Shape = Enum.PartType.Ball },
				{ Attach = "LowerTorso", Role = "Tail", Size = Vector3.new(0.8, 1.6, 0.8), Offset = CFrame.new(0, -0.9, 0), Color = color("#3FE0D0"), Material = Enum.Material.ForceField, Shape = Enum.PartType.Ball },
			},
		},
		Moves = {
			Spit = {
				Kind = "Projectile",
				Weight = 3,
				MinRange = 6,
				MaxRange = 44,
				Telegraph = 0.65,
				Blows = { "Light3" },
				Speed = 50,
				Radius = 1.1,
				Range = 70,
				Damage = 13,
				Posture = 10,
				HitStun = NPC_STUN,
				Parryable = false,
				Blockable = true,
				Recovery = 0.6,
				Cooldown = 0,
			},
			Flare = {
				Kind = "Melee",
				Weight = 2,
				MinRange = 0,
				MaxRange = 7,
				Telegraph = 0.6,
				Blows = { "Light5" },
				Reach = 8,
				Arc = 360,
				Damage = 9,
				Posture = 18,
				HitStun = 0.45,
				Parryable = false,
				Blockable = true,
				Recovery = 0.7,
				Cooldown = 5,
			},
		},
	},

	-- Keepers of the drowned shrines. Their lanterns fling burning tallow and, worse, kindle the
	-- courage of every creature around them: kill the acolyte first.
	LanternAcolyte = {
		Level = 6,
		MaxHealth = 120,
		MaxPosture = 60,
		WalkSpeed = 8,
		RunSpeed = 13,
		AggroRadius = 45,
		KeepAway = 11,
		Rewards = { XP = 70, GoldMin = 5, GoldMax = 11 },
		Body = {
			Scale = 1,
			Skin = color("#A9A08C"),
			Torso = color("#4A3A2C"),
			Arms = color("#55432F"),
			Legs = color("#3A2E24"),
			Extras = {
				{ Attach = "Head", Role = "Hood", Size = Vector3.new(1.45, 1.3, 1.45), Offset = CFrame.new(0, 0.3, 0.1), Color = color("#3A2E24"), Material = Enum.Material.Fabric },
				{ Attach = "LowerTorso", Role = "Robe", Size = Vector3.new(2.2, 2.4, 1.6), Offset = CFrame.new(0, -1.1, 0), Color = color("#4A3A2C"), Material = Enum.Material.Fabric },
				{ Attach = "UpperTorso", Role = "Stole", Size = Vector3.new(0.5, 2.2, 0.25), Offset = CFrame.new(0, -0.2, -0.62), Color = color("#9E3F24"), Material = Enum.Material.Fabric },
				{ Attach = "RightHand", Role = "Lantern", Size = Vector3.new(0.7, 0.9, 0.7), Offset = CFrame.new(0, -0.7, -0.1), Color = color("#FFB45A"), Material = Enum.Material.Neon, Glow = true },
				{ Attach = "RightHand", Role = "LanternCage", Size = Vector3.new(0.85, 0.15, 0.85), Offset = CFrame.new(0, -0.2, -0.1), Color = color("#3D4045"), Material = Enum.Material.Metal },
			},
		},
		Moves = {
			Tallow = {
				Kind = "Projectile",
				Weight = 3,
				MinRange = 6,
				MaxRange = 42,
				Telegraph = 0.7,
				Blows = { "Light3" },
				Speed = 55,
				Radius = 1.2,
				Range = 70,
				Damage = 15,
				Posture = 12,
				HitStun = NPC_STUN,
				Parryable = false,
				Blockable = true,
				Recovery = 0.6,
				Cooldown = 0,
			},
			Kindle = {
				Kind = "Buff",
				Weight = 4,
				MinRange = 0,
				MaxRange = 60,
				Telegraph = 0.9,
				Blows = { "Light5" },
				Radius = 30,
				Damage = 0,
				Posture = 0,
				HitStun = 0,
				Parryable = false,
				Blockable = false,
				Bonus = 0.3,
				Duration = 8,
				Recovery = 0.8,
				Cooldown = 14,
			},
			Shove = {
				Kind = "Melee",
				Weight = 2,
				MinRange = 0,
				MaxRange = 6,
				Telegraph = 0.45,
				Blows = { "Light2" },
				Reach = 6,
				Arc = 120,
				Damage = 7,
				Posture = 20,
				HitStun = 0.45,
				Parryable = true,
				Blockable = true,
				Recovery = 0.5,
				Cooldown = 4,
			},
		},
	},

	-- Rustwood's hunter: bark-skinned, antlered, almost invisible among the red leaves until it
	-- pounces. Fast, two-hit rakes; the pounce is the moment to punish.
	RustwoodStalker = {
		Level = 7,
		MaxHealth = 170,
		MaxPosture = 90,
		WalkSpeed = 10,
		RunSpeed = 20,
		AggroRadius = 30,
		Stealth = true,
		Rewards = { XP = 90, GoldMin = 6, GoldMax = 13 },
		Body = {
			Scale = 1.1,
			Skin = color("#5C3F2C"),
			Torso = color("#4D3A2C"),
			Arms = color("#5C3F2C"),
			Legs = color("#4A3426"),
			Extras = {
				{ Attach = "Head", Role = "Antler", Size = Vector3.new(0.25, 1.6, 0.25), Offset = CFrame.new(-0.45, 1.0, 0) * CFrame.Angles(0, 0, math.rad(25)), Color = color("#3E2C20"), Material = Enum.Material.Wood },
				{ Attach = "Head", Role = "Antler", Size = Vector3.new(0.25, 1.6, 0.25), Offset = CFrame.new(0.45, 1.0, 0) * CFrame.Angles(0, 0, math.rad(-25)), Color = color("#3E2C20"), Material = Enum.Material.Wood },
				{ Attach = "Head", Role = "Eyes", Size = Vector3.new(0.9, 0.15, 0.1), Offset = CFrame.new(0, 0.15, -0.6), Color = color("#FFB45A"), Material = Enum.Material.Neon },
				{ Attach = "UpperTorso", Role = "Mantle", Size = Vector3.new(2.6, 0.8, 1.6), Offset = CFrame.new(0, 0.5, 0.1), Color = color("#B5532C"), Material = Enum.Material.LeafyGrass },
				{ Attach = "RightHand", Role = "Claw", Size = Vector3.new(0.3, 0.3, 1.4), Offset = CFrame.new(0, -0.4, -0.6), Color = color("#2B2A28"), Material = Enum.Material.Slate },
				{ Attach = "LeftHand", Role = "Claw", Size = Vector3.new(0.3, 0.3, 1.4), Offset = CFrame.new(0, -0.4, -0.6), Color = color("#2B2A28"), Material = Enum.Material.Slate },
			},
		},
		Moves = {
			Rake = {
				Kind = "Melee",
				Weight = 3,
				MinRange = 0,
				MaxRange = 8,
				Telegraph = 0.45,
				Blows = { "Light1", "Light2" },
				BlowInterval = 0.35,
				Reach = 7,
				Arc = 120,
				Damage = 12,
				Posture = 10,
				HitStun = NPC_STUN,
				Parryable = true,
				Blockable = true,
				Lunge = 3,
				Recovery = 0.8,
				Cooldown = 0,
			},
			Pounce = {
				Kind = "Melee",
				Weight = 2,
				MinRange = 9,
				MaxRange = 22,
				Telegraph = 0.7,
				Blows = { "Light4" },
				Reach = 7,
				Arc = 80,
				Damage = 22,
				Posture = 20,
				HitStun = 0.5,
				Parryable = true,
				Blockable = true,
				Lunge = 15,
				Recovery = 1.3,
				Cooldown = 5,
			},
			Gore = {
				Kind = "Melee",
				Weight = 1,
				MinRange = 0,
				MaxRange = 7,
				Telegraph = 0.8,
				Blows = { "Heavy" },
				Reach = 7,
				Arc = 70,
				Damage = 24,
				Posture = 26,
				HitStun = 0.55,
				Parryable = false,
				Blockable = true,
				HyperArmor = true,
				Lunge = 3,
				Recovery = 1.2,
				Cooldown = 7,
			},
		},
	},

	-- A pale, segmented thing from the Cistern drains. Its bite drinks blood and Current alike
	-- and heals it; don't trade blows, dodge the latch and strike after.
	CisternLeech = {
		Level = 8,
		MaxHealth = 200,
		MaxPosture = 70,
		WalkSpeed = 7,
		RunSpeed = 12,
		AggroRadius = 26,
		Drain = { Heal = 0.6, Current = 10 },
		Rewards = { XP = 95, GoldMin = 6, GoldMax = 14 },
		Body = {
			Scale = 1,
			Skin = color("#B9B3A6"),
			Torso = color("#B9B3A6"),
			Arms = color("#B9B3A6"),
			Legs = color("#B9B3A6"),
			Creature = true,
			Extras = {
				{ Attach = "UpperTorso", Role = "Segment", Size = Vector3.new(2.2, 2.0, 2.4), Offset = CFrame.new(0, 0, 0), Color = color("#C7C0B0"), Material = Enum.Material.SmoothPlastic, Shape = Enum.PartType.Ball },
				{ Attach = "LowerTorso", Role = "Segment", Size = Vector3.new(2.0, 1.8, 2.2), Offset = CFrame.new(0, -0.4, 0.9), Color = color("#B3AC9C"), Material = Enum.Material.SmoothPlastic, Shape = Enum.PartType.Ball },
				{ Attach = "LeftUpperLeg", Role = "Segment", Size = Vector3.new(1.6, 1.4, 1.8), Offset = CFrame.new(0.4, -0.2, 1.0), Color = color("#A69F8F"), Material = Enum.Material.SmoothPlastic, Shape = Enum.PartType.Ball },
				{ Attach = "RightLowerLeg", Role = "Segment", Size = Vector3.new(1.2, 1.0, 1.4), Offset = CFrame.new(-0.4, 0, 1.0), Color = color("#9A9383"), Material = Enum.Material.SmoothPlastic, Shape = Enum.PartType.Ball },
				{ Attach = "Head", Role = "Maw", Size = Vector3.new(1.5, 1.5, 0.8), Offset = CFrame.new(0, -0.3, -0.5), Color = color("#5A1E22"), Material = Enum.Material.SmoothPlastic, Shape = Enum.PartType.Cylinder },
				{ Attach = "Head", Role = "Glow", Size = Vector3.new(0.5, 0.5, 0.5), Offset = CFrame.new(0, 0.5, -0.4), Color = color("#3FE0D0"), Material = Enum.Material.Neon, Shape = Enum.PartType.Ball, Glow = true },
			},
		},
		Moves = {
			Latch = {
				Kind = "Melee",
				Weight = 3,
				MinRange = 0,
				MaxRange = 7,
				Telegraph = 0.6,
				Blows = { "Light1" },
				Reach = 6,
				Arc = 90,
				Damage = 16,
				Posture = 10,
				HitStun = 0.4,
				Parryable = true,
				Blockable = true,
				Lunge = 4,
				Recovery = 0.9,
				Cooldown = 0,
			},
			Bile = {
				Kind = "Projectile",
				Weight = 1.5,
				MinRange = 7,
				MaxRange = 26,
				Telegraph = 0.75,
				Blows = { "Light3" },
				Speed = 42,
				Radius = 1.4,
				Range = 40,
				Damage = 12,
				Posture = 10,
				HitStun = NPC_STUN,
				Parryable = false,
				Blockable = true,
				Recovery = 0.7,
				Cooldown = 4,
			},
		},
	},

	-- The lagoon's lord: a hulking golem grown into a crab's armour. Its front is a wall of shell;
	-- circle behind it and strike the soft back (WeakPoint) while it recovers from its slams.
	Brinehulk = {
		Level = 9,
		MaxHealth = 900,
		MaxPosture = 260,
		WalkSpeed = 6,
		RunSpeed = 12,
		AggroRadius = 38,
		WeakPoint = { Arc = 110, Damage = 2.0, Posture = 2.0 },
		Rewards = { XP = 320, GoldMin = 30, GoldMax = 55 },
		Body = {
			Scale = 1.7,
			Skin = color("#6E7C78"),
			Torso = color("#3E4A4D"),
			Arms = color("#56656A"),
			Legs = color("#323B3D"),
			Extras = {
				{ Attach = "UpperTorso", Role = "Shell", Size = Vector3.new(3.2, 2.6, 1.8), Offset = CFrame.new(0, 0.4, -0.9), Color = color("#8A4A36"), Material = Enum.Material.Pebble, Shape = Enum.PartType.Ball },
				{ Attach = "UpperTorso", Role = "Barnacle", Size = Vector3.new(0.9, 0.9, 0.9), Offset = CFrame.new(-1.1, 1.0, -1.2), Color = color("#C9C0A8"), Material = Enum.Material.Pebble, Shape = Enum.PartType.Ball },
				{ Attach = "UpperTorso", Role = "Barnacle", Size = Vector3.new(0.7, 0.7, 0.7), Offset = CFrame.new(1.0, 1.1, -1.3), Color = color("#BDB49B"), Material = Enum.Material.Pebble, Shape = Enum.PartType.Ball },
				{ Attach = "UpperTorso", Role = "SoftBack", Size = Vector3.new(1.8, 1.4, 0.4), Offset = CFrame.new(0, 0.2, 0.62), Color = color("#C4706A"), Material = Enum.Material.SmoothPlastic },
				{ Attach = "RightHand", Role = "Claw", Size = Vector3.new(1.4, 1.0, 2.4), Offset = CFrame.new(0, -0.5, -0.8), Color = color("#A4553A"), Material = Enum.Material.Pebble },
				{ Attach = "LeftHand", Role = "Claw", Size = Vector3.new(1.4, 1.0, 2.4), Offset = CFrame.new(0, -0.5, -0.8), Color = color("#A4553A"), Material = Enum.Material.Pebble },
				{ Attach = "Head", Role = "Eyes", Size = Vector3.new(0.9, 0.2, 0.1), Offset = CFrame.new(0, 0.1, -0.6), Color = color("#3FE0D0"), Material = Enum.Material.Neon },
			},
		},
		Moves = {
			Sweep = {
				Kind = "Melee",
				Weight = 3,
				MinRange = 0,
				MaxRange = 12,
				Telegraph = 0.75,
				Blows = { "Light5" },
				Reach = 7,
				Arc = 200,
				Damage = 24,
				Posture = 26,
				HitStun = 0.45,
				Parryable = true,
				Blockable = true,
				Lunge = 1,
				Recovery = 1.1,
				Cooldown = 0,
			},
			Slam = {
				Kind = "Melee",
				Weight = 2,
				MinRange = 0,
				MaxRange = 10,
				Telegraph = 1.0,
				Blows = { "Heavy" },
				Reach = 6,
				Arc = 70,
				Damage = 40,
				Posture = 40,
				HitStun = 0.6,
				Parryable = false,
				Blockable = true,
				HyperArmor = true,
				Lunge = 2,
				Recovery = 1.8,
				Cooldown = 4,
			},
			Charge = {
				Kind = "Melee",
				Weight = 1.5,
				MinRange = 12,
				MaxRange = 26,
				Telegraph = 0.85,
				Blows = { "Light4" },
				Reach = 5,
				Arc = 80,
				Damage = 28,
				Posture = 30,
				HitStun = 0.5,
				Parryable = false,
				Blockable = true,
				HyperArmor = true,
				Lunge = 12,
				Recovery = 1.6,
				Cooldown = 6,
			},
		},
	},

	-- FLOOR 1 GUARDIAN ---------------------------------------------------------------------

	-- The Brinewarden, Keeper of the First Gate: a towering armoured crab-knight (about 20 studs)
	-- with a coral greatsword. Body only: GuardianService spawns it scripted and runs the whole
	-- fight from Shared.Data.Guardians (health, posture, moves, weak points, rewards), so Moves is
	-- empty and Rewards pay nothing here. Its body is the Blender model (MeshBody) once
	-- SpireKit_Guardians is imported, else the placeholder parts above; both keep the role names
	-- the fight uses ("Shell", "Core", "Seam", "Claw", "Helm").
	Brinewarden = {
		Level = 12,
		MaxHealth = 7500, -- nominal; the fight scales it by party size
		MaxPosture = 900,
		WalkSpeed = 10,
		RunSpeed = 17,
		AggroRadius = 200,
		Rewards = { XP = 0, GoldMin = 0, GoldMax = 0 },
		Body = {
			Scale = 3.4,
			Skin = color("#1F2A2C"),
			Torso = color("#1F2A2C"),
			Arms = color("#1F2A2C"),
			Legs = color("#1F2A2C"),
			Creature = true,
			MeshBody = "Brinewarden",
			Extras = BRINEWARDEN_EXTRAS,
		},
		Moves = {},
	},
}

-- Ids used before Phase 9 (saved stats, old spawn points, dev commands) map to their successors.
local ALIASES: { [string]: string } = {
	SaltwornDrifter = "DrownedSailor",
	BarnacledHulk = "Brinehulk",
	BrineAcolyte = "LanternAcolyte",
}

local MobsModule = {}

MobsModule.Aliases = ALIASES

function MobsModule.Get(mobId: string): MobDef?
	return Mobs[mobId] or Mobs[ALIASES[mobId] or ""]
end

-- The current id for a possibly old one.
function MobsModule.Resolve(mobId: string): string
	return if Mobs[mobId] then mobId else (ALIASES[mobId] or mobId)
end

function MobsModule.All(): { [string]: MobDef }
	return Mobs
end

return table.freeze(MobsModule)
