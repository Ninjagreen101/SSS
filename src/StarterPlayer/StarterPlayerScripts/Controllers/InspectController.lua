--!strict
--[[
	InspectController (Phase 12)
	Click (or tap) another player's character to open a small context strip beside them:
	Inspect, Invite to party, Trade. Inspect sends RequestInspect(userId); the server answers
	InspectResult(userId, payload | nil) and a compact card shows their level, Position, title,
	Company and the nine equipment slots (rarity colours, the usual item tooltips).

	- The click is a raycast from the cursor that ignores your own character and stops at walls. It
	  needs a free cursor (hold Free Cursor, or any menu context) or a touch; with the cursor locked a
	  click is an attack. Taps that drag (camera swipes) don't count.
	- Invite to party and Trade call PartyController.Invite(userId) and TradeController.RequestTrade(userId)
	  when those controllers exist; otherwise the buttons are greyed out.
	- The strip and the card are built once and reused.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Enums = require(Shared.Enums)
local Strings = require(Shared.Strings)
local Net = require(Shared.Net)
local Maid = require(Shared.Util.Maid)
local Positions = require(Shared.Data.Positions)
local Types = require(Shared.Types)

local UI = script.Parent.Parent.UI
local UITheme = require(UI.UITheme)
local Create = require(UI.Create)
local Layers = require(UI.Layers)
local Icons = require(UI.Icons)
local ItemText = require(UI.ItemText)
local ProgressionText = require(UI.ProgressionText)
local QuestText = require(UI.QuestText)
local Components = require(UI.Components)

local InputController = require(script.Parent.InputController)
local UIController = require(script.Parent.UIController)

type ItemInstance = Types.ItemInstance

type Payload = {
	UserId: number,
	Name: string,
	DisplayName: string,
	Level: number,
	Position: string,
	Title: string,
	Company: string,
	Gear: { [string]: ItemInstance },
}

type Card = {
	Panel: Frame,
	Name: TextLabel,
	Handle: TextLabel,
	TitleLabel: TextLabel,
	Level: TextLabel,
	PositionLabel: TextLabel,
	CompanyLabel: TextLabel,
	Slots: { [string]: Components.ItemSlot },
}

type Strip = {
	Panel: Frame,
	Name: TextLabel,
	Inspect: Components.Button,
	Invite: Components.Button,
	Trade: Components.Button,
}

local C = UITheme.Colors
local S = Strings.Inspect
local localPlayer = Players.LocalPlayer

local TAP_MAX_MOVE = 14 -- px a press may travel and still be a tap
local TAP_MAX_TIME = 0.5
local STRIP_WIDTH = 210
local BUTTON_HEIGHT = 44
local SLOT_SIZE = 60
local SLOT_GAP = 6
local COLUMNS = 5
local RAY_EXTRA = 40 -- the camera sits behind the player; the server still checks the real distance

local InspectController = {}

local card: Card? = nil
local strip: Strip? = nil
local stripTarget: Player? = nil
local stripMaid = Maid.new()
local current: Payload? = nil
local lastRequest = -math.huge
local pendingName = ""
local press: { Input: InputObject, At: Vector2, Time: number }? = nil

-- Another controller by name, or nil when it isn't in the build (being written separately).
local function optional(name: string): any?
	local module = script.Parent:FindFirstChild(name)
	if module and module:IsA("ModuleScript") then
		local ok, result = pcall(require, module)
		if ok then
			return result
		end
	end
	return nil
end

local function canInvite(): boolean
	local controller = optional("PartyController")
	return controller ~= nil and type(controller.Invite) == "function"
end

local function canTrade(): boolean
	local controller = optional("TradeController")
	return controller ~= nil and type(controller.RequestTrade) == "function"
end

local function toast(text: string)
	Components.Toast.Push({ Title = text, Color = C.TextMuted, Key = "InspectNotice", Silent = true })
end

local function rootOf(character: Model?): BasePart?
	return if character then character:FindFirstChild("HumanoidRootPart") :: BasePart? else nil
end

local function distanceTo(target: Player): number?
	local mine, theirs = rootOf(localPlayer.Character), rootOf(target.Character)
	if not mine or not theirs then
		return nil
	end
	return (mine.Position - theirs.Position).Magnitude
end

-- THE CARD -----------------------------------------------------------------------------------------

local function slotLabel(slot: string): string
	return Strings.Inventory.SlotNames[slot] or slot
end

local function slotTooltip(slot: string): Components.TooltipContent?
	local payload = current
	if not payload then
		return nil
	end
	local item = payload.Gear[slot]
	if item then
		return ItemText.Tooltip(item, nil)
	end
	return {
		Title = slotLabel(slot),
		Icon = Icons.ForSlot(slot),
		Subtitle = S.Empty,
	}
end

local function buildCard(): Card
	local width = COLUMNS * SLOT_SIZE + (COLUMNS - 1) * SLOT_GAP + UITheme.Padding.Large * 2
	local rows = math.ceil(#Enums.EquipSlot / COLUMNS)
	local gridHeight = rows * SLOT_SIZE + (rows - 1) * SLOT_GAP
	local panel: Frame = Create.new("Frame", {
		Name = "InspectCard",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -24, 0.5, 0),
		Size = UDim2.fromOffset(width, 150 + 26 + gridHeight + UITheme.Padding.Large * 2),
		Visible = false,
		Parent = Layers.Get("Overlay"),
	})
	Create.ApplyPanelStyle(panel)
	local inner: Frame = Create.new("Frame", {
		Name = "Inner",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = panel,
	})
	Create.Padding(inner, UITheme.Padding.Large)

	local name = Create.Label({
		Name = "Name",
		Text = "",
		Font = UITheme.Fonts.Title,
		TextSize = UITheme.TextSize.Heading,
		Color = C.Foam,
		Size = UDim2.new(1, -48, 0, 28),
		Parent = inner,
	})
	local handle = Create.Label({
		Name = "Handle",
		Text = "",
		TextSize = UITheme.TextSize.Caption,
		Color = C.TextDim,
		Position = UDim2.fromOffset(0, 28),
		Size = UDim2.new(1, -48, 0, 16),
		Parent = inner,
	})
	local title = Create.Label({
		Name = "Title",
		Text = "",
		Font = UITheme.Fonts.Display,
		TextSize = UITheme.TextSize.Small,
		Color = UITheme.Nameplate.Title,
		Position = UDim2.fromOffset(0, 46),
		Size = UDim2.new(1, 0, 0, 20),
		Parent = inner,
	})
	local level = Create.Label({
		Name = "Level",
		Text = "",
		Font = UITheme.Fonts.BodyBold,
		Color = C.Accent,
		Position = UDim2.fromOffset(0, 70),
		Size = UDim2.new(1, 0, 0, 22),
		Parent = inner,
	})
	local positionLabel = Create.Label({
		Name = "Position",
		Text = "",
		RichText = true,
		Position = UDim2.fromOffset(0, 92),
		Size = UDim2.new(1, 0, 0, 22),
		Parent = inner,
	})
	local company = Create.Label({
		Name = "Company",
		Text = "",
		Color = C.TextMuted,
		TextSize = UITheme.TextSize.Small,
		Position = UDim2.fromOffset(0, 114),
		Size = UDim2.new(1, 0, 0, 20),
		Parent = inner,
	})
	Create.Label({
		Name = "GearHeader",
		Text = string.upper(S.Gear),
		Font = UITheme.Fonts.Title,
		TextSize = UITheme.TextSize.Caption,
		Color = C.Accent,
		Position = UDim2.fromOffset(0, 140),
		Size = UDim2.new(1, 0, 0, 18),
		Parent = inner,
	})

	local grid: Frame = Create.new("Frame", {
		Name = "Gear",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 162),
		Size = UDim2.new(1, 0, 0, gridHeight),
		Parent = inner,
	})
	Create.new("UIGridLayout", {
		CellSize = UDim2.fromOffset(SLOT_SIZE, SLOT_SIZE),
		CellPadding = UDim2.fromOffset(SLOT_GAP, SLOT_GAP),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = grid,
	})

	local slots: { [string]: Components.ItemSlot } = {}
	for order, slot in Enums.EquipSlot do
		local itemSlot = Components.ItemSlot.new({
			Size = SLOT_SIZE,
			Name = `Inspect_{slot}`,
			Placeholder = Icons.ForSlot(slot),
			LayoutOrder = order,
			Parent = grid,
		})
		Components.Tooltip.Attach(itemSlot.Instance, function(): Components.TooltipContent?
			return slotTooltip(slot)
		end)
		itemSlot.Activated:Connect(function()
			-- A tap shows the tooltip too (touch has no hover).
			local content = slotTooltip(slot)
			if content then
				Components.Tooltip.Show(content, itemSlot.Instance, itemSlot.Instance)
			end
		end)
		slots[slot] = itemSlot
	end

	Components.IconButton.new({
		Icon = "Close",
		Size = UITheme.Size.MinTouchTarget,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 8, 0, -8),
		Parent = inner,
		OnActivated = function()
			InspectController.CloseCard()
		end,
	})

	return {
		Panel = panel,
		Name = name,
		Handle = handle,
		TitleLabel = title,
		Level = level,
		PositionLabel = positionLabel,
		CompanyLabel = company,
		Slots = slots,
	}
