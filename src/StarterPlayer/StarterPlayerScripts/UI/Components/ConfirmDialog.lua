--!strict
-- ConfirmDialog: yes/no modal that resolves a Promise<boolean>.
-- Dismissing (back button, backdrop, X) counts as "no".

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UI = script.Parent.Parent
local UITheme = require(UI.UITheme)
local Create = require(UI.Create)
local Modal = require(script.Parent.Modal)
local Button = require(script.Parent.Button)
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Promise = require(Shared.Util.Promise)
local Strings = require(Shared.Strings)

export type ConfirmProps = {
	Title: string,
	Message: string,
	ConfirmText: string?,
	CancelText: string?,
	Danger: boolean?,
}

local ConfirmDialog = {}

function ConfirmDialog.Show(props: ConfirmProps): Promise.Promise<boolean>
	return Promise.new(function(resolve: (boolean) -> ())
		local modal = Modal.new({ Title = props.Title, Size = UDim2.fromOffset(440, 240) })
		local answered = false
		local function answer(value: boolean)
			if answered then
				return
			end
			answered = true
			resolve(value)
			modal:Close()
		end

		Create.Label({
			Text = props.Message,
			Color = UITheme.Colors.TextMuted,
			Wrapped = true,
			YAlignment = Enum.TextYAlignment.Top,
			Size = UDim2.new(1, 0, 1, -58),
			Parent = modal.Content,
		})

		local row: Frame = Create.new("Frame", {
			Name = "Buttons",
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.fromScale(0, 1),
			Size = UDim2.new(1, 0, 0, UITheme.Size.ButtonHeight),
			Parent = modal.Content,
		})
		Create.List(row, Enum.FillDirection.Horizontal, UITheme.Padding.Medium, Enum.HorizontalAlignment.Right)

		Button.new({
			Text = props.CancelText or Strings.UI.Cancel,
			Variant = "Secondary",
			Size = UDim2.fromOffset(140, UITheme.Size.ButtonHeight),
			LayoutOrder = 1,
			Parent = row,
			OnActivated = function()
				answer(false)
			end,
		})
		Button.new({
			Text = props.ConfirmText or Strings.UI.Confirm,
			Variant = if props.Danger then "Danger" else "Primary",
			Size = UDim2.fromOffset(140, UITheme.Size.ButtonHeight),
			LayoutOrder = 2,
			Parent = row,
			OnActivated = function()
				answer(true)
			end,
		})

		modal.Closed:Once(function()
			if not answered then
				answered = true
				resolve(false)
			end
			modal:Destroy()
		end)
		modal:Open()
	end)
end

return ConfirmDialog
