-- dwight/auto/preview.lua
-- Plan preview: show decomposition before executing

local M = {}

local api = vim.api
local _flatten = require("dwight.util").flatten_lines

--- Show decomposed tasks in a review buffer.
--- <CR> starts execution, e opens task for editing, q cancels.
function M._show_decomposition(request, tasks, callback)
	local decompose = require("dwight.auto.decompose")

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

return M
