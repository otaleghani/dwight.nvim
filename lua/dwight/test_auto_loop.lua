-- tests/test_auto_loop.lua
-- Tests for auto/loop.lua _build_prev_context.

vim.opt.rtp:prepend(vim.fn.getcwd())

local loop = require("dwight.auto.loop")
local T = _T

--------------------------------------------------------------------
-- _build_prev_context
--------------------------------------------------------------------

io.write("── auto/loop._build_prev_context ──\n")

T.test("build_prev_context: nil returns empty string", function()
	T.eq("", loop._build_prev_context(nil))
end)

T.test("build_prev_context: empty table returns empty string", function()
	T.eq("", loop._build_prev_context({}))
end)

T.test("build_prev_context: structured data", function()
	local sessions = {
		{
			task_num = 1,
			title = "Create auth",
			had_error = false,
			files_created = { "src/auth.go" },
			files_edited = { "src/server.go" },
			summary = "Implemented auth module",
			iterations = 5,
		},
	}
	local result = loop._build_prev_context(sessions)
	T.match("PREVIOUS TASKS COMPLETED", result)
	T.match("Create auth", result)
	T.match("src/auth.go", result)
	T.match("src/server.go", result)
	T.match("Implemented auth module", result)
	T.match("5 turns", result)
end)

T.test("build_prev_context: journal fallback parsing", function()
	local sessions = {
		{
			task_num = 1,
			title = "Setup",
			had_error = false,
			journal = {
				"created src/main.go",
				"edited src/config.go",
			},
		},
	}
	local result = loop._build_prev_context(sessions)
	T.match("src/main.go", result)
	T.match("src/config.go", result)
end)

T.test("build_prev_context: fragile file detection (2+ touches)", function()
	local sessions = {
		{
			task_num = 1,
			title = "Task A",
			had_error = false,
			files_edited = { "shared.go" },
		},
		{
			task_num = 2,
			title = "Task B",
			had_error = false,
			files_edited = { "shared.go" },
		},
	}
	local result = loop._build_prev_context(sessions)
	T.match("FRAGILE FILES", result)
	T.match("shared.go", result)
	T.match("2x", result)
end)

T.test("build_prev_context: error icon for failed tasks", function()
	local sessions = {
		{
			task_num = 1,
			title = "Failed task",
			had_error = true,
		},
	}
	local result = loop._build_prev_context(sessions)
	T.match("x Task 1", result)
end)

T.test("build_prev_context: success icon for passing tasks", function()
	local sessions = {
		{
			task_num = 1,
			title = "Good task",
			had_error = false,
		},
	}
	local result = loop._build_prev_context(sessions)
	-- The checkmark character
	T.match("Task 1", result)
end)
