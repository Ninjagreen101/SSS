--!strict
--[[
	Net
	The only way systems talk across the network.

	Server:
		Net.Init()                          -- creates every remote (bootstrap calls this first)
		Net.On(name, handler)               -- handler(player, ...validated args)
		Net.OnInvoke(name, handler)         -- RemoteFunction handler, returns a value
		Net.Fire(name, player, ...)         -- to one client
		Net.FireAll / FireList / FireExcept
		Net.Violation                       -- Signal(player, remoteName, kind, reason)

	Client:
		Net.Init()                          -- waits for the remotes to replicate
		Net.FireServer(name, ...)
		Net.InvokeServer(name, ...)
		Net.OnClient(name, handler)

	Every client -> server call is rate limited (Config.Net.Rates) and its
	arguments checked against Definitions before any handler runs. Rejected
	calls never reach game code; they raise a Violation for AntiExploitService.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(script.Parent.Config)
local Schema = require(script.Parent.Util.Schema)
local Signal = require(script.Parent.Util.Signal)
local Log = require(script.Parent.Util.Log)
local Definitions = require(script.Definitions)
local RateLimiter = require(script.RateLimiter)

export type ViolationKind = "RateLimited" | "Malformed" | "WrongDirection"

local IS_SERVER = RunService:IsServer()
local FOLDER_NAME = "Remotes"
local log = Log.new("Net")

local Net = {}

Net.Violation = Signal.new() :: Signal.Signal<Player, string, ViolationKind, string>

local remotes: { [string]: Instance } = {}
local serverHandlers: { [string]: (Player, ...any) -> () } = {}
local invokeHandlers: { [string]: (Player, ...any) -> any } = {}
local limiter = RateLimiter.new()
local initialized = false

local function getDef(name: string): Definitions.RemoteDef
	local def = Definitions[name]
	if not def then
		error(`[Net] Unknown remote '{name}'`, 3)
	end
	return def
end

local function className(kind: Definitions.RemoteKind): string
	if kind == "Function" then
		return "RemoteFunction"
	elseif kind == "Unreliable" then
		return "UnreliableRemoteEvent"
	end
	return "RemoteEvent"
end

-- Rate limit + validate one inbound call. Returns true if it may proceed.
local function admit(player: Player, name: string, def: Definitions.RemoteDef, ...: any): boolean
	if def.Direction ~= "ToServer" then
		Net.Violation:Fire(player, name, "WrongDirection", "client fired a server-to-client remote")
		return false
	end
	local rate = Config.Net.Rates[name] or Config.Net.DefaultRate
	if not limiter:Take(player, name, rate.Burst, rate.PerSecond) then
		Net.Violation:Fire(player, name, "RateLimited", "rate limit exceeded")
		return false
	end
	local ok, reason = Schema.Args(def.Args, ...)
	if not ok then
		Net.Violation:Fire(player, name, "Malformed", reason or "invalid arguments")
		return false
	end
	return true
end

local function initServer()
	local folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME

	for name, def in Definitions do
		local remote = Instance.new(className(def.Kind))
		remote.Name = name
		remotes[name] = remote

		if def.Kind == "Function" then
			local fn = remote :: RemoteFunction
			fn.OnServerInvoke = function(player: Player, ...: any): any
				if not admit(player, name, def, ...) then
					return nil
				end
				local handler = invokeHandlers[name]
				if not handler then
					return nil
				end
				return handler(player, ...)
			end
		elseif def.Kind == "Unreliable" then
			-- Always connected (even for ToClient remotes) so junk sent by a
			-- client is dropped instead of queuing on the server.
			(remote :: UnreliableRemoteEvent).OnServerEvent:Connect(function(player: Player, ...: any)
				if admit(player, name, def, ...) then
					local handler = serverHandlers[name]
					if handler then
						handler(player, ...)
					end
				end
			end)
		else
			(remote :: RemoteEvent).OnServerEvent:Connect(function(player: Player, ...: any)
				if admit(player, name, def, ...) then
					local handler = serverHandlers[name]
					if handler then
						handler(player, ...)
					end
				end
			end)
		end

		remote.Parent = folder
	end

	Players.PlayerRemoving:Connect(function(player: Player)
		limiter:ClearPlayer(player)
	end)

	folder.Parent = ReplicatedStorage
end

local function initClient()
	local folder = ReplicatedStorage:WaitForChild(FOLDER_NAME, 30)
	if not folder then
		error("[Net] Remotes folder never replicated")
	end
	for name in Definitions do
		local remote = folder:WaitForChild(name, 30)
		if remote then
			remotes[name] = remote
		else
			log:Warn(`Remote '{name}' missing on client`)
		end
	end
end

function Net.Init()
	if initialized then
		return
	end
	initialized = true
	if IS_SERVER then
		initServer()
	else
		initClient()
	end
end

local function getRemote(name: string): Instance
	local remote = remotes[name]
	if not remote then
		error(`[Net] Remote '{name}' not initialized (call Net.Init first)`, 3)
	end
	return remote
end

-- SERVER API ---------------------------------------------------------------

function Net.On(name: string, handler: (Player, ...any) -> ())
	assert(IS_SERVER, "Net.On is server-only")
	local def = getDef(name)
	assert(def.Direction == "ToServer" and def.Kind ~= "Function", `[Net] '{name}' is not a client->server event`)
	assert(serverHandlers[name] == nil, `[Net] '{name}' already has a handler`)
	serverHandlers[name] = handler
end

function Net.OnInvoke(name: string, handler: (Player, ...any) -> any)
	assert(IS_SERVER, "Net.OnInvoke is server-only")
	local def = getDef(name)
	assert(def.Kind == "Function", `[Net] '{name}' is not a RemoteFunction`)
	invokeHandlers[name] = handler
end

local function fireOne(remote: Instance, player: Player, ...: any)
	if remote:IsA("UnreliableRemoteEvent") then
		remote:FireClient(player, ...)
	else
		(remote :: RemoteEvent):FireClient(player, ...)
	end
end

function Net.Fire(name: string, player: Player, ...: any)
	assert(IS_SERVER, "Net.Fire is server-only")
	local def = getDef(name)
	assert(def.Direction == "ToClient", `[Net] '{name}' is not server->client`)
	if player.Parent ~= Players then
		return
	end
	fireOne(getRemote(name), player, ...)
end

function Net.FireAll(name: string, ...: any)
	assert(IS_SERVER, "Net.FireAll is server-only")
	local def = getDef(name)
	assert(def.Direction == "ToClient", `[Net] '{name}' is not server->client`)
	local remote = getRemote(name)
	if remote:IsA("UnreliableRemoteEvent") then
		remote:FireAllClients(...)
	else
		(remote :: RemoteEvent):FireAllClients(...)
	end
end

function Net.FireList(name: string, players: { Player }, ...: any)
	assert(IS_SERVER, "Net.FireList is server-only")
	getDef(name)
	local remote = getRemote(name)
	for _, player in players do
		if player.Parent == Players then
			fireOne(remote, player, ...)
		end
	end
end

function Net.FireExcept(name: string, except: Player, ...: any)
	assert(IS_SERVER, "Net.FireExcept is server-only")
	getDef(name)
	local remote = getRemote(name)
	for _, player in Players:GetPlayers() do
		if player ~= except then
			fireOne(remote, player, ...)
		end
	end
end

-- CLIENT API ---------------------------------------------------------------

function Net.FireServer(name: string, ...: any)
	assert(not IS_SERVER, "Net.FireServer is client-only")
	local def = getDef(name)
	assert(def.Direction == "ToServer" and def.Kind ~= "Function", `[Net] '{name}' is not a client->server event`)
	local remote = getRemote(name)
	if remote:IsA("UnreliableRemoteEvent") then
		remote:FireServer(...)
	else
		(remote :: RemoteEvent):FireServer(...)
	end
end

function Net.InvokeServer(name: string, ...: any): any
	assert(not IS_SERVER, "Net.InvokeServer is client-only")
	local def = getDef(name)
	assert(def.Kind == "Function", `[Net] '{name}' is not a RemoteFunction`)
	return (getRemote(name) :: RemoteFunction):InvokeServer(...)
end

function Net.OnClient(name: string, handler: (...any) -> ()): RBXScriptConnection
	assert(not IS_SERVER, "Net.OnClient is client-only")
	local def = getDef(name)
	assert(def.Direction == "ToClient", `[Net] '{name}' is not server->client`)
	local remote = getRemote(name)
	if remote:IsA("UnreliableRemoteEvent") then
		return remote.OnClientEvent:Connect(handler)
	end
	return (remote :: RemoteEvent).OnClientEvent:Connect(handler)
end

return Net
