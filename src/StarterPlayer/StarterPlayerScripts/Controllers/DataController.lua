--!strict
--[[
	DataController
	The client's read-only replica of its own saved data. Receives one
	snapshot after ClientReady, then batched path changes. Settings are the
	one thing the client edits: SetSetting applies locally at once (so the
	UI feels instant), then sends a debounced, server-validated save request.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Types = require(Shared.Types)
local Net = require(Shared.Net)
local Signal = require(Shared.Util.Signal)
local Promise = require(Shared.Util.Promise)
local TableUtil = require(Shared.Util.TableUtil)
local SettingsSchema = require(Shared.Data.SettingsSchema)

type PlayerData = Types.PlayerData

local DataController = {}

DataController.Ready = Signal.new() :: Signal.Signal<PlayerData>
-- Fired for every applied change: (path, value)
DataController.Changed = Signal.new() :: Signal.Signal<{ string }, any>

local data: PlayerData? = nil
local readyWaiters: { (PlayerData) -> () } = {}
local pendingSettings: { [string]: any } = {}
local settingsFlush: thread? = nil

local function startsWith(path: { string }, prefix: { string }): boolean
	if #path < #prefix then
		-- A change to a parent branch also affects the prefix.
		for index = 1, #path do
			if path[index] ~= prefix[index] then
				return false
			end
		end
		return true
	end
	for index, key in prefix do
		if path[index] ~= key then
			return false
		end
	end
	return true
end

local function applyChange(path: { string }, value: any)
	local current = data
	if not current then
		return
	end
	TableUtil.SetPath(current :: any, path, value)
	DataController.Changed:Fire(path, value)
end

local function flushSettings()
	settingsFlush = nil
	for key, value in pendingSettings do
		Net.FireServer("RequestSaveSetting", key, value)
	end
	table.clear(pendingSettings)
end

function DataController.IsReady(): boolean
	return data ~= nil
end

function DataController.GetData(): PlayerData?
	return data
end

function DataController.Get(path: { string }): any
	if not data then
		return nil
	end
	return TableUtil.GetPath(data :: any, path)
end

function DataController.WaitForData(): Promise.Promise<PlayerData>
	if data then
		return Promise.resolve(data :: PlayerData)
	end
	return Promise.new(function(resolve: (PlayerData) -> ())
		table.insert(readyWaiters, resolve)
	end)
end

-- Calls `callback(value)` now (if loaded) and whenever anything at or under
-- `path` changes. Returns the connection.
function DataController.Observe(path: { string }, callback: (any) -> ()): Signal.Connection
	if data then
		task.spawn(callback, DataController.Get(path))
	end
	local readyConnection = DataController.Ready:Connect(function()
		callback(DataController.Get(path))
	end)
	local changeConnection = DataController.Changed:Connect(function(changedPath: { string })
		if startsWith(changedPath, path) then
			callback(DataController.Get(path))
		end
	end)
	-- Return a combined connection.
	local combined = {
		Connected = true,
	}
	function combined.Disconnect(self: any)
		self.Connected = false
		readyConnection:Disconnect()
		changeConnection:Disconnect()
	end
	combined.Destroy = combined.Disconnect
	return (combined :: any) :: Signal.Connection
end

-- A setting's value (defaults until data arrives).
function DataController.GetSetting(key: string): any
	local value = DataController.Get({ "Settings", key })
	if value == nil then
		return (SettingsSchema.Defaults :: any)[key]
	end
	return value
end

-- Applies a setting locally and queues a validated save on the server.
function DataController.SetSetting(key: string, value: any): boolean
	local validator = SettingsSchema.Validators[key]
	if not validator then
		return false
	end
	local ok = validator(value)
	if not ok then
		return false
	end
	local copy = TableUtil.DeepCopy(value)
	if data then
		applyChange({ "Settings", key }, copy)
	end
	pendingSettings[key] = copy
	if settingsFlush then
		task.cancel(settingsFlush)
	end
	settingsFlush = task.delay(Config.Data.SaveSettingsDebounce, flushSettings)
	return true
end

function DataController.Init()
	Net.OnClient("DataSnapshot", function(snapshot: any)
		data = snapshot :: PlayerData
		local loaded = data :: PlayerData
		-- Re-apply settings edited before the snapshot arrived.
		for key, value in pendingSettings do
			TableUtil.SetPath(loaded :: any, { "Settings", key }, TableUtil.DeepCopy(value))
		end
		DataController.Ready:Fire(loaded)
		local waiters = readyWaiters
		readyWaiters = {}
		for _, resolve in waiters do
			resolve(loaded)
		end
	end)

	Net.OnClient("DataChanged", function(changes: { Types.DataChange })
		for _, change in changes do
			-- Ignore echoes of settings we still have queued (local value wins).
			local isPendingSetting = change.Path[1] == "Settings" and pendingSettings[change.Path[2]] ~= nil
			if not isPendingSetting then
				applyChange(change.Path, change.Value)
			end
		end
	end)
end

function DataController.Start()
	-- Every controller has connected its listeners in Init, so it is now
	-- safe for the server to send the snapshot.
	Net.FireServer("ClientReady")
end

return DataController
