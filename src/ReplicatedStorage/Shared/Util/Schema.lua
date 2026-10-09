--!strict
--[[
	Schema
	Composable runtime validators for anything that crosses the network or is
	loaded from storage. A validator returns (true) or (false, reason).
	Every number check rejects NaN and +/- infinity; every string and
	collection has a hard size cap so exploiters can't send huge payloads.
]]

local MathUtil = require(script.Parent.MathUtil)

export type Validator = (value: any) -> (boolean, string?)

local Schema = {}

function Schema.Any(): Validator
	return function(_value: any)
		return true
	end
end

function Schema.Nil(): Validator
	return function(value: any)
		if value == nil then
			return true
		end
		return false, "expected nil"
	end
end

function Schema.Boolean(): Validator
	return function(value: any)
		if type(value) == "boolean" then
			return true
		end
		return false, "expected boolean"
	end
end

function Schema.Number(min: number?, max: number?): Validator
	local lo = min or -math.huge
	local hi = max or math.huge
	return function(value: any)
		if type(value) ~= "number" then
			return false, "expected number"
		end
		if not MathUtil.IsFinite(value) then
			return false, "number not finite"
		end
		if value < lo or value > hi then
			return false, `number out of range [{lo}, {hi}]`
		end
		return true
	end
end

function Schema.Integer(min: number?, max: number?): Validator
	local base = Schema.Number(min, max)
	return function(value: any)
		local ok, reason = base(value)
		if not ok then
			return false, reason
		end
		if value % 1 ~= 0 then
			return false, "expected integer"
		end
		return true
	end
end

function Schema.String(minLength: number?, maxLength: number?): Validator
	local lo = minLength or 0
	local hi = maxLength or 200
	return function(value: any)
		if type(value) ~= "string" then
			return false, "expected string"
		end
		local length = #value
		if length < lo or length > hi then
			return false, `string length out of range [{lo}, {hi}]`
		end
		if not utf8.len(value) then
			return false, "invalid utf8"
		end
		return true
	end
end

-- Identifier strings (ids, enum names): letters, digits, underscore, dash.
function Schema.Id(maxLength: number?): Validator
	local hi = maxLength or 64
	return function(value: any)
		if type(value) ~= "string" then
			return false, "expected id string"
		end
		if #value == 0 or #value > hi then
			return false, "id length out of range"
		end
		if not string.match(value, "^[%w_%-]+$") then
			return false, "id has invalid characters"
		end
		return true
	end
end

-- One of a fixed set of strings.
function Schema.OneOf(options: { any }): Validator
	local set: { [string]: boolean } = {}
	for _, option in options do
		set[option] = true
	end
	return function(value: any)
		if type(value) == "string" and set[value] then
			return true
		end
		return false, "value not in allowed set"
	end
end

-- Any finite Vector3 whose magnitude is at most `maxMagnitude`.
function Schema.Vector3(maxMagnitude: number?): Validator
	local cap = maxMagnitude or 1e5
	return function(value: any)
		if typeof(value) ~= "Vector3" then
			return false, "expected Vector3"
		end
		if not MathUtil.IsFiniteVector3(value) then
			return false, "Vector3 not finite"
		end
		if value.Magnitude > cap then
			return false, "Vector3 too large"
		end
		return true
	end
end

-- A direction: finite, roughly unit length (small tolerance for float error).
function Schema.UnitVector3(): Validator
	return function(value: any)
		if typeof(value) ~= "Vector3" then
			return false, "expected Vector3"
		end
		if not MathUtil.IsFiniteVector3(value) then
			return false, "Vector3 not finite"
		end
		local magnitude = value.Magnitude
		if magnitude < 0.98 or magnitude > 1.02 then
			return false, "expected unit vector"
		end
		return true
	end
end

function Schema.Optional(inner: Validator): Validator
	return function(value: any)
		if value == nil then
			return true
		end
		return inner(value)
	end
end

-- An array (dense, 1..n) of items, with a maximum length.
function Schema.ArrayOf(item: Validator, maxLength: number): Validator
	return function(value: any)
		if type(value) ~= "table" then
			return false, "expected array"
		end
		local count = 0
		for key in value do
			count += 1
			if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
				return false, "array has non-index key"
			end
			if count > maxLength then
				return false, "array too long"
			end
		end
		if count ~= #value then
			return false, "array has holes"
		end
		for index, element in value do
			local ok, reason = item(element)
			if not ok then
				return false, `[{index}] {reason or "invalid"}`
			end
		end
		return true
	end
end

-- A dictionary with validated keys and values, and a maximum entry count.
function Schema.MapOf(key: Validator, item: Validator, maxEntries: number): Validator
	return function(value: any)
		if type(value) ~= "table" then
			return false, "expected map"
		end
		local count = 0
		for k, v in value do
			count += 1
			if count > maxEntries then
				return false, "map has too many entries"
			end
			local okKey, keyReason = key(k)
			if not okKey then
				return false, `key: {keyReason or "invalid"}`
			end
			local okValue, valueReason = item(v)
			if not okValue then
				return false, `{tostring(k)}: {valueReason or "invalid"}`
			end
		end
		return true
	end
end

-- A table with exactly these fields (unknown fields are rejected).
function Schema.Shape(fields: { [string]: Validator }): Validator
	return function(value: any)
		if type(value) ~= "table" then
			return false, "expected table"
		end
		for k in value do
			if type(k) ~= "string" or fields[k] == nil then
				return false, `unexpected field {tostring(k)}`
			end
		end
		for name, validator in fields do
			local ok, reason = validator(value[name])
			if not ok then
				return false, `{name}: {reason or "invalid"}`
			end
		end
		return true
	end
end

-- Validates a full argument list against an ordered list of validators.
-- Extra arguments are rejected so remotes can't be padded with junk.
function Schema.Args(validators: { Validator }, ...: any): (boolean, string?)
	local count = select("#", ...)
	if count > #validators then
		return false, `too many arguments ({count} > {#validators})`
	end
	for index, validator in validators do
		local ok, reason = validator((select(index, ...)))
		if not ok then
			return false, `arg {index}: {reason or "invalid"}`
		end
	end
	return true
end

return Schema
