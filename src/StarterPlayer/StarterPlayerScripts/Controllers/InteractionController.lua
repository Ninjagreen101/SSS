--!strict
--[[
	InteractionController
	Draws every ProximityPrompt that uses Style = Custom (Waystones now;
	NPCs, chests and doors later) in The Spire's look, and drives them from
	the Interact action so rebinding works:

	- Key badge shows the player's current Interact binding ("E", "X"), or
	  "TAP" on touch. Changes live when the device or bindings change.
	- A ring around the badge fills while the prompt is being held.
	- Input: Roblox's own key handling is switched off on our side
	  (KeyboardKeyCode = Unknown) and the Interact action calls
	  InputHoldBegin/End on the nearest visible prompt instead. On touch the
	  prompt itself is tappable, as is the Interact button.
	The server still owns what happens on Triggered and checks distance.
]]

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Strings = require(Shared.Strings)
local Maid = require(Shared.Util.Maid)
local TweenUtil = require(Shared.Util.TweenUtil)

local UI = script.Parent.Parent.UI
local UITheme = require(UI.UITheme)
local Create = require(UI.Create)
local Device = require(UI.Device)
local UISound = require(UI.UISound)
local Components = require(UI.Components)

local InputController = require(script.Parent.InputController)

local P = UITheme.Prompt
local player = Players.LocalPlayer

local InteractionController = {}

type Shown = {
	Prompt: ProximityPrompt,
	Maid: Maid.Maid,
	KeyLabel: TextLabel,
	Ring: Components.RadialProgress,
	Holding: boolean,
}

local shown: { [ProximityPrompt]: Shown } = {}
local activePrompt: ProximityPrompt? = nil -- the prompt the held Interact is driving

local function keyText(): string
	if Device.IsTouch() then
		return Strings.Prompts.Tap
	end
	return InputController.GetPrompt("Interact")
end

local function promptPosition(prompt: ProximityPrompt): Vector3?
	local parent = prompt.Parent
	if parent and parent:IsA("BasePart") then
		return parent.Position
	elseif parent and parent:IsA("Attachment") then
		return parent.WorldPosition
	elseif parent and parent:IsA("Model") then
		return parent:GetPivot().Position
	end
	return nil
end

local function nearestPrompt(): ProximityPrompt?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return nil
	end
	local best: ProximityPrompt? = nil
	local bestDistance = math.huge
	for prompt in shown do
		local position = promptPosition(prompt)
		if position and prompt.Enabled then
			local distance = (position - root.Position).Magnitude
			if distance < bestDistance then
				best = prompt
				bestDistance = distance
			end
		end
	end
	return best
end

local function beginHold(prompt: ProximityPrompt)
	activePrompt = prompt
	prompt:InputHoldBegin()
end

local function endHold()
	local prompt = activePrompt
	activePrompt = nil
	if prompt then
		prompt:InputHoldEnd()
	end
end

