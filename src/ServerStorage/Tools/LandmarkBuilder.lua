--!strict
--[[
	LandmarkBuilder (edit-time tool)
	Composes Floor 1's one-off structures from kit pieces and BuildingGenerator buildings:

	  ClimbersGuild   a three-storey stone hall with a columned portico and the Guild crest,
	                  at the head of the Climb
	  Cathedral       the Cathedral of the Ascent: nave of tall window bays, flying buttresses,
	                  twin bell towers, a portal, a rose window in the apse and a spire (~105 tall)
	  Plaza           the Market plaza: fountain, ring of stalls, benches, lamps, notice board, bell tower
	  Market          one workshop building per crafting/trade station around the plaza (Layout.Workshops),
	                  each with a lit signboard, themed dressing and a StationSpot where its station stands
	  Rotunda         the Rotunda of Attunement: a twelve-bayed domed drum on the Guild Terrace with a
	                  Current pool and a dais (ShrineSpot) for the Attunement Shrine
	  SeatFixtures    moves the existing station models and the Attunement Shrine onto their spots
	  Harbour         breakwater quays, lighthouse, harbour tower, piers, the moored brig, fishing
	                  boats, cranes, bollards and dock clutter, and the Climbers' Rest statue
	  Civic           the Watch barracks, the Library of Floors, the training yard
	  EastGate        the archway where the East Road leaves town
	  FirstGate       the Guardian gate on its plateau with a colonnaded approach

	Each builder takes the layout and a parent and returns its Model. Local space for a landmark:
	origin at the front centre on the ground, +Z = front (toward the street or the town).
	Usage (Command Bar, Edit mode):
	    local LB = require(game.ServerStorage.Tools.LandmarkBuilder)
	    LB.All(require(game.ServerStorage.Tools.Layouts.Floor1), workspace.Floor1.Town)
]]

local CollectionService = game:GetService("CollectionService")

local Kit = require(script.Parent.KitLibrary)
local BuildingGenerator = require(script.Parent.BuildingGenerator)
local Floor1 = require(script.Parent.Layouts.Floor1)

type Layout = typeof(Floor1)

local LandmarkBuilder = {}

local HALF_PI = math.pi / 2

-- HELPERS ----------------------------------------------------------------------------------

local function newModel(parent: Instance, name: string, pivot: CFrame): Model
	local old = parent:FindFirstChild(name)
	if old then
		old:Destroy()
	end
	local m = Instance.new("Model")
	m.Name = name
	m.WorldPivot = pivot
	m.Parent = parent
	CollectionService:AddTag(m, "SpireLandmark")
	return m
end

local function finish(m: Model, mode: Enum.ModelStreamingMode?): Model
	m.ModelStreamingMode = mode or Enum.ModelStreamingMode.Atomic
	return m
end

-- CFrame at polar (r, a) on height y whose +Z looks toward the bay (inward) or away from it.
local function polarCF(L: Layout, r: number, a: number, y: number, inward: boolean): CFrame
	local p = L.FromPolar(r, a)
	local pos = Vector3.new(p.X, y, p.Y)
	local dir = Vector3.new(math.cos(a), 0, math.sin(a))
	local front = if inward then -dir else dir
	return CFrame.lookAt(pos, pos - front)
end

-- Place a piece in a landmark's local space.
local function put(model: Model, origin: CFrame, piece: string, cf: CFrame, opts: Kit.PlaceOptions?)
	local o: Kit.PlaceOptions = opts or {}
	o.Flatten = if o.Flatten == nil then true else o.Flatten
	Kit.Place(piece, origin * cf, model, o)
end

local function yaw(rad: number): CFrame
	return CFrame.Angles(0, rad, 0)
end

local function landmarkCF(L: Layout, name: string, y: number): CFrame
	local lm = L.Landmarks[name]
	assert(lm, `no landmark {name}`)
	return polarCF(L, lm.R, lm.A, y, lm.Facing == "In")
end

