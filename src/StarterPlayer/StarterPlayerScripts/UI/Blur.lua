--!strict
--[[
	Blur
	Reference-counted background blur for full-screen menus and modals.
	Each opener calls Push() and the returned release function when it closes;
	the blur fades out only when nobody needs it any more.
]]

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UITheme = require(script.Parent.UITheme)
local TweenUtil = require(ReplicatedStorage:WaitForChild("Shared").Util.TweenUtil)

local Blur = {}

local holders = 0
local effect: BlurEffect? = nil

local function getEffect(): BlurEffect
	if effect and effect.Parent then
		return effect
	end
	local created = Instance.new("BlurEffect")
	created.Name = "SpireMenuBlur"
	created.Size = 0
	created.Enabled = true
	-- Lighting children created on the client exist only for this player.
	created.Parent = Lighting
	effect = created
	return created
end

local function apply()
	local blur = getEffect()
	local target = if holders > 0 then UITheme.BlurSize else 0
	local time = if holders > 0 then UITheme.Motion.OpenTime else UITheme.Motion.CloseTime
	TweenUtil.Play(blur, time, { Size = target })
end

-- Requests blur; returns a release function (safe to call more than once).
function Blur.Push(): () -> ()
	holders += 1
	apply()
	local released = false
	return function()
		if released then
			return
		end
		released = true
		holders = math.max(0, holders - 1)
		apply()
	end
end

return Blur
