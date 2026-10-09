--!strict
--[[
	CanalFishController
	Small dark tidefish with glowing tails swim in Lowharbor's Current canals. Client-only: nothing
	replicates, and nothing runs where nobody is looking.

	- Each canal leg is found by its CurrentSeam part (the Neon line on the canal bed). The fish
	  appear when a seam streams in and go away when it streams out.
	- A school swims a slow figure-eight down the length of its leg, between the bed and the
	  surface, so the fish turn smoothly at the ends instead of flipping around.
	- Only schools within CULL_RADIUS of the camera are moved, and moved in one BulkMoveTo.
	  The rest are taken out of the world.
	- The school size scales with graphics quality. On the lowest settings there are no fish.
]]

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local CanalFishController = {}

local SEAM_NAME = "CurrentSeam"
local CULL_RADIUS = 200 -- studs from the camera to the nearest point of a leg
local MAX_FISH = 8 -- per leg at full quality
local MIN_QUALITY = 0.25 -- below this, no fish at all
local LANE = 3.4 -- half the width a school uses (canals are 14 wide, walls included)
local END_MARGIN = 8 -- fish stay this far from each end of a leg (the waterfalls)
local BED_CLEARANCE = 1.1 -- above the seam
local SURFACE_GAP = 1.2 -- below the water line (seam + 4.4)
local WATER_ABOVE_SEAM = 4.4

local BODY_COLOR = Color3.fromHex("1B2628")
local TAIL_COLOR = Color3.fromHex("3FE0D0")

type Fish = {
	Body: Part,
	Tail: Part,
	Phase: number,
	Rate: number, -- radians per second along the figure-eight
	Lane: number,
	Depth: number,
	Wiggle: number,
	Size: number,
}

type School = {
	Seam: BasePart,
	Folder: Folder,
	Fish: { Fish },
	Visible: boolean,
}

local schools: { [BasePart]: School } = {}
local holder: Folder? = nil
local random = Random.new()

local function qualityScale(): number
	local ok, level = pcall(function()
		return UserSettings().GameSettings.SavedQualityLevel.Value
	end)
	if not ok or type(level) ~= "number" or level == 0 then
		return 0.6 -- automatic quality: be conservative
	end
	return math.clamp(level / 10, 0.2, 1)
end

-- Client-made parts never replicate, so the schools can live in Workspace itself (not under the
-- camera, which can be replaced and would take the fish with it).
local function ensureHolder(): Folder
	local existing = holder
	if existing and existing.Parent then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = "CanalFish"
	folder.Parent = Workspace
	holder = folder
	return folder
end

local function quietPart(name: string, size: Vector3, color: Color3, material: Enum.Material): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Color = color
	part.Material = material
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Massless = true
	return part
end

local function makeFish(parent: Instance): Fish
	local size = random:NextNumber(0.75, 1.25)
	local body = quietPart("Body", Vector3.new(0.5, 0.42, 1.6) * size, BODY_COLOR, Enum.Material.SmoothPlastic)
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Sphere
	mesh.Parent = body
	body.Parent = parent
	local tail = quietPart("Tail", Vector3.new(0.08, 0.5, 0.55) * size, TAIL_COLOR, Enum.Material.Neon)
	tail.Transparency = 0.25
	tail.Parent = parent
	return {
		Body = body,
		Tail = tail,
		Phase = random:NextNumber(0, 2 * math.pi),
		Rate = random:NextNumber(0.05, 0.085),
		Lane = random:NextNumber(0.5, 1) * (if random:NextNumber() < 0.5 then -1 else 1),
		Depth = random:NextNumber(),
		Wiggle = random:NextNumber(7, 11),
		Size = size,
	}
end

