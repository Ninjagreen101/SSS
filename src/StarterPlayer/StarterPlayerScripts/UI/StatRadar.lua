--!strict
--[[
	StatRadar
	A seven-point radar of your build: one spoke per stat (Vitality,
	Endurance, Strength, Finesse, Draw, Density, Control), the filled shape
	is your current total in each, and staged (unconfirmed) points show as a
	bright outline beyond it. Rings mark thirds of the scale; the scale is
	the soft cap (40) or your highest stat, whichever is bigger.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Maid = require(Shared.Util.Maid)

local UITheme = require(script.Parent.UITheme)
local Create = require(script.Parent.Create)
local Icons = require(script.Parent.Icons)
local Shapes = require(script.Parent.Shapes)

local C = UITheme.Colors
local LABEL_ROOM = 30 -- px kept outside the outer ring for the stat icons

export type StatRadar = {
	Instance: Frame,
	Set: (self: StatRadar, stats: { string }, totals: { [string]: number }, staged: { [string]: number }) -> (),
	Destroy: (self: StatRadar) -> (),
}

export type StatRadarProps = {
	Size: number, -- diameter in px
	Position: UDim2?,
	AnchorPoint: Vector2?,
	LayoutOrder: number?,
	Parent: Instance?,
}

local StatRadar = {}

function StatRadar.new(props: StatRadarProps): StatRadar
	local maid = Maid.new()
	local size = props.Size
	local frame: Frame = Create.new("Frame", {
		Name = "StatRadar",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(size, size),
		Position = props.Position or UDim2.new(),
		AnchorPoint = props.AnchorPoint or Vector2.zero,
		LayoutOrder = props.LayoutOrder or 0,
	})
	maid:Add(frame)
	local drawing: Frame = Create.new("Frame", { Name = "Drawing", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = frame })
	local centre = Vector2.new(size / 2, size / 2)
	local radius = size / 2 - LABEL_ROOM

	-- Point on spoke `index` (of `count`) at `fraction` of the radius; the
	-- first spoke points straight up.
	local function point(index: number, count: number, fraction: number): Vector2
		local angle = -math.pi / 2 + (index - 1) * (2 * math.pi / count)
		return centre + Vector2.new(math.cos(angle), math.sin(angle)) * radius * fraction
	end

	local self = { Instance = frame }

	function self.Set(_self: StatRadar, stats: { string }, totals: { [string]: number }, staged: { [string]: number })
		drawing:ClearAllChildren()
		local count = #stats
		if count < 3 then
			return
		end
		local highest = 0
		for _, stat in stats do
			highest = math.max(highest, (totals[stat] or 0) + (staged[stat] or 0))
		end
		local softCap = Config.Progression.SoftCaps[1].Threshold
		local scale = math.max(softCap, math.ceil(highest * 1.1 / 10) * 10)

		-- Backing glow and rings.
		Icons.Fx("Glow", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromOffset(centre.X, centre.Y),
			Size = UDim2.fromOffset(radius * 2.4, radius * 2.4),
			Color = C.Aqua,
			Transparency = 0.9,
			Parent = drawing,
		})
		for ring = 1, 3 do
			local fraction = ring / 3
			for index = 1, count do
				Shapes.Line(point(index, count, fraction), point(index % count + 1, count, fraction), 1, {
					Color = C.EdgeBright,
					Transparency = if ring == 3 then 0.35 else 0.7,
					Parent = drawing,
				})
			end
		end
		for index = 1, count do
			Shapes.Line(centre, point(index, count, 1), 1, { Color = C.Edge, Transparency = 0.4, Parent = drawing })
		end

		-- Your build, filled; staged points as an outline beyond it.
		local filled: { Vector2 } = {}
		local preview: { Vector2 } = {}
		local anyStaged = false
		for index, stat in stats do
			local total = totals[stat] or 0
			local extra = staged[stat] or 0
			anyStaged = anyStaged or extra > 0
			filled[index] = point(index, count, math.clamp(total / scale, 0.04, 1))
			preview[index] = point(index, count, math.clamp((total + extra) / scale, 0.04, 1))
		end
		Shapes.Fan(centre, filled, { Color = C.Aqua, Transparency = 0.55, ZIndex = 2, Parent = drawing })
		for index = 1, count do
			Shapes.Line(filled[index], filled[index % count + 1], 2, { Color = C.Aqua, ZIndex = 3, Parent = drawing })
		end
		if anyStaged then
			for index = 1, count do
				Shapes.Line(preview[index], preview[index % count + 1], 2, { Color = C.Foam, Transparency = 0.15, ZIndex = 4, Parent = drawing })
			end
		end
		for index = 1, count do
			local dot: Frame = Create.new("Frame", {
				Name = "Vertex",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromOffset(filled[index].X, filled[index].Y),
				Size = UDim2.fromOffset(6, 6),
				BackgroundColor3 = C.Foam,
				ZIndex = 5,
				Parent = drawing,
			})
			Create.Corner(dot, UITheme.CornerPill)
			-- Stat icon just outside the outer ring.
			local labelPoint = point(index, count, 1 + (LABEL_ROOM * 0.55) / radius)
			Icons.new(Icons.ForStat(stats[index]), {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromOffset(labelPoint.X, labelPoint.Y),
				Size = UDim2.fromOffset(18, 18),
				Color = if (staged[stats[index]] or 0) > 0 then C.Foam else C.Accent,
				ZIndex = 5,
				Parent = drawing,
			})
		end
	end

	function self.Destroy(_self: StatRadar)
		maid:Clean()
	end

	frame.Parent = props.Parent
	return self :: StatRadar
end

return StatRadar
