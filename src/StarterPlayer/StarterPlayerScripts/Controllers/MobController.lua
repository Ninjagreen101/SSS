--!strict
--[[
	MobController
	Everything players see of enemies. The server only moves mobs and decides
	their attacks; each client animates them locally, which keeps the server
	and network light.

	- Locomotion: Roblox's standard idle / walk / run, sped up to match how
	  fast the mob really moves.
	- Blows: when the MobBlow attribute changes, the attack animation is
	  played stretched so its moment of contact lands exactly when the
	  server checks the hit. The first blow of a move shows the red
	  telegraph glow until contact.
	- Hit stun and posture breaks play the Hurt / Broken animations.
	- Nameplate: level, name and health bar over mobs within
	  Mobs.Visual.HealthBarDistance once they're fighting or hurt (hidden on
	  the mob you're locked on to, which has its own marker). Elites are gold.
	- Statuses (Soaked, Chilled, ...) show under the health bar in their
	  Attunement's colour.
	- Death: the body fades out (Mobs.Visual.DissolveDuration).
	- Stealth mobs (Rustwood Stalkers) are nearly invisible while idle or
	  patrolling until you come within STEALTH_REVEAL studs or they engage.
	- Empowered mobs (a Lantern Acolyte's Kindle, attribute EmpoweredUntil)
	  glow amber until it wears off.
	Bolts are drawn by SpellVFXController.
	Only mobs within Mobs.AI.AnimationCullRadius of the camera animate.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Attributes = require(Shared.Attributes)
local Strings = require(Shared.Strings)
local Mobs = require(Shared.Data.Mobs)
local Spells = require(Shared.Data.Spells)
local Maid = require(Shared.Util.Maid)

local UI = script.Parent.Parent.UI
local UITheme = require(UI.UITheme)
local Create = require(UI.Create)

local LockOnController = require(script.Parent.LockOnController)

local A = Attributes.Names
local VISUAL = Config.Mobs.Visual
local LOCO = Config.Mobs.Locomotion
local ANIMS = Config.Assets.Animations

local MobController = {}

type Visual = {
	Model: Model,
	Humanoid: Humanoid,
	Root: BasePart,
	Maid: Maid.Maid,
	Tracks: { [string]: AnimationTrack },
	Loco: string?,
	Highlight: Highlight?,
	HighlightUntil: number,
	Plate: BillboardGui,
	Fill: Frame,
	StatusLabel: TextLabel,
	Dead: boolean,
	Animating: boolean,
	NextUpdate: number,
	Stealth: boolean, -- fades while lurking (Rustwood Stalkers)
	Hidden: boolean,
	BaseTransparency: { [BasePart]: number },
	Empower: Highlight?, -- warm glow while a Lantern Acolyte's Kindle lasts
}

local visuals: { [Model]: Visual } = {}

local UPDATE_INTERVAL = 0.1
local STEALTH_REVEAL = 18
local STEALTH_ALPHA = 0.88 -- how see-through a lurking stalker is (1 = invisible)
local LURKING = { Idle = true, Patrol = true }

-- Statuses shown on nameplates, with the Attunement whose colour they wear.
local STATUS_ORDER = { "Frozen", "Chilled", "Soaked", "Shocked", "Heavy", "Rooted", "Renewing" }
local STATUS_ELEMENT: { [string]: string } = {
	Frozen = "Rime",
	Chilled = "Rime",
	Soaked = "Tide",
	Shocked = "Tempest",
	Heavy = "Abyss",
	Rooted = "Bloom",
	Renewing = "Bloom",
}
local FIGHTING = { Alert = true, Chase = true, Attack = true, Recover = true, Staggered = true, Broken = true }

local function now(): number
	return Workspace:GetServerTimeNow()
end

local function idFor(slot: string): string?
	local id: any = (ANIMS.Classes.Longsword :: any)[slot] or (ANIMS.Common :: any)[slot]
	if type(id) ~= "string" or id == "" then
		return nil
	end
	return if string.find(id, "rbxasset", 1, true) then id else `rbxassetid://{id}`
end

local function track(visual: Visual, name: string, id: string?, priority: Enum.AnimationPriority, looped: boolean): AnimationTrack?
	local existing = visual.Tracks[name]
	if existing then
		return existing
	end
	if not id then
		return nil
	end
	local animator = visual.Humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		return nil
	end
	local animation = Instance.new("Animation")
	animation.AnimationId = id
	local ok, loaded = pcall(function()
		return animator:LoadAnimation(animation)
	end)
	if not ok then
		return nil
	end
	loaded.Priority = priority
	loaded.Looped = looped
	visual.Tracks[name] = loaded
	return loaded
end

local function stopAll(visual: Visual, fade: number)
	for _, t in visual.Tracks do
		if t.IsPlaying then
			t:Stop(fade)
		end
	end
	visual.Loco = nil
end

local function stopActions(visual: Visual)
	for _, t in visual.Tracks do
		if t.IsPlaying and t.Priority == Enum.AnimationPriority.Action then
			t:Stop(0.1)
		end
	end
end

local function setGlow(visual: Visual, on: boolean)
	local highlight = visual.Highlight
	if on and not highlight then
		local created = Instance.new("Highlight")
		created.Name = "Telegraph"
		created.FillColor = UITheme.Colors.Danger
		created.OutlineColor = UITheme.Colors.Danger
		created.FillTransparency = 0.5
		created.OutlineTransparency = 0.1
		created.DepthMode = Enum.HighlightDepthMode.Occluded
		created.Adornee = visual.Model
		created.Parent = visual.Model
		visual.Maid:Add(created)
		visual.Highlight = created
		highlight = created
	end
	if highlight then
		highlight.Enabled = on
	end
end

-- LOCOMOTION -------------------------------------------------------------------

local function updateLocomotion(visual: Visual)
	local velocity = visual.Root.AssemblyLinearVelocity
	local speed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
	local name: string
	local id: string
	local rate = 1
	if speed > LOCO.RunThreshold then
		name, id, rate = "Run", LOCO.Run, speed / LOCO.RunAnimSpeed
	elseif speed > 1 then
		name, id, rate = "Walk", LOCO.Walk, speed / LOCO.WalkAnimSpeed
	else
		name, id = "Idle", LOCO.Idle
	end
	local t = track(visual, name, id, Enum.AnimationPriority.Movement, true)
	if not t then
		return
	end
	if visual.Loco ~= name then
		local previous = visual.Loco and visual.Tracks[visual.Loco]
		if previous then
			previous:Stop(0.2)
		end
		t:Play(0.2)
		visual.Loco = name
	end
	t:AdjustSpeed(math.clamp(rate, 0.5, 2))
end

-- BLOWS ------------------------------------------------------------------------

local function onBlow(visual: Visual)
	local raw = visual.Model:GetAttribute(A.MobBlow)
	if type(raw) ~= "string" or visual.Dead then
		return
	end
	local parts = string.split(raw, ";")
	local slot = parts[1]
	local windup = tonumber(parts[2]) or 0
	local startedAt = tonumber(parts[3]) or now()
	local telegraph = parts[4] == "1"
	local remaining = math.max(0.03, windup - (now() - startedAt))

	if telegraph then
		visual.HighlightUntil = os.clock() + remaining
		setGlow(visual, true)
	end
	if not visual.Animating then
		return
	end
	local t = track(visual, slot, idFor(slot), Enum.AnimationPriority.Action, false)
	if not t then
		return
	end
	-- Stretch the windup so the clip's contact frame lands on the server's hit.
	local contact = (Config.Mobs.AnimationContact :: any)[slot] or 0.14
	t:Play(0.08, 1, contact / remaining)
	task.delay(remaining, function()
		if t.IsPlaying then
			t:AdjustSpeed(1)
		end
	end)
end

local function onCombatState(visual: Visual)
	local state = visual.Model:GetAttribute(A.CombatState)
	if visual.Dead or not visual.Animating then
		return
	end
	if state == "Staggered" or state == "Broken" then
		stopActions(visual)
		setGlow(visual, false)
		local slot = if state == "Broken" then "Broken" else "Hurt"
		local t = track(visual, slot, idFor(slot), Enum.AnimationPriority.Action, false)
		if t then
			t:Play(0.05)
		end
	end
end

-- NAMEPLATE --------------------------------------------------------------------

local function buildPlate(model: Model, head: BasePart, mobId: string, def: Mobs.MobDef?): (BillboardGui, Frame, TextLabel)
	local elite = model:GetAttribute(A.Elite) == true
	local name = Strings.Mobs[mobId] or mobId
	local template = if elite then Strings.MobUI.EliteNameplate else Strings.MobUI.Nameplate
	local gui: BillboardGui = Create.new("BillboardGui", {
		Name = "MobPlate",
		Adornee = head,
		AlwaysOnTop = false,
		LightInfluence = 0,
		MaxDistance = VISUAL.HealthBarDistance,
		Size = UDim2.fromOffset(170, 44),
		StudsOffsetWorldSpace = Vector3.new(0, 2.2 * (if def then def.Body.Scale else 1), 0),
		Enabled = false,
	})
	Create.new("TextLabel", {
		Name = "Name",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 16),
		FontFace = UITheme.Fonts.BodyBold,
		TextSize = 14,
		TextColor3 = if elite then Config.Mobs.Elite.GlowColor else UITheme.Colors.Text,
		TextStrokeTransparency = 0.4,
		Text = Strings.Format(template, { level = if def then def.Level else 1, name = name }),
		Parent = gui,
	})
	local bar: Frame = Create.new("Frame", {
		Name = "Bar",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 19),
		Size = UDim2.new(0.8, 0, 0, 6),
		BackgroundColor3 = UITheme.Colors.Track,
		BackgroundTransparency = 0.2,
		Parent = gui,
	})
	Create.Corner(bar, UITheme.CornerPill)
	Create.Stroke(bar, UITheme.Colors.StoneShadow, 1, 0.3)
	local fill: Frame = Create.new("Frame", {
		Name = "Fill",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = UITheme.Colors.Health,
		Parent = bar,
	})
	Create.Corner(fill, UITheme.CornerPill)
	local statuses: TextLabel = Create.new("TextLabel", {
		Name = "Statuses",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 28),
		Size = UDim2.new(1, 0, 0, 14),
		FontFace = UITheme.Fonts.BodyBold,
		TextSize = 11,
		RichText = true,
		TextStrokeTransparency = 0.5,
		TextColor3 = UITheme.Colors.Text,
		Text = "",
		Parent = gui,
	})
	gui.Parent = model
	return gui, fill, statuses
