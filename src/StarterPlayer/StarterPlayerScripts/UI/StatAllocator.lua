--!strict
--[[
	StatAllocator
	The attribute block shared by the Character page and the Skill Tree's
	build panel: points to spend, then one row per stat with its icon, name,
	total (base, + staged, + gear and skill tree), and - / + buttons. Staged
	points live in StatDraft until Confirm sends them; Reset drops them.
	Hovering a stat's name explains what each point gives and the soft caps.
]]

local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Strings = require(Shared.Strings)
local Types = require(Shared.Types)
local Maid = require(Shared.Util.Maid)
local GearStats = require(Shared.Data.GearStats)

local UITheme = require(script.Parent.UITheme)
local Create = require(script.Parent.Create)
local Icons = require(script.Parent.Icons)
local StatDraft = require(script.Parent.StatDraft)
local Components = require(script.Parent.Components)

type PlayerData = Types.PlayerData

local C = UITheme.Colors
local S = Strings.Inventory
local ROW_HEIGHT = 34

export type StatAllocatorProps = {
	Data: () -> PlayerData?,
	Confirm: (points: { [string]: number }) -> (),
	Width: UDim?, -- defaults to the parent's full width
	LayoutOrder: number?,
	Parent: Instance,
}

export type StatAllocator = {
	Instance: Frame,
	Refresh: (self: StatAllocator) -> (),
	Destroy: (self: StatAllocator) -> (),
}

local StatAllocator = {}

-- What one more point of a stat gives, for its tooltip.
local function statTooltip(stat: string): Components.TooltipContent
	local P = Config.Progression
	local effect = Strings.Format(Strings.Progression.StatEffects[stat] or "", {
		health = P.Stats.Vitality.HealthPerPoint,
		stamina = P.Stats.Endurance.StaminaPerPoint,
		vessel = P.Stats.Draw.VesselPerPoint,
	})
	local lines: { Components.TooltipLine } = { { Text = effect } }
	for _, cap in P.SoftCaps do
		table.insert(lines, {
			Text = Strings.Format(S.Sheet.SoftCapHint, { threshold = cap.Threshold, percent = math.floor(cap.Multiplier * 100) }),
			Color = C.TextDim,
		})
	end
	return { Title = S.StatNames[stat] or stat, Icon = Icons.ForStat(stat), TitleColor = C.Accent, Lines = lines }
end

