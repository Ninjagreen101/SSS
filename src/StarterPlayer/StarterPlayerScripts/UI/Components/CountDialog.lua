--!strict
--[[
	CountDialog
	"How many?" for splitting stacks, selling and buying several. A slider
	plus -/+ buttons (big enough for touch); resolves the chosen count, or
	nil if cancelled.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UI = script.Parent.Parent
local UITheme = require(UI.UITheme)
local Create = require(UI.Create)
local Modal = require(script.Parent.Modal)
local Button = require(script.Parent.Button)
local Slider = require(script.Parent.Slider)
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Promise = require(Shared.Util.Promise)
local Strings = require(Shared.Strings)

export type CountProps = {
	Title: string,
	Min: number,
	Max: number,
	Value: number?,
	ConfirmText: string?,
	-- Optional line under the slider that updates with the count ("Sell for 40 gold").
	Describe: ((count: number) -> string)?,
}

local CountDialog = {}

function CountDialog.Show(props: CountProps): Promise.Promise<number?>
	return Promise.new(function(resolve: (number?) -> ())
		local modal = Modal.new({ Title = props.Title, Size = UDim2.fromOffset(440, 270) })
		local answered = false
		local function answer(value: number?)
			if answered then
				return
			end
			answered = true
			resolve(value)
			modal:Close()
		end

		local count = math.clamp(props.Value or props.Min, props.Min, props.Max)
		local row: Frame = Create.new("Frame", {
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 48),
			Parent = modal.Content,
		})
		local slider = Slider.new({
			Min = props.Min,
			Max = props.Max,
			Value = count,
			Step = 1,
			Format = function(value: number): string
				return tostring(math.floor(value))
			end,
			Size = UDim2.new(1, -120, 1, 0),
			Position = UDim2.fromOffset(60, 0),
			Parent = row,
		})
		local detail = Create.Label({
			Text = "",
			Color = UITheme.Colors.TextMuted,
			Position = UDim2.fromOffset(0, 60),
			Size = UDim2.new(1, 0, 0, 28),
			XAlignment = Enum.TextXAlignment.Center,
			Parent = modal.Content,
		})
		local function refresh()
			detail.Text = if props.Describe then props.Describe(count) else ""
		end
		local function set(value: number)
			count = math.clamp(math.floor(value), props.Min, props.Max)
			slider:SetValue(count, true)
			refresh()
		end
		slider.Changed:Connect(function(value: number)
			count = math.floor(value)
			refresh()
		end)
		Button.new({
			Text = "-",
			Size = UDim2.fromOffset(48, 48),
			Parent = row,
			OnActivated = function()
				set(count - 1)
			end,
		})
		Button.new({
			Text = "+",
			Size = UDim2.fromOffset(48, 48),
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.fromScale(1, 0),
			Parent = row,
			OnActivated = function()
				set(count + 1)
			end,
		})
		refresh()

		local buttons: Frame = Create.new("Frame", {
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.fromScale(0, 1),
			Size = UDim2.new(1, 0, 0, UITheme.Size.ButtonHeight),
			Parent = modal.Content,
		})
		Create.List(buttons, Enum.FillDirection.Horizontal, UITheme.Padding.Medium, Enum.HorizontalAlignment.Right)
		Button.new({
			Text = Strings.UI.Cancel,
			Size = UDim2.fromOffset(140, UITheme.Size.ButtonHeight),
			LayoutOrder = 1,
			Parent = buttons,
			OnActivated = function()
				answer(nil)
			end,
		})
		Button.new({
			Text = props.ConfirmText or Strings.UI.Confirm,
			Variant = "Primary",
			Size = UDim2.fromOffset(140, UITheme.Size.ButtonHeight),
			LayoutOrder = 2,
			Parent = buttons,
			OnActivated = function()
				answer(count)
			end,
		})
		modal.Closed:Once(function()
			if not answered then
				answered = true
				resolve(nil)
			end
		end)
		modal:Open()
	end)
end

return CountDialog
