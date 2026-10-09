--!strict
-- Maid: collects connections, instances, threads and cleanup callbacks and
-- releases all of them with one call (player leave, death, menu close).

export type Task = RBXScriptConnection | Instance | thread | () -> () | { Destroy: (any) -> () }

export type Maid = {
	_tasks: { [any]: Task },
	Give: (self: Maid, item: Task) -> Task,
	Set: (self: Maid, key: string, item: Task?) -> (),
	Clean: (self: Maid) -> (),
	Destroy: (self: Maid) -> (),
}

local Maid = {}
Maid.__index = Maid

function Maid.new(): Maid
	return setmetatable({ _tasks = {} }, Maid) :: any
end

local function release(item: Task)
	if typeof(item) == "RBXScriptConnection" then
		item:Disconnect()
	elseif typeof(item) == "Instance" then
		item:Destroy()
	elseif type(item) == "thread" then
		if coroutine.status(item) ~= "dead" then
			pcall(task.cancel, item)
		end
	elseif type(item) == "function" then
		item()
	elseif type(item) == "table" and type((item :: any).Destroy) == "function" then
		(item :: any):Destroy()
	end
end

function Maid.Give(self: Maid, item: Task): Task
	table.insert(self._tasks :: any, item)
	return item
end

function Maid.Set(self: Maid, key: string, item: Task?)
	local old = self._tasks[key]
	if old ~= nil then
		self._tasks[key] = nil
		release(old)
	end
	if item ~= nil then
		self._tasks[key] = item
	end
end

function Maid.Clean(self: Maid)
	local items = self._tasks
	self._tasks = {}
	for _, item in items do
		release(item)
	end
end

function Maid.Destroy(self: Maid)
	self:Clean()
end

return Maid
