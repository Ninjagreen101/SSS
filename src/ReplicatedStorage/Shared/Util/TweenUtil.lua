--!strict
--[[
	TweenUtil
	Thin helpers over TweenService so every system tweens the same way and
	tweens can be cancelled through a Maid.
]]

local TweenService = game:GetService("TweenService")

local TweenUtil = {}

function TweenUtil.Info(
	duration: number,
	style: Enum.EasingStyle?,
	direction: Enum.EasingDirection?,
	repeatCount: number?,
	reverses: boolean?,
	delayTime: number?
): TweenInfo
	return TweenInfo.new(
		duration,
		style or Enum.EasingStyle.Quad,
		direction or Enum.EasingDirection.Out,
		repeatCount or 0,
		reverses or false,
		delayTime or 0
	)
end

-- Creates and plays a tween. `props` uses property names as keys.
function TweenUtil.Play(
	instance: Instance,
	duration: number,
	props: { [string]: any },
	style: Enum.EasingStyle?,
	direction: Enum.EasingDirection?
): Tween
	local tween = TweenService:Create(instance, TweenUtil.Info(duration, style, direction), props)
	tween:Play()
	return tween
end

-- Same as Play but with a full TweenInfo.
function TweenUtil.PlayInfo(instance: Instance, info: TweenInfo, props: { [string]: any }): Tween
	local tween = TweenService:Create(instance, info, props)
	tween:Play()
	return tween
end

-- Yields until the tween finishes (or is cancelled). Returns the final state.
function TweenUtil.Await(tween: Tween): Enum.PlaybackState
	if tween.PlaybackState == Enum.PlaybackState.Playing or tween.PlaybackState == Enum.PlaybackState.Delayed then
		return tween.Completed:Wait()
	end
	return tween.PlaybackState
end

return TweenUtil
