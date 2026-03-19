-- dwight/errors.lua
-- Thin wrapper around pcall that logs errors instead of silently discarding them.

local M = {}

--- Protected call with logging.
--- On success: returns fn() result.
--- On failure: logs to session_log (if open), optionally vim.notify based on severity.
--- Never propagates errors to caller — same resilience as bare pcall.
---
--- @param label string Short description of what we're attempting (e.g. "languages.reset")
--- @param fn function The function to call
--- @param severity? string "silent" (default), "warn", or "error"
--- @return any|nil Result of fn() on success, nil on failure
function M.try(label, fn, severity)
	severity = severity or "silent"
	local ok, result = pcall(fn)
	if ok then
		return result
	end

	-- Log to session_log if available
	pcall(function()
		local session_log = require("dwight.session_log")
		session_log.append(string.format("[error] %s: %s", label, tostring(result)))
	end)

	-- Notify based on severity
	if severity == "warn" then
		pcall(vim.notify, string.format("[dwight] %s: %s", label, tostring(result)), vim.log.levels.WARN)
	elseif severity == "error" then
		pcall(vim.notify, string.format("[dwight] %s: %s", label, tostring(result)), vim.log.levels.ERROR)
	end

	return nil
end

return M
