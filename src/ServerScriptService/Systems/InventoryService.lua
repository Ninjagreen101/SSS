--!strict
--[[
	InventoryService
	The only system that changes items, equipment and currencies.

	Transactions: every change runs InventoryRules on a private copy of the
	item branches (bag, bank, equipment, currencies, item state, recipes,
	Beacons, hotbar). If any rule fails, the copy is thrown away and nothing
	changed. If all succeed, the copy is committed in one non-yielding step
	(DataService.RunAtomic) and only what actually changed is replicated:
	single items by uid, other branches whole. So a purchase can never take
	your gold without giving the item, and a pickup sends one item, not the
	whole bag.

	Handles the inventory requests (equip, use, lock, split, salvage, quick
	slots, recipe tracking, Beacon cores), quick items (Z / X: potions, food
	buffs, throwables), the starter kit, death wear on equipped gear, and
	recipe discovery toasts. Stations (shops, smithing, bank, crafting) and
	loot call Transact / Give from their own services.

	Results go to the client as ItemResult(ok, reason, payload); the client
	turns them into toasts, reveals and sounds.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Attributes = require(Shared.Attributes)
local Types = require(Shared.Types)
local Net = require(Shared.Net)
local Items = require(Shared.Data.Items)
local Spells = require(Shared.Data.Spells)
local Rules = require(Shared.Data.InventoryRules)
local TableUtil = require(Shared.Util.TableUtil)
local Log = require(Shared.Util.Log)

local DataService = require(script.Parent.DataService)
local GearService = require(script.Parent.GearService)
local VitalsService = require(script.Parent.VitalsService)
local CombatService = require(script.Parent.CombatService)
local StatusService = require(script.Parent.StatusService)
local TargetService = require(script.Parent.TargetService)
local AnalyticsService = require(script.Parent.AnalyticsService)

type PlayerData = Types.PlayerData
type Mutation = (draft: PlayerData) -> (boolean, string?)

local A = Attributes.Names
local log = Log.new("InventoryService")

-- Branches a transaction may change. Everything else on the draft is a
-- read-only reference to the live profile (Level, Stats, Floors...).
local BRANCHES: { string } = { "Inventory", "Bank", "Equipped", "Currencies", "ItemState", "RecipesKnown", "Beacons", "Hotbar" }

local InventoryService = {}

local random = Random.new()

local function now(): number
	return Workspace:GetServerTimeNow()
end

local function deepEqual(a: any, b: any): boolean
	if type(a) ~= "table" or type(b) ~= "table" then
		return a == b
	end
	for key, value in a do
		if not deepEqual(value, b[key]) then
			return false
		end
	end
	for key in b do
		if a[key] == nil then
			return false
		end
	end
	return true
end

-- RESULTS ------------------------------------------------------------------------

function InventoryService.Result(player: Player, ok: boolean, reason: string?, payload: { [string]: any }?)
	Net.Fire("ItemResult", player, ok, reason or "Success", payload or {})
end

-- TRANSACTIONS -----------------------------------------------------------------------

-- Runs `mutate` on a draft and commits it only if it returns true.
-- `mutate` must not yield. Returns ok, reason (reason can be set on success,
-- e.g. "UpgradeFailed").
function InventoryService.Transact(player: Player, mutate: Mutation): (boolean, string?)
	if DataService.IsTradeLocked(player) then
		return false, "TradeLocked"
	end
	local data = DataService.GetData(player)
	if not data then
		return false, "NotLoaded"
	end
	local live = data :: any
	local draft = table.clone(live)
	for _, branch in BRANCHES do
		draft[branch] = TableUtil.DeepCopy(live[branch])
	end

	local ran, ok, reason = pcall(mutate, draft :: PlayerData)
	if not ran then
		log:Error(`transaction for {player.Name} errored: {ok}`)
		return false, "Invalid"
	end
	if not ok then
		return false, reason
	end

	local learned = {}
	for recipeId in draft.RecipesKnown do
		if not live.RecipesKnown[recipeId] then
			table.insert(learned, recipeId)
		end
	end

	local paths: { { string } } = {}
	local committed, err = DataService.RunAtomic({ player }, function()
		for _, name in BRANCHES do
			local branch: string = name
			local before, after = live[branch], draft[branch]
			if name == "Inventory" or name == "Bank" then
				-- Items one by one; the other fields (NextUid, Capacity) by key.
				for uid, item in after.Items do
					if not deepEqual(before.Items[uid], item) then
						table.insert(paths, { branch, "Items", uid })
					end
				end
				for uid in before.Items do
					if after.Items[uid] == nil then
						table.insert(paths, { branch, "Items", uid })
					end
				end
				for key, value in after do
					if key ~= "Items" and before[key] ~= value then
						table.insert(paths, { branch, key })
					end
				end
				live[branch] = after
			elseif not deepEqual(before, after) then
				table.insert(paths, { branch })
				live[branch] = after
			end
		end
	end)
	if not committed then
		log:Error(`commit for {player.Name} failed: {err}`)
		return false, "Invalid"
	end
	for _, path in paths do
		DataService.Replicate(player, path)
	end
	if #learned > 0 then
		table.sort(learned)
		InventoryService.Result(player, true, "RecipeLearned", { Recipes = learned })
	end
	return true, reason
end

-- Gives fresh items (loot, quests, dev tools). Rarity is a minimum.
function InventoryService.Give(player: Player, defId: string, count: number, rarity: string?): (boolean, string?)
	return InventoryService.Transact(player, function(draft: PlayerData): (boolean, string?)
		return Rules.Grant(draft, defId, count, random, rarity)
	end)
end

-- Adds an already-rolled item (loot drops carry their rolls).
function InventoryService.AddItem(player: Player, item: Types.ItemInstance, count: number): (boolean, string?)
	return InventoryService.Transact(player, function(draft: PlayerData): (boolean, string?)
		return Rules.Add(draft, item, count)
	end)
end

function InventoryService.IsAlive(player: Player): boolean
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0
end

local function rootOf(player: Player): BasePart?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

-- CONSUMABLES ----------------------------------------------------------------------

local function playersNear(position: Vector3): { Player }
	local list = {}
	for _, other in Players:GetPlayers() do
		local root = rootOf(other)
		if root and (root.Position - position).Magnitude <= Config.Combat.FeedbackRadius then
			table.insert(list, other)
		end
	end
	return list
end

-- A thrown consumable bursts at `aim`: damage, posture and its element's status.
local function throwAt(player: Player, effect: Items.ConsumableEffect, aim: Vector3)
	local character = player.Character
	local root = rootOf(player)
	if not character or not root then
		return
	end
	local offset = aim - root.Position
	if offset.Magnitude > Config.Items.Consumables.ThrowRange then
		aim = root.Position + offset.Unit * Config.Items.Consumables.ThrowRange
	end
	local radius = effect.Radius or 6
	local element = if effect.Element then Spells.Attunement(effect.Element) else nil
	Net.FireList("SpellVisual", playersNear(aim), character, "", "Throw", {
		From = root.Position,
		To = aim,
		Radius = radius,
		Color = if element then element.Color else Color3.new(1, 1, 1),
	})
	-- The burst lands when the flask does (ThrowTime matches the client arc).
	task.delay(Config.Items.Consumables.ThrowTime, function()
		for model, target in TargetService.GetAll() do
			if target.Team ~= "Players" and TargetService.IsAlive(target) and (target.Root.Position - aim).Magnitude <= radius then
				local outcome = CombatService.SpellHit(character, model, {
					Damage = effect.Damage or 0,
					Posture = effect.Posture or 0,
					Kind = "Spell",
					Parryable = false,
					Blockable = true,
					HitStun = Config.Combat.HitStun.Light,
					CritChance = 0,
					CritMultiplier = 1,
					Element = effect.Element,
				}, aim)
				if element and outcome ~= nil and outcome ~= "Dodge" and outcome ~= "PerfectDodge" then
					StatusService.Apply(model, element.Status)
				end
			end
		end
	end)
end

-- Uses one `defId` from the bag. `aim` is where throwables land.
local function useConsumable(player: Player, defId: string, aim: Vector3?): (boolean, string?)
	local def = Items.Get(defId)
	local effect = def and def.Effect
	if not def or not effect then
		return false, "Invalid"
	end
	if not InventoryService.IsAlive(player) then
		return false, "Dead"
	end
	local ready = player:GetAttribute(A.QuickItemReadyAt)
	if type(ready) == "number" and now() < ready then
		return false, "Cooldown"
	end
	local data = DataService.GetData(player)
	if data and data.Level < def.RequiredLevel then
		return false, "Level"
	end
	if effect.Kind == "Heal" then
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.Health >= humanoid.MaxHealth then
			return false, "Healthy"
		end
	elseif effect.Kind == "Current" then
		if VitalsService.GetCurrent(player) >= VitalsService.GetMaxCurrent(player) then
			return false, "Healthy"
		end
	end
	local ok, reason = InventoryService.Transact(player, function(draft: PlayerData): (boolean, string?)
		-- Take from the smallest unlocked stack.
		local chosen: Types.ItemInstance? = nil
		for _, item in draft.Inventory.Items do
			if item.DefId == defId and not item.Locked and (not chosen or item.Count < chosen.Count) then
				chosen = item
			end
		end
		if not chosen then
			return false, "Missing"
		end
		return Rules.Remove(draft, chosen.Uid, 1)
	end)
	if not ok then
		return false, reason
	end
	player:SetAttribute(A.QuickItemReadyAt, now() + Config.Items.Consumables.SharedCooldown)
	if effect.Kind == "Heal" then
		VitalsService.Heal(player, VitalsService.GetMaxHealth(player) * (effect.Fraction or 0))
	elseif effect.Kind == "Current" then
		VitalsService.AddCurrent(player, VitalsService.GetMaxCurrent(player) * (effect.Fraction or 0))
	elseif effect.Kind == "Buff" and effect.Bonuses then
		GearService.AddBuff(player, effect.BuffId or defId, effect.Bonuses, effect.Duration or 60)
	elseif effect.Kind == "Throw" then
		local root = rootOf(player)
		throwAt(player, effect, aim or (if root then root.Position + root.CFrame.LookVector * 12 else Vector3.zero))
	end
	return true, nil
end

-- INVENTORY REQUESTS -------------------------------------------------------------------

local function beaconsUnlocked(data: PlayerData): boolean
	return not Config.Current.Beacons.UnlockWithAttunement or data.Attunements.Primary ~= ""
end

-- Slots a Beacon core: it leaves the bag and lives in Beacons.Skin; any
-- core already slotted comes back to the bag.
local function slotCore(draft: PlayerData, uid: string): (boolean, string?)
	local item = draft.Inventory.Items[uid]
	local def = item and Items.Get(item.DefId)
	if not item or not def or def.Type ~= "BeaconCore" then
		return false, "Invalid"
	end
	if not beaconsUnlocked(draft) then
		return false, "NeedAttunement"
	end
	if draft.Level < def.RequiredLevel then
		return false, "Level"
	end
	local previous = draft.Beacons.Skin
	local removed, reason = Rules.Remove(draft, uid, 1)
	if not removed then
		return false, reason
	end
	if Items.Get(previous) then
		local ok, why = Rules.Grant(draft, previous, 1, random)
		if not ok then
			return false, why
		end
	end
	draft.Beacons.Skin = def.Id
	return true, nil
end

local function unslotCore(draft: PlayerData): (boolean, string?)
	local current = draft.Beacons.Skin
	if not Items.Get(current) then
		return false, "Invalid"
	end
	local ok, reason = Rules.Grant(draft, current, 1, random)
	if not ok then
		return false, reason
	end
	draft.Beacons.Skin = ""
	return true, nil
end

local function onItemAction(player: Player, action: string, uid: string, argument: string, count: number)
	if action == "Use" then
		-- Consumables use the quick-item path (cooldown, effects); the rest are transactions.
		local data = DataService.GetData(player)
		local item = data and data.Inventory.Items[uid]
		local def = item and Items.Get(item.DefId)
		if item and def and def.Type == "Consumable" then
			if item.Locked then
				InventoryService.Result(player, false, "Locked")
				return
			end
			local ok, reason = useConsumable(player, item.DefId, nil)
			InventoryService.Result(player, ok, reason, { Action = "Use", DefId = item.DefId })
			return
		end
	end

	local payload: { [string]: any } = { Action = action }
	local ok, reason = InventoryService.Transact(player, function(draft: PlayerData): (boolean, string?)
		local item = draft.Inventory.Items[uid]
		if item then
			payload.DefId = item.DefId
			payload.Rarity = item.Rarity
		end
		if action == "Unequip" then
			return Rules.Unequip(draft, argument)
		elseif action == "Track" then
			if argument ~= "" and not draft.RecipesKnown[argument] then
				return false, "Unknown"
			end
			draft.ItemState.TrackedRecipe = if draft.ItemState.TrackedRecipe == argument then "" else argument
			payload.Recipe = draft.ItemState.TrackedRecipe
			return true, nil
		elseif action == "UnslotCore" then
			return unslotCore(draft)
		elseif action == "Seen" and uid == "" then
			for _, entry in draft.Inventory.Items do
				entry.New = false
			end
			return true, nil
		elseif action == "QuickSlot" and uid == "" then
			local index = tonumber(argument)
			if index ~= 1 and index ~= 2 then
				return false, "Invalid"
			end
			draft.Hotbar.Consumables[index :: number] = ""
			return true, nil
		end

		if not item then
			return false, "Missing"
		end
		local def = Items.Get(item.DefId)
		if not def then
			return false, "Invalid"
		end
		if action == "Equip" then
			local slot = if argument ~= "" then argument else Rules.DefaultSlot(draft, item)
			if not slot then
				return false, "Invalid"
			end
			payload.Slot = slot
			return Rules.Equip(draft, uid, slot)
		elseif action == "Lock" then
			item.Locked = not item.Locked
			return true, nil
		elseif action == "Seen" then
			item.New = false
			return true, nil
		elseif action == "Split" then
			return Rules.Split(draft, uid, count)
		elseif action == "Salvage" then
			payload.Yield = Rules.SalvageYield(item)
			return Rules.Salvage(draft, uid, random)
		elseif action == "QuickSlot" then
			local index = tonumber(argument)
			if def.Type ~= "Consumable" or (index ~= 1 and index ~= 2) then
				return false, "Invalid"
			end
			draft.Hotbar.Consumables[index :: number] = def.Id
			return true, nil
		elseif action == "SlotCore" then
			return slotCore(draft, uid)
		elseif action == "Use" then
			if def.Type == "Blueprint" then
				return Rules.LearnBlueprint(draft, uid)
			elseif def.Type == "BeaconCore" then
				return slotCore(draft, uid)
			end
			return false, "Invalid"
		end
		return false, "Invalid"
	end)
	-- Seen / Lock / Track are silent; everything else gets feedback.
	if not ok or (action ~= "Seen" and action ~= "Track") then
		InventoryService.Result(player, ok, reason, payload)
	end
end

local function onQuickItem(player: Player, slot: number, aim: Vector3)
	local data = DataService.GetData(player)
	local defId = data and data.Hotbar.Consumables[slot]
	if not defId or defId == "" then
		return
	end
	local ok, reason = useConsumable(player, defId, aim)
	InventoryService.Result(player, ok, reason, { Action = "Use", DefId = defId, Quick = true })
end

-- STARTER KIT, RECIPES, DEATH ----------------------------------------------------------------

local function onProfileLoaded(player: Player)
	InventoryService.Transact(player, function(draft: PlayerData): (boolean, string?)
		if not draft.ItemState.StarterGranted then
			for _, entry in Config.Items.StarterKit do
				if Rules.Count(draft, entry.Id) == 0 then
					local ok, reason = Rules.Grant(draft, entry.Id, entry.Count, random)
					if not ok then
						return false, reason
					end
				end
			end
			-- Equip the first weapon and fill the quick slots.
			for uid, item in draft.Inventory.Items do
				local def = Items.Get(item.DefId)
				if def and def.Type == "Weapon" and draft.Equipped.Weapon == "" then
					draft.Equipped.Weapon = uid
					item.New = false
				end
			end
			draft.Hotbar.Consumables = { "HealingDraught", "CurrentTonic" }
			draft.ItemState.StarterGranted = true
		end
		-- Mark everything carried as seen (key-material discovery) and learn base recipes.
		for _, item in draft.Inventory.Items do
			draft.ItemState.SeenItems[item.DefId] = true
		end
		-- Equipped gear is never "new" (older saves had the starter sword flagged).
		for _, uid in draft.Equipped do
			local item = if uid ~= "" then draft.Inventory.Items[uid] else nil
			if item then
				item.New = false
			end
		end
		Rules.LearnBaseRecipes(draft)
		return true, nil
	end)
end

local function onDied(player: Player)
	local data = DataService.GetData(player)
	if not data then
		return
	end
	-- Which equipped pieces are about to break (for a toast each).
	local breaking = {}
	for _, uid in data.Equipped do
		local item = if uid ~= "" then data.Inventory.Items[uid] else nil
		if item and item.Durability > 0 and item.Durability <= Config.Items.Durability.LossOnDeath then
			table.insert(breaking, item.DefId)
		end
	end
	local ok = InventoryService.Transact(player, function(draft: PlayerData): (boolean, string?)
		Rules.WearOnDeath(draft)
		return true, nil
	end)
	if ok then
		for _, defId in breaking do
			InventoryService.Result(player, true, "Broken", { DefId = defId })
		end
	end
end

local function bindCharacter(player: Player, character: Model)
	local humanoid = character:WaitForChild("Humanoid", 10)
	if humanoid and humanoid:IsA("Humanoid") and player.Character == character then
		humanoid.Died:Once(function()
			onDied(player)
		end)
	end
end

-- Spends currency through a transaction and logs it for analytics.
function InventoryService.Spend(player: Player, currency: string, amount: number, reasonTag: string): (boolean, string?)
	local ok, reason = InventoryService.Transact(player, function(draft: PlayerData): (boolean, string?)
		return Rules.Pay(draft, currency, amount)
	end)
	if ok then
		local data = DataService.GetData(player)
		AnalyticsService.Economy(player, "Sink", currency, amount, if data then Rules.Balance(data, currency) else 0, "Gameplay", reasonTag)
	end
	return ok, reason
end

function InventoryService.Init()
	Net.On("RequestItemAction", onItemAction)
	Net.On("RequestQuickItem", onQuickItem)
end

function InventoryService.Start()
	DataService.ProfileLoaded:Connect(onProfileLoaded)
	local function onPlayer(player: Player)
		player.CharacterAdded:Connect(function(character: Model)
			bindCharacter(player, character)
		end)
		if player.Character then
			task.spawn(bindCharacter, player, player.Character)
		end
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		onPlayer(player)
		if DataService.IsLoaded(player) then
			onProfileLoaded(player)
		end
	end
end

return InventoryService
