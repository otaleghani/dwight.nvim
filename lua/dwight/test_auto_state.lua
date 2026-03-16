-- tests/test_auto_state.lua
-- Tests for auto.lua session state management (save, load, pause, resume).

vim.opt.rtp:prepend(vim.fn.getcwd())

local T = _T

-- Use a temp directory for state files so tests don't affect real sessions
local test_dir = vim.fn.tempname()
vim.fn.mkdir(test_dir, "p")

-- Clear cached modules so the preload hook takes effect even when
-- test_auto_state runs after other test files that already required these.
package.loaded["dwight.project"] = nil
package.loaded["dwight.auto"] = nil

-- Monkey-patch the auto_dir function to use our temp dir
-- (auto_dir is local, but _save_state/_load_state/_clear_state are public)
-- We can set up a mock project module
package.preload["dwight.project"] = function()
	return {
		is_initialized = function()
			return true
		end,
		dir = function()
			return test_dir
		end,
	}
end

local auto = require("dwight.auto")

io.write("── auto state: save/load/clear ──\n")

T.test("save and load state", function()
	auto._save_state({
		request = "Build a TUI",
		tasks = {
			{ order = 1, title = "Install deps", description = "Run go get" },
			{ order = 2, title = "Create models", description = "Define structs" },
		},
		current_task = 1,
		started = 1234567890,
		completed = {},
	})

	local state = auto._load_state()
	T.ok(state, "should load saved state")
	T.eq("Build a TUI", state.request)
	T.len(2, state.tasks)
	T.eq(1, state.current_task)
	T.eq("Install deps", state.tasks[1].title)
end)

T.test("clear state", function()
	auto._save_state({ request = "test" })
	auto._clear_state()
	local state = auto._load_state()
	T.is_nil(state, "state should be nil after clear")
end)

T.test("load returns nil when no state file", function()
	auto._clear_state()
	T.is_nil(auto._load_state())
end)

io.write("── auto state: failed state ──\n")

T.test("save failed state", function()
	auto._save_state({
		request = "Build a TUI",
		tasks = {
			{ order = 1, title = "Task 1", description = "First" },
			{ order = 2, title = "Task 2", description = "Second" },
		},
		current_task = 2,
		started = 1234567890,
		completed = {
			{ task_num = 1, title = "Task 1", had_error = false },
		},
		failed = true,
		error = "rate limit exceeded",
	})

	local state = auto._load_state()
	T.ok(state.failed, "should mark as failed")
	T.eq("rate limit exceeded", state.error)
	T.eq(2, state.current_task)
	T.len(1, state.completed)
end)

io.write("── auto state: paused state ──\n")

T.test("save paused state", function()
	auto._save_state({
		request = "Build a TUI",
		tasks = {
			{ order = 1, title = "Task 1", description = "First" },
			{ order = 2, title = "Task 2", description = "Second" },
		},
		current_task = 2,
		started = 1234567890,
		completed = {
			{ task_num = 1, title = "Task 1", had_error = false },
		},
		paused = true,
	})

	local state = auto._load_state()
	T.ok(state.paused, "should mark as paused")
	T.eq(2, state.current_task)
end)

io.write("── auto pause flag ──\n")

T.test("pause flag starts false", function()
	auto._paused = false -- reset
	T.eq(false, auto._paused)
end)

T.test("pause sets flag", function()
	auto._paused = false
	auto.pause()
	T.eq(true, auto._paused)
end)

T.test("double pause is safe", function()
	auto._paused = true
	auto.pause() -- should not error
	T.eq(true, auto._paused)
end)

T.test("cancel clears pause", function()
	auto._paused = true
	auto._pause_callback = function() end
	auto.cancel()
	T.eq(false, auto._paused)
	T.is_nil(auto._pause_callback)
end)

-- Cleanup
vim.fn.delete(test_dir, "rf")
