--!strict
--[[
	Fog (MapService)
	The fog-of-war bitset saved in Data.Map.Explored[floor] (Types.PlayerData.Map), with no Roblox
	services so the Lune simulation can check it.

	The map square (Config.World.Maps[floor]: Center, Size) is split into Cells x Cells cells
	(Config.Quests.Map.Cells). Cell i = row * Cells + col (row 0 = the square's min-Z edge, col 0 =
	its min-X edge) is bit 2^(i % 4) of hex digit floor(i / 4) + 1. "" = nothing explored; a short
	or malformed string reads as unexplored past what it covers.
]]

local Fog = {}

-- One hex digit (0..15) per four cells.
export type Grid = { number }

function Fog.Digits(cells: number): number
	return math.ceil(cells * cells / 4)
end

function Fog.Decode(hex: string, cells: number): Grid
	local count = Fog.Digits(cells)
	local grid: Grid = table.create(count, 0)
	for index = 1, math.min(#hex, count) do
		local value = tonumber(string.sub(hex, index, index), 16)
		grid[index] = if value then value else 0
	end
	return grid
end

function Fog.Encode(grid: Grid): string
	local digits: { string } = table.create(#grid)
	local any = false
	for index, value in grid do
		digits[index] = string.format("%x", value)
		if value ~= 0 then
			any = true
		end
	end
	return if any then table.concat(digits) else ""
end

function Fog.IsSet(grid: Grid, cells: number, row: number, col: number): boolean
	local cell = row * cells + col
	local digit = grid[math.floor(cell / 4) + 1]
	return digit ~= nil and bit32.band(digit, bit32.lshift(1, cell % 4)) ~= 0
end

-- Sets one cell; true if it was new.
function Fog.Set(grid: Grid, cells: number, row: number, col: number): boolean
	if row < 0 or col < 0 or row >= cells or col >= cells then
		return false
	end
	local cell = row * cells + col
	local index = math.floor(cell / 4) + 1
	local bit = bit32.lshift(1, cell % 4)
	local digit = grid[index] or 0
	if bit32.band(digit, bit) ~= 0 then
		return false
	end
	grid[index] = bit32.bor(digit, bit)
	return true
end

-- The cell under world (x, z) on a map square centred on (centerX, centerZ), or nil outside it.
function Fog.Cell(x: number, z: number, centerX: number, centerZ: number, size: number, cells: number): (number?, number?)
	local col = math.floor((x - (centerX - size / 2)) / size * cells)
	local row = math.floor((z - (centerZ - size / 2)) / size * cells)
	if col < 0 or row < 0 or col >= cells or row >= cells then
		return nil, nil
	end
	return row, col
end

-- Reveals the (2 * radius + 1)^2 block around (row, col). True if any cell was new.
function Fog.Reveal(grid: Grid, cells: number, row: number, col: number, radius: number): boolean
	local changed = false
	for r = row - radius, row + radius do
		for c = col - radius, col + radius do
			if Fog.Set(grid, cells, r, c) then
				changed = true
			end
		end
	end
	return changed
end

return Fog
