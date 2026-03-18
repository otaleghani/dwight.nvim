-- dwight/swarm/preview.lua
-- Preview buffer for swarm wave decomposition.
-- Shows waves with parallelism info; user can edit before confirming.

local M = {}

local api = vim.api
local _flatten = require("dwight.util").flatten_lines

--------------------------------------------------------------------
-- Show wave preview
--------------------------------------------------------------------

--- Show decomposed waves in a review buffer.
--- <CR> starts execution, q cancels.
function M.show(request, waves, callback, plan)
	local total_tasks = 0
	for _, w in ipairs(waves) do
		total_tasks = total_tasks + #w.tasks
	end

	local safe_request = request:sub(1, 60):gsub("\n", " ")

	local lines = {
		"<!-- ═══════════════════════════════════════════════════════ -->",
		string.format("<!-- DwightSwarm: %s -->", safe_request),
		string.format("<!-- %d waves, %d tasks total (parallel execution) -->", #waves, total_tasks),
		"<!-- -->",
		"<!-- <CR> start swarm execution | q cancel -->",
		"<!-- Edit task descriptions freely before starting -->",
		"<!-- Tasks in the same wave run IN PARALLEL -->",
		"<!-- ═══════════════════════════════════════════════════════ -->",
		"",
	}

	for _, wave in ipairs(waves) do
		lines[#lines + 1] = string.format("# Wave %d  (%d parallel tasks)", wave.wave, #wave.tasks)
		lines[#lines + 1] = ""

		for _, task in ipairs(wave.tasks) do
			local safe_title = (task.title or ""):gsub("\n", " ")
			-- Use node_id if present, otherwise numeric order
			local task_label = task.node_id or tostring(task.order)
			lines[#lines + 1] = string.format("## Task %s: %s", task_label, safe_title)

			-- Show file scope
			if task.files and #task.files > 0 then
				lines[#lines + 1] = string.format("**Files:** %s", table.concat(task.files, ", "))
			end

			-- Show dependencies
			if task.deps and #task.deps > 0 then
				lines[#lines + 1] = string.format("**Deps:** %s", table.concat(task.deps, ", "))
			else
				lines[#lines + 1] = "**Deps:** (none)"
			end

			lines[#lines + 1] = ""

			for desc_line in (task.description or ""):gmatch("[^\n]+") do
				lines[#lines + 1] = desc_line
			end
			lines[#lines + 1] = ""
			lines[#lines + 1] = "---"
			lines[#lines + 1] = ""
		end

		lines[#lines + 1] = ""
	end

	local buf = api.nvim_create_buf(true, false)
	api.nvim_buf_set_lines(buf, 0, -1, false, _flatten(lines))
	vim.bo[buf].filetype = "markdown"
	vim.bo[buf].bufhidden = "wipe"
	pcall(function()
		api.nvim_buf_set_name(buf, "dwight://swarm-plan")
	end)

	vim.cmd("tab split")
	api.nvim_win_set_buf(0, buf)

	-- Keymaps
	vim.keymap.set("n", "<CR>", function()
		local buf_lines = api.nvim_buf_get_lines(buf, 0, -1, false)
		local text = table.concat(buf_lines, "\n")
		local edited_waves = M._parse_buffer_waves(text)

		if #edited_waves == 0 then
			vim.notify("[dwight] No waves found. Keep the # Wave N / ## Task N: Title format.", vim.log.levels.WARN)
			return
		end

		-- If we have a plan, re-derive waves from edited buffer tasks
		local final_plan = nil
		if plan then
			final_plan = M._rebuild_plan(edited_waves, plan)
			if final_plan then
				local planner = require("dwight.swarm.planner")
				edited_waves = planner._to_waves(final_plan)
			end
		end

		pcall(api.nvim_buf_delete, buf, { force = true })
		callback(edited_waves, final_plan)
	end, { buffer = buf, desc = "Start swarm execution" })

	vim.keymap.set("n", "q", function()
		pcall(api.nvim_buf_delete, buf, { force = true })
		vim.notify("[dwight] DwightSwarm cancelled.", vim.log.levels.INFO)
	end, { buffer = buf, desc = "Cancel" })
end

--------------------------------------------------------------------
-- Rebuild plan from edited buffer
--------------------------------------------------------------------

--- Rebuild a SwarmPlan from edited buffer waves.
--- Returns updated plan or nil if tasks don't have node_ids.
function M._rebuild_plan(waves, original_plan)
	local has_node_ids = false
	local nodes = {}

	for _, wave in ipairs(waves) do
		for _, task in ipairs(wave.tasks) do
			if task.node_id then
				has_node_ids = true
				nodes[#nodes + 1] = {
					id = task.node_id,
					goal = task.title,
					description = task.description,
					deps = task.deps or {},
					files = task.files or {},
					status = "pending",
				}
			end
		end
	end

	if not has_node_ids then
		return nil
	end

	return {
		nodes = nodes,
		root_goal = original_plan.root_goal,
	}
end

--------------------------------------------------------------------
-- Parse waves from editable buffer
--------------------------------------------------------------------

--- Parse waves from the editable buffer format.
--- Returns { { wave = N, tasks = { { order, title, description, files, node_id, deps }, ... } }, ... }
function M._parse_buffer_waves(text)
	local waves = {}
	local current_wave = nil
	local current_task = nil

	for line in text:gmatch("[^\n]*") do
		-- Wave header: # Wave N ...
		local wave_num = line:match("^# Wave (%d+)")
		if wave_num then
			-- Save previous task if any
			if current_task and current_wave then
				current_task.description = vim.trim(current_task.description)
				current_wave.tasks[#current_wave.tasks + 1] = current_task
				current_task = nil
			end
			-- Save previous wave if any
			if current_wave and #current_wave.tasks > 0 then
				waves[#waves + 1] = current_wave
			end
			current_wave = { wave = tonumber(wave_num), tasks = {} }
			goto continue
		end

		-- Task header: ## Task <id>: Title
		-- Handles both "## Task t1: Title" and "## Task 1: Title"
		local task_id, title = line:match("^## Task ([%w_]+): (.+)")
		if task_id then
			-- Save previous task
			if current_task and current_wave then
				current_task.description = vim.trim(current_task.description)
				current_wave.tasks[#current_wave.tasks + 1] = current_task
			end

			local numeric = tonumber(task_id)
			current_task = {
				order = numeric or (#(current_wave and current_wave.tasks or {}) + 1),
				title = vim.trim(title),
				description = "",
				files = {},
				deps = {},
			}
			-- Set node_id for non-numeric IDs (DAG tasks)
			if not numeric then
				current_task.node_id = task_id
			end
			goto continue
		end

		-- Files line: **Files:** path1, path2
		if current_task then
			local files_str = line:match("^%*%*Files:%*%*%s*(.+)")
			if files_str then
				current_task.files = {}
				for f in files_str:gmatch("[^,%s]+") do
					current_task.files[#current_task.files + 1] = vim.trim(f)
				end
				goto continue
			end
		end

		-- Deps line: **Deps:** t1, t2  or  **Deps:** (none)
		if current_task then
			local deps_str = line:match("^%*%*Deps:%*%*%s*(.+)")
			if deps_str then
				current_task.deps = {}
				if not deps_str:match("%(none%)") then
					for d in deps_str:gmatch("[^,%s]+") do
						current_task.deps[#current_task.deps + 1] = vim.trim(d)
					end
				end
				goto continue
			end
		end

		-- Description line (accumulate into current task)
		if current_task then
			if not line:match("^%-%-%-") and not line:match("^<!%-%-") then
				current_task.description = current_task.description .. line .. "\n"
			end
		end

		::continue::
	end

	-- Don't forget the last task and wave
	if current_task and current_wave then
		current_task.description = vim.trim(current_task.description)
		current_wave.tasks[#current_wave.tasks + 1] = current_task
	end
	if current_wave and #current_wave.tasks > 0 then
		waves[#waves + 1] = current_wave
	end

	-- Sort tasks within each wave
	for _, w in ipairs(waves) do
		table.sort(w.tasks, function(a, b)
			return a.order < b.order
		end)
	end

	-- Sort waves
	table.sort(waves, function(a, b)
		return a.wave < b.wave
	end)

	return waves
end

return M
