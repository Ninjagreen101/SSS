--!strict
--[[
	SpellbookController
	The Spellbook menu (K, or the menu hub on touch / gamepad), Spec Section 12:

	  Primary / Secondary  one tab per Attunement: a card for each Form with
	                       an animated preview in the element's colour, its
	                       description, cost, cooldown, cast time / charge and
	                       scaling; Forms you haven't reached are locked.
	  Arts                 the equipped weapon's Weapon Art, Infusion, and the
	                       weapon's five Confluences (yours highlighted).
	  Beacons              each Beacon slot with its behaviour; locked slots
	                       say how much Control opens them.

	Hotbar strip along the bottom: drag a spell card onto a slot, or select a
	card (click / tap / A) and then a slot. Changes go to the server as
	RequestEquipSpell / RequestSetBeacon; the menu redraws from the replicated
	profile when the server confirms.
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Attributes = require(Shared.Attributes)
local Strings = require(Shared.Strings)
local Net = require(Shared.Net)
local Maid = require(Shared.Util.Maid)
local Spells = require(Shared.Data.Spells)
local Formulas = require(Shared.Data.Formulas)
local GearStats = require(Shared.Data.GearStats)
local Arts = require(Shared.Data.Arts)
local Confluences = require(Shared.Data.Confluences)

local UI = script.Parent.Parent.UI
local UITheme = require(UI.UITheme)
local Create = require(UI.Create)
local Layers = require(UI.Layers)
local Animator = require(UI.Animator)
local Components = require(UI.Components)

local DataController = require(script.Parent.DataController)
local InputController = require(script.Parent.InputController)
local UIController = require(script.Parent.UIController)

local A = Attributes.Names
local S = Strings.Spellbook
local C = Config.Current
local player = Players.LocalPlayer

local SpellbookController = {}

local MENU_ID = "Spellbook"
local CARD_SIZE = Vector2.new(250, 190)
local HOTBAR_HEIGHT = 92
local DRAG_THRESHOLD = 8

type Pages = { [string]: Components.ScrollList }

local pages: Pages = {}
local pageMaid = Maid.new()
local hotbarSlots: { TextButton } = {}
local hintLabel: TextLabel? = nil
local selected: string? = nil
local isOpen = false
local cardStrokes: { [string]: { Stroke: UIStroke, Color: Color3 } } = {}

-- DATA ---------------------------------------------------------------------------

local function data(path: { string }): any
	return DataController.Get(path)
end

local function attunements(): (string, string)
	local primary = data({ "Attunements", "Primary" })
	local secondary = data({ "Attunements", "Secondary" })
	return if type(primary) == "string" then primary else "", if type(secondary) == "string" then secondary else ""
end

local function knownForms(): { string }
	local list = data({ "Attunements", "UnlockedForms" })
	return if type(list) == "table" then list else {}
end

local function control(): number
	local value = data({ "Stats", "Control" })
	return if type(value) == "number" then value else 0
end

local function hotbar(): { string }
	local list = data({ "Hotbar", "Spells" })
	return if type(list) == "table" then list else { "", "", "", "" }
end

local function seconds(value: number): string
	return string.format("%.1f", value)
end

-- HOTBAR STRIP -------------------------------------------------------------------

local function refreshHotbar()
	local list = hotbar()
	for index, button in hotbarSlots do
		local spell = Spells.Get(list[index] or "")
		local form = spell and Strings.Forms[spell.Form]
		button.Text = if spell and form then form.Name else Strings.SpellUI.Empty
		button.TextColor3 = if spell then spell.Element.Color:Lerp(UITheme.Colors.Text, 0.35) else UITheme.Colors.TextDim
		local stroke = button:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Color = if selected then UITheme.Colors.Foam elseif spell then spell.Element.Color else UITheme.Colors.Edge
		end
	end
	for spellId, card in cardStrokes do
		card.Stroke.Color = if spellId == selected then UITheme.Colors.Parry else card.Color
		card.Stroke.Thickness = if spellId == selected then 3 else 2
	end
	local hint = hintLabel
	if hint then
		local spell = if selected then Spells.Get(selected) else nil
		local form = spell and Strings.Forms[spell.Form]
		hint.Text = if spell and form then Strings.Format(S.Selected, { spell = form.Name }) else S.HotbarHint
	end
end

local function equip(slot: number, spellId: string)
	Net.FireServer("RequestEquipSpell", slot, spellId)
	selected = nil
	refreshHotbar()
end

local function select(spellId: string)
	selected = if selected == spellId then nil else spellId
	refreshHotbar()
end

-- Which hotbar slot (if any) is under a screen point.
local function slotAt(point: Vector2): number?
	for index, button in hotbarSlots do
		local position, size = button.AbsolutePosition, button.AbsoluteSize
		if point.X >= position.X and point.X <= position.X + size.X and point.Y >= position.Y and point.Y <= position.Y + size.Y then
			return index
		end
	end
	return nil
end

local function buildHotbar(content: Frame)
	local frame: Frame = Create.new("Frame", {
		Name = "Hotbar",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, HOTBAR_HEIGHT),
		BackgroundColor3 = UITheme.Colors.PanelSunken,
		BackgroundTransparency = 0.2,
		Parent = content,
	})
	Create.Corner(frame, UITheme.CornerSmall)
	Create.Label({
		Text = S.Hotbar,
		Font = UITheme.Fonts.BodyBold,
		Position = UDim2.fromOffset(12, 6),
		Size = UDim2.fromOffset(120, 20),
		Parent = frame,
	})
	hintLabel = Create.Label({
		Text = S.HotbarHint,
		Color = UITheme.Colors.TextMuted,
		TextSize = UITheme.TextSize.Small,
		Position = UDim2.fromOffset(12, 28),
		Size = UDim2.new(0.45, 0, 0, 48),
		Wrapped = true,
		YAlignment = Enum.TextYAlignment.Top,
		Parent = frame,
	})
	for index = 1, 4 do
		local button: TextButton = Create.new("TextButton", {
			Name = `Slot{index}`,
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -12 - (4 - index) * 98, 0.5, 0),
			Size = UDim2.fromOffset(88, 64),
			BackgroundColor3 = UITheme.Colors.Panel,
			AutoButtonColor = false,
			FontFace = UITheme.Fonts.BodyBold,
			TextSize = 15,
			TextWrapped = true,
			Text = "",
			SelectionImageObject = Create.SelectionImage(),
			Parent = frame,
		})
		Create.Corner(button, UITheme.CornerSmall)
		Create.Stroke(button, UITheme.Colors.Edge, 2, 0.1)
		Create.Label({
			Text = tostring(index),
			Color = UITheme.Colors.TextMuted,
			TextSize = 12,
			Position = UDim2.fromOffset(5, 2),
			Size = UDim2.fromOffset(14, 14),
			Parent = button,
		})
		button.Activated:Connect(function()
			local spellId = selected
			if spellId then
				equip(index, spellId)
			end
		end)
		hotbarSlots[index] = button
	end
