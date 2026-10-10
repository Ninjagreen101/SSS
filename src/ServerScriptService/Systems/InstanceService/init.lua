--!strict
--[[
	InstanceService
	Reserved-server instances for dungeons and Guardian arenas (docs/PHASE12_MULTIPLAYER.md,
	"Reserved servers"; replaces the transport of decisions #133 and #149 when published).
	Every pure decision (data validation, admission, timing, retries) is in Rules.

	Going in (a public server)
	  Begin(mode, id, players) reserves a server of this same place and teleports exactly that
	  group there with { Version, Mode, Id, Members, ReturnPlaceId, Party }. It does so only when
	  Config UseReservedServers is on, the place is published and this isn't Studio. It returns
	  false when it can't or when reserving / teleporting keeps failing (TeleportRetries); the
	  caller then runs its in-server copy as before. Open trades of the group are cancelled first
	  (TradeService.Cancel) and each profile is saved (DataService.PrepareTeleport). The session
	  lock is NOT released here: it is released on PlayerRemoving like any leave, and ProfileStore's
	  session-conflict messaging hands it to the destination (ending it early would kick the player
	  if the teleport failed). TeleportInitFailed is retried per player; when it keeps failing, or
	  the player is still here and not mid-teleport after TeleportDeadline, the player is told and
	  the caller's fallback runs for them here. Nothing runs for a player who has left.

	An instance server (a reserved server of this place: PrivateServerId set, no owner)
	  The first arrival with valid data fixes the run (Rules.ParseInstance). Only players named in
	  it who teleported from this place and carry the same run are admitted (Rules.Admit); anyone
	  else is sent back without ever getting a character (FloorService.SpawnHeld). The handler
	  registered for the mode builds the run space at once (Prepare; members whose profile loaded
	  while their spawn was held get their character then), starts the run when the whole party
	  has loaded or ArrivalTimeout has passed (Begin), and decides about late members (Join). The
	  source party is rebuilt here from the record's Party (PartyService.Regroup) for whoever
	  arrived, so shared XP, SharedGold, pings and party chat work in the run. ReturnAll sends
	  everyone home: after ReturnTimeout when a run ends, at once on a failure. The way home is
	  written into each profile (PendingReturn, saved before the teleport), never into teleport
	  data; the next public server honours it once within ReturnWindow (TakeReturnTo). If the way
	  home keeps failing the player is kicked with a rejoin message (their profile is saved and
	  released as on any leave).
	  Parties are not carried back: the way home goes to any public server of the place, and the
	  source server dropped the members from its parties when they left (decision #177).

	Why the arrival's teleport data can be trusted here: it is read on the server
	(Player:GetJoinData), and a reserved server can only be entered with its access code, which
	ReserveServer hands to the reserving server alone and only server-side TeleportAsync can use.
	So every arrival in an instance server was sent by a server of this place with the data that
	server wrote. Rules.Admit still checks SourcePlaceId (set by Roblox) and that the arrival is
	named in the run's Members.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Strings = require(Shared.Strings)
local Net = require(Shared.Net)
local Log = require(Shared.Util.Log)
local Signal = require(Shared.Util.Signal)
local Guardians = require(Shared.Data.Guardians)

local DataService = require(script.Parent.DataService)
local PartyService = require(script.Parent.PartyService)
local Rules = require(script.Rules)

local I = Config.Social.Instances
local log = Log.new("InstanceService")

-- Seconds between checks on arrivals in an instance server.
local WATCH_INTERVAL = 0.5

export type Mode = Rules.Mode
export type Record = Rules.Record

export type Handler = {
	-- Builds the run space as soon as the run is known; false if it can't (everyone goes home).
	Prepare: (record: Record) -> boolean,
	-- Starts the run for the members who arrived (each has a loaded profile and a living character).
	Begin: (players: { Player }) -> (),
	-- A member who arrived after Begin: true if they joined the run, false to send them home.
	Join: (player: Player) -> boolean,
	-- Where members arrive on the floor when they go home ("Waystone:<id>" or "Gate:<id>").
	ReturnTo: (record: Record) -> string?,
}

type Outgoing = {
	PlaceId: number,
	Options: TeleportOptions,
	Attempts: number,
	Deadline: number,
	Extended: boolean, -- the deadline was pushed back once while Roblox reported the teleport running
	OnFailed: (Player) -> (),
}

type Phase = "Public" | "Waiting" | "Gathering" | "Running" | "Returning"

local InstanceService = {}

-- TradeService and CharacterService depend on this module (directly or through FloorService and
-- DungeonService), so it can't require them; they listen here instead.
-- Fires with each player about to be sent to another server, before their profile is saved
-- (TradeService cancels their trade: a trade lock would keep them here).
InstanceService.Leaving = Signal.new() :: Signal.Signal<Player>
-- Instance servers: fires once the run space exists with the admitted members who have a loaded
-- profile but no character (held until now); CharacterService spawns them.
InstanceService.Prepared = Signal.new() :: Signal.Signal<{ Player }>

local isInstance = false
local phase: Phase = "Public"
local record: Record? = nil
local handlers: { [string]: Handler } = {}
local prepared = false
local gatherStarted = 0
local lastReadyCount = 0
local evaluated: { [Player]: boolean } = {}
local admitted: { [Player]: boolean } = {}
local begun: { [Player]: boolean } = {}
local outgoing: { [Player]: Outgoing } = {}
local starting: { [Player]: boolean } = {}
local teleportState: { [Player]: Enum.TeleportState } = {} -- latest Player.OnTeleport state
local IN_FLIGHT: { [Enum.TeleportState]: boolean } = {
	[Enum.TeleportState.RequestedFromServer] = true,
	[Enum.TeleportState.Started] = true,
	[Enum.TeleportState.WaitingForServer] = true,
	[Enum.TeleportState.InProgress] = true,
}

local function sleep(seconds: number)
	task.wait(seconds)
end

local function notify(players: { Player }, key: string, args: { [string]: any }?, style: string)
	for _, player in players do
		if player.Parent == Players then
			Net.Fire("Notify", player, key, args or {}, style)
		end
	end
end

local function limits(): Rules.Limits
	return {
		PlaceId = game.PlaceId,
		MaxMembers = math.max(Config.Social.Party.RaidMaxMembers, Config.Mobs.Guardian.MaxPlayers),
		IsKnownId = function(mode: Mode, id: string): boolean
			if mode == "Dungeon" then
				return Config.Dungeons.Dungeons[id] ~= nil
			end
			return Guardians.Get(id) ~= nil
		end,
		LootModes = Config.Social.Party.LootModes,
	}
end

-- The arrival's teleport data and the place it came from (both nil if unreadable).
local function joinData(player: Player): (any, any)
	local ok, data = pcall(function(): any
		return player:GetJoinData()
	end)
	if not ok or type(data) ~= "table" then
		return nil, nil
	end
	return data.TeleportData, data.SourcePlaceId
end

-- TELEPORTS --------------------------------------------------------------------------------------

-- A player's teleport failed for good: forget it and run the failure path while they're here.
local function giveUp(player: Player, entry: Outgoing)
	if outgoing[player] ~= entry then
		return
	end
	outgoing[player] = nil
	if player.Parent == Players then
		local ok, err = pcall(function()
			entry.OnFailed(player)
		end)
		if not ok then
			log:Error(`teleport fallback for {player.Name} failed: {tostring(err)}`)
		end
	end
end

-- A player still here TeleportDeadline after the request counts as failed, unless Roblox reports
-- the teleport still running (then it gets one more TeleportDeadline). A player who left is done
-- (PlayerRemoving forgets the entry), so a slow but successful teleport never falls back.
local function armDeadline(player: Player, entry: Outgoing)
	entry.Deadline = os.clock() + I.TeleportDeadline
	task.delay(I.TeleportDeadline, function()
		if outgoing[player] ~= entry or os.clock() < entry.Deadline or player.Parent ~= Players then
			return
		end
		local state = teleportState[player]
		if state and IN_FLIGHT[state] and not entry.Extended then
			entry.Extended = true
			log:Warn(`teleport of {player.Name} still running ({state.Name}); waiting longer`)
			armDeadline(player, entry)
			return
		end
		log:Warn(`teleport of {player.Name} timed out`)
		giveUp(player, entry)
	end)
end

local function retryOrGiveUp(player: Player, entry: Outgoing, resultName: string)
	if outgoing[player] ~= entry then
		return
	end
	if not Rules.ShouldRetry(resultName, entry.Attempts, I.TeleportRetries) then
		log:Warn(`teleport of {player.Name} failed ({resultName}) after {entry.Attempts} attempts`)
		giveUp(player, entry)
		return
	end
	entry.Attempts += 1
	task.delay(Rules.RetryDelay(entry.Attempts), function()
		if outgoing[player] ~= entry or player.Parent ~= Players then
			return
		end
		teleportState[player] = nil
		armDeadline(player, entry)
		local ok, err = pcall(function()
			TeleportService:TeleportAsync(entry.PlaceId, { player }, entry.Options)
		end)
		if not ok then
			log:Warn(`teleport retry for {player.Name} failed: {tostring(err)}`)
			retryOrGiveUp(player, entry, "Failure")
		end
	end)
end

local function onInitFailed(player: Player, result: Enum.TeleportResult, message: string)
	local entry = outgoing[player]
	if not entry or result == Enum.TeleportResult.IsTeleporting then
		return
	end
	log:Warn(`TeleportInitFailed for {player.Name}: {result.Name} {message}`)
	retryOrGiveUp(player, entry, result.Name)
end

-- Teleports a group (retrying the request). True once the request went out; the players are
-- then tracked until they leave, and `onFailed` runs for anyone whose teleport fails for good.
-- False (nobody tracked) if the request itself kept failing.
local function send(players: { Player }, placeId: number, options: TeleportOptions, onFailed: (Player) -> ()): boolean
	local group: { Player } = {}
	for _, player in players do
		if player.Parent == Players and not outgoing[player] then
			table.insert(group, player)
		end
	end
	if #group == 0 then
		return false
	end
	local entries: { [Player]: Outgoing } = {}
	for _, player in group do
		local entry: Outgoing = { PlaceId = placeId, Options = options, Attempts = 1, Deadline = 0, Extended = false, OnFailed = onFailed }
		outgoing[player] = entry
		entries[player] = entry
		teleportState[player] = nil
	end
	local ok, err = Rules.Retry(I.TeleportRetries, function(): boolean
		local still: { Player } = {}
		for _, player in group do
			if player.Parent == Players and outgoing[player] == entries[player] then
				table.insert(still, player)
			end
		end
		if #still > 0 then
			TeleportService:TeleportAsync(placeId, still, options)
		end
		return true
	end, sleep)
	if not ok then
		log:Warn(`TeleportAsync failed for {#group} players: {tostring(err)}`)
		for player, entry in entries do
			if outgoing[player] == entry then
				outgoing[player] = nil
			end
		end
		return false
	end
	for player, entry in entries do
		if outgoing[player] == entry then
			armDeadline(player, entry)
		end
	end
	return true
end

-- INSTANCE SERVER --------------------------------------------------------------------------------

local function currentHandler(): Handler?
	local current = record
	return if current then handlers[current.Mode] else nil
end

local function returnDestination(): string?
	local current, handler = record, currentHandler()
	if not current or not handler then
		return nil
	end
	local ok, result = pcall(handler.ReturnTo, current)
	return if ok and type(result) == "string" then result else nil
end

-- Sends players from this instance server to a public server of this place. The destination is
-- written into each profile (PendingReturn) and saved before the teleport; the teleport data
-- carries nothing a client could use to pick its own arrival point.
local function sendHome(players: { Player }, destination: string?)
	local going: { Player } = {}
	local pending = Rules.PendingReturn(destination, os.time())
	for _, player in players do
		if player.Parent == Players and not outgoing[player] then
			InstanceService.Leaving:Fire(player)
			DataService.Set(player, { "PendingReturn" }, table.clone(pending))
			-- Saves now. A trade lock can't hold anyone here: the way home is not optional.
			DataService.PrepareTeleport(player)
			table.insert(going, player)
		end
	end
	if #going == 0 then
		return
	end
	notify(going, "Instances.ReturningNow", nil, "Info")
	local options = Instance.new("TeleportOptions")
	options:SetTeleportData(Rules.ReturnData())
	local function onFailed(player: Player)
		log:Warn(`could not send {player.Name} home; asking them to rejoin`)
		player:Kick(Strings.Instances.ReturnFailedKick)
	end
	task.spawn(function()
		if not send(going, game.PlaceId, options, onFailed) then
			for _, player in going do
				if player.Parent == Players then
					onFailed(player)
				end
			end
		end
	end)
end

local function reject(player: Player, reason: string?)
	log:Warn(`turned away {player.Name} ({reason or "?"})`)
	notify({ player }, "Instances.NotYours", nil, "Warning")
	sendHome({ player }, nil)
end

local function prepare()
	local current, handler = record, currentHandler()
	if prepared or not current or not handler or phase == "Returning" then
		return
	end
	local ok, result = pcall(handler.Prepare, current)
	if ok and result == true then
		prepared = true
		log:Info(`prepared {current.Mode} {current.Id} for {#current.Members}`)
		-- Members whose profile loaded while the run space didn't exist were held without a
		-- character (CharacterService only spawns on load); they rise now.
		local held: { Player } = {}
		for player in admitted do
			if player.Parent == Players and not player.Character and DataService.IsLoaded(player) then
				table.insert(held, player)
			end
		end
		if #held > 0 then
			InstanceService.Prepared:Fire(held)
		end
	else
		log:Error(`could not prepare {current.Mode} {current.Id}: {if ok then "refused" else tostring(result)}`)
		InstanceService.ReturnAll("Failed")
	end
end

-- Decides once per player whether this instance server admits them.
local function evaluate(player: Player)
	if not isInstance or evaluated[player] or player.Parent ~= Players then
		return
	end
	evaluated[player] = true
	local raw, source = joinData(player)
	if phase == "Returning" then
		reject(player, "Returning")
		return
	end
	local current = record
	if not current then
		local parsed, why = Rules.ParseInstance(raw, limits())
		if not parsed then
			reject(player, why)
			return
		end
		local ok, reason = Rules.Admit(parsed, player.UserId, source, game.PlaceId, raw)
		if not ok then
			reject(player, reason)
			return
		end
		record = parsed
		current = parsed
		phase = "Gathering"
		gatherStarted = os.clock()
		log:Info(`instance for {parsed.Mode} {parsed.Id}, {#parsed.Members} expected`)
		prepare()
	end
	local ok, reason = Rules.Admit(current :: Record, player.UserId, source, game.PlaceId, raw)
	if not ok then
		reject(player, reason)
		return
	end
	admitted[player] = true
end

local function isReady(player: Player): boolean
	if player.Parent ~= Players or not DataService.IsLoaded(player) then
		return false
	end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0
end

-- Rebuilds the source party (record.Party) from those of `players` who belong to it.
local function regroup(players: { Player })
	local current = record
	local party = current and current.Party
	if not party then
		return
	end
	local group: { Player } = {}
	for _, player in players do
		if player.Parent == Players and table.find(party.Members, player.UserId) then
			table.insert(group, player)
		end
	end
	local ok, err = pcall(function()
		PartyService.Regroup(group, party.Leader, party.LootMode)
	end)
	if not ok then
		log:Error(`party rebuild failed: {tostring(err)}`)
	end
end

local function watch()
	local current, handler = record, currentHandler()
	if not current or phase == "Returning" then
		return
	end
	if phase == "Gathering" then
		local ready: { Player } = {}
		for player in admitted do
			if isReady(player) then
				table.insert(ready, player)
			end
		end
		local decision = Rules.ArrivalDecision(#current.Members, #ready, os.clock() - gatherStarted, I.ArrivalTimeout)
		if decision == "Abandon" then
			log:Warn("nobody arrived in time")
			InstanceService.ReturnAll("NoParty")
		elseif decision == "Start" then
			if not prepared or not handler then
				InstanceService.ReturnAll("Failed")
				return
			end
			phase = "Running"
			for _, player in ready do
				begun[player] = true
			end
			regroup(ready)
			log:Info(`starting {current.Mode} {current.Id} with {#ready}/{#current.Members}`)
			local begin = handler.Begin
			task.spawn(function()
				local ok, err = pcall(function()
					begin(ready)
				end)
				if not ok then
					log:Error(`{current.Mode} {current.Id} failed to begin: {tostring(err)}`)
					InstanceService.ReturnAll("Failed")
				end
			end)
		elseif #ready ~= lastReadyCount then
			lastReadyCount = #ready
			notify(ready, "Instances.Waiting", { count = #ready, total = #current.Members }, "Info")
		end
	elseif phase == "Running" and handler then
		-- Late members only need a loaded profile: the handler may hold their character back.
		local join = handler.Join
		for player in admitted do
			if not begun[player] and player.Parent == Players and DataService.IsLoaded(player) then
				begun[player] = true
				task.spawn(function()
					local ok, joined = pcall(join, player)
					if not ok or joined ~= true then
						notify({ player }, "Instances.Refused", nil, "Warning")
						sendHome({ player }, returnDestination())
						return
					end
					local inRun: { Player } = {}
					for member in begun do
						table.insert(inRun, member)
					end
					regroup(inRun)
				end)
			end
		end
	end
end

-- PUBLIC API -------------------------------------------------------------------------------------

-- Sends a gathered group to a reserved server for this run. False when that can't happen (Studio,
-- unpublished, disabled, failures): the caller runs its in-server copy for the group. When true,
-- `fallback` (if given) later runs here for anyone whose teleport fails for good.
function InstanceService.Begin(mode: Mode, id: string, players: { Player }, fallback: (({ Player }) -> ())?): boolean
	local allowed, why = Rules.UseReserved({
		Enabled = I.UseReservedServers,
		PlaceId = game.PlaceId,
		IsStudio = RunService:IsStudio(),
		InInstance = isInstance,
	})
	if not allowed then
		log:Debug(`{mode} {id}: in this server ({why})`)
		return false
	end
	local group: { Player } = {}
	for _, player in players do
		if player.Parent == Players and not outgoing[player] and not starting[player] and not table.find(group, player) then
			table.insert(group, player)
		end
	end
	if #group == 0 or #group > limits().MaxMembers then
		return false
	end
	for _, player in group do
		starting[player] = true
		-- An open trade could trade-lock the profile and keep them from leaving.
		InstanceService.Leaving:Fire(player)
	end
	local function release()
		for _, player in group do
			starting[player] = nil
		end
	end
	notify(group, "Instances.Opening", nil, "Info")

	local reserved, code = Rules.Retry(I.TeleportRetries, function(): string
		local accessCode = TeleportService:ReserveServer(game.PlaceId)
		return accessCode
	end, sleep)
	if not reserved or type(code) ~= "string" or code == "" then
		log:Warn(`ReserveServer failed for {mode} {id}: {tostring(code)}`)
		release()
		notify(group, "Instances.Failed", nil, "Warning")
		return false
	end

	-- Reserving yields: whoever is still here and can leave now goes; the rest stay.
	local going: { Player } = {}
	local staying: { Player } = {}
	local userIds: { number } = {}
	for _, player in group do
		if player.Parent ~= Players then
			continue
		end
		if DataService.PrepareTeleport(player) then
			table.insert(going, player)
			table.insert(userIds, player.UserId)
		else
			table.insert(staying, player)
		end
	end
	if #going == 0 then
		release()
		return false
	end
	-- The source party, so the instance server can rebuild it: the first party among those going,
	-- cut down to its members who are going, led by its leader (else the oldest of them).
	local party: Rules.PartyData? = nil
	for _, player in going do
		local info = PartyService.Describe(player)
		if info then
			local members: { number } = {}
			for _, userId in info.Members do
				if table.find(userIds, userId) then
					table.insert(members, userId)
				end
			end
			if #members >= 2 then
				local leader = if table.find(members, info.Leader) then info.Leader else members[1]
				party = { Leader = leader, Members = members, LootMode = info.LootMode }
				break
			end
		end
	end
	local options = Instance.new("TeleportOptions")
	options.ReservedServerAccessCode = code
	options:SetTeleportData(Rules.InstanceData(mode, id, userIds, game.PlaceId, party))
	local function onFailed(player: Player)
		notify({ player }, "Instances.Failed", nil, "Warning")
		if fallback then
			fallback({ player })
		end
	end
	local sent = send(going, game.PlaceId, options, onFailed)
	release()
	if not sent then
		notify(going, "Instances.Failed", nil, "Warning")
		return false
	end
	log:Info(`{mode} {id}: {#going} teleporting to a reserved server`)
	if #staying > 0 then
		notify(staying, "Instances.Failed", nil, "Warning")
		if fallback then
			task.spawn(fallback, staying)
		end
	end
	return true
end

-- True while a player is being sent to (or reserving) another server: they can't join gatherings.
function InstanceService.IsTeleporting(player: Player): boolean
	return outgoing[player] ~= nil or starting[player] == true
end

-- True in a reserved instance server of this place.
function InstanceService.IsInstanceServer(): boolean
	return isInstance
end

-- The run this instance server holds, or nil (public servers, or before a valid arrival).
function InstanceService.GetMode(): Record?
	local current = record
	if not current then
		return nil
	end
	local party = current.Party
	return {
		Mode = current.Mode,
		Id = current.Id,
		Members = table.clone(current.Members),
		ReturnPlaceId = current.ReturnPlaceId,
		Party = if party then { Leader = party.Leader, Members = table.clone(party.Members), LootMode = party.LootMode } else nil,
	}
end

-- In an instance server: whether this player was admitted to the run.
function InstanceService.IsMember(player: Player): boolean
	if not isInstance then
		return false
	end
	evaluate(player)
	return admitted[player] == true
end

-- In an instance server, nobody gets a character before the run space exists, and non-members
-- never do (they are on their way home).
function InstanceService.HoldsSpawn(player: Player): boolean
	if not isInstance then
		return false
	end
	return not InstanceService.IsMember(player) or not prepared
end

-- The mode's handler (DungeonService, GuardianService). Prepares at once if the run is known.
function InstanceService.Register(mode: Mode, handler: Handler)
	handlers[mode] = handler
	local current = record
	if current and current.Mode == mode then
		prepare()
	end
end

-- Instance server: everyone goes home (after ReturnTimeout when the run ended, at once on a failure).
function InstanceService.ReturnAll(reason: string)
	if not isInstance or phase == "Returning" then
		return
	end
	phase = "Returning"
	local delay = Rules.ReturnDelay(reason, I.ReturnTimeout)
	log:Info(`returning everyone ({reason}) in {delay}s`)
	if delay > 0 then
		notify(Players:GetPlayers(), "Instances.Returning", { seconds = delay }, "Info")
	else
		notify(Players:GetPlayers(), "Instances.RunFailed", nil, "Warning")
	end
	task.delay(delay, function()
		sendHome(Players:GetPlayers(), returnDestination())
	end)
end

-- Instance server: these players go home now (left through an exit, refused, ...).
function InstanceService.ReturnPlayers(players: { Player }, reason: string)
	if not isInstance then
		return
	end
	log:Info(`returning {#players} ({reason})`)
	sendHome(players, returnDestination())
end

-- Public server: where a player coming home from a run should arrive ("Waystone" or "Gate", and
-- the id), read from their profile's PendingReturn (written by the instance server, never from
-- teleport data) and cleared on the first read, so it is used once; stale ones (older than
-- ReturnWindow) are dropped. The caller checks the point exists on this floor.
function InstanceService.TakeReturnTo(player: Player): (string?, string?)
	if isInstance then
		return nil, nil
	end
	local kind, id, cleared = Rules.TakePending(DataService.Get(player, { "PendingReturn" }), os.time(), I.ReturnWindow)
	if cleared then
		DataService.Set(player, { "PendingReturn" }, cleared)
	end
	return kind, id
end

-- The player's party members (not the player) alive within `radius` of `position`.
function InstanceService.PartyNear(player: Player, position: Vector3, radius: number): { Player }
	local near: { Player } = {}
	local party = PartyService.GetParty(player)
	if not party then
		return near
	end
	for _, member in party do
		if member == player or member.Parent ~= Players then
			continue
		end
		local character = member.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if root and root:IsA("BasePart") and humanoid and humanoid.Health > 0 and (root.Position - position).Magnitude <= radius then
			table.insert(near, member)
		end
	end
	return near
end

-- LIFECYCLE --------------------------------------------------------------------------------------

-- Everything is wired here: `Start` is this service's public "start a run" call, so there is no
-- Start phase. Nothing below yields; the watch loop runs in its own thread.
function InstanceService.Init()
	isInstance = game.PrivateServerId ~= "" and game.PrivateServerOwnerId == 0
	phase = if isInstance then "Waiting" else "Public"
	TeleportService.TeleportInitFailed:Connect(onInitFailed)
	local function track(player: Player)
		player.OnTeleport:Connect(function(state: Enum.TeleportState)
			if player.Parent == Players then
				teleportState[player] = state
			end
		end)
	end
	Players.PlayerAdded:Connect(track)
	for _, player in Players:GetPlayers() do
		track(player)
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		outgoing[player] = nil
		starting[player] = nil
		teleportState[player] = nil
		evaluated[player] = nil
		admitted[player] = nil
		begun[player] = nil
	end)
	if not isInstance then
		return
	end
	log:Info("this is a reserved instance server")
	Players.PlayerAdded:Connect(evaluate)
	for _, player in Players:GetPlayers() do
		evaluate(player)
	end
	task.spawn(function()
		while true do
			task.wait(WATCH_INTERVAL)
			local ok, err = pcall(function()
				watch()
			end)
			if not ok then
				log:Error(`watch failed: {tostring(err)}`)
			end
		end
	end)
end

return InstanceService
