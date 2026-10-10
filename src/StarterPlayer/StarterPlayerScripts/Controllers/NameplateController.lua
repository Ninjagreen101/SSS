--!strict
--[[
	NameplateController
	A plate over every other player's head (Phase 11):

	        Lv 7  Mirabel
	      ~ Parry Master ~        (smaller gold serif: the title they chose, attribute Title)

	- Name = DisplayName, level from the player attribute Level, title from the attribute Title
	  (a Strings path such as "Achievements.Titles.ParryMaster"; "" = none).
	- Your own plate is never shown. Roblox's default name display is turned off on characters
	  that have one of ours.
	- Plates fade with camera distance (UITheme.Nameplate FadeStart .. MaxDistance) and are
	  hidden beyond it.
	- Plates are pooled: a BillboardGui is built once and reused when players leave and join or
	  respawn. Distances update a few times a second, not every frame.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Strings = require(Shared.Strings)
local Attributes = require(Shared.Attributes)

local UI = script.Parent.Parent.UI
local UITheme = require(UI.UITheme)
local Create = require(UI.Create)
local QuestText = require(UI.QuestText)

local A = Attributes.Names
local C = UITheme.Colors
local N = UITheme.Nameplate
local Q = Strings.QuestUI
local localPlayer = Players.LocalPlayer

type Plate = {
	Gui: BillboardGui,
	Name: TextLabel,
	Level: TextLabel,
	Title: TextLabel,
	Faded: number, -- last applied fade (0 = opaque, 1 = hidden)
}

type Watch = {
	Player: Player,
	Plate: Plate?,
	Connections: { RBXScriptConnection },
	CharacterConnections: { RBXScriptConnection },
}

local NameplateController = {}

local pool: { Plate } = {}
local watched: { [Player]: Watch } = {}
local folder: Folder

local function buildPlate(): Plate
	local gui: BillboardGui = Create.new("BillboardGui", {
		Name = "SpireNameplate",
		AlwaysOnTop = false,
		LightInfluence = 0,
		ResetOnSpawn = false,
		MaxDistance = N.MaxDistance,
		Size = UDim2.fromOffset(N.Size.X, N.Size.Y),
		StudsOffsetWorldSpace = N.StudsOffset,
		Enabled = false,
	})
	local holder: Frame = Create.new("Frame", {
		Name = "Holder",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = gui,
	})
	Create.List(holder, Enum.FillDirection.Vertical, 0, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Bottom)
	local line: Frame = Create.new("Frame", {
		Name = "NameLine",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 24),
		LayoutOrder = 1,
		Parent = holder,
	})
	Create.List(line, Enum.FillDirection.Horizontal, 6, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
	local level: TextLabel = Create.new("TextLabel", {
		Name = "Level",
		BackgroundTransparency = 1,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 20),
		FontFace = UITheme.Fonts.Numbers,
		TextSize = 14,
		TextColor3 = C.Accent,
		TextStrokeColor3 = Color3.new(0, 0, 0),
		TextStrokeTransparency = 0.35,
		Text = "",
		LayoutOrder = 1,
		Parent = line,
	})
	local name: TextLabel = Create.new("TextLabel", {
		Name = "Name",
		BackgroundTransparency = 1,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 24),
		FontFace = UITheme.Fonts.BodyBold,
		TextSize = 19,
		TextColor3 = C.Text,
		TextStrokeColor3 = Color3.new(0, 0, 0),
		TextStrokeTransparency = 0.25,
		Text = "",
		LayoutOrder = 2,
		Parent = line,
	})
	local title: TextLabel = Create.new("TextLabel", {
		Name = "Title",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 18),
		FontFace = UITheme.Fonts.Display,
		TextSize = 14,
		TextColor3 = N.Title,
		TextStrokeColor3 = Color3.fromRGB(30, 20, 5),
		TextStrokeTransparency = 0.3,
		Text = "",
		LayoutOrder = 2,
		Visible = false,
		Parent = holder,
	})
	return { Gui = gui, Name = name, Level = level, Title = title, Faded = -1 }
end

local function takePlate(): Plate
	local plate = table.remove(pool)
	if plate then
		return plate
	end
	return buildPlate()
end

local function releasePlate(plate: Plate)
	plate.Gui.Enabled = false
	plate.Gui.Adornee = nil :: any
	plate.Faded = -1
	table.insert(pool, plate)
