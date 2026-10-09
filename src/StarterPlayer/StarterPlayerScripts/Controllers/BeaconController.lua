--!strict
--[[
	BeaconController
	Draws every Climber's Beacons (Spec Section 6) from their Beacons
	attribute: small glowing shapes in the primary Attunement's colour that
	circle the character, bob gently, and orbit tighter while fighting.

	  Sentry   a bright orb (its shots are server projectiles)
	  Aegis    a diamond; dim while broken ("~Aegis")
	  Lantern  a larger orb with a wide light; YOUR Lantern also reveals
	           things tagged LanternReveal within Lantern.RevealRadius
	           (their RevealTransparency attribute is how visible they get)
	  Relay    a ring, tinted with the stored spell's colour once it holds one

	Purely visual and local; beacons further than CULL_DISTANCE from the
	camera aren't drawn.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Items = require(Shared.Data.Items)
local Attributes = require(Shared.Attributes)
local Spells = require(Shared.Data.Spells)

local A = Attributes.Names
local B = Config.Current.Beacons
local player = Players.LocalPlayer

local BeaconController = {}

local CULL_DISTANCE = 150
local DEFAULT_COLOR = Color3.fromHex("#3FE0D0")

type Orb = { Behaviour: string, Broken: boolean, Part: BasePart, Light: PointLight }
type Look = { Key: string, Orbs: { Orb }, Radius: number }

local looks: { [Player]: Look } = {}
local folder: Folder? = nil
local revealed: { [BasePart]: number } = {} -- part -> its original transparency

local function beaconFolder(): Folder
	local existing = folder
	if existing and existing.Parent then
		return existing
	end
	local created = Instance.new("Folder")
	created.Name = "Beacons"
	created.Parent = Workspace
	folder = created
	return created
end

local function colorOf(target: Player): Color3
	-- A slotted Beacon core recolours the orbs (Shared/Data/Items, Core.Color).
	local coreId = target:GetAttribute(A.BeaconCore)
	local core = if type(coreId) == "string" then Items.Get(coreId) else nil
	if core and core.Core then
		return core.Core.Color
	end
	local name = target:GetAttribute(A.Attunement)
	local element = if type(name) == "string" then Spells.Attunement(name) else nil
	return if element then element.Color else DEFAULT_COLOR
end

local function makeOrb(behaviour: string, broken: boolean, color: Color3): Orb
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.Color = color
	if behaviour == "Aegis" then
		p.Shape = Enum.PartType.Block
		p.Size = Vector3.one * 0.6
	elseif behaviour == "Relay" then
		p.Shape = Enum.PartType.Cylinder
		p.Size = Vector3.new(0.15, 0.9, 0.9)
	elseif behaviour == "Lantern" then
		p.Shape = Enum.PartType.Ball
		p.Size = Vector3.one * 0.9
	else
		p.Shape = Enum.PartType.Ball
		p.Size = Vector3.one * 0.65
	end
	p.Transparency = if broken then 0.8 else 0.05
	local light = Instance.new("PointLight")
	light.Color = color
	light.Shadows = false
	light.Range = if behaviour == "Lantern" then B.Lantern.LightRange else 5
	light.Brightness = if behaviour == "Lantern" then B.Lantern.LightBrightness else 0.6
	light.Enabled = not broken
	light.Parent = p
	p.Parent = beaconFolder()
	return { Behaviour = behaviour, Broken = broken, Part = p, Light = light }
end

local function clear(look: Look)
	for _, orb in look.Orbs do
		orb.Part:Destroy()
	end
	table.clear(look.Orbs)
end

-- Rebuilds a player's orbs when their Beacons attribute changes.
local function rebuild(target: Player)
	local value = target:GetAttribute(A.Beacons)
	local key = if type(value) == "string" then value else ""
	local look = looks[target]
	if not look then
		look = { Key = "", Orbs = {}, Radius = B.OrbitRadiusIdle }
		looks[target] = look
	end
	if look.Key == key then
		return
	end
	look.Key = key
	clear(look)
	if key == "" then
		return
	end
	local color = colorOf(target)
	for _, token in string.split(key, ",") do
		local broken = string.sub(token, 1, 1) == "~"
		local behaviour = if broken then string.sub(token, 2) else token
		table.insert(look.Orbs, makeOrb(behaviour, broken, color))
	end
end

local function relayColor(target: Player): Color3?
	local spellId = target:GetAttribute(A.RelaySpell)
	local spell = if type(spellId) == "string" and spellId ~= "" then Spells.Get(spellId) else nil
	return if spell then spell.Element.Color else nil
end

-- LANTERN REVEAL -----------------------------------------------------------------

local function updateReveal(lanternAt: Vector3?)
	for _, instance in CollectionService:GetTagged(Attributes.Tags.LanternReveal) do
		if instance:IsA("BasePart") then
			local inRange = lanternAt ~= nil and (instance.Position - lanternAt).Magnitude <= B.Lantern.RevealRadius
			local original = revealed[instance]
			if inRange and not original then
				revealed[instance] = instance.Transparency
				local target = instance:GetAttribute("RevealTransparency")
				instance.Transparency = if type(target) == "number" then target else 0
			elseif not inRange and original then
				instance.Transparency = original
				revealed[instance] = nil
			end
		end
	end
end

-- STEP ---------------------------------------------------------------------------

local function step()
	local camera = Workspace.CurrentCamera
	local cameraPosition = if camera then camera.CFrame.Position else Vector3.zero
	local t = os.clock()
	local serverNow = Workspace:GetServerTimeNow()
	local myLantern: Vector3? = nil
	for target, look in looks do
		local character = target.Character
		local found = character and character:FindFirstChild("HumanoidRootPart")
		local root: BasePart? = if found and found:IsA("BasePart") then found else nil
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local alive = root ~= nil and humanoid ~= nil and humanoid.Health > 0
		local visible = alive and root ~= nil and (root.Position - cameraPosition).Magnitude <= CULL_DISTANCE
		local lastCombat = target:GetAttribute(A.LastCombat)
		local fighting = type(lastCombat) == "number" and serverNow - lastCombat <= Config.Combat.Vitals.CombatTimeout
		local goalRadius = if fighting then B.OrbitRadiusCombat else B.OrbitRadiusIdle
		look.Radius += (goalRadius - look.Radius) * 0.1
		local relay = relayColor(target)
		local count = #look.Orbs
		for index, orb in look.Orbs do
			orb.Part.Transparency = if not visible then 1 elseif orb.Broken then 0.8 else 0.05
			orb.Light.Enabled = visible and not orb.Broken
			if visible and root then
				local angle = t * B.OrbitSpeed + (index - 1) / count * math.pi * 2
				local bob = math.sin(t * 2 + index) * B.BobHeight
				local position = root.Position
					+ Vector3.new(math.cos(angle) * look.Radius, B.Height + bob, math.sin(angle) * look.Radius)
				orb.Part.CFrame = CFrame.new(position) * CFrame.Angles(t * 1.5, t * 2, 0)
				if orb.Behaviour == "Relay" then
					orb.Part.Color = relay or colorOf(target)
				end
				if orb.Behaviour == "Lantern" and target == player then
					myLantern = position
				end
			end
		end
	end
	updateReveal(myLantern)
end

local function watch(target: Player)
	target:GetAttributeChangedSignal(A.Beacons):Connect(function()
		rebuild(target)
	end)
	target:GetAttributeChangedSignal(A.Attunement):Connect(function()
		local look = looks[target]
		if look then
			look.Key = ""
			rebuild(target)
		end
	end)
	rebuild(target)
end

function BeaconController.Start()
	Players.PlayerAdded:Connect(watch)
	for _, other in Players:GetPlayers() do
		watch(other)
	end
	Players.PlayerRemoving:Connect(function(leaving: Player)
		local look = looks[leaving]
		if look then
			clear(look)
		end
		looks[leaving] = nil
	end)
	RunService.RenderStepped:Connect(step)
end

return BeaconController
