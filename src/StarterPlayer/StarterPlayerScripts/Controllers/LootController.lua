--!strict
--[[
	LootController
	Draws your personal loot (Spec Section 11 and 13):

	  - Each drop is a small model of the item (ItemModels) that flies out of
	    the corpse in an arc, lands with a bounce, then slowly turns and bobs.
	  - Rare and better show a vertical light beam in the rarity colour and a
	    name label; Legendary and better also glow the edges of the screen and
	    play a deeper chime when they land.
	  - Gold and materials fly to you within Config.Items.Loot.AutoPickupRadius;
	    gear is picked up by walking over it or with Interact (a prompt).
	  - A collected drop does a quick magnet pull into you, and the pickup feed
	    (bottom right) shows icon, name in rarity colour and a stacking count.

	Only you ever see these: the server tells each player about their own
	drops (LootDropped) and checks every pickup request (distance, owner).
	When your bag is full, drops wait on the ground and stop asking until
	something leaves your bag.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Strings = require(Shared.Strings)
local Net = require(Shared.Net)
local Maid = require(Shared.Util.Maid)
local TweenUtil = require(Shared.Util.TweenUtil)
local Items = require(Shared.Data.Items)

local UI = script.Parent.Parent.UI
local UITheme = require(UI.UITheme)
local Create = require(UI.Create)
local Layers = require(UI.Layers)
local UISound = require(UI.UISound)
local Components = require(UI.Components)
local ItemModels = require(UI.ItemModels)
local ItemText = require(UI.ItemText)

local DataController = require(script.Parent.DataController)

local L = Config.Items.Loot
local V = Config.Items.Visual
local player = Players.LocalPlayer

type DropView = {
	Id: string,
	DefId: string,
	Rarity: string,
	Count: number,
	Gold: number,
	Origin: Vector3,
	Position: Vector3,
	Auto: boolean,
	Unique: string?,
}

type Drop = {
	View: DropView,
	Model: Model,
	Maid: Maid.Maid,
	Spawned: number,
	Landed: boolean,
	Collected: number?, -- os.clock() when the magnet pull started
	CollectFrom: Vector3?,
	RequestedAt: number,
	Blocked: boolean,
	Spin: number,
}

local LootController = {}

local drops: { [string]: Drop } = {}
local folder: Folder? = nil
local edgeGlow: Frame? = nil
local lastBagFullToast = 0

local function getFolder(): Folder
	if folder and folder.Parent then
		return folder
	end
	local created = Instance.new("Folder")
	created.Name = "PersonalLoot"
	created.Parent = Workspace
	folder = created
	return created
end

local function rootPart(): BasePart?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function isGold(view: DropView): boolean
	return view.Gold > 0
end

local function rank(rarity: string): number
	return Items.RarityRank(rarity)
end

-- SCREEN-EDGE GLOW (Legendary and better) --------------------------------------------

local function glowEdges(color: Color3)
	if not edgeGlow or not edgeGlow.Parent then
		local frame: Frame = Create.new("Frame", {
			Name = "LegendaryGlow",
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			ZIndex = 1,
			Parent = Layers.Get("Overlay"),
		})
		-- Four soft gradient strips hugging the screen edges.
		local sides = {
			{ Size = UDim2.new(1, 0, 0.18, 0), Position = UDim2.fromScale(0, 0), Rotation = 90 },
			{ Size = UDim2.new(1, 0, 0.18, 0), Position = UDim2.fromScale(0, 0.82), Rotation = -90 },
			{ Size = UDim2.new(0.12, 0, 1, 0), Position = UDim2.fromScale(0, 0), Rotation = 0 },
			{ Size = UDim2.new(0.12, 0, 1, 0), Position = UDim2.fromScale(0.88, 0), Rotation = 180 },
		}
		for index, side in sides do
			local strip: Frame = Create.new("Frame", {
				Name = `Edge{index}`,
				BorderSizePixel = 0,
				BackgroundColor3 = color,
				BackgroundTransparency = 0,
				Size = side.Size,
				Position = side.Position,
				Parent = frame,
			})
			Create.new("UIGradient", {
				Rotation = side.Rotation,
				Transparency = NumberSequence.new({
					NumberSequenceKeypoint.new(0, 0.35),
					NumberSequenceKeypoint.new(1, 1),
				}),
				Parent = strip,
			})
		end
		edgeGlow = frame
	end
	local frame = edgeGlow :: Frame
	for _, strip in frame:GetChildren() do
		if strip:IsA("Frame") then
			strip.BackgroundColor3 = color
			strip.BackgroundTransparency = 1
			TweenUtil.Play(strip, 0.25, { BackgroundTransparency = 0 })
			task.delay(V.LegendaryGlowTime, function()
				TweenUtil.Play(strip, 0.8, { BackgroundTransparency = 1 })
			end)
		end
	end
end

-- DROPS -------------------------------------------------------------------------------

local function decorate(drop: Drop)
	local view = drop.View
	local model = drop.Model
	local center = model.PrimaryPart :: BasePart
	local color = if isGold(view) then UITheme.Colors.Stamina else UITheme.RarityColor(view.Rarity)
	local tuning = Config.Items.Rarities[view.Rarity]

	-- Name label (bigger drops only; materials and gold stay quiet).
	if not view.Auto or rank(view.Rarity) >= rank("Uncommon") then
		local billboard = Instance.new("BillboardGui")
		billboard.Name = "Label"
		billboard.Size = UDim2.fromOffset(200, 26)
		billboard.StudsOffsetWorldSpace = Vector3.new(0, 1.6, 0)
		billboard.MaxDistance = V.LabelDistance
		billboard.AlwaysOnTop = rank(view.Rarity) >= rank("Rare")
		billboard.LightInfluence = 0
		billboard.Adornee = center
		billboard.Parent = model
		local label = Create.Label({
			Text = if isGold(view) then `{view.Gold} {Strings.Inventory.Gold}` else ItemText.Name(view.DefId) .. (if view.Count > 1 then ` x{view.Count}` else ""),
			Font = UITheme.Fonts.BodyBold,
			TextSize = UITheme.TextSize.Small,
			Color = color,
			XAlignment = Enum.TextXAlignment.Center,
			Size = UDim2.fromScale(1, 1),
			Parent = billboard,
		})
		label.TextStrokeTransparency = 0.3
	end

	-- Light beam for Rare and better.
	if tuning and tuning.Beam then
		local bottom = Instance.new("Attachment")
		bottom.Name = "BeamBottom"
		bottom.Parent = center
		local top = Instance.new("Attachment")
		top.Name = "BeamTop"
		top.Position = Vector3.new(0, V.BeamHeight, 0)
		top.Parent = center
		local beam = Instance.new("Beam")
		beam.Attachment0 = bottom
		beam.Attachment1 = top
		beam.Color = ColorSequence.new(color)
		beam.LightEmission = 1
		beam.LightInfluence = 0
		beam.FaceCamera = true
		beam.Width0 = if rank(view.Rarity) >= rank("Legendary") then 0.9 else 0.55
		beam.Width1 = 0.08
		beam.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.15),
			NumberSequenceKeypoint.new(0.7, 0.6),
			NumberSequenceKeypoint.new(1, 1),
		})
		beam.Parent = center
		if rank(view.Rarity) >= rank("Epic") then
			local light = Instance.new("PointLight")
			light.Color = color
			light.Range = 8
			light.Brightness = 1.2
			light.Parent = center
		end
	end

	-- Gear: walk over it, or press Interact.
	if not view.Auto then
		local prompt = Instance.new("ProximityPrompt")
		prompt.Name = "PickupPrompt"
		prompt.Style = Enum.ProximityPromptStyle.Custom
		prompt.ActionText = Strings.Prompts.Pickup
		prompt.ObjectText = ItemText.Name(view.DefId)
		prompt.MaxActivationDistance = L.InteractRadius
		prompt.RequiresLineOfSight = false
		prompt.KeyboardKeyCode = Enum.KeyCode.E
		prompt.GamepadKeyCode = Enum.KeyCode.ButtonX
		prompt.Parent = center
		drop.Maid:Add(prompt.Triggered:Connect(function()
			drop.RequestedAt = os.clock()
			Net.FireServer("RequestPickup", view.Id)
		end))
	end
