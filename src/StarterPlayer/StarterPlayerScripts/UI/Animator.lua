--!strict
--[[
	Animator
	One RenderStepped connection drives every looping UI animation (flowing
	Current bars, Mythic rotating borders, Spire-Forged shimmer, glow pulses)
	instead of one connection per element. Elements register a step function
	and get back a cleanup callback for their Maid.

	Steps can join a named group; a paused group's steps are skipped, so a
	closed menu's ambient animations (the Skill Tree's water and stars) cost
	nothing until it opens again.
]]

local RunService = game:GetService("RunService")

export type StepFn = (time: number, dt: number) -> ()

local Animator = {}

local steps: { [number]: StepFn } = {}
local groups: { [number]: string? } = {}
local paused: { [string]: boolean? } = {}
local nextId = 0
local count = 0
local connection: RBXScriptConnection? = nil
local clock = 0

local function ensureRunning()
	if connection or count == 0 then
		return
	end
	connection = RunService.RenderStepped:Connect(function(dt: number)
		clock += dt
		for id, step in steps do
			local group = groups[id]
			if not (group and paused[group]) then
				step(clock, dt)
			end
		end
	end)
end

local function stopIfIdle()
	if count == 0 and connection then
		connection:Disconnect()
		connection = nil
	end
end

-- Registers a step (optionally in a pausable group); returns a function
-- that unregisters it.
function Animator.Add(step: StepFn, group: string?): () -> ()
	nextId += 1
	local id = nextId
	steps[id] = step
	groups[id] = group
	count += 1
	ensureRunning()
	return function()
		if steps[id] then
			steps[id] = nil
			groups[id] = nil
			count -= 1
			stopIfIdle()
		end
	end
end

-- Pauses or resumes every step in `group`.
function Animator.SetPaused(group: string, isPaused: boolean)
	paused[group] = if isPaused then true else nil
end

-- Scrolls a gradient's offset horizontally forever (flowing liquid look).
function Animator.Flow(gradient: UIGradient, speed: number, group: string?): () -> ()
	return Animator.Add(function(time: number)
		local t = (time * speed) % 2
		gradient.Offset = Vector2.new(t - 1, 0)
	end, group)
end

-- Rotates a gradient continuously (degrees per second).
function Animator.Spin(gradient: UIGradient, degreesPerSecond: number): () -> ()
	return Animator.Add(function(time: number)
		gradient.Rotation = (time * degreesPerSecond) % 360
	end)
end

-- Pulses a property between two numbers with a sine wave.
function Animator.Pulse(instance: Instance, property: string, low: number, high: number, period: number, group: string?): () -> ()
	local target = instance :: any
	return Animator.Add(function(time: number)
		local alpha = (math.sin(time * math.pi * 2 / period) + 1) * 0.5
		target[property] = low + (high - low) * alpha
	end, group)
end

return Animator
