--!strict
--[[
	TouchControls
	The mobile button cluster (Spec Section 12): big attack button in the
	bottom-right with the four spell buttons on an arc around it, dodge /
	block / jump in a column beside it, small lock-on and interact buttons.
	Roblox's own thumbstick stays bottom-left; its jump button is replaced
	by ours so it can't overlap the cluster.

	- Attack: tap = Light Attack, hold past HoldThreshold = Heavy Attack.
	- Every target is at least 44 px; positions/scales can be overridden per
	  button from Settings.TouchLayout (the layout editor writes these).
	- Visible only on touch devices and only in the Gameplay context.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local InputConfig = require(Shared.Config.Input)
local Strings = require(Shared.Strings)
local Maid = require(Shared.Util.Maid)
local TweenUtil = require(Shared.Util.TweenUtil)

local Controllers = script.Parent.Parent
local UI = Controllers.Parent.UI
local UITheme = require(UI.UITheme)
local Create = require(UI.Create)
local Layers = require(UI.Layers)
local Animator = require(UI.Animator)
local Device = require(UI.Device)
local DataController = require(Controllers.DataController)

-- Minimal view of InputController (avoids a circular require).
type InputApi = {
	BeginAction: (action: any, device: any?) -> boolean,
	EndAction: (action: any) -> (),
	GetContext: () -> string,
	ContextChanged: { Connect: (self: any, handler: (string) -> ()) -> any },
}

type ButtonState = {
	Info: InputConfig.TouchButtonInfo,
	Button: TextButton,
	Scale: UIScale,
	Input: InputObject?,
	HoldThread: thread?,
	HoldFired: boolean,
}

local TouchControls = {}

local input: InputApi
local maid = Maid.new()
local root: Frame? = nil
local states: { [string]: ButtonState } = {}

local function applyLayout(layout: { [string]: any }?)
	for id, state in states do
		local info = state.Info
		local override = layout and layout[id]
		local scale = 1
		if type(override) == "table" then
			state.Button.Position = UDim2.fromScale(override.X, override.Y)
			scale = override.Scale
		elseif info.Corner == "TopRight" then
			state.Button.Position = UDim2.new(1, info.Offset.X, 0, info.Offset.Y)
		else
			state.Button.Position = UDim2.new(1, info.Offset.X, 1, info.Offset.Y)
		end
		local size = math.max(Config.Input.MinTouchTarget, info.Size * scale)
		state.Button.Size = UDim2.fromOffset(size, size)
		state.Button.TextSize = math.floor(math.clamp(size * 0.24, 12, 22))
	end
end

local function setPressed(state: ButtonState, pressed: boolean)
	TweenUtil.Play(state.Scale, 0.06, { Scale = if pressed then 0.9 else 1 })
	state.Button.BackgroundColor3 = if pressed then UITheme.Colors.CurrentDeep else UITheme.Colors.HudPanel
end

local function release(state: ButtonState)
	if not state.Input then
		return
	end
	state.Input = nil
	setPressed(state, false)
	local info = state.Info
	if state.HoldThread then
		task.cancel(state.HoldThread)
		state.HoldThread = nil
	end
	if info.HoldAction then
		if state.HoldFired then
			input.EndAction(info.HoldAction)
		else
			-- Short tap: fire the tap action as a full press.
			input.BeginAction(info.TapAction, "Touch")
			input.EndAction(info.TapAction)
		end
	else
		input.EndAction(info.TapAction)
	end
	state.HoldFired = false
end

local function press(state: ButtonState, touch: InputObject)
	if state.Input then
		return
	end
	state.Input = touch
	setPressed(state, true)
	local info = state.Info
	local holdAction = info.HoldAction
	if holdAction then
		state.HoldFired = false
		state.HoldThread = task.delay(Config.Input.HoldThreshold, function()
			state.HoldThread = nil
			if state.Input == touch then
				state.HoldFired = true
				input.BeginAction(holdAction, "Touch")
			end
		end)
	else
		input.BeginAction(info.TapAction, "Touch")
	end
end

local function buildButton(parent: Frame, info: InputConfig.TouchButtonInfo): ButtonState
	local isAttack = info.Id == "Attack"
	local button: TextButton = Create.new("TextButton", {
		Name = info.Id,
		Text = Strings.TouchLabels[info.Id] or info.Id,
		FontFace = UITheme.Fonts.BodyBold,
		TextColor3 = UITheme.Colors.Text,
		BackgroundColor3 = UITheme.Colors.HudPanel,
		BackgroundTransparency = 0.3,
		AutoButtonColor = false,
		Selectable = false,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Parent = parent,
	})
	Create.Corner(button, UITheme.CornerPill)
	local stroke = Create.Stroke(
		button,
		if isAttack or info.Glow then UITheme.Colors.Current else UITheme.Colors.Brass,
		if isAttack then 2.5 else 1.5,
		if isAttack then 0.15 else 0.35
	)
	if info.Glow then
		maid:Add(Animator.Pulse(stroke, "Transparency", 0.05, 0.6, 1.6))
	end
	local scale: UIScale = Create.new("UIScale", { Parent = button })

	local state: ButtonState = {
		Info = info,
		Button = button,
		Scale = scale,
		Input = nil,
		HoldThread = nil,
		HoldFired = false,
	}
	maid:Add(button.InputBegan:Connect(function(touch: InputObject)
		if touch.UserInputType == Enum.UserInputType.Touch and touch.UserInputState == Enum.UserInputState.Begin then
			press(state, touch)
		end
	end))
	return state
end

local function updateVisibility()
	local frame = root
	if not frame then
		return
	end
	local visible = Device.Current() == "Touch" and input.GetContext() == "Gameplay"
	frame.Visible = visible
	if not visible then
		for _, state in states do
			release(state)
		end
	end
end

-- Hides Roblox's default jump button (ours replaces it) whenever it appears.
local function suppressDefaultJump(playerGui: PlayerGui)
	local function hook(object: Instance)
		if object.Name == "JumpButton" and object:IsA("GuiObject") and object:FindFirstAncestor("TouchGui") then
			local button = object :: GuiObject
			button.Visible = false
			maid:Add(button:GetPropertyChangedSignal("Visible"):Connect(function()
				if button.Visible then
					button.Visible = false
				end
			end))
		end
	end
	for _, descendant in playerGui:GetDescendants() do
		hook(descendant)
	end
	maid:Add(playerGui.DescendantAdded:Connect(hook))
end

function TouchControls.Init(api: InputApi)
	input = api
end

function TouchControls.Start()
	local layer = Layers.Get("Touch")
	local frame: Frame = Create.new("Frame", {
		Name = "TouchControls",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		Parent = layer,
	})
	root = frame
	maid:Add(frame)

	local buttons = (Config.Input.TouchButtons :: any) :: { InputConfig.TouchButtonInfo }
	for _, info in buttons do
		states[info.Id] = buildButton(frame, info)
	end
	applyLayout(nil)

	-- Finger lifts anywhere end the press (the finger may slide off the button).
	maid:Add(UserInputService.InputEnded:Connect(function(touch: InputObject)
		if touch.UserInputType ~= Enum.UserInputType.Touch then
			return
		end
		for _, state in states do
			if state.Input == touch then
				release(state)
			end
		end
	end))

	-- The Position ability button only shows once an ability is on the key.
	maid:Add(DataController.Observe({ "Hotbar", "Ability" }, function(ability: any)
		local state = states.Ability
		if state then
			state.Button.Visible = type(ability) == "string" and ability ~= ""
			if not state.Button.Visible then
				release(state)
			end
		end
	end))

	maid:Add(DataController.Observe({ "Settings", "TouchLayout" }, function(layout: any)
		applyLayout(if type(layout) == "table" then layout else nil)
	end))
	maid:Add(Device.Changed:Connect(updateVisibility))
	maid:Add(input.ContextChanged:Connect(updateVisibility))
	updateVisibility()

	if UserInputService.TouchEnabled then
		local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui") :: PlayerGui
		suppressDefaultJump(playerGui)
	end
end

return TouchControls
