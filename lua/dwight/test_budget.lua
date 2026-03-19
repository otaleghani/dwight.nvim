-- tests/test_budget.lua
-- Tests for cost budget caps (tracker.lua budget functions + config validation).

vim.opt.rtp:prepend(vim.fn.getcwd())

local T = _T

--------------------------------------------------------------------
-- Setup: mock dwight.config and dwight.project so tracker works
--------------------------------------------------------------------

-- Minimal project mock
package.loaded["dwight.project"] = {
	is_initialized = function()
		return false
	end,
	tracker_file = function()
		return "/tmp/dwight-test-usage.json"
	end,
	dir = function()
		return "/tmp"
	end,
}

-- Minimal dwight mock (provides .config)
local mock_config = {
	backend = "claude_code",
	cost_limits = {},
}
package.loaded["dwight"] = { config = mock_config }

local tracker = require("dwight.tracker")
local config = require("dwight.config")

--------------------------------------------------------------------
-- Helper: reset state between tests
--------------------------------------------------------------------

local function reset()
	tracker._session = {
		invocations = 0,
		chars_sent = 0,
		chars_received = 0,
		cost = 0,
		by_mode = {},
		by_model = {},
		model = nil,
		started = os.time(),
	}
	mock_config.cost_limits = {}
end

--------------------------------------------------------------------
-- check_budget (internal helper, exposed as _check_budget)
--------------------------------------------------------------------

io.write("── check_budget ──\n")

T.test("check_budget: nil limit → not exceeded, not warning", function()
	local result = tracker._check_budget(5.0, nil, 0.8, "Test")
	T.eq(false, result.exceeded)
	T.eq(false, result.warning)
	T.is_nil(result.message)
end)

T.test("check_budget: under limit → not exceeded, not warning", function()
	local result = tracker._check_budget(2.0, 10.0, 0.8, "Test")
	T.eq(false, result.exceeded)
	T.eq(false, result.warning)
end)

T.test("check_budget: at warn threshold → warning = true", function()
	local result = tracker._check_budget(8.0, 10.0, 0.8, "Test")
	T.eq(false, result.exceeded)
	T.eq(true, result.warning)
	T.ok(result.message, "should have a message")
	T.match("80%%", result.message)
end)

T.test("check_budget: over limit → exceeded = true", function()
	local result = tracker._check_budget(10.5, 10.0, 0.8, "Test")
	T.eq(true, result.exceeded)
	T.ok(result.message, "should have a message")
	T.match("exceeded", result.message)
end)

T.test("check_budget: exactly at limit → exceeded = true", function()
	local result = tracker._check_budget(5.0, 5.0, 0.8, "Test")
	T.eq(true, result.exceeded)
end)

T.test("check_budget: just below threshold → no warning", function()
	local result = tracker._check_budget(7.9, 10.0, 0.8, "Test")
	T.eq(false, result.exceeded)
	T.eq(false, result.warning)
end)

--------------------------------------------------------------------
-- check_session_budget
--------------------------------------------------------------------

io.write("── check_session_budget ──\n")

T.test("session budget: no limit set → not exceeded", function()
	reset()
	mock_config.cost_limits = {}
	local result = tracker.check_session_budget()
	T.eq(false, result.exceeded)
	T.eq(false, result.warning)
end)

T.test("session budget: under limit → not exceeded", function()
	reset()
	tracker._session.cost = 2.0
	mock_config.cost_limits = { per_session = 5.0, warn_threshold = 0.8 }
	local result = tracker.check_session_budget()
	T.eq(false, result.exceeded)
	T.eq(false, result.warning)
end)

T.test("session budget: at 80% → warning", function()
	reset()
	tracker._session.cost = 4.0
	mock_config.cost_limits = { per_session = 5.0, warn_threshold = 0.8 }
	local result = tracker.check_session_budget()
	T.eq(false, result.exceeded)
	T.eq(true, result.warning)
	T.match("Session budget at 80%%", result.message)
end)

T.test("session budget: over limit → exceeded", function()
	reset()
	tracker._session.cost = 5.5
	mock_config.cost_limits = { per_session = 5.0, warn_threshold = 0.8 }
	local result = tracker.check_session_budget()
	T.eq(true, result.exceeded)
	T.match("Session budget exceeded", result.message)
end)

--------------------------------------------------------------------
-- check_daily_budget
--------------------------------------------------------------------

io.write("── check_daily_budget ──\n")

T.test("daily budget: no limit set → not exceeded", function()
	reset()
	mock_config.cost_limits = {}
	local result = tracker.check_daily_budget()
	T.eq(false, result.exceeded)
	T.eq(false, result.warning)
end)

