-- dwight/tdd.lua
-- TDD workflow: discover test files, run → fix → rerun loop.
-- :DwightTDD starts a session, auto-injects test context into /tdd mode.

local M = {}

M._session = nil -- { description, test_cmd, iterations, last_result, phase, started }

local MAX_ITERATIONS = 10

--------------------------------------------------------------------
-- Test File Discovery
--------------------------------------------------------------------

local PATTERNS = {
	-- source → test patterns per ecosystem
	{ src = "(.+)%.ts$", tests = { "%1.test.ts", "%1.spec.ts", "__tests__/%1.ts" } },
	{ src = "(.+)%.tsx$", tests = { "%1.test.tsx", "%1.spec.tsx" } },
	{ src = "(.+)%.js$", tests = { "%1.test.js", "%1.spec.js", "__tests__/%1.js" } },
	{ src = "(.+)%.py$", tests = { "test_%1.py", "%1_test.py", "tests/test_%1.py" } },
	{ src = "(.+)%.go$", tests = { "%1_test.go" } },
	{ src = "(.+)%.rs$", tests = { "%1_test.rs", "tests/%1.rs" } },
	{ src = "(.+)%.lua$", tests = { "%1_spec.lua", "%1_test.lua", "tests/%1_spec.lua" } },
	{ src = "(.+)%.rb$", tests = { "%1_spec.rb", "spec/%1_spec.rb", "%1_test.rb" } },
	{ src = "(.+)%.java$", tests = { "%1Test.java" } },
	{ src = "(.+)%.kt$", tests = { "%1Test.kt" } },
}

--- Find test file(s) for a given source file.
function M.find_test_file(filepath)
	if not filepath or filepath == "" then
		return nil
	end
	local dir = vim.fn.fnamemodify(filepath, ":h")
	local name = vim.fn.fnamemodify(filepath, ":t")

	for _, pat in ipairs(PATTERNS) do
		local base = name:match(pat.src)
		if base then
			for _, test_pat in ipairs(pat.tests) do
				local test_name = test_pat:gsub("%%1", base)
				-- Check in same dir and parent dir
				local candidates = {
					dir .. "/" .. test_name,
					vim.fn.getcwd() .. "/" .. test_name,
				}
				for _, cand in ipairs(candidates) do
					if vim.fn.filereadable(cand) == 1 then
						return cand
					end
				end
			end
		end
	end

	return nil
end

--- Read test file content (trimmed to 3000 lines).
function M.read_test_file(path)
	if not path then
		return nil
	end
	local f = io.open(path, "r")
	if not f then
		return nil
	end
	local content = f:read("*a")
	f:close()
	local lines = vim.split(content, "\n", { plain = true })
	if #lines > 3000 then
		content = table.concat(vim.list_slice(lines, 1, 3000), "\n") .. "\n-- [truncated]"
	end
	return content
end

--------------------------------------------------------------------
-- TDD Session
--------------------------------------------------------------------

function M.start(description)
	local runner = require("dwight.runner")

	if not description or description == "" then
		vim.ui.input({ prompt = "Feature to TDD: " }, function(desc)
			if desc and desc ~= "" then
				M.start(desc)
			end
		end)
		return
	end

	local test_cmd = runner._detect_runner()
	if test_cmd == "" then
		vim.ui.input({ prompt = "Test command (none detected): " }, function(cmd)
			if cmd and cmd ~= "" then
				M._start_with(description, cmd)
			else
				vim.notify("[dwight] TDD requires a test command.", vim.log.levels.WARN)
			end
		end)
		return
	end

	M._start_with(description, test_cmd)
end

function M._start_with(description, test_cmd)
	M._session = {
		description = description,
		test_cmd = test_cmd,
		iterations = 0,
		last_result = nil,
		phase = "write_test",
		started = os.time(),
	}
	vim.notify(
		string.format('[dwight] TDD session started: "%s" (test cmd: %s)', description, test_cmd),
		vim.log.levels.INFO
	)
	M._agent_step()
end

