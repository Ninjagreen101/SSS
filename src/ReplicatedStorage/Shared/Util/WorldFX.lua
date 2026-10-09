--!strict
-- WorldFX: turns EmitterPresets entries into configured ParticleEmitters and
-- resolves palette colours. Used by the edit-time PlanApplier and by client
-- controllers (rain, ambience) so every world effect shares one definition.

local Shared = script.Parent.Parent
local Config = require(Shared.Config)
local EmitterPresets = require(Shared.Data.EmitterPresets)

local Palette = Config.Palette

local WorldFX = {}

function WorldFX.color(key: string): Color3
	return Palette[key] or Color3.fromRGB(200, 200, 200)
end

local function numberSequence(points: { { number } }): NumberSequence
	local kps = {}
	for _, p in points do
		table.insert(kps, NumberSequenceKeypoint.new(p[1], p[2]))
	end
	if #kps == 1 then
		table.insert(kps, NumberSequenceKeypoint.new(1, points[1][2]))
	end
	return NumberSequence.new(kps)
end

-- Create a ParticleEmitter for `presetName`; `qualityScale` (0..1) scales the rate.
function WorldFX.emitter(presetName: string, qualityScale: number?): ParticleEmitter
	local p = EmitterPresets[presetName]
	assert(p, "unknown emitter preset " .. presetName)
	local e = Instance.new("ParticleEmitter")
	e.Name = presetName
	e.Texture = p.texture
	e.Rate = p.rate * (qualityScale or 1) * p.quality
	e.Lifetime = NumberRange.new(p.lifetime[1], p.lifetime[2])
	e.Speed = NumberRange.new(p.speed[1], p.speed[2])
	e.SpreadAngle = Vector2.new(p.spread[1], p.spread[2])
	e.Size = numberSequence(p.size)
	e.Transparency = numberSequence(p.transparency)
	local c0 = WorldFX.color(p.color)
	local c1 = if p.colorEnd then WorldFX.color(p.colorEnd) else c0
	e.Color = ColorSequence.new(c0, c1)
	e.LightEmission = p.lightEmission
	e.LightInfluence = p.lightInfluence
	e.Acceleration = Vector3.new(p.acceleration[1], p.acceleration[2], p.acceleration[3])
	e.Drag = p.drag
	e.RotSpeed = NumberRange.new(p.rotSpeed[1], p.rotSpeed[2])
	e.Rotation = NumberRange.new(0, 360)
	if p.squash then
		e.Squash = NumberSequence.new(p.squash)
	end
	if p.zOffset then
		e.ZOffset = p.zOffset
	end
	if p.direction then
		e.EmissionDirection = (Enum.NormalId :: any)[p.direction]
	end
	e:SetAttribute("Preset", presetName)
	e:SetAttribute("BaseRate", e.Rate)
	if p.night then
		e:SetAttribute("NightOnly", true)
	end
	return e
end

function WorldFX.isArea(presetName: string): boolean
	local p = EmitterPresets[presetName]
	return p ~= nil and p.area
end

return WorldFX