end

-- FORM CARDS ---------------------------------------------------------------------

-- A small looping animation of what the Form does, in the element's colour.
local function preview(parent: GuiObject, form: string, color: Color3, maid: Maid.Maid)
	local box: Frame = Create.new("Frame", {
		Name = "Preview",
		Position = UDim2.fromOffset(10, 10),
		Size = UDim2.new(1, -20, 0, 54),
		BackgroundColor3 = UITheme.Colors.PanelSunken,
		ClipsDescendants = true,
		Parent = parent,
	})
	Create.Corner(box, UITheme.CornerSmall)
	local function shape(size: UDim2, round: boolean): Frame
		local frame: Frame = Create.new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Size = size,
			BackgroundColor3 = color,
			BorderSizePixel = 0,
			Parent = box,
		})
		if round then
			Create.Corner(frame, UITheme.CornerPill)
		end
		return frame
	end
	local caster = shape(UDim2.fromOffset(10, 10), true)
	caster.Position = UDim2.fromScale(0.12, 0.5)
	caster.BackgroundColor3 = UITheme.Colors.Text
	local a = shape(UDim2.fromOffset(10, 10), true)
	local b = shape(UDim2.fromOffset(4, 4), false)
	maid:Add(Animator.Add(function(time: number)
		local t = (time % 1.4) / 1.4
		if form == "Bolt" then
			a.Size = UDim2.fromOffset(10, 10)
			a.Position = UDim2.fromScale(0.15 + t * 0.8, 0.5)
			b.Visible = false
		elseif form == "Wave" then
			a.Size = UDim2.fromOffset(6, 10 + t * 40)
			a.Position = UDim2.fromScale(0.2 + t * 0.5, 0.5)
			a.BackgroundTransparency = t
			b.Visible = false
		elseif form == "Ward" then
			a.Size = UDim2.fromOffset(18 + math.sin(time * 4) * 6, 18 + math.sin(time * 4) * 6)
			a.Position = UDim2.fromScale(0.12, 0.5)
			a.BackgroundTransparency = 0.5
			b.Visible = false
		elseif form == "Lance" then
			local charge = math.clamp(t * 1.6, 0, 1)
			a.Size = UDim2.new(if t > 0.62 then 0.8 else 0.02, 0, 0, if t > 0.62 then 6 else 2 + charge * 6)
			a.Position = UDim2.new(0.15 + (if t > 0.62 then 0.4 else 0), 0, 0.5, 0)
			a.BackgroundTransparency = if t > 0.62 then (t - 0.62) * 2.5 else 0
			b.Visible = false
		elseif form == "Well" then
			local pulse = (time * 1.2) % 1
			a.Size = UDim2.fromOffset(20 + pulse * 40, 8 + pulse * 14)
			a.Position = UDim2.fromScale(0.65, 0.6)
			a.BackgroundTransparency = pulse
			b.Visible = true
			b.Size = UDim2.fromOffset(20, 8)
			b.Position = UDim2.fromScale(0.65, 0.6)
		else -- Step
			local x = if t < 0.5 then 0.12 else 0.75
			caster.Position = UDim2.fromScale(x, 0.5)
			a.Size = UDim2.new(0.63 * (1 - math.clamp((t - 0.5) * 3, 0, 1)), 0, 0, 3)
			a.Position = UDim2.fromScale(0.435, 0.5)
			a.Visible = t >= 0.5
			b.Visible = false
		end
	end))
