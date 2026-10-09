--!strict
--[[
	WildBuilder (edit-time tool)
	Everything outside the town walls, driven by the layout's data tables:

	  SecretTerrain(L)        carve the hidden areas into the terrain (run after FloorBuilder)
	  Waystones(L, parent)    the floor's Waystones (FloorService reads tag Waystone + WaystoneId)
	  Spawns(L)               enemy spawn points in Workspace.MobSpawns (MobService attributes)
	  Pressure(L)             Current Pressure zones in Workspace.PressureZones
	  Secrets(L, parent)      discovery volumes (SpireSecret), caches (SpireCache), shrines, crystals
	  Scatter(L, parent, seed, ruleIndex?)   trees, rocks and plants per region (Layout.Scatter)
	  OldWharf(L, parent)     the derelict wharf: broken piers, a wreck, rubble, dead lanterns
	  CisternEntrance(L, parent)  the ruined basin and the stair down into the Sunken Cistern

	Heights come from the layout's Height(x, z) (the same function that wrote the terrain), so
	nothing needs raycasts and the tool runs in Edit mode. Usage:
	    local WB = require(game.ServerStorage.Tools.WildBuilder)
	    local L = require(game.ServerStorage.Tools.Layouts.Floor1)
	    WB.All(L, workspace.Floor1)
]]

local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")

local Kit = require(script.Parent.KitLibrary)
local Floor1 = require(script.Parent.Layouts.Floor1)

type Layout = typeof(Floor1)

local WildBuilder = {}

local CURRENT = Color3.fromHex("#3FE0D0")

-- Dark-fantasy palettes: dried-blood rusts, bog greens and near-black pines. Kept desaturated so
-- the teal Current glow (fungus, anemones, water) is the brightest thing in the wilds.
local LEAF_PALETTES: { [string]: { Color3 } } = {
	Rustwood = { Color3.fromHex("#6A2A1C"), Color3.fromHex("#5A2418"), Color3.fromHex("#7A3420"), Color3.fromHex("#4E2016"),
		Color3.fromHex("#6E3A24") },
	Marshroot = { Color3.fromHex("#33402A"), Color3.fromHex("#2C3826"), Color3.fromHex("#3A4630") },
	Spirepine = { Color3.fromHex("#1C2C2A"), Color3.fromHex("#203430"), Color3.fromHex("#182624") },
}

-- Sea life that grows underwater (Kelp must be submerged; the rest may also sit on the shore).
local AQUATIC: { [string]: "Submerged" | "Either" } = {
	Kelp_Tall = "Submerged",
	Coral_Branch = "Either",
	Coral_Fan = "Either",
	Anemone_Glow = "Either",
	Barnacles = "Either",
}

-- HELPERS ------------------------------------------------------------------------------------

local function folder(parent: Instance, name: string): Folder
	local f = parent:FindFirstChild(name)
	if f and f:IsA("Folder") then
		return f
	end
	local n = Instance.new("Folder")
	n.Name = name
	n.Parent = parent
	return n
end

local function fresh(parent: Instance, name: string): Folder
	local old = parent:FindFirstChild(name)
	if old then
		old:Destroy()
	end
	return folder(parent, name)
end

local function ground(L: Layout, x: number, z: number): Vector3
	return Vector3.new(x, L.Height(x, z), z)
end

local function slopeAt(L: Layout, x: number, z: number): number
	local dx = L.Height(x + 2, z) - L.Height(x - 2, z)
	local dz = L.Height(x, z + 2) - L.Height(x, z - 2)
	return math.deg(math.atan(math.sqrt(dx * dx + dz * dz) / 4))
end

local function invisiblePart(name: string, size: Vector3, cf: CFrame, parent: Instance): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Transparency = 1
	p.CastShadow = false
	p.Size = size
	p.CFrame = cf
	p.Parent = parent
	return p
end

local function material(name: string): Enum.Material
	local ok, value = pcall(function(): Enum.Material
		return (Enum.Material :: any)[name]
	end)
	return if ok and value then value else Enum.Material.Ground
end

-- SECRET TERRAIN -------------------------------------------------------------------------------