local function bandY(L: Layout, r: number): number
	local band = L.BandAt(r)
	return if band then band.Y else L.Bands[#L.Bands].Y
end

-- CLIMBERS' GUILD ---------------------------------------------------------------------------

function LandmarkBuilder.ClimbersGuild(L: Layout, parent: Instance): Model
	local lm = L.Landmarks.ClimbersGuild
	local W, D = 48, 40
	local y = bandY(L, lm.R)
	-- footprint centre sits D/2 + portico depth behind the landmark point's front
	local origin = landmarkCF(L, "ClimbersGuild", y)
	local model = newModel(parent, "ClimbersGuild", origin)
	local hall = BuildingGenerator.Build({
		Width = W,
		Depth = D,
		Storeys = 3,
		Style = "Stone",
		Kind = "Hall",
		Wealth = 1,
		Roof = "Hip",
		Seed = 1001,
		InteriorAll = true,
		Doors = { "Front", "Back" },
		Name = "GuildHall",
		RoofColor = Color3.fromHex("#2F3A48"),
		Lit = true,
		Sign = false,
	}, origin * CFrame.new(0, 0, -6), model)
	hall.Model.ModelStreamingMode = Enum.ModelStreamingMode.Default

	-- portico: raised floor, four grand columns, a stone canopy with the crest
	local front = D / 2 - 6
	put(model, origin, "Floor_Stone", CFrame.new(0, 2, front + 6), { Scale = Vector3.new(W / 16, 1, 12 / 16) })
	put(model, origin, "Steps_Entrance", CFrame.new(0, 0, front + 12), { Scale = Vector3.new(W / 6, 1, 1) })
	for _, x in { -18, -6, 6, 18 } do
		put(model, origin, "Column_Grand", CFrame.new(x, 2, front + 9))
	end
	put(model, origin, "Floor_Stone", CFrame.new(0, 27.2, front + 6), { Scale = Vector3.new((W + 2) / 16, 1.6, 13 / 16) })
	put(model, origin, "Cornice_16", CFrame.new(-16, 27.4, front + 12.6), { Scale = Vector3.new(1.06, 1.3, 1.3) })
	put(model, origin, "Cornice_16", CFrame.new(0, 27.4, front + 12.6), { Scale = Vector3.new(1.06, 1.3, 1.3) })
	put(model, origin, "Cornice_16", CFrame.new(16, 27.4, front + 12.6), { Scale = Vector3.new(1.06, 1.3, 1.3) })
	put(model, origin, "Guild_Crest", CFrame.new(0, 28, front + 12.3), { Scale = Vector3.new(1.5, 1.5, 1.5) })
	for _, x in { -12, 12 } do
		put(model, origin, "Banner_Wall", CFrame.new(x, 24, front + 1.2), { Tint = { Cloth = Color3.fromHex("#1F5A66") } })
	end
	-- clerk counter and the guild notice board inside the front door
	put(model, origin, "Counter", CFrame.new(-12, 2, front - 10), { Flatten = false, Name = "GuildCounter" })
	put(model, origin, "Notice_Board", CFrame.new(16, 2, front + 1.5), { Flatten = false, Name = "GuildNoticeBoard" })
	return finish(model, Enum.ModelStreamingMode.Default)
end

-- CATHEDRAL OF THE ASCENT -------------------------------------------------------------------

function LandmarkBuilder.Cathedral(L: Layout, parent: Instance): Model
	local lm = L.Landmarks.Cathedral
	local y = bandY(L, lm.R)
	-- the landmark point is the nave centre; the facade sits 40 in front of it
	local centre = landmarkCF(L, "Cathedral", y)
	local origin = centre * CFrame.new(0, 0, 40)
	local model = newModel(parent, "Cathedral", origin)
	local NAVE, BAYS, HALF = 32, 5, 16
	local LEN = BAYS * 16
	local tint = { Plaster = Color3.fromHex("#B7AE9C") }

	-- floor and plinth
	put(model, origin, "Floor_Stone", CFrame.new(0, 2, -LEN / 2), { Scale = Vector3.new((NAVE + 4) / 16, 1, (LEN + 2) / 16) })
	for _, s in { -1, 1 } do
		put(model, origin, "Foundation_16", CFrame.new(s * (HALF + 0.5), 0, -LEN / 2) * yaw(s * HALF_PI),
			{ Scale = Vector3.new(LEN / 16, 1, 1) })
	end

	-- nave walls of tall window bays, with flying buttresses between them
	for k = 0, BAYS - 1 do
		local z = -8 - 16 * k
		for _, s in { -1, 1 } do
			put(model, origin, "Cathedral_Bay", CFrame.new(s * HALF, 2, z) * yaw(s * HALF_PI), { Tint = tint })
			if k > 0 then
				put(model, origin, "Flying_Buttress", CFrame.new(s * HALF, 2, z + 8) * yaw(s * HALF_PI))
				put(model, origin, "Pinnacle", CFrame.new(s * (HALF + 14), 26, z + 8))
			end
		end
	end
	-- apse wall with the rose window
	for _, x in { -8, 8 } do
		put(model, origin, "Cathedral_Bay", CFrame.new(x, 2, -LEN) * yaw(math.pi), { Tint = tint })
	end
	put(model, origin, "Rose_Window", CFrame.new(0, 15, -LEN - 1.8) * yaw(math.pi))

	-- facade: portal, fillers to the nave walls, twin bell towers
	put(model, origin, "Cathedral_Portal", CFrame.new(0, 2, 0), { Flatten = false, Name = "Portal" })
	for _, s in { -1, 1 } do
		put(model, origin, "Cathedral_Bay", CFrame.new(s * 12.5, 2, 0), { Scale = Vector3.new(7 / 16, 1, 1), Tint = tint })
		put(model, origin, "Belltower", CFrame.new(s * (HALF + 7.5), 2, -7.5))
	end
	put(model, origin, "Steps_Entrance", CFrame.new(0, 0, 4.4), { Scale = Vector3.new(3, 1, 1) })

	-- roof (ridge along the nave), gable ends and the crossing spire
	local span = (NAVE + 2) / 16
	put(model, origin, "Roof_Gable", CFrame.new(0, 34, -LEN / 2) * yaw(HALF_PI),
		{ Scale = Vector3.new(LEN / 16, span, span), Tint = { Roof = Color3.fromHex("#33404A") } })
	put(model, origin, "Roof_GableEnd_Stone", CFrame.new(0, 34, 0), { Scale = Vector3.new(span, span, 1), Tint = tint })
	put(model, origin, "Roof_GableEnd_Stone", CFrame.new(0, 34, -LEN) * yaw(math.pi), { Scale = Vector3.new(span, span, 1), Tint = tint })
	put(model, origin, "Cathedral_Spire", CFrame.new(0, 40, -LEN + 24))

	-- interior: two rows of columns, pews facing the altar, lanterns
	for k = 1, BAYS - 1 do
		for _, s in { -1, 1 } do
			put(model, origin, "Column_Grand", CFrame.new(s * 10, 2, -16 * k), { Shadows = false })
		end
	end
	for row = 0, 7 do
		for _, s in { -1, 1 } do
			put(model, origin, "Bench", CFrame.new(s * 4.5, 2, -14 - row * 6) * yaw(math.pi),
				{ Collision = true, Shadows = false })
		end
	end
	put(model, origin, "Cistern_Altar", CFrame.new(0, 2, -LEN + 8), { Flatten = false, Name = "Altar" })
	for _, x in { -6, 6 } do
		put(model, origin, "Candles", CFrame.new(x, 2, -LEN + 6), { Shadows = false })
	end
	for k = 1, 4 do
		put(model, origin, "Lantern_Hanging", CFrame.new(0, 30, -16 * k), { Shadows = false })
	end
	return finish(model, Enum.ModelStreamingMode.Default)
end

-- MARKET PLAZA -------------------------------------------------------------------------------

function LandmarkBuilder.Plaza(L: Layout, parent: Instance): Model
	local y = bandY(L, L.Plaza.Radius)
	local centre = polarCF(L, L.Plaza.Radius, L.Plaza.Angle, y, true)
	local model = newModel(parent, "MarketPlaza", centre)
	put(model, centre, "Fountain", CFrame.new(0, 0, 0), { Flatten = false, Name = "Fountain" })
	-- a ring of stalls facing the fountain, leaving the Climb (local +-Z) open
	local ring = 40
	local n = 0
	for deg = 0, 345, 15 do
		local rad = math.rad(deg)
		local fromAxis = math.abs(math.sin(rad))
		if fromAxis < 0.42 then
			continue -- keep the avenue through the plaza clear
		end
		n += 1
		local pos = Vector3.new(math.sin(rad) * ring, 0, math.cos(rad) * ring)
		local cf = CFrame.lookAt(pos, pos * 2) -- +Z (counter) toward the fountain
		put(model, centre, "Market_Stall", cf, {
			Flatten = false,
			Name = `Stall{n}`,
			Tint = { Cloth = if n % 2 == 0 then Color3.fromHex("#7A2E24") else Color3.fromHex("#1F5A66") },
		})
	end
	-- benches around the fountain, lamps on the plaza rim
	for deg = 45, 315, 90 do
		local rad = math.rad(deg)
		local pos = Vector3.new(math.sin(rad) * 18, 0, math.cos(rad) * 18)
		put(model, centre, "Bench", CFrame.lookAt(pos, pos * 2), { Collision = true })
	end
	for deg = 0, 330, 30 do
		local rad = math.rad(deg)
		local pos = Vector3.new(math.sin(rad) * 60, 0, math.cos(rad) * 60)
		Kit.Place("LampPost", centre * CFrame.fromMatrix(pos, -pos.Unit, Vector3.yAxis), model, { Name = "LampPost" })
	end
	put(model, centre, "Notice_Board", CFrame.new(-26, 0, 8) * yaw(HALF_PI), { Flatten = false, Name = "PlazaNoticeBoard" })
	-- the bell tower on the plaza's south-east edge
	local bt = L.Landmarks.Belltower
	local _, tower = Kit.Place("Belltower", polarCF(L, bt.R, bt.A, y, true), model, { Flatten = false, Name = "Belltower" })
	if tower then
		CollectionService:AddTag(tower, "SpireBell") -- tolls at dawn and dusk (EnvironmentController)
	end
	return finish(model)
end

-- MARKET WORKSHOPS ----------------------------------------------------------------------------

local SIGN_WOOD = Color3.fromHex("#2E2219")
local SIGN_TEXT = Color3.fromHex("#E2BE78")

-- Invisible marker the fixtures are seated on (SeatFixtures). Kept in the model so a rebuild of
-- the landmark never loses where its station goes.
local function spot(model: Model, name: string, cf: CFrame): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Transparency = 1
	p.Size = Vector3.new(1, 1, 1)
	p.CFrame = cf
	p.Parent = model
	return p
end

local function plainPart(model: Instance, name: string, size: Vector3, cf: CFrame, material: Enum.Material, color: Color3,
	collide: boolean?): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = collide == true
	p.CanQuery = collide == true
	p.CanTouch = false
	p.Size = size
	p.CFrame = cf
	p.Material = material
	p.Color = color
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = model
	return p
end

-- A carved signboard over the door with the workshop's name (front face = building +Z).
local function signboard(model: Model, at: CFrame, width: number, text: string)
	local board = plainPart(model, "Signboard", Vector3.new(width, 2.6, 0.35), at, Enum.Material.Wood, SIGN_WOOD)
	board.CastShadow = false
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Back -- +Z of the board, toward the street
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 32
	gui.LightInfluence = 0.3
	gui.Brightness = 1.4
	gui.MaxDistance = 140 -- not drawn from across the town (cheap on phones)
	gui.Parent = board
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(0.94, 0.8)
	label.Position = UDim2.fromScale(0.03, 0.1)
	label.Font = Enum.Font.Fantasy
	label.Text = text
	label.TextScaled = true
	label.TextColor3 = SIGN_TEXT
	label.TextStrokeColor3 = Color3.new(0, 0, 0)
	label.TextStrokeTransparency = 0.55
	label.Parent = gui
end

-- A bubbling cauldron's vapour (Alchemy) or a candle-smoke wisp, on an invisible holder.
local function vapour(model: Model, at: CFrame, color: Color3, rate: number)
	local holder = spot(model, "Vapour", at)
	local e = Instance.new("ParticleEmitter")
	e.Texture = "rbxasset://textures/particles/smoke_main.dds"
	e.Color = ColorSequence.new(color)
	e.LightEmission = 0.6
	e.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(1, 1) })
	e.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.6), NumberSequenceKeypoint.new(1, 2.4) })
	e.Lifetime = NumberRange.new(1.5, 2.5)
	e.Rate = rate
	e.Speed = NumberRange.new(1, 2)
	e.SpreadAngle = Vector2.new(15, 15)
	e.Parent = holder