end

local function line(parent: Instance, text: string, order: number, color: Color3?, size: number?)
	Create.Label({
		Text = text,
		Color = color or UITheme.Colors.TextMuted,
		TextSize = size or UITheme.TextSize.Small,
		Wrapped = true,
		YAlignment = Enum.TextYAlignment.Top,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, 0, 0, 0),
		LayoutOrder = order,
		Parent = parent,
	})
end

local function startDrag(spellId: string, color: Color3, input: InputObject, maid: Maid.Maid)
	local origin = Vector2.new(input.Position.X, input.Position.Y)
	local ghost: Frame? = nil
	local moveConnection: RBXScriptConnection? = nil
	local endConnection: RBXScriptConnection? = nil
	local function cleanup()
		if moveConnection then
			moveConnection:Disconnect()
		end
		if endConnection then
			endConnection:Disconnect()
		end
		if ghost then
			ghost:Destroy()
			ghost = nil
		end
	end
	moveConnection = UserInputService.InputChanged:Connect(function(changed: InputObject)
		if changed.UserInputType ~= Enum.UserInputType.MouseMovement and changed ~= input then
			return
		end
		local point = Vector2.new(changed.Position.X, changed.Position.Y)
		if not ghost and (point - origin).Magnitude >= DRAG_THRESHOLD then
			local created: Frame = Create.new("Frame", {
				Name = "DragGhost",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Size = UDim2.fromOffset(80, 40),
				BackgroundColor3 = color,
				BackgroundTransparency = 0.4,
				ZIndex = 100,
				Parent = Layers.Get("Tooltip"),
			})
			Create.Corner(created, UITheme.CornerSmall)
			ghost = created
		end
		local g = ghost
		if g then
			-- Input positions exclude the top-bar inset; the Tooltip layer ignores it.
			local inset = GuiService:GetGuiInset()
			local at = Layers.ToLayerSpace("Tooltip", point + inset)
			g.Position = UDim2.fromOffset(at.X, at.Y)
		end
	end)
	endConnection = UserInputService.InputEnded:Connect(function(ended: InputObject)
		if ended.UserInputType ~= Enum.UserInputType.MouseButton1 and ended ~= input then
			return
		end
		if ghost then
			local slot = slotAt(Vector2.new(ended.Position.X, ended.Position.Y))
			if slot then
				equip(slot, spellId)
			end
		end
		cleanup()
	end)
	maid:Add(cleanup)
end

