-- dwight/auto/init.lua
-- DwightAuto: autonomous mode for complex features.
-- Decomposes a big request into sequential sub-tasks, each executed by DwightAgent
-- without manual plan review. System notifications on completion/failure.
--
-- Flow: User request → LLM decomposition → sub-task 1 plan+execute → sub-task 2 → ... → done.
-- On failure: stop, save state, system notify. User can :DwightAutoResume.

local M = {}

--------------------------------------------------------------------
-- Shared mutable state (read by loop.lua via require("dwight.auto"))
--------------------------------------------------------------------

--- Pause flag: when true, the loop stops after the current task completes.
--- Set by :DwightPause, cleared by :DwightContinue.
M._paused = false
M._pause_callback = nil -- stored continuation when paused

--------------------------------------------------------------------
-- Inter-task verification pipeline (delegated to gates.lua)
--------------------------------------------------------------------

local gates = require("dwight.gates")

-- Backwards-compatible aliases for callers and tests
M._gate_lint = gates.lint
M._gate_tests = gates.tests
M._gate_coverage = gates.coverage
M._gate_smoke = gates.smoke
M._verification_gate = gates.run_all

--------------------------------------------------------------------
-- Re-exports from sub-modules
--------------------------------------------------------------------

-- notify.lua
function M._system_notify(...)
	return require("dwight.auto.notify")._system_notify(...)
end
function M._notify_progress(...)
	return require("dwight.auto.notify")._notify_progress(...)
end
function M._notify_failure(...)
	return require("dwight.auto.notify")._notify_failure(...)
end
function M._notify_done(...)
	return require("dwight.auto.notify")._notify_done(...)
end

-- git.lua
function M.git_sync(...)
	return require("dwight.auto.git").git_sync(...)
end
function M.is_git_repo(...)
	return require("dwight.auto.git").is_git_repo(...)
end
function M._git_checkpoint(...)
	return require("dwight.auto.git")._git_checkpoint(...)
end
function M._git_rollback(...)
	return require("dwight.auto.git")._git_rollback(...)
end

-- decompose.lua
function M._parse_tasks(...)
	return require("dwight.auto.decompose")._parse_tasks(...)
end
function M._decompose(...)
	return require("dwight.auto.decompose")._decompose(...)
end
-- DECOMPOSE_PROMPT: accessed via __index metatable at bottom of file

-- state.lua
function M.auto_dir(...)
	return require("dwight.auto.state").auto_dir(...)
end
function M._save_state(...)
	return require("dwight.auto.state")._save_state(...)
end
function M._load_state(...)
	return require("dwight.auto.state")._load_state(...)
end
function M._clear_state(...)
	return require("dwight.auto.state")._clear_state(...)
end
function M._write_session_log(...)
	return require("dwight.auto.state")._write_session_log(...)
end

-- loop.lua
function M._build_prev_context(...)
	return require("dwight.auto.loop")._build_prev_context(...)
end
function M._execute_task(...)
	return require("dwight.auto.loop")._execute_task(...)
end
function M._execute_task_agentic(...)
	return require("dwight.auto.loop")._execute_task_agentic(...)
end
function M._run_loop(...)
	return require("dwight.auto.loop")._run_loop(...)
end

-- preview.lua
function M._show_decomposition(...)
	return require("dwight.auto.preview")._show_decomposition(...)
end
function M._parse_buffer_tasks(...)
	return require("dwight.auto.preview")._parse_buffer_tasks(...)
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

	-- Show decomposition progress in the status buffer
	local status = require("dwight.agent_status")
	status.open()
	status.start_session("Auto: " .. request:sub(1, 50))
	status.spin("Decomposing request into sub-tasks...")

	vim.notify("[dwight] DwightAuto: decomposing request into sub-tasks…", vim.log.levels.INFO)

	M._decompose(request, function(tasks, err)
		status.stop_spin()
		if err then
			status.append_hl("Decomposition failed: " .. err:sub(1, 200), "DwightFail")
			status.end_session(false, 0)
			vim.notify("[dwight] Decomposition failed: " .. err, vim.log.levels.ERROR)
			return
		end

		status.append_hl(string.format("Decomposed into %d sub-tasks", #tasks), "DwightOK")
		for i, task in ipairs(tasks) do
			status.append_hl(string.format("  %d. %s", i, task.title), "DwightDim")
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

	-- Reuse existing session if already open (from decomposition spinner),
	-- otherwise start a new one.
	if not status.is_active() then
		status.start_session("Auto: " .. request:sub(1, 50))
	end

	status.append("")
	status.header(string.format("Executing %d tasks", #tasks))
	status.append("")

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
		local git = require("dwight.auto.git")
		if git.is_git_repo() and completed_count > 0 then
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

--------------------------------------------------------------------
-- Metatable: DECOMPOSE_PROMPT passthrough
--------------------------------------------------------------------

setmetatable(M, {
	__index = function(_, key)
		if key == "DECOMPOSE_PROMPT" then
			return require("dwight.auto.decompose").DECOMPOSE_PROMPT
		end
	end,
})

return M
