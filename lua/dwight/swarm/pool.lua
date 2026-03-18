-- dwight/swarm/pool.lua
-- Multi-process orchestration: spawn parallel agents, each in its own worktree.
-- Wraps agentic.run with task_id tracking and wave-level completion.

local M = {}

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

	if total == 0 then
		on_all_done({})
		return
	end

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
				completed = completed + 1
				results[#results + 1] = {
					task_id = tid,
					success = success,
					data = data,
					title = t.title,
				}

				if completed >= total then
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