end

local function spawnDrop(view: DropView)
	if drops[view.Id] then
		return
	end
	local model = if isGold(view) then ItemModels.BuildGold() else ItemModels.Build(view.DefId, view.Rarity)
	-- Ground drops are smaller than icons: gear ~1.5 studs, the rest ~1 stud.
	model:ScaleTo(if view.Auto then 0.32 else 0.5)
	model:PivotTo(CFrame.new(view.Origin))
	model.Parent = getFolder()
	local maid = Maid.new()
	maid:Add(model)
	local drop: Drop = {
		View = view,
		Model = model,
		Maid = maid,
		Spawned = os.clock(),
		Landed = false,
		Collected = nil,
		CollectFrom = nil,
		RequestedAt = 0,
		Blocked = false,
		Spin = math.random() * math.pi * 2,
	}
	drops[view.Id] = drop
	decorate(drop)
end

local function onLanded(drop: Drop)
	drop.Landed = true
	local rarity = drop.View.Rarity
	if drop.View.Gold > 0 then
		return
	end
	if rank(rarity) >= rank("Legendary") then
		UISound.Play("LegendaryLoot")
		glowEdges(UITheme.RarityColor(rarity))
	elseif rank(rarity) >= rank("Rare") then
		UISound.Play("RareLoot")
	end
end

local function removeDrop(id: string, collected: boolean)
	local drop = drops[id]
	if not drop then
		return
	end
	if collected then
		-- Magnet pull into the player, then gone (the step loop finishes it).
		drop.Collected = os.clock()
		drop.CollectFrom = drop.Model:GetPivot().Position
		for _, descendant in drop.Model:GetDescendants() do
			if descendant:IsA("ProximityPrompt") or descendant:IsA("BillboardGui") or descendant:IsA("Beam") then
				descendant:Destroy()
			end
		end
	else
		drops[id] = nil
		drop.Maid:Clean()
	end
