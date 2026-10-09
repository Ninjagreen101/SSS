--!strict
-- Strings: every player-facing string, keyed for future localisation.
-- Strings.get("Waystone.Attuned", name) formats with string.format when
-- arguments are given; unknown keys return the key itself so gaps are visible.

local World = require(script.World)

local Strings = {}

local tables: { { [string]: string } } = { World.Text }

function Strings.get(key: string, ...: any): string
	for _, t in tables do
		local s = t[key]
		if s then
			if select("#", ...) > 0 then
				return string.format(s, ...)
			end
			return s
		end
	end
	return key
end

function Strings.has(key: string): boolean
	for _, t in tables do
		if t[key] then
			return true
		end
	end
	return false
end

Strings.MerchantLines = World.MerchantLines

return Strings
