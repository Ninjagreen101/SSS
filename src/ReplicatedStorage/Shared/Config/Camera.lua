--!strict
-- Over-the-shoulder camera, lock-on and feedback tuning (Spec Sections 7 and 13).

local TableUtil = require(script.Parent.Parent.Util.TableUtil)

return TableUtil.DeepFreeze({
	FieldOfView = 70,
	SprintFieldOfView = 76,
	ShoulderOffset = Vector3.new(2.2, 2.0, 0),
	Distance = 11,
	MinDistance = 4,
	MaxDistance = 18,
	FollowSpeed = 18,
	LandingDip = 5, -- studs/s downward camera kick on a hard landing (scales with fall speed, up to 2.5x)
	LandingDipSpring = { Speed = 14, Damper = 0.55 },
	ZoomSmoothing = 12,
	CollisionEaseOut = 6, -- how fast the camera eases back out after a wall clears
	FocusSnapDistance = 30, -- teleports further than this snap the camera instead of gliding
	GamepadDeadzone = 0.15,
	ShakeFrequency = 25,
	LockOnTurnSpeed = 10,
	MaxFade = 0.85,
	LandingMinFallSpeed = 30, -- studs/s: softer landings don't dip the camera
	ZoomStep = 1.5,
	PitchMin = -70,
	PitchMax = 60,
	MouseDegreesPerPixel = 0.25,
	GamepadDegreesPerSecond = 220,
	TouchDegreesPerPixel = 0.35,
	PinchZoomSpeed = 0.04,
	CollisionRadius = 0.6,
	FadeDistance = 3, -- character fades when the camera gets this close
	ShoulderSwapSpeed = 10,
	FovSpeed = 6,
	PunchRecovery = 7, -- how fast a CameraController.Punch FOV kick settles
	PunchDegrees = 14, -- Confluence start / Camera = "Punch" steps
	ShakeConfluence = 0.55,
	ShakeDecay = 1.6, -- shake trauma (0..1) lost per second
	ShakeMaxDegrees = 2.2,

	LockOn = {
		MaxDistance = 60,
		ViewAngleDegrees = 50,
		SwitchFlickThreshold = 0.35, -- right stick X past this flicks to the next target
		SwitchMousePixels = 40, -- a mouse flick this fast (pixels in one frame) switches targets
		SwitchCooldown = 0.3,
		BreakDistanceMultiplier = 1.25, -- lock breaks beyond MaxDistance x this
	},
})