end

local function fill(watch: Watch)
	local plate = watch.Plate
	if not plate then
		return
	end
	local who = watch.Player
	plate.Name.Text = who.DisplayName
	local level = who:GetAttribute(A.Level)
	plate.Level.Text = if type(level) == "number" then Strings.Format(Q.PlateLevel, { level = level }) else ""
	plate.Level.Visible = plate.Level.Text ~= ""
	local title = QuestText.TitleFromPath(who:GetAttribute(A.Title))
	plate.Title.Text = if title then title else ""
	plate.Title.Visible = title ~= nil
end

local function disconnectAll(list: { RBXScriptConnection })
	for _, connection in list do
		connection:Disconnect()
	end
	table.clear(list)
end

local function attach(watch: Watch, character: Model?)
	disconnectAll(watch.CharacterConnections)
	local plate = watch.Plate
	if not character then
		if plate then
			releasePlate(plate)
			watch.Plate = nil
		end
		return
	end
	local function adorn()
		local head = character:FindFirstChild("Head")
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		end
		if not (head and head:IsA("BasePart")) then
			return
		end
		local current = watch.Plate or takePlate()
		watch.Plate = current
		current.Gui.Adornee = head
		current.Gui.Parent = folder
		current.Faded = -1
		fill(watch)
	end
	adorn()
	table.insert(watch.CharacterConnections, character.ChildAdded:Connect(function(child: Instance)
		if child.Name == "Head" or child:IsA("Humanoid") then
			adorn()
		end
	end))
end

local function watchPlayer(who: Player)
	if who == localPlayer or watched[who] then
		return
	end
	local watch: Watch = { Player = who, Plate = nil, Connections = {}, CharacterConnections = {} }
	watched[who] = watch
	table.insert(watch.Connections, who.CharacterAdded:Connect(function(character: Model)
		attach(watch, character)
	end))
	table.insert(watch.Connections, who.CharacterRemoving:Connect(function()
		attach(watch, nil)
	end))
	table.insert(watch.Connections, who:GetAttributeChangedSignal(A.Level):Connect(function()
		fill(watch)
	end))
	table.insert(watch.Connections, who:GetAttributeChangedSignal(A.Title):Connect(function()
		fill(watch)
	end))
	table.insert(watch.Connections, who:GetPropertyChangedSignal("DisplayName"):Connect(function()
		fill(watch)
	end))
	attach(watch, who.Character)
end

local function unwatchPlayer(who: Player)
	local watch = watched[who]
	if not watch then
		return
	end
	watched[who] = nil
	disconnectAll(watch.Connections)
	attach(watch, nil)
end

local function applyFade(plate: Plate, fade: number)
	if math.abs(plate.Faded - fade) < 0.02 then
		return
	end
	plate.Faded = fade
	plate.Gui.Enabled = fade < 0.99
	plate.Name.TextTransparency = fade
	plate.Name.TextStrokeTransparency = 0.25 + fade * 0.75
	plate.Level.TextTransparency = fade
	plate.Level.TextStrokeTransparency = 0.35 + fade * 0.65
	plate.Title.TextTransparency = fade
	plate.Title.TextStrokeTransparency = 0.3 + fade * 0.7
end

local function refreshFades()
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local eye = camera.CFrame.Position
	local span = math.max(1, N.MaxDistance - N.FadeStart)
	for _, watch in watched do
		local plate = watch.Plate
		local head = plate and plate.Gui.Adornee
		if plate and head and head:IsA("BasePart") and head.Parent then
			local distance = (head.Position - eye).Magnitude
			applyFade(plate, math.clamp((distance - N.FadeStart) / span, 0, 1))
		elseif plate then
			applyFade(plate, 1)
		end
	end
end

function NameplateController.Init()
	folder = Instance.new("Folder")
	folder.Name = "SpireNameplates"
	folder.Parent = localPlayer:WaitForChild("PlayerGui")
end

function NameplateController.Start()
	for _, who in Players:GetPlayers() do
		watchPlayer(who)
	end
	Players.PlayerAdded:Connect(watchPlayer)
	Players.PlayerRemoving:Connect(unwatchPlayer)
	task.spawn(function()
		while true do
			task.wait(N.Refresh)
			refreshFades()
		end
	end)
end

return NameplateController
