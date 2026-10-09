--!strict
--[[
	InputController
	One action map for keyboard/mouse, gamepad and touch. Game code never
	reads keys directly; it listens for actions:

		InputController.ActionBegan:Connect(function(action, device) ... end)
		InputController.ActionEnded:Connect(function(action, heldSeconds) ... end)

	- Contexts: "Gameplay" actions fire only while no menu is open; "Menu"
	  actions (close, tab left/right) only while one is. Switching context
	  ends any held action so nothing gets stuck (e.g. Block).
	- Bindings: defaults from Config.Input, player overrides from saved
	  Settings.Keybinds. Two bindings per device; gamepad chords "A+B".
	- Rebinding: CaptureNext() listens for the next key/button (with chord
	  detection), SetBinding() validates, resolves conflicts and saves.
	- Touch: TouchControls (child module) feeds the same actions.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Enums = require(Shared.Enums)
local Strings = require(Shared.Strings)
local Types = require(Shared.Types)
local Signal = require(Shared.Util.Signal)
local Promise = require(Shared.Util.Promise)
local TableUtil = require(Shared.Util.TableUtil)
local SettingsSchema = require(Shared.Data.SettingsSchema)

local UI = script.Parent.Parent.UI
local Device = require(UI.Device)
local DataController = require(script.Parent.DataController)
local TouchControls = require(script.TouchControls)

-- Actions are Enums.Action names; kept as plain strings internally because they
-- index config tables and saved data.
type Action = string
type InputDevice = Enums.InputDevice
type InputContext = Enums.InputContext
type BindingDevice = Enums.BindingDevice
type ActionBinding = Types.ActionBinding

type Capture = {
	Device: BindingDevice,
	Resolve: (string?) -> (),
	StartedAt: number,
	PendingButton: string?,
}

local IS_STUDIO = RunService:IsStudio()
local MOUSE_NAMES: { [Enum.UserInputType]: string } = {
	[Enum.UserInputType.MouseButton1] = "MouseButton1",
	[Enum.UserInputType.MouseButton2] = "MouseButton2",
	[Enum.UserInputType.MouseButton3] = "MouseButton3",
}

local InputController = {}

InputController.ActionBegan = Signal.new() :: Signal.Signal<Action, InputDevice>
InputController.ActionEnded = Signal.new() :: Signal.Signal<Action, number>
InputController.ContextChanged = Signal.new() :: Signal.Signal<InputContext>
InputController.BindingsChanged = Signal.new() :: Signal.Signal<>
InputController.DeviceChanged = Device.Changed

local context: InputContext = "Gameplay"
local effective: { [string]: ActionBinding } = {}
local keyboardMap: { [string]: { Action } } = {}
local gamepadMap: { [string]: { Action } } = {}
local chordMap: { [string]: { { Modifier: string, Action: Action } } } = {} -- keyed by the second button
local down: { [Action]: number } = {} -- action -> time began
local beganBy: { [string]: { Action } } = {} -- "Keyboard:Q" -> actions it started
local heldGamepad: { [string]: number } = {} -- button -> time pressed
local capture: Capture? = nil
local swallow: { [string]: boolean } = {} -- inputs consumed by capture; ignore their release

-- BINDING TABLES -------------------------------------------------------------

local function defaultsFor(action: string): ActionBinding
	local info = Config.Input.Actions[action]
	return {
		Keyboard = table.clone(info.Keyboard),
		Gamepad = table.clone(info.Gamepad),
	}
end

local function contextsOverlap(a: string, b: string): boolean
	local ca = Config.Input.Actions[a].Contexts
	local cb = Config.Input.Actions[b].Contexts
	for _, c in ca do
		if table.find(cb, c) then
			return true
		end
	end
	return false
end

local function rebuildMaps()
	table.clear(keyboardMap)
	table.clear(gamepadMap)
	table.clear(chordMap)
	for actionName, binding in effective do
		local action = actionName :: Action
		for _, name in binding.Keyboard do
			local list = keyboardMap[name] or {}
			table.insert(list, action)
			keyboardMap[name] = list
		end
		for _, name in binding.Gamepad do
			local parts = string.split(name, "+")
			if #parts == 2 then
				local list = chordMap[parts[2]] or {}
				table.insert(list, { Modifier = parts[1], Action = action })
				chordMap[parts[2]] = list
			else
				local list = gamepadMap[name] or {}
				table.insert(list, action)
				gamepadMap[name] = list
			end
		end
	end
end

local function loadBindings(overrides: { [string]: ActionBinding }?)
	table.clear(effective)
	for action in Config.Input.Actions do
		local override = overrides and overrides[action]
		if override and Config.Input.Actions[action].Rebindable then
			effective[action] = {
				Keyboard = table.clone(override.Keyboard),
				Gamepad = table.clone(override.Gamepad),
			}
		else
			effective[action] = defaultsFor(action)
		end
	end
	rebuildMaps()
	InputController.BindingsChanged:Fire()
end

-- Only actions whose bindings differ from the defaults are saved.
local function buildOverrides(): { [string]: ActionBinding }
	local overrides: { [string]: ActionBinding } = {}
	for _, action in SettingsSchema.RebindableActions do
		local current = effective[action]
		local default = defaultsFor(action)
		local same = table.concat(current.Keyboard, "|") == table.concat(default.Keyboard, "|")
			and table.concat(current.Gamepad, "|") == table.concat(default.Gamepad, "|")
		if not same then
			overrides[action] = TableUtil.DeepCopy(current)
		end
	end
	return overrides
end

-- ACTION DISPATCH ------------------------------------------------------------

local function actionAllowed(action: Action): boolean
	local info = Config.Input.Actions[action]
	if not info then
		return false
	end
	if action == "DevGallery" and not IS_STUDIO then
		return false
	end
	return table.find(info.Contexts, context) ~= nil
end

local function beginAction(action: Action, device: InputDevice): boolean
	if down[action] or not actionAllowed(action) then
		return false
	end
	down[action] = os.clock()
	InputController.ActionBegan:Fire(action, device)
	return true
end

local function endAction(action: Action)
	local started = down[action]
	if not started then
		return
	end
	down[action] = nil
	InputController.ActionEnded:Fire(action, os.clock() - started)
end

-- Name + binding device for an input, or nil if it's not bindable.
local function resolveInput(input: InputObject): (string?, BindingDevice?)
	local inputType = input.UserInputType
	local mouse = MOUSE_NAMES[inputType]
	if mouse then
		return mouse, "Keyboard"
	end
	if inputType == Enum.UserInputType.Keyboard then
		if input.KeyCode.Name == "Unknown" then
			return nil, nil
		end
		return input.KeyCode.Name, "Keyboard"
	end
	if string.sub(inputType.Name, 1, 7) == "Gamepad" then
		return input.KeyCode.Name, "Gamepad"
	end
	return nil, nil
end

local function resolveCapture(result: string?)
	local active = capture
	if not active then
		return
	end
	capture = nil
	active.Resolve(result)
end

local function handleCaptureBegan(name: string, bindDevice: BindingDevice)
	local active = capture :: Capture
	if os.clock() - active.StartedAt < 0.1 then
		return -- ignore the tail of the click that started capture
	end
	swallow[`{bindDevice}:{name}`] = true
	if active.Device ~= bindDevice then
		return
	end
	if bindDevice == "Keyboard" then
		if name == "Backspace" then
			resolveCapture(nil)
		elseif SettingsSchema.ValidateKeyboardBinding(name) then
			resolveCapture(name)
		end
		return
	end
	-- Gamepad: wait briefly so a second button can form a chord.
	if active.PendingButton and active.PendingButton ~= name then
		resolveCapture(`{active.PendingButton}+{name}`)
		return
	end
	active.PendingButton = name
	task.delay(Config.Input.ChordCaptureWindow, function()
		if capture == active and active.PendingButton == name then
			resolveCapture(name)
		end
	end)
end

local function onInputBegan(input: InputObject, gameProcessed: boolean)
	local name, bindDevice = resolveInput(input)
	if not name or not bindDevice then
		return
	end
	if bindDevice == "Gamepad" then
		heldGamepad[name] = os.clock()
	end
	if capture then
		handleCaptureBegan(name, bindDevice :: BindingDevice)
		return
	end
	if UserInputService:GetFocusedTextBox() then
		return
	end
	-- Clicks on UI buttons belong to the UI, not to combat.
	if gameProcessed and MOUSE_NAMES[input.UserInputType] then
		return
	end

	local device: InputDevice = if bindDevice == "Gamepad" then "Gamepad" else "KeyboardMouse"
	local started: { Action } = {}
	local candidates: { Action } = {}

	if bindDevice == "Gamepad" then
		local chordHit = false
		local chords: { { Modifier: string, Action: Action } } = chordMap[name] or {}
		for _, chord in chords do
			if heldGamepad[chord.Modifier] then
				table.insert(candidates, chord.Action)
				chordHit = true
			end
		end
		if not chordHit then
			local direct: { Action } = gamepadMap[name] or {}
			for _, action in direct do
				table.insert(candidates, action)
			end
		end
	else
		local mapped: { Action } = keyboardMap[name] or {}
		for _, action in mapped do
			table.insert(candidates, action)
		end
	end

	for _, action in candidates do
		if beginAction(action, device) then
			table.insert(started, action)
		end
	end
	if #started > 0 then
		beganBy[`{bindDevice}:{name}`] = started
	end
end

local function onInputEnded(input: InputObject, _gameProcessed: boolean)
	local name, bindDevice = resolveInput(input)
	if not name or not bindDevice then
		return
	end
	if bindDevice == "Gamepad" then
		heldGamepad[name] = nil
		local active = capture
		if active and active.PendingButton == name then
			resolveCapture(name)
		end
	end
	local key = `{bindDevice}:{name}`
	if swallow[key] then
		swallow[key] = nil
		return
	end
	local actions = beganBy[key]
	if actions then
		beganBy[key] = nil
		for _, action in actions do
			endAction(action)
		end
	end
end

-- PUBLIC API -----------------------------------------------------------------

function InputController.GetDevice(): InputDevice
	return Device.Current()
end

function InputController.GetContext(): InputContext
	return context
end

function InputController.SetContext(newContext: InputContext)
	if newContext == context then
		return
	end
	context = newContext
	-- End anything held that isn't valid in the new context.
	for action in table.clone(down) do
		if not actionAllowed(action) then
			endAction(action)
		end
	end
	for key, actions in beganBy do
		local remaining = {}
		for _, action in actions do
			if down[action] then
				table.insert(remaining, action)
			end
		end
		if #remaining > 0 then
			beganBy[key] = remaining
		else
			beganBy[key] = nil
		end
	end
	InputController.ContextChanged:Fire(newContext)
end

function InputController.IsDown(action: Action): boolean
	return down[action] ~= nil
end

function InputController.GetHoldTime(action: Action): number
	local started = down[action]
	return if started then os.clock() - started else 0
end

-- Used by on-screen touch buttons (and tutorials) to drive actions.
function InputController.BeginAction(action: Action, device: InputDevice?): boolean
	return beginAction(action, device or "Touch")
end

function InputController.EndAction(action: Action)
	endAction(action)
end

function InputController.GetBindings(action: Action, bindDevice: BindingDevice): { string }
	local binding = effective[action]
	if not binding then
		return {}
	end
	return table.clone(if bindDevice == "Keyboard" then binding.Keyboard else binding.Gamepad)
end

-- Short prompt label for the player's current device ("E", "X", "LT + RT").
function InputController.GetPrompt(action: Action): string
	local device = Device.Current()
	if device == "Touch" then
		return ""
	end
	local list = InputController.GetBindings(action, if device == "Gamepad" then "Gamepad" else "Keyboard")
	return Strings.KeyName(list[1] or "")
end

-- Rebinds one slot. Returns ok, and a message for the player (conflict
-- moved from another action, or why it was rejected).
function InputController.SetBinding(action: Action, bindDevice: BindingDevice, slot: number, binding: string): (boolean, string?)
	local info = Config.Input.Actions[action]
	if not info or not info.Rebindable then
		return false, nil
	end
	local valid = if bindDevice == "Keyboard"
		then SettingsSchema.ValidateKeyboardBinding(binding)
		else SettingsSchema.ValidateGamepadBinding(binding)
	if not valid then
		return false, Strings.Format(Strings.UI.KeyReserved, { key = Strings.KeyName(binding) })
	end

	-- Fixed (non-rebindable) actions keep their keys.
	for other, otherInfo in Config.Input.Actions do
		if not otherInfo.Rebindable and other ~= action and contextsOverlap(action, other) then
			local list = if bindDevice == "Keyboard" then otherInfo.Keyboard else otherInfo.Gamepad
			if table.find(list, binding) then
				return false, Strings.Format(Strings.UI.KeyReserved, { key = Strings.KeyName(binding) })
			end
		end
	end

	-- Steal the binding from any rebindable action that would clash.
	local message: string? = nil
	for other, current in effective do
		if other ~= action and Config.Input.Actions[other].Rebindable and contextsOverlap(action, other) then
			local list = if bindDevice == "Keyboard" then current.Keyboard else current.Gamepad
			local index = table.find(list, binding)
			if index then
				table.remove(list, index)
				message = Strings.Format(Strings.UI.KeyConflict, {
					key = Strings.KeyName(binding),
					other = Strings.Actions[other] or other,
				})
			end
		end
	end

	local own = effective[action]
	local list = if bindDevice == "Keyboard" then own.Keyboard else own.Gamepad
	local existing = table.find(list, binding)
	if existing then
		table.remove(list, existing)
	end
	local index = math.clamp(slot, 1, math.min(#list + 1, Config.Input.MaxBindingsPerDevice))
	list[index] = binding

	rebuildMaps()
	DataController.SetSetting("Keybinds", buildOverrides())
	InputController.BindingsChanged:Fire()
	return true, message
end

-- Clears a slot (leaves the action unbound on that slot).
function InputController.ClearBinding(action: Action, bindDevice: BindingDevice, slot: number)
	local own = effective[action]
	if not own or not Config.Input.Actions[action].Rebindable then
		return
	end
	local list = if bindDevice == "Keyboard" then own.Keyboard else own.Gamepad
	if list[slot] then
		table.remove(list, slot)
		rebuildMaps()
		DataController.SetSetting("Keybinds", buildOverrides())
		InputController.BindingsChanged:Fire()
	end
end

function InputController.ResetBindings()
	loadBindings(nil)
	DataController.SetSetting("Keybinds", {})
end

-- Listens for the next key (Keyboard) or button/chord (Gamepad).
-- Resolves nil on Backspace, timeout, or if another capture starts.
function InputController.CaptureNext(bindDevice: BindingDevice): Promise.Promise<string?>
	resolveCapture(nil)
	return Promise.new(function(resolve: (string?) -> ())
		local active: Capture = {
			Device = bindDevice,
			Resolve = resolve,
			StartedAt = os.clock(),
			PendingButton = nil,
		}
		capture = active
		task.delay(Config.Input.CaptureTimeout, function()
			if capture == active then
				resolveCapture(nil)
			end
		end)
	end)
end

function InputController.IsCapturing(): boolean
	return capture ~= nil
end

-- LIFECYCLE ------------------------------------------------------------------

function InputController.Init()
	Device.Start()
	loadBindings(nil)
	DataController.Observe({ "Settings", "Keybinds" }, function(overrides: any)
		if type(overrides) == "table" then
			loadBindings(overrides)
		end
	end)
	TouchControls.Init(InputController :: any)
end

function InputController.Start()
	UserInputService.InputBegan:Connect(onInputBegan)
	UserInputService.InputEnded:Connect(onInputEnded)
	-- Releasing focus (alt-tab) must not leave actions held.
	UserInputService.WindowFocusReleased:Connect(function()
		for action in table.clone(down) do
			endAction(action)
		end
		table.clear(beganBy)
		table.clear(heldGamepad)
	end)
	TouchControls.Start()

	-- Mobile jump button (Roblox's own is replaced by ours, see TouchControls).
	InputController.ActionBegan:Connect(function(action: Action)
		if action ~= "Jump" then
			return
		end
		local character = Players.LocalPlayer.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid.Jump = true
		end
	end)
end

return InputController