end

local function glowLight(part: BasePart, color: Color3, range: number, brightness: number)
	local light = Instance.new("PointLight")
	light.Color = color
	light.Range = range
	light.Brightness = brightness
	light.Shadows = false
	light.Parent = part
end

-- Kind-specific dressing in building space (front at z = D/2, door near x = 0, station on +x).
local function dressWorkshop(model: Model, bf: CFrame, w: any, cloth: Color3)
	local W, D = w.Width :: number, w.Depth :: number
	local front = D / 2
	local left = -W / 2
	local kind = w.Kind :: string
	local function at(x: number, y: number, z: number, turn: number?): CFrame
		return bf * CFrame.new(x, y, z) * yaw(turn or 0)
	end
	if kind == "Forge" then
		Kit.Place("Weapon_Rack", at(left + 4, 0, front + 0.3), model, { Flatten = true })
		Kit.Place("Anvil", at(left + 5, 0, front + 5, 0.4), model, { Flatten = true, Collision = true })
		Kit.Place("Barrel", at(left + 2.2, 0, front + 2.5), model, { Flatten = true, Collision = true })
	elseif kind == "Armorer" then
		Kit.Place("Weapon_Rack", at(left + 4, 0, front + 0.3), model, { Flatten = true })
		Kit.Place("Weapon_Rack", at(left + 4, 0, front + 6, math.pi / 2), model, { Flatten = true })
		Kit.Place("Crate", at(left + 2, 0, front + 3), model, { Flatten = true, Collision = true })
	elseif kind == "Loom" then
		Kit.Place("Sacks", at(left + 3, 0, front + 2.5), model, { Flatten = true, Collision = true })
		Kit.Place("Crate_Stack", at(left + 4, 0, front + 6, 0.3), model, { Flatten = true, Collision = true })
		-- dyed cloth hung out to dry under the eaves
		local dyes = { Color3.fromHex("#5A2E4E"), Color3.fromHex("#1F5B5E"), Color3.fromHex("#7A5A2A") }
		for i, x in { -W / 2 + 2.2, W / 2 - 2.2 } do
			Kit.Place("Banner_Wall", at(x, 12.4, front + 0.6), model, { Flatten = true, Collision = false,
				Tint = { Cloth = dyes[i] } })
		end
	elseif kind == "Alchemy" then
		Kit.Place("Cooking_Pot", at(left + 4, 0, front + 4.5), model, { Flatten = true, Collision = true })
		vapour(model, at(left + 4, 3.6, front + 4.5), Color3.fromHex("#7CFF9A"), 4)
		Kit.Place("Potted_Plant", at(-4.4, 0, front + 1.6), model, { Flatten = true })
		Kit.Place("Glow_Mushrooms", at(left + 1.5, 0, front + 1.5), model, { Flatten = true, Collision = false })
		Kit.Place("Barrel", at(left + 1.8, 0, front + 7), model, { Flatten = true, Collision = true })
	elseif kind == "Shop" then
		Kit.Place("Cart", at(left + 5, 0, front + 6, 0.35), model, { Flatten = true, Collision = true })
		Kit.Place("Barrel", at(left + 1.8, 0, front + 1.8), model, { Flatten = true, Collision = true })
		Kit.Place("Barrel", at(left + 4, 0, front + 1.6), model, { Flatten = true, Collision = true })
		Kit.Place("Sacks", at(-4.8, 0, front + 1.6), model, { Flatten = true, Collision = true })
	elseif kind == "Bank" then
		-- a columned porch: two grand columns carrying a stone lintel over the door
		for _, x in { -6, 6 } do
			Kit.Place("Column_Grand", at(x, 0, front + 2.2), model, { Flatten = true, Scale = Vector3.new(1, 1.04, 1) })
		end
		Kit.Place("Floor_Stone", at(0, 25, front + 2.2), model, { Flatten = true, Scale = Vector3.new(15 / 16, 1.4, 5.5 / 16) })
		Kit.Place("Chest", at(left + 3, 0, front + 2), model, { Flatten = true, Collision = true })
	elseif kind == "TokenShop" then
		for _, x in { left + 2, left + 5 } do
			Kit.Place("Current_Crystal_S", at(x, 0, front + 2), model, { Flatten = true, Collision = false })
		end
		Kit.Place("Notice_Board", at(left + 3, 0, front + 5, 0.5), model, { Flatten = true })
	elseif kind == "Altar" then
		Kit.Place("Current_Crystal_M", at(left + 4, 0, front + 4.5), model, { Flatten = true, Collision = false })
		for i = 0, 3 do
			Kit.Place("Candles", at(left + 1.5 + i * 0.9, 0, front + 1.6 + (i % 2) * 0.6), model, { Flatten = true,
				Collision = false, Shadows = false })
		end
		Kit.Place("RuneBand_16", at(0, 8.2, front + 0.6), model, { Flatten = true, Collision = false,
			Scale = Vector3.new(W / 16, 1, 1) })
	end
	-- banners on the upper storey either side, in the workshop's colour
	for _, x in { -W / 2 + 2.2, W / 2 - 2.2 } do
		Kit.Place("Banner_Wall", at(x, 26, front + 0.6), model, { Flatten = true, Collision = false,
			Tint = { Cloth = cloth } })
	end
