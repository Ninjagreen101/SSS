--!strict
--[[
	Tooltip
	One shared tooltip panel on the Tooltip layer. Attach(target, provider)
	shows it on mouse hover (following the cursor), on gamepad selection
	(beside the target) and on touch long-press (0.35 s).

	Two details worth knowing:
	  - Roblox doesn't fire MouseLeave when the hovered button disappears
	    (its menu closes, its list rebuilds), so while a tooltip is up its
	    owner is checked every frame and the tooltip hides with it.
	  - A wrapped TextLabel inside an auto-sizing frame collapses to one
	    letter per line (or, given a fixed width, stays one line tall), so
	    each line is measured first (TextService) and given a fixed size:
	    its natural width, or the panel's maximum width with wrapping and
	    the measured wrapped height when it's longer.
]]

local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextService = game:GetService("TextService")
local UserInputService = game:GetService("UserInputService")

local UI = script.Parent.Parent
local UITheme = require(UI.UITheme)
local Create = require(UI.Create)
local Layers = require(UI.Layers)
local Icons = require(UI.Icons)
local Maid = require(ReplicatedStorage:WaitForChild("Shared").Util.Maid)

export type TooltipLine = {
	Text: string,
	Color: Color3?,
	Bold: boolean?,
}

export type TooltipContent = {
	Title: string,
	TitleColor: Color3?,
	Icon: string?, -- icon name shown left of the title (UI/Icons)
	Subtitle: string?,
	Lines: { TooltipLine }?,
	Footer: string?,
}

local LONG_PRESS = 0.35
local CURSOR_OFFSET = Vector2.new(18, 18)

local Tooltip = {}

local panel: Frame? = nil
local accent: Frame? = nil
local followConnection: RBXScriptConnection? = nil
local owner: GuiObject? = nil
local contentMaid = Maid.new()
local renderToken = 0 -- bumps on every render / hide, so a stale render never lands
local widthCache: { [string]: number } = {}
local heightCache: { [string]: number } = {}

