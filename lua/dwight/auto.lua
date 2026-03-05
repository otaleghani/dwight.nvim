-- dwight/auto.lua
-- DwightAuto: autonomous mode for complex features.
-- Decomposes a big request into sequential sub-tasks, each executed by DwightAgent
-- without manual plan review. System notifications on completion/failure.
--
-- Flow: User request → LLM decomposition → sub-task 1 plan+execute → sub-task 2 → ... → done.
-- On failure: stop, save state, system notify. User can :DwightAutoResume.

local M = {}

local api = vim.api
local _flatten = require("dwight.util").flatten_lines

--------------------------------------------------------------------
-- System notifications (OS-level, not vim.notify)
--------------------------------------------------------------------

--- Detect OS and send a system notification.
--- Falls back silently if no notification tool is available.
function M._system_notify(title, body, urgency)
	urgency = urgency or "normal" -- "low", "normal", "critical"

	local uv = vim.loop or vim.uv
	local cmd, args

	if vim.fn.has("mac") == 1 then
		-- macOS: prefer terminal-notifier, fall back to osascript
		if vim.fn.executable("terminal-notifier") == 1 then
			cmd = "terminal-notifier"
			args = { "-title", title, "-message", body, "-sound", "default", "-group", "dwight-auto" }
		else
			cmd = "osascript"
			args = {
				"-e",
				string.format(
					'display notification "%s" with title "%s" sound name "Glass"',
					body:gsub('"', '\\"'),
					title:gsub('"', '\\"')
				),
			}
		end
	elseif vim.fn.executable("notify-send") == 1 then
		-- Linux: notify-send (libnotify)
		cmd = "notify-send"
		args = { "--urgency=" .. urgency, "--app-name=Dwight", title, body }
	elseif vim.fn.executable("powershell.exe") == 1 then
		-- Windows/WSL
		cmd = "powershell.exe"
		args = {
			"-Command",
			string.format(
				"[System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms'); "
					.. "$n = New-Object System.Windows.Forms.NotifyIcon; "
					.. "$n.Icon = [System.Drawing.SystemIcons]::Information; "
					.. "$n.Visible = $true; "
					.. "$n.ShowBalloonTip(5000, '%s', '%s', 'Info')",
				title:gsub("'", "''"),
				body:gsub("'", "''")
			),
		}
	end

	if not cmd then
		return
	end -- no notification tool available

	-- Fire and forget — don't block Neovim
	local handle
	handle = uv.spawn(cmd, {
		args = args,
		stdio = { nil, nil, nil },
		detached = true,
	}, function()
		if handle then
			handle:close()
		end
	end)
end

--- Convenience wrappers.
function M._notify_progress(task_num, total, task_title)
	M._system_notify(string.format("Dwight [%d/%d]", task_num, total), string.format("Completed: %s", task_title))
end

function M._notify_failure(task_num, total, task_title, err)
	M._system_notify(
		string.format("Dwight [%d/%d] FAILED", task_num, total),
		string.format("%s\n%s", task_title, (err or ""):sub(1, 100)),
		"critical"
	)
end

function M._notify_done(request, duration, cost)
	local cost_str = cost and cost > 0 and string.format(" (~$%.2f)", cost) or ""
	M._system_notify(
		"Dwight: All Done!",
		string.format("%s\nCompleted in %ds%s", request:sub(1, 80), duration, cost_str)
	)
end

--------------------------------------------------------------------
-- Git checkpoints: safe rollback between tasks
--------------------------------------------------------------------

local uv = vim.loop or vim.uv

