--!strict
--[[
	Surface
	The drawn floor map, shared by the Map (M) and the minimap. A surface is a square Frame whose
	children are placed by Scale (0..1 across the floor's map square), so the owner zooms and pans
	by resizing and moving the surface alone.

	Layers, bottom to top:
	- Base: the uploaded top-down render (Config.World.Maps[floor].Image) or, with no image, the
	  region grid (ReplicatedStorage.FloorData.Regions, current floor only) drawn as merged colour
	  rectangles (runs along each row, stacked with identical runs on the rows below).
	- Labels (optional): region names at each region's centre, shown once that spot is explored.
	- Fog: unexplored cells of the profile's Map.Explored[floor] bitset (Config.Quests.Map.Cells
	  per side), merged the same way into a pooled set of frames.

	Map square: Center/Size from Config.World.Maps; image x = world X, image y = world Z (north =
	-Z at the top). Fog cell i = row * Cells + col (row 0 at min Z, col 0 at min X) is bit
	2^(i % 4) of hex digit floor(i / 4) + 1.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Strings = require(Shared.Strings)

local UI = script.Parent.Parent.Parent.UI
local UITheme = require(UI.UITheme)
local Create = require(UI.Create)

local DataController = require(script.Parent.Parent.DataController)

local M = UITheme.Map
local CELLS = Config.Quests.Map.Cells

export type MapInfo = { Image: string, Center: Vector2, Size: number }

type Rect = { I0: number, I1: number, K0: number, K1: number, Key: string }

type Grid = {
	Data: string,
	Cell: number,
	Origin: Vector2,
	Columns: number,
	Legend: { [string]: string },
}

type RegionLabel = { Label: TextLabel, Unit: Vector2 }

export type Surface = {
	Root: Frame,
	Floor: string?,
	HasMap: boolean,
	SetFloor: (self: Surface, floor: string) -> (),
	RefreshFog: (self: Surface, force: boolean?) -> (),
	Destroy: (self: Surface) -> (),
}

type FloorBase = {
	Frame: Frame,
	Labels: { RegionLabel },
	Drawn: boolean,
}

type SurfaceImpl = Surface & {
	Labels: boolean,
	Base: Frame,
	LabelLayer: Frame?,
	FogLayer: Frame,
	FogPool: { Frame },
	FogKey: string,
	BaseCache: { [string]: FloorBase },
	RegionLabels: { RegionLabel },
}

local Surface = {}
Surface.__index = Surface

-- MAP SQUARE ---------------------------------------------------------------------------------

function Surface.Info(floor: string): MapInfo?
	local maps = Config.World.Maps :: { [string]: MapInfo }
	return maps[floor]
end

-- The floor this server runs (each server is one floor).
function Surface.CurrentFloor(): string
	local value = Workspace:GetAttribute("FloorId")
	if type(value) == "string" and value ~= "" then
		return value
	end
	local saved = DataController.Get({ "Floors", "Current" })
	return if type(saved) == "string" and saved ~= "" then saved else "1"
end

-- World (x, z) -> unit map coordinates (0..1 inside the square; may fall outside).
function Surface.ToUnit(info: MapInfo, x: number, z: number): Vector2
	local half = info.Size / 2
	return Vector2.new((x - (info.Center.X - half)) / info.Size, (z - (info.Center.Y - half)) / info.Size)
end

function Surface.ToWorld(info: MapInfo, unit: Vector2): (number, number)
	local half = info.Size / 2
	return info.Center.X - half + unit.X * info.Size, info.Center.Y - half + unit.Y * info.Size
end

-- EXPLORATION --------------------------------------------------------------------------------

local function exploredHex(floor: string): string
	local value = DataController.Get({ "Map", "Explored", floor })
	return if type(value) == "string" then value else ""
end

local function decode(hex: string): { boolean }
	local cells: { boolean } = table.create(CELLS * CELLS, false)
	for digitIndex = 1, #hex do
		local digit = tonumber(string.sub(hex, digitIndex, digitIndex), 16) or 0
		if digit ~= 0 then
			local base = (digitIndex - 1) * 4
			for bit = 0, 3 do
				if bit32.btest(digit, bit32.lshift(1, bit)) then
					local index = base + bit + 1
					if index <= CELLS * CELLS then
						cells[index] = true
					end
				end
			end
		end
	end
	return cells
end

-- Is the cell under unit coordinate `unit` explored?
function Surface.IsExplored(floor: string, unit: Vector2): boolean
	local col = math.floor(unit.X * CELLS)
	local row = math.floor(unit.Y * CELLS)
	if col < 0 or row < 0 or col >= CELLS or row >= CELLS then
		return false
	end
	local index = row * CELLS + col
	local digitIndex = index // 4 + 1
	local digit = tonumber(string.sub(exploredHex(floor), digitIndex, digitIndex), 16) or 0
	return bit32.btest(digit, bit32.lshift(1, index % 4))
end

-- Merges a grid into rectangles: runs of equal keys along each row, extended down while the row
-- below has the identical run. `keyAt(col, row)` returns nil for "nothing here".
local function mergeRects(columns: number, rows: number, keyAt: (number, number) -> string?): { Rect }
	local done: { Rect } = {}
	local open: { [string]: Rect } = {}
	for row = 0, rows - 1 do
		local nextOpen: { [string]: Rect } = {}
		local col = 0
		while col < columns do
			local key = keyAt(col, row)
			if not key then
				col += 1
				continue
			end
			local start = col
			while col + 1 < columns and keyAt(col + 1, row) == key do
				col += 1
			end
			local runKey = `{start}:{col}:{key}`
			local rect = open[runKey]
			if rect then
				rect.K1 = row
				open[runKey] = nil
			else
				rect = { I0 = start, I1 = col, K0 = row, K1 = row, Key = key }
			end
			nextOpen[runKey] = rect
			col += 1
		end
		for _, rect in open do
			table.insert(done, rect)
		end
		open = nextOpen
	end
	for _, rect in open do
		table.insert(done, rect)
	end
	return done
end

-- REGION GRID --------------------------------------------------------------------------------

local function loadGrid(): Grid?
	local folder = ReplicatedStorage:FindFirstChild("FloorData")
	local value = folder and folder:FindFirstChild("Regions")
	if not (value and value:IsA("StringValue")) or value.Value == "" then
		return nil
	end
	local legend: { [string]: string } = {}
	local raw = value:GetAttribute("Legend")
	if type(raw) == "string" then
		for _, pair in string.split(raw, ",") do
			local parts = string.split(pair, "=")
			if #parts == 2 then
				legend[parts[1]] = parts[2]
			end
		end
	end
	local origin = value:GetAttribute("Origin")
	local cell = value:GetAttribute("Cell")
	local columns = value:GetAttribute("Columns")
	return {
		Data = value.Value,
		Cell = if type(cell) == "number" then cell else Config.Environment.RegionCell,
		Origin = if typeof(origin) == "Vector2" then origin else Vector2.new(-1500, -1500),
		Columns = if type(columns) == "number" then columns else 60,
		Legend = legend,
	}
end

local function letterAt(grid: Grid, col: number, row: number): string?
	local index = row * grid.Columns + col + 1
	local letter = string.sub(grid.Data, index, index)
	return if letter ~= "" then letter else nil
end

local function gridRows(grid: Grid): number
	return math.floor(#grid.Data / grid.Columns)
end

-- The region grid as merged colour rectangles.
local function buildRegionRects(parent: Frame, info: MapInfo, grid: Grid)
	local seam = 0.6 / info.Size -- a hair of overlap so rectangles never show hairline gaps
	local rects = mergeRects(grid.Columns, gridRows(grid), function(col: number, row: number): string?
		return letterAt(grid, col, row)
	end)
	for _, rect in rects do
		local region = grid.Legend[rect.Key] or ""
		local x0 = grid.Origin.X + rect.I0 * grid.Cell
		local z0 = grid.Origin.Y + rect.K0 * grid.Cell
		local x1 = grid.Origin.X + (rect.I1 + 1) * grid.Cell
		local z1 = grid.Origin.Y + (rect.K1 + 1) * grid.Cell
		local a = Surface.ToUnit(info, x0, z0)
		local b = Surface.ToUnit(info, x1, z1)
		Create.new("Frame", {
			Name = region,
			BorderSizePixel = 0,
			BackgroundColor3 = M.Regions[region] or M.Background,
			Position = UDim2.fromScale(a.X, a.Y),
			Size = UDim2.fromScale(b.X - a.X + seam, b.Y - a.Y + seam),
			Parent = parent,
		})
	end
end

-- Region names at the mean of each region's cells.
local function buildRegionLabels(parent: Frame, info: MapInfo, grid: Grid): { RegionLabel }
	local sums: { [string]: Vector3 } = {}
	for row = 0, gridRows(grid) - 1 do
		for col = 0, grid.Columns - 1 do
			local letter = letterAt(grid, col, row)
			local region = letter and grid.Legend[letter]
			if region then
				local sum = sums[region] or Vector3.zero
				sums[region] = sum + Vector3.new(col + 0.5, row + 0.5, 1)
			end
		end
	end
	local labels: { RegionLabel } = {}
	for region, sum in sums do
		local name = Strings.Regions[region]
		if name and sum.Z > 0 then
			local x = grid.Origin.X + sum.X / sum.Z * grid.Cell
			local z = grid.Origin.Y + sum.Y / sum.Z * grid.Cell
			local unit = Surface.ToUnit(info, x, z)
			local label = Create.Label({
				Name = region,
				Text = string.upper(name),
				Font = UITheme.Fonts.Display,
				TextSize = 15,
				Color = UITheme.Colors.Foam,
				XAlignment = Enum.TextXAlignment.Center,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(unit.X, unit.Y),
				Size = UDim2.fromOffset(220, 20),
				Parent = parent,
			})
			label.TextStrokeTransparency = 0.35
			label.TextTransparency = 0.15
			table.insert(labels, { Label = label, Unit = unit })
		end
	end
	return labels
end

-- SURFACE ------------------------------------------------------------------------------------

-- `labels`: draw region names (the full map; the minimap is too small for them).
function Surface.new(parent: Instance, labels: boolean): Surface
	local root: Frame = Create.new("Frame", {
		Name = "MapSurface",
		BackgroundColor3 = M.Background,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Parent = parent,
	})
	local base: Frame = Create.new("Frame", { Name = "Base", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 1, Parent = root })
	-- A soft vignette over the base so the edges of the floor fall away into the sea.
	local shade: Frame = Create.new("Frame", {
		Name = "Shade",
		BackgroundColor3 = M.Background,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 2,
		Parent = root,
	})
	Create.new("UIGradient", {
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.4),
			NumberSequenceKeypoint.new(0.12, 1),
			NumberSequenceKeypoint.new(0.88, 1),
			NumberSequenceKeypoint.new(1, 0.4),
		}),
		Parent = shade,
	})
	local labelLayer: Frame? = nil
	if labels then
		labelLayer = Create.new("Frame", { Name = "Labels", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 4, Parent = root })
	end
	local fog: Frame = Create.new("Frame", { Name = "Fog", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 3, Parent = root })
	local self: SurfaceImpl = setmetatable({
		Root = root,
		Floor = nil,
		HasMap = false,
		Labels = labels,
		Base = base,
		LabelLayer = labelLayer,
		FogLayer = fog,
		FogPool = {},
		FogKey = "",
		BaseCache = {},
		RegionLabels = {},
	}, Surface) :: any
	return self
