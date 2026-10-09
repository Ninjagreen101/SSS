--!strict
--[[
	Promise
	Small, typed promise for async work: profile loading, confirm dialogs,
	teleports. A promise settles once (Resolved / Rejected / Cancelled).
	Handlers always run in their own thread so they may yield safely.
	Unhandled rejections are warned in Output so errors are never silent.
]]

export type Status = "Pending" | "Resolved" | "Rejected" | "Cancelled"

-- Chained promises lose their value type; callers cast with `:: T` when needed.
export type AnyPromise = {
	andThen: (self: AnyPromise, onResolved: ((any) -> any)?, onRejected: ((any) -> any)?) -> AnyPromise,
	catch: (self: AnyPromise, onRejected: (any) -> any) -> AnyPromise,
	finally: (self: AnyPromise, handler: (Status) -> ()) -> AnyPromise,
	await: (self: AnyPromise) -> (boolean, any),
	expect: (self: AnyPromise) -> any,
	cancel: (self: AnyPromise) -> (),
	getStatus: (self: AnyPromise) -> Status,
}

export type Promise<T> = {
	andThen: (self: Promise<T>, onResolved: ((T) -> any)?, onRejected: ((any) -> any)?) -> AnyPromise,
	catch: (self: Promise<T>, onRejected: (any) -> any) -> AnyPromise,
	finally: (self: Promise<T>, handler: (Status) -> ()) -> Promise<T>,
	await: (self: Promise<T>) -> (boolean, any),
	expect: (self: Promise<T>) -> T,
	cancel: (self: Promise<T>) -> (),
	getStatus: (self: Promise<T>) -> Status,
}

type Impl = {
	_status: Status,
	_value: any,
	_callbacks: { () -> () },
	_cancelHooks: { () -> () },
	_handled: boolean,
}

local Methods = {}
local Meta = { __index = Methods, __tostring = function()
	return "Promise"
end }

local Promise = {}

local function traceback(err: any): string
	return debug.traceback(tostring(err), 2)
end

local function isPromise(value: any): boolean
	return type(value) == "table" and getmetatable(value) == Meta
end

local function newPending(): Impl
	local self: Impl = {
		_status = "Pending",
		_value = nil,
		_callbacks = {},
		_cancelHooks = {},
		_handled = false,
	}
	setmetatable(self :: any, Meta)
	return self
end

local function flush(self: Impl)
	local callbacks = self._callbacks
	self._callbacks = {}
	for _, callback in callbacks do
		task.spawn(callback)
	end
end

local settle: (self: Impl, status: Status, value: any) -> ()

settle = function(self: Impl, status: Status, value: any)
	if self._status ~= "Pending" then
		return
	end
	if status == "Resolved" and isPromise(value) then
		-- Adopt the state of a returned promise.
		local inner = value :: Impl
		inner._handled = true
		local function adopt()
			if inner._status == "Cancelled" then
				Methods.cancel(self)
			else
				settle(self, inner._status, inner._value)
			end
		end
		if inner._status == "Pending" then
			table.insert(inner._callbacks, adopt)
		else
			adopt()
		end
		return
	end
	self._status = status
	self._value = value
	table.clear(self._cancelHooks)
	if status == "Rejected" then
		task.defer(function()
			if not self._handled then
				warn(`[Promise] Unhandled rejection: {tostring(value)}`)
			end
		end)
	end
	flush(self)
end

function Promise.new<T>(executor: (resolve: (T) -> (), reject: (any) -> (), onCancel: (() -> ()) -> ()) -> ()): Promise<T>
	local self = newPending()
	local function resolve(value: T)
		settle(self, "Resolved", value)
	end
	local function reject(err: any)
		settle(self, "Rejected", err)
	end
	local function onCancel(hook: () -> ())
		if self._status == "Cancelled" then
			hook()
		elseif self._status == "Pending" then
			table.insert(self._cancelHooks, hook)
		end
	end
	task.spawn(function()
		local ok, err = xpcall(function(): any
			executor(resolve, reject, onCancel)
			return nil
		end, traceback)
		if not ok then
			reject(err)
		end
	end)
	return (self :: any) :: Promise<T>
