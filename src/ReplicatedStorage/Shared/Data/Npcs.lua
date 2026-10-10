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

local function color(hex: string): Color3
	return Color3.fromHex(hex)
end

-- One welded detail part.
local function part(attach: string, role: string, size: Vector3, offset: CFrame, tint: string, material: Enum.Material, shape: Enum.PartType?, glow: boolean?): Mobs.BodyPart
	return { Attach = attach, Role = role, Size = size, Offset = offset, Color = color(tint), Material = material, Shape = shape, Glow = glow }
end

local function v(x: number, y: number, z: number): Vector3
	return Vector3.new(x, y, z)
end

local Npcs: { [string]: NpcDef } = {
	-- Brannoc Hale, Dockmaster: weathered oilskin coat, peaked cap, brass lantern on his belt.
	Brannoc = {
		Floor = "1",
		Look = {
			Scale = 1.05, Skin = color("#B58A6A"), Torso = color("#2F4452"), Arms = color("#2F4452"), Legs = color("#3A3A3A"),
			Extras = {
				part("Head", "Cap", v(1.5, 0.35, 1.5), CFrame.new(0, 0.7, 0), "#1E2A33", Enum.Material.Fabric),
				part("Head", "CapPeak", v(1.2, 0.12, 0.6), CFrame.new(0, 0.55, -0.85), "#1E2A33", Enum.Material.Fabric),
				part("UpperTorso", "Coat", v(2.3, 1.3, 1.3), CFrame.new(0, -0.15, 0), "#3E5C6B", Enum.Material.Fabric),
				part("LowerTorso", "Skirt", v(2.2, 1.2, 1.25), CFrame.new(0, -0.4, 0), "#3E5C6B", Enum.Material.Fabric),
				part("LowerTorso", "Belt", v(2.1, 0.25, 1.15), CFrame.new(0, 0.2, 0), "#5A3A22", Enum.Material.Leather),
				part("LowerTorso", "Lantern", v(0.5, 0.7, 0.5), CFrame.new(1.2, -0.1, 0), "#FFC76B", Enum.Material.Neon, nil, true),
			},
		},
		Behaviour = "Stand",
		Gives = { "F1_M01", "F1_M02", "F1_S01" },
		Voice = 0.85,
	},
	-- Warden Ysolde Tarn: guild captain in a pale-grey cloak and shoulder plate with a tide-teal sash.
	Ysolde = {
		Floor = "1",
		Look = {
			Scale = 1.05, Skin = color("#C9A98E"), Torso = color("#3B4A5A"), Arms = color("#3B4A5A"), Legs = color("#2C3440"),
			Extras = {
				part("UpperTorso", "Cloak", v(2.4, 2.6, 0.3), CFrame.new(0, -0.6, 0.75), "#8E9AA6", Enum.Material.Fabric),
				part("RightUpperArm", "Pauldron", v(1.5, 0.6, 1.5), CFrame.new(0, 0.4, 0), "#A9B2BC", Enum.Material.Metal),
				part("LeftUpperArm", "Pauldron", v(1.5, 0.6, 1.5), CFrame.new(0, 0.4, 0), "#A9B2BC", Enum.Material.Metal),
				part("UpperTorso", "Sash", v(2.1, 0.35, 1.25), CFrame.new(0, 0.1, 0) * CFrame.Angles(0, 0, math.rad(25)), "#3FE0D0", Enum.Material.Fabric),
				part("Head", "Circlet", v(1.3, 0.12, 1.3), CFrame.new(0, 0.6, 0), "#C9B37E", Enum.Material.Metal),
				part("LowerTorso", "Sword", v(0.25, 0.25, 3.2), CFrame.new(-1.1, -0.2, 0.3), "#C9CED6", Enum.Material.Metal),
				part("RightHand", "Seal", v(0.5, 0.5, 0.15), CFrame.new(0, 0, -0.4), "#3FE0D0", Enum.Material.Neon, Enum.PartType.Ball, true),
			},
		},
		Behaviour = "Stand",
		Gives = { "F1_M03", "F1_M04", "F1_M05", "F1_M06", "F1_M08", "F1_M09", "F1_M11", "F1_M12" },
		Voice = 1.0,
	},
	-- Old Pell: one-eyed net-mender, slumped, with a patch, a draped net and a bone needle.
	Pell = {
		Floor = "1",
		Look = {
			Scale = 0.95, Skin = color("#A07C5E"), Torso = color("#5A5242"), Arms = color("#5A5242"), Legs = color("#3B3A33"),
			Extras = {
				part("Head", "EyePatch", v(0.45, 0.4, 0.1), CFrame.new(0.3, 0.1, -0.65), "#141414", Enum.Material.Leather),
				part("Head", "Hat", v(1.6, 0.3, 1.6), CFrame.new(0, 0.65, 0), "#6B5A3A", Enum.Material.Fabric),
				part("UpperTorso", "Net", v(2.4, 0.5, 1.5), CFrame.new(0, 0.5, 0) * CFrame.Angles(0, 0, math.rad(-12)), "#8A8068", Enum.Material.Fabric),
				part("LowerTorso", "NetPile", v(1.8, 0.6, 1.2), CFrame.new(0.9, -1.1, -0.2), "#7A7058", Enum.Material.Fabric),
				part("RightHand", "Needle", v(0.1, 0.1, 1.4), CFrame.new(0, 0, -0.6), "#E7E0CF", Enum.Material.SmoothPlastic),
			},
		},
		Behaviour = "Work",
		Gives = { "F1_S02" },
		Voice = 0.8,
	},
	-- Ilse Marrow: Archivist in ink-blue robes with a spectacle chain and a heavy book.
	Ilse = {
		Floor = "1",
		Look = {
			Scale = 1.0, Skin = color("#D2B8A0"), Torso = color("#2B3350"), Arms = color("#2B3350"), Legs = color("#232A40"),
			Extras = {
				part("LowerTorso", "Robe", v(2.3, 2.0, 1.3), CFrame.new(0, -0.9, 0), "#2B3350", Enum.Material.Fabric),
				part("Head", "Spectacles", v(1.1, 0.25, 0.1), CFrame.new(0, 0.1, -0.65), "#C9B37E", Enum.Material.Metal),
				part("Head", "Hair", v(1.3, 0.6, 1.3), CFrame.new(0, 0.55, 0.1), "#B8B8C0", Enum.Material.Fabric, Enum.PartType.Ball),
				part("LeftHand", "Book", v(0.9, 0.2, 1.2), CFrame.new(0, 0.1, -0.5), "#5A2C3A", Enum.Material.Leather),
				part("UpperTorso", "Stole", v(0.6, 2.0, 1.35), CFrame.new(0, -0.1, 0), "#C9B37E", Enum.Material.Fabric),
				part("Head", "Quill", v(0.12, 1.2, 0.12), CFrame.new(-0.7, 0.9, 0.1) * CFrame.Angles(0, 0, math.rad(20)), "#E9E4D4", Enum.Material.SmoothPlastic),
			},
		},
		Behaviour = "Stand",
		Gives = { "F1_M10", "F1_S03" },
		Voice = 1.15,
	},
	-- Tobin Quill: plump provisioner, green apron, ledger and a pack on his back.
	Tobin = {
		Floor = "1",
		Look = {
			Scale = 1.0, Skin = color("#C49A78"), Torso = color("#6F5A3E"), Arms = color("#6F5A3E"), Legs = color("#4A3E2E"),
			Extras = {
				part("UpperTorso", "Apron", v(2.1, 2.4, 0.2), CFrame.new(0, -0.5, -0.7), "#5C7A3E", Enum.Material.Fabric),
				part("UpperTorso", "Pack", v(1.8, 1.8, 0.9), CFrame.new(0, 0, 1.0), "#7A5A34", Enum.Material.Leather),
				part("UpperTorso", "Bedroll", v(2.0, 0.55, 0.55), CFrame.new(0, 1.2, 1.0), "#A98E62", Enum.Material.Fabric),
				part("Head", "Beret", v(1.6, 0.3, 1.6), CFrame.new(0.15, 0.65, 0), "#8A3A2E", Enum.Material.Fabric),
				part("LeftHand", "Ledger", v(0.8, 0.15, 1.0), CFrame.new(0, 0.1, -0.5), "#3A2A1E", Enum.Material.Leather),
			},
		},
		Behaviour = "Stand",
		Gives = { "F1_S04" },
		Voice = 1.1,
	},
	-- Sister Caddith: hooded white habit with a candle-lit censer.
	Caddith = {
		Floor = "1",
		Look = {
			Scale = 1.0, Skin = color("#D8C2AE"), Torso = color("#D9D4C6"), Arms = color("#D9D4C6"), Legs = color("#BDB8A8"),
			Extras = {
				part("Head", "Hood", v(1.8, 1.7, 1.8), CFrame.new(0, 0.15, 0.1), "#D9D4C6", Enum.Material.Fabric, Enum.PartType.Ball),
				part("LowerTorso", "Habit", v(2.3, 2.0, 1.35), CFrame.new(0, -0.9, 0), "#D9D4C6", Enum.Material.Fabric),
				part("UpperTorso", "Scapular", v(1.6, 2.6, 1.4), CFrame.new(0, -0.5, 0), "#3E5C6B", Enum.Material.Fabric),
				part("RightHand", "Censer", v(0.6, 0.6, 0.6), CFrame.new(0, -0.8, 0), "#C9B37E", Enum.Material.Metal, Enum.PartType.Ball),
				part("RightHand", "CenserFlame", v(0.3, 0.3, 0.3), CFrame.new(0, -0.8, 0), "#FFD98A", Enum.Material.Neon, Enum.PartType.Ball, true),
				part("UpperTorso", "Pendant", v(0.4, 0.5, 0.1), CFrame.new(0, 0.3, -0.72), "#3FE0D0", Enum.Material.Neon, nil, true),
			},
		},
		Behaviour = "Stand",
		Gives = { "F1_S05" },
		Voice = 1.2,
	},
	-- Captain Maren Dusk: Watch breastplate, red-dark cloak and a round shield.
	Maren = {
		Floor = "1",
		Look = {
			Scale = 1.1, Skin = color("#9A7458"), Torso = color("#4A3030"), Arms = color("#4A3030"), Legs = color("#2E2E34"),
			Extras = {
				part("UpperTorso", "Breastplate", v(2.2, 1.6, 1.3), CFrame.new(0, 0, 0), "#7E8794", Enum.Material.Metal),
				part("Head", "Helm", v(1.5, 0.8, 1.5), CFrame.new(0, 0.45, 0), "#7E8794", Enum.Material.Metal),
				part("Head", "Crest", v(0.2, 0.6, 1.2), CFrame.new(0, 1.0, 0), "#8A2E2E", Enum.Material.Fabric),
				part("UpperTorso", "Cloak", v(2.3, 2.6, 0.25), CFrame.new(0, -0.6, 0.75), "#6A2A2A", Enum.Material.Fabric),
				part("LeftLowerArm", "Shield", v(0.3, 2.0, 2.0), CFrame.new(-0.4, 0, -0.3), "#5A5F6A", Enum.Material.Metal, Enum.PartType.Cylinder),
				part("LowerTorso", "Spear", v(0.2, 0.2, 5.5), CFrame.new(1.3, 0, 0), "#7A5A34", Enum.Material.Wood),
			},
		},
		Behaviour = "Stand",
		Gives = { "F1_M07", "F1_S06", "F1_S07" },
		Voice = 0.8,
	},
	-- Reedwarden Osk: reed-green marsh cloak, tall hat and a hooded lamp on a pole.
	Osk = {
		Floor = "1",
		Look = {
			Scale = 1.05, Skin = color("#8E6C50"), Torso = color("#4A5A34"), Arms = color("#4A5A34"), Legs = color("#38422A"),
			Extras = {
				part("Head", "ReedHat", v(2.2, 0.2, 2.2), CFrame.new(0, 0.6, 0), "#B9A560", Enum.Material.Fabric, Enum.PartType.Cylinder),
				part("Head", "HatCrown", v(1.2, 0.7, 1.2), CFrame.new(0, 0.9, 0), "#B9A560", Enum.Material.Fabric),
				part("UpperTorso", "ReedCloak", v(2.4, 2.8, 0.3), CFrame.new(0, -0.6, 0.75), "#6F8A3E", Enum.Material.Grass),
				part("RightHand", "Pole", v(0.15, 0.15, 5.0), CFrame.new(0, 0, 0), "#6B4A2C", Enum.Material.Wood),
				part("RightHand", "Lamp", v(0.6, 0.8, 0.6), CFrame.new(0, 0, -2.4), "#7FE8D0", Enum.Material.Neon, nil, true),
			},
		},
		Behaviour = "Stand",
		Gives = { "F1_S08" },
		Voice = 0.9,
	},
	-- Hesk Thornwell: rusty-brown forester, longbow, quiver and a hide hood.
	Hesk = {
		Floor = "1",
		Look = {
			Scale = 1.05, Skin = color("#A8795A"), Torso = color("#6A4A2C"), Arms = color("#6A4A2C"), Legs = color("#4A3A2A"),
			Extras = {
				part("Head", "Hood", v(1.7, 1.3, 1.7), CFrame.new(0, 0.3, 0.1), "#5A3A22", Enum.Material.Leather, Enum.PartType.Ball),
				part("UpperTorso", "Quiver", v(0.6, 1.8, 0.6), CFrame.new(0.3, 0.2, 0.9) * CFrame.Angles(0, 0, math.rad(15)), "#4A3220", Enum.Material.Leather),
				part("UpperTorso", "Arrows", v(0.5, 0.5, 0.5), CFrame.new(0.5, 1.3, 0.9), "#C9B37E", Enum.Material.Wood),
				part("LeftHand", "Bow", v(0.15, 3.6, 0.5), CFrame.new(0, 0, -0.4), "#8A5A2C", Enum.Material.Wood),
				part("UpperTorso", "Bracer", v(2.1, 0.3, 1.2), CFrame.new(0, -0.7, 0), "#8A3E22", Enum.Material.Leather),
				part("RightLowerLeg", "Boots", v(1.1, 1.0, 1.2), CFrame.new(0, -0.6, 0), "#3A2A1E", Enum.Material.Leather),
			},
		},
		Behaviour = "Stand",
		Gives = { "F1_S09" },
		Voice = 0.9,
	},
	-- Fen: a small canal urchin with an oversized coat, a glowing jar and a scrap net.
	Fen = {
		Floor = "1",
		Look = {
			Scale = 0.75, Skin = color("#B58E72"), Torso = color("#7A6A58"), Arms = color("#7A6A58"), Legs = color("#4A4036"),
			Extras = {
				part("UpperTorso", "BigCoat", v(2.5, 1.6, 1.4), CFrame.new(0, -0.3, 0), "#5A6A5C", Enum.Material.Fabric),
				part("Head", "Cap", v(1.5, 0.4, 1.5), CFrame.new(0, 0.65, 0.1), "#3E5C6B", Enum.Material.Fabric),
				part("RightHand", "Jar", v(0.6, 0.8, 0.6), CFrame.new(0, -0.5, 0), "#3FE0D0", Enum.Material.Glass, Enum.PartType.Cylinder, true),
				part("LeftHand", "ScrapNet", v(0.15, 2.6, 0.15), CFrame.new(0, 0, -0.3), "#6B4A2C", Enum.Material.Wood),
				part("LeftHand", "NetHoop", v(1.2, 0.12, 1.2), CFrame.new(0, 1.4, -0.3), "#8A8068", Enum.Material.Fabric, Enum.PartType.Cylinder),
				part("Head", "Scarf", v(1.4, 0.4, 1.4), CFrame.new(0, -0.7, 0), "#A64A3A", Enum.Material.Fabric),
			},
		},
		Behaviour = "Route",
		PauseSeconds = 3,
		Gives = { "F1_S10" },
		Voice = 1.3,
	},
}


local NpcsModule = {}

function NpcsModule.Get(id: string): NpcDef?
	return Npcs[id]
end

function NpcsModule.All(): { [string]: NpcDef }
	return Npcs
end

return table.freeze(NpcsModule)
