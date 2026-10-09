--!strict
--[[
	RadialProgress
	A circular progress ring (Saturation around the portrait, interaction
	hold timers, later skill cooldowns).

	How it works: Roblox has no arc primitive, so the ring is drawn twice,
	each copy clipped to one half of the square. A UIGradient on each ring's
	UIStroke is fully opaque on one side of a hard edge and transparent on the
	other. Rotating that gradient sweeps the hard edge around the centre:
		right half shows 0..180 degrees  -> rotation = angle        (0..180)
		left half shows 180..360 degrees -> rotation = angle        (180..360)
	(each half parks its edge at 180 when it should show nothing / everything).
	Progress starts at 12 o'clock and fills clockwise.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UI = script.Parent.Parent
local UITheme = require(UI.UITheme)
local Create = require(UI.Create)
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Maid = require(Shared.Util.Maid)
local TweenUtil = require(Shared.Util.TweenUtil)

export type RadialProgressProps = {
	Color: Color3,
	TrackColor: Color3?,
	TrackTransparency: number?,
	Thickness: number?,
	Size: UDim2?,
	Position: UDim2?,
	AnchorPoint: Vector2?,
	ZIndex: number?,
	Name: string?,
	Parent: Instance?,
}

export type RadialProgress = {
	Instance: Frame,
	Maid: Maid.Maid,
	SetValue: (self: RadialProgress, fraction: number, tweenTime: number?) -> (),
	GetValue: (self: RadialProgress) -> number,
	SetColor: (self: RadialProgress, color: Color3) -> (),
	Destroy: (self: RadialProgress) -> (),
}

local RadialProgress = {}

-- Hard-edged transparency: opaque for the first half of the gradient axis.
local HALF_MASK = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0),
	NumberSequenceKeypoint.new(0.5, 0),
	NumberSequenceKeypoint.new(0.501, 1),
	NumberSequenceKeypoint.new(1, 1),
})

local function makeRing(parent: Instance, color: Color3, thickness: number, zIndex: number, offsetX: number): (Frame, UIStroke)
	local ring: Frame = Create.new("Frame", {
		Name = "Ring",
		BackgroundTransparency = 1,
		-- The ring is twice the clip's width so its centre sits on the seam.
		Size = UDim2.fromScale(2, 1),
		Position = UDim2.fromScale(offsetX, 0),
		ZIndex = zIndex,
		Parent = parent,
	})
	Create.Corner(ring, UITheme.CornerPill)
	local stroke: UIStroke = Create.new("UIStroke", {
		Color = color,
		Thickness = thickness,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Parent = ring,
	})
	return ring, stroke
end

function RadialProgress.new(props: RadialProgressProps): RadialProgress
	local maid = Maid.new()
	local thickness = props.Thickness or 4
	local zIndex = props.ZIndex or 1
	local value = 0
	-- Tweened through a NumberValue so the angle can animate smoothly.
	local driver = Instance.new("NumberValue")
	maid:Add(driver)

	local root: Frame = Create.new("Frame", {
		Name = props.Name or "RadialProgress",
		BackgroundTransparency = 1,
		Size = props.Size or UDim2.fromOffset(64, 64),
		Position = props.Position or UDim2.new(),
		AnchorPoint = props.AnchorPoint or Vector2.zero,
		ZIndex = zIndex,
	})
	maid:Add(root)

	-- Full faint track behind the progress.
	local track: Frame = Create.new("Frame", {
		Name = "Track",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = zIndex,
		Parent = root,
	})
	Create.Corner(track, UITheme.CornerPill)
	Create.Stroke(
		track,
		props.TrackColor or UITheme.Colors.Track,
		thickness,
		if props.TrackTransparency ~= nil then props.TrackTransparency else 0.35
	)

	local strokes: { UIStroke } = {}
	local function half(name: string, x: number, ringOffset: number): UIGradient
		local clip: Frame = Create.new("Frame", {
			Name = name,
			BackgroundTransparency = 1,
			ClipsDescendants = true,
			Size = UDim2.fromScale(0.5, 1),
			Position = UDim2.fromScale(x, 0),
			ZIndex = zIndex + 1,
			Parent = root,
		})
		local _, stroke = makeRing(clip, props.Color, thickness, zIndex + 1, ringOffset)
		table.insert(strokes, stroke)
		local gradient: UIGradient = Create.new("UIGradient", {
			Transparency = HALF_MASK,
			Rotation = 0,
			Parent = stroke,
		})
		return gradient
	end
	local rightGradient = half("Right", 0.5, -1)
	local leftGradient = half("Left", 0, 0)

	local function render(fraction: number)
		local angle = math.clamp(fraction, 0, 1) * 360
		rightGradient.Rotation = math.min(angle, 180)
		leftGradient.Rotation = math.max(angle, 180)
		-- A hairline can survive at exactly 0; hide the halves outright.
		strokes[1].Enabled = angle > 0.5
		strokes[2].Enabled = angle > 180
	end
	render(0)
	maid:Add(driver.Changed:Connect(function(newValue: number)
		render(newValue)
	end))

	local self = {
		Instance = root,
		Maid = maid,
	}

	function self.SetValue(_self: RadialProgress, fraction: number, tweenTime: number?)
		value = math.clamp(fraction, 0, 1)
		if tweenTime and tweenTime > 0 then
			maid:Set("tween", TweenUtil.Play(driver, tweenTime, { Value = value }, Enum.EasingStyle.Linear))
		else
			maid:Set("tween", nil)
			driver.Value = value
			render(value)
		end
	end

	function self.GetValue(_self: RadialProgress): number
		return value
	end

	function self.SetColor(_self: RadialProgress, color: Color3)
		for _, stroke in strokes do
			stroke.Color = color
		end
	end

	function self.Destroy(_self: RadialProgress)
		maid:Clean()
	end

	root.Parent = props.Parent
	return self :: RadialProgress
end

return RadialProgress
