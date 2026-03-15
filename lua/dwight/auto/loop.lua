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

	-- Create initial git checkpoint before any tasks run
	if git.is_git_repo() then
		local diff_out, _ = git.git_sync({ "status", "--porcelain" }, 3000)
		if diff_out and vim.trim(diff_out) ~= "" then
			git.git_sync({ "add", "-A" }, 5000)
			git.git_sync({ "commit", "-m", "chore: pre-session checkpoint", "--no-verify" }, 10000)
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
			status.append("")
			status.append(string.format("ALL %d TASKS COMPLETE in %ds", total, total_duration))
			status.append("")
			status.append("Usage:")
			local tokens = status.session_tokens and status.session_tokens() or { input = 0, output = 0, total = 0 }
			local fmt_tok = function(n)
				if n >= 1000000 then
					return string.format("%.1fM", n / 1000000)
				end
				if n >= 1000 then
					return string.format("%.1fk", n / 1000)
				end
				return tostring(n)
			end
			for _, s in ipairs(completed_sessions) do
				local task_cost = s.cost or 0
				local cost_str = task_cost > 0 and string.format("$%.2f", task_cost) or "—"
				local icon = s.had_error and "x" or "✓"
				local title = s.title or "?"
				status.append(
					string.format("  %s %-30s %s", icon, "Task " .. (s.task_num or 0) .. ": " .. title, cost_str)
				)
			end
			status.append("")
			status.append("  " .. string.rep("─", 37))
			local summary_parts = {}
			if total_cost > 0 then
				summary_parts[#summary_parts + 1] = string.format("~$%.2f", total_cost)
			end
			if tokens.total > 0 then
				summary_parts[#summary_parts + 1] = fmt_tok(tokens.input)
					.. " in / "
					.. fmt_tok(tokens.output)
					.. " out"
			end
			if #summary_parts > 0 then
				status.append("  Total: " .. table.concat(summary_parts, " | "))
			end
			status.append("")
			status.append(string.rep("═", 40))

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
				-- Kill any running agentic process (prevents zombie Claude Code sessions)
				pcall(function()
					local agentic = require("dwight.agentic")
					agentic.abort()
				end)

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

				-- Wait 3s for Claude Code to fully die before git rollback.
				-- Without this delay, Claude Code child processes may recreate files
				-- that git clean just removed.
				local rollback_timer = uv.new_timer()
				rollback_timer:start(3000, 0, function()
					rollback_timer:close()
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
						status.append(string.rep("═", 40))
						status.append("")
						status.append(string.format("FAILED at task %d/%d in %ds", idx, total, total_duration))
						status.append("")
						status.append("Usage:")
						local fmt_tok = function(n)
							if n >= 1000000 then
								return string.format("%.1fM", n / 1000000)
							end
							if n >= 1000 then
								return string.format("%.1fk", n / 1000)
							end
							return tostring(n)
						end
						for _, s in ipairs(completed_sessions) do
							local task_cost = s.cost or 0
							local cost_str = task_cost > 0 and string.format("$%.2f", task_cost) or "—"
							local icon = s.had_error and "x" or "✓"
							local title = s.title or "?"
							status.append(
								string.format(
									"  %s %-30s %s",
									icon,
									"Task " .. (s.task_num or 0) .. ": " .. title,
									cost_str
								)
							)
						end
						-- Add the failed task entry
						status.append(string.format("  x %-30s FAILED", "Task " .. idx .. ": " .. (task.title or "?")))
						status.append("")
						status.append("  " .. string.rep("─", 37))
						local summary_parts = {}
						if total_cost > 0 then
							summary_parts[#summary_parts + 1] = string.format("~$%.2f", total_cost)
						end
						if tokens.total > 0 then
							summary_parts[#summary_parts + 1] = fmt_tok(tokens.input)
								.. " in / "
								.. fmt_tok(tokens.output)
								.. " out"
						end
						if #summary_parts > 0 then
							status.append("  Total: " .. table.concat(summary_parts, " | "))
						end
						status.append("")
						status.append(string.rep("═", 40))

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
				end) -- rollback_timer
			end -- handle_failure

			if success then
				notify._notify_progress(idx, total, task.title)

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
				git._git_checkpoint(idx, total, task.title, status)

				-- Verification pipeline: lint → tests → coverage → smoke
				-- Pass baseline_failures and baseline_coverage for delta checks
				auto._verification_gate(status, function(gate_passed, gate_output)
					if gate_passed then
						-- Show diff stats for this task's changes
						pcall(function()
							if git.is_git_repo() then
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
