--!strict
--[[
	CombatFeedbackController
	Everything that makes hits *feel* like hits (Spec Section 13). Purely
	visual; the server already decided what happened.

	- Damage numbers float up from targets (Settings > Damage Numbers).
	  Labels replace numbers for PARRY, DODGE, BROKEN, ABSORBED and
	  friends. Spell and Confluence numbers wear their Attunement's colour;
	  Reactions show their name (SURGE, SHATTER, CRUSH) in the Reaction tint.
	- Hit flash: a brief white highlight on whatever was hit.
	- Hit stop: when *your* blow lands, your animations freeze for a few
	  frames (longer for heavies, ripostes and finishers).
	- Camera shake on hits you deal and take (scaled by Settings, off with
	  Reduced Motion).
	- Perfect dodge: the world's animations around you slow briefly and
	  the colours dip.
	- Slash arcs: a quick glowing arc shows every swing, yours and other
	  players', so combat reads clearly even before real animations exist.
]]

local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Attributes = require(Shared.Attributes)
local Strings = require(Shared.Strings)
local Net = require(Shared.Net)
local TweenUtil = require(Shared.Util.TweenUtil)
local Spells = require(Shared.Data.Spells)

local UI = script.Parent.Parent.UI
local UITheme = require(UI.UITheme)
local Create = require(UI.Create)

local DataController = require(script.Parent.DataController)
local CameraController = require(script.Parent.CameraController)

local C = Config.Combat
local T = UITheme.CombatText
local player = Players.LocalPlayer

local CombatFeedbackController = {}

type Number = { Attachment: Attachment, Gui: BillboardGui, Label: TextLabel, Shown: number }

local pool: { Number } = {}
local nextIndex = 0
local vfxFolder: Folder? = nil

local LABELS: { [string]: string } = {
	Parry = Strings.Combat.Parry,
	Blocked = Strings.Combat.Blocked,
	GuardBreak = Strings.Combat.GuardBreak,
	Dodge = Strings.Combat.Dodge,
	PerfectDodge = Strings.Combat.PerfectDodge,
	Broken = Strings.Combat.Broken,
	Absorbed = Strings.Combat.Absorbed,
}

local function getFolder(): Folder
	local folder = vfxFolder
	if folder and folder.Parent then
		return folder
	end
	local created = Instance.new("Folder")
	created.Name = "SpireVFX"
	created.Parent = Workspace
	vfxFolder = created
	return created
end

-- DAMAGE NUMBERS --------------------------------------------------------------

local function takeNumber(): Number
	if #pool < T.MaxActive then
		local attachment = Instance.new("Attachment")
		attachment.Name = "CombatText"
		attachment.Parent = Workspace.Terrain
		local gui: BillboardGui = Create.new("BillboardGui", {
			Name = "CombatText",
			Adornee = attachment,
			AlwaysOnTop = true,
			LightInfluence = 0,
			Size = UDim2.fromOffset(220, 50),
			MaxDistance = C.FeedbackRadius,
			ResetOnSpawn = false,
			Enabled = false,
			Parent = player:WaitForChild("PlayerGui"),
		})
		local label = Create.Label({
			Name = "Text",
			Text = "",
			Font = UITheme.Fonts.Numbers,
			TextSize = T.TextSize,
			XAlignment = Enum.TextXAlignment.Center,
			Size = UDim2.fromScale(1, 1),
			Parent = gui,
		})
		label.TextStrokeTransparency = 0.3
		local entry: Number = { Attachment = attachment, Gui = gui, Label = label, Shown = 0 }
		table.insert(pool, entry)
		return entry
	end
	-- Pool full: reuse the oldest.
	nextIndex = nextIndex % #pool + 1
	return pool[nextIndex]
end