end

function LandmarkBuilder.Market(L: Layout, parent: Instance): Model
	local y = bandY(L, L.Plaza.Radius)
	local centre = polarCF(L, L.Plaza.Radius, L.Plaza.Angle, y, true)
	local model = newModel(parent, "MarketWorkshops", centre)
	for i, w in L.Workshops do
		local rad = math.rad(w.Angle)
		local dist = L.WorkshopFront + w.Depth / 2
		local pos = Vector3.new(math.sin(rad) * dist, 0, math.cos(rad) * dist)
		local bf = centre * CFrame.lookAt(pos, pos * 2) -- building +Z (its front) faces the fountain
		local cloth = Color3.fromHex(w.Cloth)
		local result = BuildingGenerator.Build({
			Width = w.Width,
			Depth = w.Depth,
			Storeys = w.Storeys,
			Style = w.Style,
			Kind = w.Building :: any,
			Wealth = if w.Kind == "Bank" then 1 else 0.7,
			Roof = if w.Width >= w.Depth then "Gable" else "Hip",
			Seed = 3000 + i,
			Doors = { "Front" },
			Name = `Workshop_{w.Kind}`,
			Plaster = if w.Plaster then Color3.fromHex(w.Plaster) else nil,
			Cloth = cloth,
			Lit = true,
			Sign = true,
			Balcony = false,
			Smoke = if w.Kind == "Forge" then "Forge" elseif w.Kind == "Alchemy" or w.Kind == "Armorer" then "Hearth" else nil,
		}, bf, model)
		local building = result.Model
		building:SetAttribute("Workshop", w.Kind)
		-- signboard and its two lanterns over the door
		local boardW = math.min(w.Width - 4, 16)
		signboard(building, bf * CFrame.new(0, 14, w.Depth / 2 + 0.75), boardW, w.Name)
		for _, s in { -1, 1 } do
			Kit.Place("Lantern_Wall", bf * CFrame.new(s * (boardW / 2 + 1.2), 15.4, w.Depth / 2), building,
				{ Flatten = true, Collision = false, Shadows = false })
		end
		dressWorkshop(building, bf, w, cloth)
		-- the station stands in front of the door, to its right; its +Z side (where the station's own
		-- sign faces) looks out to the plaza, the same way as the building
		local stationAt = bf * CFrame.new(w.Width / 2 - 4.5, 0, w.Depth / 2 + 9)
		local s = spot(building, "StationSpot", stationAt)
		s:SetAttribute("StationKind", w.Kind)
		if w.Kind == "Forge" then
			-- live coals beside the station's anvil, lighting the plaza side of the smithy
			local coals = plainPart(building, "ForgeCoals", Vector3.new(1.4, 0.3, 1.4), stationAt * CFrame.new(2.4, 3.4, 0.6),
				Enum.Material.Neon, Color3.fromHex("#FF6A1E"))
			coals.CastShadow = false
			glowLight(coals, Color3.fromHex("#FF8A3A"), 14, 1.6)
		end
	end
	return finish(model, Enum.ModelStreamingMode.Default)
