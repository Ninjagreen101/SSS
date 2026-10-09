--!strict
-- Persistence tuning.

local Data = {
	StoreName = "SpireProfiles_v1",
	DataVersion = 1,
	AutosaveSeconds = 120,
	SessionLockSeconds = 300, -- a lock older than this is considered abandoned
	LoadRetries = 6,
	LoadRetryDelay = 2,
	SaveRetries = 4,
}

return Data
