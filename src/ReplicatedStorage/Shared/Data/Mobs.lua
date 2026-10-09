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