T.test("daily budget: empty usage.json → not exceeded (0 < limit)", function()
	reset()
	mock_config.cost_limits = { per_day = 20.0, warn_threshold = 0.8 }
	-- read_data returns { lifetime = ... } with no daily_cost since file doesn't exist
	local result = tracker.check_daily_budget()
	T.eq(false, result.exceeded)
	T.eq(false, result.warning)
end)

--------------------------------------------------------------------
-- check_all_budgets
--------------------------------------------------------------------

io.write("── check_all_budgets ──\n")

T.test("all budgets: session warning + daily OK → warning true, exceeded false", function()
	reset()
	tracker._session.cost = 4.0
	mock_config.cost_limits = { per_session = 5.0, warn_threshold = 0.8 }
	local result = tracker.check_all_budgets()
	T.eq(false, result.exceeded)
	T.eq(true, result.warning)
	T.ok(#result.messages > 0, "should have messages")
end)

T.test("all budgets: session exceeded → exceeded true", function()
	reset()
	tracker._session.cost = 6.0
	mock_config.cost_limits = { per_session = 5.0, warn_threshold = 0.8 }
	local result = tracker.check_all_budgets()
	T.eq(true, result.exceeded)
end)

T.test("all budgets: no limits → clean result", function()
	reset()
	mock_config.cost_limits = {}
	local result = tracker.check_all_budgets()
	T.eq(false, result.exceeded)
	T.eq(false, result.warning)
	T.len(0, result.messages)
end)

--------------------------------------------------------------------
-- session_budget_remaining
--------------------------------------------------------------------

io.write("── session_budget_remaining ──\n")

T.test("remaining: returns correct delta", function()
	reset()
	tracker._session.cost = 3.0
	mock_config.cost_limits = { per_session = 5.0 }
	local remaining = tracker.session_budget_remaining()
	T.eq(2.0, remaining)
end)

T.test("remaining: returns 0 when over budget", function()
	reset()
	tracker._session.cost = 7.0
	mock_config.cost_limits = { per_session = 5.0 }
	local remaining = tracker.session_budget_remaining()
	T.eq(0, remaining)
end)

T.test("remaining: returns nil when no limit set", function()
	reset()
	mock_config.cost_limits = {}
	local remaining = tracker.session_budget_remaining()
	T.is_nil(remaining)
end)

--------------------------------------------------------------------
-- Config validation for cost_limits
--------------------------------------------------------------------

io.write("── config.validate cost_limits ──\n")

T.test("validate: valid cost_limits produces 0 messages", function()
	local msgs = config.validate({
		cost_limits = { per_session = 5.0, per_day = 20.0, warn_threshold = 0.8 },
	})
	T.len(0, msgs)
end)

T.test("validate: negative per_session produces WARN", function()
	local msgs = config.validate({
		cost_limits = { per_session = -1 },
	})
	T.ok(#msgs > 0)
	T.eq("WARN", msgs[1].level)
	T.match("per_session", msgs[1].msg)
end)

T.test("validate: string per_session produces WARN", function()
	local msgs = config.validate({
		cost_limits = { per_session = "five" },
	})
	T.ok(#msgs > 0)
	T.eq("WARN", msgs[1].level)
end)

T.test("validate: negative per_day produces WARN", function()
	local msgs = config.validate({
		cost_limits = { per_day = -10 },
	})
	T.ok(#msgs > 0)
	T.eq("WARN", msgs[1].level)
	T.match("per_day", msgs[1].msg)
end)

T.test("validate: warn_threshold out of range produces WARN", function()
	local msgs = config.validate({
		cost_limits = { warn_threshold = 1.5 },
	})
	T.ok(#msgs > 0)
	T.eq("WARN", msgs[1].level)
	T.match("warn_threshold", msgs[1].msg)
end)

T.test("validate: warn_threshold negative produces WARN", function()
	local msgs = config.validate({
		cost_limits = { warn_threshold = -0.1 },
	})
	T.ok(#msgs > 0)
	T.eq("WARN", msgs[1].level)
end)

T.test("validate: warn_threshold 0.0 is valid", function()
	local msgs = config.validate({
		cost_limits = { warn_threshold = 0.0 },
	})
	T.len(0, msgs)
end)

T.test("validate: warn_threshold 1.0 is valid", function()
	local msgs = config.validate({
		cost_limits = { warn_threshold = 1.0 },
	})
	T.len(0, msgs)
end)

T.test("validate: nil per_session is valid (disabled)", function()
	local msgs = config.validate({
		cost_limits = { per_session = nil, per_day = 20.0 },
	})
	T.len(0, msgs)
end)

T.test("unknown cost_limits key detected", function()
	local msgs = config.find_unknown_keys({
		cost_limits = { per_sesion = 5.0 },
	})
	T.ok(#msgs > 0)
	T.match("per_sesion", msgs[1].msg)
end)
