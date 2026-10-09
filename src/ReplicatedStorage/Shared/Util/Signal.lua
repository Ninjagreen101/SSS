--!strict
-- Typed in-process signal for communication between systems.

export type Connection = {
	Connected: boolean,
	Disconnect: (self: Connection) -> (),
}

export type Signal<T...> = {
	Connect: (self: Signal<T...>, fn: (T...) -> ()) -> Connection,
	Once: (self: Signal<T...>, fn: (T...) -> ()) -> Connection,
	Fire: (self: Signal<T...>, T...) -> (),
	Wait: (self: Signal<T...>) -> T...,
	DisconnectAll: (self: Signal<T...>) -> (),
}

local Signal = {}
Signal.__index = Signal

type Handler = { fn: (...any) -> (), connected: boolean, once: boolean }

local ConnectionClass = {}
ConnectionClass.__index = ConnectionClass

function ConnectionClass.Disconnect(self: any)
	self.Connected = false
	self._handler.connected = false
end

function Signal.new<T...>(): Signal<T...>
	local self = setmetatable({ _handlers = {} :: { Handler } }, Signal)
	return self :: any
end

local function connect(self: any, fn: (...any) -> (), once: boolean): Connection
	local handler: Handler = { fn = fn, connected = true, once = once }
	table.insert(self._handlers, handler)
	return setmetatable({ Connected = true, _handler = handler }, ConnectionClass) :: any
end

function Signal.Connect(self: any, fn: (...any) -> ()): Connection
	return connect(self, fn, false)
end

function Signal.Once(self: any, fn: (...any) -> ()): Connection
	return connect(self, fn, true)
end

function Signal.Fire(self: any, ...: any)
	local handlers = self._handlers :: { Handler }
	local alive: { Handler } = {}
	for _, h in handlers do
		if h.connected then
			if h.once then
				h.connected = false
			else
				table.insert(alive, h)
			end
			task.spawn(h.fn, ...)
		end
	end
	self._handlers = alive
end

function Signal.Wait(self: any): ...any
	local thread = coroutine.running()
	connect(self, function(...: any)
		task.spawn(thread, ...)
	end, true)
	return coroutine.yield()
end

function Signal.DisconnectAll(self: any)
	for _, h in self._handlers :: { Handler } do
		h.connected = false
	end
	self._handlers = {}
end

return Signal
