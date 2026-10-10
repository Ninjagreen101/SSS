--!strict
--[[
	Extra
	Live markers other controllers put on the Map and the minimap (party members, pings), set
	through MapController.SetExtraMarkers(key, provider). Providers are called every map update
	(up to 30 times a second), so they must be cheap and return current world positions.
]]

export type Marker = {
	World: Vector3,
	Color: Color3,
	Size: number?, -- px on the minimap (the big map draws it 1.5x)
	Rim: boolean?, -- stick to the minimap's rim when outside it
}

export type Provider = () -> { Marker }

local Extra = {}

local providers: { [string]: Provider } = {}

function Extra.Set(key: string, provider: Provider?)
	if provider then
		providers[key] = provider
	else
		providers[key] = nil
	end
end

function Extra.Collect(): { Marker }
	local out: { Marker } = {}
	for _, provider in providers do
		for _, marker in provider() do
			table.insert(out, marker)
		end
	end
	return out
end

return Extra
