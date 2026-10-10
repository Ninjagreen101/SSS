--!strict
--[[
	CompanyService.Store
	Every Company DataStore call goes through here.

	- Update(key, mutate): one UpdateAsync. `mutate(old)` returns the new value, or nil and a
	  reason to cancel (nothing is written). UpdateAsync may call it several times when another
	  server wrote the key first; only the last call counts, so mutate must derive everything from
	  `old` (and reset anything it records outside on every call). A mutate that errors cancels
	  with "Invalid" instead of retrying.
	- Read(key): an uncached read (another server may have just written).
	- Both are pcall-guarded, wait (a bounded time) for request budget before each call, and retry
	  failed calls with doubling backoff. Out of budget or out of attempts = "Busy" / "Failed".

	The backend is the real DataStore in a published game, or Store.Memory(): an in-memory
	DataStore used in Studio without API access and by tools/place/test_company.luau, with hooks
	to simulate another server's write landing mid-update and failing calls.
]]

export type Backend = {
	-- Runs `transform` the way DataStore:UpdateAsync does and returns the committed value (nil if
	-- cancelled). Errors on a failed request.
	Update: (key: string, transform: (any) -> any) -> any,
	Read: (key: string) -> any,
	-- Requests left right now for "Update" / "Read" (math.huge when unmetered).
	Budget: (kind: string) -> number,
}

export type Options = {
	Attempts: number,
	Backoff: number, -- seconds before the second attempt; doubles after each failure
	BudgetWait: number, -- longest wait for request budget before giving up with "Busy"
	Wait: (seconds: number) -> (),
	OnError: ((key: string, attempt: number, message: string) -> ())?,
}

export type Store = {
	Update: (key: string, mutate: (old: any) -> (any, string?)) -> (boolean, any, string?),
	Read: (key: string) -> (boolean, any, string?),
}

export type Memory = {
	Backend: Backend,
	Data: { [string]: any },
	Conflicts: { [string]: (any) -> any }, -- runs once mid-update, as another server's write
	Failures: { [string]: number }, -- the next N requests on this key error
	Calls: { [string]: number }, -- transform runs per key
}

local BUDGET_POLL = 0.5

local Store = {}

function Store.new(backend: Backend, options: Options): Store
	local function waitForBudget(kind: string): boolean
		local waited = 0
		while backend.Budget(kind) < 1 do
			if waited >= options.BudgetWait then
				return false
			end
			options.Wait(BUDGET_POLL)
			waited += BUDGET_POLL
		end
		return true
	end

	local function report(key: string, attempt: number, message: string)
		if options.OnError then
			options.OnError(key, attempt, message)
		end
	end

	local function update(key: string, mutate: (old: any) -> (any, string?)): (boolean, any, string?)
		for attempt = 1, options.Attempts do
			if not waitForBudget("Update") then
				return false, nil, "Busy"
			end
			local refused: string? = nil
			local ok, result = pcall(backend.Update, key, function(old: any): any
				refused = nil
				local ran, new, reason = pcall(mutate, old)
				if not ran then
					report(key, attempt, `mutate errored: {tostring(new)}`)
					refused = "Invalid"
					return nil
				end
				if new == nil then
					refused = reason or "Refused"
				end
				return new
			end)
			if ok then
				if refused then
					return false, nil, refused
				end
				if result == nil then
					return false, nil, "Failed"
				end
				return true, result, nil
			end
			report(key, attempt, tostring(result))
			if attempt < options.Attempts then
				options.Wait(options.Backoff * 2 ^ (attempt - 1))
			end
		end
		return false, nil, "Failed"
	end

	local function read(key: string): (boolean, any, string?)
		for attempt = 1, options.Attempts do
			if not waitForBudget("Read") then
				return false, nil, "Busy"
			end
			local ok, result = pcall(backend.Read, key)
			if ok then
				return true, result, nil
			end
			report(key, attempt, tostring(result))
			if attempt < options.Attempts then
				options.Wait(options.Backoff * 2 ^ (attempt - 1))
			end
		end
		return false, nil, "Failed"
	end

	return {
		Update = update,
		Read = read,
	}
end

local function deepCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for key, inner in value do
		out[key] = deepCopy(inner)
	end
	return out
end

-- An in-memory DataStore with UpdateAsync semantics: the transform sees a private copy; if another
-- write lands before the commit (Conflicts hook), the write is rejected and the transform runs again
-- on the newer value.
function Store.Memory(): Memory
	local memory: Memory = {
		Backend = nil :: any,
		Data = {},
		Conflicts = {},
		Failures = {},
		Calls = {},
	}
	local function failIfScheduled(key: string)
		local failures = memory.Failures[key]
		if failures and failures > 0 then
			memory.Failures[key] = failures - 1
			error(`simulated DataStore failure on {key}`)
		end
	end
	memory.Backend = {
		Update = function(key: string, transform: (any) -> any): any
			failIfScheduled(key)
			while true do
				memory.Calls[key] = (memory.Calls[key] or 0) + 1
				local result = transform(deepCopy(memory.Data[key]))
				local conflict = memory.Conflicts[key]
				if conflict then
					memory.Conflicts[key] = nil
					memory.Data[key] = deepCopy(conflict(deepCopy(memory.Data[key])))
					continue
				end
				if result == nil then
					return nil
				end
				memory.Data[key] = deepCopy(result)
				return deepCopy(result)
			end
		end,
		Read = function(key: string): any
			failIfScheduled(key)
			return deepCopy(memory.Data[key])
		end,
		Budget = function(_kind: string): number
			return math.huge
		end,
	}
	return memory
end

return table.freeze(Store)
