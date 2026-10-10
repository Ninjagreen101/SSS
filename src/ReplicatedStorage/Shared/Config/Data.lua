--!strict
-- Saving configuration (Spec Section 3, Saving).

local TableUtil = require(script.Parent.Parent.Util.TableUtil)

return TableUtil.DeepFreeze({
	StoreName = "SpirePlayerData",
	KeyPrefix = "Player_",
	DataVersion = 8, -- bump + add a migration in DataService/Migrations for every schema change
	AutosaveSeconds = 120,
	LoadRetryKickSeconds = 60, -- give up loading after this long and kick with a retry message
	SaveSettingsDebounce = 1.5, -- client batches settings edits before sending
})
