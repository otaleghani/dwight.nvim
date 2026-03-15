-- dwight/agent/sessions.lua
-- Session persistence, listing, and picker UIs (Telescope / fallback).

local M = {}

local api = vim.api
local _flatten = require("dwight.util").flatten_lines

--------------------------------------------------------------------
-- Session logging (plan + execution log)
--------------------------------------------------------------------

--- Save a full agent session (plan + all execution entries).
--- Also saves a resume file if the session had errors.
function M._save_session(session)
	pcall(function()
		local agent_dir = require("dwight.agent")._agent_dir
		local dir = agent_dir()
		vim.fn.mkdir(dir, "p")

		local path = string.format("%s/%s_%s.md", dir, session.id, session.name)

		local lines = {
			"# Agent Session",
			"",
			"**Request:** " .. session.request,
			string.format("**Time:** %s (%ds)", os.date("%Y-%m-%d %H:%M:%S", session.timestamp), session.duration),
			string.format("**Outcome:** %s", session.had_error and "❌ FAILED" or "✅ SUCCESS"),
			string.format("**Cost:** ~$%.4f", session.cost or 0),
		}

		-- Include failed step info for resume
		if session.failed_step then
			lines[#lines + 1] = string.format("**Failed at:** Step %d", session.failed_step)
		end

		lines[#lines + 1] = ""
		lines[#lines + 1] = "---"
		lines[#lines + 1] = ""
		lines[#lines + 1] = "## Plan"
		lines[#lines + 1] = ""
		lines[#lines + 1] = session.plan
		lines[#lines + 1] = ""
		lines[#lines + 1] = "---"
		lines[#lines + 1] = ""
		lines[#lines + 1] = "## Execution Log"
		lines[#lines + 1] = ""

		-- Append all quickfix entries as the execution log
		for i, entry in ipairs(session.entries or {}) do
			local icon = entry.type == "E" and "x" or entry.type == "W" and "!" or "✓"
			local file = entry.filename and (" `" .. vim.fn.fnamemodify(entry.filename, ":.") .. "`") or ""
			lines[#lines + 1] = string.format("%d. %s %s%s", i, icon, entry.text or "", file)
		end

		if #(session.entries or {}) == 0 then
			lines[#lines + 1] = "(no entries)"
		end

		-- Include step journal if available
		if session.journal and #session.journal > 0 then
			lines[#lines + 1] = ""
			lines[#lines + 1] = "---"
			lines[#lines + 1] = ""
			lines[#lines + 1] = "## Step Journal"
			lines[#lines + 1] = ""
			for _, entry in ipairs(session.journal) do
				lines[#lines + 1] = "- " .. entry
			end
		end

		local f = io.open(path, "w")
		if f then
			f:write(table.concat(lines, "\n"))
			f:close()
		end
	end)
end

--------------------------------------------------------------------
-- DwightAgentLog: browse saved sessions with Telescope
--------------------------------------------------------------------

--- List all saved agent sessions.
function M.list_sessions()
	local agent_dir = require("dwight.agent")._agent_dir
	local dir = agent_dir()
	if vim.fn.isdirectory(dir) ~= 1 then
		return {}
	end

	local uv = vim.loop or vim.uv
	local sessions = {}
	local handle = uv.fs_scandir(dir)
	if not handle then
		return {}
	end

	while true do
		local name, ftype = uv.fs_scandir_next(handle)
		if not name then
			break
		end
		if ftype == "file" and name:match("%.md$") then
			local path = dir .. "/" .. name

			-- Parse metadata from the first few lines
			local f = io.open(path, "r")
			if f then
				local content = f:read("*a")
				f:close()

				local request = content:match("%*%*Request:%*%* (.-)[\n]") or name
				local time_str = content:match("%*%*Time:%*%* (.-)[\n]") or ""
				local outcome = content:match("%*%*Outcome:%*%* (.-)[\n]") or ""

				sessions[#sessions + 1] = {
					name = name:gsub("%.md$", ""),
					path = path,
					request = request,
					time = time_str,
					outcome = outcome,
				}
			end
		end
	end

	-- Sort by name descending (newest first, since names start with timestamp)
	table.sort(sessions, function(a, b)
		return a.name > b.name
	end)
	return sessions
end

--- Open the agent log browser.
function M.show_log()
	local sessions = M.list_sessions()

	if #sessions == 0 then
		vim.notify("[dwight] No agent sessions found. Run :DwightAgent first.", vim.log.levels.INFO)
		return
	end

	-- Try Telescope
	local has_telescope, _ = pcall(require, "telescope")
	if has_telescope then
		M._show_log_telescope(sessions)
	else
		M._show_log_fallback(sessions)
	end
end

function M._show_log_telescope(sessions)
	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")
	local previewers = require("telescope.previewers")

	pickers
		.new({}, {
			prompt_title = "🧠 Agent Sessions",
			finder = finders.new_table({
				results = sessions,
				entry_maker = function(session)
					local icon = session.outcome:match("SUCCESS") and "✅" or "❌"
					return {
						value = session,
						display = string.format("%s %s — %s", icon, session.request:sub(1, 50), session.time),
						ordinal = session.name .. " " .. session.request,
						filename = session.path,
					}
				end,
			}),
			previewer = previewers.new_buffer_previewer({
				title = "Session Log",
				define_preview = function(self, entry)
					local path = entry.value.path
					if vim.fn.filereadable(path) == 1 then
						local lines = vim.fn.readfile(path)
						api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, _flatten(lines))
						vim.bo[self.state.bufnr].filetype = "markdown"
					end
				end,
			}),
			sorter = conf.generic_sorter({}),
			attach_mappings = function(prompt_bufnr, _map)
				actions.select_default:replace(function()
					local entry = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					if entry and entry.value.path then
						vim.cmd("edit " .. vim.fn.fnameescape(entry.value.path))
					end
				end)
				return true
			end,
		})
		:find()
end

function M._show_log_fallback(sessions)
	local items = {}
	for _, s in ipairs(sessions) do
		local icon = s.outcome:match("SUCCESS") and "✅" or "❌"
		items[#items + 1] = string.format("%s %s — %s", icon, s.request:sub(1, 50), s.time)
	end

	require("dwight.select").pick(items, { prompt = "🧠 Agent Sessions:" }, function(_, idx)
		if idx and sessions[idx] then
			vim.cmd("edit " .. vim.fn.fnameescape(sessions[idx].path))
		end
	end)
end

return M
