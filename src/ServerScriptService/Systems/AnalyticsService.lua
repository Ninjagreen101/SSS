--!strict
--[[
	AnalyticsService (game system)
	Wraps Roblox's built-in AnalyticsService so every system logs funnels,
	economy flows and progression the same way. All calls are protected:
	analytics must never break gameplay. In Studio, events print instead.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local RobloxAnalytics = game:GetService("AnalyticsService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Log = require(Shared.Util.Log)

local log = Log.new("Analytics")
local IS_STUDIO = RunService:IsStudio()

local AnalyticsService = {}

local function safe(label: string, fn: () -> ())
	if IS_STUDIO then
		log:Debug(label)
		return
	end
	local ok, err = pcall(function(): any
		fn()
		return nil
	end)
	if not ok then
		log:Warn(`{label} failed: {tostring(err)}`)
	end
end

-- Onboarding funnel step (tutorial). Steps must be logged in order, starting at 1.
function AnalyticsService.FunnelStep(player: Player, step: number, stepName: string)
	safe(`Funnel {step} {stepName} ({player.Name})`, function()
		RobloxAnalytics:LogOnboardingFunnelStepEvent(player, step, stepName)
	end)
end

-- Currency gained (Source) or spent (Sink).
function AnalyticsService.Economy(
	player: Player,
	flow: "Source" | "Sink",
	currency: string,
	amount: number,
	endingBalance: number,
	transactionType: string,
	itemSku: string?
)
	safe(`Economy {flow} {amount} {currency} ({transactionType}) for {player.Name}`, function()
		local flowType = if flow == "Source" then Enum.AnalyticsEconomyFlowType.Source else Enum.AnalyticsEconomyFlowType.Sink
		RobloxAnalytics:LogEconomyEvent(player, flowType, currency, amount, endingBalance, transactionType, itemSku)
	end)
end

-- Progression through levelled content (floors, dungeons, Guardians).
function AnalyticsService.Progression(
	player: Player,
	path: string,
	status: "Start" | "Complete" | "Fail",
	level: number,
	levelName: string?
)
	safe(`Progression {path} {status} {level} ({player.Name})`, function()
		local statusEnum = if status == "Start"
			then Enum.AnalyticsProgressionType.Start
			elseif status == "Complete" then Enum.AnalyticsProgressionType.Complete
			else Enum.AnalyticsProgressionType.Fail
		RobloxAnalytics:LogProgressionEvent(player, path, statusEnum, level, levelName)
	end)
end

-- Free-form counter events (e.g. "ParrySuccess").
function AnalyticsService.Custom(player: Player, eventName: string, value: number?)
	safe(`Custom {eventName}={value or 1} ({player.Name})`, function()
		RobloxAnalytics:LogCustomEvent(player, eventName, value or 1)
	end)
end

function AnalyticsService.Init() end

function AnalyticsService.Start()
	Players.PlayerAdded:Connect(function(player: Player)
		AnalyticsService.Custom(player, "SessionStart")
	end)
end

return AnalyticsService