end

local function showCard(payload: Payload)
	local c = card
	if not c then
		return
	end
	current = payload
	c.Name.Text = payload.DisplayName
	c.Handle.Text = if payload.DisplayName ~= payload.Name then `@{payload.Name}` else ""
	local title = QuestText.TitleFromPath(payload.Title)
	c.TitleLabel.Text = title or ""
	c.TitleLabel.Visible = title ~= nil
	c.Level.Text = Strings.Format(S.Level, { level = payload.Level })
	local def = if payload.Position ~= "" then Positions.Get(payload.Position) else nil
	if def then
		c.PositionLabel.Text = `<font color="#{def.Color:ToHex()}">{ProgressionText.PositionName(def.Id)}</font>`
	else
		c.PositionLabel.Text = `<font color="#{C.TextDim:ToHex()}">{S.NoPosition}</font>`
	end
	c.CompanyLabel.Text = if payload.Company ~= "" then Strings.Format(S.Company, { name = payload.Company }) else ""
	c.CompanyLabel.Visible = payload.Company ~= ""
	for slot, itemSlot in c.Slots do
		local item = payload.Gear[slot]
		itemSlot:SetItem(if item then ItemText.Slot(item) else nil)
	end
	c.Panel.Visible = true
end

function InspectController.CloseCard()
	local c = card
	if c then
		c.Panel.Visible = false
	end
	current = nil
	Components.Tooltip.Hide()
