-- dwight/sessions.lua
-- Unified session browser: scans agent, auto, and swarm session logs.

local M = {}

local api = vim.api
local _flatten = require("dwight.util").flatten_lines

--------------------------------------------------------------------
-- Parsing helpers
--------------------------------------------------------------------

--- Parse metadata from a session log file.
--- Works across agent, auto, and swarm formats.
--- @param path string File path
--- @return table|nil Parsed metadata
local function parse_session_file(path)
	local f = io.open(path, "r")
	if not f then
		return nil
	end

	local content = f:read(2048) -- only read header
	f:close()
	if not content then
		return nil
	end

	local meta = { path = path }

	meta.request = content:match("%*%*Request:%*%* (.-)[\n]") or ""

	-- Outcome: agent uses **Outcome:**, auto/swarm use **Result:**
	local outcome = content:match("%*%*Outcome:%*%* (.-)[\n]")
	local result = content:match("%*%*Result:%*%* (.-)[\n]")
	local outcome_raw = outcome or result or ""
	meta.success = outcome_raw:match("SUCCESS") ~= nil

	-- Duration
	local dur_str = content:match("%*%*Duration:%*%* (%d+)s")
	if dur_str then
		meta.duration = tonumber(dur_str) or 0
	else
		-- Agent format: **Time:** 2026-03-20 14:32:00 (45s)
		local time_dur = content:match("%*%*Time:%*%* .- %((%d+)s%)")
		meta.duration = tonumber(time_dur) or 0
	end

	-- Cost
	local cost_str = content:match("%*%*Cost:%*%* ~%$([%d%.]+)")
	meta.cost = tonumber(cost_str) or 0

	-- Timestamp from filename: YYYYMMDD-HHMMSS
	local y, mo, d, h, mi, s = path:match("(%d%d%d%d)(%d%d)(%d%d)%-(%d%d)(%d%d)(%d%d)")
	if y then
		meta.timestamp = os.time({
			year = tonumber(y),
			month = tonumber(mo),
			day = tonumber(d),
			hour = tonumber(h),
			min = tonumber(mi),
			sec = tonumber(s),
		})
	else
		meta.timestamp = 0
	end

	return meta
end

--- Format duration for display.
local function fmt_dur(secs)
	if not secs or secs <= 0 then
		return ""
	end
	if secs >= 60 then
		return string.format("%dm%ds", math.floor(secs / 60), secs % 60)
	end
	return string.format("%ds", secs)
end

--------------------------------------------------------------------
-- Scanner
--------------------------------------------------------------------

--- Scan a directory for .md session logs.
--- @param dir string Directory path
--- @param mode string Mode label (e.g. "agent", "auto", "swarm")
--- @return table List of parsed session entries
local function scan_dir(dir, mode)
	local sessions = {}
	if vim.fn.isdirectory(dir) ~= 1 then
		return sessions
	end

	local uv = vim.loop or vim.uv
	local handle = uv.fs_scandir(dir)
	if not handle then
		return sessions
	end

	while true do
		local name, ftype = uv.fs_scandir_next(handle)
		if not name then
			break
		end
		if (ftype == "file" or ftype == nil) and name:match("%.md$") then
			local path = dir .. "/" .. name
			local meta = parse_session_file(path)
			if meta then
				meta.mode = mode
				meta.filename = name
				sessions[#sessions + 1] = meta
			end
		end
	end

	return sessions
end

--- List all sessions across agent, auto, and swarm.
--- Returns entries sorted by timestamp descending.
function M.list_all()
	local sessions = {}

	-- Determine directories
	local agent_dir, auto_dir, swarm_dir

	local ok, project = pcall(require, "dwight.project")
	if ok and project.is_initialized() then
		local pdir = project.dir()
		agent_dir = pdir .. "/agent"
		auto_dir = pdir .. "/auto-logs"
		swarm_dir = pdir .. "/swarm-logs"
	else
		local data = vim.fn.stdpath("data") .. "/dwight"
		agent_dir = data .. "/agent"
		auto_dir = data .. "/auto-logs"
		swarm_dir = data .. "/swarm-logs"
	end

	-- Scan all three directories
	for _, s in ipairs(scan_dir(agent_dir, "agent")) do
		sessions[#sessions + 1] = s
	end
	for _, s in ipairs(scan_dir(auto_dir, "auto")) do
		sessions[#sessions + 1] = s
	end
	for _, s in ipairs(scan_dir(swarm_dir, "swarm")) do
		sessions[#sessions + 1] = s
	end

	-- Sort by timestamp descending (newest first)
	table.sort(sessions, function(a, b)
		return (a.timestamp or 0) > (b.timestamp or 0)
	end)

	return sessions
end

--------------------------------------------------------------------
-- Picker UI
--------------------------------------------------------------------

--- Format a session entry for display.
local function format_entry(s)
	local icon = s.success and "+" or "x"
	local mode_tag = string.format("[%-5s]", s.mode)
	local cost_str = s.cost > 0 and string.format(", ~$%.2f", s.cost) or ""
	local dur_str = fmt_dur(s.duration)
	local time_str = ""
	if s.timestamp and s.timestamp > 0 then
		time_str = os.date("%Y-%m-%d %H:%M", s.timestamp)
	end
	return string.format("%s %s %s — %s (%s%s)", mode_tag, icon, s.request:sub(1, 50), time_str, dur_str, cost_str)
end

--- Show session browser (Telescope or fallback).
function M.show()
	local sessions = M.list_all()

	if #sessions == 0 then
		vim.notify(
			"[dwight] No sessions found. Run :DwightAgent, :DwightAuto, or :DwightSwarm first.",
			vim.log.levels.INFO
		)
		return
	end

	local has_telescope, _ = pcall(require, "telescope")
	if has_telescope then
		M._show_telescope(sessions)
	else
		M._show_fallback(sessions)
	end
end

function M._show_telescope(sessions)
	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")
	local previewers = require("telescope.previewers")

	pickers
		.new({}, {
			prompt_title = "All Sessions (agent/auto/swarm)",
			finder = finders.new_table({
				results = sessions,
				entry_maker = function(session)
					return {
						value = session,
						display = format_entry(session),
						ordinal = session.mode .. " " .. session.request .. " " .. (session.filename or ""),
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

function M._show_fallback(sessions)
	local items = {}
	for _, s in ipairs(sessions) do
		items[#items + 1] = format_entry(s)
	end

	require("dwight.select").pick(items, { prompt = "All Sessions:" }, function(_, idx)
		if idx and sessions[idx] then
			vim.cmd("edit " .. vim.fn.fnameescape(sessions[idx].path))
		end
	end)
end

return M
