--!strict
--[[
	Components
	The Spire UI library. Every menu is assembled from these, so the whole
	game shares one look and one set of behaviours (hover/press motion,
	click sounds, gamepad selection, touch support).

	local C = require(UI.Components)
	local button = C.Button.new({ Text = "Equip", Variant = "Primary", Parent = frame })
]]

local Panel = require(script.Panel)
local Button = require(script.Button)
local IconButton = require(script.IconButton)
local TabBar = require(script.TabBar)
local Tooltip = require(script.Tooltip)
local ItemSlot = require(script.ItemSlot)
local ProgressBar = require(script.ProgressBar)
local RadialProgress = require(script.RadialProgress)
local Toast = require(script.Toast)
local Modal = require(script.Modal)
local ConfirmDialog = require(script.ConfirmDialog)
local ScrollList = require(script.ScrollList)
local SearchBox = require(script.SearchBox)
local Dropdown = require(script.Dropdown)
local Slider = require(script.Slider)
local Toggle = require(script.Toggle)
local KeybindField = require(script.KeybindField)
local ContextMenu = require(script.ContextMenu)
local CountDialog = require(script.CountDialog)

export type Panel = Panel.Panel
export type Button = Button.Button
export type IconButton = IconButton.IconButton
export type TabBar = TabBar.TabBar
export type TooltipContent = Tooltip.TooltipContent
export type TooltipLine = Tooltip.TooltipLine
export type ItemSlot = ItemSlot.ItemSlot
export type SlotItem = ItemSlot.SlotItem
export type ProgressBar = ProgressBar.ProgressBar
export type RadialProgress = RadialProgress.RadialProgress
export type ToastData = Toast.ToastData
export type Modal = Modal.Modal
export type ConfirmProps = ConfirmDialog.ConfirmProps
export type ScrollList = ScrollList.ScrollList
export type SearchBox = SearchBox.SearchBox
export type Dropdown = Dropdown.Dropdown
export type Slider = Slider.Slider
export type Toggle = Toggle.Toggle
export type KeybindField = KeybindField.KeybindField
export type ContextOption = ContextMenu.Option

return {
	Panel = Panel,
	Button = Button,
	IconButton = IconButton,
	TabBar = TabBar,
	Tooltip = Tooltip,
	ItemSlot = ItemSlot,
	ProgressBar = ProgressBar,
	RadialProgress = RadialProgress,
	Toast = Toast,
	Modal = Modal,
	ConfirmDialog = ConfirmDialog,
	ScrollList = ScrollList,
	SearchBox = SearchBox,
	Dropdown = Dropdown,
	Slider = Slider,
	Toggle = Toggle,
	KeybindField = KeybindField,
	ContextMenu = ContextMenu,
	CountDialog = CountDialog,
}