-- Widest a line may be inside the panel (the panel's max width minus padding).
local function maxLineWidth(): number
	return UITheme.Size.TooltipMaxWidth - UITheme.Padding.Medium * 2
end

-- Natural one-line width of `text` (cached; may yield the first time).
local function measure(text: string, font: Font, size: number): number
	local key = `{font.Family}|{font.Weight.Name}|{size}|{text}`
	local cached = widthCache[key]
	if cached then
		return cached
	end
	local params = Instance.new("GetTextBoundsParams")
	params.Text = text
	params.Font = font
	params.Size = size
	local ok, bounds = pcall(function(): Vector2
		return TextService:GetTextBoundsAsync(params)
	end)
	-- If measuring fails, assume a long line so it wraps at the max width.
	local width = if ok then math.ceil(bounds.X) + 2 else maxLineWidth()
	widthCache[key] = width
	return width
end

-- Height of `text` wrapped at `width` (cached; may yield the first time).
local function measureHeight(text: string, font: Font, size: number, width: number): number
	local key = `{font.Family}|{font.Weight.Name}|{size}|{width}|{text}`
	local cached = heightCache[key]
	if cached then
		return cached
	end
	local params = Instance.new("GetTextBoundsParams")
	params.Text = text
	params.Font = font
	params.Size = size
	params.Width = width
	local ok, bounds = pcall(function(): Vector2
		return TextService:GetTextBoundsAsync(params)
	end)
	-- If measuring fails, guess from the one-line width.
	local height = if ok then math.ceil(bounds.Y) + 2 else math.ceil(size * 1.25 * math.ceil(measure(text, font, size) / width))
	heightCache[key] = height
	return height
end

-- Is `target` still on screen (in the game, visible all the way up, its ScreenGui enabled)?
local function isShown(target: GuiObject): boolean
	if not target:IsDescendantOf(game) then
		return false
	end
	local current: Instance? = target
	while current do
		if current:IsA("GuiObject") and not current.Visible then
			return false
		elseif current:IsA("LayerCollector") then
			return current.Enabled
		end
		current = current.Parent
	end
	return false
end

local body: Frame? = nil -- the padded, list-laid-out inside of the panel

local function getPanel(): Frame
	if panel and panel.Parent then
		return panel
	end
	local frame: Frame = Create.new("Frame", {
		Name = "Tooltip",
		AutomaticSize = Enum.AutomaticSize.XY,
		Size = UDim2.fromOffset(0, 0),
		Visible = false,
		ZIndex = 50,
	})
	-- No inner glow: the tooltip auto-sizes around its body.
	Create.ApplyPanelStyle(frame, { Glow = false, Transparency = 0.04, Color = UITheme.Colors.Midnight, StrokeColor = UITheme.Colors.EdgeBright, StrokeTransparency = 0.45 })
	Create.new("UISizeConstraint", { MaxSize = Vector2.new(UITheme.Size.TooltipMaxWidth, math.huge), Parent = frame })
	-- A thin bar down the left edge in the title's colour.
	accent = Create.new("Frame", {
		Name = "Accent",
		BorderSizePixel = 0,
		BackgroundColor3 = UITheme.Colors.Aqua,
		Position = UDim2.fromOffset(0, 8),
		Size = UDim2.new(0, 3, 1, -16),
		ZIndex = 51,
		Parent = frame,
	})
	local inner: Frame = Create.new("Frame", {
		Name = "Body",
		BackgroundTransparency = 1,
		AutomaticSize = Enum.AutomaticSize.XY,
		Size = UDim2.fromOffset(0, 0),
		ZIndex = 50,
		Parent = frame,
	})
	Create.Padding(inner, UITheme.Padding.Medium)
	Create.List(inner, Enum.FillDirection.Vertical, UITheme.Padding.Tiny)
	body = inner
	frame.Parent = Layers.Get("Tooltip")
	panel = frame
	return frame
end

-- Screen position (top-left of the full screen) of a GuiObject.
-- AbsolutePosition is always measured below the top-bar inset, even inside
-- ScreenGuis that ignore the inset, so the inset is always added back.
local function screenPosition(target: GuiObject): Vector2
	return target.AbsolutePosition + GuiService:GetGuiInset()
end

local function clampToScreen(frame: Frame, layerPosition: Vector2): Vector2
	local layerScale = Layers.GetScale("Tooltip")
	local screen = Layers.Get("Tooltip").AbsoluteSize / layerScale
	local size = frame.AbsoluteSize / layerScale
	local x = math.clamp(layerPosition.X, 4, math.max(4, screen.X - size.X - 4))
	local y = math.clamp(layerPosition.Y, 4, math.max(4, screen.Y - size.Y - 4))
	return Vector2.new(x, y)
end

local function place(frame: Frame, layerPosition: Vector2)
	local p = clampToScreen(frame, layerPosition)
	frame.Position = UDim2.fromOffset(p.X, p.Y)
end

type LineSpec = { Text: string, Font: Font, TextSize: number, Color: Color3 }

-- Builds the panel's contents. Returns false if a newer render or a hide
-- happened while lines were being measured (then nothing is shown).
local function render(content: TooltipContent): boolean
	renderToken += 1
	local token = renderToken
	local specs: { LineSpec } = {
		{ Text = content.Title, Font = UITheme.Fonts.Title, TextSize = UITheme.TextSize.BodyLarge, Color = content.TitleColor or UITheme.Colors.Text },
	}
	if content.Subtitle then
		table.insert(specs, { Text = content.Subtitle, Font = UITheme.Fonts.Body, TextSize = UITheme.TextSize.Small, Color = UITheme.Colors.TextMuted })
	end
	local lines: { TooltipLine } = content.Lines or {}
	for _, line in lines do
		table.insert(specs, {
			Text = line.Text,
			Font = if line.Bold then UITheme.Fonts.BodyBold else UITheme.Fonts.Body,
			TextSize = UITheme.TextSize.Small,
			Color = line.Color or UITheme.Colors.Text,
		})
	end
	if content.Footer then
		table.insert(specs, { Text = content.Footer, Font = UITheme.Fonts.Body, TextSize = UITheme.TextSize.Caption, Color = UITheme.Colors.TextDim })
	end

	-- Measure everything first (this can yield), then build in one go.
	local limit = maxLineWidth()
	local widths: { number } = {}
	local heights: { [number]: number } = {} -- only for lines that wrap
	for index, spec in specs do
		local width = measure(spec.Text, spec.Font, spec.TextSize)
		widths[index] = width
		local room = if index == 1 and content.Icon then limit - 30 else limit
		if width > room then
			heights[index] = measureHeight(spec.Text, spec.Font, spec.TextSize, room)
		end
	end
	if token ~= renderToken then
		return false
	end

	getPanel()
	local frame = body :: Frame
	contentMaid:Clean()
	if accent then
		accent.BackgroundColor3 = content.TitleColor or UITheme.Colors.Aqua
	end
	for index, spec in specs do
		local width = widths[index]
		if index == 1 and content.Icon then
			-- Title row: [icon] Title
			local iconSize = 22
			local row: Frame = contentMaid:Add(Create.new("Frame", {
				Name = "TitleRow",
				BackgroundTransparency = 1,
				AutomaticSize = Enum.AutomaticSize.Y,
				Size = UDim2.fromOffset(math.min(width, limit - iconSize - 8) + iconSize + 8, 0),
				LayoutOrder = index,
				Parent = frame,
			}))
			Icons.new(content.Icon, {
				Size = UDim2.fromOffset(iconSize, iconSize),
				Color = spec.Color,
				Parent = row,
			})
			Create.Label({
				Text = spec.Text,
				Font = spec.Font,
				TextSize = spec.TextSize,
				Color = spec.Color,
				AutomaticSize = if heights[index] then Enum.AutomaticSize.None else Enum.AutomaticSize.Y,
				Position = UDim2.fromOffset(iconSize + 8, 0),
				Size = UDim2.fromOffset(math.min(width, limit - iconSize - 8), heights[index] or 0),
				Wrapped = heights[index] ~= nil,
				Parent = row,
			})
		else
			contentMaid:Add(Create.Label({
				Text = spec.Text,
				Font = spec.Font,
				TextSize = spec.TextSize,
				Color = spec.Color,
				AutomaticSize = if heights[index] then Enum.AutomaticSize.None else Enum.AutomaticSize.Y,
				Size = UDim2.fromOffset(math.min(width, limit), heights[index] or 0),
				Wrapped = heights[index] ~= nil,
				LayoutOrder = index,
				Parent = frame,
			}))
		end
	end
	return true
end

local function stopFollowing()
	if followConnection then
		followConnection:Disconnect()
		followConnection = nil
	end
end

-- Shows content. With `anchor`, sits beside it; otherwise follows the mouse.
-- `target` (set by Attach) is the GuiObject the tooltip belongs to: the
-- tooltip hides itself as soon as that object leaves the screen.
function Tooltip.Show(content: TooltipContent, anchor: GuiObject?, target: GuiObject?)
	stopFollowing()
	owner = target
	if not render(content) then
		return
	end
	if target and (owner ~= target or not isShown(target)) then
		return -- hidden or replaced while the lines were measured
	end
	local frame = getPanel()
	frame.Visible = true
	local function update()
		local current = owner
		if current and not isShown(current) then
			Tooltip.Hide()
			return
		end
		if anchor then
			local layerScale = Layers.GetScale("Tooltip")
			local pos = screenPosition(anchor) / layerScale
			local size = anchor.AbsoluteSize / layerScale
			place(frame, Vector2.new(pos.X + size.X + 10, pos.Y))
		else
			local mouse = Layers.ToLayerSpace("Tooltip", UserInputService:GetMouseLocation())
			place(frame, mouse + CURSOR_OFFSET)
		end
	end
	update()
	followConnection = RunService.RenderStepped:Connect(update)
end

function Tooltip.Hide()
	stopFollowing()
	owner = nil
	renderToken += 1
	if panel then
		panel.Visible = false
	end
	contentMaid:Clean()
end

-- Wires a target; provider is called each time it shows (can return nil to skip).
-- Returns a cleanup function.
function Tooltip.Attach(target: GuiObject, provider: () -> TooltipContent?): () -> ()
	local maid = Maid.new()

	local function show(anchor: GuiObject?)
		local content = provider()
		if content then
			Tooltip.Show(content, anchor, target)
		end
	end
	local function hide()
		if owner == target then
			Tooltip.Hide()
		end
	end

	maid:Add(target.MouseEnter:Connect(function()
		if not UserInputService.TouchEnabled or UserInputService.MouseEnabled then
			show(nil)
		end
	end))
	maid:Add(target.MouseLeave:Connect(hide))
	maid:Add(target.SelectionGained:Connect(function()
		show(target)
	end))
	maid:Add(target.SelectionLost:Connect(hide))
	maid:Add(target.InputBegan:Connect(function(input: InputObject)
		if input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end
		maid:Set("longPress", task.delay(LONG_PRESS, function()
			if input.UserInputState == Enum.UserInputState.Begin or input.UserInputState == Enum.UserInputState.Change then
				show(target)
			end
		end))
	end))
	maid:Add(target.InputEnded:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.Touch then
			maid:Set("longPress", nil)
			hide()
		end
	end))
	maid:Add(target.AncestryChanged:Connect(function()
		if not target:IsDescendantOf(game) then
			hide()
		end
	end))
	maid:Add(hide)

	return function()
		maid:Clean()
	end
end

return Tooltip