function WildBuilder.SecretTerrain(L: Layout): number
	local terrain = Workspace.Terrain
	local n = 0
	for _, secret in L.Secrets do
		for _, op in secret.Terrain do
			local m = material(op.Material)
			local at = Vector3.new(op.X, op.Y, op.Z)
			if op.Op == "Ball" then
				terrain:FillBall(at, op.R or 8, m)
			elseif op.Op == "Cylinder" then
				terrain:FillCylinder(CFrame.new(at), op.H or 8, op.R or 8, m)
			elseif op.Op == "Block" then
				terrain:FillBlock(CFrame.new(at), Vector3.new(op.SX or 8, op.SY or 4, op.SZ or 8), m)
			end
			n += 1
		end
	end
	return n
end

-- WAYSTONES ------------------------------------------------------------------------------------

function WildBuilder.Waystones(L: Layout, parent: Instance): number
	local root = fresh(parent, "Waystones")
	for _, spot in L.Waystones do
		local base = ground(L, spot.At.X, spot.At.Y)
		local model = Instance.new("Model")
		model.Name = spot.Id
		model:SetAttribute("WaystoneId", spot.Id)
		if spot.Default then
			model:SetAttribute("DefaultWaystone", true)
		end
		-- face the dais toward the floor centre-ish so the spawn point sits on the near side
		local cf = CFrame.lookAt(base, base + Vector3.new(-spot.At.X, 0, -spot.At.Y).Unit)
		Kit.Place("Waystone_Base", cf, model, { Flatten = true })
		local crystalAt = Kit.Anchor("Waystone_Base", "Crystal")
		local crystal = Instance.new("Part")
		crystal.Name = "Crystal"
		crystal.Anchored = true
		crystal.CanCollide = false
		crystal.Material = Enum.Material.Neon
		crystal.Color = CURRENT
		crystal.Size = Vector3.new(1.6, 3.2, 1.6)
		crystal.CFrame = cf * CFrame.new(crystalAt or Vector3.new(0, 7, 0)) * CFrame.Angles(0, math.rad(45), 0)
		crystal.CastShadow = false
		crystal.Parent = model
		local light = Instance.new("PointLight")
		light.Color = CURRENT
		light.Range = 18
		light.Brightness = 1.2
		light.Parent = crystal
		CollectionService:AddTag(crystal, "WaystoneCrystal")
		local spawnAt = Kit.Anchor("Waystone_Base", "Spawn")
		local spawnPoint = invisiblePart("SpawnPoint", Vector3.new(2, 1, 2), cf * CFrame.new(spawnAt or Vector3.new(0, 0, 8.5)), model)
		spawnPoint.CFrame = spawnPoint.CFrame + Vector3.new(0, 0.5, 0)
		model.PrimaryPart = crystal
		model.WorldPivot = cf
		model.Parent = root
		CollectionService:AddTag(model, "Waystone")
	end
	return #L.Waystones
end

-- SPAWNS AND PRESSURE ----------------------------------------------------------------------------

function WildBuilder.Spawns(L: Layout): number
	local root = fresh(Workspace, "MobSpawns")
	for i, spot in L.Spawns do
		local at = ground(L, spot.At.X, spot.At.Y)
		local p = invisiblePart(`{spot.Mob}_{i}`, Vector3.new(4, 1, 4), CFrame.new(at + Vector3.new(0, 1, 0)), root)
		p:SetAttribute("MobId", spot.Mob)
		p:SetAttribute("SpawnCount", spot.Count)
		p:SetAttribute("PatrolRadius", spot.Patrol)
		p:SetAttribute("RespawnTime", spot.Respawn)
		p:SetAttribute("Zone", spot.Zone)
		if spot.Elite then
			p:SetAttribute("Elite", true)
		end
		if spot.NightOnly then
			p:SetAttribute("NightOnly", true)
		end
	end
	return #L.Spawns
end

function WildBuilder.Pressure(L: Layout): number
	local root = fresh(Workspace, "PressureZones")
	for _, zone in L.PressureZones do
		local p = invisiblePart(zone.Name, Vector3.new(zone.Size.X, 700, zone.Size.Y), CFrame.new(zone.At.X, 150, zone.At.Y), root)
		p:SetAttribute("Pressure", zone.Pressure)
		CollectionService:AddTag(p, "PressureZone")
	end
	return #L.PressureZones
end

-- SECRETS ------------------------------------------------------------------------------------------

