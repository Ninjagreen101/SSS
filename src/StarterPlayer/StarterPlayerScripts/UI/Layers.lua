--!strict
--[[
	Layers
	Owns the ScreenGuis every piece of UI lives in (HUD, Touch, Menu,
	Overlay, Modal, Tooltip), each with a UIScale that follows the viewport
	size and the player's HUD Scale setting. Created on demand so components
	can always find their layer.
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local UITheme = require(script.Parent.UITheme)

export type LayerName = "HUD" | "Touch" | "Menu" | "Overlay" | "Modal" | "Tooltip"

local Layers = {}

local guis: { [string]: ScreenGui } = {}
local scales: { [string]: UIScale } = {}
local userScale = 1
local viewportConnection: RBXScriptConnection? = nil

local function playerGui(): PlayerGui
	local player = Players.LocalPlayer
	return player:WaitForChild("PlayerGui") :: PlayerGui
end

local function viewportSize(): Vector2
	local camera = Workspace.CurrentCamera
	return if camera then camera.ViewportSize else Vector2.new(1280, 720)
end

local function applyScale(name: string)
	local uiScale = scales[name]
	if not uiScale then
		return
	end
	-- Touch controls are sized in physical pixels and never shrink below
	-- the 44 px minimum target, so they ignore the HUD scale.
	if name == "Touch" then
		uiScale.Scale = math.max(1, UITheme.ComputeScale(viewportSize(), 1))
	else
		uiScale.Scale = UITheme.ComputeScale(viewportSize(), if name == "HUD" then userScale else 1)
	end
end

local function watchViewport()
	if viewportConnection then
		return
	end
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	viewportConnection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
		for name in scales do
			applyScale(name)
		end
	end)
end

function Layers.Get(name: LayerName): ScreenGui
	local existing = guis[name]
	if existing and existing.Parent then
		return existing
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = `Spire{name}`
	gui.DisplayOrder = (UITheme.Layers :: any)[name]
	gui.ResetOnSpawn = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.IgnoreGuiInset = name ~= "HUD"
	-- ScreenInsets overrides IgnoreGuiInset. The HUD uses CoreUISafeInsets so
	-- it sits below Roblox's own top-left buttons (menu, chat) instead of
	-- under them; touch controls only need to avoid notches.
	gui.ScreenInsets = if name == "HUD"
		then Enum.ScreenInsets.CoreUISafeInsets
		elseif name == "Touch" then Enum.ScreenInsets.DeviceSafeInsets
		else Enum.ScreenInsets.None
	local uiScale = Instance.new("UIScale")
	uiScale.Name = "Scale"
	uiScale.Parent = gui
	guis[name] = gui
	scales[name] = uiScale
	applyScale(name)
	watchViewport()
	gui.Parent = playerGui()
	return gui
end

-- Inverse of the layer's UIScale: converts screen pixels into layer space.
function Layers.ToLayerSpace(name: LayerName, screen: Vector2): Vector2
	local uiScale = scales[name]
	local s = if uiScale then uiScale.Scale else 1
	return screen / s
end

function Layers.GetScale(name: LayerName): number
	local uiScale = scales[name]
	return if uiScale then uiScale.Scale else 1
end

-- Player HUD Scale setting (0.75..1.25).
function Layers.SetUserScale(scale: number)
	userScale = scale
	for name in scales do
		applyScale(name)
	end
end

return Layers
