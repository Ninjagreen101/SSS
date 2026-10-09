--!strict
--[[
	SecretService
	Hidden places and their rewards (Spec: 2-4 hidden areas per floor).

	Secret areas: invisible parts tagged "SpireSecret" with attribute SecretId (display names in
	Strings.Secrets). The first time a player stands inside one they get a toast and discovery XP.

	Caches: models tagged "SpireCache" (a chest) with attributes
	    CacheId   unique id
	    Items     "IronScrap x8, ClimbersLongsword:Rare" (defId[:minRarity][ xCount], comma separated)
	    Gold      gold inside
	A server ProximityPrompt opens it once per player; what you found is remembered in
	Data.Discoveries ("Cache:<id>", "Area:<id>"). The prompt is created on the server and checks
	distance itself, so a client can't open a cache from across the map.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Strings = require(Shared.Strings)
local Net = require(Shared.Net)
local Log = require(Shared.Util.Log)

local DataService = require(script.Parent.DataService)
local Rewards = require(script.Parent.Rewards)
local ProgressionService = require(script.Parent.ProgressionService)
local AnalyticsService = require(script.Parent.AnalyticsService)

local log = Log.new("SecretService")

local TAG_SECRET = "SpireSecret"
local TAG_CACHE = "SpireCache"
local OPEN_DISTANCE = 12
local SCAN_INTERVAL = 0.5

local SecretService = {}

local areas: { [BasePart]: string } = {}

local function inside(part: BasePart, position: Vector3): boolean
	local p = part.CFrame:PointToObjectSpace(position)
	local half = part.Size / 2
	return math.abs(p.X) <= half.X and math.abs(p.Y) <= half.Y and math.abs(p.Z) <= half.Z
end

local function rootOf(player: Player): BasePart?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function secretName(id: string): string
	return Strings.Secrets[id] or id
end

local function openCache(player: Player, model: Model)
	local id = model:GetAttribute("CacheId")
	if type(id) ~= "string" then
		return
	end
	local root = rootOf(player)
	if not root or (root.Position - model:GetPivot().Position).Magnitude > OPEN_DISTANCE then
		return
	end
	local data = DataService.GetData(player)
	if not data then
		return
	end
	local key = `Cache:{id}`
	if data.Discoveries[key] then
		Net.Fire("Notify", player, "Toasts.CacheEmpty", {}, "Info")
		return
	end
	DataService.Set(player, { "Discoveries", key }, true)
	local itemSpec = model:GetAttribute("Items")
	local gold = model:GetAttribute("Gold")
	Rewards.Grant(player, if type(itemSpec) == "string" then itemSpec else nil, if type(gold) == "number" then gold else nil)
	ProgressionService.AwardDiscovery(player, "Cache")
	Net.Fire("Notify", player, "Toasts.CacheOpened", { gold = if type(gold) == "number" then gold else 0 }, "Success")
	AnalyticsService.Custom(player, "CacheOpened")
end

local function registerCache(instance: Instance)
	if not instance:IsA("Model") or instance:FindFirstChild("CachePrompt", true) then
		return
	end
	local host = instance.PrimaryPart or instance:FindFirstChildWhichIsA("BasePart", true)
	if not host then
		log:Warn(`cache {instance:GetFullName()} has no parts`)
		return
	end
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "CachePrompt"
	prompt.ActionText = Strings.Prompts.OpenCache
	prompt.ObjectText = Strings.Prompts.CacheObject
	prompt.HoldDuration = 0.6
	prompt.MaxActivationDistance = 8
	prompt.RequiresLineOfSight = false
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.GamepadKeyCode = Enum.KeyCode.ButtonX
	prompt.Parent = host
	prompt.Triggered:Connect(function(player: Player)
		openCache(player, instance)
	end)
end

local function registerArea(instance: Instance)
	if not instance:IsA("BasePart") then
		return
	end
	local id = instance:GetAttribute("SecretId")
	if type(id) ~= "string" then
		log:Warn(`secret area {instance:GetFullName()} has no SecretId`)
		return
	end
	instance.Transparency = 1
	instance.CanCollide = false
	instance.CanQuery = false
	instance.CanTouch = false
	areas[instance] = id
end

local function scan()
	for _, player in Players:GetPlayers() do
		local root = rootOf(player)
		local data = root and DataService.GetData(player)
		if not root or not data then
			continue
		end
		for part, id in areas do
			local key = `Area:{id}`
			if not data.Discoveries[key] and part.Parent and inside(part, root.Position) then
				DataService.Set(player, { "Discoveries", key }, true)
				ProgressionService.AwardDiscovery(player, "Secret")
				Net.Fire("Notify", player, "Toasts.SecretFound", { name = secretName(id) }, "Success")
				AnalyticsService.Custom(player, "SecretFound")
			end
		end
	end
end

function SecretService.Init() end

function SecretService.Start()
	for _, model in CollectionService:GetTagged(TAG_CACHE) do
		registerCache(model)
	end
	CollectionService:GetInstanceAddedSignal(TAG_CACHE):Connect(registerCache)
	for _, part in CollectionService:GetTagged(TAG_SECRET) do
		registerArea(part)
	end
	CollectionService:GetInstanceAddedSignal(TAG_SECRET):Connect(registerArea)
	CollectionService:GetInstanceRemovedSignal(TAG_SECRET):Connect(function(part)
		if part:IsA("BasePart") then
			areas[part] = nil
		end
	end)
	local acc = 0
	RunService.Heartbeat:Connect(function(dt: number)
		acc += dt
		if acc >= SCAN_INTERVAL then
			acc = 0
			scan()
		end
	end)
end

return SecretService
