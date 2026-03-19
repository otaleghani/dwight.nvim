-- dwight/auto/loop.lua
-- Autonomous execution loop: build context, execute tasks, run verification

local M = {}

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

--------------------------------------------------------------------
-- Shared recap renderer
--------------------------------------------------------------------

local function fmt_tok(n)
	if n >= 1000000 then
		return string.format("%.1fM", n / 1000000)
	end
	if n >= 1000 then
		return string.format("%.1fk", n / 1000)
	end
	return tostring(n)
end

--- Render the final recap block.
--- @param opts table { status, total_duration, total_cost, tokens, completed_sessions, tasks, failed_idx }
local function render_recap(status, opts)
	local completed = opts.completed_sessions or {}
	local all_tasks = opts.tasks or {}
	local total = #all_tasks
	local total_duration = opts.total_duration or 0
	local total_cost = opts.total_cost or 0
	local tokens = opts.tokens or { input = 0, output = 0, total = 0 }
	local failed_idx = opts.failed_idx -- nil if all succeeded
	local completed_count = opts.completed_count or #completed

	status.append(string.rep("═", 40))
	status.append("")

	-- Header line
	if failed_idx then
		status.append_hl(
			string.format(" %d/%d tasks completed in %ds", completed_count, total, total_duration),
			"DwightFail"
		)
	else
		status.append_hl(string.format(" %d/%d tasks completed in %ds", total, total, total_duration), "DwightOK")
	end

	-- Cost in header if available
	if total_cost > 0 then
		status.append_hl(string.format(" Total cost: ~$%.2f", total_cost), "DwightCost")
	end
	status.append("")

	-- Build a lookup of completed sessions by task_num
	local session_by_num = {}
	for _, s in ipairs(completed) do
		session_by_num[s.task_num] = s
	end

	-- Render each task (completed, failed, or skipped)
	for i, task in ipairs(all_tasks) do
		local s = session_by_num[i]
		local task_cost = s and (s.cost or 0) or 0
		local cost_str = task_cost > 0 and string.format("  $%.2f", task_cost) or ""
		local dur = s and (s.duration or 0) or 0
		local title = task.title or "?"

		if s and not s.had_error then
			status.append_hl(string.format("  ● Task %d: %s  %ds%s", i, title, dur, cost_str), "DwightOK")
		elseif s and s.had_error then
			status.append_hl(string.format("  ✗ Task %d: %s  %ds%s", i, title, dur, cost_str), "DwightFail")
			local err = (s.journal and s.journal[#s.journal]) or ""
			if s.summary and s.summary ~= "" then
				err = s.summary
			end
			if opts.failed_error and i == failed_idx then
				err = opts.failed_error
			end
			if err ~= "" then
				status.append_hl(string.format("    └ %s", err:sub(1, 120)), "DwightFail")
			end
		else
			status.append_hl(string.format("  ○ Task %d: %s", i, title), "DwightSkip")
		end
	end

	status.append("")
	status.append("  " .. string.rep("─", 37))

	-- Token summary
	local summary_parts = {}
	if total_cost > 0 then
		summary_parts[#summary_parts + 1] = string.format("~$%.2f", total_cost)
	end
	if tokens.total > 0 then
		summary_parts[#summary_parts + 1] = fmt_tok(tokens.input) .. " in / " .. fmt_tok(tokens.output) .. " out"
	end
	if #summary_parts > 0 then
		status.append("  " .. table.concat(summary_parts, " | "))
	end
	status.append("")
end

--------------------------------------------------------------------
-- Task execution
--------------------------------------------------------------------

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

	-- Tool call counters for compact display
	local tool_counts = { reads = 0, writes = 0, edits = 0, cmds = 0, searches = 0, other = 0 }
	local tool_log = {} -- detailed tool descriptions for foldable section

	-- Classify a tool description into a counter key
	local function classify_tool(desc)
		if desc:match("^Read ") then
			return "reads"
		elseif desc:match("^Write ") then
			return "writes"
		elseif desc:match("^Edit ") then
			return "edits"
		elseif desc:match("^%$ ") or desc:match("^Tool: Bash") then
			return "cmds"
		elseif desc:match("^Search ") or desc:match("^List ") then
			return "searches"
		else
			return "other"
		end
	end

	-- Format tool counters into a compact string like "8r 3w 2e 1cmd"
	local function fmt_tools()
		local parts = {}
		if tool_counts.reads > 0 then
			parts[#parts + 1] = tool_counts.reads .. "r"
		end
		if tool_counts.writes > 0 then
			parts[#parts + 1] = tool_counts.writes .. "w"
		end
		if tool_counts.edits > 0 then
			parts[#parts + 1] = tool_counts.edits .. "e"
		end
		if tool_counts.cmds > 0 then
			parts[#parts + 1] = tool_counts.cmds .. "cmd"
		end
		if tool_counts.searches > 0 then
			parts[#parts + 1] = tool_counts.searches .. "s"
		end
		if tool_counts.other > 0 then
			parts[#parts + 1] = tool_counts.other .. "?"
		end
		if #parts == 0 then
			return ""
		end
		return " [" .. table.concat(parts, " ") .. "]"
	end

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
			-- Only surface structured events (test results, errors) in the buffer.
			-- Everything else goes to session_log only.
			if text:match("Tests? FAILED") or text:match("Build failed") then
				status.stop_spin()
				status.append_hl(string.format("  [%d/%d] %s", task_num, total_tasks, text:sub(1, 200)), "DwightFail")
				status.spin(
					string.format("[%d/%d] working...%s  %ds", task_num, total_tasks, fmt_tools(), os.time() - started)
				)
			elseif text:match("Tests? passed") or text:match("Build OK") then
				status.stop_spin()
				status.append_hl(string.format("  [%d/%d] %s", task_num, total_tasks, text:sub(1, 200)), "DwightOK")
				status.spin(
					string.format("[%d/%d] working...%s  %ds", task_num, total_tasks, fmt_tools(), os.time() - started)
				)
			end
			-- Always log to session_log for full history
			pcall(function()
				if #text > 5 then
					require("dwight.session_log").append(
						string.format("[%d/%d] %s", task_num, total_tasks, text:sub(1, 500))
					)
				end
			end)
		end,

		on_tool = function(desc)
			-- Increment counter and update spinner in-place
			local key = classify_tool(desc)
			tool_counts[key] = tool_counts[key] + 1
			tool_log[#tool_log + 1] = desc:sub(1, 120)
			status.spin(
				string.format("[%d/%d] working...%s  %ds", task_num, total_tasks, fmt_tools(), os.time() - started)
			)
			-- Log detail to session_log
			pcall(function()
				require("dwight.session_log").append(string.format("  [%d/%d] %s", task_num, total_tasks, desc))
			end)
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
				-- Store tool log for foldable details
				tool_log = tool_log,
				tool_counts = tool_counts,
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
						end
					end
				)
			end)

			-- Compact completion line
			local task_cost = session_data.cost or 0
			local cost_str = task_cost > 0 and string.format("  ~$%.2f", task_cost) or ""
			local tools_str = fmt_tools()

			if success then
				status.append_hl(
					string.format("  ● %s  %ds%s%s", task.title, duration, cost_str, tools_str),
					"DwightOK"
				)
			else
				status.append_hl(
					string.format("  ✗ %s  %ds%s%s", task.title, duration, cost_str, tools_str),
					"DwightFail"
				)
				if data.error and data.error ~= "" then
					status.append_hl(string.format("    └ %s", data.error:sub(1, 200)), "DwightFail")
				end
			end

			-- Foldable detail section
			if #tool_log > 0 then
				local total_tools = 0
				for _, v in pairs(tool_counts) do
					total_tools = total_tools + v
				end
				status.append_fold(string.format("  ▸ Details (%d tool calls)", total_tools), tool_log)
			end

			callback(success, session_data)
		end,
	})
end

--- Run the autonomous loop: execute tasks sequentially.
function M._run_loop(tasks, start_from, master_request, master_started, status, prev_sessions)
	local git = require("dwight.auto.git")
	local state = require("dwight.auto.state")
	local notify = require("dwight.auto.notify")
	local auto = require("dwight.auto")

	local uv = vim.loop or vim.uv

	local total = #tasks
	-- Seed with previous sessions (from resume or earlier in this run)
	local completed_sessions = {}
	if prev_sessions then
		for _, s in ipairs(prev_sessions) do
			completed_sessions[#completed_sessions + 1] = s
		end
	end
	local total_cost = 0

	-- Collect baseline info into summary + detail lines, then render as one fold
	local baseline_lines = {}
	local baseline_summary = {}

	-- Create initial git checkpoint before any tasks run
	if git.is_git_repo() then
		local diff_out, _ = git.git_sync({ "status", "--porcelain" }, 3000)
		if diff_out and vim.trim(diff_out) ~= "" then
			git.git_sync({ "add", "-A" }, 5000)
			git.git_sync({ "commit", "-m", "chore: pre-session checkpoint", "--no-verify" }, 10000)
			baseline_lines[#baseline_lines + 1] = "Initial git checkpoint saved"
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
	local baseline_failures = {}
	pcall(function()
		local agentic = require("dwight.agentic")
		local test_cmd = agentic.get_test_command()
		if not test_cmd then
			return
		end

		local output = vim.fn.system(test_cmd .. " 2>&1")
		local code = vim.v.shell_error

		if code ~= 0 then
			local gates = require("dwight.gates")
			local detected_lang = nil
			pcall(function()
				detected_lang = agentic.detect_language()
			end)
			for _, test_name in ipairs(gates.parse_test_failures(output, detected_lang)) do
				baseline_failures[test_name] = true
			end
			local count = 0
			for _ in pairs(baseline_failures) do
				count = count + 1
			end
			if count > 0 then
				baseline_summary[#baseline_summary + 1] = string.format("tests: %d pre-existing", count)
				baseline_lines[#baseline_lines + 1] =
					string.format("%d pre-existing test failure(s) (will be ignored in gates)", count)
				for name, _ in pairs(baseline_failures) do
					baseline_lines[#baseline_lines + 1] = "  - " .. name
				end
			else
				baseline_summary[#baseline_summary + 1] = "tests: compile error?"
				baseline_lines[#baseline_lines + 1] =
					"Baseline tests failed (couldn't parse test names — may be compile error)"
				local n = 0
				for line in output:gmatch("[^\n]+") do
					baseline_lines[#baseline_lines + 1] = "  " .. line
					n = n + 1
					if n >= 5 then
						break
					end
				end
			end
		else
			baseline_summary[#baseline_summary + 1] = "tests pass"
			baseline_lines[#baseline_lines + 1] = "Baseline tests pass"
		end
	end)

	-- Capture baseline coverage BEFORE any tasks run.
	local baseline_coverage = nil
	pcall(function()
		local agentic = require("dwight.agentic")
		local cov_info = agentic.get_coverage_command()
		if not cov_info then
			return
		end

		local output = vim.fn.system(cov_info.cmd .. " 2>&1")
		local pct = cov_info.parse_total(output)
		if pct then
			baseline_coverage = pct
			baseline_summary[#baseline_summary + 1] = string.format("%.1f%% cov", pct)
			baseline_lines[#baseline_lines + 1] = string.format("Baseline coverage: %.1f%%", pct)
		else
			baseline_lines[#baseline_lines + 1] = "Couldn't parse baseline coverage — delta gate will be skipped"
		end
	end)

	-- Check lint baseline
	pcall(function()
		local agentic = require("dwight.agentic")
		local lint_cmd, lint_bin = agentic.get_lint_command()
		if lint_cmd then
			baseline_summary[#baseline_summary + 1] = "lint: " .. (lint_bin or "yes")
			baseline_lines[#baseline_lines + 1] = string.format("Linter: %s", lint_bin or lint_cmd)
		end
		local smoke = agentic.get_smoke_command()
		if smoke then
			baseline_lines[#baseline_lines + 1] = "Smoke test available"
		end
	end)

	-- Render baseline as a single fold
	if #baseline_lines > 0 then
		local header = "Baseline"
		if #baseline_summary > 0 then
			header = header .. " (" .. table.concat(baseline_summary, ", ") .. ")"
		end
		status.append_fold("  " .. header, baseline_lines)
	end

	local function run_next(idx)
		if idx > total then
			-- ALL DONE
			local total_duration = os.time() - master_started
			total_cost = status.session_cost and status.session_cost() or 0

			status.stop_spin()
			local tokens = status.session_tokens and status.session_tokens() or { input = 0, output = 0, total = 0 }

			render_recap(status, {
				completed_sessions = completed_sessions,
				tasks = tasks,
				total_duration = total_duration,
				total_cost = total_cost,
				tokens = tokens,
				completed_count = total,
			})

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
			state._write_session_log({
				success = true,
				request = master_request,
				duration = total_duration,
				backend = cfg_ok and cfg.backend or "?",
				cost = total_cost,
				total_tasks = total,
				completed_count = total,
				sessions = completed_sessions,
			})

			state._clear_state()
			auto._paused = false
			auto._pause_callback = nil
			notify._notify_done(master_request, total_duration, total_cost)

			vim.notify(
				string.format("[dwight] DwightAuto: all %d tasks complete in %ds!", total, total_duration),
				vim.log.levels.INFO
			)
			return
		end

		local task = tasks[idx]

		-- Budget check before starting next task
		local budget_ok, budget = pcall(function()
			return require("dwight.tracker").check_all_budgets()
		end)
		if budget_ok and budget.exceeded then
			status.stop_spin()
			for _, msg in ipairs(budget.messages) do
				status.append_hl("  " .. msg, "DwightFail")
			end

			local total_duration = os.time() - master_started
			total_cost = status.session_cost and status.session_cost() or 0
			local tokens = status.session_tokens and status.session_tokens() or { input = 0, output = 0, total = 0 }

			render_recap(status, {
				completed_sessions = completed_sessions,
				tasks = tasks,
				total_duration = total_duration,
				total_cost = total_cost,
				tokens = tokens,
				failed_idx = idx,
				failed_error = "Budget exceeded",
				completed_count = idx - 1,
			})

			status.end_session(false, total_duration)

			state._save_state({
				request = master_request,
				tasks = tasks,
				current_task = idx,
				started = master_started,
				completed = completed_sessions,
				failed = true,
				error = "Budget exceeded",
			})

			vim.notify(
				string.format("[dwight] DwightAuto: budget exceeded, stopping before task %d", idx),
				vim.log.levels.ERROR
			)
			return
		elseif budget_ok and budget.warning then
			for _, msg in ipairs(budget.messages) do
				status.append_hl("  " .. msg, "DwightWarn")
			end
		end

		-- Save state for resume
		state._save_state({
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
				-- Kill any running agentic process and wait for it to actually die
				-- before git rollback. Polling _active_handle avoids the race
				-- condition of a fixed delay.
				local agentic = require("dwight.agentic")
				agentic.abort()

				-- Capture the diff BEFORE rolling back (for retry-in-place)
				local failure_diff = ""
				local failure_diff_stat = ""
				pcall(function()
					if git.is_git_repo() then
						failure_diff_stat = vim.fn.system("git diff --stat HEAD 2>/dev/null") or ""
						failure_diff = vim.fn.system("git diff HEAD 2>/dev/null") or ""
						-- Cap at reasonable size
						if #failure_diff > 15000 then
							failure_diff = failure_diff:sub(1, 15000) .. "\n... (truncated)"
						end
					end
				end)
				vim.wait(5000, function()
					return agentic._active_handle == nil
				end, 100)
				vim.schedule(function()
					-- Rollback to last checkpoint
					git._git_rollback(status)

					state._save_state({
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

					notify._notify_failure(idx, total, task.title, err_msg)

					local total_duration = os.time() - master_started
					total_cost = status.session_cost and status.session_cost() or 0

					local tokens = status.session_tokens and status.session_tokens()
						or { input = 0, output = 0, total = 0 }

					render_recap(status, {
						completed_sessions = completed_sessions,
						tasks = tasks,
						total_duration = total_duration,
						total_cost = total_cost,
						tokens = tokens,
						failed_idx = idx,
						failed_error = err_msg,
						completed_count = idx - 1,
					})

					status.stop_spin()
					status.end_session(false, total_duration)

					-- Write session summary log
					local cfg_ok2, cfg2 = pcall(function()
						return require("dwight").config
					end)
					state._write_session_log({
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
			end -- handle_failure

			if success then
				notify._notify_progress(idx, total, task.title)

				-- Git checkpoint
				git._git_checkpoint(idx, total, task.title, status)

				-- Verification pipeline: lint → tests → coverage → smoke
				-- Pass baseline_failures and baseline_coverage for delta checks
				auto._verification_gate(status, function(gate_passed, gate_output)
					if gate_passed then
						-- Compact diff summary (file count only)
						pcall(function()
							if git.is_git_repo() then
								local diff_out = vim.fn.system("git diff --stat HEAD~1..HEAD 2>/dev/null")
								if diff_out and vim.trim(diff_out) ~= "" then
									-- Extract last line: " N files changed, N insertions(+), N deletions(-)"
									local last_line
									for line in diff_out:gmatch("[^\n]+") do
										last_line = line
									end
									if last_line then
										status.append_hl("    " .. vim.trim(last_line), "DwightDim")
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
								status.append_hl(
									string.format(
										"    pragma: @feature:%s +%d file(s)",
										feature_name or "?",
										#sync.added
									),
									"DwightDim"
								)
								-- Stage the pragma additions so they're included in the checkpoint
								git.git_sync({ "add", "-A" }, 3000)
								git.git_sync({ "commit", "--amend", "--no-edit", "--no-verify" }, 5000)
							end

							-- Rebuild feature index
							integration.rebuild_features()
						end)

						-- Check if paused: stop here and save continuation
						if auto._paused then
							status.append("")
							status.append(
								string.format("PAUSED after task %d/%d. Use :DwightContinue to resume.", idx, total)
							)
							status.append("   Use :DwightContinue [prompt] to override next task's description.")
							status.append("   Use :DwightAutoSkip to skip the next task.")

							state._save_state({
								request = master_request,
								tasks = tasks,
								current_task = idx + 1,
								started = master_started,
								completed = completed_sessions,
								paused = true,
							})

							auto._pause_callback = function(override_prompt)
								auto._paused = false
								auto._pause_callback = nil
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

return M
