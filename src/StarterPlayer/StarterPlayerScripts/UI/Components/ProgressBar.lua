--!strict
--[[
	ProgressBar
	Resource bar used for health, Current, stamina, posture and boss bars.
	- Trail: a lighter "recent damage" segment that waits 0.5 s, then drains.
	- Flow: a scrolling highlight that makes the Current bar look liquid.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UI = script.Parent.Parent
local UITheme = require(UI.UITheme)
local Create = require(UI.Create)
local Animator = require(UI.Animator)
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Maid = require(Shared.Util.Maid)
local TweenUtil = require(Shared.Util.TweenUtil)
local MathUtil = require(Shared.Util.MathUtil)

export type ProgressBarProps = {
	Color: Color3,
	TrailColor: Color3?,
	Flow: boolean?,
	ShowText: boolean?,
	Size: UDim2?,
	Position: UDim2?,
	AnchorPoint: Vector2?,
	LayoutOrder: number?,
	Name: string?,
	Parent: Instance?,
}

export type ProgressBar = {
	Instance: Frame,
	Maid: Maid.Maid,
	SetValue: (self: ProgressBar, current: number, max: number, instant: boolean?) -> (),
	SetColor: (self: ProgressBar, color: Color3) -> (),
	GetFraction: (self: ProgressBar) -> number,
	Destroy: (self: ProgressBar) -> (),
}

local ProgressBar = {}

local function brighten(color: Color3, amount: number): Color3
	return color:Lerp(Color3.new(1, 1, 1), amount)
end

function ProgressBar.new(props: ProgressBarProps): ProgressBar
	local maid = Maid.new()
	local fraction = 1
	local trailFraction = 1

	local track: Frame = Create.new("Frame", {
		Name = props.Name or "ProgressBar",
		BackgroundColor3 = UITheme.Colors.Track,
		BackgroundTransparency = 0.2,
		BorderSizePixel = 0,
		ClipsDescendants = true,
		Size = props.Size or UDim2.new(1, 0, 0, 14),
		Position = props.Position or UDim2.new(),
		AnchorPoint = props.AnchorPoint or Vector2.zero,
		LayoutOrder = props.LayoutOrder or 0,
	})
	Create.Corner(track, UDim.new(0, 4))
	Create.Stroke(track, UITheme.Colors.Brass, 1, 0.75)
	maid:Add(track)

	local trail: Frame? = nil
	if props.TrailColor then
		local created: Frame = Create.new("Frame", {
			Name = "Trail",
			BackgroundColor3 = props.TrailColor,
			BorderSizePixel = 0,
			Size = UDim2.fromScale(1, 1),
			Parent = track,
		})
		Create.Corner(created, UDim.new(0, 4))
		trail = created
	end

	local fill: Frame = Create.new("Frame", {
		Name = "Fill",
		BackgroundColor3 = props.Color,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 2,
		Parent = track,
	})
	Create.Corner(fill, UDim.new(0, 4))

	-- Top highlight so bars read as glossy liquid rather than flat blocks.
	local sheen: Frame = Create.new("Frame", {
		Name = "Sheen",
		BackgroundColor3 = Color3.new(1, 1, 1),
		BackgroundTransparency = 0.82,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0.42, 0),
		ZIndex = 3,
		Parent = fill,
	})
	Create.Corner(sheen, UDim.new(0, 4))

	local flowGradient: UIGradient? = nil
	if props.Flow then
		local base = props.Color
		local bright = brighten(base, 0.45)
		local gradient: UIGradient = Create.new("UIGradient", {
			Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, base),
				ColorSequenceKeypoint.new(0.2, bright),
				ColorSequenceKeypoint.new(0.4, base),
				ColorSequenceKeypoint.new(0.6, bright),
				ColorSequenceKeypoint.new(0.8, base),
				ColorSequenceKeypoint.new(1, bright),
			}),
			Parent = fill,
		})
		fill.BackgroundColor3 = Color3.new(1, 1, 1)
		maid:Add(Animator.Flow(gradient, UITheme.Motion.FlowSpeed))
		flowGradient = gradient
	end

	local label: TextLabel? = nil
	if props.ShowText then
		local created = Create.Label({
			Name = "Value",
			Text = "",
			Font = UITheme.Fonts.Numbers,
			TextSize = UITheme.TextSize.Caption,
			XAlignment = Enum.TextXAlignment.Center,
			Size = UDim2.fromScale(1, 1),
			Parent = track,
		})
		created.ZIndex = 4
		created.TextStrokeTransparency = 0.4
		label = created
	end

	local self = {
		Instance = track,
		Maid = maid,
	}

	function self.SetValue(_self: ProgressBar, current: number, max: number, instant: boolean?)
		local safeMax = if max > 0 then max else 1
		local newFraction = math.clamp(current / safeMax, 0, 1)
		local m = UITheme.Motion
		if label then
			label.Text = `{MathUtil.FormatNumber(math.max(0, current))} / {MathUtil.FormatNumber(max)}`
		end
		if instant then
			maid:Set("fillTween", nil)
			maid:Set("trailTween", nil)
			maid:Set("trailDelay", nil)
			fill.Size = UDim2.fromScale(newFraction, 1)
			if trail then
				trail.Size = UDim2.fromScale(newFraction, 1)
			end
			fraction = newFraction
			trailFraction = newFraction
			return
		end
		if newFraction < fraction then
			-- Damage: fill snaps down fast, the trail holds then drains.
			maid:Set("fillTween", TweenUtil.Play(fill, 0.08, { Size = UDim2.fromScale(newFraction, 1) }))
			local trailFrame = trail
			if trailFrame then
				maid:Set("trailTween", nil)
				maid:Set("trailDelay", task.delay(m.TrailDelay, function()
					trailFraction = newFraction
					maid:Set(
						"trailTween",
						TweenUtil.Play(trailFrame, m.TrailDrainTime, { Size = UDim2.fromScale(newFraction, 1) }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
					)
				end))
			end
		else
			-- Gain: fill grows smoothly; the trail stays at least as long as the fill.
			maid:Set("fillTween", TweenUtil.Play(fill, 0.2, { Size = UDim2.fromScale(newFraction, 1) }))
			if trail and trailFraction < newFraction then
				maid:Set("trailDelay", nil)
				maid:Set("trailTween", nil)
				trail.Size = UDim2.fromScale(newFraction, 1)
				trailFraction = newFraction
			end
		end
		fraction = newFraction
	end

	function self.SetColor(_self: ProgressBar, color: Color3)
		if flowGradient then
			local bright = brighten(color, 0.45)
			flowGradient.Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, color),
				ColorSequenceKeypoint.new(0.2, bright),
				ColorSequenceKeypoint.new(0.4, color),
				ColorSequenceKeypoint.new(0.6, bright),
				ColorSequenceKeypoint.new(0.8, color),
				ColorSequenceKeypoint.new(1, bright),
			})
		else
			fill.BackgroundColor3 = color
		end
	end

	function self.GetFraction(_self: ProgressBar): number
		return fraction
	end

	function self.Destroy(_self: ProgressBar)
		maid:Clean()
	end

	track.Parent = props.Parent
	return self :: ProgressBar
end

return ProgressBar
