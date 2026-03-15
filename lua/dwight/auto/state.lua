-- dwight/auto/state.lua
-- Session state: save/load for resume, pause/continue

local M = {}

function M.auto_dir()
	local project = require("dwight.project")
	if project.is_initialized() then
		return project.dir() .. "/auto"
	end
	return vim.fn.stdpath("data") .. "/dwight/auto"
end

function M._save_state(state)
	local dir = M.auto_dir()
	vim.fn.mkdir(dir, "p")
	local path = dir .. "/current.json"
	local f = io.open(path, "w")
	if f then
		f:write(vim.json.encode(state))
		f:close()
	end
end

function M._load_state()
	local path = M.auto_dir() .. "/current.json"
	local f = io.open(path, "r")
	if not f then
		return nil
	end
	local raw = f:read("*a")
	f:close()
	local ok, data = pcall(vim.json.decode, raw)
	if not ok then
		return nil
	end
	return data
end

function M._clear_state()
	pcall(os.remove, M.auto_dir() .. "/current.json")
end

--- Write a session summary log to .dwight/auto-logs/
--- Called after both successful and failed DwightAuto runs.
function M._write_session_log(opts)
	pcall(function()
		local project = require("dwight.project")
		if not project.is_initialized() then
			return
		end

		local log_dir = project.dir() .. "/auto-logs"
		vim.fn.mkdir(log_dir, "p")

		local timestamp = os.date("%Y%m%d-%H%M%S")
		local success = opts.success and "success" or "failed"
		local path = string.format("%s/%s-%s.md", log_dir, timestamp, success)

		local lines = {}
		lines[#lines + 1] = string.format("# DwightAuto Session — %s", os.date("%Y-%m-%d %H:%M:%S"))
		lines[#lines + 1] = ""
		lines[#lines + 1] = string.format("**Request:** %s", opts.request or "?")
		lines[#lines + 1] = string.format("**Result:** %s", opts.success and "SUCCESS" or "FAILED")
		lines[#lines + 1] = string.format("**Duration:** %ds", opts.duration or 0)
		lines[#lines + 1] = string.format("**Backend:** %s", opts.backend or "?")
		if opts.cost and opts.cost > 0 then
			lines[#lines + 1] = string.format("**Cost:** ~$%.2f", opts.cost)
		end
		lines[#lines + 1] =
			string.format("**Tasks:** %d/%d completed", opts.completed_count or 0, opts.total_tasks or 0)
		lines[#lines + 1] = ""

		-- Git diff stat: summary of ALL changes made in this session
		pcall(function()
			-- Get diff stat from the pre-auto checkpoint to HEAD
			local diff_handle =
				io.popen("git diff --stat HEAD~" .. tostring(opts.completed_count or 0) .. "..HEAD 2>/dev/null")
			if diff_handle then
				local diff_output = diff_handle:read("*a")
				diff_handle:close()
				if diff_output and diff_output ~= "" then
					lines[#lines + 1] = "## Changes Summary (git diff --stat)"
					lines[#lines + 1] = "```"
					lines[#lines + 1] = diff_output:sub(1, 3000)
					lines[#lines + 1] = "```"
					lines[#lines + 1] = ""
				end
			end
		end)

		-- Collect all files touched across all sessions
		local all_created = {}
		local all_edited = {}
		if opts.sessions then
			for _, s in ipairs(opts.sessions) do
				if s.files_created then
					for _, f in ipairs(s.files_created) do
						all_created[f] = true
					end
				end
				if s.files_edited then
					for _, f in ipairs(s.files_edited) do
						all_edited[f] = true
					end
				end
			end
		end

		-- File inventory
		local has_files = false
		for _ in pairs(all_created) do
			has_files = true
			break
		end
		if not has_files then
			for _ in pairs(all_edited) do
				has_files = true
				break
			end
		end

		if has_files then
			lines[#lines + 1] = "## Files Touched"
			lines[#lines + 1] = ""
			if next(all_created) then
				lines[#lines + 1] = "**Created:**"
				for f in pairs(all_created) do
					lines[#lines + 1] = "- `" .. f .. "`"
				end
				lines[#lines + 1] = ""
			end
			if next(all_edited) then
				lines[#lines + 1] = "**Modified:**"
				for f in pairs(all_edited) do
					if not all_created[f] then -- don't double-list
						lines[#lines + 1] = "- `" .. f .. "`"
					end
				end
				lines[#lines + 1] = ""
			end
		end

		-- Task details
		lines[#lines + 1] = "## Tasks"
		lines[#lines + 1] = ""
		if opts.sessions then
			for _, s in ipairs(opts.sessions) do
				local icon = s.had_error and "x" or "✓"
				local dur = s.duration and string.format(" (%ds)", s.duration) or ""
				local cost = (s.cost and s.cost > 0) and string.format(" $%.2f", s.cost) or ""
				lines[#lines + 1] =
					string.format("### %s Task %d: %s%s%s", icon, s.task_num or 0, s.title or "?", dur, cost)
				lines[#lines + 1] = ""

				-- Task description
				if s.description and s.description ~= "" then
					lines[#lines + 1] = "**Description:**"
					lines[#lines + 1] = s.description:sub(1, 500)
					lines[#lines + 1] = ""
				end

				-- Files touched by this task
				if (s.files_created and #s.files_created > 0) or (s.files_edited and #s.files_edited > 0) then
					lines[#lines + 1] = "**Files:**"
					if s.files_created then
						for _, f in ipairs(s.files_created) do
							lines[#lines + 1] = "- `" .. f .. "` (new)"
						end
					end
					if s.files_edited then
						for _, f in ipairs(s.files_edited) do
							lines[#lines + 1] = "- `" .. f .. "`"
						end
					end
					lines[#lines + 1] = ""
				end

				-- Full output from Claude Code / agentic loop
				if s.full_output and s.full_output ~= "" then
					lines[#lines + 1] = "<details><summary>Full agent output</summary>"
					lines[#lines + 1] = ""
					lines[#lines + 1] = "```"
					-- Cap at 5000 chars per task to keep log reasonable
					local output = s.full_output:sub(1, 5000)
					if #s.full_output > 5000 then
						output = output .. "\n... (truncated, " .. #s.full_output .. " chars total)"
					end
					lines[#lines + 1] = output
					lines[#lines + 1] = "```"
					lines[#lines + 1] = ""
					lines[#lines + 1] = "</details>"
					lines[#lines + 1] = ""
				elseif s.summary and s.summary ~= "" then
					-- Fallback to summary if no full output
					lines[#lines + 1] = "**Summary:**"
					lines[#lines + 1] = s.summary:sub(1, 1000)
					lines[#lines + 1] = ""
				end

				-- Error info
				if s.error and s.error ~= "" then
					lines[#lines + 1] = "**Error:** " .. s.error:sub(1, 500)
					lines[#lines + 1] = ""
				end

				lines[#lines + 1] = "---"
				lines[#lines + 1] = ""
			end
		end

		-- Failed task info
		if opts.failed_task then
			lines[#lines + 1] = "## Failure Details"
			lines[#lines + 1] = ""
			lines[#lines + 1] =
				string.format("Failed on task %d: %s", opts.failed_task.num or 0, opts.failed_task.title or "?")
			if opts.failed_task.error then
				lines[#lines + 1] = "Error: " .. opts.failed_task.error:sub(1, 500)
			end
			lines[#lines + 1] = ""
		end

		local f = io.open(path, "w")
		if f then
			f:write(table.concat(lines, "\n"))
			f:close()
		end
	end)
end

return M
