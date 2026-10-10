--!strict
--[[
	Frames
	Compact party frames at the bottom left (Spec Section 12): one per other member, no portrait,
	with a leader mark, name, level, a health bar and a Current bar. They refresh
	Social.Party.FrameUpdateHz times a second from the member's Humanoid and player attributes;
	a member whose character isn't streamed in shows dimmed. On touch they sit above the
	thumbstick.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Strings = require(Shared.Strings)

local UI = script.Parent.Parent.Parent.UI
local UITheme = require(UI.UITheme)
local Create = require(UI.Create)
local Layers = require(UI.Layers)
local Device = require(UI.Device)

local State = require(script.Parent.State)

local C = UITheme.Colors
local S = Strings.Party
local SP = Config.Social.Party

local WIDTH = 200
local ROW_HEIGHT = 40

type Row = {
	Frame: Frame,
	Mark: Frame,
	Name: TextLabel,
	Level: TextLabel,
	Health: Frame,
	Current: Frame,
	Player: Player?,
}

local Frames = {}

local holder: Frame
local rows: { Row } = {}

local function bar(parent: Instance, y: number, height: number, color: Color3): Frame
	local track: Frame = Create.new("Frame", {
		Name = "Track",
		BackgroundColor3 = C.HudSunken,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(8, y),
		Size = UDim2.new(1, -16, 0, height),
		Parent = parent,
	})
	Create.Corner(track, UDim.new(0, 2))
	local fill: Frame = Create.new("Frame", {
		Name = "Fill",
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Parent = track,
	})
	Create.Corner(fill, UDim.new(0, 2))
	return fill
end

local function newRow(index: number): Row
	local frame: Frame = Create.new("Frame", {
		Name = "Member",
		BackgroundColor3 = C.HudPanel,
		BackgroundTransparency = 0.25,
		Size = UDim2.fromOffset(WIDTH, ROW_HEIGHT),
		LayoutOrder = index,
		Parent = holder,
	})
	Create.Corner(frame, UDim.new(0, 6))
	Create.Stroke(frame, C.Brass, 1, 0.6)
	local mark: Frame = Create.new("Frame", {
		Name = "Leader",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(13, 12),
		Size = UDim2.fromOffset(7, 7),
		Rotation = 45,
		BackgroundColor3 = C.Parry,
		BorderSizePixel = 0,
		Parent = frame,
	})
	local name = Create.Label({
		Name = "Name",
		Text = "",
		Font = UITheme.Fonts.BodyBold,
		TextSize = 14,
		Position = UDim2.fromOffset(22, 3),
		Size = UDim2.new(1, -70, 0, 18),
		Parent = frame,
	})
	name.TextTruncate = Enum.TextTruncate.AtEnd
	local level = Create.Label({
		Name = "Level",
		Text = "",
		TextSize = 12,
		Color = C.TextMuted,
		XAlignment = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -8, 0, 3),
		Size = UDim2.fromOffset(48, 18),
		Parent = frame,
	})
	return {
		Frame = frame,
		Mark = mark,
		Name = name,
		Level = level,
		Health = bar(frame, 23, 7, C.Health),
		Current = bar(frame, 32, 4, C.Current),
		Player = nil,
	}
end

local function update()
	local party = State.Party
	for _, row in rows do
		local who = row.Player
		if who and row.Frame.Visible then
			local vitals = State.Vitals(who)
			row.Level.Text = Strings.Format(S.Level, { level = vitals.Level })
			row.Health.Size = UDim2.fromScale(math.clamp(vitals.Health / math.max(vitals.MaxHealth, 1), 0, 1), 1)
			row.Current.Size = UDim2.fromScale(math.clamp(vitals.Current / vitals.MaxCurrent, 0, 1), 1)
			row.Name.TextColor3 = if vitals.Present then C.Text else C.TextDim
			row.Frame.BackgroundTransparency = if vitals.Present and vitals.Health > 0 then 0.25 else 0.55
			row.Mark.Visible = party ~= nil and party.Leader == who.UserId
		end
	end
end

local function rebuild()
	local others = State.Others()
	for index, who in others do
		local row = rows[index] or newRow(index)
		rows[index] = row
		row.Player = who
		row.Name.Text = who.DisplayName
		row.Frame.Visible = true
	end
	for index = #others + 1, #rows do
		rows[index].Player = nil
		rows[index].Frame.Visible = false
	end
	holder.Visible = #others > 0
	update()
end

local function layout()
	if Device.IsTouch() then
		holder.Position = UDim2.new(0, 12, 0.62, 0)
	else
		holder.Position = UDim2.new(0, 16, 1, -24)
	end
end

function Frames.Init()
	holder = Create.new("Frame", {
		Name = "PartyFrames",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0, 1),
		Size = UDim2.fromOffset(WIDTH, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Visible = false,
		Parent = Layers.Get("HUD"),
	})
	local list = Create.List(holder, Enum.FillDirection.Vertical, 4)
	list.VerticalAlignment = Enum.VerticalAlignment.Bottom
	layout()
	Device.Changed:Connect(layout)
	State.Changed:Connect(rebuild)
	Players.PlayerAdded:Connect(rebuild)
	Players.PlayerRemoving:Connect(function()
		task.defer(rebuild)
	end)
end

function Frames.Start()
	task.spawn(function()
		while true do
			task.wait(1 / SP.FrameUpdateHz)
			if holder.Visible then
				update()
			end
		end
	end)
end

return Frames
