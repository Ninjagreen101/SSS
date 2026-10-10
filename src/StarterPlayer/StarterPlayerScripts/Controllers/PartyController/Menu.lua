--!strict
--[[
	Menu
	The Party menu (P, also in the menu hub) with three tabs:
	- Members: everyone in your party with level, health and Current (live while open), the
	  leader's mark, loot mode, and the leader's controls (promote, kick, raid, disband). Leave.
	- Invite: climbers nearby (Social.Party.InviteRadius) and a name search over everyone on
	  this server, each with an Invite button.
	- Finder: the server's Party Finder board, filtered by activity, with Ask to Join; post,
	  update or remove your own listing with an activity and a note. While this tab is open it
	  re-sends Refresh so the server keeps pushing board updates (Social.Finder.WatchSeconds).
	Everything is a request; the server checks every rule and answers with PartyState /
	FinderListings / Notify.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Strings = require(Shared.Strings)
local Net = require(Shared.Net)
local Maid = require(Shared.Util.Maid)
local Attributes = require(Shared.Attributes)

local UI = script.Parent.Parent.Parent.UI
local UITheme = require(UI.UITheme)
local Create = require(UI.Create)
local Components = require(UI.Components)
local Animator = require(UI.Animator)

local State = require(script.Parent.State)

local A = Attributes.Names
local C = UITheme.Colors
local S = Strings.Party
local F = Strings.Finder
local SP = Config.Social.Party
local SF = Config.Social.Finder
local localPlayer = Players.LocalPlayer

local MENU_ID = "Party"
local TOUCH = Config.Input.MinTouchTarget
local ROW_HEIGHT = 60
local MAX_SEARCH = 40

type MemberRow = { Player: Player?, Health: Frame, Current: Frame, Level: TextLabel }

local Menu = {}
Menu.Id = MENU_ID

local function send(action: string, arg: string)
	Net.FireServer("RequestParty", action, arg)
end

local function label(text: string, props: { [string]: any }?): TextLabel
	local made = Create.Label({ Text = text })
	if props then
		for key, value in props do
			(made :: any)[key] = value
		end
	end
	return made
end

local function row(parent: Instance, height: number, order: number): Frame
	local frame: Frame = Create.new("Frame", {
		Name = "Row",
		BackgroundColor3 = C.PanelRaised,
		BackgroundTransparency = 0.3,
		Size = UDim2.new(1, -8, 0, height),
		LayoutOrder = order,
		Parent = parent,
	})
	Create.Corner(frame, UITheme.CornerSmall)
	Create.Padding(frame, 0, UITheme.Padding.Medium, 0)
	return frame
end

local function bar(parent: Instance, position: UDim2, size: UDim2, color: Color3): Frame
	local track: Frame = Create.new("Frame", {
		BackgroundColor3 = C.Track,
		BorderSizePixel = 0,
		Position = position,
		Size = size,
		Parent = parent,
	})
	Create.Corner(track, UDim.new(0, 2))
	local fill: Frame = Create.new("Frame", { BackgroundColor3 = color, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), Parent = track })
	Create.Corner(fill, UDim.new(0, 2))
	return fill
end

local function button(parent: Instance, text: string, variant: ("Primary" | "Secondary" | "Danger")?, width: number, order: number, onClick: () -> (), enabled: boolean?): Components.Button
	return Components.Button.new({
		Text = text,
		Variant = variant or "Secondary",
		Size = UDim2.fromOffset(width, TOUCH),
		LayoutOrder = order,
		Enabled = enabled,
		TextSize = UITheme.TextSize.Small,
		Parent = parent,
		OnActivated = onClick,
	})
end

local function hRow(parent: Instance, height: number, order: number, align: Enum.HorizontalAlignment?): Frame
	local frame: Frame = Create.new("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, height),
		LayoutOrder = order,
		Parent = parent,
	})
	local list = Create.List(frame, Enum.FillDirection.Horizontal, UITheme.Padding.Small, align)
	list.VerticalAlignment = Enum.VerticalAlignment.Center
	return frame
