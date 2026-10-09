--!strict
--[[
	Log
	Tagged logging. Debug lines only print in Studio so live servers stay quiet;
	warnings and errors always print with the system tag for fast triage.
]]

local RunService = game:GetService("RunService")

export type Logger = {
	Debug: (self: Logger, message: string) -> (),
	Info: (self: Logger, message: string) -> (),
	Warn: (self: Logger, message: string) -> (),
	Error: (self: Logger, message: string) -> (),
}

local IS_STUDIO = RunService:IsStudio()

local Log = {}

function Log.new(tag: string): Logger
	local prefix = `[{tag}]`
	local logger = {}

	function logger.Debug(_self: Logger, message: string)
		if IS_STUDIO then
			print(prefix, message)
		end
	end

	function logger.Info(_self: Logger, message: string)
		print(prefix, message)
	end

	function logger.Warn(_self: Logger, message: string)
		warn(prefix, message)
	end

	-- Reports without throwing so one failure never stops a system loop.
	function logger.Error(_self: Logger, message: string)
		task.spawn(error, `{prefix} {message}`, 0)
	end

	return (logger :: any) :: Logger
end

return Log
