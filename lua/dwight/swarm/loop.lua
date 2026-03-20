-- dwight/swarm/loop.lua
-- Wave execution loop: for each wave, create worktrees, spawn parallel agents,
-- wait for all to finish, merge branches, run verification gates, advance.

local M = {}

--------------------------------------------------------------------
-- Shared helpers
--------------------------------------------------------------------

function M._fmt_dur(secs)
	if secs >= 60 then
		return string.format("%dm%ds", math.floor(secs / 60), secs % 60)
	end
	return string.format("%ds", secs)
end

function M._fmt_cost(c)
	if not c or c <= 0 then
		return ""
	end
	return string.format("~$%.2f", c)
end

-- Local aliases for internal use
local function fmt_dur(secs)
	return M._fmt_dur(secs)
end
local function fmt_cost(c)
	return M._fmt_cost(c)
end

--------------------------------------------------------------------
-- Build project context (shared across all tasks in a wave)
--------------------------------------------------------------------

local function build_context(prev_wave_results, request)
	local parts = {}
	local errors = require("dwight.errors")

	errors.try("swarm.context.manifest", function()
		local ctx = require("dwight.context")
		local manifest = ctx.build_xml()
		if manifest then
			parts[#parts + 1] = manifest:sub(1, 1500)
		end
	end)

	errors.try("swarm.context.features", function()
		local features = require("dwight.features")
		local xml = features.build_project_context()
		if xml and xml ~= "" then
			parts[#parts + 1] = xml
		end
	end)

	errors.try("swarm.context.tree", function()
		local bootstrap = require("dwight.bootstrap")
		local scan = bootstrap.scan()
		if scan.tree and #scan.tree > 0 then
			local lines = {}
			for _, line in ipairs(scan.tree) do
				lines[#lines + 1] = line
				if #lines >= 40 then
					break
				end
			end
			parts[#parts + 1] = "<project_tree>\n" .. table.concat(lines, "\n") .. "\n</project_tree>"
		end
	end)

	-- Inject skills + libs + pragma instructions via integration module
	errors.try("swarm.context.integration", function()
		local integration = require("dwight.integration")
		local full_ctx = integration.build_full_context()
		if full_ctx then
			parts[#parts + 1] = full_ctx
		end
	end)

	-- Inject lessons from past sessions
	errors.try("swarm.context.lessons", function()
		local lessons_mod = require("dwight.agent.lessons")
		local lessons = lessons_mod._find_relevant_lessons(request or "")
		if #lessons > 0 then
			local lesson_parts = { "\n## Lessons from Past Sessions" }
			for _, l in ipairs(lessons) do
				lesson_parts[#lesson_parts + 1] = "- " .. l.text
			end
			parts[#parts + 1] = table.concat(lesson_parts, "\n")
		end
	end)

	-- Inject recent session context (cross-mode bridge)
	errors.try("swarm.context.last_session", function()
		local integration = require("dwight.integration")
		local last_ctx = integration.read_last_session_context()
		if last_ctx then
			parts[#parts + 1] = last_ctx
		end
	end)

	-- Include context from previous waves
	if prev_wave_results and #prev_wave_results > 0 then
		local prev_parts = { "\nPREVIOUS WAVES COMPLETED:" }
		for _, wr in ipairs(prev_wave_results) do
			prev_parts[#prev_parts + 1] = string.format("\nWave %d:", wr.wave_num or 0)
			for _, tr in ipairs(wr.task_results or {}) do
				local icon = tr.success and "+" or "x"
				prev_parts[#prev_parts + 1] = string.format("  %s %s", icon, tr.title or "?")
				if tr.summary and tr.summary ~= "" then
					prev_parts[#prev_parts + 1] = "    " .. tr.summary:sub(1, 200)
				end
			end
		end
		parts[#parts + 1] = table.concat(prev_parts, "\n")
	end

	return table.concat(parts, "\n\n")
end

--------------------------------------------------------------------
-- Execute one wave: worktrees → parallel agents → merge → gates
--------------------------------------------------------------------

--- Execute a single wave.
--- @param wave table { wave = N, tasks = { ... } }
--- @param wave_idx number 1-based wave index
--- @param total_waves number
--- @param request string Original user request
--- @param status table agent_status module
--- @param prev_wave_results table Results from previous waves
--- @param opts table { max_parallel, cleanup_worktrees, on_partial_failure }
--- @param callback function(success, wave_result)
--- @param plan table|nil Optional SwarmPlan for node status tracking
function M._execute_wave(wave, wave_idx, total_waves, request, status, prev_wave_results, opts, callback, plan)
	local worktree = require("dwight.swarm.worktree")
	local pool = require("dwight.swarm.pool")
	local gates = require("dwight.gates")
	local wave_started = os.time()

	-- Abort any stale merge state left by a prior crash
	if worktree.check_merge_state() then
		status.append_hl("  Aborted stale merge state from prior session", "DwightWarn")
	end

	-- Clean up any stale worktrees from prior sessions
	worktree.cleanup_stale()

	status.append("")
	status.header(string.format("Wave %d/%d (%d parallel tasks)", wave_idx, total_waves, #wave.tasks))

	-- Cap parallel tasks
	local max_p = opts.max_parallel or 3
	local tasks_to_run = wave.tasks
	if #tasks_to_run > max_p then
		-- Split excess into next wave (handled by caller if needed)
		-- For now, just cap with a warning
		status.append_hl(string.format("  Capping to %d parallel tasks (from %d)", max_p, #tasks_to_run), "DwightWarn")
		tasks_to_run = {}
		for i = 1, max_p do
			tasks_to_run[i] = wave.tasks[i]
		end
	end

	-- Step 1: Create worktrees
	local batch = {}
	local worktree_paths = {}
	for i, task in ipairs(tasks_to_run) do
		local wt_path, err = worktree.create(wave_idx, i)
		if not wt_path then
			status.append_hl(string.format("  Failed to create worktree for task %d: %s", i, err or "?"), "DwightFail")
			-- Skip this task
		else
			worktree_paths[#worktree_paths + 1] = wt_path
			local task_id = string.format("swarm-w%d-t%d", wave_idx, i)
			local files = task.files or {}

			-- Build description with optional file scope hint
			local desc = string.format(
				'%s\n\nThis is task %d in wave %d/%d of a parallel swarm for: "%s".\n'
					.. "Focus ONLY on this task. Other tasks in this wave are running simultaneously on different files.",
				task.description,
				task.order,
				wave_idx,
				total_waves,
				request:sub(1, 100)
			)
			if #files > 0 then
				desc = desc
					.. "\n\nFILE SCOPE: You should primarily create/edit ONLY these files: "
					.. table.concat(files, ", ")
					.. ".\nKeep changes to other files minimal. Other tasks own other files."
			end

			batch[#batch + 1] = {
				task_id = task_id,
				title = task.title,
				description = desc,
				wt_path = wt_path,
				task_idx = i,
				files = files,
				node_id = task.node_id,
			}

			-- Start spinner for this task
			status.spin_multi(task_id, string.format("[W%d/%d] %s", wave_idx, i, task.title:sub(1, 40)))
		end
	end

	if #batch == 0 then
		callback(false, {
			wave_num = wave_idx,
			duration = 0,
			task_results = {},
			error = "No worktrees could be created",
		})
		return
	end

	-- Step 2: Build shared context
	local context = build_context(prev_wave_results, request)

	-- Step 3: Run agents in parallel
	pool.run_batch(
		batch,
		context,
		-- on_task_status
		function(task_id, text)
			if text:match("Tests? FAILED") or text:match("Build failed") then
				status.spin_multi(task_id, task_id:sub(-4) .. " " .. text:sub(1, 60))
			elseif text:match("Tests? passed") or text:match("Build OK") then
				status.spin_multi(task_id, task_id:sub(-4) .. " " .. text:sub(1, 60))
			end
		end,
		-- on_task_tool
		function(task_id, desc)
			status.spin_multi(task_id, task_id:sub(-4) .. " " .. desc:sub(1, 60))
		end,
		-- on_all_done
		function(results)
			local wave_duration = os.time() - wave_started
			status.stop_spin_all()

			-- Step 4: Commit changes in each worktree
			local task_results = {}
			local successes = {}
			local failures = {}

			for _, r in ipairs(results) do
				local b = nil
				for _, bt in ipairs(batch) do
					if bt.task_id == r.task_id then
						b = bt
						break
					end
				end

				local tr = {
					task_id = r.task_id,
					title = r.title,
					success = r.success,
					duration = r.data and r.data.duration or 0,
					summary = r.data and r.data.summary or "",
					error = r.data and r.data.error or nil,
				}
				task_results[#task_results + 1] = tr

				if r.success and b then
					-- Commit in worktree
					worktree.commit(
						b.wt_path,
						string.format("feat(swarm): wave %d — %s", wave_idx, r.title:sub(1, 50))
					)
					successes[#successes + 1] = b
					status.append_hl(string.format("  + %s  %s", r.title, fmt_dur(tr.duration)), "DwightOK")
				else
					failures[#failures + 1] = { batch_entry = b, result = r }
					status.append_hl(
						string.format(
							"  x %s  %s — %s",
							r.title,
							fmt_dur(tr.duration),
							(tr.error or "failed"):sub(1, 80)
						),
						"DwightFail"
					)
				end
			end

			-- Extract lessons from each successful task result
			for _, r in ipairs(results) do
				if r.success and r.data and r.data.journal then
					pcall(function()
						local lessons_mod = require("dwight.agent.lessons")
						lessons_mod._extract_lessons(
							{
								request = r.title,
								had_error = false,
								timestamp = os.time(),
							},
							r.data.journal,
							function(lessons_out)
								if lessons_out and #lessons_out > 0 then
									lessons_mod._append_lessons(lessons_out)
								end
							end
						)
					end)
				end
			end

			-- Update plan node statuses
			if plan then
				local by_id = {}
				for _, node in ipairs(plan.nodes) do
					by_id[node.id] = node
				end
				for _, r in ipairs(results) do
					local nid = r.node_id
					if nid and by_id[nid] then
						by_id[nid].status = r.success and "done" or "failed"
					end
				end
			end

			-- Step 5: Overlap detection + smart merge ordering
			local pre_merge_sha = worktree.head_sha()

			local overlap_tasks = {}
			for _, s in ipairs(successes) do
				overlap_tasks[#overlap_tasks + 1] = { task_idx = s.task_idx, wt_path = s.wt_path }
			end
			local overlaps, file_map = worktree.detect_overlaps(overlap_tasks, pre_merge_sha)

			if #overlaps > 0 then
				local warn_lines = {}
				for _, o in ipairs(overlaps) do
					local idx_strs = {}
					for _, idx in ipairs(o.task_indices) do
						idx_strs[#idx_strs + 1] = tostring(idx)
					end
					warn_lines[#warn_lines + 1] =
						string.format("  %s  (tasks %s)", o.file, table.concat(idx_strs, ", "))
				end
				status.append_hl(string.format("  File overlaps detected (%d files):", #overlaps), "DwightWarn")
				for _, wl in ipairs(warn_lines) do
					status.append_hl(wl, "DwightWarn")
				end

				-- Reorder successes for merge (fewest overlaps first)
				successes = worktree.order_for_merge(successes, overlaps)
			end

			-- Always attempt auto-resolve on conflict (unless explicitly disabled)
			local auto_resolve = opts.auto_resolve ~= false

			-- Step 6: Async merge loop
			local function merge_next(idx)
				if idx > #successes then
					-- All merged successfully — cleanup and proceed to gates

					-- Cleanup worktrees
					if opts.cleanup_worktrees ~= false then
						for _, wt_path in ipairs(worktree_paths) do
							worktree.remove(wt_path)
						end
					end

					-- Handle partial failure (some tasks failed)
					if #failures > 0 and opts.on_partial_failure ~= "continue" then
						callback(false, {
							wave_num = wave_idx,
							duration = wave_duration,
							task_results = task_results,
							error = string.format("%d/%d tasks failed", #failures, #results),
							failed_tasks = failures,
						})
						return
					end

					-- Step 7: Run verification gates
					gates.run_all(status, function(gate_passed, gate_output)
						if gate_passed then
							pcall(function()
								local git = require("dwight.auto.git")
								git._git_checkpoint(wave_idx, total_waves, "wave " .. wave_idx .. " merged", status)
							end)

							-- Pragma sync + feature rebuild after successful merge
							pcall(function()
								local integration = require("dwight.integration")
								local feature_name = integration.detect_feature_name(request)
								local sync = integration.pragma_sync(feature_name)
								if #sync.added > 0 then
									status.append_hl(
										string.format("  Pragma sync: tagged %d new file(s)", #sync.added),
										"DwightOK"
									)
								end
								integration.rebuild_features()
							end)

							status.append_hl(
								string.format(
									"  Wave %d: %d/%d tasks, %s",
									wave_idx,
									#successes,
									#results,
									fmt_dur(wave_duration)
								),
								"DwightOK"
							)

							callback(true, {
								wave_num = wave_idx,
								duration = wave_duration,
								task_results = task_results,
								failed_tasks = #failures > 0 and failures or nil,
							})
						else
							if pre_merge_sha then
								worktree.rollback(pre_merge_sha)
								status.append_hl("  Rolled back wave " .. wave_idx .. " (gates failed)", "DwightWarn")
							end

							callback(false, {
								wave_num = wave_idx,
								duration = wave_duration,
								task_results = task_results,
								error = "verification gates failed after merge",
								gate_output = gate_output,
								pre_merge_sha = pre_merge_sha,
							})
						end
					end)
					return
				end

				local s = successes[idx]
				worktree.merge_async(
					s.wt_path,
					wave_idx,
					s.task_idx,
					{ auto_resolve = auto_resolve },
					function(ok, err, conflict_files)
						if ok then
							merge_next(idx + 1)
						else
							-- Build rich diagnostic if we have conflict info
							if conflict_files and #conflict_files > 0 then
								local diag_lines =
									worktree.build_conflict_diagnostic(conflict_files, file_map, successes)
								status.append_hl(
									string.format("  Merge failed for task %d: %s", s.task_idx, err or "?"),
									"DwightFail"
								)
								status.append_fold("  Conflict details", diag_lines)
							else
								status.append_hl(
									string.format("  Merge failed for task %d: %s", s.task_idx, err or "?"),
									"DwightFail"
								)
							end

							-- Rollback to pre-merge state
							if pre_merge_sha then
								worktree.rollback(pre_merge_sha)
							end

							-- Cleanup worktrees
							if opts.cleanup_worktrees ~= false then
								for _, wt_path in ipairs(worktree_paths) do
									worktree.remove(wt_path)
								end
							end

							callback(false, {
								wave_num = wave_idx,
								duration = wave_duration,
								task_results = task_results,
								error = "merge conflict: " .. (err or "?"),
								pre_merge_sha = pre_merge_sha,
								conflict_files = conflict_files,
							})
						end
					end
				)
			end

			merge_next(1)
		end
	)
end

--------------------------------------------------------------------
-- Main loop: iterate through waves
--------------------------------------------------------------------

--- Run the wave execution loop.
--- @param waves table List of { wave = N, tasks = {...} }
--- @param start_from number Wave index to start from (1-based)
--- @param request string Original user request
--- @param master_started number os.time() when the swarm started
--- @param status table agent_status module
--- @param prev_wave_results table Results from previous waves (for resume)
--- @param plan table|nil Optional SwarmPlan for node status tracking
function M.run(waves, start_from, request, master_started, status, prev_wave_results, plan)
	local state_mod = require("dwight.swarm.state")
	local notify = require("dwight.auto.notify")
	local swarm = require("dwight.swarm")

	local cfg = require("dwight").config
	local sopts = cfg.swarm_opts or {}

	local total_waves = #waves
	prev_wave_results = prev_wave_results or {}

	-- Truncate scratchpad for fresh sessions
	if start_from == 1 and #prev_wave_results == 0 then
		pcall(function()
			local project = require("dwight.project")
			if project.is_initialized() then
				local f = io.open(project.dir() .. "/scratchpad.jsonl", "w")
				if f then
					f:close()
				end
			end
		end)
	end

	local function run_next_wave(idx)
		if idx > total_waves then
			-- ALL WAVES DONE
			local total_duration = os.time() - master_started
			local total_cost = status.session_cost and status.session_cost() or 0

			status.append("")
			status.append(string.rep("=", 40))
			status.append_hl(
				string.format(" All %d waves complete in %s", total_waves, fmt_dur(total_duration)),
				"DwightOK"
			)
			if total_cost > 0 then
				status.append_hl(string.format(" Total cost: %s", fmt_cost(total_cost)), "DwightCost")
			end
			status.append("")

			-- Per-wave summary
			for _, wr in ipairs(prev_wave_results) do
				local ok_count = 0
				for _, tr in ipairs(wr.task_results or {}) do
					if tr.success then
						ok_count = ok_count + 1
					end
				end
				status.append(
					string.format(
						"  Wave %d: %d/%d tasks  %s",
						wr.wave_num,
						ok_count,
						#(wr.task_results or {}),
						fmt_dur(wr.duration or 0)
					)
				)
			end
			status.append("")

			status.end_session(true, total_duration)

			-- Post-session diff
			pcall(function()
				local agent = require("dwight.agent")
				agent._show_post_diff(status)
			end)

			-- Post-session integration (feature warnings, squash hint, PR hint)
			pcall(function()
				local integration = require("dwight.integration")
				local sessions = {}
				for _, wr in ipairs(prev_wave_results) do
					for _, tr in ipairs(wr.task_results or {}) do
						sessions[#sessions + 1] = {
							summary = tr.summary or tr.title,
							files_created = {},
							files_edited = {},
						}
					end
				end
				integration.post_session(request, sessions, status)
			end)

			-- Write last session summary (cross-mode context bridge)
			pcall(function()
				local integration = require("dwight.integration")
				integration.write_last_session({
					mode = "swarm",
					request = request,
					success = true,
					duration = total_duration,
					cost = total_cost,
				})
			end)

			-- Write session log
			state_mod.write_log({
				success = true,
				request = request,
				duration = total_duration,
				total_waves = total_waves,
				cost = total_cost,
				wave_results = prev_wave_results,
			})

			state_mod.clear()
			swarm._paused = false

			notify._notify_done(request, total_duration, total_cost)
			vim.notify(
				string.format(
					"[dwight] DwightSwarm: all %d waves complete in %s!",
					total_waves,
					fmt_dur(total_duration)
				),
				vim.log.levels.INFO
			)
			return
		end

		local wave = waves[idx]

		-- Budget check before starting next wave
		local budget_ok, budget = pcall(function()
			return require("dwight.tracker").check_all_budgets()
		end)
		if budget_ok and budget.exceeded then
			local total_duration = os.time() - master_started
			local total_cost = status.session_cost and status.session_cost() or 0

			status.append("")
			for _, msg in ipairs(budget.messages) do
				status.append_hl("  " .. msg, "DwightFail")
			end
			status.end_session(false, total_duration)

			state_mod.save({
				request = request,
				waves = waves,
				current_wave = idx,
				started = master_started,
				wave_results = prev_wave_results,
				failed = true,
				error = "Budget exceeded",
				plan = plan,
			})

			state_mod.write_log({
				success = false,
				request = request,
				duration = total_duration,
				total_waves = total_waves,
				cost = total_cost,
				wave_results = prev_wave_results,
				failed_wave = idx,
				failed_error = "Budget exceeded",
			})

			notify._notify_failure(idx, total_waves, "wave " .. idx, "Budget exceeded")
			vim.notify(
				string.format("[dwight] DwightSwarm: budget exceeded, stopping before wave %d", idx),
				vim.log.levels.ERROR
			)
			return
		elseif budget_ok and budget.warning then
			for _, msg in ipairs(budget.messages) do
				status.append_hl("  " .. msg, "DwightWarn")
			end
		end

		-- Save state for resume
		state_mod.save({
			request = request,
			waves = waves,
			current_wave = idx,
			started = master_started,
			wave_results = prev_wave_results,
			plan = plan,
		})

		-- Check if paused
		if swarm._paused then
			status.append("")
			status.append(string.format("PAUSED before wave %d/%d. Use :DwightSwarmResume.", idx, total_waves))
			state_mod.save({
				request = request,
				waves = waves,
				current_wave = idx,
				started = master_started,
				wave_results = prev_wave_results,
				paused = true,
				plan = plan,
			})
			return
		end

		M._execute_wave(
			wave,
			idx,
			total_waves,
			request,
			status,
			prev_wave_results,
			sopts,
			function(success, wave_result)
				-- Include plan in wave_result for downstream use
				if plan then
					wave_result.plan = plan
				end
				prev_wave_results[#prev_wave_results + 1] = wave_result

				if success then
					run_next_wave(idx + 1)
				else
					-- Wave failed
					local total_duration = os.time() - master_started
					local total_cost = status.session_cost and status.session_cost() or 0

					status.append("")
					status.append_hl(
						string.format("Wave %d FAILED: %s", idx, (wave_result.error or "?"):sub(1, 200)),
						"DwightFail"
					)
					status.append("Use :DwightSwarmResume to retry from wave " .. idx)
					status.end_session(false, total_duration)

					state_mod.save({
						request = request,
						waves = waves,
						current_wave = idx,
						started = master_started,
						wave_results = prev_wave_results,
						failed = true,
						error = wave_result.error,
						plan = plan,
					})

					state_mod.write_log({
						success = false,
						request = request,
						duration = total_duration,
						total_waves = total_waves,
						cost = total_cost,
						wave_results = prev_wave_results,
						failed_wave = idx,
						failed_error = wave_result.error,
					})

					notify._notify_failure(idx, total_waves, "wave " .. idx, wave_result.error or "failed")

					vim.notify(
						string.format(
							"[dwight] DwightSwarm: wave %d/%d failed. :DwightSwarmResume to retry.",
							idx,
							total_waves
						),
						vim.log.levels.ERROR
					)
				end
			end,
			plan
		)
	end

	run_next_wave(start_from)
end

return M
