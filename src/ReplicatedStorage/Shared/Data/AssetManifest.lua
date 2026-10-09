--!strict
-- Uploaded asset ids for original textures and audio created for The Spire.
-- Textures are generated into assets/textures by tools/textures/gen_textures.py;
-- upload them with Studio's Asset Manager (Bulk Import) and paste the
-- rbxassetid:// ids here. Ambience loops are generated into assets/audio by
-- tools/audio/gen_ambience.py and are uploaded and pasted the same way.
-- Systems treat an empty id as "not uploaded yet" and fall back to a built-in
-- look (plain glowing water, no ambience loop) instead of erroring.

local AssetManifest = {
	Textures = {
		CurrentFlow = "", -- assets/textures/current_flow.png (seamless, scrolls on canal water)
		CurrentFalls = "", -- assets/textures/current_falls.png (scrolls down waterfall sheets)
	} :: { [string]: string },
	Ambience = {
		TownRain = "",
		Harbor = "",
		Marsh = "",
		Forest = "",
		Highland = "",
		Gate = "",
		Cave = "",
		Dungeon = "",
	} :: { [string]: string },
}

return AssetManifest