function WildBuilder.Secrets(L: Layout, parent: Instance): number
	local root = fresh(parent, "Secrets")
	for _, secret in L.Secrets do
		local holder = Instance.new("Model")
		holder.Name = secret.Id
		holder.Parent = root
		local t = secret.Trigger
		local trigger = invisiblePart("Discovery", Vector3.new(t[4], t[4], t[4]), CFrame.new(t[1], t[2], t[3]), holder)
		trigger:SetAttribute("SecretId", secret.Id)
		CollectionService:AddTag(trigger, "SpireSecret")
		local c = secret.Cache
		local cacheCF = CFrame.new(c[1], c[2], c[3]) * CFrame.Angles(0, math.rad(c[4]), 0)
		local _, chest = Kit.Place("Chest", cacheCF, holder, { Name = "Cache" })
		if chest then
			chest:SetAttribute("CacheId", secret.Id)
			chest:SetAttribute("Items", secret.Items)
			chest:SetAttribute("Gold", secret.Gold)
			CollectionService:AddTag(chest, "SpireCache")
		end
		-- the shrine: candles, a brazier of Current flame, and a crystal in the deeper ones
		Kit.Place("Candles", cacheCF * CFrame.new(-2.6, 0, 0.4), holder, { Flatten = true, Shadows = false })
		Kit.Place("Cistern_Brazier", cacheCF * CFrame.new(3.4, 0, -1.2), holder, { Flatten = true })
		if secret.Crystal then
			Kit.Place("Current_Crystal_M", cacheCF * CFrame.new(0, -0.5, -6), holder, { Flatten = true })
		end
	end
	return #L.Secrets
end

-- SCATTER ------------------------------------------------------------------------------------------

