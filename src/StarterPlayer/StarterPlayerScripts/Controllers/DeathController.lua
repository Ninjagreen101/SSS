--!strict
--[[
	DeathController
	What the player sees when they fall:
	  1. The world drains of colour and blurs; local animations slow down.
	  2. "Your Current fades" rises over the ragdoll.
	  3. The Respawn button unlocks when the server's RespawnAt time passes
	     (counting down until then). Pressing it asks the server to respawn
	     us at our last rested Waystone; the server re-checks everything.
	Everything is undone when the new character arrives.
]]

local GuiService = game:GetService("GuiService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Strings = require(Shared.Strings)
local Attributes = require(Shared.Attributes)
local Net = require(Shared.Net)
local Maid = require(Shared.Util.Maid)
local TweenUtil = require(Shared.Util.TweenUtil)

local UI = script.Parent.Parent.UI
local UITheme = require(UI.UITheme)
local Create = require(UI.Create)
local Layers = require(UI.Layers)
local Blur = require(UI.Blur)
local Device = require(UI.Device)
local Components = require(UI.Components)

local A = Attributes.Names
local D = UITheme.Death
local player = Players.LocalPlayer

local DeathController = {}

local maid = Maid.new()

local function slowAnimations(humanoid: Humanoid)
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if animator then
		for _, track in animator:GetPlayingAnimationTracks() do
			track:AdjustSpeed(D.AnimationSpeed)
		end
	end
end

local function desaturate()
	local effect = Instance.new("ColorCorrectionEffect")
	effect.Name = "SpireDeath"
	effect.Parent = Lighting
	maid:Add(effect)
	TweenUtil.Play(effect, D.FadeTime, { Saturation = D.Saturation, Contrast = D.Contrast, TintColor = D.Tint })
	maid:Add(Blur.Push())
end

local function showScreen()
	local layer = Layers.Get("Overlay")
	local screen: Frame = Create.new("Frame", {
		Name = "DeathScreen",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = layer,
	})
	maid:Add(screen)

	-- Dark band behind the text so it reads over any scene.
	local band: Frame = Create.new("Frame", {
		Name = "Band",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, 0, 0, 220),
		BackgroundColor3 = UITheme.Colors.Overlay,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Parent = screen,
	})
	Create.new("UIGradient", {
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.5, 0.35),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Rotation = 90,
		Parent = band,
	})

	local title = Create.Label({
		Name = "Title",
		Text = Strings.Death.Title,
		Font = UITheme.Fonts.Display,
		TextSize = UITheme.TextSize.Hero,
		Color = UITheme.Colors.Text,
		XAlignment = Enum.TextXAlignment.Center,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 0.5, -6),
		Size = UDim2.new(1, -40, 0, 56),
		Parent = screen,
	})
	title.TextTransparency = 1
	local subtitle = Create.Label({
		Name = "Subtitle",
		Text = Strings.Death.Subtitle,
		Font = UITheme.Fonts.DisplayRegular,
		TextSize = UITheme.TextSize.BodyLarge,
		Color = UITheme.Colors.TextMuted,
		XAlignment = Enum.TextXAlignment.Center,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0.5, 4),
		Size = UDim2.new(1, -40, 0, 26),
		Parent = screen,
	})
	subtitle.TextTransparency = 1

	local button = Components.Button.new({
		Name = "Respawn",
		Text = Strings.Death.Respawn,
		Variant = "Primary",
		Enabled = false,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0.5, 52),
		Size = UDim2.fromOffset(260, if Device.IsTouch() then UITheme.Size.ButtonHeightTouch else UITheme.Size.ButtonHeight),
		Parent = screen,
	})
	maid:Add(function()
		button:Destroy()
	end)
	button.Instance.Visible = false

	local requested = false
	button.Activated:Connect(function()
		if requested or not button:IsEnabled() then
			return
		end
		requested = true
		button:SetEnabled(false)
		Net.FireServer("RequestRespawn")
		-- If the server refused (too early, lag), allow another try shortly.
		task.delay(1, function()
			requested = false
		end)
	end)

	-- Reveal the text after a beat, then count down to the respawn unlock.
	maid:Add(task.delay(D.RevealDelay, function()
		TweenUtil.Play(band, D.FadeTime, { BackgroundTransparency = 0 })
		TweenUtil.Play(title, D.FadeTime, { TextTransparency = 0 })
		TweenUtil.Play(subtitle, D.FadeTime, { TextTransparency = 0 })
		button.Instance.Visible = true
	end))

	local unlocked = false
	maid:Add(RunService.Heartbeat:Connect(function()
		if requested then
			return
		end
		local respawnAt = player:GetAttribute(A.RespawnAt)
		local remaining = if type(respawnAt) == "number" then respawnAt - Workspace:GetServerTimeNow() else 0
		if remaining > 0 then
			button:SetText(Strings.Format(Strings.Death.RespawnIn, { seconds = math.ceil(remaining) }))
			if unlocked then
				unlocked = false
				button:SetEnabled(false)
			end
		elseif not unlocked then
			unlocked = true
			button:SetText(Strings.Death.Respawn)
			button:SetEnabled(true)
			if Device.IsGamepad() then
				GuiService.SelectedObject = button.Instance
			end
		elseif not button:IsEnabled() then
			button:SetEnabled(true)
		end
	end))
end

local function onDied(humanoid: Humanoid)
	maid:Clean()
	slowAnimations(humanoid)
	desaturate()
	showScreen()
end

local function bindCharacter(character: Model)
	maid:Clean()
	if GuiService.SelectedObject and not GuiService.SelectedObject:IsDescendantOf(game) then
		GuiService.SelectedObject = nil
	end
	local humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid?
	if humanoid then
		humanoid.Died:Connect(function()
			onDied(humanoid)
		end)
	end
end

function DeathController.Start()
	player.CharacterAdded:Connect(bindCharacter)
	if player.Character then
		task.spawn(bindCharacter, player.Character)
	end
end

return DeathController
