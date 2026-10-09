--!strict
-- Net: the single definition of every remote. The server creates the
-- instances; clients wait for them. Client -> server remotes carry intent
-- only and every call passes a per-player, per-remote token bucket and an
-- argument type check before reaching a handler. Malformed or flooding calls
-- are rejected and logged.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = script.Parent
local Config = require(Shared.Config)

type ArgType = string -- "string" | "number" | "integer" | "boolean" | "Vector3" | "any"

type Definition = {
	kind: string, -- "Event" | "Function" | "Unreliable"
	args: { ArgType }?, -- client -> server argument contract (nil: server -> client only)
}

local DEFINITIONS: { [string]: Definition } = {
	-- client -> server (intent)
	RequestWaystoneTravel = { kind = "Event", args = { "string" } },
	RequestOpenChest = { kind = "Event", args = { "string" } },
	RequestWorldState = { kind = "Function", args = {} },
	RequestDungeonLeave = { kind = "Event", args = {} },
	-- server -> client (results)
	WorldFeedback = { kind = "Event" }, -- (kind: string, key: string, args: {any}?)
	WaystoneMenu = { kind = "Event" }, -- (atWaystoneId: string, discovered: {string})
	WaystoneDiscovered = { kind = "Event" }, -- (waystoneId: string)
	ChestOpened = { kind = "Event" }, -- (chestId: string, gold: number, items: {{id, count}})
	DungeonState = { kind = "Event" }, -- (state: {[string]: any})
	ZoneAmbience = { kind = "Unreliable" }, -- (zoneId: string)
}

local FOLDER_NAME = "Remotes"
local MAX_STRING = 64

local Net = {}

local folder: Folder? = nil
local remotes: { [string]: Instance } = {}

-- ------------------------------------------------------------ validation

local function valid(value: any, t: ArgType): boolean
	if t == "any" then
		return true
	elseif t == "string" then
		return type(value) == "string" and #value <= MAX_STRING and not string.find(value, "[%c]")
	elseif t == "number" then
		return type(value) == "number" and value == value and math.abs(value) ~= math.huge
	elseif t == "integer" then
		return type(value) == "number" and value == value and math.abs(value) < 2 ^ 31 and math.floor(value) == value
	elseif t == "boolean" then
		return type(value) == "boolean"
	elseif t == "Vector3" then
		if typeof(value) ~= "Vector3" then
			return false
		end
		local v = value :: Vector3
		for _, c in { v.X, v.Y, v.Z } do
			if c ~= c or math.abs(c) == math.huge then
				return false
			end
		end
		return true
	end
	return false
end

local function checkArgs(def: Definition, args: { any }, n: number): boolean
	local contract: { ArgType } = def.args or {}
	if n ~= #contract then
		return false
	end
	for i, t in contract do
		if not valid(args[i], t) then
			return false
		end
	end
	return true
end

-- ---------------------------------------------------------- rate limits

type Bucket = { tokens: number, stamp: number }
local buckets: { [Player]: { [string]: Bucket } } = {}
local violations: { [Player]: number } = {}

local function allow(player: Player, name: string): boolean
	local limit = Config.Net.Limits[name] or Config.Net.DefaultLimit
	local perPlayer = buckets[player]
	if not perPlayer then
		perPlayer = {}
		buckets[player] = perPlayer
	end
	local now = os.clock()
	local b = perPlayer[name]
	if not b then
		b = { tokens = limit.burst, stamp = now }
		perPlayer[name] = b
	end
	b.tokens = math.min(limit.burst, b.tokens + (now - b.stamp) * limit.rate)
	b.stamp = now
	if b.tokens < 1 then
		return false
	end
	b.tokens -= 1
	return true
end

local function reject(player: Player, name: string, reason: string)
	local count = (violations[player] or 0) + 1
	violations[player] = count
	player:SetAttribute("NetViolations", count)
	if count <= Config.Net.ViolationLogThreshold or count % 50 == 0 then
		warn(string.format("[Net] rejected %s from %s (%s) #%d", name, player.Name, reason, count))
	end