end

-- Per frame: arcs, bounces, idle spin, magnet pulls, and pickup requests.
local requestAccumulator = 0
local function step(dt: number)
	local root = rootPart()
	local now = os.clock()
	requestAccumulator += dt
	local checkPickups = requestAccumulator >= 0.1
	if checkPickups then
		requestAccumulator = 0
	end
	local reduced = DataController.GetSetting("ReducedMotion") == true
	for id, drop in drops do
		local view = drop.View
		if drop.Collected then
			local alpha = math.clamp((now - drop.Collected) / V.MagnetTime, 0, 1)
			local target = if root then root.Position else view.Position
			local from = drop.CollectFrom or view.Position
			drop.Model:PivotTo(CFrame.new(from:Lerp(target, alpha * alpha)))
			if alpha >= 1 then
				drops[id] = nil
				drop.Maid:Clean()
			end
			continue
		end
		local elapsed = now - drop.Spawned
		local position: Vector3
		if reduced or elapsed >= V.ArcTime then
			if not drop.Landed then
				onLanded(drop)
			end
			local since = math.max(0, elapsed - V.ArcTime)
			local bounce = if reduced then 0 else math.abs(math.sin(since * 9)) * V.BounceHeight * math.exp(-since * V.BounceDecay)
			local bob = if reduced then 0 else math.sin(now * 2 + drop.Spin) * 0.12
			position = view.Position + Vector3.new(0, 0.35 + bounce + bob, 0)
		else
			local alpha = elapsed / V.ArcTime
			position = view.Origin:Lerp(view.Position, alpha) + Vector3.new(0, 4 * V.ArcHeight * alpha * (1 - alpha), 0)
		end
		drop.Spin += dt * V.SpinSpeed
		drop.Model:PivotTo(CFrame.new(position) * CFrame.Angles(0, drop.Spin, 0))

		-- Ask the server for drops in reach (it re-checks). Retry at most once a second.
		if checkPickups and root and drop.Landed and not drop.Blocked and now - drop.RequestedAt > 1 then
			local distance = (root.Position - view.Position).Magnitude
			local reach = if view.Auto then L.AutoPickupRadius else L.WalkOverRadius
			if distance <= reach then
				drop.RequestedAt = now
				Net.FireServer("RequestPickup", id)
			end
		end
	end
end

-- PICKUP FEED -------------------------------------------------------------------------------

local function onItemResult(ok: boolean, reason: string, payload: { [string]: any })
	if type(payload) ~= "table" then
		return
	end
	if not ok and type(payload.DropId) == "string" then
		local drop = drops[payload.DropId]
		if drop and reason == "Full" then
			drop.Blocked = true
			if os.clock() - lastBagFullToast > 6 then
				lastBagFullToast = os.clock()
				UISound.Play("UIError")
				Components.Toast.Push({ Title = Strings.Toasts.BagFull, Color = UITheme.Colors.Danger, Key = "bagfull" })
			end
		end
		return
	end
	if not ok or reason ~= "Pickup" then
		return
	end
	local gold = tonumber(payload.Gold) or 0
	if gold > 0 then
		UISound.Play("GoldPickup")
		Components.Toast.Push({
			Title = Strings.Inventory.Gold,
			Color = UITheme.Colors.Stamina,
			Key = "pickup:gold",
			Count = gold,
			Item = "Gold",
			Silent = true,
			Duration = V.FeedDuration,
		})
		return
	end
	local defId = payload.DefId
	if type(defId) ~= "string" or defId == "" then
		return
	end
	local rarity = if type(payload.Rarity) == "string" then payload.Rarity else "Common"
	UISound.Play(if rank(rarity) >= rank("Rare") then "RareLoot" else "ItemPickup")
	Components.Toast.Push({
		Title = ItemText.Name(defId),
		Color = UITheme.RarityColor(rarity),
		Key = `pickup:{defId}:{rarity}`,
		Count = tonumber(payload.Count) or 1,
		Item = defId,
		ItemRarity = rarity,
		Silent = true,
		Duration = V.FeedDuration,
	})
end

function LootController.Init()
	Net.OnClient("LootDropped", function(list: { DropView })
		if type(list) ~= "table" then
			return
		end
		for _, view in list do
			if type(view) == "table" and type(view.Id) == "string" then
				spawnDrop(view)
			end
		end
	end)
	Net.OnClient("LootRemoved", function(id: string, collected: boolean)
		if type(id) == "string" then
			removeDrop(id, collected == true)
		end
	end)
	Net.OnClient("ItemResult", onItemResult)
end

function LootController.Start()
	RunService.RenderStepped:Connect(step)
	-- Something left the bag: drops that were waiting may fit now.
	DataController.Changed:Connect(function(path: { string })
		if path[1] == "Inventory" then
			for _, drop in drops do
				drop.Blocked = false
			end
		end
	end)
	-- Respawning clears nothing: drops stay until collected or expired.
	player.CharacterAdded:Connect(function()
		for _, drop in drops do
			drop.RequestedAt = 0
		end
	end)
end

return LootController
