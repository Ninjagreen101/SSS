--!strict
--[[
	DevService (Studio only)
	Creates ServerStorage.DevHooks, a BindableFunction that test scripts and
	the Studio command bar can call to poke live server state:

		game.ServerStorage.DevHooks:Invoke("Damage", "PlayerName", 40)

	Commands (player name first, then arguments):
		Damage <amount>      Heal <amount>      Kill
		AddGold <amount>     SetLevel <level>   SetStamina <value>
		Respawn              Restore            Dump
		GotoLostCurrent      (teleports next to your Lost Current orb)
		Goto <Vector3>       teleports you there, e.g. Vector3.new(0, 4, -85)
		SetWeapon <defId>    wield any weapon, e.g. "StonejawGreatblade"
		Posture              your current combat state and posture
		SpawnMob <mobId>     an enemy 12 studs in front of you; add "!" for an
		                     elite, e.g. "Brinehulk!"
		ClearMobs            removes every enemy (spawn points refill later)
		Mobs                 every live enemy: id, state, health, target
		AddXP <amount>
		Attune <name>        sets your Attunement without the Shrine, e.g. "Tide";
		                     "Tide/Rime" sets a second one too
		Resonance <stacks>   sets your Resonance stacks (5 = Confluence ready)
		SetStat <"Stat=n">   sets one stat, e.g. "Control=40"
		Beacons <"a,b,c">    fills your Beacon slots, e.g. "Sentry,Aegis"
		GiveItem <"id[:rarity][xN]">  e.g. "Wispfangs:Legendary", "IronScrap x50"
		AddTokens <amount>   Floor Tokens for your current floor
		Pity <kills>         sets your Lowharbor pity counter (40 = next kill is Rare+)
		DropShowcase         drops one item of every rarity in front of you
		ClearBag             empties your bag (keeps equipped items)
		Wear <durability>    sets every equipped item's durability (0 = broken)
		Bag                  lists your bag: uid, item, rarity, count, upgrade
		SkillPoints <n>      adds skill points
		Position <id>        sets your Position without the Hall ("" clears it,
		                     and refunds the tree)
		ResetRespecs         makes your next respec free again
		AbilityReady         clears your ability cooldown
		Time <hour>          sets the clock, e.g. 19.5 (dusk)
		Weather <name>       "Clear", "Overcast" or "Rain"

	It never exists in a live server: Init returns immediately outside Studio,
	and ServerStorage is invisible to clients anyway.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Log = require(Shared.Util.Log)

local DataService = require(script.Parent.DataService)
local VitalsService = require(script.Parent.VitalsService)
local CharacterService = require(script.Parent.CharacterService)
local WeaponService = require(script.Parent.WeaponService)
local MobService = require(script.Parent.MobService)
local ProgressionService = require(script.Parent.ProgressionService)
local PositionService = require(script.Parent.PositionService)
local CurrentService = require(script.Parent.CurrentService)
local EnvironmentService = require(script.Parent.EnvironmentService)
local InventoryService = require(script.Parent.InventoryService)
local LootService = require(script.Parent.LootService)
local Rules = require(Shared.Data.InventoryRules)
local Positions = require(Shared.Data.Positions)
local ProgressionRules = require(Shared.Data.ProgressionRules)
local Types = require(Shared.Types)

local log = Log.new("DevService")

local DevService = {}

type Command = (player: Player, value: any) -> any

local function humanoidOf(player: Player): Humanoid?
	local character = player.Character
	return character and character:FindFirstChildOfClass("Humanoid")
end

local COMMANDS: { [string]: Command } = {
	Damage = function(player, value)
		return VitalsService.Damage(player, value or 10)
	end,
	Heal = function(player, value)
		return VitalsService.Heal(player, value or 1e6)
	end,
	Kill = function(player)
		local humanoid = humanoidOf(player)
		if humanoid then
			humanoid.Health = 0
		end
		return true
	end,
	AddGold = function(player, value)
		DataService.Increment(player, { "Currencies", "Gold" }, value or 100, 0, Config.Economy.MaxGold)
		local data = DataService.GetData(player)
		return data and data.Currencies.Gold
	end,
	SetLevel = function(player, value)
		-- Going up grants the stat and skill points of those levels, like real level-ups.
		return ProgressionService.SetLevel(player, if type(value) == "number" then value else 1)
	end,
	SkillPoints = function(player, value)
		return DataService.Increment(player, { "SkillPoints" }, if type(value) == "number" then value else 10, 0)
	end,
	Position = function(player, value)
		local data = DataService.GetData(player)
		if not data or type(value) ~= "string" or (value ~= "" and not Positions.Get(value)) then
			return "usage: Position \"Vanguard\" (or \"\" to clear)"
		end
		if value ~= data.Position then
			DataService.Increment(player, { "SkillPoints" }, ProgressionRules.SpentSkillPoints(data))
			DataService.Set(player, { "SkillTree" }, {})
			DataService.Set(player, { "Hotbar", "Ability" }, "")
			DataService.Set(player, { "Position" }, value)
		end
		return value
	end,
	ResetRespecs = function(player)
		DataService.Set(player, { "RespecCount" }, 0)
		return 0
	end,
	AbilityReady = function(player)
		PositionService.ResetCooldown(player)
		return true
	end,
	SetStamina = function(player, value)
		local spend = VitalsService.GetStamina(player) - (value or 0)
		if spend > 0 then
			VitalsService.SpendStamina(player, spend)
		end
		return VitalsService.GetStamina(player)
	end,
	Respawn = function(player)
		CharacterService.Respawn(player)
		return true
	end,
	GotoLostCurrent = function(player)
		local data = DataService.GetData(player)
		local stored = data and data.LostCurrent.Position
		if not stored or #stored ~= 3 then
			return false
		end
		CharacterService.Teleport(player, CFrame.new(stored[1] + 3, stored[2] + 3, stored[3]))
		return true
	end,
	Goto = function(player, value)
		if typeof(value) ~= "Vector3" then
			return "usage: Goto <Vector3>"
		end
		CharacterService.Teleport(player, CFrame.new(value))
		return true
	end,
	SetWeapon = function(player, value)
		return WeaponService.SetDevOverride(player, tostring(value))
	end,
	Posture = function(player)
		local character = player.Character
		if not character then
			return nil
		end
		return {
			State = character:GetAttribute("CombatState"),
			Posture = character:GetAttribute("Posture"),
			Weapon = character:GetAttribute("WeaponId"),
		}
	end,
	Restore = function(player)
		VitalsService.RestoreAll(player)
		return true
	end,
	SpawnMob = function(player, value)
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if type(value) ~= "string" or not root or not root:IsA("BasePart") then
			return "usage: SpawnMob <mobId>[!]"
		end
		local elite = string.sub(value, -1) == "!"
		local mobId = if elite then string.sub(value, 1, -2) else value
		local mob = MobService.Spawn(mobId, root.Position + root.CFrame.LookVector * 12, elite, nil)
		return if mob then mob.Model:GetFullName() else `unknown mob {mobId}`
	end,
	ClearMobs = function()
		MobService.Clear()
		return true
	end,
	Mobs = function()
		local result = {}
		for _, mob in MobService.GetAll() do
			table.insert(result, {
				Id = mob.MobId,
				Elite = mob.Elite,
				State = mob.State,
				Health = math.floor(mob.Humanoid.Health),
				Target = if mob.Target then mob.Target.Name else nil,
				Position = mob.Root.Position,
			})
		end
		return result
	end,
	Attune = function(player, value)
		if type(value) ~= "string" then
			return "usage: Attune <Primary>[/<Secondary>]"
		end
		local parts = string.split(value, "/")
		DataService.Set(player, { "Attunements", "Primary" }, parts[1])
		DataService.Set(player, { "Attunements", "Secondary" }, parts[2] or "")
		player:SetAttribute("Attunement", parts[1])
		-- Re-setting the level makes SpellService learn every Form it allows.
		local data = DataService.GetData(player)
		if data then
			DataService.Set(player, { "Level" }, data.Level)
		end
		return data and data.Hotbar.Spells
	end,
	Resonance = function(player, value)
		CurrentService.DevSetStacks(player, math.floor(tonumber(value) or 0))
		return CurrentService.GetStacks(player)
	end,
	SetStat = function(player, value)
		if type(value) ~= "string" then
			return "usage: SetStat \"Control=40\""
		end
		local name, amount = string.match(value, "^(%a+)=(%d+)$")
		local data = DataService.GetData(player)
		if not name or not amount or not data or (data.Stats :: any)[name] == nil then
			return "unknown stat"
		end
		DataService.Set(player, { "Stats", name }, tonumber(amount))
		return (data.Stats :: any)[name]
	end,
	Beacons = function(player, value)
		local list = if type(value) == "string" then string.split(value, ",") else {}
		local slots = {}
		for index = 1, Config.Current.Beacons.MaxSlots do
			slots[index] = list[index] or ""
		end
		DataService.Set(player, { "Beacons", "Slots" }, slots)
		return slots
	end,
	GiveItem = function(player, value)
		if type(value) ~= "string" then
			return "usage: GiveItem \"Wispfangs:Legendary\" or \"IronScrap x50\""
		end
		local spec, countText = string.match(value, "^([%w:]+)%s*x?(%d*)$")
		if not spec then
			return "bad format"
		end
		local parts = string.split(spec, ":")
		local ok, reason = InventoryService.Give(player, parts[1], tonumber(countText) or 1, parts[2])
		return if ok then "given" else reason
	end,
	AddTokens = function(player, value)
		local data = DataService.GetData(player)
		local floor = if data then data.Floors.Current else "1"
		local ok = InventoryService.Transact(player, function(draft: Types.PlayerData): (boolean, string?)
			Rules.Earn(draft, "FloorTokens", tonumber(value) or 10, floor)
			return true, nil
		end)
		return ok
	end,
	Pity = function(player, value)
		local ok = InventoryService.Transact(player, function(draft: Types.PlayerData): (boolean, string?)
			draft.ItemState.Pity[Config.Loot.DefaultZone] = math.floor(tonumber(value) or 0)
			return true, nil
		end)
		return ok
	end,
	DropShowcase = function(player)
		LootService.DevDropShowcase(player)
		return "dropped"
	end,
	ClearBag = function(player)
		local ok = InventoryService.Transact(player, function(draft: Types.PlayerData): (boolean, string?)
			for uid, item in draft.Inventory.Items do
				if Rules.EquippedSlot(draft, uid) == nil then
					draft.Inventory.Items[uid] = nil
				else
					item.Locked = false
				end
			end
			return true, nil
		end)
		return ok
	end,
	Wear = function(player, value)
		local ok = InventoryService.Transact(player, function(draft: Types.PlayerData): (boolean, string?)
			for _, uid in draft.Equipped do
				local item = if uid ~= "" then draft.Inventory.Items[uid] else nil
				if item then
					item.Durability = math.clamp(math.floor(tonumber(value) or 0), 0, Config.Items.Durability.Max)
				end
			end
			return true, nil
		end)
		return ok
	end,
	Bag = function(player)
		local data = DataService.GetData(player)
		if not data then
			return "not loaded"
		end
		local lines = {}
		for uid, item in data.Inventory.Items do
			table.insert(lines, `{uid} {item.DefId} {item.Rarity} x{item.Count} +{item.Upgrade} dur{item.Durability} affixes{#item.Affixes}{if item.Unique then " " .. item.Unique else ""}`)
		end
		table.sort(lines)
		return table.concat(lines, "\n")
	end,
	AddXP = function(player, value)
		return ProgressionService.AddXP(player, if type(value) == "number" then value else 100)
	end,
	Time = function(_, value)
		EnvironmentService.SetClock(if type(value) == "number" then value else 12)
		return EnvironmentService.GetClock()
	end,
	Weather = function(_, value)
		EnvironmentService.SetWeather(if type(value) == "string" then value else "Clear")
		return EnvironmentService.GetWeather()
	end,
	Dump = function(player)
		local humanoid = humanoidOf(player)
		local data = DataService.GetData(player)
		return {
			Health = humanoid and humanoid.Health,
			MaxHealth = humanoid and humanoid.MaxHealth,
			WalkSpeed = humanoid and humanoid.WalkSpeed,
			Stamina = VitalsService.GetStamina(player),
			Current = VitalsService.GetCurrent(player),
			Winded = VitalsService.IsWinded(player),
			Sprinting = VitalsService.IsSprinting(player),
			Gold = data and data.Currencies.Gold,
			Level = data and data.Level,
			Deaths = data and data.PlayStats.Deaths,
			LastWaystone = data and data.Waystones.Last,
			LostCurrent = data and data.LostCurrent,
			Attributes = player:GetAttributes(),
		}
	end,
}

local function findPlayer(name: string?): Player?
	if name then
		local exact = Players:FindFirstChild(name)
		if exact and exact:IsA("Player") then
			return exact
		end
	end
	-- No / unknown name: the first player (handy in Play Solo).
	return Players:GetPlayers()[1]
end

function DevService.Init()
	if not RunService:IsStudio() then
		return
	end
	local hook = Instance.new("BindableFunction")
	hook.Name = "DevHooks"
	hook.OnInvoke = function(command: string, playerName: string?, value: any): any
		local handler = COMMANDS[command]
		if not handler then
			return `unknown command {command}`
		end
		local player = findPlayer(playerName)
		if not player then
			return "no player"
		end
		return handler(player, value)
	end
	hook.Parent = ServerStorage
	log:Info("DevHooks ready (Studio only)")
end

return DevService