end

function Promise.resolve<T>(value: T): Promise<T>
	local self = newPending()
	settle(self, "Resolved", value)
	return (self :: any) :: Promise<T>
end

function Promise.reject(err: any): AnyPromise
	local self = newPending()
	settle(self, "Rejected", err)
	return (self :: any) :: AnyPromise
end

-- Resolves with the real elapsed time after `seconds`.
function Promise.delay(seconds: number): Promise<number>
	return Promise.new(function(resolve: (number) -> (), _reject, onCancel)
		local started = os.clock()
		local thread = task.delay(seconds, function()
			resolve(os.clock() - started)
		end)
		onCancel(function()
			pcall(task.cancel, thread)
		end)
	end)
end

-- Resolves with every value in order once all resolve; rejects on the first rejection.
function Promise.all(promises: { AnyPromise }): Promise<{ any }>
	return Promise.new(function(resolve: ({ any }) -> (), reject)
		local count = #promises
		if count == 0 then
			resolve({})
			return
		end
		local results = table.create(count)
		local remaining = count
		for index, item in promises do
			item:andThen(function(value: any)
				results[index] = value
				remaining -= 1
				if remaining == 0 then
					resolve(results)
				end
				return nil
			end, function(err: any)
				reject(err)
				return nil
			end)
		end
	end)
end

-- Settles the same way as the first promise to settle.
function Promise.race(promises: { AnyPromise }): AnyPromise
	local result = Promise.new(function(resolve: (any) -> (), reject)
		for _, item in promises do
			item:andThen(function(value: any)
				resolve(value)
				return nil
			end, function(err: any)
				reject(err)
				return nil
			end)
		end
	end)
	return (result :: any) :: AnyPromise
end

function Promise.is(value: any): boolean
	return isPromise(value)
end

function Methods.andThen(self: Impl, onResolved: ((any) -> any)?, onRejected: ((any) -> any)?): Impl
	self._handled = true
	local child = newPending()
	local function run()
		if self._status == "Resolved" then
			if onResolved then
				local ok, result = xpcall(onResolved, traceback, self._value)
				settle(child, if ok then "Resolved" else "Rejected", result)
			else
				settle(child, "Resolved", self._value)
			end
		elseif self._status == "Rejected" then
			if onRejected then
				local ok, result = xpcall(onRejected, traceback, self._value)
				settle(child, if ok then "Resolved" else "Rejected", result)
			else
				settle(child, "Rejected", self._value)
			end
		else
			Methods.cancel(child)
		end
	end
	if self._status == "Pending" then
		table.insert(self._callbacks, run)
	else
		task.spawn(run)
	end
	return child
end

function Methods.catch(self: Impl, onRejected: (any) -> any): Impl
	return Methods.andThen(self, nil, onRejected)
end

function Methods.finally(self: Impl, handler: (Status) -> ()): Impl
	self._handled = true
	local function run()
		handler(self._status)
	end
	if self._status == "Pending" then
		table.insert(self._callbacks, run)
	else
		task.spawn(run)
	end
	return self
end

function Methods.await(self: Impl): (boolean, any)
	self._handled = true
	if self._status == "Pending" then
		local thread = coroutine.running()
		table.insert(self._callbacks, function()
			task.spawn(thread)
		end)
		coroutine.yield()
	end
	if self._status == "Resolved" then
		return true, self._value
	elseif self._status == "Cancelled" then
		return false, "Cancelled"
	end
	return false, self._value
end

function Methods.expect(self: Impl): any
	local ok, value = Methods.await(self)
	if not ok then
		error(value, 2)
	end
	return value
end

function Methods.cancel(self: Impl)
	if self._status ~= "Pending" then
		return
	end
	self._status = "Cancelled"
	local hooks = self._cancelHooks
	self._cancelHooks = {}
	for _, hook in hooks do
		task.spawn(hook)
	end
	flush(self)
end

function Methods.getStatus(self: Impl): Status
	return self._status
end

return Promise