local function formCard(parent: Instance, attunement: string, form: string, order: number, maid: Maid.Maid)
	local spell = Spells.Get(Spells.Id(attunement, form))
	if not spell then
		return
	end
	local shape = spell.Shape
	local known = table.find(knownForms(), form) ~= nil
	local strings = Strings.Forms[form]
	local color = spell.Element.Color
	local card: TextButton = Create.new("TextButton", {
		Name = form,
		LayoutOrder = order,
		Size = UDim2.fromOffset(CARD_SIZE.X, CARD_SIZE.Y),
		BackgroundColor3 = UITheme.Colors.PanelRaised,
		AutoButtonColor = false,
		Text = "",
		Active = known,
		Selectable = known,
		SelectionImageObject = Create.SelectionImage(),
		Parent = parent,
	})
	Create.Corner(card, UITheme.CornerSmall)
	local stroke = Create.Stroke(card, color, 2, if known then 0.15 else 0.7)
	if known then
		cardStrokes[spell.Id] = { Stroke = stroke, Color = color }
	end
	preview(card, form, color, maid)
	local body: Frame = Create.new("Frame", {
		Name = "Body",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(10, 70),
		Size = UDim2.new(1, -20, 1, -76),
		Parent = card,
	})
	Create.List(body, Enum.FillDirection.Vertical, 2)
	Create.Label({
		Text = if strings then strings.Name else form,
		Font = UITheme.Fonts.Title,
		TextSize = 18,
		Color = color,
		LayoutOrder = 1,
		Parent = body,
	})
	if known then
		line(body, if strings then strings.Description else "", 2, UITheme.Colors.Text)
		local cost = shape.Cost * Formulas.SpellCost(control())
		local details = {
			Strings.Format(S.Cost, { cost = math.floor(cost + 0.5) }),
			Strings.Format(S.Cooldown, { seconds = seconds(shape.Cooldown) }),
		}
		if shape.Charge then
			table.insert(details, Strings.Format(S.Charge, { seconds = seconds(shape.Charge.Max) }))
		elseif shape.CastTime > 0 then
			table.insert(details, Strings.Format(S.CastTime, { seconds = seconds(shape.CastTime) }))
		end
		line(body, table.concat(details, "  ·  "), 3)
		line(body, S.Scaling, 4, UITheme.Colors.TextDim)
	else
		line(body, Strings.Format(S.UnlocksAt, { level = shape.UnlockLevel }), 2, UITheme.Colors.TextDim)
		card.BackgroundTransparency = 0.4
	end
	if not known then
		return
	end
	card.Activated:Connect(function()
		select(spell.Id)
	end)
	card.InputBegan:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			startDrag(spell.Id, color, input, maid)
		end
	end)
end

local function message(parent: Instance, text: string)
	Create.Label({
		Text = text,
		Color = UITheme.Colors.TextMuted,
		Wrapped = true,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, -24, 0, 0),
		Parent = parent,
	})
end

local function fillAttunement(page: Components.ScrollList, attunement: string, unlockLevel: number, maid: Maid.Maid)
	local container = page.Instance
	if attunement == "" then
		local text = if unlockLevel == C.Attunement.PrimaryLevel
			then Strings.Format(S.NotAttuned, { level = unlockLevel })
			else Strings.Format(S.LockedTab, { level = unlockLevel })
		message(container, text)
		return
	end
	local info = Strings.Attunements[attunement]
	local element = Spells.Attunement(attunement)
	Create.Label({
		Text = if info then `{info.Name} — {info.Description}` else attunement,
		Color = if element then element.Color else UITheme.Colors.Text,
		Wrapped = true,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, -24, 0, 0),
		LayoutOrder = 0,
		Parent = container,
	})
	local grid: Frame = Create.new("Frame", {
		Name = "Cards",
		BackgroundTransparency = 1,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, -12, 0, 0),
		LayoutOrder = 1,
		Parent = container,
	})
	Create.new("UIGridLayout", {
		CellSize = UDim2.fromOffset(CARD_SIZE.X, CARD_SIZE.Y),
		CellPadding = UDim2.fromOffset(12, 12),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = grid,
	})
	for order, form in Spells.FormsByLevel() do
		formCard(grid, attunement, form, order, maid)
	end
end

-- ARTS PAGE ----------------------------------------------------------------------

local function infoBlock(parent: Instance, title: string, body: string, color: Color3, order: number)
	local block: Frame = Create.new("Frame", {
		Name = title,
		BackgroundColor3 = UITheme.Colors.PanelRaised,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, -12, 0, 0),
		LayoutOrder = order,
		Parent = parent,
	})
	Create.Corner(block, UITheme.CornerSmall)
	Create.Stroke(block, color, 1.5, 0.3)
	Create.Padding(block, UITheme.Padding.Medium)
	Create.List(block, Enum.FillDirection.Vertical, 4)
	Create.Label({ Text = title, Font = UITheme.Fonts.Title, TextSize = 17, Color = color, LayoutOrder = 1, Parent = block })
	line(block, body, 2, UITheme.Colors.Text)