--- Run a git command synchronously. Returns (output, exit_code).
local function git_sync(args, timeout_ms)
	local result, code_out, done = nil, nil, false
	local chunks = {}
	local stdout = uv.new_pipe(false)
	local handle
	handle = uv.spawn("git", {
		args = args,
		stdio = { nil, stdout, nil },
		cwd = vim.fn.getcwd(),
	}, function(code)
		if stdout then
			stdout:close()
		end
		if handle then
			handle:close()
		end
		vim.schedule(function()
			result = table.concat(chunks, "")
			code_out = code
			done = true
		end)
	end)
	if not handle then
		return nil, -1
	end
	stdout:read_start(function(e, d)
		if not e and d then
			chunks[#chunks + 1] = d
		end
	end)
	vim.wait(timeout_ms or 5000, function()
		return done
	end, 50)
	return result, code_out or -1
end

--- Check if the project is a git repo.
local function is_git_repo()
	local _, code = git_sync({ "rev-parse", "--git-dir" }, 2000)
	return code == 0
end

--- Create a git checkpoint after a successful task.
--- Commits all changes with a descriptive message.
--- Returns true if checkpoint was created.
function M._git_checkpoint(task_num, total, title, status)
	if not is_git_repo() then
		return false
	end

	-- Check if there are any changes to commit
	local diff_output, _ = git_sync({ "status", "--porcelain" }, 3000)
	if not diff_output or vim.trim(diff_output) == "" then
		status.append("  No changes to checkpoint (clean working tree)")
		return true -- not an error, just nothing to commit
	end

	-- Stage all changes
	local _, add_code = git_sync({ "add", "-A" }, 5000)
	if add_code ~= 0 then
		status.append("  WARN: Git add failed — skipping checkpoint")
		return false
	end

	-- Build a descriptive commit message using integration module (immediate, no LLM)
	local msg
	pcall(function()
		local integration = require("dwight.integration")
		msg = integration.smart_commit_message(task_num, total, title)
	end)
	if not msg or msg == "" then
		msg = string.format("feat: %s", title:sub(1, 65))
	end

	local _, commit_code = git_sync({ "commit", "-m", msg, "--no-verify" }, 10000)
	if commit_code ~= 0 then
		status.append("  WARN: Git commit failed — skipping checkpoint")
		return false
	end

	-- Show just the first line in the status
	local first_line = msg:match("^([^\n]+)")
	status.append(string.format("  Git checkpoint: %s", first_line))

	-- Background: upgrade commit message with LLM-generated one (fire-and-forget)
	-- Save the commit hash so we only amend THIS commit, not a later one
	local checkpoint_hash
	pcall(function()
		local h, _ = git_sync({ "rev-parse", "HEAD" }, 2000)
		if h then
			checkpoint_hash = vim.trim(h)
		end
	end)

	pcall(function()
		require("dwight.commit").generate_auto(title, task_num, total, function(ai_msg)
			if ai_msg and vim.trim(ai_msg) ~= "" then
				vim.schedule(function()
					pcall(function()
						-- Safety: only amend if HEAD is still our checkpoint commit
						local cur_head, _ = git_sync({ "rev-parse", "HEAD" }, 2000)
						if cur_head and checkpoint_hash and vim.trim(cur_head) == checkpoint_hash then
							local _, amend_code = git_sync({ "commit", "--amend", "-m", ai_msg, "--no-verify" }, 10000)
							if amend_code == 0 then
								local ai_first = ai_msg:match("^([^\n]+)")
								status.append(string.format("  Commit upgraded: %s", ai_first))
							end
						end
					end)
				end)
			end
		end)
	end)

	return true
end

--- Rollback to the last git checkpoint.
--- Used when a task fails and we want to reset to a clean state.
function M._git_rollback(status)
	if not is_git_repo() then
		return false
	end

	-- Reset to last commit (which is the checkpoint)
	local _, code = git_sync({ "reset", "--hard", "HEAD" }, 5000)
	if code ~= 0 then
		status.append("  WARN: Git rollback failed")
		return false
	end

	-- Clean untracked files too
	git_sync({ "clean", "-fd" }, 5000)

	status.append("  Git rollback: restored to last checkpoint")
	return true
end

--------------------------------------------------------------------
-- Inter-task verification pipeline
--------------------------------------------------------------------

--- Run a shell command asynchronously with a timeout.
--- callback(exit_code, combined_output)
local function run_gate_cmd(cmd, timeout_ms, callback)
	local stdout_chunks = {}
	local stderr_chunks = {}
	local stdout_pipe = uv.new_pipe(false)
	local stderr_pipe = uv.new_pipe(false)
	local done = false

	local handle
	handle = uv.spawn("sh", {
		args = { "-c", cmd },
		stdio = { nil, stdout_pipe, stderr_pipe },
		cwd = vim.fn.getcwd(),
	}, function(code)
		if done then
			return
		end
		done = true
		if stdout_pipe then
			pcall(function()
				stdout_pipe:close()
			end)
		end
		if stderr_pipe then
			pcall(function()
				stderr_pipe:close()
			end)
		end
		if handle then
			pcall(function()
				handle:close()
			end)
		end

		vim.schedule(function()
			local out = table.concat(stdout_chunks, "") .. table.concat(stderr_chunks, "")
			callback(code, out)
		end)
	end)

	if not handle then
		callback(-1, "failed to spawn: " .. cmd)
		return
	end

	-- Timeout
	local timer = uv.new_timer()
	timer:start(timeout_ms or 120000, 0, function()
		timer:close()
		if not done then
			done = true
			pcall(function()
				handle:kill("sigkill")
			end)
			vim.schedule(function()
				callback(-1, "timeout after " .. (timeout_ms / 1000) .. "s")
			end)
		end
	end)

	stdout_pipe:read_start(function(err, data)
		if not err and data then
			stdout_chunks[#stdout_chunks + 1] = data
		end
	end)
	stderr_pipe:read_start(function(err, data)
		if not err and data then
			stderr_chunks[#stderr_chunks + 1] = data
		end
	end)
end

--- Run the lint gate: project linter must pass (or be unavailable → skip).
--- callback(passed, output)
function M._gate_lint(status, callback)
	local agentic = require("dwight.agentic")
	local lint_cmd, lint_bin = agentic.get_lint_command()

	if not lint_cmd then
		callback(true, "") -- no linter → skip
		return
	end

	status.append(string.format("  Lint: %s", lint_cmd))

	run_gate_cmd(lint_cmd, 60000, function(code, output)
		if code == 0 then
			status.append("  Lint gate passed")
			callback(true, output)
		else
			-- Count issues
			local issue_count = 0
			for _ in output:gmatch("\n") do
				issue_count = issue_count + 1
			end
			status.append(string.format("  FAILED Lint gate (%s, ~%d issue(s))", lint_bin or "linter", issue_count))
			local n = 0
			for line in output:gmatch("[^\n]+") do
				status.append("    " .. line)
				n = n + 1
				if n >= 8 then
					status.append("    ...")
					break
				end
			end
			callback(false, output)
		end
	end)
end

--- Run the unit test gate with baseline failure filtering.
--- callback(passed, output)
function M._gate_tests(status, callback, baseline_failures)
	local agentic = require("dwight.agentic")
	local test_cmd = agentic.get_test_command()

	if not test_cmd then
		callback(true, "") -- no test command → skip
		return
	end

	status.append(string.format("  Tests: %s", test_cmd))

	run_gate_cmd(test_cmd, 120000, function(code, output)
		if code == 0 then
			status.append("  Test gate passed")
			callback(true, output)
		else
			-- Check if all failures are pre-existing (baseline) failures
			local new_failures = {}
			local all_failures = {}
			for test_name in output:gmatch("%-%-%-% FAIL:%s+(%S+)") do
				all_failures[#all_failures + 1] = test_name
				if not (baseline_failures and baseline_failures[test_name]) then
					new_failures[#new_failures + 1] = test_name
				end
			end

			if #new_failures == 0 and #all_failures > 0 then
				status.append(
					string.format(
						"  WARN: Test gate: %d pre-existing failure(s), no NEW failures — passing",
						#all_failures
					)
				)
				callback(true, output)
			else
				status.append("  FAILED Test gate (exit " .. code .. ")")
				if #new_failures > 0 then
					status.append(string.format("  %d NEW test failure(s):", #new_failures))
					for _, name in ipairs(new_failures) do
						status.append("    - " .. name)
					end
				end
				local n = 0
				for line in output:gmatch("[^\n]+") do
					status.append("    " .. line)
					n = n + 1
					if n >= 10 then
						status.append("    ...")
						break
					end
				end
				callback(false, output)
			end
		end
	end)
end

--- Run coverage delta check: coverage must not decrease.
--- baseline_coverage: number (percentage) captured before the run started.
--- callback(passed, output)
function M._gate_coverage(status, callback, baseline_coverage)
	if not baseline_coverage then
		callback(true, "") -- no baseline → skip
		return
	end

	local agentic = require("dwight.agentic")
	local cov_info = agentic.get_coverage_command()
	if not cov_info then
		callback(true, "") -- no coverage tool → skip
		return
	end

	status.append(string.format("  Coverage: %s", cov_info.cmd))

	run_gate_cmd(cov_info.cmd, 180000, function(code, output)
		-- Coverage command may "fail" if tests fail, but we already tested above.
		-- Parse coverage regardless of exit code.
		local new_coverage = cov_info.parse_total(output)
		if not new_coverage then
			status.append("  WARN: Coverage gate: couldn't parse coverage — skipping")
			callback(true, output)
			return
		end

		local delta = new_coverage - baseline_coverage
		if delta >= -1.0 then -- allow 1% tolerance for flaky coverage measurement
			status.append(
				string.format(
					"  Coverage gate passed: %.1f%% (baseline %.1f%%, delta %+.1f%%)",
					new_coverage,
					baseline_coverage,
					delta
				)
			)
			callback(true, output)
		else
			status.append(
				string.format(
					"  FAILED Coverage gate: %.1f%% → %.1f%% (dropped %.1f%%)",
					baseline_coverage,
					new_coverage,
					-delta
				)
			)
			status.append("     Agent's changes reduced test coverage. New code may be untested.")
			callback(false, output)
		end
	end)
end

--- Run smoke test: build the app and verify it starts.
--- callback(passed, output)
function M._gate_smoke(status, callback)
	local agentic = require("dwight.agentic")
	local smoke = agentic.get_smoke_command()

	if not smoke then
		callback(true, "") -- no entry point → skip
		return
	end

	status.append(string.format("  Smoke: %s", smoke.build))

	-- Step 1: Build
	run_gate_cmd(smoke.build, 60000, function(build_code, build_output)
		if build_code ~= 0 then
			status.append("  FAILED Smoke gate: build failed")
			local n = 0
			for line in build_output:gmatch("[^\n]+") do
				status.append("    " .. line)
				n = n + 1
				if n >= 8 then
					status.append("    ...")
					break
				end
			end
			-- Cleanup
			if smoke.cleanup then
				pcall(function()
					vim.fn.system(smoke.cleanup)
				end)
			end
			callback(false, build_output)
			return
		end

		-- Step 2: Run (quick start check)
		if smoke.run then
			status.append(string.format("  Smoke: %s", smoke.run))
			run_gate_cmd(smoke.run, 15000, function(run_code, run_output)
				-- Cleanup
				if smoke.cleanup then
					pcall(function()
						vim.fn.system(smoke.cleanup)
					end)
				end

				-- run_code may be non-zero for --help (some CLIs exit 1 for --help)
				-- We mainly care that it didn't crash/panic
				local panicked = run_output:match("panic:")
					or run_output:match("SIGSEGV")
					or run_output:match("fatal error:")
					or run_output:match("Traceback %(most recent")
					or run_output:match("Error: Cannot find module")
				if panicked then
					status.append("  FAILED Smoke gate: app panicked/crashed on startup")
					local n = 0
					for line in run_output:gmatch("[^\n]+") do
						status.append("    " .. line)
						n = n + 1
						if n >= 10 then
							status.append("    ...")
							break
						end
					end
					callback(false, run_output)
				else
					status.append("  Smoke gate passed (app builds and starts)")
					callback(true, run_output)
				end
			end)
		else
			-- No run command, build passing is enough
			if smoke.cleanup then
				pcall(function()
					vim.fn.system(smoke.cleanup)
				end)
			end
			status.append("  Smoke gate passed (builds successfully)")
			callback(true, build_output)
		end
	end)
end

--- Full verification pipeline: lint → tests → coverage → smoke.
--- Runs gates sequentially, stops at first failure.
--- callback(passed: boolean, output: string)
function M._verification_gate(status, callback, baseline_failures, baseline_coverage)
	status.append("  Verification pipeline")

	-- Gate 1: Lint
	M._gate_lint(status, function(lint_ok, lint_out)
		if not lint_ok then
			callback(false, lint_out)
			return
		end

		-- Gate 2: Unit tests
		M._gate_tests(status, function(test_ok, test_out)
			if not test_ok then
				callback(false, test_out)
				return
			end

			-- Gate 3: Coverage delta
			M._gate_coverage(status, function(cov_ok, cov_out)
				if not cov_ok then
					callback(false, cov_out)
					return
				end

				-- Gate 4: Smoke test
				M._gate_smoke(status, function(smoke_ok, smoke_out)
					if smoke_ok then
						status.append("  All verification gates passed")
					end
					callback(smoke_ok, smoke_out)
				end)
			end, baseline_coverage)
		end, baseline_failures)
	end)
end

--------------------------------------------------------------------
-- Task decomposition prompt
--------------------------------------------------------------------

local DECOMPOSE_PROMPT = [=[
You are Dwight, an autonomous coding agent. The developer wants a complex feature built.
Your job is to DECOMPOSE it into small, sequential sub-tasks that can each be executed
independently by a DwightAgent session (max 5-6 steps each).

The developer wants: %s

Project context:
%s

DECOMPOSITION RULES:
1. Each sub-task MUST be independently verifiable (tests pass after each sub-task).
2. Sub-tasks execute SEQUENTIALLY — each one can depend on files from previous ones.
3. Each sub-task should be small enough for a single DwightAgent plan (5-6 steps max).
4. Order matters: foundational work first (types, interfaces), then implementation, then wiring.
5. Include what each sub-task should produce (files, interfaces, tests).
6. MAXIMUM 8 sub-tasks. If the feature needs more, you're decomposing too finely.
7. Each sub-task description must be CONCRETE: include file paths, function names, types.
8. Do NOT include sub-tasks for "review" or "cleanup" — each sub-task should produce clean code.

USE THE EXPLORED CODE:
If <explored_code> is included above, you MUST base your decisions on the ACTUAL code:
- Use the EXACT interface names, method signatures, and type definitions from the code.
- Match the EXISTING testing patterns (test framework, assertion style, mock patterns).
- Reference the ACTUAL file structure and import paths from the project.
- Do NOT invent function signatures that don't match the existing interfaces.
- If the code shows a particular pattern (e.g., dependency injection, middleware chain),
  your sub-tasks should follow that same pattern.

CRITICAL — TDD ORDERING WITHIN EACH TASK:
9. Each sub-task MUST follow test-first order: write tests FIRST (verify-fail), then implement.
   NEVER put "implement handlers" before "write tests". The agent is more reliable when
   tests exist before implementation — it gives the on-fail handler something to target.

CRITICAL — FILE GROWTH AWARENESS:
10. If multiple sub-tasks edit the SAME file (e.g., server.go, server_test.go), be aware that
    each edit makes the file larger and harder for the agent to handle. When a file has been
    edited by 2+ prior tasks:
    - The sub-task description MUST list all existing functions/types in that file so the agent
      knows what to preserve.
    - Keep each edit step to 1-2 new functions maximum.
    - If adding 4+ functions to an already-edited file, split into two sub-tasks.
11. When a test file has been edited by prior tasks and needs NEW mock behavior (e.g., changing
    a stateless mock to stateful), this is a STRUCTURAL change. It should be its own step with
    a read action first, not combined with adding test functions.

CRITICAL — HANDLER + ROUTE WIRING IN SAME STEP:
12. When a sub-task implements HTTP handler functions, it MUST ALSO register the routes/endpoints
    for those handlers IN THE SAME SUB-TASK. NEVER split "implement handlers" and "register
    routes" into separate sub-tasks — the tests call the server's ServeHTTP/mux which returns
    404 for unregistered routes, so the verify step will fail if routes aren't registered.
    If handlers go in handlers.go and routes are registered in server.go, BOTH files must be
    edited in the same sub-task.

CRITICAL — TEMPLATE LOADING MUST USE EMBED:
13. When adding HTML template rendering to a Go web server, ALWAYS use `//go:embed templates/*.html`
    with `embed.FS` and `template.ParseFS`. NEVER use `template.Must(template.ParseGlob(...))` in
    a constructor — it panics during tests because the working directory differs. The sub-task
    description MUST specify embed.FS, not ParseGlob. Example: "Use `//go:embed templates/*.html`
    with `template.ParseFS` to load templates."

CRITICAL — FEATURE PRAGMA PROPAGATION:
14. This project tracks feature boundaries using `@feature:name` pragma comments on line 1 of
    source files. If the <project> context above lists features, ANY sub-task that creates new
    files belonging to an existing feature MUST include an instruction to add the pragma.
    Example: if splitting `auth.lua` (@feature:auth) into `auth/login.lua` and `auth/signup.lua`,
    the sub-task description must say: "Add `-- @feature:auth` on line 1 of each new file."
    Without this, the feature system loses track of the new files.

RESPOND IN THIS EXACT FORMAT (one sub-task per <task> block):

<tasks>
<task order="1" title="Short title">
Concrete description of what to build. Include:
- Exact file paths to create/edit
- Function signatures and types
- What tests to write
- What the verify command should be
</task>
<task order="2" title="Short title" depends_on="1">
...
</task>
</tasks>

IMPORTANT:
- The depends_on attribute is informational only — all tasks run sequentially.
- Each task description becomes the "request" for a DwightAgent session.
- Make descriptions detailed enough that the agent can execute correctly WITHOUT
  seeing the decomposition context. Each task description must be self-contained.
- If a task edits files created by a previous task, mention the file paths explicitly.

CRITICAL OUTPUT FORMAT RULES:
- Your response MUST contain <tasks>...</tasks> with at least 2 <task> blocks inside.
- Do NOT write a prose summary, overview, or architecture description instead of tasks.
- Do NOT explain the plan — just produce the <task> blocks.
- If you want to think through the design first, do so BRIEFLY, then ALWAYS follow with
  the <tasks> XML block containing the actual decomposition.
- Start your <tasks> block as early as possible in the response.
]=]

--- Parse decomposition XML into task list.
--- Returns { { order, title, description, depends_on }, ... }
--- Robust: handles attribute reordering, extra whitespace, markdown fences, fallback formats.
function M._parse_tasks(raw)
	local tasks = {}

	-- Strip markdown code fences if the LLM wrapped the output
	local cleaned = raw:gsub("```xml%s*\n?", ""):gsub("```%s*\n?", "")

	-- Strategy 1: Parse <task ...>...</task> blocks with flexible attribute extraction
	for attrs, body in cleaned:gmatch("<task%s+(.-)>(.-)</task>") do
		-- Extract attributes in any order
		local order_str = attrs:match('order="(%d+)"') or attrs:match("order='(%d+)'")
		local title = attrs:match('title="([^"]*)"') or attrs:match("title='([^']*)'")
		local depends = attrs:match('depends_on="([^"]*)"') or attrs:match("depends_on='([^']*)'")

		-- Title might span to a newline if attributes are on separate lines
		if not title then
			title = attrs:match('title="([^"]+)') -- unclosed quote (newline before close)
		end

		if title then
			tasks[#tasks + 1] = {
				order = tonumber(order_str) or #tasks + 1,
				title = vim.trim(title),
				description = vim.trim(body),
				depends_on = depends,
			}
		end
	end

	-- Strategy 2: Fallback — markdown headings like:
	--   ## Task 1: Title       ## Step 1: Title
	--   ### Task 1: Title      ### Step 1 - Title
	--   ### Sub-task 1: Title
	-- Handles any heading level (##, ###, ####), any keyword (Task/Step/Sub-task).
	-- NOTE: Lua patterns use + * - ? only. NO {2,} quantifier!
	--   ###* = two '#' followed by zero-or-more '#' = 2+ hashes.
	if #tasks == 0 then
		local current_title, current_order, current_body

		-- More specific patterns tried in order
		-- ###* matches "##" + optional extra "#"s = any heading level 2+
		-- [:%.%-%s] as separator handles : - . and whitespace
		local heading_patterns = {
			"^###*%s*[Ss]tep%s+(%d+)%s*[:%.%-]+%s*(.+)",
			"^###*%s*[Tt]ask%s+(%d+)%s*[:%.%-]+%s*(.+)",
			"^###*%s*[Ss]ub%-?[Tt]ask%s+(%d+)%s*[:%.%-]+%s*(.+)",
			"^###*%s*(%d+)%s*[:%.%-]+%s*(.+)", -- ### 1: Title (number only)
		}

		local function try_heading(line)
			for _, pat in ipairs(heading_patterns) do
				local num, t = line:match(pat)
				if num then
					return tonumber(num), t
				end
			end
			return nil, nil
		end

		for line in (cleaned .. "\n"):gmatch("([^\n]*)\n") do
			local num, t = try_heading(line)
			if num then
				-- Save previous task
				if current_title and current_body then
					tasks[#tasks + 1] = {
						order = current_order,
						title = vim.trim(current_title),
						description = vim.trim(current_body),
					}
				end
				current_order = num
				current_title = t
				current_body = ""
			elseif current_title then
				current_body = (current_body or "") .. line .. "\n"
			end
		end
		-- Don't forget the last task!
		if current_title and current_body then
			tasks[#tasks + 1] = {
				order = current_order,
				title = vim.trim(current_title),
				description = vim.trim(current_body),
			}
		end
	end

	-- Strategy 3: Fallback — numbered list: 1. **Title**: description
	if #tasks == 0 then
		for num, title, desc in cleaned:gmatch("(%d+)%.%s+%*%*([^*]+)%*%*:?%s*([^\n]+)") do
			tasks[#tasks + 1] = {
				order = tonumber(num) or #tasks + 1,
				title = vim.trim(title),
				description = vim.trim(desc),
			}
		end
	end

	-- Sort by order
	table.sort(tasks, function(a, b)
		return a.order < b.order
	end)
	return tasks
end

--- Decompose a complex request into sub-tasks.
--- Uses exploration-informed approach: reads key project files before decomposing
--- so the LLM makes decisions grounded in actual code, not just file names.
--- callback(tasks, err)
function M._decompose(request, callback)
	-- Phase 1: Gather project context (tree, manifest, pragmas)
	local context_parts = {}
	local project_info = nil

	pcall(function()
		local ctx = require("dwight.context")
		project_info = ctx.scan()
		local manifest = ctx.build_xml()
		if manifest then
			if #manifest > 1500 then
				manifest = manifest:sub(1, 1500) .. "\n..."
			end
			context_parts[#context_parts + 1] = manifest
		end
	end)

	pcall(function()
		local features = require("dwight.features")
		local xml = features.build_project_context()
		if xml and xml ~= "" then
			context_parts[#context_parts + 1] = xml
		end
		local names = features.names()
		if #names > 0 then
			context_parts[#context_parts + 1] = "Features: " .. table.concat(names, ", ")
		end
	end)

	local tree_lines = {}
	pcall(function()
		local bootstrap = require("dwight.bootstrap")
		local scan = bootstrap.scan()
		if scan.tree and #scan.tree > 0 then
			for _, line in ipairs(scan.tree) do
				tree_lines[#tree_lines + 1] = line
				if #tree_lines >= 60 then
					break
				end
			end
			context_parts[#context_parts + 1] = "<project_tree>\n"
				.. table.concat(tree_lines, "\n")
				.. "\n</project_tree>"
		end
	end)

	-- Inject skills + libs + pragma instructions via integration module
	pcall(function()
		local integration = require("dwight.integration")
		local full_ctx = integration.build_full_context()
		if full_ctx then
			context_parts[#context_parts + 1] = full_ctx
		end

		-- Feature-scoped context: if the request references specific features,
		-- inject their full signatures so decomposition is grounded in actual code
		local feature_ctx = integration.build_feature_context(request)
		if feature_ctx then
			context_parts[#context_parts + 1] = feature_ctx
		end
	end)

	-- Phase 2: Exploration — auto-read key files relevant to the request.
	-- This is what makes decomposition much better: the LLM sees actual code.
	local exploration_parts = {}
	local cwd = vim.fn.getcwd()
	local total_exploration_chars = 0
	local MAX_EXPLORATION_CHARS = 20000 -- Cap to avoid prompt bloat

	--- Read a file if it exists and we have budget, return content or nil.
	local function explore_file(rel_path)
		if total_exploration_chars >= MAX_EXPLORATION_CHARS then
			return nil
		end
		local full = cwd .. "/" .. rel_path
		local f = io.open(full, "r")
		if not f then
			return nil
		end
		local content = f:read("*a")
		f:close()
		if not content or content == "" then
			return nil
		end
		-- Cap individual files
		if #content > 4000 then
			content = content:sub(1, 4000) .. "\n... (truncated)"
		end
		total_exploration_chars = total_exploration_chars + #content
		return content
	end

	-- Strategy: read files that are most likely relevant to the request.
	-- Priority tiers (higher = read first):
	--   1. Interface/type definition files (the contracts)
	--   2. Files whose names match request keywords
	--   3. Main entry point, server/router wiring
	--   4. Existing test files (testing patterns)
	--   5. Config/README for project conventions

	local explore_patterns = {
		-- Tier 1: Interfaces and types (highest priority)
		{ pattern = "interface", desc = "interface definitions", priority = 10 },
		{ pattern = "types", desc = "type definitions", priority = 10 },
		{ pattern = "models", desc = "data models", priority = 9 },
		{ pattern = "schema", desc = "schema definitions", priority = 9 },
		-- Tier 2: Server/app wiring
		{ pattern = "server", desc = "server/app setup", priority = 7 },
		{ pattern = "router", desc = "routing", priority = 7 },
		{ pattern = "routes", desc = "routes", priority = 7 },
		{ pattern = "app", desc = "app setup", priority = 6 },
		{ pattern = "main", desc = "entry point", priority = 6 },
		-- Tier 3: Test files (learn testing patterns)
		{ pattern = "_test", desc = "test patterns", priority = 5 },
		{ pattern = "test_", desc = "test patterns", priority = 5 },
		{ pattern = ".spec", desc = "test patterns", priority = 5 },
		-- Tier 4: Config (project conventions)
		{ pattern = "config", desc = "configuration", priority = 3 },
		{ pattern = "readme", desc = "project documentation", priority = 2 },
	}

	-- Also look for files mentioned in or relevant to the request
	local request_lower = request:lower()
	local request_keywords = {}
	for word in request_lower:gmatch("%w+") do
		if #word > 3 then
			request_keywords[word] = true
		end
	end

	-- Scan tree for matching files, score by priority
	local scored_files = {}
	local files_seen = {}
	for _, line in ipairs(tree_lines) do
		if not line:match("/$") then -- skip directories
			local basename = line:match("[^/]+$") or line
			local base_lower = basename:lower()
			local best_priority = 0
			local best_reason = ""

			-- Check against explore patterns
			for _, ep in ipairs(explore_patterns) do
				if base_lower:match(ep.pattern) and ep.priority > best_priority then
					best_priority = ep.priority
					best_reason = ep.desc
				end
			end

			-- Check against request keywords (high priority — directly relevant)
			for kw in pairs(request_keywords) do
				if base_lower:match(kw) then
					best_priority = math.max(best_priority, 8) -- between interfaces and server
					best_reason = "matches request keyword '" .. kw .. "'"
				end
			end

			-- Content-based scoring: peek at first 200 bytes to check relevance
			if best_priority == 0 and not files_seen[line] then
				pcall(function()
					local peek_f = io.open(cwd .. "/" .. line, "r")
					if peek_f then
						local peek = peek_f:read(500)
						peek_f:close()
						if peek then
							local peek_lower = peek:lower()
							local keyword_hits = 0
							for kw in pairs(request_keywords) do
								if peek_lower:find(kw, 1, true) then
									keyword_hits = keyword_hits + 1
								end
							end
							if keyword_hits >= 2 then
								best_priority = 4 + keyword_hits -- scale with relevance
								best_reason = string.format("content matches %d request keywords", keyword_hits)
							end
						end
					end
				end)
			end

			if best_priority > 0 and not files_seen[line] then
				files_seen[line] = true
				scored_files[#scored_files + 1] = {
					path = line,
					reason = best_reason,
					priority = best_priority,
				}
			end
		end
	end

	-- Sort by priority (highest first) so we read the most important files within budget
	table.sort(scored_files, function(a, b)
		return a.priority > b.priority
	end)

	-- Limit test files to 2 max (we want patterns, not all tests)
	local test_count = 0
	local files_to_read = {}
	for _, entry in ipairs(scored_files) do
		if entry.reason == "test patterns" then
			test_count = test_count + 1
			if test_count > 2 then
				goto continue
			end
		end
		files_to_read[#files_to_read + 1] = entry
		::continue::
	end

	-- Read the files (most important first, cap at budget)
	for _, entry in ipairs(files_to_read) do
		local content = explore_file(entry.path)
		if content then
			exploration_parts[#exploration_parts + 1] = string.format(
				'<explored_file path="%s" reason="%s">\n%s\n</explored_file>',
				entry.path,
				entry.reason,
				content
			)
		end
	end

	if #exploration_parts > 0 then
		context_parts[#context_parts + 1] = "\n<explored_code>\n"
			.. "The following files were auto-read to help you understand the codebase. "
			.. "Use this code to make SPECIFIC, GROUNDED decisions about file paths, "
			.. "function signatures, interface contracts, and testing patterns.\n\n"
			.. table.concat(exploration_parts, "\n\n")
			.. "\n</explored_code>"
	end

	-- Phase 3: Build prompt and call LLM
	local context = #context_parts > 0 and table.concat(context_parts, "\n\n") or "(no context)"
	local prompt = string.format(DECOMPOSE_PROMPT, request, context)

	-- Log the decomposition call to DwightLog
	local log = require("dwight.log")
	local job_id = log._next_id()
	log.start(
		job_id,
		"auto:decompose",
		api.nvim_get_current_buf(),
		0,
		0,
		"DwightAuto decomposition: " .. request:sub(1, 200) .. "\n\n" .. prompt:sub(1, 4000)
	)
	-- Set metadata for DwightLog display
	pcall(function()
		local cfg = require("dwight").config
		local backend = cfg.backend or "api"
		local model = "?"
		if backend == "claude_code" then
			model = cfg.claude_code_model or "claude-code"
		else
			local providers = require("dwight.providers")
			local resolved = providers.resolve_model(nil)
			model = resolved.model_id or "?"
		end
		log.set_metadata(job_id, {
			model = model,
			backend = backend,
		})
	end)

	require("dwight.skills")._run_llm(prompt, function(raw, code)
		if code ~= 0 or not raw or vim.trim(raw) == "" then
			local detail = ""
			if not raw or vim.trim(raw or "") == "" then
				detail = " (empty response)"
			end
			local err_msg = "Decomposition LLM failed (exit " .. tostring(code) .. ")" .. detail
			log.finish(job_id, "error", raw or "", nil, err_msg)
			callback(nil, err_msg)
			return
		end

		-- Log raw output for debugging (write to .dwight/ if possible)
		pcall(function()
			local project = require("dwight.project")
			if project.is_initialized() then
				local log_path = project.dir() .. "/decompose-last.txt"
				local lf = io.open(log_path, "w")
				if lf then
					lf:write("-- DwightAuto decomposition output\n")
					lf:write("-- Request: " .. request:sub(1, 200) .. "\n")
					lf:write("-- Timestamp: " .. os.date() .. "\n\n")
					lf:write(raw)
					lf:close()
				end
			end
		end)

		local tasks = M._parse_tasks(raw)
		if #tasks == 0 then
			-- RETRY: The LLM may have returned a summary instead of structured tasks.
			-- Re-prompt once with a correction.
			log.append_note(job_id, "0 tasks parsed from first attempt, retrying with correction prompt")

			local retry_prompt = string.format(
				"Your previous response did NOT contain the required <task> XML blocks. "
					.. "You gave a prose summary instead. Here is what you wrote:\n\n"
					.. "---\n%s\n---\n\n"
					.. "Now rewrite this as the REQUIRED format. Your response MUST contain:\n\n"
					.. "<tasks>\n"
					.. '<task order="1" title="Short title">\nConcrete description...\n</task>\n'
					.. '<task order="2" title="Short title">\nConcrete description...\n</task>\n'
					.. "</tasks>\n\n"
					.. "Produce ONLY the <tasks> XML block. No preamble, no summary, no explanation.\n"
					.. "The original request was: %s",
				raw:sub(1, 3000),
				request:sub(1, 200)
			)

			require("dwight.skills")._run_llm(retry_prompt, function(retry_raw, retry_code)
				if retry_code ~= 0 or not retry_raw or vim.trim(retry_raw) == "" then
					local preview = raw:sub(1, 500):gsub("\n", " "):gsub("%s+", " ")
					local err_msg = "No tasks found in decomposition output (retry also failed). "
						.. "Check .dwight/decompose-last.txt for full LLM response. "
						.. "Preview: "
						.. preview
					log.finish(job_id, "parse_fail", raw, nil, err_msg)
					callback(nil, err_msg)
					return
				end

				-- Save retry output too
				pcall(function()
					local project = require("dwight.project")
					if project.is_initialized() then
						local log_path = project.dir() .. "/decompose-retry.txt"
						local lf = io.open(log_path, "w")
						if lf then
							lf:write("-- DwightAuto decomposition RETRY output\n")
							lf:write("-- Timestamp: " .. os.date() .. "\n\n")
							lf:write(retry_raw)
							lf:close()
						end
					end
				end)

				local retry_tasks = M._parse_tasks(retry_raw)
				if #retry_tasks == 0 then
					local preview = retry_raw:sub(1, 500):gsub("\n", " "):gsub("%s+", " ")
					local err_msg = "No tasks found even after retry. "
						.. "Check .dwight/decompose-retry.txt. "
						.. "Preview: "
						.. preview
					log.finish(job_id, "parse_fail", retry_raw, nil, err_msg)
					callback(nil, err_msg)
					return
				end

				-- Retry succeeded
				local task_summary = {}
				for _, t in ipairs(retry_tasks) do
					task_summary[#task_summary + 1] = string.format("%d. %s", t.order, t.title)
				end
				log.finish(
					job_id,
					"success",
					retry_raw,
					string.format("%d tasks (after retry):\n%s", #retry_tasks, table.concat(task_summary, "\n")),
					nil
				)

				callback(retry_tasks, nil)
			end)
			return
		end

		-- Log success
		local task_summary = {}
		for _, t in ipairs(tasks) do
			task_summary[#task_summary + 1] = string.format("%d. %s", t.order, t.title)
		end
		log.finish(
			job_id,
			"success",
			raw,
			string.format("%d tasks:\n%s", #tasks, table.concat(task_summary, "\n")),
			nil
		)

		callback(tasks, nil)
	end)
end

--------------------------------------------------------------------
-- Session state: save/load for resume, pause/continue
--------------------------------------------------------------------

--- Pause flag: when true, the loop stops after the current task completes.
--- Set by :DwightPause, cleared by :DwightContinue.
M._paused = false
M._pause_callback = nil -- stored continuation when paused

local function auto_dir()
	local project = require("dwight.project")
	if project.is_initialized() then
		return project.dir() .. "/auto"
	end
	return vim.fn.stdpath("data") .. "/dwight/auto"
end

function M._save_state(state)
	local dir = auto_dir()
	vim.fn.mkdir(dir, "p")
	local path = dir .. "/current.json"
	local f = io.open(path, "w")
	if f then
		f:write(vim.json.encode(state))
		f:close()
	end
end

function M._load_state()
	local path = auto_dir() .. "/current.json"
	local f = io.open(path, "r")
	if not f then
		return nil
	end
	local raw = f:read("*a")
	f:close()
	local ok, data = pcall(vim.json.decode, raw)
	if not ok then
		return nil
	end
	return data
end

function M._clear_state()
	pcall(os.remove, auto_dir() .. "/current.json")
end

--- Write a session summary log to .dwight/auto-logs/
--- Called after both successful and failed DwightAuto runs.
function M._write_session_log(opts)
	pcall(function()
		local project = require("dwight.project")
		if not project.is_initialized() then
			return
		end

		local log_dir = project.dir() .. "/auto-logs"
		vim.fn.mkdir(log_dir, "p")

		local timestamp = os.date("%Y%m%d-%H%M%S")
		local success = opts.success and "success" or "failed"
		local path = string.format("%s/%s-%s.md", log_dir, timestamp, success)

		local lines = {}
		lines[#lines + 1] = string.format("# DwightAuto Session — %s", os.date("%Y-%m-%d %H:%M:%S"))
		lines[#lines + 1] = ""
		lines[#lines + 1] = string.format("**Request:** %s", opts.request or "?")
		lines[#lines + 1] = string.format("**Result:** %s", opts.success and "SUCCESS" or "FAILED")
		lines[#lines + 1] = string.format("**Duration:** %ds", opts.duration or 0)
		lines[#lines + 1] = string.format("**Backend:** %s", opts.backend or "?")
		if opts.cost and opts.cost > 0 then
			lines[#lines + 1] = string.format("**Cost:** ~$%.2f", opts.cost)
		end
		lines[#lines + 1] =
			string.format("**Tasks:** %d/%d completed", opts.completed_count or 0, opts.total_tasks or 0)
		lines[#lines + 1] = ""

		-- Git diff stat: summary of ALL changes made in this session
		pcall(function()
			-- Get diff stat from the pre-auto checkpoint to HEAD
			local diff_handle =
				io.popen("git diff --stat HEAD~" .. tostring(opts.completed_count or 0) .. "..HEAD 2>/dev/null")
			if diff_handle then
				local diff_output = diff_handle:read("*a")
				diff_handle:close()
				if diff_output and diff_output ~= "" then
					lines[#lines + 1] = "## Changes Summary (git diff --stat)"
					lines[#lines + 1] = "```"
					lines[#lines + 1] = diff_output:sub(1, 3000)
					lines[#lines + 1] = "```"
					lines[#lines + 1] = ""
				end
			end
		end)

		-- Collect all files touched across all sessions
		local all_created = {}
		local all_edited = {}
		if opts.sessions then
			for _, s in ipairs(opts.sessions) do
				if s.files_created then
					for _, f in ipairs(s.files_created) do
						all_created[f] = true
					end
				end
				if s.files_edited then
					for _, f in ipairs(s.files_edited) do
						all_edited[f] = true
					end
				end
			end
		end

		-- File inventory
		local has_files = false
		for _ in pairs(all_created) do
			has_files = true
			break
		end
		if not has_files then
			for _ in pairs(all_edited) do
				has_files = true
				break
			end
		end

		if has_files then
			lines[#lines + 1] = "## Files Touched"
			lines[#lines + 1] = ""
			if next(all_created) then
				lines[#lines + 1] = "**Created:**"
				for f in pairs(all_created) do
					lines[#lines + 1] = "- `" .. f .. "`"
				end
				lines[#lines + 1] = ""
			end
			if next(all_edited) then
				lines[#lines + 1] = "**Modified:**"
				for f in pairs(all_edited) do
					if not all_created[f] then -- don't double-list
						lines[#lines + 1] = "- `" .. f .. "`"
					end
				end
				lines[#lines + 1] = ""
			end
		end

		-- Task details
		lines[#lines + 1] = "## Tasks"
		lines[#lines + 1] = ""
		if opts.sessions then
			for _, s in ipairs(opts.sessions) do
				local icon = s.had_error and "x" or "✓"
				local dur = s.duration and string.format(" (%ds)", s.duration) or ""
				local cost = (s.cost and s.cost > 0) and string.format(" $%.2f", s.cost) or ""
				lines[#lines + 1] =
					string.format("### %s Task %d: %s%s%s", icon, s.task_num or 0, s.title or "?", dur, cost)
				lines[#lines + 1] = ""

				-- Task description
				if s.description and s.description ~= "" then
					lines[#lines + 1] = "**Description:**"
					lines[#lines + 1] = s.description:sub(1, 500)
					lines[#lines + 1] = ""
				end

				-- Files touched by this task
				if (s.files_created and #s.files_created > 0) or (s.files_edited and #s.files_edited > 0) then
					lines[#lines + 1] = "**Files:**"
					if s.files_created then
						for _, f in ipairs(s.files_created) do
							lines[#lines + 1] = "- `" .. f .. "` (new)"
						end
					end
					if s.files_edited then
						for _, f in ipairs(s.files_edited) do
							lines[#lines + 1] = "- `" .. f .. "`"
						end
					end
					lines[#lines + 1] = ""
				end

				-- Full output from Claude Code / agentic loop
				if s.full_output and s.full_output ~= "" then
					lines[#lines + 1] = "<details><summary>Full agent output</summary>"
					lines[#lines + 1] = ""
					lines[#lines + 1] = "```"
					-- Cap at 5000 chars per task to keep log reasonable
					local output = s.full_output:sub(1, 5000)
					if #s.full_output > 5000 then
						output = output .. "\n... (truncated, " .. #s.full_output .. " chars total)"
					end
					lines[#lines + 1] = output
					lines[#lines + 1] = "```"
					lines[#lines + 1] = ""
					lines[#lines + 1] = "</details>"
					lines[#lines + 1] = ""
				elseif s.summary and s.summary ~= "" then
					-- Fallback to summary if no full output
					lines[#lines + 1] = "**Summary:**"
					lines[#lines + 1] = s.summary:sub(1, 1000)
					lines[#lines + 1] = ""
				end

				-- Error info
				if s.error and s.error ~= "" then
					lines[#lines + 1] = "**Error:** " .. s.error:sub(1, 500)
					lines[#lines + 1] = ""
				end

				lines[#lines + 1] = "---"
				lines[#lines + 1] = ""
			end
		end

		-- Failed task info
		if opts.failed_task then
			lines[#lines + 1] = "## Failure Details"
			lines[#lines + 1] = ""
			lines[#lines + 1] =
				string.format("Failed on task %d: %s", opts.failed_task.num or 0, opts.failed_task.title or "?")
			if opts.failed_task.error then
				lines[#lines + 1] = "Error: " .. opts.failed_task.error:sub(1, 500)
			end
			lines[#lines + 1] = ""
		end

		local f = io.open(path, "w")
		if f then
			f:write(table.concat(lines, "\n"))
			f:close()
		end
	end)
end

--------------------------------------------------------------------
-- Autonomous execution loop
--------------------------------------------------------------------

--- Build context summary from completed previous tasks.
--- Uses structured data from agentic finish (files_created, files_edited, summary)
--- instead of regex-parsing journal strings.
--- Capped at ~2500 chars to avoid overwhelming the next task.
function M._build_prev_context(completed_sessions)
	if not completed_sessions or #completed_sessions == 0 then
		return ""
	end

	local parts = {}
	parts[#parts + 1] = "\n\nPREVIOUS TASKS COMPLETED (the codebase has been modified by these):"

	-- Track all files touched across tasks for fragile file detection
	local file_touch_counts = {}

	for _, session in ipairs(completed_sessions) do
		local title = session.title or ("Task " .. (session.task_num or "?"))
		local status_icon = session.had_error and "x" or "✓"
		parts[#parts + 1] = string.format("\n%s Task %d: %s", status_icon, session.task_num or 0, title)

		-- Use structured data from agentic finish if available
		local created = session.files_created
		local edited = session.files_edited

		-- Fallback: parse from journal if structured data not available
		if (not created or #created == 0) and (not edited or #edited == 0) and session.journal then
			created = {}
			edited = {}
			local created_set, edited_set = {}, {}
			for _, j in ipairs(session.journal) do
				for file in (j or ""):gmatch("created ([%w_/%.%-]+)") do
					if not created_set[file] then
						created_set[file] = true
						created[#created + 1] = file
					end
				end
				for file in (j or ""):gmatch("edited ([%w_/%.%-]+)") do
					if not edited_set[file] then
						edited_set[file] = true
						edited[#edited + 1] = file
					end
				end
			end
		end

		if created and #created > 0 then
			parts[#parts + 1] = "  Created: " .. table.concat(created, ", ")
			for _, f in ipairs(created) do
				file_touch_counts[f] = (file_touch_counts[f] or 0) + 1
			end
		end
		if edited and #edited > 0 then
			parts[#parts + 1] = "  Edited: " .. table.concat(edited, ", ")
			for _, f in ipairs(edited) do
				file_touch_counts[f] = (file_touch_counts[f] or 0) + 1
			end
		end

		-- Include agentic summary if available (much more useful than journal regex)
		if session.summary and session.summary ~= "" then
			local summary = session.summary:sub(1, 200)
			parts[#parts + 1] = "  Summary: " .. summary
		end

		-- Include token usage for cost awareness
		if session.iterations then
			parts[#parts + 1] = string.format("  Effort: %d turns", session.iterations)
		end
	end

	-- Flag fragile files (touched by 2+ tasks)
	local fragile = {}
	for file, count in pairs(file_touch_counts) do
		if count >= 2 then
			fragile[#fragile + 1] = string.format("%s (%dx)", file, count)
		end
	end

	if #fragile > 0 then
		table.sort(fragile)
		parts[#parts + 1] = "\nFRAGILE FILES (edited by multiple tasks — read before editing, minimal changes):"
		parts[#parts + 1] = "  " .. table.concat(fragile, ", ")
	end

	local result = table.concat(parts, "\n")
	if #result > 2500 then
		result = result:sub(1, 2500) .. "\n... (truncated)"
	end
	return result
end

--- Execute a single sub-task: generate plan → auto-execute.
--- callback(success, session_data)
function M._execute_task(task, task_num, total_tasks, master_request, status, prev_sessions, callback)
	M._execute_task_agentic(task, task_num, total_tasks, master_request, status, prev_sessions, callback)
end

--------------------------------------------------------------------
-- Agentic execution: tool-use loop (new architecture)
--------------------------------------------------------------------

function M._execute_task_agentic(task, task_num, total_tasks, master_request, status, prev_sessions, callback)
	local agent = require("dwight.agent")
	local agentic = require("dwight.agentic")

	status.append(string.format("[%d/%d] %s", task_num, total_tasks, task.title))

	-- Build context
	local prev_context = M._build_prev_context(prev_sessions)
	local project_context = ""
	pcall(function()
		-- Reuse the agent's context gathering
		local context_mod = require("dwight.context")
		local manifest = context_mod.build_xml()
		if manifest then
			if #manifest > 1500 then
				manifest = manifest:sub(1, 1500) .. "\n... (deps truncated)"
			end
			project_context = project_context .. manifest .. "\n"
		end
	end)
	pcall(function()
		local features = require("dwight.features")
		local xml = features.build_project_context()
		if xml and xml ~= "" then
			project_context = project_context .. xml .. "\n"
		end
	end)
	pcall(function()
		local bootstrap = require("dwight.bootstrap")
		local scan = bootstrap.scan()
		if scan.tree and #scan.tree > 0 then
			local tree = table.concat(scan.tree, "\n")
			local lines = {}
			for line in tree:gmatch("[^\n]+") do
				lines[#lines + 1] = line
				if #lines >= 40 then
					break
				end
			end
			if #lines >= 40 then
				lines[#lines + 1] = "... (truncated)"
			end
			project_context = project_context
				.. "\n<project_tree>\n"
				.. table.concat(lines, "\n")
				.. "\n</project_tree>"
		end
	end)

	-- Inject lessons from past sessions
	local lessons_text = ""
	pcall(function()
		local lessons = agent._find_relevant_lessons(task.description)
		if lessons and #lessons > 0 then
			local parts = {}
			for _, l in ipairs(lessons) do
				parts[#parts + 1] = "- " .. l.text
			end
			lessons_text = "\n\n## Lessons from Past Sessions\n" .. table.concat(parts, "\n")
		end
	end)

	-- Inject skills + libs + pragma instructions via integration module
	local integration_text = ""
	pcall(function()
		local integration = require("dwight.integration")
		local full_ctx = integration.build_full_context()
		if full_ctx then
			integration_text = "\n\n" .. full_ctx
		end

		-- Feature-scoped context: if the task references specific features,
		-- inject their full signatures and source snippets
		local feature_ctx = integration.build_feature_context(task.description .. " " .. master_request)
		if feature_ctx then
			integration_text = integration_text .. "\n\n" .. feature_ctx
		end
	end)

	local task_description = string.format(
		'%s\n\nThis is sub-task %d/%d of the larger goal: "%s".\n'
			.. "Focus ONLY on what this sub-task describes. Do not implement anything beyond it.",
		task.description,
		task_num,
		total_tasks,
		master_request:sub(1, 100)
	)

	local started = os.time()
	local detected_lang = agentic.detect_language()

	agentic.run({
		task = task_description,
		context = project_context .. lessons_text .. integration_text,
		prev_tasks = prev_context ~= "" and prev_context or nil,
		language = detected_lang,

		on_status = function(text)
			if #text > 15 then
				status.stop_spin()
				status.append(string.format("[%d/%d] %s", task_num, total_tasks, text:sub(1, 500)))
			end
		end,

		on_tool = function(desc)
			status.stop_spin()
			status.append(string.format("  [%d/%d] %s", task_num, total_tasks, desc))
			status.spin(string.format("[%d/%d] working...", task_num, total_tasks))
		end,

		on_complete = function(success, data)
			local duration = os.time() - started
			status.stop_spin()

			local session_data = {
				task_num = task_num,
				title = task.title,
				description = task.description,
				had_error = not success,
				duration = duration,
				journal = data.journal or {},
				-- Use tracker cost, falling back to agentic loop's own estimate
				cost = (status.session_cost and status.session_cost() or 0) > 0
						and (status.session_cost and status.session_cost() or 0)
					or (data.estimated_cost or 0),
				agentic = true,
				iterations = data.iterations,
				summary = data.summary,
				-- Full output from Claude Code (used by session log)
				full_output = data.output,
				input_tokens = data.total_input_tokens or 0,
				output_tokens = data.total_output_tokens or 0,
				-- Structured file data from agentic finish (used by _build_prev_context)
				files_created = data.files_created or {},
				files_edited = data.files_edited or {},
				commands_run = data.commands_run or {},
			}

			-- Save session
			pcall(function()
				local session_id = os.date("%Y%m%d-%H%M%S")
				local safe_name = task.title:sub(1, 25):gsub("[^%w_%-]", "-"):gsub("%-+", "-")
				agent._save_session({
					id = session_id,
					name = "auto-" .. safe_name,
					request = task_description,
					had_error = not success,
					duration = duration,
					timestamp = os.time(),
					journal = data.journal,
					cost = session_data.cost,
					agentic = true,
					summary = data.summary,
				})
			end)

			-- Extract lessons
			pcall(function()
				agent._extract_lessons(
					{
						request = task_description,
						had_error = not success,
						timestamp = os.time(),
					},
					data.journal or {},
					function(lessons)
						if lessons and #lessons > 0 then
							agent._append_lessons(lessons)
							status.append(string.format("Learned %d lesson(s)", #lessons))
						end
					end
				)
			end)

			-- Report result
			local task_cost = session_data.cost or 0
			local cost_str = task_cost > 0 and string.format(" (~$%.2f)", task_cost) or ""
			local iter_str = data.iterations and string.format(" [%d turns]", data.iterations) or ""

			if success then
				status.append(
					string.format(
						"[%d/%d] %s — done in %ds%s%s",
						task_num,
						total_tasks,
						task.title,
						duration,
						cost_str,
						iter_str
					)
				)
			else
				status.append(
					string.format(
						"[%d/%d] %s — FAILED in %ds%s%s",
						task_num,
						total_tasks,
						task.title,
						duration,
						cost_str,
						iter_str
					)
				)
				-- Surface the actual error reason so it's not silently swallowed
				if data.error and data.error ~= "" then
					status.append(string.format("  Reason: %s", data.error:sub(1, 200)))
				end
				if data.summary and data.summary ~= "" then
					status.append(string.format("  %s", data.summary:sub(1, 200)))
				end
			end

			callback(success, session_data)
		end,
	})
end

--- Run the autonomous loop: execute tasks sequentially.
function M._run_loop(tasks, start_from, master_request, master_started, status, prev_sessions)
	local total = #tasks
	-- Seed with previous sessions (from resume or earlier in this run)
	local completed_sessions = {}
	if prev_sessions then
		for _, s in ipairs(prev_sessions) do
			completed_sessions[#completed_sessions + 1] = s
		end
	end
	local total_cost = 0

	-- Create initial git checkpoint before any tasks run
	if is_git_repo() then
		local diff_out, _ = git_sync({ "status", "--porcelain" }, 3000)
		if diff_out and vim.trim(diff_out) ~= "" then
			git_sync({ "add", "-A" }, 5000)
			git_sync({ "commit", "-m", "chore: pre-session checkpoint", "--no-verify" }, 10000)
			status.append("Initial git checkpoint saved")
		end
	end

	-- Snapshot HEAD for post-session diff review
	local pre_head = nil
	pcall(function()
		local out = vim.fn.system("git rev-parse HEAD 2>/dev/null")
		if vim.v.shell_error == 0 then
			pre_head = vim.trim(out)
		end
	end)

	-- Capture baseline test failures BEFORE any tasks run.
	-- This way we only fail the verification gate on NEW test failures,
	-- not pre-existing broken tests in the project.
	local baseline_failures = {}
	pcall(function()
		local agentic = require("dwight.agentic")
		local test_cmd = agentic.get_test_command()
		if not test_cmd then
			return
		end

		status.append("Running baseline test snapshot...")
		local output = vim.fn.system(test_cmd .. " 2>&1")
		local code = vim.v.shell_error

		if code ~= 0 then
			-- Extract failing test names: "--- FAIL: TestName (0.00s)"
			for test_name in output:gmatch("%-%-%-% FAIL:%s+(%S+)") do
				baseline_failures[test_name] = true
			end
			local count = 0
			for _ in pairs(baseline_failures) do
				count = count + 1
			end
			if count > 0 then
				status.append(
					string.format("  WARN: %d pre-existing test failure(s) (will be ignored in gates)", count)
				)
				for name, _ in pairs(baseline_failures) do
					status.append("    - " .. name)
				end
			else
				-- Tests failed but we couldn't parse test names — might be compile error
				status.append("  WARN: Baseline tests failed (couldn't parse test names — may be compile error)")
				-- Show first few lines
				local n = 0
				for line in output:gmatch("[^\n]+") do
					status.append("    " .. line)
					n = n + 1
					if n >= 5 then
						break
					end
				end
			end
		else
			status.append("  Baseline tests pass")
		end
	end)

	-- Capture baseline coverage BEFORE any tasks run.
	-- Used by the coverage delta gate to detect regressions.
	local baseline_coverage = nil
	pcall(function()
		local agentic = require("dwight.agentic")
		local cov_info = agentic.get_coverage_command()
		if not cov_info then
			return
		end

		status.append("Capturing baseline coverage...")
		local output = vim.fn.system(cov_info.cmd .. " 2>&1")
		local pct = cov_info.parse_total(output)
		if pct then
			baseline_coverage = pct
			status.append(string.format("  Baseline coverage: %.1f%%", pct))
		else
			status.append("  WARN: Couldn't parse baseline coverage — delta gate will be skipped")
		end
	end)

	-- Check lint baseline (just note if linter is available)
	pcall(function()
		local agentic = require("dwight.agentic")
		local lint_cmd, lint_bin = agentic.get_lint_command()
		if lint_cmd then
			status.append(string.format("Linter available: %s", lint_bin))
		end
		local smoke = agentic.get_smoke_command()
		if smoke then
			status.append("Smoke test available")
		end
	end)

	local function run_next(idx)
		if idx > total then
			-- ALL DONE
			local total_duration = os.time() - master_started
			total_cost = status.session_cost and status.session_cost() or 0

			status.stop_spin()
			status.append(string.rep("═", 40))
			status.append(string.format("ALL %d TASKS COMPLETE in %ds", total, total_duration))

			-- Per-task cost breakdown
			local tokens = status.session_tokens and status.session_tokens() or { input = 0, output = 0, total = 0 }
			status.append("")
			status.append("Usage:")
			for _, s in ipairs(completed_sessions) do
				local task_cost = s.cost or 0
				local cost_str = task_cost > 0 and string.format("$%.2f", task_cost) or "—"
				local icon = s.had_error and "x" or "✓"
				status.append(string.format("  %s Task %d: %s (%s)", icon, s.task_num or 0, s.title or "?", cost_str))
			end
			status.append("  ──────────────────────")
			if total_cost > 0 then
				status.append(string.format("  Cost:   ~$%.2f", total_cost))
			end
			if tokens.total > 0 then
				local fmt_tok = function(n)
					if n >= 1000000 then
						return string.format("%.1fM", n / 1000000)
					end
					if n >= 1000 then
						return string.format("%.1fk", n / 1000)
					end
					return tostring(n)
				end
				status.append(
					string.format(
						"  Tokens: %s in / %s out (%s total)",
						fmt_tok(tokens.input),
						fmt_tok(tokens.output),
						fmt_tok(tokens.total)
					)
				)
			end

			status.end_session(true, total_duration)

			-- Post-session integration: audit suggestions, split warnings, squash offer
			pcall(function()
				local integration = require("dwight.integration")
				integration.post_session(master_request, completed_sessions, status)
			end)

			-- Post-session diff review (reuse agent's diff_review)
			pcall(function()
				local agent = require("dwight.agent")
				agent._show_post_diff(status, pre_head)
			end)

			-- If solving a GitHub issue, prompt for PR
			pcall(function()
				local gh = require("dwight.github")
				if gh._active_issue then
					vim.defer_fn(function()
						gh.maybe_offer_pr()
					end, 1000)
				end
			end)

			-- Write session summary log
			local cfg_ok, cfg = pcall(function()
				return require("dwight").config
			end)
			M._write_session_log({
				success = true,
				request = master_request,
				duration = total_duration,
				backend = cfg_ok and cfg.backend or "?",
				cost = total_cost,
				total_tasks = total,
				completed_count = total,
				sessions = completed_sessions,
			})

			M._clear_state()
			M._paused = false
			M._pause_callback = nil
			M._notify_done(master_request, total_duration, total_cost)

			vim.notify(
				string.format("[dwight] DwightAuto: all %d tasks complete in %ds!", total, total_duration),
				vim.log.levels.INFO
			)
			return
		end

		local task = tasks[idx]

		-- Save state for resume
		M._save_state({
			request = master_request,
			tasks = tasks,
			current_task = idx,
			started = master_started,
			completed = completed_sessions,
		})

		status.append("")
		status.header(string.format("Task %d/%d: %s", idx, total, task.title))

		M._execute_task(task, idx, total, master_request, status, completed_sessions, function(success, session_data)
			completed_sessions[#completed_sessions + 1] = session_data

			-- Track running cost
			local running_cost = status.session_cost and status.session_cost() or 0

			-- Helper: handle failure (used by both direct failure and gate failure)
			local function handle_failure(err_msg)
				-- Kill any running agentic process (prevents zombie Claude Code sessions)
				pcall(function()
					agentic.abort()
				end)

				-- Capture the diff BEFORE rolling back (for retry-in-place)
				local failure_diff = ""
				local failure_diff_stat = ""
				pcall(function()
					if is_git_repo() then
						failure_diff_stat = vim.fn.system("git diff --stat HEAD 2>/dev/null") or ""
						failure_diff = vim.fn.system("git diff HEAD 2>/dev/null") or ""
						-- Cap at reasonable size
						if #failure_diff > 15000 then
							failure_diff = failure_diff:sub(1, 15000) .. "\n... (truncated)"
						end
					end
				end)

				-- Wait 3s for Claude Code to fully die before git rollback.
				-- Without this delay, Claude Code child processes may recreate files
				-- that git clean just removed.
				local rollback_timer = uv.new_timer()
				rollback_timer:start(3000, 0, function()
					rollback_timer:close()
					vim.schedule(function()
						-- Rollback to last checkpoint
						M._git_rollback(status)

						M._save_state({
							request = master_request,
							tasks = tasks,
							current_task = idx,
							started = master_started,
							completed = completed_sessions,
							failed = true,
							error = err_msg or "execution failed",
							-- Retry context: what the failed attempt produced before rollback
							retry_context = {
								diff_stat = failure_diff_stat,
								diff = failure_diff,
								error = err_msg,
								summary = session_data.summary or "",
								task_title = task.title,
							},
						})

						M._notify_failure(idx, total, task.title, err_msg)

						local total_duration = os.time() - master_started
						total_cost = status.session_cost and status.session_cost() or 0

						local tokens = status.session_tokens and status.session_tokens()
							or { input = 0, output = 0, total = 0 }
						status.append("")
						status.append("Usage:")
						for _, s in ipairs(completed_sessions) do
							local task_cost = s.cost or 0
							local cost_str = task_cost > 0 and string.format("$%.2f", task_cost) or "—"
							local icon = s.had_error and "x" or "✓"
							status.append(
								string.format("  %s Task %d: %s (%s)", icon, s.task_num or 0, s.title or "?", cost_str)
							)
						end
						status.append("  ──────────────────────")
						if total_cost > 0 then
							status.append(string.format("  Cost:   ~$%.2f", total_cost))
						end
						if tokens.total > 0 then
							local fmt_tok = function(n)
								if n >= 1000000 then
									return string.format("%.1fM", n / 1000000)
								end
								if n >= 1000 then
									return string.format("%.1fk", n / 1000)
								end
								return tostring(n)
							end
							status.append(
								string.format(
									"  Tokens: %s in / %s out (%s total)",
									fmt_tok(tokens.input),
									fmt_tok(tokens.output),
									fmt_tok(tokens.total)
								)
							)
						end

						status.stop_spin()
						status.end_session(false, total_duration)

						-- Write session summary log
						local cfg_ok2, cfg2 = pcall(function()
							return require("dwight").config
						end)
						M._write_session_log({
							success = false,
							request = master_request,
							duration = total_duration,
							backend = cfg_ok2 and cfg2.backend or "?",
							cost = total_cost,
							total_tasks = total,
							completed_count = idx - 1,
							sessions = completed_sessions,
							failed_task = {
								num = idx,
								title = task.title,
								error = err_msg,
							},
						})

						vim.notify(
							string.format(
								"[dwight] DwightAuto: task %d/%d failed (%s). Use :DwightAutoRetry to retry in place, :DwightAutoResume to restart, :DwightAutoSkip to skip.",
								idx,
								total,
								task.title
							),
							vim.log.levels.ERROR
						)
					end) -- vim.schedule
				end) -- rollback_timer
			end -- handle_failure

			if success then
				M._notify_progress(idx, total, task.title)

				-- Show running total
				local running_tokens = status.session_tokens and status.session_tokens()
					or { input = 0, output = 0, total = 0 }
				local parts = {}
				if running_cost > 0 then
					parts[#parts + 1] = string.format("~$%.2f", running_cost)
				end
				if running_tokens.total > 0 then
					local fmt = function(n)
						if n >= 1000 then
							return string.format("%.1fk", n / 1000)
						end
						return tostring(n)
					end
					parts[#parts + 1] = fmt(running_tokens.total) .. " tok"
				end
				if #parts > 0 then
					status.append(string.format("  Running total: %s", table.concat(parts, " | ")))
				end

				-- Git checkpoint
				M._git_checkpoint(idx, total, task.title, status)

				-- Verification pipeline: lint → tests → coverage → smoke
				-- Pass baseline_failures and baseline_coverage for delta checks
				M._verification_gate(status, function(gate_passed, gate_output)
					if gate_passed then
						-- Show diff stats for this task's changes
						pcall(function()
							if is_git_repo() then
								local diff_out = vim.fn.system("git diff --stat HEAD~1..HEAD 2>/dev/null")
								if diff_out and vim.trim(diff_out) ~= "" then
									status.append("  Changes:")
									for line in diff_out:gmatch("[^\n]+") do
										status.append("    " .. line)
									end
								end
							end
						end)

						-- Post-task integration: pragma sync + feature index rebuild
						pcall(function()
							local integration = require("dwight.integration")
							-- Detect feature name from the request or task description
							local feature_name = integration.detect_feature_name(master_request)
							if not feature_name then
								feature_name = integration.detect_feature_name(task.description)
							end

							local sync = integration.pragma_sync(feature_name)
							if #sync.added > 0 then
								status.append(
									string.format(
										"  Pragma sync: added @feature:%s to %d new file(s)",
										feature_name or "?",
										#sync.added
									)
								)
								for _, path in ipairs(sync.added) do
									status.append("     + " .. path)
								end
								-- Stage the pragma additions so they're included in the checkpoint
								git_sync({ "add", "-A" }, 3000)
								git_sync({ "commit", "--amend", "--no-edit", "--no-verify" }, 5000)
							end

							-- Rebuild feature index
							integration.rebuild_features()
						end)

						-- Check if paused: stop here and save continuation
						if M._paused then
							status.append("")
							status.append(
								string.format("PAUSED after task %d/%d. Use :DwightContinue to resume.", idx, total)
							)
							status.append("   Use :DwightContinue [prompt] to override next task's description.")
							status.append("   Use :DwightAutoSkip to skip the next task.")

							M._save_state({
								request = master_request,
								tasks = tasks,
								current_task = idx + 1,
								started = master_started,
								completed = completed_sessions,
								paused = true,
							})

							M._pause_callback = function(override_prompt)
								M._paused = false
								M._pause_callback = nil
								-- Apply override if given
								if override_prompt and override_prompt ~= "" and tasks[idx + 1] then
									tasks[idx + 1].description = override_prompt
									status.append(string.format("Task %d prompt overridden.", idx + 1))
								end
								run_next(idx + 1)
							end
							return
						end

						run_next(idx + 1)
					else
						-- Verification pipeline failed after this "successful" task
						status.append(
							string.format("  FAILED Task %d reported success but verification pipeline failed!", idx)
						)
						session_data.had_error = true
						session_data.gate_failed = true
						handle_failure("Verification pipeline failed after task " .. idx)
					end
				end, baseline_failures, baseline_coverage)
			else
				-- Direct failure from agentic loop
				handle_failure(session_data.error or "execution failed")
			end
		end)
	end

	run_next(start_from)
end

--------------------------------------------------------------------
-- Plan preview: show decomposition before executing
--------------------------------------------------------------------

--- Show decomposed tasks in a review buffer.
--- <CR> starts execution, e opens task for editing, q cancels.
function M._show_decomposition(request, tasks, callback)
	-- Sanitize: replace newlines in inline text that goes into single lines
	local safe_request = request:sub(1, 60):gsub("\n", " ")

	local lines = {
		"<!-- ═══════════════════════════════════════════════════════ -->",
		string.format("<!-- DwightAuto: %s -->", safe_request),
		string.format("<!-- %d sub-tasks to execute sequentially -->", #tasks),
		"<!-- -->",
		"<!-- <CR> start autonomous execution | q cancel -->",
		"<!-- Edit task descriptions freely before starting -->",
		"<!-- ═══════════════════════════════════════════════════════ -->",
		"",
	}

	for _, task in ipairs(tasks) do
		local safe_title = (task.title or ""):gsub("\n", " ")
		lines[#lines + 1] = string.format("## Task %d: %s", task.order, safe_title)
		lines[#lines + 1] = ""
		for desc_line in (task.description or ""):gmatch("[^\n]+") do
			lines[#lines + 1] = desc_line
		end
		lines[#lines + 1] = ""
		lines[#lines + 1] = "---"
		lines[#lines + 1] = ""
	end

	local buf = api.nvim_create_buf(true, false)
	api.nvim_buf_set_lines(buf, 0, -1, false, _flatten(lines))
	vim.bo[buf].filetype = "markdown"
	vim.bo[buf].bufhidden = "wipe"
	pcall(function()
		api.nvim_buf_set_name(buf, "dwight://auto-plan")
	end)

	vim.cmd("tab split")
	api.nvim_win_set_buf(0, buf)

	-- Keymaps
	vim.keymap.set("n", "<CR>", function()
		-- Re-parse tasks from buffer (user may have edited)
		local buf_lines = api.nvim_buf_get_lines(buf, 0, -1, false)
		local text = table.concat(buf_lines, "\n")
		local edited_tasks = M._parse_buffer_tasks(text)

		if #edited_tasks == 0 then
			vim.notify("[dwight] No tasks found. Keep the ## Task N: Title format.", vim.log.levels.WARN)
			return
		end

		-- Close the preview buffer
		pcall(api.nvim_buf_delete, buf, { force = true })

		callback(edited_tasks)
	end, { buffer = buf, desc = "Start autonomous execution" })

	vim.keymap.set("n", "q", function()
		pcall(api.nvim_buf_delete, buf, { force = true })
		vim.notify("[dwight] DwightAuto cancelled.", vim.log.levels.INFO)
	end, { buffer = buf, desc = "Cancel" })
end

--- Parse tasks from the editable buffer format.
--- Returns { { order, title, description }, ... }
function M._parse_buffer_tasks(text)
	local tasks = {}
	local current_task = nil

	for line in text:gmatch("[^\n]*") do
		local order, title = line:match("^## Task (%d+): (.+)")
		if order then
			if current_task then
				current_task.description = vim.trim(current_task.description)
				tasks[#tasks + 1] = current_task
			end
			current_task = {
				order = tonumber(order),
				title = vim.trim(title),
				description = "",
			}
		elseif current_task then
			-- Skip separator lines and comment lines
			if not line:match("^%-%-%-") and not line:match("^<!%-%-") then
				current_task.description = current_task.description .. line .. "\n"
			end
		end
	end

	-- Don't forget the last task
	if current_task then
		current_task.description = vim.trim(current_task.description)
		tasks[#tasks + 1] = current_task
	end

	table.sort(tasks, function(a, b)
		return a.order < b.order
	end)
	return tasks
end

--------------------------------------------------------------------
-- Main entry: :DwightAuto [request]
--------------------------------------------------------------------

function M.auto(request)
	if not request or vim.trim(request) == "" then
		require("dwight.ui").open_prompt(nil, {
			dispatch = "auto",
		})
		return
	end

	-- Check project is initialized
	local project = require("dwight.project")
	if not project.is_initialized() then
		vim.notify("[dwight] Run :DwightInit first.", vim.log.levels.WARN)
		return
	end

	-- Check if there's already an auto session running
	local existing = M._load_state()
	if existing and not existing.failed then
		vim.notify(
			"[dwight] An auto session is already in progress. Use :DwightAutoResume or :DwightAutoCancel.",
			vim.log.levels.WARN
		)
		return
	end

	-- Pre-flight: check if the request involves features that are too large
	pcall(function()
		local split = require("dwight.split")
		local oversized = split.audit()
		if #oversized > 0 then
			local names = {}
			for _, r in ipairs(oversized) do
				names[#names + 1] = "$" .. r.name
			end
			vim.notify(
				string.format(
					"[dwight] Large features detected: %s. Consider :DwightSplitFeature to improve reliability.",
					table.concat(names, ", ")
				),
				vim.log.levels.WARN
			)
		end
	end)

	vim.notify("[dwight] DwightAuto: decomposing request into sub-tasks…", vim.log.levels.INFO)

	M._decompose(request, function(tasks, err)
		if err then
			vim.notify("[dwight] Decomposition failed: " .. err, vim.log.levels.ERROR)
			return
		end

		vim.notify(
			string.format("[dwight] Decomposed into %d sub-tasks. Review and <CR> to start.", #tasks),
			vim.log.levels.INFO
		)

		-- Show preview, let user review/edit, then start
		M._show_decomposition(request, tasks, function(final_tasks)
			M._start_execution(request, final_tasks, 1)
		end)
	end)
end

--- Start autonomous execution (used by both auto and resume).
function M._start_execution(request, tasks, start_from, prev_sessions)
	local status = require("dwight.agent_status")
	local master_started = os.time()

	status.start_session("Auto: " .. request:sub(1, 50))
	status.append(string.format("%d sub-tasks, starting from task %d", #tasks, start_from))
	for i, task in ipairs(tasks) do
		local marker = i < start_from and "✓" or (i == start_from and ">" or " ")
		status.append(string.format("  %s %d. %s", marker, i, task.title))
	end

	M._system_notify("Dwight Auto Started", string.format("%d tasks: %s", #tasks, request:sub(1, 80)))

	M._run_loop(tasks, start_from, request, master_started, status, prev_sessions)
end

--------------------------------------------------------------------
-- Resume from failure
--------------------------------------------------------------------

function M.resume(opts)
	opts = opts or {}
	local state = M._load_state()
	if not state then
		vim.notify("[dwight] No auto session to resume. Run :DwightAuto first.", vim.log.levels.INFO)
		return
	end

	-- Handle paused state (from :DwightContinue)
	if state.paused and M._pause_callback then
		M._pause_callback(opts.override_prompt)
		return
	end

	if not state.failed and not state.paused then
		vim.notify("[dwight] Auto session is not in a failed/paused state. Nothing to resume.", vim.log.levels.INFO)
		return
	end

	local task_num = state.current_task or 1
	local total = #state.tasks
	local skip = opts.skip or false

	-- If skipping the failed task, advance to next
	if skip then
		if task_num >= total then
			vim.notify("[dwight] Can't skip — already at last task.", vim.log.levels.WARN)
			return
		end
		vim.notify(
			string.format("[dwight] Skipping task %d/%d: %s", task_num, total, state.tasks[task_num].title),
			vim.log.levels.INFO
		)
		task_num = task_num + 1
	end

	-- Show summary of what's already done
	local completed_count = state.completed and #state.completed or 0
	local msg_parts = {
		string.format("[dwight] Resuming DwightAuto from task %d/%d", task_num, total),
		string.format("   %d task(s) already completed:", completed_count),
	}
	if state.completed then
		for _, s in ipairs(state.completed) do
			local icon = s.had_error and "x" or "✓"
			msg_parts[#msg_parts + 1] = string.format("     %s %d. %s", icon, s.task_num or 0, s.title or "?")
		end
	end
	msg_parts[#msg_parts + 1] = string.format("   Next: %s", state.tasks[task_num].title)
	vim.notify(table.concat(msg_parts, "\n"), vim.log.levels.INFO)

	-- Show diff summary of changes so far
	pcall(function()
		if is_git_repo() and completed_count > 0 then
			local diff = vim.fn.system("git diff --stat HEAD~" .. completed_count .. "..HEAD 2>/dev/null")
			if diff and vim.trim(diff) ~= "" then
				vim.notify("[dwight] Changes so far:\n" .. diff:sub(1, 1000), vim.log.levels.INFO)
			end
		end
	end)

	-- If override prompt given, apply it to the target task
	if opts.override_prompt and opts.override_prompt ~= "" then
		state.tasks[task_num].description = opts.override_prompt
		vim.notify(string.format("[dwight] Overriding task %d description.", task_num), vim.log.levels.INFO)
	end

	-- Direct resume (no decomposition review needed — user already saw it)
	if opts.review then
		M._show_decomposition(state.request, state.tasks, function(final_tasks)
			M._start_execution(state.request, final_tasks, task_num, state.completed or {})
		end)
	else
		M._start_execution(state.request, state.tasks, task_num, state.completed or {})
	end
end

--------------------------------------------------------------------
-- Pause: stop after current task completes
--------------------------------------------------------------------

function M.pause()
	if M._paused then
		vim.notify("[dwight] Already paused. Use :DwightContinue to resume.", vim.log.levels.INFO)
		return
	end
	M._paused = true
	vim.notify("[dwight] DwightAuto will pause after the current task completes.", vim.log.levels.INFO)
end

--------------------------------------------------------------------
-- Continue: resume from paused state
--------------------------------------------------------------------

function M.continue(override_prompt)
	if M._pause_callback then
		vim.notify("[dwight] Continuing DwightAuto...", vim.log.levels.INFO)
		M._pause_callback(override_prompt)
		return
	end

	-- Fallback: try loading from saved state
	local state = M._load_state()
	if state and state.paused then
		M.resume({ override_prompt = override_prompt })
		return
	end

	vim.notify("[dwight] Nothing to continue. Use :DwightAuto to start a new session.", vim.log.levels.INFO)
end

--------------------------------------------------------------------
-- Skip: skip the next/failed task
--------------------------------------------------------------------

function M.skip()
	-- If paused with a callback, skip by advancing
	if M._pause_callback then
		vim.notify("[dwight] Skipping next task...", vim.log.levels.INFO)
		-- We need to reach into the closure — cleaner to use resume with skip
		M._paused = false
		M._pause_callback = nil
		M.resume({ skip = true })
		return
	end

	-- Otherwise try resuming with skip
	local state = M._load_state()
	if state and (state.failed or state.paused) then
		M.resume({ skip = true })
	else
		vim.notify("[dwight] Nothing to skip.", vim.log.levels.INFO)
	end
end

--------------------------------------------------------------------
-- Retry in place: re-run the failed task with error context
--------------------------------------------------------------------

--- Retry the failed task, injecting context about what the previous attempt
--- did wrong. The working tree is already rolled back to the last checkpoint.
--- The agent gets: original task + what was attempted + what went wrong.
function M.retry()
	local state = M._load_state()
	if not state then
		vim.notify("[dwight] No auto session to retry. Run :DwightAuto first.", vim.log.levels.INFO)
		return
	end
	if not state.failed then
		vim.notify("[dwight] Session is not in a failed state. Nothing to retry.", vim.log.levels.INFO)
		return
	end

	local task_num = state.current_task or 1
	local total = #state.tasks
	local task = state.tasks[task_num]
	local rc = state.retry_context

	if rc then
		-- Inject retry context into the task description
		local retry_hint_parts = {
			"\n\n## PREVIOUS ATTEMPT (FAILED)\n",
			"A previous attempt at this task FAILED. Learn from its mistakes:\n",
		}
		if rc.error and rc.error ~= "" then
			retry_hint_parts[#retry_hint_parts + 1] = "**Error:** " .. rc.error:sub(1, 500) .. "\n"
		end
		if rc.summary and rc.summary ~= "" then
			retry_hint_parts[#retry_hint_parts + 1] = "**What was attempted:** " .. rc.summary:sub(1, 1000) .. "\n"
		end
		if rc.diff_stat and rc.diff_stat ~= "" then
			retry_hint_parts[#retry_hint_parts + 1] = "**Files that were changed (now rolled back):**\n```\n"
				.. rc.diff_stat:sub(1, 2000)
				.. "\n```\n"
		end
		if rc.diff and rc.diff ~= "" then
			retry_hint_parts[#retry_hint_parts + 1] = "**Diff of the failed attempt (for reference — code is rolled back):**\n```diff\n"
				.. rc.diff:sub(1, 8000)
				.. "\n```\n"
		end
		retry_hint_parts[#retry_hint_parts + 1] = [[
**Instructions for retry:**
- The working tree has been rolled back to a clean state.
- You MUST re-implement this task from scratch, but AVOID the same mistakes.
- If the previous attempt hit rate limits or timed out, work more efficiently.
- If the previous attempt had compile/test errors, read the failing code carefully first.
- If the previous diff looks mostly correct, you can re-apply similar changes but fix the broken parts.
]]
		task.description = task.description .. table.concat(retry_hint_parts)
	end

	vim.notify(
		string.format(
			"[dwight] Retrying task %d/%d: %s (with error context from previous attempt)",
			task_num,
			total,
			task.title
		),
		vim.log.levels.INFO
	)

	M._start_execution(state.request, state.tasks, task_num, state.completed or {})
end

--------------------------------------------------------------------
-- Cancel active session
--------------------------------------------------------------------

function M.cancel()
	M._clear_state()
	M._paused = false
	M._pause_callback = nil
	pcall(function()
		require("dwight.agentic").abort()
	end)
	vim.notify("[dwight] DwightAuto session cleared.", vim.log.levels.INFO)
end

--------------------------------------------------------------------
-- Status check
--------------------------------------------------------------------

function M.status()
	local state = M._load_state()
	if not state then
		vim.notify("[dwight] No auto session active.", vim.log.levels.INFO)
		return
	end

	local task_num = state.current_task or 1
	local total = #state.tasks
	local status_str = state.failed and "FAILED" or (state.paused and "PAUSED" or "IN PROGRESS")

	local parts = {
		string.format("[dwight] DwightAuto: %s", status_str),
		string.format("  Request: %s", state.request:sub(1, 60)),
		string.format("  Progress: task %d/%d — %s", task_num, total, state.tasks[task_num].title),
	}

	-- Show completed tasks
	if state.completed and #state.completed > 0 then
		parts[#parts + 1] = string.format("  Completed: %d task(s)", #state.completed)
		for _, s in ipairs(state.completed) do
			local icon = s.had_error and "x" or "✓"
			parts[#parts + 1] = string.format("    %s %d. %s", icon, s.task_num or 0, s.title or "?")
		end
	end

	if state.failed then
		if state.retry_context then
			parts[#parts + 1] =
				"  Use :DwightAutoRetry to retry with error context, :DwightAutoResume to restart clean, :DwightAutoSkip to skip."
		else
			parts[#parts + 1] = "  Use :DwightAutoResume to retry, :DwightAutoSkip to skip."
		end
	elseif state.paused then
		parts[#parts + 1] = "  Use :DwightContinue to resume, :DwightAutoSkip to skip next."
	else
		parts[#parts + 1] = "  Running… Use :DwightPause to pause after current task."
	end

	vim.notify(table.concat(parts, "\n"), vim.log.levels.INFO)
end

return M
