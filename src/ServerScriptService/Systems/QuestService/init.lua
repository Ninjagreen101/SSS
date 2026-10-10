--!strict
--[[
	QuestService
	Owns quest state in the profile (docs/PHASE11_QUESTS.md; data in Shared.Data.Quests, every rule
	in Rules, shared with tools/place/sim_quests.luau).

	- Requests (RequestQuestAction, intent only; each is re-checked here):
	    Accept   a main / side quest from its Giver (npcId, within TalkRadius), or a rolled daily /
	             weekly from the log (npcId "", only after it was abandoned: rolls start on their own)
	    TurnIn   a ready quest to its TurnIn NPC; rewards (XP, gold, Shards, items) are paid in one
	             inventory transaction, refused whole with BagFull when the items don't fit
	    Abandon  side quests, dailies and weeklies (never the main story)
	    Track    the quest the HUD tracker follows ("" = none)
	    Reroll   one of today's unfinished dailies, Config.Quests.DailyRerolls times a day
	  Refusals come back as a Notify toast (Strings.QuestUI.Errors).
	- Progress: GameEvents actions feed every active quest (Rules.Feed). Quests without a TurnIn
	  complete on the spot when ready. RequestTalk(npcId) from a player near that NPC is the Talk
	  action (and holds the NPC). Reach and Region actions are fired here: every ReachCheckSeconds
	  each player is checked against the quest points (Parts tagged SpireQuestPoint, or in
	  Workspace.Floor<N>.QuestPoints, with PointId and Radius; one Reach per entry) and the region
	  grid (ReplicatedStorage.FloorData.Regions, as the client's ambience reads it).
	- Dailies and weeklies are rolled per player at the UTC resets (Rules.RollDue) on join and while
	  playing; last period's leave the log.
	- Completing: Data.Quests.Completed[id] = unix time, GameEvents "Quest", QuestEvent Completed
	  with the rewards and, for the main story, the next main quest once it can be accepted (Next).
	- QuestEvent(kind, questId, payload) carries the moments (Accepted, Progress {Index}, Ready,
	  Completed, Abandoned, Rolled {Pool, Ids}); the state itself replicates through DataService.

	Public: QuestService.Give(player, questId) starts a quest without a Giver check (the tutorial's
	hand-off of F1_M01); false when it can't start (already active or done, requirements, log full).
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Attributes = require(Shared.Attributes)
local Net = require(Shared.Net)
local Types = require(Shared.Types)
local Log = require(Shared.Util.Log)
local Quests = require(Shared.Data.Quests)
local Npcs = require(Shared.Data.Npcs)
local InventoryRules = require(Shared.Data.InventoryRules)

local GameEvents = require(script.Parent.GameEvents)
local DataService = require(script.Parent.DataService)
local FloorService = require(script.Parent.FloorService)
local InventoryService = require(script.Parent.InventoryService)
local EconomyService = require(script.Parent.EconomyService)
local ProgressionService = require(script.Parent.ProgressionService)
local AnalyticsService = require(script.Parent.AnalyticsService)
local NpcService = require(script.Parent.NpcService)
local Rules = require(script.Rules)

type PlayerData = Types.PlayerData
type QuestDef = Quests.QuestDef
type Reason = Rules.Reason

local A = Attributes.Names
local Q = Config.Quests
local log = Log.new("QuestService")

local PERIOD_CHECK_SECONDS = 1 -- resets and on-the-spot completions waiting for bag space
local KIND_ORDER: { [string]: number } = { Main = 1, Side = 2, Tutorial = 3, Daily = 4, Weekly = 5 }

type Session = {
	Inside: { [string]: boolean }, -- quest points the player stands in now
	Region: string?,
	Warned: { [string]: boolean }, -- on-the-spot quests whose bag-full toast was shown
}

type RegionGrid = { Data: string, Cell: number, Origin: Vector2, Columns: number, Legend: { [string]: string } }

local QuestService = {}

local sessions: { [Player]: Session } = {}
local points: { [BasePart]: string } = {}
local regions: RegionGrid? = nil
local random = Random.new()

-- WORLD --------------------------------------------------------------------------------------

local function rootOf(player: Player): BasePart?
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if humanoid and humanoid.Health > 0 and root and root:IsA("BasePart") then
		return root
	end
	return nil
end

local function addPoint(instance: Instance)
	local id = instance:GetAttribute(A.PointId)
	if instance:IsA("BasePart") and type(id) == "string" and id ~= "" then
		points[instance] = id
	end
end

local function radiusOf(part: BasePart): number
	local radius = part:GetAttribute(A.Radius)
	return if type(radius) == "number" and radius > 0 then radius else Q.Tutorial.PointRadius
end

local function loadRegions()
	local folder = ReplicatedStorage:FindFirstChild("FloorData")
	local value = folder and folder:FindFirstChild("Regions")
	if not (value and value:IsA("StringValue")) then
		return
	end
	local origin = value:GetAttribute("Origin")
	local columns = value:GetAttribute("Columns")
	local cell = value:GetAttribute("Cell")
	local raw = value:GetAttribute("Legend")
	if typeof(origin) ~= "Vector2" or type(columns) ~= "number" or type(raw) ~= "string" then
		log:Warn("FloorData.Regions has no Origin / Columns / Legend; no Region actions")
		return
	end
	local legend: { [string]: string } = {}
	for _, pair in string.split(raw, ",") do
		local parts = string.split(pair, "=")
		if #parts == 2 then
			legend[parts[1]] = parts[2]
		end
	end
	regions = {
		Data = value.Value,
		Cell = if type(cell) == "number" and cell > 0 then cell else Config.Environment.RegionCell,
		Origin = origin,
		Columns = columns,
		Legend = legend,
	}
end

local function regionAt(position: Vector3): string?
	local grid = regions
	if not grid then
		return nil
	end
	local i = math.floor((position.X - grid.Origin.X) / grid.Cell)
	local k = math.floor((position.Z - grid.Origin.Y) / grid.Cell)
	if i < 0 or k < 0 or i >= grid.Columns or k >= grid.Columns then
		return nil
	end
	local index = k * grid.Columns + i + 1
	return grid.Legend[string.sub(grid.Data, index, index)]
end

-- STATE HELPERS ------------------------------------------------------------------------------

local function factsFor(player: Player, data: PlayerData): Rules.Facts
	local secrets: { [string]: boolean } = {}
	for key, found in data.Discoveries do
		if found and string.sub(key, 1, 5) == "Area:" then
			secrets[string.sub(key, 6)] = true
		end
	end
	local session = sessions[player]
	return {
		Waystones = data.Waystones.Discovered,
		Secrets = secrets,
		Attunements = { data.Attunements.Primary, data.Attunements.Secondary },
		Inside = if session then session.Inside else {},
	}
end

local function event(player: Player, kind: string, questId: string, payload: { [string]: any }?)
	Net.Fire("QuestEvent", player, kind, questId, payload or {})
end

local function refuse(player: Player, reason: Reason)
	Net.Fire("Notify", player, `QuestUI.Errors.{reason}`, {}, "Warning")
end

-- The quest the tracker should follow when the tracked one leaves the log: story first.
local function nextTracked(active: { [string]: Types.QuestState }): string
	local best: string? = nil
	local bestKey = math.huge
	for id in active do
		local def = Quests.Get(id)
		if def then
			local key = (KIND_ORDER[def.Kind] or 9) * 1000 + (def.Order or 999)
			if key < bestKey or (key == bestKey and best ~= nil and id < best) then
				best = id
				bestKey = key
			end
		end
	end
	return best or ""
end

local function fixTracked(player: Player, data: PlayerData)
	local tracked = data.Quests.Tracked
	if tracked ~= "" and data.Quests.Active[tracked] == nil then
		DataService.Set(player, { "Quests", "Tracked" }, nextTracked(data.Quests.Active))
	end
end

-- COMPLETING ---------------------------------------------------------------------------------

-- Pays a ready quest out and moves it to Completed. The quest leaves the log before the
-- transaction (and comes back only if it fails), and nothing here yields, so it can't pay twice.
local function complete(player: Player, id: string): (boolean, Reason?)
	local data = DataService.GetData(player)
	local def = Quests.Get(id)
	if not data or not def then
		return false, "NotAvailable"
	end
	local book = data.Quests
	local state = book.Active[id]
	if not state then
		return false, "NotAvailable"
	end
	local before = book.Completed[id]
	if not Rules.Finish(book, id, os.time()) then
		return false, "NotReady"
	end
	local rewards = def.Rewards
	local gold = 0
	local ok, reason = InventoryService.Transact(player, function(draft: PlayerData): (boolean, string?)
		local items = rewards.Items
		if items then
			for _, item in items do
				local granted, why = InventoryRules.Grant(draft, item.Id, item.Count, random, item.Rarity)
				if not granted then
					return false, why
				end
			end
		end
		gold = InventoryRules.Earn(draft, "Gold", rewards.Gold)
		return true, nil
	end)
	if not ok then
		book.Active[id] = state
		book.Completed[id] = before
		if reason ~= "Full" and reason ~= "TradeLocked" then
			log:Warn(`{player.Name} couldn't hand in {id}: {reason or "?"}`)
		end
		return false, if reason == "Full" then "BagFull" else "NotAvailable"
	end

	DataService.Set(player, { "Quests", "Active", id }, nil)
	DataService.Set(player, { "Quests", "Completed", id }, book.Completed[id])
	fixTracked(player, data)
	local session = sessions[player]
	if session then
		session.Warned[id] = nil
	end

	if rewards.XP > 0 then
		ProgressionService.AddXP(player, rewards.XP)
	end
	if gold > 0 then
		AnalyticsService.Economy(player, "Source", "Gold", gold, data.Currencies.Gold, "Gameplay", "Quest")
		GameEvents.Fire(player, "Gold", "", gold)
	end
	local shards = rewards.Shards or 0
	if shards > 0 then
		EconomyService.GrantShards(player, shards, "Quest")
	end
	AnalyticsService.Custom(player, `Quest{def.Kind}Completed`)

	local nextId: string? = nil
	if def.Kind == "Main" then
		local candidate = Rules.NextMain(id)
		if candidate and Rules.CanAccept(candidate, book) then
			nextId = candidate
		end
	end
	event(player, "Completed", id, { XP = rewards.XP, Gold = gold, Shards = shards, Next = nextId })
	GameEvents.Fire(player, "Quest", id)
	return true, nil
end

-- Quests without a TurnIn finish where they are; a full bag keeps them ready (one toast) and they
-- are retried every PERIOD_CHECK_SECONDS.
local function completeOnSpot(player: Player, id: string): boolean
	local done, reason = complete(player, id)
	if done then
		return true
	end
	local session = sessions[player]
	if reason == "BagFull" and session and not session.Warned[id] then
		session.Warned[id] = true
		event(player, "Ready", id, {})
		refuse(player, "BagFull")
	end
	return false
end

local function completeReadyOnSpot(player: Player)
	local data = DataService.GetData(player)
	if not data then
		return
	end
	local ready: { string } = {}
	for id, state in data.Quests.Active do
		local def = Quests.Get(id)
		if def and def.TurnIn == nil and Rules.IsReady(def, state) then
			table.insert(ready, id)
		end
	end
	table.sort(ready)
	for _, id in ready do
		completeOnSpot(player, id)
	end
end

-- Replicates and announces what an action moved; ready on-the-spot quests complete.
local function report(player: Player, data: PlayerData, moved: { Rules.Moved })
	for _, entry in moved do
		DataService.Set(player, { "Quests", "Active", entry.Id }, data.Quests.Active[entry.Id])
	end
	for _, entry in moved do
		local def = Quests.Get(entry.Id)
		if not entry.Ready then
			event(player, "Progress", entry.Id, { Index = entry.Objectives[1] })
		elseif def and def.TurnIn == nil then
			completeOnSpot(player, entry.Id)
		else
			event(player, "Ready", entry.Id, { Index = entry.Objectives[1] })
		end
	end
end

-- PERIODS ------------------------------------------------------------------------------------

local function rollDue(player: Player, data: PlayerData)
	local daily, weekly = Rules.RollDue(data.Quests, player.UserId, os.time(), factsFor(player, data))
	if not daily and not weekly then
		return
	end
	DataService.Replicate(player, { "Quests" })
	fixTracked(player, data)
	if daily then
		event(player, "Rolled", "", { Pool = "Daily", Ids = table.clone(data.Quests.Dailies) })
	end
	if weekly then
		event(player, "Rolled", "", { Pool = "Weekly", Ids = table.clone(data.Quests.Weeklies) })
	end
	completeReadyOnSpot(player)
end

-- STARTING -----------------------------------------------------------------------------------

local function start(player: Player, data: PlayerData, def: QuestDef, id: string, npcId: string)
	local state = Rules.Start(def, os.time(), npcId, factsFor(player, data))
	DataService.Set(player, { "Quests", "Active", id }, state)
	local tracked = data.Quests.Tracked
	if tracked == "" or data.Quests.Active[tracked] == nil then
		DataService.Set(player, { "Quests", "Tracked" }, id)
	end
	event(player, "Accepted", id, {})
	AnalyticsService.Custom(player, `Quest{def.Kind}Accepted`)
	if Rules.IsReady(def, state) then
		if def.TurnIn == nil then
			completeOnSpot(player, id)
		else
			event(player, "Ready", id, {})
		end
	end
end

-- REQUESTS -----------------------------------------------------------------------------------

local function accept(player: Player, data: PlayerData, id: string, npcId: string): (boolean, Reason?)
	local def = Quests.Get(id)
	if not def then
		return false, "NotAvailable"
	end
	local ok: boolean, reason: Reason?
	if Rules.IsRepeatable(def) then
		if npcId ~= "" then
			return false, "NotAvailable"
		end
		ok, reason = Rules.CanAcceptRolled(id, data.Quests)
	else
		if not Rules.OfferedBy(def, npcId) then
			return false, "NotAvailable"
		end
		if not NpcService.IsNear(player, npcId) then
			return false, "TooFar"
		end
		ok, reason = Rules.CanAccept(id, data.Quests)
	end
	if not ok then
		return false, reason
	end
	if npcId ~= "" then
		NpcService.Hold(npcId, player)
	end
	start(player, data, def, id, npcId)
	return true, nil
end

local function turnIn(player: Player, data: PlayerData, id: string, npcId: string): (boolean, Reason?)
	local def = Quests.Get(id)
	local state = data.Quests.Active[id]
	if not def or not state or not Rules.TurnInAt(def, npcId) then
		return false, "NotAvailable"
	end
	if npcId ~= "" then
		if not NpcService.IsNear(player, npcId) then
			return false, "TooFar"
		end
		NpcService.Hold(npcId, player)
	end
	if not Rules.IsReady(def, state) then
		return false, "NotReady"
	end
	return complete(player, id)
end

local function abandon(player: Player, data: PlayerData, id: string): (boolean, Reason?)
	local def = Quests.Get(id)
	if not def or data.Quests.Active[id] == nil or not Rules.CanAbandon(def) then
		return false, "NotAvailable"
	end
	DataService.Set(player, { "Quests", "Active", id }, nil)
	fixTracked(player, data)
	local session = sessions[player]
	if session then
		session.Warned[id] = nil
	end
	event(player, "Abandoned", id, {})
	return true, nil
end

local function track(player: Player, data: PlayerData, id: string): (boolean, Reason?)
	if id ~= "" and data.Quests.Active[id] == nil then
		return false, nil
	end
	if data.Quests.Tracked ~= id then
		DataService.Set(player, { "Quests", "Tracked" }, id)
	end
	return true, nil
end

local function reroll(player: Player, data: PlayerData, id: string): (boolean, Reason?)
	local wasTracked = data.Quests.Tracked == id
	local pick: string?, reason: Reason? = Rules.Reroll(data.Quests, player.UserId, os.time(), id, factsFor(player, data))
	if not pick then
		return false, reason
	end
	DataService.Replicate(player, { "Quests" })
	if wasTracked then
		DataService.Set(player, { "Quests", "Tracked" }, pick)
	end
	local session = sessions[player]
	if session then
		session.Warned[id] = nil
	end
	event(player, "Rolled", pick, { Pool = "Daily", Ids = table.clone(data.Quests.Dailies), Replaced = id })
	completeReadyOnSpot(player)
	return true, nil
end

local function onAction(player: Player, action: string, questId: string, npcId: string)
	local data = DataService.GetData(player)
	if not data or not sessions[player] then
		return
	end
	rollDue(player, data)
	local ok: boolean, reason: Reason?
	if action == "Accept" then
		ok, reason = accept(player, data, questId, npcId)
	elseif action == "TurnIn" then
		ok, reason = turnIn(player, data, questId, npcId)
	elseif action == "Abandon" then
		ok, reason = abandon(player, data, questId)
	elseif action == "Track" then
		ok, reason = track(player, data, questId)
	elseif action == "Reroll" then
		ok, reason = reroll(player, data, questId)
	else
		return
	end
	if not ok and reason then
		refuse(player, reason)
	end
end

local function onTalk(player: Player, npcId: string)
	if not Npcs.Get(npcId) or not sessions[player] or not NpcService.IsNear(player, npcId) then
		return
	end
	NpcService.Hold(npcId, player)
	GameEvents.Fire(player, "Talk", npcId)
end

-- ACTIONS ------------------------------------------------------------------------------------

local function onEvent(player: Player, kind: GameEvents.Kind, key: string, amount: number)
	local data = DataService.GetData(player)
	if not data or not sessions[player] then
		return
	end
	local moved = Rules.Feed(data.Quests, kind, key, amount, factsFor(player, data))
	if #moved > 0 then
		report(player, data, moved)
	end
end

-- Reach (one per entry into a point) and Region (on entering one) for everyone.
local function checkPlayers()
	for player, session in sessions do
		local root = rootOf(player)
		if not root or not DataService.IsLoaded(player) then
			continue
		end
		local position = root.Position
		local now: { [string]: boolean } = {}
		for part, id in points do
			if part.Parent and (position - part.Position).Magnitude <= radiusOf(part) then
				now[id] = true
			end
		end
		local entered: { string } = {}
		for id in now do
			if not session.Inside[id] then
				table.insert(entered, id)
			end
		end
		session.Inside = now
		table.sort(entered)
		for _, id in entered do
			GameEvents.Fire(player, "Reach", id)
		end
		local region = regionAt(position)
		if region and region ~= session.Region then
			session.Region = region
			GameEvents.Fire(player, "Region", region)
		end
	end
end

-- LIFECYCLE ----------------------------------------------------------------------------------

local function onLoaded(player: Player)
	local data = DataService.GetData(player)
	if not data or sessions[player] then
		return
	end
	sessions[player] = { Inside = {}, Region = nil, Warned = {} }
	local book = data.Quests
	-- States that no longer fit their quest (content changed) are repaired; unknown quests leave.
	for id, state in book.Active do
		local def = Quests.Get(id)
		if not def or type(state) ~= "table" then
			book.Active[id] = nil
			continue
		end
		if type(state.Progress) ~= "table" then
			state.Progress = {}
		end
		Rules.Repair(def, state)
	end
	for _, key in { "Dailies", "Weeklies" } do
		local list = (book :: any)[key]
		local kept: { string } = {}
		if type(list) == "table" then
			for _, id in list do
				if type(id) == "string" and Quests.Get(id) then
					table.insert(kept, id)
				end
			end
		end
		(book :: any)[key] = kept
	end
	if type(book.Rerolls) ~= "number" or book.Rerolls < 0 then
		book.Rerolls = 0
	end
	local facts = factsFor(player, data)
	Rules.RollDue(book, player.UserId, os.time(), facts)
	Rules.Refresh(book, facts)
	if book.Tracked ~= "" and book.Active[book.Tracked] == nil then
		book.Tracked = nextTracked(book.Active)
	end
	DataService.Replicate(player, { "Quests" })
	completeReadyOnSpot(player)
end

-- PUBLIC API ---------------------------------------------------------------------------------

-- Starts quest `questId` for `player` without a Giver (the tutorial hands over F1_M01). Returns
-- false when it can't start: unknown, rolled, already active or done, requirements, log full.
function QuestService.Give(player: Player, questId: string): boolean
	local data = DataService.GetData(player)
	local def = Quests.Get(questId)
	if not data or not def or not sessions[player] or Rules.IsRepeatable(def) then
		return false
	end
	if not Rules.CanAccept(questId, data.Quests) then
		return false
	end
	start(player, data, def, questId, "")
	return true
end

-- True if `player` has completed quest `questId` (this period, for dailies and weeklies).
function QuestService.IsCompleted(player: Player, questId: string): boolean
	local data = DataService.GetData(player)
	return data ~= nil and data.Quests.Completed[questId] ~= nil
end

function QuestService.Init()
	Net.On("RequestQuestAction", onAction)
	Net.On("RequestTalk", onTalk)
end

function QuestService.Start()
	for _, instance in CollectionService:GetTagged(Attributes.Tags.QuestPoint) do
		addPoint(instance)
	end
	CollectionService:GetInstanceAddedSignal(Attributes.Tags.QuestPoint):Connect(addPoint)
	CollectionService:GetInstanceRemovedSignal(Attributes.Tags.QuestPoint):Connect(function(instance: Instance)
		if instance:IsA("BasePart") then
			points[instance] = nil
		end
	end)
	-- Points placed without the tag still count when they sit in the floor's QuestPoints folder.
	local floor = Workspace:FindFirstChild(`Floor{FloorService.GetFloorId()}`)
	local folder = floor and floor:FindFirstChild("QuestPoints")
	if folder then
		for _, instance in folder:GetDescendants() do
			addPoint(instance)
		end
	end
	if next(points) == nil then
		log:Warn("No quest points found (run Tools.Floor1Npcs); Reach objectives can't progress")
	end
	loadRegions()

	GameEvents.Fired:Connect(onEvent)
	DataService.ProfileLoaded:Connect(function(player: Player)
		onLoaded(player)
	end)
	DataService.ProfileReleased:Connect(function(player: Player)
		sessions[player] = nil
	end)
	for _, player in Players:GetPlayers() do
		if DataService.IsLoaded(player) then
			task.spawn(onLoaded, player)
		end
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		sessions[player] = nil
	end)

	local reachTimer, periodTimer = 0, 0
	RunService.Heartbeat:Connect(function(dt: number)
		reachTimer += dt
		periodTimer += dt
		if reachTimer >= Q.ReachCheckSeconds then
			reachTimer = 0
			checkPlayers()
		end
		if periodTimer >= PERIOD_CHECK_SECONDS then
			periodTimer = 0
			for player in sessions do
				local data = DataService.GetData(player)
				if data then
					rollDue(player, data)
					completeReadyOnSpot(player)
				end
			end
		end
	end)
end

return QuestService