end

local function refreshStatuses(visual: Visual)
	local t = now()
	local parts = {}
	for _, status in STATUS_ORDER do
		local ends = visual.Model:GetAttribute(Attributes.Status(status))
		if type(ends) == "number" and ends > t then
			local element = Spells.Attunement(STATUS_ELEMENT[status])
			local color = if element then element.Color else UITheme.Colors.Text
			local label = string.upper(Strings.Statuses[status] or status)
			if status == "Chilled" then
				local stacks = visual.Model:GetAttribute(A.ChillStacks)
				if type(stacks) == "number" then
					label ..= ` {stacks}`
				end
			end
			table.insert(parts, `<font color="#{color:ToHex()}">{label}</font>`)
		end
	end
	visual.StatusLabel.Text = table.concat(parts, "  ")
end

local function refreshHealth(visual: Visual)
	local humanoid = visual.Humanoid
	local fraction = if humanoid.MaxHealth > 0 then math.clamp(humanoid.Health / humanoid.MaxHealth, 0, 1) else 0
	visual.Fill.Size = UDim2.fromScale(fraction, 1)
end

-- DEATH ------------------------------------------------------------------------

local function dissolve(visual: Visual)
	if visual.Dead then
		return
	end
	visual.Dead = true
	visual.Plate.Enabled = false
	if visual.Empower then
		visual.Empower:Destroy()
		visual.Empower = nil
	end
	setGlow(visual, false)
	stopAll(visual, 0.2)
	local info = TweenInfo.new(VISUAL.DissolveDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	for _, item in visual.Model:GetDescendants() do
		if item:IsA("BasePart") and item.Transparency < 1 then
			TweenService:Create(item, info, { Transparency = 1 }):Play()
		elseif item:IsA("Decal") then
			TweenService:Create(item, info, { Transparency = 1 }):Play()
		elseif item:IsA("PointLight") then
			TweenService:Create(item, info, { Brightness = 0 }):Play()
		end
	end
end

-- LIFECYCLE --------------------------------------------------------------------

local function unbind(model: Model)
	local visual = visuals[model]
	if visual then
		visuals[model] = nil
		visual.Maid:Destroy()
	end
end

local function bind(instance: Instance)
	if not instance:IsA("Model") or visuals[instance] then
		return
	end
	local model = instance
	local humanoid = model:WaitForChild("Humanoid", 10)
	local root = model:WaitForChild("HumanoidRootPart", 10)
	local head = model:WaitForChild("Head", 10)
	if not (humanoid and humanoid:IsA("Humanoid") and root and root:IsA("BasePart") and head and head:IsA("BasePart")) then
		return
	end
	if not model.Parent or visuals[model] then
		return
	end
	local mobId = model:GetAttribute(A.MobId)
	local def = if type(mobId) == "string" then Mobs.Get(mobId) else nil
	local plate, fill, statusLabel = buildPlate(model, head, if type(mobId) == "string" then mobId else model.Name, def)
	local visual: Visual = {
		Model = model,
		Humanoid = humanoid,
		Root = root,
		Maid = Maid.new(),
		Tracks = {},
		Loco = nil,
		Highlight = nil,
		HighlightUntil = 0,
		Plate = plate,
		Fill = fill,
		StatusLabel = statusLabel,
		Dead = false,
		Animating = false,
		NextUpdate = 0,
		Stealth = def ~= nil and def.Stealth == true,
		Hidden = false,
		BaseTransparency = {},
		Empower = nil,
	}
	if visual.Stealth then
		for _, d in model:GetDescendants() do
			if d:IsA("BasePart") and d.Transparency < 1 then
				visual.BaseTransparency[d] = d.Transparency
			end
		end
	end
	visuals[model] = visual
	visual.Maid:Add(plate)
	visual.Maid:Add(function()
		for _, t in visual.Tracks do
			t:Stop(0)
			t:Destroy()
		end
	end)
	visual.Maid:Add(model:GetAttributeChangedSignal(A.MobBlow):Connect(function()
		onBlow(visual)
	end))
	visual.Maid:Add(model:GetAttributeChangedSignal(A.CombatState):Connect(function()
		onCombatState(visual)
	end))
	visual.Maid:Add(humanoid.HealthChanged:Connect(function(health: number)
		refreshHealth(visual)
		if health <= 0 then
			dissolve(visual)
		end
	end))
	visual.Maid:Add(model:GetAttributeChangedSignal(A.MobState):Connect(function()
		if model:GetAttribute(A.MobState) == "Dead" then
			dissolve(visual)
		end
	end))
	visual.Maid:Add(model.AncestryChanged:Connect(function()
		if not model:IsDescendantOf(Workspace) then
			unbind(model)
		end
	end))
	refreshHealth(visual)
	if humanoid.Health <= 0 or model:GetAttribute(A.MobState) == "Dead" then
		dissolve(visual)
	end
end

local function setHidden(visual: Visual, hidden: boolean)
	if visual.Hidden == hidden then
		return
	end
	visual.Hidden = hidden
	local info = TweenInfo.new(if hidden then 1.2 else 0.25)
	for part, base in visual.BaseTransparency do
		if part.Parent then
			local goal = if hidden then base + (1 - base) * STEALTH_ALPHA else base
			TweenService:Create(part, info, { Transparency = goal }):Play()
		end
	end
end

local function refreshEmpower(visual: Visual)
	local untilAt = visual.Model:GetAttribute("EmpoweredUntil")
	local on = type(untilAt) == "number" and untilAt > Workspace:GetServerTimeNow()
	if on and not visual.Empower then
		local h = Instance.new("Highlight")
		h.Name = "Empower"
		h.FillColor = Color3.fromHex("#FFB45A")
		h.OutlineColor = Color3.fromHex("#FFD9A0")
		h.FillTransparency = 0.72
		h.OutlineTransparency = 0.35
		h.DepthMode = Enum.HighlightDepthMode.Occluded
		h.Adornee = visual.Model
		h.Parent = visual.Model
		visual.Empower = h
	elseif not on and visual.Empower then
		visual.Empower:Destroy()
		visual.Empower = nil
	end
end

local function update()
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local clock = os.clock()
	local eye = camera.CFrame.Position
	local locked = LockOnController.GetTarget()
	for model, visual in visuals do
		if visual.HighlightUntil > 0 and clock >= visual.HighlightUntil then
			visual.HighlightUntil = 0
			setGlow(visual, false)
		end
		if clock >= visual.NextUpdate and not visual.Dead then
			visual.NextUpdate = clock + UPDATE_INTERVAL
			local distance = (visual.Root.Position - eye).Magnitude
			local animate = distance <= Config.Mobs.AI.AnimationCullRadius
			if animate ~= visual.Animating then
				visual.Animating = animate
				if not animate then
					stopAll(visual, 0.2)
				end
			end
			if animate then
				updateLocomotion(visual)
			end
			local humanoid = visual.Humanoid
			local state = model:GetAttribute(A.MobState)
			local hurt = humanoid.Health < humanoid.MaxHealth
			refreshStatuses(visual)
			refreshEmpower(visual)
			if visual.Stealth then
				setHidden(visual, type(state) == "string" and LURKING[state] == true and distance > STEALTH_REVEAL and not hurt)
			end
			visual.Plate.Enabled = model ~= locked
				and not visual.Hidden
				and distance <= VISUAL.HealthBarDistance
				and (hurt or (type(state) == "string" and FIGHTING[state] == true))
		end
	end
end

function MobController.Start()
	for _, model in CollectionService:GetTagged(Attributes.Tags.Mob) do
		task.spawn(bind, model)
	end
	CollectionService:GetInstanceAddedSignal(Attributes.Tags.Mob):Connect(bind)
	RunService.RenderStepped:Connect(update)
end

return MobController
