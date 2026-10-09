--!strict
--[[
	Maid
	Tracks everything a system creates (connections, instances, threads, tweens,
	cleanup callbacks, other Maids) so one Clean() call releases it all.
	Every system owns a Maid per player / per menu / per character and cleans it
	on leave, death or close.
]]

local Maid = {}
Maid.__index = Maid

type MaidData = {
	_tasks: { [any]: any },
	_cleaning: boolean,
}

export type Maid = {
	Add: (self: Maid, item: any) -> any, -- returns `item` (typed any to keep the type solver simple)
	Set: (self: Maid, key: string, item: any?) -> (),
	Get: (self: Maid, key: string) -> any?,
	Remove: (self: Maid, item: any) -> (),
	Clean: (self: Maid) -> (),
	Destroy: (self: Maid) -> (),
}

-- Releases a single task based on its runtime type.
local function cleanTask(item: any)
	local kind = typeof(item)
	if kind == "RBXScriptConnection" then
		item:Disconnect()
	elseif kind == "Instance" then
		if item:IsA("Tween") then
			item:Cancel()
		end
		item:Destroy()
	elseif kind == "function" then
		item()
	elseif kind == "thread" then
		-- Cancelling the running thread (or a dead one) errors, so guard it.
		if coroutine.status(item) ~= "dead" and coroutine.running() ~= item then
			pcall(task.cancel, item)
		end
	elseif kind == "table" then
		if type(item.Destroy) == "function" then
			item:Destroy()
		elseif type(item.Disconnect) == "function" then
			item:Disconnect()
		elseif type(item.Clean) == "function" then
			item:Clean()
		end
	end
end

function Maid.new(): Maid
	local self: MaidData = {
		_tasks = {},
		_cleaning = false,
	}
	return (setmetatable(self, Maid) :: any) :: Maid
end

-- Adds a task and returns it, so creation and tracking can be one expression:
-- local part = maid:Add(Instance.new("Part"))
function Maid.Add<T>(self: MaidData, item: T): T
	if self._cleaning then
		-- Adding while cleaning would leak; release immediately instead.
		cleanTask(item)
		return item
	end
	self._tasks[item] = true
	return item
end

-- Stores a task under a key, cleaning whatever was there before.
function Maid.Set(self: MaidData, key: string, item: any?)
	local previous = self._tasks[key]
	if previous ~= nil and previous ~= item then
		self._tasks[key] = nil
		cleanTask(previous)
	end
	if item ~= nil then
		if self._cleaning then
			cleanTask(item)
		else
			self._tasks[key] = item
		end
	end
end

function Maid.Get(self: MaidData, key: string): any?
	return self._tasks[key]
end

-- Stops tracking a task without cleaning it.
function Maid.Remove(self: MaidData, item: any)
	self._tasks[item] = nil
end

function Maid.Clean(self: MaidData)
	if self._cleaning then
		return
	end
	self._cleaning = true
	-- Tasks may add more tasks while cleaning; loop until empty.
	local key, value = next(self._tasks)
	while key ~= nil do
		self._tasks[key] = nil
		if value == true then
			cleanTask(key)
		else
			cleanTask(value)
		end
		key, value = next(self._tasks)
	end
	self._cleaning = false
end

Maid.Destroy = Maid.Clean

return Maid
