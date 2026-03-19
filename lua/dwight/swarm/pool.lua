-- dwight/swarm/pool.lua
-- Multi-process orchestration: spawn parallel agents, each in its own worktree.
-- Wraps agentic.run with task_id tracking and wave-level completion.

local M = {}

local uv = vim.loop or vim.uv

--------------------------------------------------------------------
-- Run a batch of tasks in parallel
--------------------------------------------------------------------

--- Spawn agents for all tasks in a wave, each in its own worktree.
--- Calls back when ALL tasks in the batch have completed.
---
--- @param tasks table List of { task_id, description, title, wt_path }
--- @param context string Shared project context
--- @param on_task_status function(task_id, text) Per-task status callback
--- @param on_task_tool function(task_id, text) Per-task tool callback
--- @param on_all_done function(results) Called when all tasks finish
---   results: list of { task_id, success, data, title }
function M.run_batch(tasks, context, on_task_status, on_task_tool, on_all_done)
	local agentic = require("dwight.agentic")
	local total = #tasks
	local completed = 0
	local results = {}
	local done = false

	if total == 0 then
		on_all_done({})
		return
	end

	-- Wave-level timeout: safety net in case individual agent callbacks never fire.
	-- Default: cli_timeout * 1.5 (individual agents already have cli_timeout).
	local wave_timer = nil
	local cfg_ok, cfg = pcall(function()
		return require("dwight").config
	end)
	local ac = (cfg_ok and cfg and cfg.agentic_opts) or {}
	local cli_timeout = ac.cli_timeout or 600
	local wave_timeout_ms = (ac.wave_timeout or math.floor(cli_timeout * 1.5)) * 1000

	wave_timer = uv.new_timer()
	wave_timer:start(wave_timeout_ms, 0, function()
		wave_timer:close()
		wave_timer = nil
		if done then
			return
		end
		done = true
		-- Abort all remaining agents
		pcall(function()
			agentic.abort_all()
		end)
		-- Mark incomplete tasks as timed out
		vim.schedule(function()
			local completed_ids = {}
			for _, r in ipairs(results) do
				completed_ids[r.task_id] = true
			end
			for _, t in ipairs(tasks) do
				if not completed_ids[t.task_id] then
					results[#results + 1] = {
						task_id = t.task_id,
						success = false,
						data = { error = "wave timeout" },
						title = t.title,
						node_id = t.node_id,
					}
				end
			end
			on_all_done(results)
		end)
	end)

	for _, t in ipairs(tasks) do
		local tid = t.task_id

		agentic.run({
			task = t.description,
			context = context,
			cwd = t.wt_path,
			task_id = tid,

			on_status = function(text)
				on_task_status(tid, text)
			end,

			on_tool = function(desc)
				on_task_tool(tid, desc)
			end,

			on_complete = function(success, data)
				if done then
					return
				end
				completed = completed + 1
				results[#results + 1] = {
					task_id = tid,
					success = success,
					data = data,
					title = t.title,
					node_id = t.node_id,
				}

				if completed >= total then
					done = true
					if wave_timer and not wave_timer:is_closing() then
						wave_timer:close()
						wave_timer = nil
					end
					on_all_done(results)
				end
			end,
		})
	end
end

--- Abort all tasks in the registry.
function M.abort_all()
	require("dwight.agentic").abort_all()
end

return M
