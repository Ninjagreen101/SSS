--!strict
--[[
	GuardPoseController
	The two-handed guard. While a character's CombatState is "Blocking", its
	arms are re-posed every frame so the right hand holds the grip at a guard
	point in front of the chest (blade angled up across the body) and the left
	hand holds the grip just behind it.

	Why not just an animation: avatars have different proportions (arm length,
	hand size, shoulder width), so no fixed animation lands both hands on the
	grip for everyone. The Block animation still poses the legs and torso; the
	arms are solved here with two-bone IK from each avatar's own joint
	positions, after animations run and before the frame is drawn.

	Guard positions come from Config.Combat.Block.GuardPose, written for the
	default R15 body and scaled to each avatar's arm length and shoulder width.

	Runs on every client for every player's character. It is visual only:
	blocking itself is decided by the server. Twin weapons (one blade in each
	hand) keep the animated pose.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Attributes = require(Shared.Attributes)
local Items = require(Shared.Data.Items)
local Maid = require(Shared.Util.Maid)
local WeaponGrip = require(Shared.Util.WeaponGrip)

local A = Attributes.Names
local GUARD = Config.Combat.Block.GuardPose

local GuardPoseController = {}

-- A Motor6D or an AnimationConstraint, seen the same way:
-- child = parent * C0 * Transform * C1:Inverse()
type Joint = {
	Instance: Instance,
	Motor: Motor6D?,
	Attachment0: Attachment?,
	Attachment1: Attachment?,
}

type Arm = {
	Shoulder: Joint,
	Elbow: Joint,
	Wrist: Joint,
	Hand: BasePart,
	Pole: Vector3, -- upper-torso space, already scaled
}

type Rig = {
	Character: Model,
	Humanoid: Humanoid,
	Root: BasePart,
	RootJoint: Joint,
	Waist: Joint,
	Right: Arm,
	Left: Arm,
	Grip: CFrame, -- right hand's grip frame in upper-torso space, already scaled
	Weight: number, -- 0 = animated arms, 1 = full guard pose
}

local rigs: { [Model]: Rig? } = {}
local maids: { [Model]: Maid.Maid } = {}

-- JOINTS ---------------------------------------------------------------------------

local function c0(joint: Joint): CFrame
	local motor = joint.Motor
	if motor then
		return motor.C0
	end
	return (joint.Attachment0 :: Attachment).CFrame
end

local function c1(joint: Joint): CFrame
	local motor = joint.Motor
	if motor then
		return motor.C1
	end
	return (joint.Attachment1 :: Attachment).CFrame
end

local function getTransform(joint: Joint): CFrame
	return (joint.Instance :: any).Transform
end

local function setTransform(joint: Joint, transform: CFrame)
	(joint.Instance :: any).Transform = transform
end

-- The joint that attaches `child` to its parent part.
local function jointFor(character: Model, child: BasePart): Joint?
	for _, item in character:GetDescendants() do
		if item:IsA("Motor6D") then
			if item.Part1 == child and item.Part0 then
				local joint: Joint = { Instance = item :: Instance, Motor = item }
				return joint
			end
		elseif item:IsA("AnimationConstraint") then
			local a0, a1 = item.Attachment0, item.Attachment1
			if a0 and a1 and a1.Parent == child then
				local joint: Joint = { Instance = item :: Instance, Attachment0 = a0, Attachment1 = a1 }
				return joint
			end
		end
	end
	return nil
end

-- IK -------------------------------------------------------------------------------

-- Rotation whose +Y is `up` and whose X is `bend` (made perpendicular).
local function basis(up: Vector3, bend: Vector3): CFrame
	local y = up.Unit
	local x = (bend - y * bend:Dot(y)).Unit
	return CFrame.fromMatrix(Vector3.zero, x, y, x:Cross(y))
end

-- A bone's rest frame in its own part: +Y runs from the far joint back to the
-- near one, and the elbow bends about X.
local function restBasis(bone: Vector3): CFrame
	local y = -bone.Unit
	return basis(y, y:Cross(Vector3.zAxis))
end

-- Places a part so `pivot` (a point in the part) sits at `world`, with rotation `rotation`.
local function placed(rotation: CFrame, pivot: Vector3, world: Vector3): CFrame
	return CFrame.new(world - rotation:VectorToWorldSpace(pivot)) * rotation
end

-- Two-bone IK: puts the hand's grip point on `target` (hand -Z along the
-- blade) with the elbow bending toward `pole`, then blends the joints from
-- their animated pose by `weight`.
local function solveArm(arm: Arm, torso: CFrame, target: CFrame, weight: number)
	local shoulderFrame = torso * c0(arm.Shoulder)
	local shoulder = shoulderFrame.Position
	local upperBone = c0(arm.Elbow).Position - c1(arm.Shoulder).Position
	local lowerBone = c0(arm.Wrist).Position - c1(arm.Elbow).Position
	local a, b = upperBone.Magnitude, lowerBone.Magnitude
	if a < 1e-3 or b < 1e-3 then
		return
	end

	local hand = target * WeaponGrip.Offset(arm.Hand):Inverse()
	local wrist = (hand * c1(arm.Wrist)).Position
	local toWrist = wrist - shoulder
	local direction = if toWrist.Magnitude > 1e-4 then toWrist.Unit else torso.LookVector
	-- Out of reach: the arm straightens toward the target.
	local reach = math.clamp(toWrist.Magnitude, 1e-3, a + b - 1e-3)
	local cosA = math.clamp((a * a + reach * reach - b * b) / (2 * a * reach), -1, 1)
	local sinA = math.sqrt(1 - cosA * cosA)
	local poleOffset = torso * arm.Pole - shoulder
	local side = poleOffset - direction * poleOffset:Dot(direction)
	side = if side.Magnitude > 1e-4 then side.Unit else -torso.UpVector
	local elbow = shoulder + (direction * cosA + side * sinA) * a
	local wristReached = shoulder + direction * reach

	local upperDir = (elbow - shoulder).Unit
	local lowerDir = (wristReached - elbow).Unit
	local bend = upperDir:Cross(lowerDir)
	bend = if bend.Magnitude > 1e-4 then bend.Unit else torso.RightVector

	local upper = placed(basis(-upperDir, bend) * restBasis(upperBone):Inverse(), c1(arm.Shoulder).Position, shoulder)
	local lower = placed(basis(-lowerDir, bend) * restBasis(lowerBone):Inverse(), c1(arm.Elbow).Position, elbow)

	local shoulderT = shoulderFrame:Inverse() * upper * c1(arm.Shoulder)
	local elbowT = (upper * c0(arm.Elbow)):Inverse() * lower * c1(arm.Elbow)
	local wristT = ((lower * c0(arm.Wrist)):Inverse() * hand * c1(arm.Wrist)).Rotation

	setTransform(arm.Shoulder, getTransform(arm.Shoulder):Lerp(shoulderT, weight))
	setTransform(arm.Elbow, getTransform(arm.Elbow):Lerp(elbowT, weight))
	setTransform(arm.Wrist, getTransform(arm.Wrist):Lerp(wristT, weight))
end

-- The upper torso's frame this frame, from the animated root and waist joints.
local function torsoFrame(rig: Rig): CFrame
	local lower = rig.Root.CFrame * c0(rig.RootJoint) * getTransform(rig.RootJoint) * c1(rig.RootJoint):Inverse()
	return lower * c0(rig.Waist) * getTransform(rig.Waist) * c1(rig.Waist):Inverse()
end

local function isGuarding(rig: Rig): boolean
	local character = rig.Character
	if character:GetAttribute(A.CombatState) ~= "Blocking" or rig.Humanoid.Health <= 0 then
		return false
	end
	local weaponId = character:GetAttribute(A.WeaponId)
	local def = if type(weaponId) == "string" then Items.GetWeapon(weaponId) else nil
	return def ~= nil and def.Model.Twin ~= true
end

local function step(dt: number)
	local rate = dt / math.max(GUARD.BlendTime, 1e-3)
	for _, maybeRig in rigs do
		local rig = maybeRig :: Rig
		local goal = if isGuarding(rig) then 1 else 0
		if goal > rig.Weight then
			rig.Weight = math.min(goal, rig.Weight + rate)
		elseif goal < rig.Weight then
			rig.Weight = math.max(goal, rig.Weight - rate)
		end
		if rig.Weight > 0 then
			local torso = torsoFrame(rig)
			local grip = torso * rig.Grip
			local offHand = grip * CFrame.new(0, 0, WeaponGrip.OffHandGap(rig.Right.Hand, rig.Left.Hand))
			solveArm(rig.Right, torso, grip, rig.Weight)
			solveArm(rig.Left, torso, offHand, rig.Weight)
		end
	end
end

-- SETUP ----------------------------------------------------------------------------

-- Distance between two attachments on the same part (independent of pose).
local function span(part: BasePart, a: string, b: string): number?
	local p = part:FindFirstChild(a)
	local q = part:FindFirstChild(b)
	if p and q and p:IsA("Attachment") and q:IsA("Attachment") then
		return (p.Position - q.Position).Magnitude
	end
	return nil
end

-- Scales an upper-torso-space point from the default body to this avatar:
-- sideways by shoulder width, up and forward by arm length.
local function scaled(point: Vector3, scaleX: number, scale: number): Vector3
	return Vector3.new(point.X * scaleX, point.Y * scale, point.Z * scale)
end

-- The right hand's grip frame: blade (-Z) along BladeDirection, +Y toward the wrist.
local function guardFrame(scaleX: number, scale: number): CFrame
	local z = -GUARD.BladeDirection.Unit
	local wrist = GUARD.WristDirection
	local y = (wrist - z * wrist:Dot(z)).Unit
	return CFrame.fromMatrix(scaled(GUARD.GripOffset, scaleX, scale), y:Cross(z), y, z)
end

local function part(character: Model, name: string): BasePart?
	local found = character:WaitForChild(name, 10)
	return if found and found:IsA("BasePart") then found else nil
end

local function arm(character: Model, side: string, pole: Vector3): Arm?
	local upper = part(character, `{side}UpperArm`)
	local lower = part(character, `{side}LowerArm`)
	local hand = part(character, `{side}Hand`)
	if not (upper and lower and hand) then
		return nil
	end
	local shoulder = jointFor(character, upper)
	local elbow = jointFor(character, lower)
	local wrist = jointFor(character, hand)
	if not (shoulder and elbow and wrist) then
		return nil
	end
	return { Shoulder = shoulder, Elbow = elbow, Wrist = wrist, Hand = hand, Pole = pole }
end

local function build(character: Model): Rig?
	local humanoid = character:WaitForChild("Humanoid", 10)
	local root = part(character, "HumanoidRootPart")
	local lowerTorso = part(character, "LowerTorso")
	local torso = part(character, "UpperTorso")
	local rightUpper = part(character, "RightUpperArm")
	local rightLower = part(character, "RightLowerArm")
	if not (humanoid and humanoid:IsA("Humanoid") and root and lowerTorso and torso and rightUpper and rightLower) then
		return nil -- not an R15 character
	end
	local rootJoint = jointFor(character, lowerTorso)
	local waist = jointFor(character, torso)
	if not (rootJoint and waist) then
		return nil
	end

	local upperLength = span(rightUpper, "RightShoulderRigAttachment", "RightElbowRigAttachment")
	local lowerLength = span(rightLower, "RightElbowRigAttachment", "RightWristRigAttachment")
	local shoulders = span(torso, "LeftShoulderRigAttachment", "RightShoulderRigAttachment")
	local armLength = if upperLength and lowerLength then upperLength + lowerLength else GUARD.ReferenceArmLength
	local scale = armLength / GUARD.ReferenceArmLength
	local scaleX = (shoulders or GUARD.ReferenceShoulderWidth) / GUARD.ReferenceShoulderWidth

	local right = arm(character, "Right", scaled(GUARD.RightPole, scaleX, scale))
	local left = arm(character, "Left", scaled(GUARD.LeftPole, scaleX, scale))
	if not (right and left) then
		return nil
	end
	return {
		Character = character,
		Humanoid = humanoid,
		Root = root,
		RootJoint = rootJoint,
		Waist = waist,
		Right = right,
		Left = left,
		Grip = guardFrame(scaleX, scale),
		Weight = 0,
	}
end

local function bind(character: Model)
	local previous = maids[character]
	if previous then
		previous:Destroy()
	end
	local maid = Maid.new()
	maids[character] = maid
	maid:Add(function()
		rigs[character] = nil
	end)
	maid:Add(character.AncestryChanged:Connect(function(_, parent: Instance?)
		if not parent and maids[character] == maid then
			maid:Destroy()
			maids[character] = nil
		end
	end))
	-- Avatar parts can be swapped in after spawning; rebuild when they are.
	local function rebuild()
		if maids[character] ~= maid then
			return
		end
		rigs[character] = build(character)
	end
	maid:Add(character.DescendantAdded:Connect(function(item: Instance)
		if item:IsA("Motor6D") or item:IsA("AnimationConstraint") then
			task.defer(rebuild)
		end
	end))
	rebuild()
end

local function watch(player: Player)
	player.CharacterAdded:Connect(bind)
	if player.Character then
		task.spawn(bind, player.Character)
	end
end

function GuardPoseController.Start()
	Players.PlayerAdded:Connect(watch)
	for _, player in Players:GetPlayers() do
		watch(player)
	end
	-- After animations have posed the character, before physics and rendering.
	RunService.PreSimulation:Connect(step)
end

return GuardPoseController