end

-- ------------------------------------------------------------------ server

function Net.initServer()
	assert(RunService:IsServer(), "Net.initServer on client")
	local f = ReplicatedStorage:FindFirstChild(FOLDER_NAME) :: Folder?
	if not f then
		local nf = Instance.new("Folder")
		nf.Name = FOLDER_NAME
		nf.Parent = ReplicatedStorage
		f = nf
	end
	folder = f
	local names = {}
	for name in DEFINITIONS do
		table.insert(names, name)
	end
	table.sort(names)
	for _, name in names do
		local def = DEFINITIONS[name]
		local className = if def.kind == "Function" then "RemoteFunction" elseif def.kind == "Unreliable" then "UnreliableRemoteEvent" else "RemoteEvent"
		local inst = (f :: Folder):FindFirstChild(name) or Instance.new(className)
		inst.Name = name
		inst.Parent = f
		remotes[name] = inst
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		buckets[player] = nil
		violations[player] = nil
	end)
end

-- Handle a client -> server event with validation and rate limiting.
function Net.onEvent(name: string, handler: (player: Player, ...any) -> ())
	local def = DEFINITIONS[name]
	assert(def and def.kind == "Event" and def.args, "not a client event: " .. name)
	local remote = remotes[name] :: RemoteEvent
	remote.OnServerEvent:Connect(function(player: Player, ...: any)
		local args = { ... }
		local n = select("#", ...)
		if not allow(player, name) then
			reject(player, name, "rate")
			return
		end
		if not checkArgs(def, args, n) then
			reject(player, name, "args")
			return
		end
		handler(player, table.unpack(args, 1, n))
	end)
end

function Net.onInvoke(name: string, handler: (player: Player, ...any) -> any)
	local def = DEFINITIONS[name]
	assert(def and def.kind == "Function", "not a function remote: " .. name)
	local remote = remotes[name] :: RemoteFunction
	remote.OnServerInvoke = function(player: Player, ...: any): any
		local args = { ... }
		local n = select("#", ...)
		if not allow(player, name) then
			reject(player, name, "rate")
			return nil
		end
		if not checkArgs(def, args, n) then
			reject(player, name, "args")
			return nil
		end
		return handler(player, table.unpack(args, 1, n))
	end
end

function Net.fire(player: Player, name: string, ...: any)
	local r = remotes[name]
	if r and r:IsA("RemoteEvent") then
		(r :: RemoteEvent):FireClient(player, ...)
	elseif r and r:IsA("UnreliableRemoteEvent") then
		(r :: UnreliableRemoteEvent):FireClient(player, ...)
	end
end

function Net.fireAll(name: string, ...: any)
	local r = remotes[name]
	if r and r:IsA("RemoteEvent") then
		(r :: RemoteEvent):FireAllClients(...)
	elseif r and r:IsA("UnreliableRemoteEvent") then
		(r :: UnreliableRemoteEvent):FireAllClients(...)
	end
end

-- ------------------------------------------------------------------ client

local function clientRemote(name: string): Instance
	local r = remotes[name]
	if r then
		return r
	end
	assert(DEFINITIONS[name], "unknown remote " .. name)
	local f = folder or ReplicatedStorage:WaitForChild(FOLDER_NAME) :: Folder
	folder = f
	local inst = (f :: Folder):WaitForChild(name)
	remotes[name] = inst
	return inst
end

function Net.connect(name: string, fn: (...any) -> ()): RBXScriptConnection
	local r = clientRemote(name)
	if r:IsA("UnreliableRemoteEvent") then
		return (r :: UnreliableRemoteEvent).OnClientEvent:Connect(fn)
	end
	return (r :: RemoteEvent).OnClientEvent:Connect(fn)
end

function Net.send(name: string, ...: any)
	(clientRemote(name) :: RemoteEvent):FireServer(...)
end

function Net.invoke(name: string, ...: any): any
	return (clientRemote(name) :: RemoteFunction):InvokeServer(...)
end

return Net
