--!strict
--[[
	StatDraft
	Stat points you've staged with + / - but not yet confirmed. Shared by the
	Character page and the Skill Tree's build panel, so points staged on one
	show on the other. Nothing is spent until Confirm sends the draft to the
	server (RequestAllocateStats), which checks it against your real points.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Signal = require(ReplicatedStorage:WaitForChild("Shared").Util.Signal)

local StatDraft = {}

StatDraft.Changed = Signal.new() :: Signal.Signal<>

local pending: { [string]: number? } = {}

function StatDraft.Get(stat: string): number
	return pending[stat] or 0
end

function StatDraft.Total(): number
	local total = 0
	for _, amount in pending do
		total += amount or 0
	end
	return total
end

-- Stages one point up or down. `available` is your unspent stat points;
-- returns false if the change isn't possible.
function StatDraft.Step(stat: string, delta: number, available: number): boolean
	local current = pending[stat] or 0
	local nextValue = current + delta
	if nextValue < 0 or (delta > 0 and StatDraft.Total() + delta > available) then
		return false
	end
	pending[stat] = if nextValue > 0 then nextValue else nil
	StatDraft.Changed:Fire()
	return true
end

function StatDraft.Snapshot(): { [string]: number }
	local copy: { [string]: number } = {}
	for stat, amount in pending do
		if amount then
			copy[stat] = amount
		end
	end
	return copy
end

function StatDraft.Clear()
	if next(pending) ~= nil then
		table.clear(pending)
		StatDraft.Changed:Fire()
	end
end

-- Drops the draft if it no longer fits (points spent elsewhere, a respec).
function StatDraft.Validate(available: number)
	if StatDraft.Total() > available then
		StatDraft.Clear()
	end
end

return StatDraft