local function showText(position: Vector3, text: string, color: Color3, size: number)
	local entry = takeNumber()
	local spread = T.Spread
	local start = position + Vector3.new((math.random() * 2 - 1) * spread, 1.5, (math.random() * 2 - 1) * spread)
	entry.Attachment.WorldPosition = start
	entry.Label.Text = text
	entry.Label.TextColor3 = color
	entry.Label.TextSize = size
	entry.Label.TextTransparency = 0
	entry.Label.TextStrokeTransparency = 0.3
	entry.Gui.Enabled = true
	entry.Shown += 1
	local shown = entry.Shown
	TweenUtil.Play(entry.Attachment, T.Duration, { WorldPosition = start + Vector3.new(0, T.Rise, 0) }, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenUtil.Play(entry.Label, T.Duration, { TextTransparency = 1, TextStrokeTransparency = 1 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	task.delay(T.Duration, function()
		-- Only hide it if it wasn't reused for a newer number meanwhile.
		if entry.Shown == shown then
			entry.Gui.Enabled = false
		end
	end)
end

-- EFFECTS ---------------------------------------------------------------------

local function flash(model: Model)
	if model == player.Character then
		return
	end
	local highlight = Instance.new("Highlight")
	highlight.FillColor = Color3.new(1, 1, 1)
	highlight.FillTransparency = 0.35
	highlight.OutlineTransparency = 1
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.Parent = model
	task.delay(Config.Mobs.Visual.HitFlashDuration, function()
		highlight:Destroy()
	end)
end

local function playingTracks(model: Model): { AnimationTrack }
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	return if animator then animator:GetPlayingAnimationTracks() else {}
end

-- Freezes a model's animations for `duration` (hit stop), then restores them.
local function freeze(model: Model, duration: number, scale: number)
	local tracks = playingTracks(model)
	local speeds: { [AnimationTrack]: number } = {}
	for _, track in tracks do
		speeds[track] = track.Speed
		track:AdjustSpeed(track.Speed * scale)
	end
	task.delay(duration, function()
		for track, speed in speeds do
			if track.IsPlaying then
				track:AdjustSpeed(speed)
			end
		end
	end)
end

local function reducedMotion(): boolean
	return DataController.GetSetting("ReducedMotion") == true
end

local function perfectDodge()
	local duration = C.Dodge.PerfectSlowDuration
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if root then
		for _, model in CollectionService:GetTagged(Attributes.Tags.CombatTarget) do
			local otherRoot = model:FindFirstChild("HumanoidRootPart")
			if model ~= character and model:IsA("Model") and otherRoot and otherRoot:IsA("BasePart")
				and (otherRoot.Position - root.Position).Magnitude <= C.FeedbackRadius / 3 then
				freeze(model, duration, C.Dodge.PerfectSlowTimeScale)
			end
		end
	end
	if reducedMotion() then
		return
	end
	local effect = Instance.new("ColorCorrectionEffect")
	effect.Name = "SpirePerfectDodge"
	effect.Saturation = -0.45
	effect.TintColor = UITheme.Colors.Current:Lerp(Color3.new(1, 1, 1), 0.7)
	effect.Parent = Lighting
	TweenUtil.Play(effect, duration, { Saturation = 0, TintColor = Color3.new(1, 1, 1) }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	task.delay(duration, function()
		effect:Destroy()
	end)
end

local function spark(position: Vector3, color: Color3)
	local ball = Instance.new("Part")
	ball.Shape = Enum.PartType.Ball
	ball.Material = Enum.Material.Neon
	ball.Color = color
	ball.Size = Vector3.one * 0.6
	ball.Anchored = true
	ball.CanCollide = false
	ball.CanQuery = false
	ball.CanTouch = false
	ball.CastShadow = false
	ball.Position = position + Vector3.new(0, 1.5, 0)
	ball.Parent = getFolder()
	TweenUtil.Play(ball, 0.18, { Size = Vector3.one * 3, Transparency = 1 }, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	task.delay(0.2, function()
		ball:Destroy()
	end)
end

-- PUBLIC API ------------------------------------------------------------------

-- Draws a quick glowing arc in front of `model` along `aim`.
function CombatFeedbackController.DrawSlash(model: Model, aim: Vector3, reach: number, arc: number, kind: string)
	local root = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
	if not root or not root:IsA("BasePart") then
		return
	end
	local S = UITheme.Slash
	local flatAim = Vector3.new(aim.X, 0, aim.Z)
	if flatAim.Magnitude < 0.01 then
		return
	end
	flatAim = flatAim.Unit
	local color = if kind == "Riposte" then UITheme.Colors.Parry
		elseif kind == "Npc" then UITheme.Colors.Danger
		elseif kind == "Charged" then UITheme.Colors.Current
		else UITheme.Colors.Text:Lerp(UITheme.Colors.Current, 0.35)
	local thickness = if kind == "Heavy" or kind == "Charged" then S.Thickness * 1.8 else S.Thickness
	local radius = math.max(2.5, reach * S.RadiusFraction)
	local centre = root.Position + Vector3.new(0, S.Height, 0)
	local half = math.rad(math.max(arc, 20) / 2)
	local count = S.Segments
	local step = (half * 2) / count
	local length = radius * step * 1.15
	local baseAngle = math.atan2(flatAim.X, flatAim.Z)
	local folder = getFolder()
	for index = 0, count - 1 do
		local angle = baseAngle - half + step * (index + 0.5)
		local direction = Vector3.new(math.sin(angle), 0, math.cos(angle))
		local tangent = Vector3.new(math.cos(angle), 0, -math.sin(angle))
		local position = centre + direction * radius
		local segment = Instance.new("Part")
		segment.Name = "Slash"
		segment.Anchored = true
		segment.CanCollide = false
		segment.CanQuery = false
		segment.CanTouch = false
		segment.CastShadow = false
		segment.Material = Enum.Material.Neon
		segment.Color = color
		segment.Size = Vector3.new(thickness, thickness, length)
		segment.CFrame = CFrame.lookAt(position, position + tangent)
		segment.Transparency = 1
		segment.Parent = folder
		local delay = S.RevealTime * index / count
		task.delay(delay, function()
			segment.Transparency = 0.15
			TweenUtil.Play(segment, S.FadeTime, { Transparency = 1 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
			task.delay(S.FadeTime, function()
				segment:Destroy()
			end)
		end)
	end
end

local function onDamage(
	target: Model,
	amount: number,
	outcome: string,
	crit: boolean,
	position: Vector3,
	attacker: Model?,
	reaction: string?,
	element: string?
)
	if typeof(target) ~= "Instance" or typeof(position) ~= "Vector3" then
		return
	end
	local attunement = if type(element) == "string" then Spells.Attunement(element) else nil
	local character = player.Character
	local mine = attacker ~= nil and attacker == character
	local onMe = target == character

	-- Numbers / labels.
	if DataController.GetSetting("DamageNumbers") ~= false then
		local label = LABELS[outcome]
		if outcome == "Blocked" and amount > 0 then
			showText(position, tostring(amount), UITheme.Colors.Blocked, T.TextSize)
		elseif label then
			local color = if outcome == "Parry" then UITheme.Colors.Parry
				elseif outcome == "Broken" or outcome == "GuardBreak" then UITheme.Colors.Danger
				elseif outcome == "Dodge" or outcome == "PerfectDodge" or outcome == "Absorbed" then UITheme.Colors.Current
				else UITheme.Colors.Blocked
			showText(position, label, color, T.LabelTextSize)
			if outcome == "Broken" and amount > 0 then
				showText(position, tostring(amount), UITheme.Colors.Text, T.TextSize)
			end
		elseif amount > 0 then
			local big = crit or outcome == "Finisher" or outcome == "Riposte" or outcome == "Reaction"
			local reactionName = if type(reaction) == "string" then Strings.Combat.Reactions[reaction] else nil
			local text = if outcome == "Finisher" then `{Strings.Combat.Finisher} {amount}`
				elseif outcome == "Riposte" then `{Strings.Combat.Riposte} {amount}`
				elseif outcome == "Reaction" then `{reactionName or Strings.Combat.Reaction} {amount}`
				elseif crit then `{amount}!`
				else tostring(amount)
			local color = if onMe then UITheme.Colors.Danger
				elseif outcome == "Reaction" then UITheme.Colors.Reaction
				elseif big then UITheme.Colors.Parry
				elseif attunement then attunement.Color
				else UITheme.Colors.Text
			showText(position, text, color, if big then T.BigTextSize else T.TextSize)
		end
	end

	-- Flash and hit stop on landed blows.
	local landed = amount > 0
		and (outcome == "Hit" or outcome == "Riposte" or outcome == "Finisher" or outcome == "Broken" or outcome == "Reaction")
	if landed then
		flash(target)
	end
	if mine and landed and character then
		local stop = if outcome == "Finisher" then C.HitStop.BrokenFinisher
			elseif outcome == "Riposte" then C.HitStop.Riposte
			else C.HitStop.Light
		freeze(character, stop, 0)
		CameraController.Shake(if outcome == "Finisher" or outcome == "Riposte" then C.CameraShake.Heavy else C.CameraShake.Light)
	end
	if onMe then
		if outcome == "PerfectDodge" then
			perfectDodge()
		elseif outcome == "Parry" then
			spark(position, UITheme.Colors.Parry)
			CameraController.Shake(C.CameraShake.Light)
		elseif outcome == "GuardBreak" then
			CameraController.Shake(C.CameraShake.Heavy)
		elseif amount > 0 then
			CameraController.Shake(if outcome == "Blocked" then C.CameraShake.Light else C.CameraShake.Heavy)
		end
	elseif mine and outcome == "Parry" then
		spark(position, UITheme.Colors.Parry)
	end
end

function CombatFeedbackController.Start()
	Net.OnClient("DamageDealt", onDamage)
	Net.OnClient("SwingVisual", function(attacker: Model, kind: string, aim: Vector3, reach: number, arc: number, windup: number)
		if typeof(attacker) ~= "Instance" or not attacker:IsA("Model") or typeof(aim) ~= "Vector3" then
			return
		end
		task.delay(if type(windup) == "number" then windup else 0, function()
			if attacker.Parent then
				CombatFeedbackController.DrawSlash(attacker, aim, reach, arc, kind)
			end
		end)
	end)
end

return CombatFeedbackController