local function pick(rng: Random, weights: { [string]: number }): string
	local keys = {}
	local total = 0
	for k, w in weights do
		table.insert(keys, k)
		total += w
	end
	table.sort(keys)
	local roll = rng:NextNumber() * total
	for _, k in keys do
		roll -= weights[k]
		if roll <= 0 then
			return k
		end
	end
	return keys[#keys]
end

local function nearRoad(L: Layout, p: Vector2, pad: number): boolean
	for _, road in L.Roads do
		local d = L.PolylineDist(p, road.Points)
		if d < road.Width / 2 + pad then
			return true
		end
	end
	return false
end

local function nearKeepClear(L: Layout, p: Vector2): boolean
	for _, w in L.Waystones do
		if (w.At - p).Magnitude < 20 then
			return true
		end
	end
	for _, s in L.Secrets do
		local c = Vector2.new(s.Cache[1], s.Cache[3])
		if (c - p).Magnitude < 16 then
			return true
		end
	end
	if (p - L.Points.FirstGate).Magnitude < 70 then
		return true
	end
	-- the gate colonnade runs west from the gate
	local gate = L.Points.FirstGate
	if p.X < gate.X and p.X > gate.X - 200 and math.abs(p.Y - gate.Y) < 30 then
		return true
	end
	return false
end

local function leafTint(rng: Random, piece: string): { [string]: Color3 }?
	for family, palette in LEAF_PALETTES do
		if string.find(piece, family, 1, true) then
			return { Leaf = palette[rng:NextInteger(1, #palette)] }
		end
	end
	return nil
end

-- Scatters one rule (or every rule when ruleIndex is nil). Returns pieces placed.
function WildBuilder.Scatter(L: Layout, parent: Instance, seed: number, ruleIndex: number?): number
	local root = folder(parent, "Scatter")
	local placed = 0
	for index, rule in L.Scatter do
		if ruleIndex and index ~= ruleIndex then
			continue
		end
		local rng = Random.new(seed * 1000 + index)
		local holder = fresh(root, `{rule.Region}_{index}`)
		local step = rule.Spacing
		local accept = math.clamp(rule.Density * step * step / 10000, 0, 1)
		local B = L.Bounds - 8
		local z = -B
		while z < B do
			local x = -B
			while x < B do
				if rng:NextNumber() < accept then
					local px = x + rng:NextNumber(0, step)
					local pz = z + rng:NextNumber(0, step)
					local p = Vector2.new(px, pz)
					if L.Region(px, pz) == rule.Region and not nearRoad(L, p, 4) and not nearKeepClear(L, p) then
						local h = L.Height(px, pz)
						local wet = L.Water(px, pz, h)
						local piece = pick(rng, rule.Pieces)
						local floating = piece == "Lilypads"
						local aquatic = AQUATIC[piece]
						local ok
						if floating then
							ok = wet ~= nil and wet - h > 0.6
						elseif aquatic == "Submerged" then
							ok = wet ~= nil and wet - h > 3
						elseif aquatic == "Either" then
							ok = wet ~= nil or h >= (rule.MinHeight or 0.4)
						else
							ok = wet == nil and h >= (rule.MinHeight or 0.4)
						end
						if ok and slopeAt(L, px, pz) <= rule.MaxSlope then
							local info = Kit.Info(piece)
							local meta = Kit.Meta(piece)
							local s = rng:NextNumber(rule.Scale[1], rule.Scale[2])
							local y = if floating then (wet or 0) + 0.05 else h - 0.4 * s
							local tilt = if info and info.Category == "Tree" then 0 else rng:NextNumber(-0.08, 0.08)
							local cf = CFrame.new(px, y, pz) * CFrame.Angles(tilt, rng:NextNumber(0, 2 * math.pi), tilt)
							Kit.Place(piece, cf, holder, {
								Scale = Vector3.one * s,
								Flatten = true,
								Collision = meta.noCollide ~= true,
								Shadows = info ~= nil and (info.Category == "Tree" or info.Category == "Cliff" or s > 1.1),
								Tint = leafTint(rng, piece),
							})
							placed += 1
						end
					end
				end
				x += step
			end
			z += step
		end
	end
	return placed
end

-- OLD WHARF ------------------------------------------------------------------------------------------

function WildBuilder.OldWharf(L: Layout, parent: Instance): number
	local root = fresh(parent, "OldWharf")
	local rng = Random.new(404)
	local centre = L.Points.OldWharf
	local towardBay = (L.Bay - centre).Unit
	local along = Vector2.new(-towardBay.Y, towardBay.X)
	local n = 0
	local function at(off: Vector2, lift: number?): CFrame
		local p = centre + along * off.X + towardBay * off.Y
		local h = L.Height(p.X, p.Y)
		local base = Vector3.new(p.X, math.max(h, 0) + (lift or 0), p.Y)
		local face = Vector3.new(towardBay.X, 0, towardBay.Y)
		return CFrame.lookAt(base, base - face)
	end
	-- three broken piers reaching into the bay, some planks sagging into the water
	for i, offset in { -50, 0, 46 } do
		local length = 3 + (i % 2)
		for k = 0, length - 1 do
			if rng:NextNumber() < 0.25 and k > 0 then
				continue -- a missing section
			end
			local p = centre + along * offset + towardBay * (60 + 16 * k)
			local sag = if k == length - 1 then math.rad(rng:NextNumber(6, 14)) else math.rad(rng:NextNumber(-2, 2))
			local base = Vector3.new(p.X, 3.5 - k * 0.6, p.Y)
			local dir = Vector3.new(towardBay.X, 0, towardBay.Y)
			Kit.Place("Pier_16", CFrame.fromMatrix(base, dir, Vector3.yAxis) * CFrame.Angles(0, 0, sag), root, { Flatten = true })
			n += 1
		end
		Kit.Place("Mooring_Piles", at(Vector2.new(offset + 6, 54)), root, { Flatten = true })
	end
	-- the wreck: a fishing boat heeled over on the sand
	Kit.Place("Fishing_Boat", at(Vector2.new(-20, 28), -1.5) * CFrame.Angles(0, math.rad(60), math.rad(24)), root, { Name = "Wreck" })
	-- rubble, crates, a dead lantern post that still lights at night (the sailors' lure)
	for _ = 1, 10 do
		local off = Vector2.new(rng:NextNumber(-70, 70), rng:NextNumber(-10, 40))
		local piece = ({ "Rubble", "Crate", "Barrel", "Rope_Coil", "Lobster_Traps", "Driftwood" })[rng:NextInteger(1, 6)]
		Kit.Place(piece, at(off, -0.3) * CFrame.Angles(0, rng:NextNumber(0, 6.28), rng:NextNumber(-0.2, 0.2)), root,
			{ Flatten = true, Shadows = false })
		n += 1
	end
	for _, x in { -36, 30 } do
		Kit.Place("LampPost", at(Vector2.new(x, 16)) * CFrame.Angles(0, 0, math.rad(8)), root, { Name = "DrownedLamp" })
	end
	Kit.Place("Notice_Board", at(Vector2.new(0, -6)), root, { Name = "WharfNotice" })
	return n
end

-- RELICS --------------------------------------------------------------------------------------------

-- Leviathan skeletons from Layout.Relics, settled into the ground so the ribs vault out of the mud.
function WildBuilder.Relics(L: Layout, parent: Instance): number
	local root = fresh(parent, "Relics")
	for i, relic in L.Relics do
		local h = L.Height(relic.At.X, relic.At.Y)
		local cf = CFrame.new(relic.At.X, h - relic.Sink, relic.At.Y) * CFrame.Angles(0, relic.Yaw, math.rad(4))
		Kit.Place(relic.Piece, cf, root, { Name = `Relic{i}`, Scale = Vector3.one * relic.Scale, Shadows = true })
	end
	return #L.Relics
end

-- CISTERN ENTRANCE -----------------------------------------------------------------------------------

function WildBuilder.CisternEntrance(L: Layout, parent: Instance): Model
	local old = parent:FindFirstChild("CisternEntrance")
	if old then
		old:Destroy()
	end
	local model = Instance.new("Model")
	model.Name = "CisternEntrance"
	model.Parent = parent
	local c = L.Points.Cistern
	local y = L.CisternBasin.Y
	-- the stair faces the Waystone above (north-west), descending into the dark
	local mouth = L.Waystones[5] and L.Waystones[5].At or (c + Vector2.new(-80, -90))
	local dir = (mouth - c).Unit
	local origin = CFrame.lookAt(Vector3.new(c.X, y, c.Y), Vector3.new(c.X, y, c.Y) - Vector3.new(dir.X, 0, dir.Y))
	Kit.Place("Cistern_Arch", origin * CFrame.new(0, 0, 4), model, { Name = "Arch" })
	Kit.Place("Cistern_Gate", origin * CFrame.new(0, 0, -2), model, { Name = "EntryGate", Collision = false })
	-- the doorway itself: touching it takes a group into their own copy of the Cistern (DungeonService)
	local door = invisiblePart("CisternDoor", Vector3.new(14, 14, 3), origin * CFrame.new(0, 7, -3), model)
	door:SetAttribute("DungeonId", "SunkenCistern")
	CollectionService:AddTag(door, "SpireDungeonDoor")
	for _, s in { -1, 1 } do
		Kit.Place("Cistern_Pillar", origin * CFrame.new(s * 18, 0, 10), model, { Flatten = true })
		Kit.Place("Cistern_Brazier", origin * CFrame.new(s * 9, 0, 9), model, { Flatten = true })
		Kit.Place("Cistern_Wall_16", origin * CFrame.new(s * 22, 0, -6) * CFrame.Angles(0, s * math.pi / 2, math.rad(s * 8)),
			model, { Flatten = true })
	end
	-- a broken ring of the old cistern roof around the basin
	for k = 0, 9 do
		local a = k / 10 * 2 * math.pi
		if k % 3 == 2 then
			continue
		end
		local pos = Vector3.new(c.X + math.cos(a) * 58, y, c.Y + math.sin(a) * 58)
		Kit.Place("Cistern_Pillar", CFrame.new(pos) * CFrame.Angles(0, a, math.rad((k % 2) * 6)), model, {
			Flatten = true,
			Scale = Vector3.new(1, 0.6 + (k % 4) * 0.2, 1),
		})
	end
	Kit.Place("Current_Crystal_L", origin * CFrame.new(-30, 0, -26), model, { Flatten = true })
	Kit.Place("Current_Crystal_M", origin * CFrame.new(26, 0, -30), model, { Flatten = true })
	model.ModelStreamingMode = Enum.ModelStreamingMode.Default
	return model
end

-- ALL ------------------------------------------------------------------------------------------------

function WildBuilder.All(L: Layout, parent: Instance): { [string]: number }
	local wild = folder(parent, "Wild")
	return {
		SecretTerrain = WildBuilder.SecretTerrain(L),
		Waystones = WildBuilder.Waystones(L, parent),
		Spawns = WildBuilder.Spawns(L),
		Pressure = WildBuilder.Pressure(L),
		Secrets = WildBuilder.Secrets(L, wild),
		OldWharf = WildBuilder.OldWharf(L, wild),
		Relics = WildBuilder.Relics(L, wild),
		Cistern = #WildBuilder.CisternEntrance(L, wild):GetDescendants(),
		Scatter = WildBuilder.Scatter(L, wild, 1),
	}
end

return WildBuilder
