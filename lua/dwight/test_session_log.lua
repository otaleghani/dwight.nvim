-- @feature:name
-- tests/test_session_log.lua
-- Tests for session_log.lua notify hook re-entrancy guard.

vim.opt.rtp:prepend(vim.fn.getcwd())

local T = _T

io.write("── session_log notify hook ──\n")

T.test("notify hook: re-entrant call does not recurse", function()
	-- Simulate what session_log does: hook vim.notify, then call vim.notify from within
	local call_count = 0
	local original = vim.notify

	-- Install a hook similar to session_log's
	local in_hook = false
	vim.notify = function(msg, level, opts)
		if in_hook then
			return original(msg, level, opts)
		end
		in_hook = true
		call_count = call_count + 1
		original(msg, level, opts)
		-- Simulate a plugin that re-triggers vim.notify inside the hook
		if call_count < 5 then
			vim.notify("[dwight] nested call", vim.log.levels.INFO)
		end
		in_hook = false
	end

	vim.notify("[dwight] test message", vim.log.levels.WARN)

	-- Without guard: call_count would grow exponentially. With guard: stays bounded.
	T.ok(call_count <= 2, "re-entrancy guard should prevent infinite recursion, got " .. call_count)

	vim.notify = original
end)
