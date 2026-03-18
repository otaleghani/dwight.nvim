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
function M.show(request, waves, callback)
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
			lines[#lines + 1] = string.format("## Task %d: %s", task.order, safe_title)

			-- Show file scope
			if task.files and #task.files > 0 then
				lines[#lines + 1] = string.format("**Files:** %s", table.concat(task.files, ", "))
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

		pcall(api.nvim_buf_delete, buf, { force = true })
		callback(edited_waves)
	end, { buffer = buf, desc = "Start swarm execution" })

	vim.keymap.set("n", "q", function()
		pcall(api.nvim_buf_delete, buf, { force = true })
		vim.notify("[dwight] DwightSwarm cancelled.", vim.log.levels.INFO)
	end, { buffer = buf, desc = "Cancel" })
end

--------------------------------------------------------------------
-- Parse waves from editable buffer
--------------------------------------------------------------------

--- Parse waves from the editable buffer format.
--- Returns { { wave = N, tasks = { { order, title, description, files }, ... } }, ... }
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

		-- Task header: ## Task N: Title
		local order, title = line:match("^## Task (%d+): (.+)")
		if order then
			-- Save previous task
			if current_task and current_wave then
				current_task.description = vim.trim(current_task.description)
				current_wave.tasks[#current_wave.tasks + 1] = current_task
			end
			current_task = {
				order = tonumber(order),
				title = vim.trim(title),
				description = "",
				files = {},
			}
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