end

function Surface.SetFloor(self: SurfaceImpl, floor: string)
	if self.Floor == floor then
		return
	end
	self.Floor = floor
	for key, entry in self.BaseCache do
		entry.Frame.Visible = key == floor
		for _, label in entry.Labels do
			label.Label.Visible = false
		end
	end
	local info = Surface.Info(floor)
	if not info then
		self.HasMap = false
		self.RegionLabels = {}
		self:RefreshFog(true)
		return
	end
	local entry = self.BaseCache[floor]
	if not entry then
		local frame: Frame = Create.new("Frame", { Name = `Floor{floor}`, BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = self.Base })
		local drawn = false
		if info.Image ~= "" then
			Create.new("ImageLabel", {
				Name = "Render",
				BackgroundTransparency = 1,
				Image = info.Image,
				ScaleType = Enum.ScaleType.Stretch,
				Size = UDim2.fromScale(1, 1),
				Parent = frame,
			})
			drawn = true
		end
		-- The region grid only describes the floor this server runs.
		local grid = if floor == Surface.CurrentFloor() then loadGrid() else nil
		local labels: { RegionLabel } = {}
		if grid then
			if not drawn then
				buildRegionRects(frame, info, grid)
				drawn = true
			end
			local labelLayer = self.LabelLayer
			if labelLayer then
				labels = buildRegionLabels(labelLayer, info, grid)
			end
		end
		entry = { Frame = frame, Labels = labels, Drawn = drawn }
		self.BaseCache[floor] = entry
	end
	assert(entry, "floor base")
	self.RegionLabels = entry.Labels
	self.HasMap = entry.Drawn
	self:RefreshFog(true)