function M._agent_step()
	local session = M._session
	if not session then
		return
	end

	if session.iterations >= MAX_ITERATIONS then
		vim.notify(string.format("[dwight] TDD: hit %d iteration cap. Stopping.", MAX_ITERATIONS), vim.log.levels.WARN)
		M.stop()
		return
	end

	local prompt
	if session.phase == "write_test" then
		prompt = string.format(
			"Write a FAILING test for the following feature:\n\n%s\n\n"
				.. "The test runner command is: %s\n"
				.. "Write the minimal test that captures the requirement. "
				.. "The test MUST fail (red) because the feature is not implemented yet.",
			session.description,
			session.test_cmd
		)
		if session.last_result then
			prompt = prompt
				.. string.format(
					"\n\nPrevious test run (exit %d):\n%s\n%s",
					session.last_result.exit_code,
					session.last_result.stdout or "",
					session.last_result.stderr or ""
				)
		end
	elseif session.phase == "implement" then
		prompt = string.format(
			"The following test is FAILING. Write the MINIMUM code to make it pass.\n\n"
				.. "Feature: %s\nTest runner: %s\n\n"
				.. "Failing test output (exit %d):\n%s\n%s\n\n"
				.. "Do NOT modify the test. Only write production code to make the test pass.",
			session.description,
			session.test_cmd,
			session.last_result and session.last_result.exit_code or 1,
			session.last_result and session.last_result.stdout or "",
			session.last_result and session.last_result.stderr or ""
		)
	end

	vim.notify(string.format("[dwight] TDD #%d: %s phase", session.iterations + 1, session.phase), vim.log.levels.INFO)

	require("dwight.agent").run(prompt, {
		_skip_plan = true,
		on_complete = function(_success)
			vim.schedule(function()
				M._run_tests()
			end)
		end,
	})
end

function M._run_tests()
	if not M._session then
		return
	end
	local runner = require("dwight.runner")

	runner.run_with_callback(M._session.test_cmd, function(result)
		if not M._session then
			return
		end

		M._session.last_result = result
		M._session.iterations = M._session.iterations + 1

		-- Save to browsable history
		M._save_run(result)

		local pass_count, fail_count = M._parse_test_counts(result)
		local icon = result.exit_code == 0 and "●" or "✗"

		vim.notify(
			string.format(
				"[dwight] %s TDD #%d: %s (pass:%s fail:%s)",
				icon,
				M._session.iterations,
				M._session.test_cmd,
				pass_count or "?",
				fail_count or "?"
			),
			result.exit_code == 0 and vim.log.levels.INFO or vim.log.levels.WARN
		)

		if M._session.phase == "write_test" then
			if result.exit_code ~= 0 then
				-- Red confirmed: advance to implement
				vim.notify("[dwight] TDD: test fails (red). Moving to implement phase.", vim.log.levels.INFO)
				M._session.phase = "implement"
				M._agent_step()
			else
				-- Test didn't fail: retry write_test
				vim.notify("[dwight] TDD: test passes but should fail. Retrying write_test.", vim.log.levels.WARN)
				M._agent_step()
			end
		elseif M._session.phase == "implement" then
			if result.exit_code == 0 then
				-- Green confirmed: ask whether to continue
				vim.notify("[dwight] TDD: tests pass (green)!", vim.log.levels.INFO)
				vim.ui.select({ "Continue (next feature cycle)", "Stop TDD session" }, {
					prompt = "All tests pass! Continue TDD?",
				}, function(choice)
					if choice == "Continue (next feature cycle)" then
						M._session.phase = "write_test"
						M._agent_step()
					else
						M.stop()
					end
				end)
			else
				-- Still failing: retry implement
				vim.notify("[dwight] TDD: tests still failing. Retrying implement.", vim.log.levels.WARN)
				M._agent_step()
			end
		end
	end)
end

--- Parse pass/fail counts from test output (heuristic).
function M._parse_test_counts(result)
	local output = (result.stdout or "") .. "\n" .. (result.stderr or "")

	-- Jest/Vitest: Tests: 2 failed, 5 passed, 7 total
	local fail, pass = output:match("(%d+) failed.-(%d+) passed")
	if pass then
		return pass, fail
	end

	-- pytest: 3 passed, 1 failed
	pass, fail = output:match("(%d+) passed.-(%d+) failed")
	if pass then
		return pass, fail
	end
	pass = output:match("(%d+) passed")
	if pass then
		return pass, "0"
	end

	-- Go: ok/FAIL + pass count
	if output:match("^ok") then
		return "all", "0"
	end
	if output:match("^FAIL") then
		return "?", "?"
	end

	-- Rust: test result: ok. X passed; Y failed
	pass, fail = output:match("(%d+) passed; (%d+) failed")
	if pass then
		return pass, fail
	end

	-- Generic: look for pass/fail numbers
	pass = output:match("(%d+) pass")
	fail = output:match("(%d+) fail")
	return pass, fail
end