end

-- REQUESTS ---------------------------------------------------------------------------------------

-- Asks the server for `target`'s gear. Checks reach and the cooldown here first so the player
-- gets a reason instead of silence.
function InspectController.Request(target: Player)
	if target == localPlayer then
		return
	end
	local distance = distanceTo(target)
	if not distance or distance > Config.Social.Inspect.MaxDistance then
		toast(S.TooFar)
		return
	end
	if os.clock() - lastRequest < Config.Social.Inspect.Cooldown then
		toast(S.Cooldown)
		return
	end
	lastRequest = os.clock()
	pendingName = target.DisplayName
	Net.FireServer("RequestInspect", target.UserId)
end

local function onResult(userId: any, payload: any)
	if type(payload) ~= "table" or type(payload.Gear) ~= "table" then
		toast(Strings.Format(S.Unavailable, { name = if pendingName ~= "" then pendingName else "?" }))
		return
	end
	if payload.UserId ~= userId then
		return
	end
	showCard(payload :: Payload)
end

-- THE STRIP --------------------------------------------------------------------------------------

function InspectController.CloseStrip()
	stripTarget = nil
	stripMaid:Clean()
	local s = strip
	if s then
		s.Panel.Visible = false
	end
end

local function placeStrip()
	local s, target = strip, stripTarget
	local camera = Workspace.CurrentCamera
	if not s or not target or not camera then
		return
	end
	local root = rootOf(target.Character)
	local distance = distanceTo(target)
	if not root or not distance or distance > Config.Social.Inspect.MaxDistance + RAY_EXTRA then
		InspectController.CloseStrip()
		return
	end
	local point, onScreen = camera:WorldToViewportPoint(root.Position + Vector3.new(0, 2, 0))
	if not onScreen then
		InspectController.CloseStrip()
		return
	end
	local layerPoint = Layers.ToLayerSpace("Overlay", Vector2.new(point.X, point.Y))
	local viewport = Layers.ToLayerSpace("Overlay", camera.ViewportSize)
	local size = s.Panel.AbsoluteSize / Layers.GetScale("Overlay")
	local x = math.clamp(layerPoint.X + 48, 8, math.max(8, viewport.X - size.X - 8))
	local y = math.clamp(layerPoint.Y - size.Y / 2, 8, math.max(8, viewport.Y - size.Y - 8))
	s.Panel.Position = UDim2.fromOffset(x, y)
end