end

-- ROTUNDA OF ATTUNEMENT ----------------------------------------------------------------------------

local ROTUNDA_STONE = Color3.fromHex("#3C4044")
local ROTUNDA_STEP = Color3.fromHex("#4C5052")
local CURRENT = Color3.fromHex("#3FE0D0")

local function disc(model: Model, name: string, radius: number, height: number, cf: CFrame, material: Enum.Material,
	color: Color3, collide: boolean): Part
	local p = plainPart(model, name, Vector3.new(height, radius * 2, radius * 2), cf * CFrame.Angles(0, 0, HALF_PI),
		material, color, collide)
	p.Shape = Enum.PartType.Cylinder
	return p
end

function LandmarkBuilder.Rotunda(L: Layout, parent: Instance): Model
	local lm = L.Landmarks.AttunementShrine
	local y = bandY(L, lm.R)
	local origin = landmarkCF(L, "AttunementShrine", y) -- the rotunda's centre; +Z faces the bay
	local model = newModel(parent, "RotundaOfAttunement", origin)
	-- every kit piece of the drum is scaled up by S so the rotunda towers over the terrace houses
	local S = 1.35
	local SIDES, BAY, WALL_H = 12, 16 * S, 32 * S
	local apothem = (BAY / 2) / math.tan(math.pi / SIDES) -- 40.3
	local corner = (BAY / 2) / math.sin(math.pi / SIDES) -- 41.7
	local F = 3 -- floor level on top of the stepped plinth

	-- stepped plinth: three 1-stud tiers (walkable steps all round)
	for k, r in { 51, 48, 45 } do
		disc(model, `Plinth{k}`, r, 1, origin * CFrame.new(0, k - 0.5, 0), Enum.Material.Slate,
			if k == 3 then ROTUNDA_STONE else ROTUNDA_STEP, true)
	end
	-- the drum: twelve tall window bays, the front one a portal
	for i = 0, SIDES - 1 do
		local phi = i * 2 * math.pi / SIDES
		local pos = Vector3.new(math.sin(phi) * apothem, F, math.cos(phi) * apothem)
		local cf = CFrame.lookAt(pos, Vector3.new(0, F, 0)) -- +Z (the bay's face) outward
		if i == 0 then
			-- the portal stands open: drop its door leaves (wood, brass and iron channels) and the
			-- door's collision box, keeping the posts and the arch
			local parts = Kit.Place("Cathedral_Portal", origin * cf, model, { Flatten = true,
				Scale = Vector3.new(BAY / 18, S, S) })
			for _, part in parts do
				local channel = part:GetAttribute("Channel")
				local mag = part.Size.Magnitude / S
				if channel == "WoodDark" or channel == "Brass" or channel == "Metal" or (part.Name == "Collision" and mag > 18.5 and mag < 21) then
					part:Destroy()
				end
			end
		else
			put(model, origin, "Cathedral_Bay", cf, { Scale = Vector3.one * S })
			put(model, origin, "RuneBand_16", cf * CFrame.new(0, 3, 1.1 * S), { Collision = false, Shadows = false,
				Scale = Vector3.one * S })
		end
		put(model, origin, "Cornice_16", cf * CFrame.new(0, WALL_H - 0.6 * S, 1.2 * S), { Collision = false,
			Scale = Vector3.new(1.08 * S, 1.4 * S, 1.4 * S) })
		if i == 2 or i == SIDES - 2 then
			put(model, origin, "Banner_Wall", cf * CFrame.new(0, WALL_H - 3 * S, 1.6 * S), { Collision = false,
				Scale = Vector3.one * S, Tint = { Cloth = Color3.fromHex("#1F4E52") } })
		end
		-- a grand column and a pinnacle on every corner of the drum
		local cphi = (i + 0.5) * 2 * math.pi / SIDES
		local cpos = Vector3.new(math.sin(cphi) * (corner + 0.6), F, math.cos(cphi) * (corner + 0.6))
		local ccf = CFrame.lookAt(cpos, Vector3.new(0, F, 0))
		put(model, origin, "Column_Grand", ccf, { Scale = Vector3.new(S, WALL_H / 24, S) })
		put(model, origin, "Pinnacle", ccf * CFrame.new(0, WALL_H + 0.4, 0), { Scale = Vector3.one * 1.4 * S, Shadows = false })
	end
	-- the dome, and a Current crystal burning at its crown
	local domeScale = (corner * 2 + 2) / 16
	put(model, origin, "Roof_Dome", CFrame.new(0, F + WALL_H, 0), { Scale = Vector3.new(domeScale, 3, domeScale) })
	local crownY = F + WALL_H + 14.7 * 3 - 2
	put(model, origin, "Current_Crystal_M", CFrame.new(0, crownY, 0), { Scale = Vector3.one * 1.6, Collision = false })
	local crown = plainPart(model, "CrownLight", Vector3.new(1, 1, 1), origin * CFrame.new(0, crownY + 6, 0),
		Enum.Material.Neon, CURRENT)
	crown.Transparency = 1
	glowLight(crown, CURRENT, 40, 1.2)

	-- inside: a ring pool of Current water around the dais the Shrine stands on
	local base = origin * CFrame.new(0, F, 0)
	disc(model, "PoolRim", 15, 1.2, base * CFrame.new(0, 0.6, 0), Enum.Material.Slate, ROTUNDA_STEP, true)
	local pool = disc(model, "Pool", 13.6, 0.4, base * CFrame.new(0, 1.05, 0), Enum.Material.Glass, Color3.fromHex("#1F6E78"), true)
	pool.Transparency = 0.25
	local poolGlow = disc(model, "PoolGlow", 13, 0.2, base * CFrame.new(0, 0.85, 0), Enum.Material.Neon, CURRENT, false)
	poolGlow.Transparency = 0.35
	disc(model, "Dais", 9.5, 1.6, base * CFrame.new(0, 0.8, 0), Enum.Material.Slate, ROTUNDA_STONE, true)
	glowLight(poolGlow, CURRENT, 26, 1.4)
	-- light falling from the oculus onto the dais
	for k = 0, 3 do
		local a = k * HALF_PI + 0.4
		local shaft = plainPart(model, `LightShaft{k}`, Vector3.new(2.4, WALL_H + 6, 2.4),
			base * CFrame.new(math.cos(a) * 3, WALL_H / 2 + 4, math.sin(a) * 3) * CFrame.Angles(math.rad(6) * math.cos(a), 0, math.rad(6) * math.sin(a)),
			Enum.Material.Neon, Color3.fromHex("#BFF6EE"))
		shaft.Transparency = 0.9
		shaft.CastShadow = false
	end
	-- braziers around the hall, candles at the portal
	for k = 0, 3 do
		local a = math.pi / 4 + k * HALF_PI
		put(model, origin, "Cistern_Brazier", CFrame.new(math.sin(a) * 26, F, math.cos(a) * 26), { Shadows = false,
			Scale = Vector3.one * 1.3 })
	end
	for _, x in { -5, 5 } do
		put(model, origin, "Candles", CFrame.new(x, F, apothem - 3), { Collision = false, Shadows = false })
	end
	-- the approach: lamps either side of the steps
	for _, x in { -12, 12 } do
		Kit.Place("LampPost", origin * CFrame.new(x, 0, 56), model, { Name = "LampPost" })
	end
	-- where the Attunement Shrine stands (SeatFixtures), facing the portal
	spot(model, "ShrineSpot", base * CFrame.new(0, 1.6, 0) * yaw(math.pi))
	return finish(model, Enum.ModelStreamingMode.Default)
end

-- FIXTURES --------------------------------------------------------------------------------------

-- Moves a fixture model so it sits on `cf` with its lowest point on cf's height.
local function seat(fixture: Model, cf: CFrame)
	fixture:PivotTo(cf)
	local box, size = fixture:GetBoundingBox()
	local bottom = box.Position.Y - size.Y / 2
	fixture:PivotTo(cf + Vector3.new(0, cf.Position.Y - bottom, 0))
end

-- Seats the floor's stations on the market's StationSpots (by StationKind) and the Attunement
-- Shrine on the rotunda's ShrineSpot. Returns how many fixtures moved. Stations keep their ids
-- and attributes; only their position changes.
function LandmarkBuilder.SeatFixtures(town: Instance): number
	local moved = 0
	local market = town:FindFirstChild("MarketWorkshops")
	local spots: { [string]: BasePart } = {}
	if market then
		for _, d in market:GetDescendants() do
			if d:IsA("BasePart") and d.Name == "StationSpot" then
				local kind = d:GetAttribute("StationKind")
				if type(kind) == "string" then
					spots[kind] = d
				end
			end
		end
	end
	for _, station in CollectionService:GetTagged("ItemStation") do
		if station:IsA("Model") and station:IsDescendantOf(town) then
			local kind = station:GetAttribute("StationKind")
			local target = if type(kind) == "string" then spots[kind] else nil
			if target then
				seat(station, target.CFrame)
				moved += 1
			end
		end
	end
	local rotunda = town:FindFirstChild("RotundaOfAttunement")
	local shrineSpot = rotunda and rotunda:FindFirstChild("ShrineSpot")
	if shrineSpot and shrineSpot:IsA("BasePart") then
		for _, shrine in CollectionService:GetTagged("AttunementShrine") do
			if shrine:IsA("Model") and shrine:IsDescendantOf(town) then
				seat(shrine, shrineSpot.CFrame)
				moved += 1
			end
		end
	end
	return moved
end

-- HARBOUR --------------------------------------------------------------------------------------

local function dockClutter(model: Model, at: CFrame, rng: Random)
	local pieces = { "Crate", "Crate_Stack", "Barrel", "Barrel", "Sacks", "Rope_Coil", "Lobster_Traps", "Fish_Rack" }
	for i = 1, rng:NextInteger(3, 5) do
		local piece = pieces[rng:NextInteger(1, #pieces)]
		local off = CFrame.new(rng:NextNumber(-5, 5), 0, rng:NextNumber(-3, 3)) * yaw(rng:NextNumber(0, 2 * math.pi))
		Kit.Place(piece, at * off, model, { Flatten = true, Shadows = i == 1, Collision = true })
	end
end

function LandmarkBuilder.Harbour(L: Layout, parent: Instance): Model
	local model = newModel(parent, "Harbour", CFrame.new(L.Bay.X, 0, L.Bay.Y))
	local rng = Random.new(77)
	local docksY = L.Bands[1].Y

	-- breakwater quays (both faces of each arm), lighthouse and harbour tower at the tips
	for _, arm in L.Breakwaters do
		local a, b = arm[1], arm[2]
		local dir = (b - a).Unit
		local side = Vector2.new(-dir.Y, dir.X)
		local len = (b - a).Magnitude
		local n = math.ceil(len / 16)
		for k = 0, n - 1 do
			local p = a:Lerp(b, (k + 0.5) / n)
			for _, s in { -1, 1 } do
				local face = side * s
				local pos = Vector3.new(p.X + face.X * 9.5, 5, p.Y + face.Y * 9.5)
				local front = Vector3.new(face.X, 0, face.Y)
				Kit.Place("Quay_16", CFrame.lookAt(pos, pos - front), model, {
					Flatten = true,
					Scale = Vector3.new(len / n / 16 + 0.03, 1, 1),
				})
			end
		end
	end
	local lh = L.Points.Lighthouse
	local _, lighthouse = Kit.Place("Lighthouse", CFrame.new(lh.X, 5, lh.Y), model, { Name = "Lighthouse" })
	if lighthouse then
		lighthouse.ModelStreamingMode = Enum.ModelStreamingMode.Persistent
		pcall(function()
			(lighthouse :: any).LevelOfDetail = Enum.ModelLevelOfDetail.StreamingMesh -- low-detail mesh when far away
		end)
		CollectionService:AddTag(lighthouse, "SpireBeacon")
	end
	local ht = L.Points.HarbourTower
	Kit.Place("Tower_Harbour", CFrame.new(ht.X, 5, ht.Y) * yaw(math.pi / 3), model, { Name = "HarbourTower" })

	-- piers out from the quay, with boats moored alongside
	local piers = { { A = -0.5, Len = 4 }, { A = -0.3, Len = 3 }, { A = 0.42, Len = 5 }, { A = 0.55, Len = 3 } }
	for i, pier in piers do
		for k = 0, pier.Len - 1 do
			local r = L.QuayRadius - 8 - 16 * k
			local p = L.FromPolar(r, pier.A)
			local radial = Vector3.new(math.cos(pier.A), 0, math.sin(pier.A))
			Kit.Place("Pier_16", CFrame.fromMatrix(Vector3.new(p.X, docksY - 0.6, p.Y), radial, Vector3.yAxis), model, { Flatten = true })
		end
		local tip = L.FromPolar(L.QuayRadius - 16 * pier.Len, pier.A)
		local radial = Vector3.new(math.cos(pier.A), 0, math.sin(pier.A))
		local tangent = Vector3.new(-math.sin(pier.A), 0, math.cos(pier.A))
		local mid = L.FromPolar(L.QuayRadius - 8 * pier.Len - 4, pier.A)
		if i == 3 then
			-- the brig, bow to the sea, alongside the longest pier
			local pos = Vector3.new(mid.X, 0, mid.Y) + tangent * 19
			Kit.Place("Ship_Brig", CFrame.fromMatrix(pos, -radial, Vector3.yAxis), model, { Name = "Brig" })
		else
			local pos = Vector3.new(mid.X, 0, mid.Y) + tangent * (if i % 2 == 0 then -10 else 10)
			Kit.Place("Fishing_Boat", CFrame.fromMatrix(pos, -radial, Vector3.yAxis), model, { Name = "FishingBoat" })
		end
		Kit.Place("Mooring_Piles", CFrame.new(tip.X, docksY - 0.6, tip.Y), model, { Flatten = true })
		Kit.Place("Bollard", CFrame.new(tip.X, docksY - 0.6, tip.Y) + radial * 4, model, { Flatten = true, Collision = false })
	end
	for i = 1, 5 do
		local a = rng:NextNumber(-0.6, 0.6)
		local p = L.FromPolar(rng:NextNumber(230, 280), a)
		Kit.Place("Rowboat", CFrame.new(p.X, 0, p.Y) * yaw(rng:NextNumber(0, 2 * math.pi)), model, { Flatten = true })
	end
	for i = 1, 6 do
		local p = L.FromPolar(rng:NextNumber(120, 250), rng:NextNumber(-2.6, 2.6))
		Kit.Place("Buoy", CFrame.new(p.X, -0.6, p.Y), model, { Flatten = true, Shadows = false })
	end

	-- the quay: cranes, bollards, nets and clutter, avoiding piers, canals and the Climb
	local quayR = L.QuayRadius + 6
	for _, a in { -0.42, 0.08, 0.34 } do
		local cf = polarCF(L, quayR - 2, a, docksY, false) -- jib reaches out over the water
		Kit.Place("Crane_Dock", cf, model, { Name = "Crane" })
	end
	local a = -0.62
	while a < 0.62 do
		local nearPier = false
		for _, pier in piers do
			nearPier = nearPier or math.abs(a - pier.A) * quayR < 8
		end
		local nearCanal = false
		for _, ca in L.Canals do
			nearCanal = nearCanal or math.abs(a - ca) * quayR < 12
		end
		if not nearPier and not nearCanal and math.abs(a) * quayR > 16 then
			Kit.Place("Bollard", polarCF(L, L.QuayRadius + 2, a, docksY, true), model, { Flatten = true, Collision = false, Shadows = false })
			if rng:NextNumber() < 0.45 then
				dockClutter(model, polarCF(L, quayR + 4, a + 0.02, docksY, true), rng)
			elseif rng:NextNumber() < 0.3 then
				Kit.Place("Nets_Frame", polarCF(L, quayR + 4, a + 0.02, docksY, true), model, { Flatten = true })
			end
		end
		a += 26 / quayR
	end

	-- Climbers' Rest: the statue at the foot of the Climb, facing the sea (new arrivals' first sight)
	Kit.Place("Statue_Climber", polarCF(L, L.QuayRadius + 6, 0, docksY, true), model, { Name = "ClimberStatue" })
	return finish(model, Enum.ModelStreamingMode.Default)
end

-- CIVIC BUILDINGS ------------------------------------------------------------------------------

function LandmarkBuilder.Civic(L: Layout, parent: Instance): Model
	local model = newModel(parent, "Civic", CFrame.new())
	local barracks = L.Landmarks.Barracks
	BuildingGenerator.Build({
		Width = 40,
		Depth = 28,
		Storeys = 2,
		Style = "Stone",
		Kind = "Barracks",
		Wealth = 0.8,
		Roof = "Gable",
		Seed = 2001,
		InteriorAll = true,
		Name = "WatchBarracks",
		Lit = true,
	}, polarCF(L, barracks.R, barracks.A, bandY(L, barracks.R), true), model)
	local library = L.Landmarks.LibraryOfFloors
	BuildingGenerator.Build({
		Width = 32,
		Depth = 28,
		Storeys = 3,
		Style = "Stone",
		Kind = "Library",
		Wealth = 0.95,
		Roof = "Hip",
		Seed = 2002,
		InteriorAll = true,
		Name = "LibraryOfFloors",
		Lit = true,
		Sign = true,
	}, polarCF(L, library.R, library.A, bandY(L, library.R), true), model)

	-- training yard: a fenced square with weapon racks (the training dummies move here in 9C)
	local yard = L.Landmarks.TrainingYard
	local y = bandY(L, yard.R)
	local origin = polarCF(L, yard.R, yard.A, y, true)
	local yardModel = Instance.new("Model")
	yardModel.Name = "TrainingYard"
	yardModel.Parent = model
	put(yardModel, origin, "Floor_Cobble", CFrame.new(0, 0.1, 0), { Scale = Vector3.new(48 / 16, 1, 48 / 16), Collision = false })
	for side = 0, 3 do
		local face = yaw(side * HALF_PI)
		for _, x in { -20, -12, -4, 4, 12, 20 } do
			if side == 0 and math.abs(x) == 4 then
				continue -- the gate toward the street
			end
			put(yardModel, origin, "Fence", face * CFrame.new(x, 0, 24))
		end
	end
	for _, x in { -16, 0, 16 } do
		put(yardModel, origin, "Weapon_Rack", CFrame.new(x, 0, -22))
	end
	return finish(model, Enum.ModelStreamingMode.Default)
end

-- GATES ------------------------------------------------------------------------------------------

function LandmarkBuilder.EastGate(L: Layout, parent: Instance): Model
	local lm = L.Landmarks.EastGate
	local origin = polarCF(L, L.TownOuter - 6, lm.A, bandY(L, L.TownOuter - 6), true)
	local model = newModel(parent, "EastGate", origin)
	put(model, origin, "Street_Arch", CFrame.new(0, 0, 0), { Flatten = false, Name = "Arch" })
	for _, x in { -16, 16 } do
		put(model, origin, "Banner_Wall", CFrame.new(x * 0.62, 20, 5.6), { Tint = { Cloth = Color3.fromHex("#1F5A66") } })
	end
	return finish(model)
end

function LandmarkBuilder.FirstGate(L: Layout, parent: Instance): Model
	local p = L.Points.FirstGate
	local y = L.GatePlateau.Y
	-- the gate faces west, toward the town
	local origin = CFrame.lookAt(Vector3.new(p.X, y, p.Y), Vector3.new(p.X + 1, y, p.Y))
	local model = newModel(parent, "FirstGate", origin)
	local _, gate = Kit.Place("First_Gate", origin, model, { Name = "Gate" })
	if gate then
		pcall(function()
			(gate :: any).LevelOfDetail = Enum.ModelLevelOfDetail.StreamingMesh
		end)
		gate.ModelStreamingMode = Enum.ModelStreamingMode.Persistent
		CollectionService:AddTag(gate, "SpireFirstGate")
	end
	-- the approach: a paved avenue between columns and braziers, two Climber statues at its mouth
	put(model, origin, "Floor_Stone", CFrame.new(0, 0.1, 80), { Scale = Vector3.new(28 / 16, 1, 140 / 16), Collision = false })
	for k = 0, 6 do
		for _, s in { -1, 1 } do
			put(model, origin, "Column_Grand", CFrame.new(s * 18, 0, 34 + k * 20))
			put(model, origin, "Cistern_Brazier", CFrame.new(s * 13, 0, 44 + k * 20), { Shadows = false })
		end
	end
	for _, s in { -1, 1 } do
		put(model, origin, "Statue_Climber", CFrame.new(s * 26, 0, 168), { Flatten = false, Name = "GateStatue" })
	end
	return finish(model, Enum.ModelStreamingMode.Default)
end

-- ALL --------------------------------------------------------------------------------------------

function LandmarkBuilder.All(L: Layout, parent: Instance): { [string]: number }
	local counts: { [string]: number } = {}
	for _, step in {
		{ "ClimbersGuild", LandmarkBuilder.ClimbersGuild },
		{ "Cathedral", LandmarkBuilder.Cathedral },
		{ "Plaza", LandmarkBuilder.Plaza },
		{ "Market", LandmarkBuilder.Market },
		{ "Rotunda", LandmarkBuilder.Rotunda },
		{ "Harbour", LandmarkBuilder.Harbour },
		{ "Civic", LandmarkBuilder.Civic },
		{ "EastGate", LandmarkBuilder.EastGate },
		{ "FirstGate", LandmarkBuilder.FirstGate },
	} :: { { any } } do
		local name: string, fn: (Layout, Instance) -> Model = step[1], step[2]
		local m = fn(L, parent)
		counts[name] = #m:GetDescendants()
	end
	return counts
end

return LandmarkBuilder