local function addSeam(part: Instance)
	if not part:IsA("BasePart") or part.Name ~= SEAM_NAME or schools[part] then
		return
	end
	local quality = qualityScale()
	if quality < MIN_QUALITY then
		return
	end
	local folder = Instance.new("Folder")
	folder.Name = "School"
	local school: School = { Seam = part, Folder = folder, Fish = {}, Visible = false }
	local count = math.max(2, math.floor(MAX_FISH * quality + 0.5))
	for _ = 1, count do
		table.insert(school.Fish, makeFish(folder))
	end
	schools[part] = school
end

local function removeSeam(part: Instance)
	if not part:IsA("BasePart") then
		return
	end
	local school = schools[part]
	if school then
		school.Folder:Destroy()
		schools[part] = nil
	end
end

local parts: { BasePart } = {}
local frames: { CFrame } = {}

local function step()
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local camPos = camera.CFrame.Position
	local now = os.clock()
	local folder = ensureHolder()
	table.clear(parts)
	table.clear(frames)
	for seam, school in schools do
		if not seam.Parent then
			continue
		end
		local cf = seam.CFrame
		local half = math.max(1, seam.Size.Z / 2 - END_MARGIN)
		-- distance from the camera to the leg (a segment along the seam)
		local rel = cf:PointToObjectSpace(camPos)
		local along = math.clamp(rel.Z, -half, half)
		local near = (Vector3.new(rel.X, rel.Y, rel.Z - along)).Magnitude < CULL_RADIUS
		if near ~= school.Visible then
			school.Visible = near
			school.Folder.Parent = if near then folder else nil
		end
		if not near then
			continue
		end
		local lowY = BED_CLEARANCE
		local highY = WATER_ABOVE_SEAM - SURFACE_GAP
		for _, fish in school.Fish do
			-- figure-eight: once along the leg while crossing the lane twice
			local t = now * fish.Rate + fish.Phase
			local z = math.sin(t) * half
			local x = math.sin(2 * t) * LANE * fish.Lane
			local dz = math.cos(t) * half
			local dx = 2 * math.cos(2 * t) * LANE * fish.Lane
			local y = lowY + (highY - lowY) * (0.5 + 0.5 * math.sin(t * 3 + fish.Depth * 6.28)) * 0.8
				+ (highY - lowY) * 0.1
			local pos = cf:PointToWorldSpace(Vector3.new(x, y, z))
			local heading = cf:VectorToWorldSpace(Vector3.new(dx, 0, dz))
			if heading.Magnitude < 1e-3 then
				heading = cf.LookVector
			end
			local body = CFrame.lookAt(pos, pos + heading)
			local sway = math.sin(now * fish.Wiggle + fish.Phase) * 0.18
			body *= CFrame.Angles(0, sway, 0)
			local tailSwing = math.sin(now * fish.Wiggle + fish.Phase - 1.2) * 0.6
			local tail = body * CFrame.new(0, 0, 0.8 * fish.Size) * CFrame.Angles(0, tailSwing, 0)
				* CFrame.new(0, 0, 0.25 * fish.Size)
			table.insert(parts, fish.Body)
			table.insert(frames, body)
			table.insert(parts, fish.Tail)
			table.insert(frames, tail)
		end
	end
	if #parts > 0 then
		Workspace:BulkMoveTo(parts, frames, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

local function watch(canals: Instance)
	for _, child in canals:GetChildren() do
		addSeam(child)
	end
	canals.ChildAdded:Connect(addSeam)
	canals.ChildRemoved:Connect(removeSeam)
end

function CanalFishController.Init()
	-- the canals live in the floor model; nothing to wire up before Start
end

function CanalFishController.Start()
	task.spawn(function()
		local floor = Workspace:WaitForChild("Floor1", 60)
		local town = floor and floor:WaitForChild("Town", 60)
		local infra = town and town:WaitForChild("Infrastructure", 60)
		local canals = infra and infra:WaitForChild("Canals", 60)
		if canals then
			watch(canals)
		end
	end)
	RunService.RenderStepped:Connect(step)
end

return CanalFishController