local function buildStrip(): Strip
	local height = 36 + 3 * (BUTTON_HEIGHT + 6) + UITheme.Padding.Medium * 2 - 6
	local panel: Frame = Create.new("Frame", {
		Name = "InspectStrip",
		Size = UDim2.fromOffset(STRIP_WIDTH, height),
		Visible = false,
		Parent = Layers.Get("Overlay"),
	})
	Create.ApplyPanelStyle(panel)
	local inner: Frame = Create.new("Frame", {
		Name = "Inner",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = panel,
	})
	Create.Padding(inner, UITheme.Padding.Medium)
	local name = Create.Label({
		Name = "Name",
		Text = "",
		Font = UITheme.Fonts.BodyBold,
		Color = C.Foam,
		Size = UDim2.new(1, 0, 0, 30),
		Parent = inner,
	})
	local function button(text: string, order: number, onActivated: () -> ()): Components.Button
		return Components.Button.new({
			Text = text,
			Variant = "Secondary",
			Size = UDim2.new(1, 0, 0, BUTTON_HEIGHT),
			Position = UDim2.fromOffset(0, 36 + (order - 1) * (BUTTON_HEIGHT + 6)),
			Parent = inner,
			OnActivated = onActivated,
		})
	end
	local inspectButton = button(S.Inspect, 1, function()
		local target = stripTarget
		if target then
			InspectController.Request(target)
		end
	end)
	local inviteButton = button(S.InviteParty, 2, function()
		local target = stripTarget
		local controller = optional("PartyController")
		if target and controller and type(controller.Invite) == "function" then
			controller.Invite(target.UserId)
		end
		InspectController.CloseStrip()
	end)
	local tradeButton = button(S.Trade, 3, function()
		local target = stripTarget
		local controller = optional("TradeController")
		if target and controller and type(controller.RequestTrade) == "function" then
			controller.RequestTrade(target.UserId)
		end
		InspectController.CloseStrip()
	end)
	return { Panel = panel, Name = name, Inspect = inspectButton, Invite = inviteButton, Trade = tradeButton }
end

local function openStrip(target: Player)
	local s = strip
	if not s then
		return
	end
	stripMaid:Clean()
	stripTarget = target
	s.Name.Text = target.DisplayName
	s.Invite:SetEnabled(canInvite())
	s.Trade:SetEnabled(canTrade())
	s.Panel.Visible = true
	placeStrip()
	stripMaid:Add(RunService.RenderStepped:Connect(placeStrip))
	stripMaid:Add(target.AncestryChanged:Connect(function()
		if not target:IsDescendantOf(Players) then
			InspectController.CloseStrip()
		end
	end))
end

-- CLICKS -----------------------------------------------------------------------------------------

-- The other player whose character is under `screen`, if the first thing the ray meets is one.
local function playerAt(screen: Vector2): Player?
	local camera = Workspace.CurrentCamera
	if not camera then
		return nil
	end
	local ray = camera:ScreenPointToRay(screen.X, screen.Y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local own = localPlayer.Character
	params.FilterDescendantsInstances = if own then { own } else {}
	local result = Workspace:Raycast(ray.Origin, ray.Direction * (Config.Social.Inspect.MaxDistance + RAY_EXTRA + 60), params)
	if not result then
		return nil
	end
	local model = result.Instance:FindFirstAncestorOfClass("Model")
	while model do
		local owner = Players:GetPlayerFromCharacter(model)
		if owner then
			return if owner ~= localPlayer then owner else nil
		end
		model = model:FindFirstAncestorOfClass("Model")
	end
	return nil
end

local function clickable(): boolean
	local humanoid = if localPlayer.Character then localPlayer.Character:FindFirstChildOfClass("Humanoid") else nil
	return humanoid ~= nil
		and humanoid.Health > 0
		and InputController.GetContext() == "Gameplay"
		and not UIController.IsMenuOpen()
end

local function onInputBegan(input: InputObject, gameProcessed: boolean)
	local kind = input.UserInputType
	if kind ~= Enum.UserInputType.MouseButton1 and kind ~= Enum.UserInputType.Touch then
		return
	end
	if gameProcessed or not clickable() then
		press = nil
		return
	end
	-- With the cursor locked a click is an attack, not a pick.
	if kind == Enum.UserInputType.MouseButton1 and UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter then
		press = nil
		return
	end
	press = { Input = input, At = Vector2.new(input.Position.X, input.Position.Y), Time = os.clock() }
end

local function onInputEnded(input: InputObject)
	local started = press
	if not started or started.Input ~= input then
		return
	end
	press = nil
	local at = Vector2.new(input.Position.X, input.Position.Y)
	if (at - started.At).Magnitude > TAP_MAX_MOVE or os.clock() - started.Time > TAP_MAX_TIME then
		return
	end
	local target = playerAt(at)
	if target then
		openStrip(target)
	elseif stripTarget then
		InspectController.CloseStrip()
	end
end

-- LIFECYCLE --------------------------------------------------------------------------------------

function InspectController.Init()
	Net.OnClient("InspectResult", onResult)
end

function InspectController.Start()
	card = buildCard()
	strip = buildStrip()
	UserInputService.InputBegan:Connect(onInputBegan)
	UserInputService.InputEnded:Connect(onInputEnded)
	UIController.MenuOpened:Connect(function()
		InspectController.CloseStrip()
		InspectController.CloseCard()
	end)
	Players.PlayerRemoving:Connect(function(who: Player)
		if stripTarget == who then
			InspectController.CloseStrip()
		end
		if current and current.UserId == who.UserId then
			InspectController.CloseCard()
		end
	end)
	localPlayer.CharacterAdded:Connect(function()
		InspectController.CloseStrip()
	end)
end

return InspectController
