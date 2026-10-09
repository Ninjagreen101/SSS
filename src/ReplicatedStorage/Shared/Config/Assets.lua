--!strict
--[[
	Asset ids in one place so swapping to final uploaded audio/images is a
	one-line change. UI sounds currently use sounds that ship inside the Roblox
	client (rbxasset://), which are legal to use; replace them with original
	uploads during the audio polish pass (Phase 15).
]]

local TableUtil = require(script.Parent.Parent.Util.TableUtil)

return TableUtil.DeepFreeze({
	-- UI sprite sheets (StarterPlayerScripts/UI/Icons maps every icon and
	-- effect to its rectangle). White shapes on transparency, tinted in game.
	UI = {
		IconSheet = "rbxassetid://137769721909628", -- SpireIcons.png (1024 x 1024)
		FxSheet = "rbxassetid://70686210867423", -- SpireWaterFX.png (512 x 512)
	},

	Sounds = {
		UIClick = { Id = "rbxasset://sounds/clickfast.wav", Volume = 0.35, Pitch = 1.1 },
		UIOpen = { Id = "rbxasset://sounds/switch.wav", Volume = 0.22, Pitch = 1.25 },
		UIClose = { Id = "rbxasset://sounds/switch.wav", Volume = 0.18, Pitch = 0.9 },
		UIConfirm = { Id = "rbxasset://sounds/switch.wav", Volume = 0.4, Pitch = 1.0 },
		UIError = { Id = "rbxasset://sounds/electronicpingshort.wav", Volume = 0.3, Pitch = 0.6 },
		UIToast = { Id = "rbxasset://sounds/electronicpingshort.wav", Volume = 0.22, Pitch = 1.4 },
		-- Items (Phase 7): built-in client sounds until the audio pass.
		ItemEquip = { Id = "rbxasset://sounds/unsheath.wav", Volume = 0.35, Pitch = 0.8 }, -- the equip clunk
		ItemPickup = { Id = "rbxasset://sounds/clickfast.wav", Volume = 0.25, Pitch = 1.5 },
		GoldPickup = { Id = "rbxasset://sounds/clickfast.wav", Volume = 0.3, Pitch = 2.1 },
		RareLoot = { Id = "rbxasset://sounds/electronicpingshort.wav", Volume = 0.35, Pitch = 1.9 }, -- the sparkle
		LegendaryLoot = { Id = "rbxasset://sounds/electronicpingshort.wav", Volume = 0.5, Pitch = 1.2 },
		CraftDone = { Id = "rbxasset://sounds/electronicpingshort.wav", Volume = 0.4, Pitch = 1.55 },
		UpgradeSuccess = { Id = "rbxasset://sounds/unsheath.wav", Volume = 0.45, Pitch = 1.25 },
		UpgradeFail = { Id = "rbxasset://sounds/switch.wav", Volume = 0.45, Pitch = 0.45 },
		ItemUse = { Id = "rbxasset://sounds/switch.wav", Volume = 0.3, Pitch = 1.6 },
		-- Progression (Phase 8): the level-up chime is two rising notes.
		LevelUp = { Id = "rbxasset://sounds/electronicpingshort.wav", Volume = 0.5, Pitch = 1.0 },
		LevelUpHigh = { Id = "rbxasset://sounds/electronicpingshort.wav", Volume = 0.5, Pitch = 1.5 },
		SkillUnlock = { Id = "rbxasset://sounds/electronicpingshort.wav", Volume = 0.35, Pitch = 1.75 },
	},

	-- Animation ids ("rbxassetid://123" or just "123"). Empty = no animation:
	-- combat still works, the character just doesn't swing visibly.
	-- Roblox only plays animations owned by this experience's owner, so these
	-- must be made or re-published under your own account (see PHASE_3_REPORT).
	-- Light1..5 = combo swings (classes with shorter combos use the first N).
	Animations = {
		Classes = {
			-- Published from ServerStorage.SpireLongswordAnimations (Mixamo, retargeted). Other classes
			-- borrow these until they get their own clips (CombatController retimes them to their windup).
			Longsword = {
				Light1 = "131509060751065",
				Light2 = "79088972739632",
				Light3 = "107802146649111",
				Light4 = "103859441615484",
				Light5 = "106227419936817",
				Heavy = "113688050118899",
				HeavyCharge = "100961120022350",
			},
			Greatblade = { Light1 = "", Light2 = "", Light3 = "", Light4 = "", Light5 = "", Heavy = "", HeavyCharge = "" },
			Twinfangs = { Light1 = "", Light2 = "", Light3 = "", Light4 = "", Light5 = "", Heavy = "", HeavyCharge = "" },
			SpireLance = { Light1 = "", Light2 = "", Light3 = "", Light4 = "", Light5 = "", Heavy = "", HeavyCharge = "" },
			Needle = { Light1 = "", Light2 = "", Light3 = "", Light4 = "", Light5 = "", Heavy = "", HeavyCharge = "" },
			Arcblade = { Light1 = "", Light2 = "", Light3 = "", Light4 = "", Light5 = "", Heavy = "", HeavyCharge = "" },
		},
		Common = {
			Dodge = "76707284471909", -- forward roll, 0.4 s, in place
			Block = "86916990544880", -- looping guard pose
			Parry = "", -- raising the guard (Block) doubles as the parry visual
			Hurt = "75804663710962",
			Broken = "118210218670630", -- stagger when posture breaks
		},
		-- Locomotion layered over Roblox's default walk/run (Movement priority).
		Movement = {
			Sprint = "131745505124578", -- looping run, played by CharacterController while sprinting
		},
		-- Phase 6 clips, published from ServerStorage.SpirePhase6Animations (Mixamo,
		-- retargeted). Any slot left empty falls back to
		-- the sword clip each Form / move names (FallbackAnimation), retimed.
		Casting = {
			Cast1H = "84573079313845", -- one-handed cast: Bolt, Wave, Ward
			Cast2H = "70622263525380", -- two-handed cast: Lance release, Well
			CastCharge = "127560867986668", -- looping hold while a Lance charges
			Infuse = "114080599916174", -- charging the blade (Infusion)
		},
		-- When a Casting clip's spell leaves the hand (seconds into the clip). The
		-- clip is sped up or slowed so that moment lands on the spell's cast time.
		CastingContact = {
			Cast1H = 0.25,
			Cast2H = 0.40,
		},
		-- Weapon Arts, one per class (Shared/Data/Arts).
		Arts = {
			Longsword = "115236055187770",
			Greatblade = "96581271196289",
			Twinfangs = "94349119078405",
			SpireLance = "85727402460886",
			Needle = "83975632951295",
			Arcblade = "80384371283740",
		},
		-- Confluence motions, one per class; the Attunement changes the effects.
		Confluences = {
			Longsword = "84125965830078",
			Greatblade = "77067417306480",
			Twinfangs = "95146075266339",
			SpireLance = "106865712303964",
			Needle = "125644014271986",
			Arcblade = "90644909081799",
		},
		-- Position abilities (Shared/Data/Abilities). Empty = the move's sword
		-- clip (FallbackAnimation) is borrowed until a clip is uploaded.
		Abilities = {
			Seawall = "",
			HarborBell = "",
			Keelbreaker = "",
			Glintstorm = "",
			RiptideLunge = "",
			Severance = "",
			Floodtide = "",
			Maelstrom = "",
			CatalystPulse = "",
			Kindle = "",
			Tidewell = "",
			GuidingLantern = "",
			Windstep = "",
			Tanglewire = "",
			ExposeWeakness = "",
		},
	},
})