local function build(prompt: ProximityPrompt)
	local adornee = prompt.Parent
	if not adornee or not (adornee:IsA("BasePart") or adornee:IsA("Attachment") or adornee:IsA("Model")) then
		return
	end
	-- Our own input drives the prompt (see header).
	-- (KeyCode.Unknown exists at runtime but is missing from the type definitions.)
	local unknown = (Enum.KeyCode :: any).Unknown
	prompt.KeyboardKeyCode = unknown
	prompt.GamepadKeyCode = unknown

	local maid = Maid.new()
	local billboard: BillboardGui = Create.new("BillboardGui", {
		Name = "SpirePrompt",
		Adornee = adornee,
		AlwaysOnTop = true,
		Active = true,
		ResetOnSpawn = false,
		LightInfluence = 0,
		MaxDistance = P.MaxDistance,
		Size = UDim2.fromOffset(P.Size.X, P.Size.Y),
		StudsOffsetWorldSpace = P.StudsOffset,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	})
	maid:Add(billboard)

	-- The whole prompt is a button so touch players can tap it.
	local frame: TextButton = Create.new("TextButton", {
		Name = "Prompt",
		Text = "",
		AutoButtonColor = false,
		Size = UDim2.fromScale(1, 1),
		Parent = billboard,
	})
	Create.ApplyPanelStyle(frame, { Glow = true })
	local scale: UIScale = Create.new("UIScale", { Scale = 0.85, Parent = frame })
	TweenUtil.Play(scale, UITheme.Motion.OpenTime, { Scale = 1 }, Enum.EasingStyle.Back)

	local keyHolder: Frame = Create.new("Frame", {
		Name = "Key",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 12, 0.5, 0),
		Size = UDim2.fromOffset(P.KeySize, P.KeySize),
		BackgroundColor3 = UITheme.Colors.PanelSunken,
		Parent = frame,
	})
	Create.Corner(keyHolder, UITheme.CornerPill)
	local keyLabel = Create.Label({
		Name = "KeyText",
		Text = keyText(),
		Font = UITheme.Fonts.BodyBold,
		TextSize = UITheme.TextSize.Small,
		XAlignment = Enum.TextXAlignment.Center,
		Size = UDim2.fromScale(1, 1),
		Parent = keyHolder,
	})
	keyLabel.ZIndex = 3
	local ring = Components.RadialProgress.new({
		Name = "Hold",
		Color = UITheme.Colors.Current,
		TrackColor = UITheme.Colors.Brass,
		TrackTransparency = 0.5,
		Thickness = 3,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 2,
		Parent = keyHolder,
	})
	maid:Add(function()
		ring:Destroy()
	end)

	local textX = 12 + P.KeySize + 10
	Create.Label({
		Name = "Action",
		Text = prompt.ActionText,
		Font = UITheme.Fonts.BodyBold,
		TextSize = UITheme.TextSize.BodyLarge,
		Position = UDim2.new(0, textX, 0.5, -1),
		AnchorPoint = Vector2.new(0, 1),
		Size = UDim2.new(1, -textX - 10, 0, 22),
		Parent = frame,
	})
	Create.Label({
		Name = "Object",
		Text = prompt.ObjectText,
		Font = UITheme.Fonts.Body,
		TextSize = UITheme.TextSize.Small,
		Color = UITheme.Colors.TextMuted,
		Position = UDim2.new(0, textX, 0.5, 1),
		Size = UDim2.new(1, -textX - 10, 0, 18),
		Parent = frame,
	})

	local entry: Shown = { Prompt = prompt, Maid = maid, KeyLabel = keyLabel, Ring = ring, Holding = false }
	shown[prompt] = entry

	-- Touch: hold the prompt itself.
	maid:Add(frame.InputBegan:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
			beginHold(prompt)
		end
	end))
	maid:Add(frame.InputEnded:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
			if activePrompt == prompt then
				endHold()
			end
		end
	end))

	billboard.Parent = player:WaitForChild("PlayerGui")
end

local function remove(prompt: ProximityPrompt)
	local entry = shown[prompt]
	if entry then
		shown[prompt] = nil
		entry.Maid:Clean()
	end
	if activePrompt == prompt then
		endHold()
	end
end

local function refreshKeys()
	local text = keyText()
	for _, entry in shown do
		entry.KeyLabel.Text = text
	end
end

function InteractionController.Init()
	InputController.ActionBegan:Connect(function(action: string)
		if action == "Interact" then
			local prompt = nearestPrompt()
			if prompt then
				beginHold(prompt)
			end
		end
	end)
	InputController.ActionEnded:Connect(function(action: string)
		if action == "Interact" then
			endHold()
		end
	end)
	InputController.BindingsChanged:Connect(refreshKeys)
	Device.Changed:Connect(refreshKeys)
end

function InteractionController.Start()
	ProximityPromptService.PromptShown:Connect(function(prompt: ProximityPrompt)
		if prompt.Style == Enum.ProximityPromptStyle.Custom and not shown[prompt] then
			build(prompt)
		end
	end)
	ProximityPromptService.PromptHidden:Connect(remove)
	ProximityPromptService.PromptButtonHoldBegan:Connect(function(prompt: ProximityPrompt)
		local entry = shown[prompt]
		if entry then
			entry.Holding = true
			entry.Ring:SetValue(0)
			entry.Ring:SetValue(1, prompt.HoldDuration)
		end
	end)
	ProximityPromptService.PromptButtonHoldEnded:Connect(function(prompt: ProximityPrompt)
		local entry = shown[prompt]
		if entry then
			entry.Holding = false
			entry.Ring:SetValue(0, 0.12)
		end
	end)
	ProximityPromptService.PromptTriggered:Connect(function(prompt: ProximityPrompt)
		local entry = shown[prompt]
		if entry then
			UISound.Play("UIConfirm")
			entry.Ring:SetValue(0, 0.25)
		end
	end)
end

return InteractionController
