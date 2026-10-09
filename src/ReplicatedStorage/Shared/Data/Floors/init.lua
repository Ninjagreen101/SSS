--!strict
-- Registry of floor definitions, keyed by floor id and by index.

local Types = require(script.Parent.Parent.Types)

local Lowharbor = require(script.Lowharbor)

local Floors = {
	ById = {
		Lowharbor = Lowharbor,
	} :: { [string]: Types.FloorDef },
	ByIndex = {
		[1] = Lowharbor,
	} :: { [number]: Types.FloorDef },
}

return Floors
