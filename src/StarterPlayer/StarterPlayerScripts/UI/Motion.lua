--!strict
--[[
	Motion
	Standard UI motion: menus open with a 0.18 s scale-from-96% + fade and
	close in 0.12 s; buttons scale to 1.04 on hover and 0.96 on press.
	Reduced Motion (a player setting) removes scaling and keeps short fades.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UITheme = require(script.Parent.UITheme)
local TweenUtil = require(ReplicatedStorage:WaitForChild("Shared").Util.TweenUtil)
local Maid = require(ReplicatedStorage:WaitForChild("Shared").Util.Maid)

local Motion = {}

local reducedMotion = false

function Motion.SetReducedMotion(enabled: boolean)
	reducedMotion = enabled
end

function Motion.IsReduced(): boolean
	return reducedMotion
end

-- Opens a CanvasGroup (fade) with its UIScale (pop). Yields until done when `wait` is true.
function Motion.Open(group: CanvasGroup, scale: UIScale, wait: boolean?)
	local m = UITheme.Motion
	group.Visible = true
	group.GroupTransparency = 1
	scale.Scale = if reducedMotion then 1 else m.OpenScale
	local fade = TweenUtil.Play(group, m.OpenTime, { GroupTransparency = 0 }, m.Style, Enum.EasingDirection.Out)
	if not reducedMotion then
		TweenUtil.Play(scale, m.OpenTime, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	end
	if wait then
		TweenUtil.Await(fade)
	end
end

-- Closes with fade + slight shrink, then hides. Always yields until hidden.
function Motion.Close(group: CanvasGroup, scale: UIScale)
	local m = UITheme.Motion
	local fade = TweenUtil.Play(group, m.CloseTime, { GroupTransparency = 1 }, m.Style, Enum.EasingDirection.In)
	if not reducedMotion then
		TweenUtil.Play(scale, m.CloseTime, { Scale = m.OpenScale }, m.Style, Enum.EasingDirection.In)
	end
	TweenUtil.Await(fade)
	group.Visible = false
end

-- Adds hover/press scale feedback to a button. Returns a Maid with the connections.
function Motion.AttachButtonFeedback(button: GuiButton): Maid.Maid
	local maid = Maid.new()
	local scale = button:FindFirstChildOfClass("UIScale")
	if not scale then
		local created = Instance.new("UIScale")
		created.Parent = button
		scale = created
	end
	local uiScale = scale :: UIScale
	local hovered = false
	local pressed = false
	local m = UITheme.Motion

	local function refresh()
		if reducedMotion then
			uiScale.Scale = 1
			return
		end
		local target = if pressed then m.PressScale elseif hovered then m.HoverScale else 1
		maid:Set("tween", TweenUtil.Play(uiScale, m.HoverTime, { Scale = target }, m.Style))
	end

	maid:Add(button.MouseEnter:Connect(function()
		hovered = true
		refresh()
	end))
	maid:Add(button.MouseLeave:Connect(function()
		hovered = false
		pressed = false
		refresh()
	end))
	maid:Add(button.SelectionGained:Connect(function()
		hovered = true
		refresh()
	end))
	maid:Add(button.SelectionLost:Connect(function()
		hovered = false
		pressed = false
		refresh()
	end))
	maid:Add(button.InputBegan:Connect(function(input: InputObject)
		local t = input.UserInputType
		if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch or input.KeyCode == Enum.KeyCode.ButtonA then
			pressed = true
			refresh()
		end
	end))
	maid:Add(button.InputEnded:Connect(function(input: InputObject)
		local t = input.UserInputType
		if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch or input.KeyCode == Enum.KeyCode.ButtonA then
			pressed = false
			if t == Enum.UserInputType.Touch then
				hovered = false
			end
			refresh()
		end
	end))
	return maid
end

return Motion