end

-- Re-reads Map.Explored for the shown floor (cheap when nothing changed).
function Surface.RefreshFog(self: SurfaceImpl, force: boolean?)
	local floor = self.Floor
	if not floor then
		return
	end
	local hex = exploredHex(floor)
	local key = `{floor}|{hex}`
	if key == self.FogKey and not force then
		return
	end
	self.FogKey = key
	local used = 0
	if self.HasMap then
		local cells = decode(hex)
		local rects = mergeRects(CELLS, CELLS, function(col: number, row: number): string?
			return if cells[row * CELLS + col + 1] then nil else "F"
		end)
		local step = 1 / CELLS
		local seam = 0.0008
		for _, rect in rects do
			used += 1
			local frame = self.FogPool[used]
			if not frame then
				frame = Create.new("Frame", {
					Name = "Fog",
					BorderSizePixel = 0,
					BackgroundColor3 = M.Fog,
					BackgroundTransparency = M.FogTransparency,
					Parent = self.FogLayer,
				})
				self.FogPool[used] = frame
			end
			frame.Visible = true
			frame.Position = UDim2.fromScale(rect.I0 * step, rect.K0 * step)
			frame.Size = UDim2.fromScale((rect.I1 - rect.I0 + 1) * step + seam, (rect.K1 - rect.K0 + 1) * step + seam)
		end
	end
	for index = used + 1, #self.FogPool do
		self.FogPool[index].Visible = false
	end
	-- Region names appear once their centre is explored.
	for _, entry in self.RegionLabels do
		entry.Label.Visible = Surface.IsExplored(floor, entry.Unit)
	end
end

function Surface.Destroy(self: SurfaceImpl)
	self.Root:Destroy()
end

return Surface