end

local function fillArts(page: Components.ScrollList)
	local container = page.Instance
	local character = player.Character
	local class = character and character:GetAttribute(A.WeaponClass)
	if type(class) ~= "string" then
		return
	end
	local key = InputController.GetPrompt("WeaponArt")
	local art = Arts.ForClass(class)
	local artStrings = Strings.Arts[class]
	if art and artStrings then
		local details = `{artStrings.Description}\n{Strings.Format(S.Cost, { cost = art.Cost })}  ·  {Strings.Format(S.Cooldown, { seconds = seconds(art.Cooldown) })}`
		infoBlock(container, `{S.WeaponArt}: {artStrings.Name}`, details, UITheme.Colors.Text, 1)
	end
	local primary = attunements()
	local element = if primary ~= "" then Spells.Attunement(primary) else nil
	if primary ~= "" and element then
		local elementName = Strings.Attunements[primary]
		infoBlock(container, S.Infusion, Strings.Format(S.InfusionBody, {
			key = key,
			element = if elementName then elementName.Name else primary,
			seconds = C.Infusion.Duration,
			status = Strings.Statuses[element.Status] or element.Status,
			cost = C.Infusion.Cost,
		}), element.Color, 2)
	else
		infoBlock(container, S.Infusion, S.InfusionLocked, UITheme.Colors.TextMuted, 2)
	end
	infoBlock(container, S.ConfluenceTitle, Strings.Format(S.ConfluenceBody, {
		key = key,
		cost = C.Confluence.CurrentCost,
		seconds = C.Confluence.Cooldown,
	}), UITheme.Colors.Parry, 3)
	for order, attunement in { "Tide", "Rime", "Tempest", "Abyss", "Bloom" } do
		local confluence = Confluences.Get(class, attunement)
		local strings = confluence and Strings.Confluences[confluence.Id]
		local def = Spells.Attunement(attunement)
		if strings and def then
			local mine = attunement == primary
			local title = if mine then `{strings.Name}  ({S.YourConfluence})` else strings.Name
			infoBlock(container, title, strings.Description, if mine then def.Color else UITheme.Colors.TextDim, 3 + order)
		end
	end
end

-- BEACONS PAGE -------------------------------------------------------------------

local function fillBeacons(page: Components.ScrollList)
	local container = page.Instance
	local primary = attunements()
	if primary == "" then
		message(container, S.BeaconLocked)
		return
	end
	local B = C.Beacons
	-- Same count as BeaconService.SlotCount: Control with gear and tree, plus
	-- the Beaconkeeper tree's extra slots.
	local profile = DataController.GetData()
	local summary = if profile then GearStats.Summarize(profile) else nil
	local unlocked = if summary
		then math.min(B.MaxSlots, Formulas.BeaconSlots(summary.Stats.Control) + math.floor(summary.Bonuses.BeaconSlots or 0))
		else Formulas.BeaconSlots(control())
	Create.Label({
		Text = Strings.Format(S.BeaconSlots, { count = unlocked, max = B.MaxSlots }),
		Font = UITheme.Fonts.BodyBold,
		LayoutOrder = 0,
		Parent = container,
	})
	local slots = data({ "Beacons", "Slots" })
	local element = Spells.Attunement(primary)
	local color = if element then element.Color else UITheme.Colors.Current
	for slot = 1, B.MaxSlots do
		local row: Frame = Create.new("Frame", {
			Name = `Beacon{slot}`,
			BackgroundColor3 = UITheme.Colors.PanelRaised,
			Size = UDim2.new(1, -12, 0, 96),
			LayoutOrder = slot,
			Parent = container,
		})
		Create.Corner(row, UITheme.CornerSmall)
		Create.Padding(row, UITheme.Padding.Medium)
		Create.Label({
			Text = Strings.Format(S.BeaconSlot, { slot = slot }),
			Font = UITheme.Fonts.BodyBold,
			Size = UDim2.fromOffset(80, 22),
			Parent = row,
		})
		if slot > unlocked then
			local threshold = B.ControlThresholds[slot - B.StartSlots]
			Create.Label({
				Text = Strings.Format(S.BeaconSlotLocked, { points = threshold or "?" }),
				Color = UITheme.Colors.TextDim,
				TextSize = UITheme.TextSize.Small,
				Position = UDim2.fromOffset(90, 0),
				Size = UDim2.new(1, -90, 0, 22),
				Parent = row,
			})
			row.Size = UDim2.new(1, -12, 0, 48)
			row.BackgroundTransparency = 0.5
		else
			local current = if type(slots) == "table" and type(slots[slot]) == "string" then slots[slot] else ""
			local strip: Frame = Create.new("Frame", {
				BackgroundTransparency = 1,
				Position = UDim2.fromOffset(90, 0),
				Size = UDim2.new(1, -90, 0, 36),
				Parent = row,
			})
			Create.List(strip, Enum.FillDirection.Horizontal, 6)
			for order, behaviour in { "", "Sentry", "Aegis", "Lantern", "Relay" } do
				local info = Strings.Beacons[behaviour]
				Components.Button.new({
					Text = if info then info.Name else S.BeaconEmpty,
					Variant = if behaviour == current then "Primary" else "Secondary",
					Size = UDim2.fromOffset(104, 34),
					LayoutOrder = order,
					Parent = strip,
					OnActivated = function()
						Net.FireServer("RequestSetBeacon", slot, behaviour)
					end,
				})
			end
			local info = Strings.Beacons[current]
			Create.Label({
				Text = if info then info.Description else S.BeaconEmpty,
				Color = if info then color else UITheme.Colors.TextDim,
				TextSize = UITheme.TextSize.Small,
				Wrapped = true,
				Position = UDim2.fromOffset(90, 42),
				Size = UDim2.new(1, -90, 0, 30),
				YAlignment = Enum.TextYAlignment.Top,
				Parent = row,
			})
		end
	end
