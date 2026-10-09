--!strict
--[[
	Signal
	Typed in-process event used between systems on the same side
	(e.g. DataService.ProfileLoaded, InputController.ActionBegan).
	Handlers run in their own threads, so one erroring or yielding handler
	never blocks the others or the firing code.
]]

export type Connection = {
	Connected: boolean,
	Disconnect: (self: Connection) -> (),
	Destroy: (self: Connection) -> (),
}

export type Signal<T...> = {
	Connect: (self: Signal<T...>, handler: (T...) -> ()) -> Connection,
	Once: (self: Signal<T...>, handler: (T...) -> ()) -> Connection,
	Wait: (self: Signal<T...>) -> T...,
	Fire: (self: Signal<T...>, T...) -> (),
	DisconnectAll: (self: Signal<T...>) -> (),
	Destroy: (self: Signal<T...>) -> (),
}

type ConnectionImpl = {
	Connected: boolean,
	_handler: (...any) -> (),
	_signal: SignalImpl,
	Disconnect: (self: ConnectionImpl) -> (),
	Destroy: (self: ConnectionImpl) -> (),
}

type SignalImpl = {
	_connections: { ConnectionImpl },
	_destroyed: boolean,
}

local Signal = {}

local function disconnect(self: ConnectionImpl)
	if not self.Connected then
		return
	end
	self.Connected = false
	local list = self._signal._connections
	local index = table.find(list, self)
	if index then
		table.remove(list, index)
	end
end

local function connect(self: SignalImpl, handler: (...any) -> ()): ConnectionImpl
	local connection: ConnectionImpl = {
		Connected = not self._destroyed,
		_handler = handler,
		_signal = self,
		Disconnect = disconnect,
		Destroy = disconnect,
	}
	if not self._destroyed then
		table.insert(self._connections, connection)
	end
	return connection
end

local function fire(self: SignalImpl, ...: any)
	-- Snapshot so handlers that disconnect during firing don't skip others.
	local snapshot = table.clone(self._connections)
	for _, connection in snapshot do
		if connection.Connected then
			task.spawn(connection._handler, ...)
		end
	end
end

local function once(self: SignalImpl, handler: (...any) -> ()): ConnectionImpl
	local connection: ConnectionImpl
	connection = connect(self, function(...: any)
		connection:Disconnect()
		handler(...)
	end)
	return connection
end

local function wait(self: SignalImpl): ...any
	local thread = coroutine.running()
	once(self, function(...: any)
		task.spawn(thread, ...)
	end)
	return coroutine.yield()
end

local function disconnectAll(self: SignalImpl)
	for _, connection in self._connections do
		connection.Connected = false
	end
	table.clear(self._connections)
end

local function destroy(self: SignalImpl)
	disconnectAll(self)
	self._destroyed = true
end

function Signal.new<T...>(): Signal<T...>
	local self = {
		_connections = {},
		_destroyed = false,
		Connect = connect,
		Once = once,
		Wait = wait,
		Fire = fire,
		DisconnectAll = disconnectAll,
		Destroy = destroy,
	}
	return (self :: any) :: Signal<T...>
end

return Signal
