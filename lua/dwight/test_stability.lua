-- tests/test_stability.lua
-- Tests for agentic mode stability improvements:
--   - classify_transient (agentic.lua)
--   - agentic.reset() (agentic.lua)
--   - parse_test_failures (gates.lua)
--   - gates.run_all sequential runner (gates.lua)
--   - worktree.check_merge_state (worktree.lua)
--   - pool.run_batch wave timeout (pool.lua)

vim.opt.rtp:prepend(vim.fn.getcwd())

-- Mock project module
package.preload["dwight.project"] = function()
	return {
		is_initialized = function()
			return true
		end,
		dir = function()
			return vim.fn.tempname()
		end,
	}
end

local T = _T

--------------------------------------------------------------------
-- classify_transient
--------------------------------------------------------------------

io.write("── classify_transient ──\n")

local agentic = require("dwight.agentic")

T.test("rate limit 429 is transient", function()
	T.ok(agentic.classify_transient("HTTP 429 Too Many Requests", 1))
end)

T.test("rate limit text is transient", function()
	T.ok(agentic.classify_transient("Error: rate limit exceeded", 1))
end)

T.test("overloaded is transient", function()
	T.ok(agentic.classify_transient("API overloaded, try again", 1))
end)

T.test("ECONNRESET is transient", function()
	T.ok(agentic.classify_transient("read ECONNRESET", 1))
end)

T.test("timeout is transient", function()
	T.ok(agentic.classify_transient("request timeout after 30s", 1))
end)

T.test("503 is transient", function()
	T.ok(agentic.classify_transient("Service Unavailable 503", 1))
end)

T.test("socket hang up is transient", function()
	T.ok(agentic.classify_transient("socket hang up", 1))
end)

T.test("normal error is not transient", function()
	T.eq(false, agentic.classify_transient("syntax error in file.lua", 1))
end)

T.test("auth error is not transient", function()
	T.eq(false, agentic.classify_transient("Claude Code not authenticated", 1))
end)

T.test("nil input returns false", function()
	T.eq(false, agentic.classify_transient(nil, 1))
end)

T.test("empty string returns false", function()
	T.eq(false, agentic.classify_transient("", 1))
end)

--------------------------------------------------------------------
-- agentic.reset()
--------------------------------------------------------------------

io.write("── agentic.reset ──\n")

T.test("reset clears all module state", function()
	-- Set some state
	agentic._active_handle = "fake_handle"
	agentic._active_pid = 12345
	agentic._active_backend = "claude_code"
	agentic._registry = { task1 = { handle = "h" } }

	agentic.reset()

	T.is_nil(agentic._active_handle)
	T.is_nil(agentic._active_pid)
	T.is_nil(agentic._active_backend)
	T.eq(0, #vim.tbl_keys(agentic._registry), "registry should be empty")
end)

T.test("reset is idempotent", function()
	agentic.reset()
	agentic.reset()
	T.is_nil(agentic._active_handle)
end)

--------------------------------------------------------------------
-- parse_test_failures
--------------------------------------------------------------------

io.write("── parse_test_failures ──\n")

local gates = require("dwight.gates")

T.test("Go failure pattern", function()
	local output = [[
--- FAIL: TestFoo (0.01s)
--- FAIL: TestBar/subtest (0.02s)
ok  	pkg/other
]]
	local failures = gates.parse_test_failures(output, "go")
	T.eq(2, #failures)
	T.eq("TestFoo", failures[1])
	T.eq("TestBar/subtest", failures[2])
end)

T.test("Python/pytest failure pattern", function()
	local output = [[
FAILED tests/test_auth.py::test_login
FAILED tests/test_auth.py::test_signup
]]
	local failures = gates.parse_test_failures(output, "python")
	T.assert(#failures >= 2, "should find at least 2 failures")
end)

T.test("Rust failure pattern", function()
	local output = [[
test result: FAILED. 1 passed; 1 failed
test auth::test_login ... FAILED
test auth::test_signup ... ok
]]
	local failures = gates.parse_test_failures(output, "rust")
	T.assert(#failures >= 1, "should find at least 1 failure")
	-- The Rust pattern should match "auth::test_login"
	local found = false
	for _, f in ipairs(failures) do
		if f:match("test_login") then
			found = true
		end
	end
	T.ok(found, "should find test_login")
end)

T.test("nil language tries all patterns", function()
	local output = "--- FAIL: TestFoo (0.01s)"
	local failures = gates.parse_test_failures(output, nil)
	T.assert(#failures >= 1, "should find failures with nil lang")
end)

T.test("no failures returns empty table", function()
	local output = "ok  pkg/foo\nPASS"
	local failures = gates.parse_test_failures(output, "go")
	T.eq(0, #failures)
end)

T.test("deduplicates failures", function()
	local output = [[
--- FAIL: TestFoo (0.01s)
--- FAIL: TestFoo (retry)
]]
	local failures = gates.parse_test_failures(output, "go")
	T.eq(1, #failures, "should deduplicate")
end)

--------------------------------------------------------------------
-- gates.run_all sequential runner
--------------------------------------------------------------------

io.write("── gates.run_all sequential runner ──\n")

T.test("run_all function exists", function()
	T.assert(type(gates.run_all) == "function")
end)

T.test("parse_test_failures function exists", function()
	T.assert(type(gates.parse_test_failures) == "function")
end)

--------------------------------------------------------------------
-- worktree.check_merge_state
--------------------------------------------------------------------

io.write("── worktree.check_merge_state ──\n")

local worktree = require("dwight.swarm.worktree")

T.test("check_merge_state function exists", function()
	T.assert(type(worktree.check_merge_state) == "function")
end)

T.test("cleanup_stale function exists", function()
	T.assert(type(worktree.cleanup_stale) == "function")
end)

T.test("check_merge_state returns false when no merge in progress", function()
	-- In a clean git repo, there should be no MERGE_HEAD
	local result = worktree.check_merge_state()
	T.eq(false, result, "should return false when no merge state")
end)

--------------------------------------------------------------------
-- pool.run_batch
--------------------------------------------------------------------

io.write("── pool wave timeout ──\n")

local pool = require("dwight.swarm.pool")

T.test("run_batch with empty tasks calls on_all_done immediately", function()
	local called = false
	pool.run_batch({}, "", function() end, function() end, function(results)
		called = true
		T.eq(0, #results)
	end)
	T.ok(called, "on_all_done should be called synchronously for empty batch")
end)