--- Get test context for prompt injection (test file + run output).
function M.get_tdd_context(selection)
	local parts = {}

	-- Find and inject test file
	local test_path = M.find_test_file(selection.filepath)
	if test_path then
		local test_content = M.read_test_file(test_path)
		if test_content then
			parts[#parts + 1] =
				string.format("\nTest file (%s):\n```\n%s\n```", vim.fn.fnamemodify(test_path, ":."), test_content)
		end
	end

	-- Inject last test run output
	if M._session and M._session.last_result then
		local r = M._session.last_result
		parts[#parts + 1] = string.format("\nTest results (exit %d):", r.exit_code)
		if r.stdout ~= "" then
			parts[#parts + 1] = r.stdout
		end
		if r.stderr ~= "" then
			parts[#parts + 1] = r.stderr
		end
	end

	if #parts == 0 then
		return nil
	end
	return table.concat(parts, "\n")
end

--- (Removed: rerun_after_apply — user controls when tests run)

--- Save a test run result to .dwight/runs/ for later browsing.
function M._save_run(result)
	local project = require("dwight.project")
	if not project.is_initialized() then
		return
	end
	local dir = project.dir() .. "/runs"
	vim.fn.mkdir(dir, "p")

	local ts = os.date("%Y-%m-%d_%H-%M-%S")
	local icon = result.exit_code == 0 and "pass" or "fail"
	local path = string.format("%s/%s_%s.txt", dir, ts, icon)

	local f = io.open(path, "w")
	if not f then
		return
	end
	f:write("Command: " .. (M._session and M._session.test_cmd or "unknown") .. "\n")
	f:write("Exit code: " .. (result.exit_code or "?") .. "\n")
	f:write("Date: " .. os.date() .. "\n")
	f:write(string.rep("─", 60) .. "\n\n")
	if result.stdout and result.stdout ~= "" then
		f:write("STDOUT:\n" .. result.stdout .. "\n\n")
	end
	if result.stderr and result.stderr ~= "" then
		f:write("STDERR:\n" .. result.stderr .. "\n")
	end
	f:close()
	return path
end

--- Browse test run history with Telescope or native picker.
function M.browse_runs()
	local project = require("dwight.project")
	if not project.is_initialized() then
		vim.notify("[dwight] Run :DwightInit first.", vim.log.levels.WARN)
		return
	end
	local dir = project.dir() .. "/runs"
	if vim.fn.isdirectory(dir) ~= 1 then
		vim.notify("[dwight] No test runs yet. Use :DwightTDD first.", vim.log.levels.INFO)
		return
	end

	local uv = vim.loop or vim.uv
	local files = {}
	local handle = uv.fs_scandir(dir)
	if handle then
		while true do
			local name, ftype = uv.fs_scandir_next(handle)
			if not name then
				break
			end
			if ftype == "file" and name:match("%.txt$") then
				files[#files + 1] = name
			end
		end
	end
	table.sort(files, function(a, b)
		return a > b
	end) -- newest first

	if #files == 0 then
		vim.notify("[dwight] No test runs found.", vim.log.levels.INFO)
		return
	end

	local has_tel, pickers = pcall(require, "telescope.pickers")
	if has_tel then
		local finders = require("telescope.finders")
		local conf = require("telescope.config").values
		local actions = require("telescope.actions")
		local action_state = require("telescope.actions.state")
		local previewers = require("telescope.previewers")

		pickers
			.new({}, {
				prompt_title = "Test Runs (newest first)",
				finder = finders.new_table({
					results = files,
					entry_maker = function(name)
						local icon = name:match("_pass%.txt$") and "●" or "✗"
						return { value = dir .. "/" .. name, display = icon .. " " .. name, ordinal = name }
					end,
				}),
				sorter = conf.generic_sorter({}),
				previewer = previewers.new_buffer_previewer({
					define_preview = function(self, entry)
						local content = vim.fn.readfile(entry.value)
						vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, content)
					end,
				}),
				attach_mappings = function(pb)
					actions.select_default:replace(function()
						local sel = action_state.get_selected_entry()
						actions.close(pb)
						if sel then
							vim.cmd("edit " .. vim.fn.fnameescape(sel.value))
						end
					end)
					return true
				end,
			})
			:find()
	else
		local items = {}
		for i, name in ipairs(files) do
			items[i] = i .. ". " .. name
		end
		vim.ui.input({ prompt = table.concat(items, " | ") .. " > " }, function(c)
			if not c then
				return
			end
			local idx = tonumber(c)
			if idx and files[idx] then
				vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/" .. files[idx]))
			end
		end)
	end
end

function M.stop()
	if not M._session then
		vim.notify("[dwight] No TDD session active.", vim.log.levels.INFO)
		return
	end
	local iters = M._session.iterations
	M._session = nil
	vim.notify(string.format("[dwight] TDD session ended (%d iterations).", iters), vim.log.levels.INFO)
end

function M.is_active()
	return M._session ~= nil
end

return M
