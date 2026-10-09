--!strict
--[[
	WeaponGrip
	Where a weapon sits in a hand. Shared by WeaponService (which builds the
	weapon model) and GuardPoseController (which puts both hands on the grip
	while guarding), so the two always agree.

	The blade points along the hand's -Z axis (forward when the arm hangs at
	rest); +Z along the grip is toward the pommel.
]]

local Config = require(script.Parent.Parent.Config)

local WeaponGrip = {}

-- The grip's centre line in hand space.
function WeaponGrip.Offset(hand: BasePart): CFrame
	return CFrame.new(0, -hand.Size.Y * Config.Combat.WeaponModel.GripDrop, 0)
end

-- How far behind the main hand (toward the pommel) the off hand holds a
-- two-handed grip. Hands are stacked along the grip, so this follows their depth.
function WeaponGrip.OffHandGap(mainHand: BasePart, offHand: BasePart): number
	return (mainHand.Size.Z + offHand.Size.Z) / 2 * Config.Combat.Block.GuardPose.OffHandGap
end

-- How far behind the main hand the grip must reach to sit under both hands.
function WeaponGrip.TwoHandedReach(mainHand: BasePart, offHand: BasePart): number
	return WeaponGrip.OffHandGap(mainHand, offHand) + offHand.Size.Z * Config.Combat.WeaponModel.OffHandMargin
end

return WeaponGrip