end

function Menu.Build(content: Frame, maid: Maid.Maid): any
	local isOpen = false
	local tabs = Components.TabBar.new({
		Tabs = {
			{ Id = "Members", Text = S.Tabs.Members },
			{ Id = "Invite", Text = S.Tabs.Invite },
			{ Id = "Finder", Text = S.Tabs.Finder },
		},
		Selected = "Members",
		Parent = content,
	})
	maid:Add(tabs)
	local top = UITheme.Size.TabHeight + UITheme.Padding.Medium
	local pages: { [string]: Frame } = {}
	local function page(id: string): Frame
		local frame: Frame = Create.new("Frame", {
			Name = id,
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(0, top),
			Size = UDim2.new(1, 0, 1, -top),
			Visible = id == "Members",
			Parent = content,
		})
		pages[id] = frame
		return frame
	end

	-- MEMBERS -------------------------------------------------------------------------------
	local membersPage = page("Members")
	local membersBody: Frame = Create.new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = membersPage })
	Create.List(membersBody, Enum.FillDirection.Vertical, UITheme.Padding.Small)
	local header = hRow(membersBody, TOUCH, 1)
	local titleLabel = label("", { FontFace = UITheme.Fonts.Title, TextSize = UITheme.TextSize.Heading, TextColor3 = C.Accent, Size = UDim2.new(0, 220, 1, 0), LayoutOrder = 1 })
	titleLabel.Parent = header
	local controls = hRow(header, TOUCH, 2, Enum.HorizontalAlignment.Right)
	controls.Size = UDim2.new(1, -228, 1, 0)
	local lootRow = hRow(membersBody, TOUCH, 2)
	local lootHint = label("", { TextColor3 = C.TextMuted, TextSize = UITheme.TextSize.Small, Size = UDim2.new(1, -420, 1, 0), LayoutOrder = 9, TextWrapped = true })
	local memberList = Components.ScrollList.new({ Size = UDim2.new(1, 0, 1, -(TOUCH * 2 + UITheme.Padding.Small * 3)), LayoutOrder = 3, Spacing = 6, Parent = membersBody })
	maid:Add(memberList)
	local empty: Frame = Create.new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Visible = false, Parent = membersPage })
	Create.List(empty, Enum.FillDirection.Vertical, UITheme.Padding.Small, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
	label(S.Empty, { FontFace = UITheme.Fonts.Title, TextSize = UITheme.TextSize.Heading, TextXAlignment = Enum.TextXAlignment.Center, LayoutOrder = 1 }).Parent = empty
	label(S.EmptyHint, { TextColor3 = C.TextMuted, TextXAlignment = Enum.TextXAlignment.Center, LayoutOrder = 2 }).Parent = empty
	label(S.ChatHint, { TextColor3 = C.TextDim, TextSize = UITheme.TextSize.Small, TextXAlignment = Enum.TextXAlignment.Center, LayoutOrder = 3 }).Parent = empty

	local memberRows: { MemberRow } = {}
	local renderMaid = Maid.new()
	maid:Add(renderMaid)

	local function updateBars()
		for _, entry in memberRows do
			local who = entry.Player
			if who then
				local vitals = State.Vitals(who)
				entry.Health.Size = UDim2.fromScale(math.clamp(vitals.Health / math.max(vitals.MaxHealth, 1), 0, 1), 1)
				entry.Current.Size = UDim2.fromScale(math.clamp(vitals.Current / vitals.MaxCurrent, 0, 1), 1)
				entry.Level.Text = if vitals.Present then Strings.Format(S.Level, { level = vitals.Level }) else S.OutOfSight
			end
		end
	end

	local function renderMembers()
		renderMaid:Clean()
		memberList:Clear()
		table.clear(memberRows)
		local party = State.Party
		membersBody.Visible = party ~= nil
		empty.Visible = party == nil
		if not party then
			return
		end
		local leader = State.IsLeader()
		titleLabel.Text = `{if party.Raid then S.RaidTitle else S.Title}  {Strings.Format(S.Count, { count = #party.Members, max = party.Capacity })}`

		-- Controls.
		for _, child in controls:GetChildren() do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
		if leader then
			renderMaid:Add(button(controls, if party.Raid then S.ConvertParty else S.ConvertRaid, "Secondary", 130, 1, function()
				send("Raid", "")
			end))
			renderMaid:Add(button(controls, S.Disband, "Danger", 110, 2, function()
				send("Disband", "")
			end))
		end
		renderMaid:Add(button(controls, S.Leave, "Danger", 100, 3, function()
			send("Leave", "")
		end))

		-- Loot mode.
		for _, child in lootRow:GetChildren() do
			if child:IsA("GuiObject") and child ~= lootHint then
				child:Destroy()
			end
		end
		label(S.LootLabel, { TextColor3 = C.Accent, Size = UDim2.new(0, 60, 1, 0), LayoutOrder = 1 }).Parent = lootRow
		for index, mode in SP.LootModes do
			renderMaid:Add(button(lootRow, S.LootModes[mode] or mode, if party.LootMode == mode then "Primary" else "Secondary", 160, 1 + index, function()
				send("LootMode", mode)
			end, leader))
		end
		lootHint.Text = S.LootHints[party.LootMode] or ""
		lootHint.Parent = lootRow

		-- Members.
		for order, member in party.Members do
			local who = Players:GetPlayerByUserId(member.UserId)
			local frame = row(memberList.Instance, ROW_HEIGHT, order)
			local isLeader = member.UserId == party.Leader
			if isLeader then
				Create.new("Frame", {
					Name = "Leader",
					AnchorPoint = Vector2.new(0.5, 0.5),
					Position = UDim2.fromOffset(6, 18),
					Size = UDim2.fromOffset(10, 10),
					Rotation = 45,
					BackgroundColor3 = C.Parry,
					BorderSizePixel = 0,
					Parent = frame,
				})
			end
			local name = if member.UserId == localPlayer.UserId then `{member.Name} {S.You}` else member.Name
			label(name, { FontFace = UITheme.Fonts.BodyBold, Position = UDim2.fromOffset(18, 6), Size = UDim2.fromOffset(220, 24) }).Parent = frame
			label(if isLeader then S.Leader else "", { TextColor3 = C.Parry, TextSize = UITheme.TextSize.Caption, Position = UDim2.fromOffset(18, 32), Size = UDim2.fromOffset(100, 20) }).Parent = frame
			local level = label("", { TextColor3 = C.TextMuted, TextSize = UITheme.TextSize.Small, Position = UDim2.fromOffset(244, 6), Size = UDim2.fromOffset(110, 20) })
			level.Parent = frame
			local health = bar(frame, UDim2.fromOffset(244, 30), UDim2.fromOffset(180, 8), C.Health)
			local current = bar(frame, UDim2.fromOffset(244, 42), UDim2.fromOffset(180, 5), C.Current)
			table.insert(memberRows, { Player = who, Health = health, Current = current, Level = level })
			if leader and member.UserId ~= localPlayer.UserId then
				local actions = hRow(frame, ROW_HEIGHT, 1, Enum.HorizontalAlignment.Right)
				actions.Size = UDim2.new(1, 0, 1, 0)
				renderMaid:Add(button(actions, S.Promote, "Secondary", 120, 1, function()
					send("Promote", tostring(member.UserId))
				end))
				renderMaid:Add(button(actions, S.Kick, "Danger", 80, 2, function()
					send("Kick", tostring(member.UserId))
				end))
			end
		end
		updateBars()
	end

	-- INVITE --------------------------------------------------------------------------------
	local invitePage = page("Invite")
	local function column(x: number, title: string): Frame
		local frame: Frame = Create.new("Frame", {
			BackgroundTransparency = 1,
			Position = UDim2.new(x, if x > 0 then 6 else 0, 0, 0),
			Size = UDim2.new(0.5, -6, 1, 0),
			Parent = invitePage,
		})
		Create.List(frame, Enum.FillDirection.Vertical, UITheme.Padding.Small)
		label(title, { FontFace = UITheme.Fonts.TitleMedium, TextColor3 = C.Accent, LayoutOrder = 1 }).Parent = frame
		return frame
	end
	local nearbyColumn = column(0, S.NearbyTitle)
	local searchColumn = column(0.5, S.SearchTitle)
	local nearbyList = Components.ScrollList.new({ Size = UDim2.new(1, 0, 1, -32), LayoutOrder = 2, Spacing = 6, Parent = nearbyColumn })
	maid:Add(nearbyList)
	local search = Components.SearchBox.new({ Placeholder = S.SearchPlaceholder, LayoutOrder = 2, Parent = searchColumn })
	maid:Add(search)
	local searchList = Components.ScrollList.new({ Size = UDim2.new(1, 0, 1, -(32 + UITheme.Size.InputHeight + UITheme.Padding.Small)), LayoutOrder = 3, Spacing = 6, Parent = searchColumn })
	maid:Add(searchList)
	local inviteMaid = Maid.new()
	maid:Add(inviteMaid)

	local function playerRow(list: Components.ScrollList, who: Player, order: number)
		local frame = row(list.Instance, TOUCH + 8, order)
		label(who.DisplayName, { FontFace = UITheme.Fonts.BodyBold, Size = UDim2.new(1, -120, 1, 0), TextTruncate = Enum.TextTruncate.AtEnd }).Parent = frame
		local partyId = who:GetAttribute(A.PartyId)
		local busy = type(partyId) == "string" and partyId ~= ""
		if busy then
			label(S.InParty, { TextColor3 = C.TextDim, TextSize = UITheme.TextSize.Small, AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Size = UDim2.new(0, 110, 1, 0), TextXAlignment = Enum.TextXAlignment.Right }).Parent = frame
		else
			local invite = button(frame, S.InviteButton, "Primary", 100, 1, function()
				send("Invite", tostring(who.UserId))
			end)
			invite.Instance.AnchorPoint = Vector2.new(1, 0.5)
			invite.Instance.Position = UDim2.fromScale(1, 0.5)
			inviteMaid:Add(invite)
		end
	end

	local function emptyNote(list: Components.ScrollList, text: string)
		label(text, { TextColor3 = C.TextMuted, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.new(1, 0, 0, 40) }).Parent = list.Instance
	end

	local function renderInvite()
		inviteMaid:Clean()
		nearbyList:Clear()
		searchList:Clear()
		local root = State.RootOf(localPlayer)
		local nearby: { { Player: Player, Distance: number } } = {}
		local query = string.lower(search:GetText())
		local found = 0
		for _, who in Players:GetPlayers() do
			if who ~= localPlayer then
				local other = State.RootOf(who)
				if root and other then
					local distance = (other.Position - root.Position).Magnitude
					if distance <= SP.InviteRadius then
						table.insert(nearby, { Player = who, Distance = distance })
					end
				end
				local matches = query == ""
					or string.find(string.lower(who.Name), query, 1, true) ~= nil
					or string.find(string.lower(who.DisplayName), query, 1, true) ~= nil
				if matches and found < MAX_SEARCH then
					found += 1
					playerRow(searchList, who, found)
				end
			end
		end
		table.sort(nearby, function(a, b): boolean
			return a.Distance < b.Distance
		end)
		for order, entry in nearby do
			playerRow(nearbyList, entry.Player, order)
		end
		if #nearby == 0 then
			emptyNote(nearbyList, S.NearbyEmpty)
		end
		if found == 0 then
			emptyNote(searchList, S.SearchEmpty)
		end
	end
	maid:Add(search.Changed:Connect(renderInvite))

	-- FINDER --------------------------------------------------------------------------------
	local finderPage = page("Finder")
	local filter = "All"
	local filterRow = hRow(finderPage, TOUCH, 1)
	filterRow.Position = UDim2.fromOffset(0, 0)
	local composeHeight = TOUCH + UITheme.Padding.Small
	local listingList = Components.ScrollList.new({
		Position = UDim2.fromOffset(0, TOUCH + UITheme.Padding.Small),
		Size = UDim2.new(1, 0, 1, -(TOUCH + UITheme.Padding.Small) - composeHeight),
		Spacing = 6,
		Parent = finderPage,
	})
	maid:Add(listingList)
	local compose: Frame = Create.new("Frame", {
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, TOUCH),
		Parent = finderPage,
	})
	local composeList = Create.List(compose, Enum.FillDirection.Horizontal, UITheme.Padding.Small)
	composeList.VerticalAlignment = Enum.VerticalAlignment.Center
	local activityOptions = {}
	for _, activity in SF.Activities do
		table.insert(activityOptions, { Id = activity, Text = F.Activities[activity] or activity })
	end
	local activityPick = Components.Dropdown.new({
		Options = activityOptions,
		Selected = SF.Activities[1],
		Size = UDim2.fromOffset(200, TOUCH),
		LayoutOrder = 1,
		Parent = compose,
	})
	maid:Add(activityPick)
	local noteBox: TextBox = Create.new("TextBox", {
		Name = "Note",
		BackgroundColor3 = C.PanelSunken,
		Size = UDim2.new(1, -(200 + 150 + 140 + UITheme.Padding.Small * 3), 1, 0),
		FontFace = UITheme.Fonts.Body,
		TextSize = UITheme.TextSize.Small,
		TextColor3 = C.Text,
		PlaceholderText = F.NotePlaceholder,
		PlaceholderColor3 = C.TextDim,
		Text = "",
		ClearTextOnFocus = false,
		TextXAlignment = Enum.TextXAlignment.Left,
		LayoutOrder = 2,
		Parent = compose,
	})
	Create.Corner(noteBox, UITheme.CornerSmall)
	Create.Stroke(noteBox)
	Create.Padding(noteBox, 0, UITheme.Padding.Small, 0)
	maid:Add(noteBox:GetPropertyChangedSignal("Text"):Connect(function()
		if #noteBox.Text > SF.NoteMax then
			noteBox.Text = string.sub(noteBox.Text, 1, SF.NoteMax)
		end
	end))
	local post = button(compose, F.List, "Primary", 150, 3, function()
		Net.FireServer("RequestFinder", "List", activityPick:GetSelected(), string.sub(noteBox.Text, 1, SF.NoteMax))
	end)
	maid:Add(post)
	local unlist = button(compose, F.Unlist, "Danger", 140, 4, function()
		Net.FireServer("RequestFinder", "Unlist", "", "")
	end)
	maid:Add(unlist)
	local finderMaid = Maid.new()
	maid:Add(finderMaid)
	local renderFinder: () -> ()

	local function renderFilters()
		for _, child in filterRow:GetChildren() do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
		local ids = { "All" }
		for _, activity in SF.Activities do
			table.insert(ids, activity)
		end
		for order, id in ids do
			finderMaid:Add(button(filterRow, if id == "All" then F.All else F.Activities[id] or id, if filter == id then "Primary" else "Secondary", 150, order, function()
				filter = id
				renderFinder()
			end))
		end
	end

	renderFinder = function()
		finderMaid:Clean()
		listingList:Clear()
		renderFilters()
		local now = Workspace:GetServerTimeNow()
		local mine = false
		local order = 0
		local inParty = State.Party ~= nil
		for _, listing in State.Listings do
			local own = listing.Owner == localPlayer.UserId
			mine = mine or own
			if filter == "All" or listing.Activity == filter then
				order += 1
				local frame = row(listingList.Instance, 70, order)
				label(F.Activities[listing.Activity] or listing.Activity, { FontFace = UITheme.Fonts.BodyBold, TextColor3 = C.Accent, Position = UDim2.fromOffset(0, 4), Size = UDim2.new(1, -170, 0, 22) }).Parent = frame
				local minutes = math.max(0, math.ceil((listing.Expires - now) / 60))
				local line = `{listing.OwnerName}  ·  {Strings.Format(F.Members, { count = listing.Members, max = listing.Capacity })}  ·  {Strings.Format(F.TimeLeft, { minutes = minutes })}`
				label(line, { TextSize = UITheme.TextSize.Small, Position = UDim2.fromOffset(0, 26), Size = UDim2.new(1, -170, 0, 18) }).Parent = frame
				label(listing.Note, { TextSize = UITheme.TextSize.Small, TextColor3 = C.TextMuted, Position = UDim2.fromOffset(0, 46), Size = UDim2.new(1, -170, 0, 18), TextTruncate = Enum.TextTruncate.AtEnd }).Parent = frame
				if own then
					label(F.Yours, { TextColor3 = C.Current, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.fromScale(1, 0.5), Size = UDim2.fromOffset(150, 24), TextXAlignment = Enum.TextXAlignment.Right }).Parent = frame
				else
					local join = button(frame, F.Join, "Primary", 150, 1, function()
						Net.FireServer("RequestFinder", "Join", listing.Id, "")
					end, not inParty and listing.Members < listing.Capacity)
					join.Instance.AnchorPoint = Vector2.new(1, 0.5)
					join.Instance.Position = UDim2.fromScale(1, 0.5)
					finderMaid:Add(join)
				end
			end
		end
		if order == 0 then
			label(F.Empty, { TextColor3 = C.TextMuted, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.new(1, 0, 0, 40) }).Parent = listingList.Instance
		end
		post:SetText(if mine then F.Update else F.List)
		post:SetEnabled(not inParty or State.IsLeader())
		unlist:SetEnabled(mine)
	end

	-- LIVE ----------------------------------------------------------------------------------
	local lastRefresh = -math.huge
	local function requestBoard()
		lastRefresh = os.clock()
		Net.FireServer("RequestFinder", "Refresh", "", "")
	end
	local function onTab(id: string)
		for key, frame in pages do
			frame.Visible = key == id
		end
		if id == "Invite" then
			renderInvite()
		elseif id == "Finder" then
			renderFinder()
			requestBoard()
		end
	end
	maid:Add(tabs.Changed:Connect(onTab))
	maid:Add(State.Changed:Connect(function()
		renderMembers()
		if isOpen and tabs:GetSelected() == "Finder" then
			renderFinder()
		end
	end))
	maid:Add(State.ListingsChanged:Connect(function()
		if isOpen then
			renderFinder()
		end
	end))
	local lastBars, lastNearby = 0, 0
	maid:Add(Animator.Add(function(time: number)
		local selected = tabs:GetSelected()
		if selected == "Members" and time - lastBars >= 1 / SP.FrameUpdateHz then
			lastBars = time
			updateBars()
		elseif selected == "Invite" and time - lastNearby >= 1 and search.TextBox:IsFocused() == false then
			lastNearby = time
			renderInvite()
		elseif selected == "Finder" and os.clock() - lastRefresh >= SF.WatchSeconds * 0.75 then
			requestBoard()
		end
	end, MENU_ID))
	Animator.SetPaused(MENU_ID, true)
	renderMembers()

	return {
		TabBar = tabs,
		OnOpen = function()
			isOpen = true
			Animator.SetPaused(MENU_ID, false)
			renderMembers()
			onTab(tabs:GetSelected())
		end,
		OnClose = function()
			isOpen = false
			Animator.SetPaused(MENU_ID, true)
		end,
	}
end

return Menu
