--!strict
--[[
	TrainingService
	Practice dummies (Phase 3, before real enemies arrive in Phase 4).

	Dummies are Models in the world tagged "TrainingDummy" with a Humanoid
	and a DummyType attribute:
	  "Training"  takes hits and never dies: posture breaks, finishers and
	              damage numbers can all be practised on it.
	  "Sparring"  also swings back every few seconds after a red warning
	              glow, so blocking, parrying and dodging can be practised.
	Both heal fully after a few seconds without being hit, and stand back
	up straight away if knocked to 0.
	They fight through CombatService exactly like enemies will, so a parry
	that works here works everywhere.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Attributes = require(Shared.Attributes)
local Log = require(Shared.Util.Log)

local TargetService = require(script.Parent.TargetService)
local CombatService = require(script.Parent.CombatService)

local A = Attributes.Names
local T = Config.World.Training
local log = Log.new("TrainingService")

local TrainingService = {}

local registered: { [Model]: boolean } = {}

local function now(): number
	return Workspace:GetServerTimeNow()
end

local function nearestPlayer(model: Model, range: number): TargetService.Target?
	local self = TargetService.Get(model)
	if not self then
		return nil
	end
	local best: TargetService.Target? = nil
	local bestDistance = range
	for _, target in TargetService.GetAll() do
		if target.Kind == "Player" and TargetService.IsAlive(target) then
			local distance = (target.Root.Position - self.Root.Position).Magnitude
			if distance <= bestDistance then
				best = target
				bestDistance = distance
			end
		end
	end
	return best
end

-- Sparring loop: face the nearest player, glow red, then swing.
local function spar(model: Model, highlight: Highlight)
	local S = T.Sparring
	while registered[model] do
		task.wait(S.Interval)
		local self = TargetService.Get(model)
		local target = nearestPlayer(model, S.AggroRange)
		if self and target and TargetService.IsAlive(self) and not CombatService.IsBusy(model) then
			local origin = self.Root.Position
			local toTarget = target.Root.Position - origin
			local aim = Vector3.new(toTarget.X, 0, toTarget.Z)
			if aim.Magnitude > 0.1 then
				aim = aim.Unit
				model:PivotTo(CFrame.lookAt(origin, origin + aim))
				highlight.Enabled = true
				task.wait(S.Telegraph)
				highlight.Enabled = false
				-- A stagger or break during the telegraph cancels the swing.
				if registered[model] and not CombatService.IsBusy(model) then
					CombatService.NpcSwing(model, {
						Reach = S.Reach,
						Arc = S.Arc,
						Aim = aim,
						Hit = {
							Damage = S.Damage,
							Posture = S.Posture,
							Kind = "Npc",
							Parryable = true,
							Blockable = true,
							HitStun = Config.Combat.HitStun.NpcLight,
							CritChance = 0,
							CritMultiplier = 1,
						},
					})
				end
			end
		end
	end
end

local function register(instance: Instance)
	if not instance:IsA("Model") or registered[instance] then
		return
	end
	local model = instance
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		log:Warn(`Dummy {model:GetFullName()} has no Humanoid`)
		return
	end
	local kind = model:GetAttribute(A.DummyType)
	-- Dummies never die: health can reach 0 but they stand straight back up.
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Dead, false)
	humanoid.BreakJointsOnDeath = false
	humanoid.MaxHealth = T.MaxHealth
	humanoid.Health = T.MaxHealth
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	model:SetAttribute(A.NameKey, if kind == "Sparring" then "Training.SparringDummy" else "Training.TrainingDummy")

	if not TargetService.Register(model, "Dummy", "Enemies") then
		log:Warn(`Dummy {model:GetFullName()} needs a HumanoidRootPart or PrimaryPart`)
		return
	end
	registered[model] = true
	CombatService.SetMaxPosture(model, T.MaxPosture)

	local lastHit = 0
	local lastHealth = humanoid.Health
	humanoid.HealthChanged:Connect(function(health: number)
		if health < lastHealth then
			lastHit = now()
			if health <= 0 then
				task.delay(T.ResetDelay, function()
					humanoid.Health = humanoid.MaxHealth
					CombatService.ResetPosture(model)
				end)
			end
		end
		lastHealth = health
	end)
	task.spawn(function()
		while registered[model] do
			task.wait(1)
			if humanoid.Health < humanoid.MaxHealth and now() - lastHit >= T.RegenDelay then
				humanoid.Health = humanoid.MaxHealth
			end
		end
	end)

	if kind == "Sparring" then
		local highlight = Instance.new("Highlight")
		highlight.Name = "Telegraph"
		highlight.FillColor = Color3.fromHex("#E2483D")
		highlight.OutlineColor = Color3.fromHex("#E2483D")
		highlight.FillTransparency = 0.45
		highlight.Enabled = false
		highlight.Parent = model
		task.spawn(spar, model, highlight)
	end
	model.AncestryChanged:Connect(function()
		if not model:IsDescendantOf(Workspace) then
			registered[model] = nil
		end
	end)
end

function TrainingService.Start()
	for _, model in CollectionService:GetTagged(Attributes.Tags.TrainingDummy) do
		register(model)
	end
	CollectionService:GetInstanceAddedSignal(Attributes.Tags.TrainingDummy):Connect(register)
end

return TrainingService
