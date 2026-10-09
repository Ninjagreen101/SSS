--!strict
-- Multi-piece assemblies built from single-material kit pieces. Each piece keeps
-- one Roblox material, so composite props (a lantern is iron + glowing glass,
-- a bed is wood + linen) are described here once and reused by every planner.

local Types = require(script.Parent.Parent.Types)

type Assembly = Types.Assembly

local Assemblies: { [string]: Assembly } = {
	street_lantern = {
		parts = {
			{ kit = "lantern_post", x = 0, y = 0, z = 0 },
			{ kit = "lantern_glass", x = 0, y = 7.0, z = -1.6 },
		},
		lights = { { x = 0, y = 7.6, z = -1.6, color = "LanternGlow", range = 22, brightness = 1.6, night = true, attach = 2 } },
		footprint = { 2, 3 },
	},
	wall_lantern = {
		parts = {
			{ kit = "lantern_wall", x = 0, y = 0, z = 0 },
			{ kit = "lantern_glass", x = 0, y = -1.1, z = -1.4 },
		},
		lights = { { x = 0, y = -0.5, z = -1.4, color = "LanternGlow", range = 18, brightness = 1.4, night = true, attach = 2 } },
		footprint = { 1, 2 },
	},
	hanging_lantern = {
		parts = {
			{ kit = "lantern_hanging", x = 0, y = 0, z = 0 },
			{ kit = "lantern_glass", x = 0, y = -3.8, z = 0 },
		},
		lights = { { x = 0, y = -3.2, z = 0, color = "LanternGlow", range = 16, brightness = 1.1, night = false, attach = 2 } },
		footprint = { 1, 1 },
	},
	market_stall = {
		parts = {
			{ kit = "market_stall_frame", x = 0, y = 0, z = 0 },
			{ kit = "market_stall_canopy", x = 0, y = 0, z = 0 },
			{ kit = "crate_s", x = -2.6, y = 3.4, z = -1.2 },
			{ kit = "barrel", x = 2.8, y = 0, z = 1.0 },
		},
		footprint = { 9, 6 },
	},
	bookshelf_full = {
		parts = {
			{ kit = "bookshelf", x = 0, y = 0, z = 0 },
			{ kit = "books", x = 0, y = 0, z = 0 },
		},
		footprint = { 6, 2 },
	},
	bed = {
		parts = {
			{ kit = "bed_frame", x = 0, y = 0, z = 0 },
			{ kit = "bed_linen", x = 0, y = 0, z = 0 },
		},
		footprint = { 4.4, 8 },
	},
	forge = {
		parts = {
			{ kit = "forge_body", x = 0, y = 0, z = 0 },
			{ kit = "forge_coals", x = 0, y = 2.65, z = 0 },
		},
		lights = { { x = 0, y = 3.6, z = 0, color = "Ember", range = 20, brightness = 2.2, night = false, attach = 2 } },
		emitters = { { preset = "ChimneySmoke", x = 0, y = 16.2, z = 1.0 }, { preset = "ForgeEmbers", x = 0, y = 3.4, z = 0 } },
		footprint = { 8, 6 },
	},
	cookpot = {
		parts = {
			{ kit = "cooking_pot", x = 0, y = 0, z = 0 },
			{ kit = "cookfire", x = 0, y = 0, z = 0 },
		},
		lights = { { x = 0, y = 1.0, z = 0, color = "Ember", range = 14, brightness = 1.6, night = false, attach = 2 } },
		emitters = { { preset = "CampfireFlame", x = 0, y = 0.5, z = 0 } },
		footprint = { 4, 4 },
	},
	potted_plant = {
		parts = {
			{ kit = "potted_plant_pot", x = 0, y = 0, z = 0 },
			{ kit = "potted_plant_leaves", x = 0, y = 0, z = 0 },
		},
		footprint = { 2.4, 2.4 },
	},
	weapon_rack_full = {
		parts = {
			{ kit = "weapon_rack", x = 0, y = 0, z = 0 },
			{ kit = "weapon_set", x = 0, y = 0, z = 0 },
		},
		footprint = { 6, 1.6 },
	},
	well = {
		parts = {
			{ kit = "well_base", x = 0, y = 0, z = 0 },
			{ kit = "well_roof", x = 0, y = 0, z = 0 },
		},
		footprint = { 7.5, 7.5 },
	},
	statue = {
		parts = {
			{ kit = "statue_plinth", x = 0, y = 0, z = 0 },
			{ kit = "statue_climber", x = 0, y = 5.7, z = 0 },
		},
		footprint = { 7.5, 7.5 },
	},
	waystone = {
		parts = {
			{ kit = "waystone", x = 0, y = 0, z = 0 },
			{ kit = "waystone_runes", x = 0, y = 0, z = 0 },
			{ kit = "waystone_ring", x = 0, y = 8.0, z = 0 },
		},
		lights = { { x = 0, y = 6.0, z = 0, color = "CurrentTeal", range = 26, brightness = 2.2, night = false, attach = 3 } },
		emitters = { { preset = "WaystoneMotes", x = 0, y = 4, z = 0 } },
		footprint = { 10, 10 },
	},
	hanging_sign = {
		parts = {
			{ kit = "sign_bracket", x = 0, y = 0, z = 0 },
			{ kit = "sign_board", x = 0, y = 0.1, z = -2.6, ry = math.pi / 2 },
		},
		footprint = { 1, 4 },
	},
	ship = {
		parts = {
			{ kit = "ship_hull", x = 0, y = 0, z = 0 },
			{ kit = "ship_mast", x = 0, y = 9.5, z = -14 },
			{ kit = "ship_sail", x = 0, y = 9.5, z = -14 },
			{ kit = "ship_mast", x = 0, y = 9.5, z = 4 },
			{ kit = "ship_sail", x = 0, y = 9.5, z = 4 },
		},
		lights = { { x = 0, y = 17.5, z = 29.8, color = "LanternGlow", range = 24, brightness = 1.8, night = true } },
		footprint = { 16, 76 },
	},
	camp = {
		parts = {
			{ kit = "tent", x = 0, y = 0, z = 0 },
			{ kit = "cooking_pot", x = 0, y = 0, z = -9 },
			{ kit = "cookfire", x = 0, y = 0, z = -9 },
			{ kit = "log_fallen", x = 6, y = 0, z = -9, ry = math.pi / 2 },
			{ kit = "crate_s", x = -5, y = 0, z = -2 },
		},
		lights = { { x = 0, y = 1.2, z = -9, color = "Ember", range = 22, brightness = 1.8, night = false } },
		emitters = { { preset = "CampfireFlame", x = 0, y = 0.5, z = -9 } },
		footprint = { 16, 20 },
	},
	treasure_chest = {
		parts = { { kit = "chest", x = 0, y = 0, z = 0 } },
		lights = { { x = 0, y = 3.2, z = 0, color = "Gold", range = 10, brightness = 0.8, night = false, attach = 1 } },
		emitters = { { preset = "TreasureGlint", x = 0, y = 2.2, z = 0 } },
		footprint = { 3.5, 2.5 },
	},
	valve = {
		parts = { { kit = "valve_wheel", x = 0, y = 4, z = 0 } },
		lights = { { x = 0, y = 4, z = -1.5, color = "CurrentTeal", range = 10, brightness = 1.2, night = false, attach = 1 } },
		footprint = { 3.5, 2 },
	},
}

return Assemblies
