--!strict
--[[
	ProgressionController
	Level-ups and progression feedback on the client (Spec Section 9):

	  - LevelUp (server, to everyone nearby): a golden-teal pillar of light
	    rises from the Climber who levelled. For yourself there's also the
	    two-note chime and a "LEVEL n" banner (the toast with the points
	    comes from the server's Notify).
	  - ProgressionResult (server, to you): toasts for stat spending,
	    choosing a Position, learning nodes, the ability key and respecs, and
	    the Result signal the Skill Tree and Character menus listen to.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Strings = require(Shared.Strings)
local Net = require(Shared.Net)
local Signal = require(Shared.Util.Signal)
local Positions = require(Shared.Data.Positions)

local UI = script.Parent.Parent.UI
local UITheme = require(UI.UITheme)
local Create = require(UI.Create)
local Layers = require(UI.Layers)
local UISound = require(UI.UISound)
local Components = require(UI.Components)
local ProgressionText = require(UI.ProgressionText)

local DataController = require(script.Parent.DataController)
local InputController = require(script.Parent.InputController)

local player = Players.LocalPlayer

local ProgressionController = {}

-- (ok, action, reason, payload) for menus that want to react to a result.
ProgressionController.Result = Signal.new() :: Signal.Signal<boolean, string, string, { [string]: any }>

local GOLD = Color3.fromHex("#F2C661")
local TEAL = Color3.fromHex("#5FE0D0")

local function effectsFolder(): Instance
	local existing = Workspace:FindFirstChild("SpellFX")
	if existing then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = "SpellFX"
	folder.Parent = Workspace
	return folder
end

local function neon(shape: Enum.PartType, size: Vector3, cframe: CFrame, color: Color3, transparency: number): Part
	local p = Instance.new("Part")
	p.Shape = shape
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.Color = color
	p.Size = size
	p.CFrame = cframe
	p.Transparency = transparency
	p.Parent = effectsFolder()
	return p
end

local function fadeOut(p: BasePart, time: number, goal: { [string]: any }?)
	local properties: { [string]: any } = goal or {}
	properties.Transparency = 1
	local tween = TweenService:Create(p, TweenInfo.new(time, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), properties)
	tween:Play()
	tween.Completed:Once(function()
		p:Destroy()
	end)
end

-- The golden-teal pillar: a gold column with a teal core, rings climbing it.
local function pillar(character: Model)
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return
	end
	local feet = root.Position - Vector3.new(0, 3, 0)
	local height = 26
	-- Mostly see-through so it never hides the fight around you.
	local column = neon(Enum.PartType.Cylinder, Vector3.new(height, 4.5, 4.5), CFrame.new(feet + Vector3.new(0, height / 2, 0)) * CFrame.Angles(0, 0, math.rad(90)), GOLD, 0.78)
	local core = neon(Enum.PartType.Cylinder, Vector3.new(height, 1.2, 1.2), column.CFrame, TEAL, 0.45)
	local light = Instance.new("PointLight")
	light.Color = GOLD
	light.Range = 22
	light.Brightness = 3
	light.Parent = core
	TweenService:Create(column, TweenInfo.new(0.3, Enum.EasingStyle.Back), { Size = Vector3.new(height, 6, 6) }):Play()
	task.delay(0.9, function()
		fadeOut(column, 0.8, { Size = Vector3.new(height, 0.5, 0.5) })
		fadeOut(core, 0.8, { Size = Vector3.new(height, 0.2, 0.2) })
	end)
	for index = 0, 3 do
		task.delay(index * 0.18, function()
			local ring = neon(Enum.PartType.Cylinder, Vector3.new(0.3, 7, 7), CFrame.new(feet + Vector3.new(0, 0.3, 0)) * CFrame.Angles(0, 0, math.rad(90)), if index % 2 == 0 then TEAL else GOLD, 0.2)
			fadeOut(ring, 1.1, { CFrame = ring.CFrame + Vector3.new(0, height * 0.8, 0), Size = Vector3.new(0.3, 3, 3) })
		end)
	end
	-- Ground flash.
	local flash = neon(Enum.PartType.Cylinder, Vector3.new(0.2, 2, 2), CFrame.new(feet + Vector3.new(0, 0.2, 0)) * CFrame.Angles(0, 0, math.rad(90)), GOLD, 0.1)
	fadeOut(flash, 0.7, { Size = Vector3.new(0.2, 16, 16) })
end

-- Your own level-up: "LEVEL n" across the screen and the chime.
local function banner(level: number)
	UISound.Play("LevelUp")
	task.delay(0.14, function()
		UISound.Play("LevelUpHigh")
	end)
	local layer = Layers.Get("Overlay")
	local label: TextLabel = Create.new("TextLabel", {
		Name = "LevelUpBanner",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.26),
		Size = UDim2.fromOffset(600, 70),
		BackgroundTransparency = 1,
		FontFace = UITheme.Fonts.Display,
		TextSize = 52,
		-- White, so the gold-to-teal gradient below shows its true colours
		-- (a UIGradient multiplies with TextColor3).
		TextColor3 = Color3.new(1, 1, 1),
		TextStrokeTransparency = 0.25,
		TextStrokeColor3 = UITheme.Colors.Overlay,
		Text = Strings.Format(Strings.Inventory.Sheet.Level, { level = level }),
		ZIndex = 40,
		Parent = layer,
	})
	Create.new("UIGradient", {
		Color = ColorSequence.new(GOLD, TEAL),
		Rotation = 90,
		Parent = label,
	})
	local scale: UIScale = Create.new("UIScale", { Scale = 1.5, Parent = label })
	TweenService:Create(scale, TweenInfo.new(0.35, Enum.EasingStyle.Back), { Scale = 1 }):Play()
	task.delay(1.8, function()
		local tween = TweenService:Create(label, TweenInfo.new(0.4), { TextTransparency = 1, TextStrokeTransparency = 1 })
		tween:Play()
		tween.Completed:Once(function()
			label:Destroy()
		end)
	end)
end

local function onLevelUp(character: Model, level: number)
	if typeof(character) ~= "Instance" or not character:IsA("Model") or type(level) ~= "number" then
		return
	end
	pillar(character)
	if character == player.Character then
		banner(level)
	end
end

-- RESULTS -----------------------------------------------------------------------------

local function toast(text: string, color: Color3, key: string?)
	Components.Toast.Push({ Title = text, Color = color, Key = key })
end

local function onResult(ok: boolean, action: string, reason: string, payload: { [string]: any })
	if type(action) ~= "string" then
		return
	end
	payload = if type(payload) == "table" then payload else {}
	if not ok then
		local template = Strings.Progression.Reasons[reason] or Strings.Progression.Reasons.Invalid
		toast(Strings.Format(template, { level = Config.Progression.Positions.UnlockLevel }), UITheme.Colors.Danger, `Progression{reason}`)
		UISound.Play("UIError")
	elseif action == "Stats" then
		toast(Strings.Toasts.StatsSpent, UITheme.Colors.Heal, "StatsSpent")
		UISound.Play("UIConfirm")
	elseif action == "Choose" then
		local id = payload.Position
		local def = if type(id) == "string" then Positions.Get(id) else nil
		toast(Strings.Format(Strings.Toasts.PositionChosen, {
			name = if type(id) == "string" then ProgressionText.PositionName(id) else "",
			key = InputController.GetPrompt("OpenSkillTree"),
		}), if def then def.Color else UITheme.Colors.Current, "PositionChosen")
		UISound.Play("LevelUp")
	elseif action == "Unlock" then
		local node = if type(payload.Node) == "string" then Positions.Node(payload.Node) else nil
		if node then
			toast(Strings.Format(Strings.Toasts.NodeUnlocked, { name = ProgressionText.NodeName(node) }), UITheme.Colors.Current, "NodeUnlocked")
		end
		UISound.Play("SkillUnlock")
	elseif action == "Equip" then
		local id = payload.Ability
		if type(id) == "string" and id ~= "" then
			toast(Strings.Format(Strings.Toasts.AbilityEquipped, { name = ProgressionText.AbilityName(id) }), UITheme.Colors.Current, "AbilityEquipped")
		end
		UISound.Play("UIConfirm")
	elseif action == "Respec" then
		toast(Strings.Toasts.Respecced, UITheme.Colors.Current, "Respecced")
		UISound.Play("UIConfirm")
	end
	ProgressionController.Result:Fire(ok, action, reason, payload)
end

-- Unspent points (for the Character and Skill Tree menus' badges).
function ProgressionController.UnspentStatPoints(): number
	local value = DataController.Get({ "StatPoints" })
	return if type(value) == "number" then value else 0
end

function ProgressionController.UnspentSkillPoints(): number
	local value = DataController.Get({ "SkillPoints" })
	return if type(value) == "number" then value else 0
end

function ProgressionController.Init()
	Net.OnClient("LevelUp", onLevelUp)
	Net.OnClient("ProgressionResult", onResult)
end

return ProgressionController