end

-- BUILD / REFRESH ----------------------------------------------------------------

local function clearPages()
	pageMaid:Clean()
	table.clear(cardStrokes)
	for _, page in pages do
		for _, child in page.Instance:GetChildren() do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
	end
end

local function refresh()
	if not isOpen then
		return
	end
	clearPages()
	local primary, secondary = attunements()
	fillAttunement(pages.Primary, primary, C.Attunement.PrimaryLevel, pageMaid)
	fillAttunement(pages.Secondary, secondary, C.Attunement.SecondaryLevel, pageMaid)
	fillArts(pages.Arts)
	fillBeacons(pages.Beacons)
	refreshHotbar()
end

local function build(content: Frame, maid: Maid.Maid): any
	local tabBar = Components.TabBar.new({
		Tabs = {
			{ Id = "Primary", Text = S.Primary },
			{ Id = "Secondary", Text = S.Secondary },
			{ Id = "Arts", Text = S.TabArts },
			{ Id = "Beacons", Text = S.TabBeacons },
		},
		Parent = content,
	})
	maid:Add(tabBar)
	local top = UITheme.Size.TabHeight + UITheme.Padding.Medium
	for _, id in { "Primary", "Secondary", "Arts", "Beacons" } do
		local page = Components.ScrollList.new({
			Name = id,
			Position = UDim2.fromOffset(0, top),
			Size = UDim2.new(1, 0, 1, -(top + HOTBAR_HEIGHT + UITheme.Padding.Medium)),
			Spacing = UITheme.Padding.Small,
			Parent = content,
		})
		page.Instance.Visible = id == "Primary"
		pages[id] = page
		maid:Add(page)
	end
	tabBar.Changed:Connect(function(id: string)
		for pageId, page in pages do
			page.Instance.Visible = pageId == id
		end
	end)
	buildHotbar(content)
	return {
		TabBar = tabBar,
		OnOpen = function()
			isOpen = true
			selected = nil
			refresh()
		end,
		OnClose = function()
			isOpen = false
			selected = nil
			clearPages()
		end,
	}
end

function SpellbookController.Init()
	UIController.RegisterMenu({
		Id = MENU_ID,
		Title = S.Title,
		Action = "OpenSpellbook",
		FullScreen = true,
		ShowInHub = true,
		Icon = "Current",
		Nav = "Journal",
		Build = build,
	})
end

function SpellbookController.Start()
	for _, path in { { "Hotbar", "Spells" }, { "Attunements" }, { "Beacons" }, { "Stats" }, { "Level" } } do
		DataController.Observe(path, function()
			refresh()
		end)
	end
	-- The Arts page follows the equipped weapon.
	local function bind(character: Model)
		character:GetAttributeChangedSignal(A.WeaponClass):Connect(refresh)
	end
	player.CharacterAdded:Connect(bind)
	if player.Character then
		bind(player.Character)
	end
end

return SpellbookController