function StatAllocator.new(props: StatAllocatorProps): StatAllocator
	local maid = Maid.new()
	local frame: Frame = Create.new("Frame", {
		Name = "Attributes",
		BackgroundTransparency = 1,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(props.Width or UDim.new(1, 0), UDim.new(0, 0)),
		LayoutOrder = props.LayoutOrder or 0,
	})
	maid:Add(frame)
	Create.List(frame, Enum.FillDirection.Vertical, 4)

	-- Header: points to spend.
	local header: Frame = Create.new("Frame", { Name = "Header", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 30), LayoutOrder = 1, Parent = frame })
	Icons.new("StatPoint", { Size = UDim2.fromOffset(20, 20), Position = UDim2.fromOffset(0, 5), Color = C.Aqua, Parent = header })
	local pointsLabel = Create.Label({
		Text = "",
		Font = UITheme.Fonts.BodyBold,
		TextSize = UITheme.TextSize.Small,
		Position = UDim2.fromOffset(28, 0),
		Size = UDim2.new(1, -28, 1, 0),
		Parent = header,
	})

	type Row = {
		Stat: string,
		Value: TextLabel,
		Minus: Components.Button,
		Plus: Components.Button,
		Icon: ImageLabel,
	}
	local rows: { Row } = {}
	for index, stat in GearStats.StatNames do
		local row: Frame = Create.new("Frame", {
			Name = `Stat_{stat}`,
			BackgroundColor3 = C.PanelSunken,
			BackgroundTransparency = 0.35,
			Size = UDim2.new(1, 0, 0, ROW_HEIGHT),
			LayoutOrder = 10 + index,
			Parent = frame,
		})
		Create.Corner(row, UITheme.CornerSmall)
		local icon = Icons.new(Icons.ForStat(stat), {
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, 8, 0.5, 0),
			Size = UDim2.fromOffset(20, 20),
			Color = C.Accent,
			Parent = row,
		})
		local name = Create.Label({
			Text = S.StatNames[stat] or stat,
			Font = UITheme.Fonts.BodyMedium,
			TextSize = UITheme.TextSize.Small,
			Color = C.TextMuted,
			Position = UDim2.fromOffset(36, 0),
			Size = UDim2.new(0.5, -36, 1, 0),
			Parent = row,
		})
		name.Active = true
		maid:Add(Components.Tooltip.Attach(name, function()
			return statTooltip(stat)
		end))
		local value = Create.Label({
			Text = "",
			RichText = true,
			Font = UITheme.Fonts.BodyBold,
			TextSize = UITheme.TextSize.Small,
			XAlignment = Enum.TextXAlignment.Right,
			Position = UDim2.fromScale(0.5, 0),
			Size = UDim2.new(0.5, -66, 1, 0),
			Parent = row,
		})
		local minus = Components.Button.new({
			Name = `Minus_{stat}`,
			Text = "",
			Icon = "Minus",
			Size = UDim2.fromOffset(26, 24),
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -34, 0.5, 0),
			TextSize = 12,
			Parent = row,
			OnActivated = function()
				local current = props.Data()
				if current then
					StatDraft.Step(stat, -1, current.StatPoints)
				end
			end,
		})
		local plus = Components.Button.new({
			Name = `Plus_{stat}`,
			Text = "",
			Icon = "Plus",
			Variant = "Primary",
			Size = UDim2.fromOffset(26, 24),
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -4, 0.5, 0),
			TextSize = 12,
			Parent = row,
			OnActivated = function()
				local current = props.Data()
				if current then
					StatDraft.Step(stat, 1, current.StatPoints)
				end
			end,
		})
		maid:Add(minus)
		maid:Add(plus)
		table.insert(rows, { Stat = stat, Value = value, Minus = minus, Plus = plus, Icon = icon })
	end

	-- Confirm / Reset, shown while points are staged.
	local actions: Frame = Create.new("Frame", { Name = "StatActions", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 38), LayoutOrder = 100, Visible = false, Parent = frame })
	local confirm = Components.Button.new({
		Name = "ConfirmStats",
		Text = S.Sheet.ConfirmStats,
		Icon = "Check",
		Variant = "Primary",
		TextSize = UITheme.TextSize.Small,
		Size = UDim2.new(0.58, -4, 1, 0),
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Parent = actions,
		OnActivated = function()
			if StatDraft.Total() > 0 then
				props.Confirm(StatDraft.Snapshot())
			end
		end,
	})
	local reset = Components.Button.new({
		Name = "ResetStats",
		Text = S.Sheet.ResetStats,
		Icon = "Reset",
		TextSize = UITheme.TextSize.Small,
		Size = UDim2.new(0.42, -4, 1, 0),
		Parent = actions,
		OnActivated = function()
			StatDraft.Clear()
		end,
	})
	maid:Add(confirm)
	maid:Add(reset)

	local self = { Instance = frame }

	function self.Refresh(_self: StatAllocator)
		local current = props.Data()
		if not current then
			return
		end
		StatDraft.Validate(current.StatPoints)
		local staged = StatDraft.Total()
		local free = current.StatPoints - staged
		pointsLabel.Text = if current.StatPoints > 0 then Strings.Format(S.Sheet.PointsToSpend, { points = free }) else S.Sheet.NoPointsToSpend
		pointsLabel.TextColor3 = if current.StatPoints > 0 then C.Aqua else C.TextDim
		local summary = GearStats.Summarize(current)
		local hasPoints = current.StatPoints > 0
		local selected = GuiService.SelectedObject
		for _, row in rows do
			local base = (current.Stats :: any)[row.Stat] :: number
			local extra = (summary.GearStats[row.Stat] or 0) + (summary.TreeStats[row.Stat] or 0)
			local added = StatDraft.Get(row.Stat)
			local text = tostring(base)
			if added > 0 then
				text ..= ` <font color="#D6F1FF">+{added}</font>`
			end
			if extra ~= 0 then
				text ..= ` <font color="#5ED3F3">(+{extra})</font>`
			end
			row.Value.Text = text
			row.Icon.ImageColor3 = if added > 0 then C.Foam else C.Accent
			row.Minus.Instance.Visible = hasPoints
			row.Plus.Instance.Visible = hasPoints
			row.Minus:SetEnabled(added > 0)
			row.Plus:SetEnabled(free > 0)
			-- Keep gamepad selection on a button that just became disabled.
			if (selected == row.Plus.Instance and free <= 0) or (selected == row.Minus.Instance and added <= 0) then
				GuiService.SelectedObject = if free > 0 then row.Plus.Instance elseif added > 0 then row.Minus.Instance else nil
			end
		end
		actions.Visible = staged > 0
	end

	function self.Destroy(_self: StatAllocator)
		maid:Clean()
	end

	maid:Add(StatDraft.Changed:Connect(function()
		self.Refresh(self :: any)
	end))
	frame.Parent = props.Parent
	return self :: StatAllocator
end

return StatAllocator
