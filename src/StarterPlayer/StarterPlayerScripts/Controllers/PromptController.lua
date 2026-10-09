--!strict
-- PromptController: themed interaction prompts for every Custom-style
-- ProximityPrompt. Small rounded dark-glass pills showing the right key or
-- button for the player's current input device (keyboard, gamepad, touch),
-- a hold-progress ring for hold prompts, and tap-to-use on touch screens.

local ProximityPromptService = game:GetService("ProximityPromptService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Theme = require(Shared.UI.Theme)
local Maid = require(Shared.Util.Maid)

local PromptController = {}

local gui: Folder

type Device = string -- "Keyboard" | "Gamepad" | "Touch"

local function device(): Device
	local last = UserInputService:GetLastInputType()
	if last == Enum.UserInputType.Touch then
		return "Touch"
	end
	if string.find(last.Name, "Gamepad") then
		return "Gamepad"
	end
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		return "Touch"
	end
	return "Keyboard"
end

local GAMEPAD_LABELS: { [string]: string } = {
	ButtonX = "X",
	ButtonY = "Y",
	ButtonA = "A",
	ButtonB = "B",
}

local function keyLabel(prompt: ProximityPrompt, d: Device): string
	if d == "Gamepad" then
		return GAMEPAD_LABELS[prompt.GamepadKeyCode.Name] or prompt.GamepadKeyCode.Name
	elseif d == "Touch" then
		return "TAP"
	end
	local name = prompt.KeyboardKeyCode.Name
	return if #name == 1 then name else string.upper(string.sub(name, 1, 3))
end

local function build(prompt: ProximityPrompt, maid: Maid.Maid)
	local d = device()
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "Prompt"
	billboard.AlwaysOnTop = true
	billboard.Size = UDim2.fromOffset(240, 64)
	billboard.SizeOffset = Vector2.new(0, 0.6)
	billboard.LightInfluence = 0
	billboard.Active = true
	billboard.Adornee = prompt.Parent :: Instance
	billboard.ResetOnSpawn = false
	billboard.Parent = gui
	maid:Give(billboard)

	local frame = Instance.new("TextButton")
	frame.Name = "Pill"
	frame.Text = ""
	frame.AutoButtonColor = false
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.5)
	frame.Size = UDim2.new(0, 0, 0, 48)
	frame.AutomaticSize = Enum.AutomaticSize.X
	frame.BackgroundColor3 = Theme.Colors.Background
	frame.BackgroundTransparency = Theme.Colors.BackgroundTransparency
	frame.Parent = billboard
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 24)
	corner.Parent = frame
	local stroke = Instance.new("UIStroke")
	stroke.Color = Theme.Colors.Border
	stroke.Thickness = Theme.Stroke
	stroke.Transparency = Theme.Colors.BorderTransparency
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = frame
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 6)
	pad.PaddingRight = UDim.new(0, 16)
	pad.Parent = frame
	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Horizontal
	list.VerticalAlignment = Enum.VerticalAlignment.Center
	list.Padding = UDim.new(0, 10)
	list.Parent = frame
	local scale = Instance.new("UIScale")
	scale.Scale = 0.8
	scale.Parent = frame

	-- key badge with hold ring
	local key = Instance.new("Frame")
	key.Name = "Key"
	key.Size = UDim2.fromOffset(38, 38)
	key.BackgroundColor3 = Theme.Colors.Surface
	key.Parent = frame
	local kc = Instance.new("UICorner")
	kc.CornerRadius = UDim.new(1, 0)
	kc.Parent = key
	local ring = Instance.new("UIStroke")
	ring.Thickness = 3
	ring.Color = Theme.Colors.Current
	ring.Transparency = 0.2
	ring.Parent = key
	local ringGrad = Instance.new("UIGradient")
	ringGrad.Rotation = -90
	ringGrad.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.001, 1),
		NumberSequenceKeypoint.new(1, 1),
	})
	ringGrad.Parent = ring
	local keyText = Instance.new("TextLabel")
	keyText.BackgroundTransparency = 1
	keyText.Size = UDim2.fromScale(1, 1)
	keyText.FontFace = Theme.Fonts.BodyBold
	keyText.TextSize = if d == "Touch" then 11 else Theme.TextSize.Key
	keyText.TextColor3 = Theme.Colors.Text
	keyText.Text = keyLabel(prompt, d)
	keyText.Parent = key

	local texts = Instance.new("Frame")
	texts.BackgroundTransparency = 1
	texts.AutomaticSize = Enum.AutomaticSize.X
	texts.Size = UDim2.fromOffset(0, 40)
	texts.Parent = frame
	local tl = Instance.new("UIListLayout")
	tl.VerticalAlignment = Enum.VerticalAlignment.Center
	tl.Parent = texts
	local object = Instance.new("TextLabel")
	object.BackgroundTransparency = 1
	object.AutomaticSize = Enum.AutomaticSize.X
	object.Size = UDim2.fromOffset(0, 16)
	object.FontFace = Theme.Fonts.Body
	object.TextSize = Theme.TextSize.Small
	object.TextColor3 = Theme.Colors.TextDim
	object.Text = prompt.ObjectText
	object.Visible = prompt.ObjectText ~= ""
	object.Parent = texts
	local action = Instance.new("TextLabel")
	action.BackgroundTransparency = 1
	action.AutomaticSize = Enum.AutomaticSize.X
	action.Size = UDim2.fromOffset(0, 22)
	action.FontFace = Theme.Fonts.BodyBold
	action.TextSize = Theme.TextSize.Heading
	action.TextColor3 = Theme.Colors.Text
	action.Text = prompt.ActionText
	action.Parent = texts

	TweenService:Create(scale, Theme.Tween.Open, { Scale = 1 }):Play()

	-- hold progress
	local progress = Instance.new("NumberValue")
	maid:Give(progress)
	maid:Give(progress.Changed:Connect(function(v: number)
		local t = math.clamp(v, 0.001, 0.999)
		ringGrad.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(t, 0),
			NumberSequenceKeypoint.new(math.min(t + 0.001, 1), 1),
			NumberSequenceKeypoint.new(1, 1),
		})
	end))
	local holdTween: Tween? = nil
	maid:Give(prompt.PromptButtonHoldBegan:Connect(function()
		if prompt.HoldDuration > 0 then
			local tween = TweenService:Create(progress, TweenInfo.new(prompt.HoldDuration, Enum.EasingStyle.Linear), { Value = 1 })
			holdTween = tween
			tween:Play()
		end
	end))
	maid:Give(prompt.PromptButtonHoldEnded:Connect(function()
		if holdTween then
			(holdTween :: Tween):Cancel()
		end
		progress.Value = 0
	end))
	maid:Give(prompt.Triggered:Connect(function()
		TweenService:Create(scale, TweenInfo.new(0.08), { Scale = 0.92 }):Play()
		task.delay(0.08, function()
			TweenService:Create(scale, TweenInfo.new(0.12), { Scale = 1 }):Play()
		end)
	end))

	-- touch: press and hold the pill itself
	maid:Give(frame.InputBegan:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
			prompt:InputHoldBegin()
		end
	end))
	maid:Give(frame.InputEnded:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
			prompt:InputHoldEnd()
		end
	end))
	maid:Give(UserInputService.LastInputTypeChanged:Connect(function()
		local nd = device()
		keyText.Text = keyLabel(prompt, nd)
		keyText.TextSize = if nd == "Touch" then 11 else Theme.TextSize.Key
	end))
	maid:Give(prompt:GetPropertyChangedSignal("ActionText"):Connect(function()
		action.Text = prompt.ActionText
	end))
end

function PromptController.Init()
	-- BillboardGuis render from any folder under PlayerGui
	local g = Instance.new("Folder")
	g.Name = "Prompts"
	g.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	gui = g
end

function PromptController.Start()
	ProximityPromptService.PromptShown:Connect(function(prompt: ProximityPrompt, inputType: Enum.ProximityPromptInputType)
		if prompt.Style ~= Enum.ProximityPromptStyle.Custom then
			return
		end
		local maid = Maid.new()
		build(prompt, maid)
		prompt.PromptHidden:Once(function()
			maid:Clean()
		end)
	end)
end

return PromptController
