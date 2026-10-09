--!strict
--[[
	Shapes
	Lines and filled triangles for UI drawings (the stat radar, skill tree
	streams). Roblox UI has no polygon primitive, so a triangle is drawn as
	two right triangles, each an ImageLabel showing the water-effects
	sheet's right-triangle texture, rotated into place.

	The texture's right angle is its bottom-left corner: one leg runs up the
	left edge, the other along the bottom edge. For a right triangle with
	its right angle at D and legs a (D -> P) and b (D -> Q):
	  - the image is |a| wide and |b| tall,
	  - rotated so its bottom edge runs along a,
	  - centred on D + (a + b) / 2.
	The image's "up" leg must turn the same way from a as b does; if b is
	on the other side, a and b swap roles.
]]

local Create = require(script.Parent.Create)
local Icons = require(script.Parent.Icons)

local Shapes = {}

export type ShapeProps = {
	Color: Color3,
	Transparency: number?,
	ZIndex: number?,
	Name: string?,
	Parent: Instance,
}

-- A straight line from `a` to `b` (offsets from the parent's top-left).
function Shapes.Line(a: Vector2, b: Vector2, thickness: number, props: ShapeProps): Frame
	local delta = b - a
	local middle = (a + b) / 2
	return Create.new("Frame", {
		Name = props.Name or "Line",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(middle.X, middle.Y),
		Size = UDim2.fromOffset(delta.Magnitude + 1, thickness),
		Rotation = math.deg(math.atan2(delta.Y, delta.X)),
		BackgroundColor3 = props.Color,
		BackgroundTransparency = props.Transparency or 0,
		BorderSizePixel = 0,
		ZIndex = props.ZIndex or 1,
		Parent = props.Parent,
	})
end

local function rightTriangle(d: Vector2, a: Vector2, b: Vector2, props: ShapeProps): ImageLabel?
	local width, height = a.Magnitude, b.Magnitude
	if width < 0.5 or height < 0.5 then
		return nil
	end
	-- Screen y points down: the texture's "up" leg is the clockwise-negative
	-- side of its bottom leg, i.e. cross(bottom, up) < 0.
	if a.X * b.Y - a.Y * b.X > 0 then
		a, b = b, a
		width, height = height, width
	end
	local centre = d + (a + b) / 2
	local image = Icons.Fx("Triangle", {
		Name = props.Name or "Triangle",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(centre.X, centre.Y),
		Size = UDim2.fromOffset(width, height),
		Rotation = math.deg(math.atan2(a.Y, a.X)),
		Color = props.Color,
		Transparency = props.Transparency,
		ZIndex = props.ZIndex,
		Parent = props.Parent,
	})
	return image
end

-- A filled triangle (two right-triangle images). Returns the images.
function Shapes.Triangle(p1: Vector2, p2: Vector2, p3: Vector2, props: ShapeProps): { ImageLabel }
	-- Split along the perpendicular from the vertex opposite the longest edge.
	local points = { p1, p2, p3 }
	local longest, best = 1, -1
	for index = 1, 3 do
		local length = (points[index % 3 + 1] - points[index]).Magnitude
		if length > best then
			longest, best = index, length
		end
	end
	local a = points[longest]
	local b = points[longest % 3 + 1]
	local c = points[(longest + 1) % 3 + 1]
	local edge = b - a
	local edgeLength = edge.Magnitude
	if edgeLength < 0.5 then
		return {}
	end
	local direction = edge / edgeLength
	local foot = a + direction * (c - a):Dot(direction)
	local made: { ImageLabel } = {}
	local first = rightTriangle(foot, a - foot, c - foot, props)
	if first then
		table.insert(made, first)
	end
	local second = rightTriangle(foot, b - foot, c - foot, props)
	if second then
		table.insert(made, second)
	end
	return made
end

-- A filled convex polygon around `centre` (fan of triangles).
function Shapes.Fan(centre: Vector2, points: { Vector2 }, props: ShapeProps): { ImageLabel }
	local made: { ImageLabel } = {}
	for index = 1, #points do
		local nextPoint = points[index % #points + 1]
		for _, image in Shapes.Triangle(centre, points[index], nextPoint, props) do
			table.insert(made, image)
		end
	end
	return made
end

return table.freeze(Shapes)
