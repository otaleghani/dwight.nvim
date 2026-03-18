-- dwight/swarm/init.lua
-- DwightSwarm: parallel multi-agent workflow using git worktrees.
-- Decomposes a request into waves of parallel tasks, runs agents in
-- isolated worktrees, merges results, and runs verification gates.

local M = {}

--------------------------------------------------------------------
-- Shared state
--------------------------------------------------------------------

M._paused = false

--------------------------------------------------------------------
-- Main entry: :DwightSwarm <request>
--------------------------------------------------------------------

function M.swarm(request)
	if not request or vim.trim(request) == "" then
		require("dwight.ui").open_prompt(nil, {
			dispatch = "swarm",
		})
		return
	end

	-- Check project is initialized
	local project = require("dwight.project")
	if not project.is_initialized() then
		vim.notify("[dwight] Run :DwightInit first.", vim.log.levels.WARN)
		return
	end

	-- Check if there's already a swarm session running
	local state = require("dwight.swarm.state")
	local existing = state.load()
	if existing and not existing.failed then
		vim.notify(
			"[dwight] A swarm session is already in progress. Use :DwightSwarmResume or :DwightSwarmCancel.",
			vim.log.levels.WARN
		)
		return
	end

	-- Check git repo
	local git = require("dwight.auto.git")
	if not git.is_git_repo() then
		vim.notify("[dwight] DwightSwarm requires a git repository (worktrees).", vim.log.levels.ERROR)
		return
	end

	-- Show decomposition progress
	local status = require("dwight.agent_status")
	status.open()
	status.start_session("Swarm: " .. request:sub(1, 50))
	status.spin("Decomposing request into parallel waves...")

	vim.notify("[dwight] DwightSwarm: planning DAG decomposition...", vim.log.levels.INFO)

	local planner = require("dwight.swarm.planner")
	planner._plan(request, function(waves, err, plan)
		status.stop_spin()
		if err then
			status.append_hl("Planning failed: " .. err:sub(1, 200), "DwightFail")
			status.end_session(false, 0)
			vim.notify("[dwight] Swarm planning failed: " .. err, vim.log.levels.ERROR)
			return
		end

		-- Summary
		local total_tasks = 0
		for _, w in ipairs(waves) do
			total_tasks = total_tasks + #w.tasks
		end

		status.append_hl(string.format("Planned %d waves, %d tasks total (DAG)", #waves, total_tasks), "DwightOK")
		for i, w in ipairs(waves) do
			status.append_hl(string.format("  Wave %d: %d parallel tasks", i, #w.tasks), "DwightDim")
			for _, t in ipairs(w.tasks) do
				local files_str = ""
				if t.files and #t.files > 0 then
					files_str = " [" .. table.concat(t.files, ", ") .. "]"
				end
				local deps_str = ""
				if t.deps and #t.deps > 0 then
					deps_str = " -> " .. table.concat(t.deps, ", ")
				end
				local id_str = t.node_id or tostring(t.order)
				status.append_hl(string.format("    %s. %s%s%s", id_str, t.title, files_str, deps_str), "DwightDim")
			end
		end

		vim.notify(
			string.format("[dwight] Planned %d waves, %d tasks. Review and <CR> to start.", #waves, total_tasks),
			vim.log.levels.INFO
		)

		-- Show preview, let user review/edit, then start
		local preview = require("dwight.swarm.preview")
		preview.show(request, waves, function(final_waves, final_plan)
			M._start_execution(request, final_waves, 1, nil, final_plan or plan)
		end, plan)
	end)
end

--------------------------------------------------------------------
-- Start execution
--------------------------------------------------------------------

function M._start_execution(request, waves, start_from, prev_wave_results, plan)
	local status = require("dwight.agent_status")
	local master_started = os.time()

	if not status.is_active() then
		status.start_session("Swarm: " .. request:sub(1, 50))
	end

	local total_tasks = 0
	for _, w in ipairs(waves) do
		total_tasks = total_tasks + #w.tasks
	end

	status.append("")
	status.header(string.format("Executing %d waves (%d tasks)", #waves, total_tasks))
	status.append("")

	pcall(function()
		require("dwight.auto.notify")._system_notify(
			"Dwight Swarm Started",
			string.format("%d waves, %d tasks: %s", #waves, total_tasks, request:sub(1, 80))
		)
	end)

	-- Pre-flight: commit dirty state
	pcall(function()
		local git = require("dwight.auto.git")
		if git.is_git_repo() then
			local diff_out, _ = git.git_sync({ "status", "--porcelain" }, 3000)
			if diff_out and vim.trim(diff_out) ~= "" then
				git.git_sync({ "add", "-A" }, 5000)
				git.git_sync({ "commit", "-m", "chore: pre-swarm checkpoint", "--no-verify" }, 10000)
				status.append_hl("  Pre-flight checkpoint saved", "DwightDim")
			end
		end
	end)

	-- Record base SHA for rollback
	local worktree = require("dwight.swarm.worktree")
	local base_sha = worktree.head_sha()
	if base_sha then
		status.append_hl("  Base SHA: " .. base_sha:sub(1, 8), "DwightDim")
	end

	local loop = require("dwight.swarm.loop")
	loop.run(waves, start_from, request, master_started, status, prev_wave_results, plan)
end

--------------------------------------------------------------------
-- Resume from failure
--------------------------------------------------------------------

function M.resume()
	local state_mod = require("dwight.swarm.state")
	local st = state_mod.load()
	if not st then
		vim.notify("[dwight] No swarm session to resume. Run :DwightSwarm first.", vim.log.levels.INFO)
		return
	end

	if not st.failed and not st.paused then
		vim.notify("[dwight] Swarm session is not in a failed/paused state.", vim.log.levels.INFO)
		return
	end

	local wave_idx = st.current_wave or 1
	vim.notify(string.format("[dwight] Resuming DwightSwarm from wave %d/%d", wave_idx, #st.waves), vim.log.levels.INFO)

	M._start_execution(st.request, st.waves, wave_idx, st.wave_results or {}, st.plan)
end

--------------------------------------------------------------------
-- Cancel
--------------------------------------------------------------------

function M.cancel()
	local state_mod = require("dwight.swarm.state")
	state_mod.clear()
	M._paused = false

	-- Abort all running agents
	pcall(function()
		require("dwight.agentic").abort_all()
	end)

	-- Cleanup worktrees
	pcall(function()
		require("dwight.swarm.worktree").cleanup_all()
	end)

	vim.notify("[dwight] DwightSwarm session cancelled and worktrees cleaned up.", vim.log.levels.INFO)
end

--------------------------------------------------------------------
-- Pause
--------------------------------------------------------------------

function M.pause()
	if M._paused then
		vim.notify("[dwight] Already paused. Use :DwightSwarmResume.", vim.log.levels.INFO)
		return
	end
	M._paused = true
	vim.notify("[dwight] DwightSwarm will pause after the current wave completes.", vim.log.levels.INFO)
end

--------------------------------------------------------------------
-- Status
--------------------------------------------------------------------

function M.status()
	local state_mod = require("dwight.swarm.state")
	local st = state_mod.load()
	if not st then
		vim.notify("[dwight] No swarm session active.", vim.log.levels.INFO)
		return
	end

	local wave_idx = st.current_wave or 1
	local total_waves = #st.waves
	local status_str = st.failed and "FAILED" or (st.paused and "PAUSED" or "IN PROGRESS")

	local total_tasks = 0
	for _, w in ipairs(st.waves) do
		total_tasks = total_tasks + #w.tasks
	end

	local parts = {
		string.format("[dwight] DwightSwarm: %s", status_str),
		string.format("  Request: %s", st.request:sub(1, 60)),
		string.format("  Progress: wave %d/%d (%d total tasks)", wave_idx, total_waves, total_tasks),
	}

	if st.wave_results and #st.wave_results > 0 then
		parts[#parts + 1] = string.format("  Completed waves: %d", #st.wave_results)
	end

	if st.failed then
		parts[#parts + 1] = "  Error: " .. (st.error or "?"):sub(1, 100)
		parts[#parts + 1] = "  Use :DwightSwarmResume to retry or :DwightSwarmCancel."
	elseif st.paused then
		parts[#parts + 1] = "  Use :DwightSwarmResume to continue."
	end

	vim.notify(table.concat(parts, "\n"), vim.log.levels.INFO)
end

return M
