-- dwight/replay.lua
-- Session replay: step through past agent sessions showing each event.
-- Reads JSONL logs from .dwight/agentic-logs/ produced by the agentic module.
--
-- :DwightReplay [session]  — pick a session and step through it
-- :DwightReplay latest     — replay the most recent session

local M = {}

local api = vim.api
local _flatten = require("dwight.util").flatten_lines

--------------------------------------------------------------------
-- Session discovery
--------------------------------------------------------------------

--- Get the agentic logs directory.
local function logs_dir()
	local ok, project = pcall(require, "dwight.project")
	if ok and project.is_initialized() then
		return project.dir() .. "/agentic-logs"
	end
	return nil
end

--- List available session log files.
--- Returns { { path, filename, timestamp, task_name, size, event_count }, ... }
--- sorted newest first.
function M.list_sessions()
	local dir = logs_dir()
	if not dir then
		return {}
	end

	local uv = vim.loop or vim.uv
	local handle = uv.fs_scandir(dir)
	if not handle then
		return {}
	end

	local sessions = {}
	while true do
		local name, ftype = uv.fs_scandir_next(handle)
		if not name then
			break
		end
		if ftype == "file" and name:match("%.jsonl$") then
			local path = dir .. "/" .. name

			-- Parse filename: 20250301-173004-task-name.jsonl
			local ts = name:match("^(%d+%-%d+)")
			local task = name:match("^%d+%-%d+%-(.+)%.jsonl$") or "unknown"

			-- Get file size
			local stat = uv.fs_stat(path)
			local size = stat and stat.size or 0

			-- Quick event count (count lines)
			local event_count = 0
			local f = io.open(path, "r")
			if f then
				for _ in f:lines() do
					event_count = event_count + 1
				end
				f:close()
			end

			sessions[#sessions + 1] = {
				path = path,
				filename = name,
				timestamp = ts,
				task_name = task:gsub("%-", " "),
				size = size,
				event_count = event_count,
			}
		end
	end

	table.sort(sessions, function(a, b)
		return a.filename > b.filename
	end)
	return sessions
end

--- Parse a JSONL session file into events.
--- Returns { { type, timestamp, ... }, ... }
function M.parse_session(path)
	local f = io.open(path, "r")
	if not f then
		return nil
	end

	local events = {}
	for line in f:lines() do
		if line ~= "" then
			local ok, event = pcall(vim.json.decode, line)
			if ok and type(event) == "table" then
				events[#events + 1] = event
			end
		end
	end
	f:close()

	return events
end

--------------------------------------------------------------------
-- Event rendering
--------------------------------------------------------------------

--- Format a timestamp as readable.
local function fmt_time(ts)
	if not ts or ts == 0 then
		return ""
	end
	return os.date("%H:%M:%S", ts)
end

--- Format duration between two timestamps.
local function fmt_duration(start_ts, end_ts)
	if not start_ts or not end_ts then
		return ""
	end
	local d = end_ts - start_ts
	if d < 60 then
		return string.format("%ds", d)
	end
	return string.format("%dm %ds", math.floor(d / 60), d % 60)
end

--- Render a single event as display lines.
--- Returns { lines = { ... }, icon = "...", title = "..." }
local function render_event(event, idx, total, session_start)
	local lines = {}
	local etype = event.type or "unknown"
	local icon, title

	-- Time offset from session start
	local offset = ""
	if session_start and event.timestamp then
		local d = event.timestamp - session_start
		if d >= 0 then
			offset = string.format(" +%ds", d)
		end
	end

	if etype == "start" then
		icon = "🚀"
		title = "Session Start"
		lines[#lines + 1] = ""
		lines[#lines + 1] = "  Backend: " .. (event.backend or "?")
		if event.task then
			lines[#lines + 1] = ""
			lines[#lines + 1] =
				"  ── Task ──────────────────────────────────────"
			-- Wrap task text
			local task = event.task
			for i = 1, #task, 80 do
				lines[#lines + 1] = "  " .. task:sub(i, i + 79)
			end
		end
	elseif etype == "cc_tool" then
		local tool = event.tool or "?"
		local detail = event.detail or ""

		if tool == "bash" or tool == "run_command" or tool == "Bash" then
			icon = "🔧"
			title = "Run Command"
			lines[#lines + 1] = ""
			lines[#lines + 1] = "  $ " .. detail
		elseif tool == "read" or tool == "read_file" or tool == "Read" then
			icon = "📖"
			title = "Read File"
			lines[#lines + 1] = ""
			lines[#lines + 1] = "  " .. detail
		elseif tool == "write" or tool == "write_file" or tool == "Write" then
			icon = "📝"
			title = "Write File"
			lines[#lines + 1] = ""
			lines[#lines + 1] = "  " .. detail
		elseif tool == "edit" or tool == "str_replace" or tool == "Edit" or tool == "MultiEdit" then
			icon = "✏️"
			title = "Edit File"
			lines[#lines + 1] = ""
			lines[#lines + 1] = "  " .. detail
		elseif tool == "list" or tool == "list_dir" or tool == "ListDir" then
			icon = "📂"
			title = "List Directory"
			lines[#lines + 1] = ""
			lines[#lines + 1] = "  " .. detail
		elseif tool == "search" or tool == "grep" or tool == "Grep" or tool == "Glob" then
			icon = "🔍"
			title = "Search"
			lines[#lines + 1] = ""
			lines[#lines + 1] = "  " .. detail
		elseif tool == "task_complete" or tool == "TodoComplete" then
			icon = "✅"
			title = "Task Complete"
		else
			icon = "🔧"
			title = "Tool: " .. tool
			if detail ~= "" then
				lines[#lines + 1] = ""
				lines[#lines + 1] = "  " .. detail
			end
		end
	elseif etype == "cc_tool_result" then
		icon = event.is_error and "🔴" or "📋"
		title = event.is_error and "Tool Error" or "Tool Result"
		if event.summary and event.summary ~= "" then
			lines[#lines + 1] = ""
			-- Show result, wrapping long lines
			for result_line in event.summary:gmatch("[^\n]+") do
				lines[#lines + 1] = "  " .. result_line:sub(1, 100)
			end
		end
	elseif etype == "cc-thought" or etype == "cc_thought" then
		icon = "💭"
		title = "Thinking"
		if event.text and event.text ~= "" then
			lines[#lines + 1] = ""
			for thought_line in event.text:gmatch("[^\n]+") do
				lines[#lines + 1] = "  " .. thought_line:sub(1, 100)
			end
		end
	elseif etype == "cc_usage" then
		icon = "📊"
		title = "Token Usage"
		lines[#lines + 1] = ""
		local tok_in = event.input_tokens or 0
		local tok_out = event.output_tokens or 0
		lines[#lines + 1] = string.format(
			"  Input: %s tokens  |  Output: %s tokens",
			tok_in >= 1000 and string.format("%.1fk", tok_in / 1000) or tostring(tok_in),
			tok_out >= 1000 and string.format("%.1fk", tok_out / 1000) or tostring(tok_out)
		)
	elseif etype == "cc_final_cost" then
		icon = "💰"
		title = "Final Cost"
		lines[#lines + 1] = ""
		local tok_in = event.input_tokens or 0
		local tok_out = event.output_tokens or 0
		lines[#lines + 1] = string.format(
			"  Tokens: %s in / %s out",
			tok_in >= 1000 and string.format("%.1fk", tok_in / 1000) or tostring(tok_in),
			tok_out >= 1000 and string.format("%.1fk", tok_out / 1000) or tostring(tok_out)
		)
		if event.duration_ms then
			lines[#lines + 1] = string.format("  Duration: %.1fs", event.duration_ms / 1000)
		end
	elseif etype == "finish" then
		icon = event.exit_code == 0 and "✅" or "❌"
		title = event.exit_code == 0 and "Session Complete" or "Session Failed"
		lines[#lines + 1] = ""
		if event.exit_code then
			lines[#lines + 1] = "  Exit code: " .. event.exit_code
		end
		if event.duration then
			lines[#lines + 1] = "  Duration: " .. fmt_duration(0, event.duration)
		end
		if event.output_len then
			lines[#lines + 1] = "  Output: " .. event.output_len .. " chars"
		end
	else
		icon = "❓"
		title = etype
		-- Show all fields
		for k, v in pairs(event) do
			if k ~= "type" and k ~= "timestamp" and k ~= "turn" then
				local val = type(v) == "string" and v:sub(1, 100) or tostring(v)
				lines[#lines + 1] = "  " .. k .. ": " .. val
			end
		end
	end

	return {
		lines = lines,
		icon = icon,
		title = title,
		offset = offset,
		time = fmt_time(event.timestamp),
	}
end

--------------------------------------------------------------------
-- Interactive replay buffer
--------------------------------------------------------------------

--- Open the replay UI for a session.
function M.replay(path)
	local events = M.parse_session(path)
	if not events or #events == 0 then
		vim.notify("[dwight] No events found in session log.", vim.log.levels.WARN)
		return
	end

	local filename = path:match("([^/]+)$") or path
	local session_start = events[1] and events[1].timestamp or 0

	-- State
	local current = 1 -- current event index
	local show_all = false -- toggle: single event vs all-up-to-current

	-- Create buffer
	local buf = api.nvim_create_buf(false, true)
	api.nvim_buf_set_name(buf, "dwight://replay/" .. filename)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	vim.bo[buf].filetype = "dwight_replay"

	-- Open split
	vim.cmd("botright split")
	local win = api.nvim_get_current_win()
	api.nvim_win_set_buf(win, buf)
	api.nvim_win_set_height(win, math.min(35, math.floor(vim.o.lines * 0.5)))

	--- Render the current view into the buffer.
	local function render()
		local lines = {}

		-- Header
		lines[#lines + 1] =
			"╔══════════════════════════════════════════════════════════════╗"
		lines[#lines + 1] = string.format("║  🔁 Session Replay: %s", filename:sub(1, 39))
		lines[#lines + 1] =
			"╚══════════════════════════════════════════════════════════════╝"
		lines[#lines + 1] = ""

		-- Progress bar
		local pbar_w = 40
		local filled = math.floor(current / #events * pbar_w)
		local pbar = string.rep("█", filled) .. string.rep("░", pbar_w - filled)
		lines[#lines + 1] = string.format(
			"  Step %d / %d  [%s]  %s",
			current,
			#events,
			pbar,
			show_all and "(cumulative)" or "(single step)"
		)
		lines[#lines + 1] = ""
		lines[#lines + 1] =
			"  ─────────────────────────────────────────────────────────────"

		-- Render events
		local start_idx = show_all and 1 or current
		local end_idx = current

		for i = start_idx, end_idx do
			local event = events[i]
			local rendered = render_event(event, i, #events, session_start)
			lines[#lines + 1] = ""

			-- Event header line
			local marker = i == current and "▶" or " "
			lines[#lines + 1] = string.format(
				"  %s %d. %s %s%s  %s",
				marker,
				i,
				rendered.icon,
				rendered.title,
				rendered.offset,
				rendered.time
			)

			-- Event body
			for _, line in ipairs(rendered.lines) do
				lines[#lines + 1] = line
			end
		end

		lines[#lines + 1] = ""
		lines[#lines + 1] =
			"  ─────────────────────────────────────────────────────────────"
		lines[#lines + 1] = ""

		-- Summary stats at current position
		local tools_so_far = 0
		local thoughts_so_far = 0
		local errors_so_far = 0
		for i = 1, current do
			local t = events[i].type or ""
			if t == "cc_tool" then
				tools_so_far = tools_so_far + 1
			elseif t == "cc-thought" or t == "cc_thought" then
				thoughts_so_far = thoughts_so_far + 1
			elseif t == "cc_tool_result" and events[i].is_error then
				errors_so_far = errors_so_far + 1
			end
		end
		lines[#lines + 1] = string.format(
			"  Progress: %d tools  |  %d thoughts  |  %d errors",
			tools_so_far,
			thoughts_so_far,
			errors_so_far
		)

		-- Keybinding help
		lines[#lines + 1] = ""
		lines[#lines + 1] = "  ── Controls ──"
		lines[#lines + 1] = "  j/→/l  Next step     k/←/h  Previous step"
		lines[#lines + 1] = "  J      Next tool     K      Previous tool"
		lines[#lines + 1] = "  gg     First step    G      Last step"
		lines[#lines + 1] = "  v      Toggle view   q      Close"

		-- Write to buffer
		vim.bo[buf].modifiable = true
		api.nvim_buf_set_lines(buf, 0, -1, false, _flatten(lines))
		vim.bo[buf].modifiable = false

		-- Scroll: keep current event visible
		pcall(function()
			-- Jump cursor to the ▶ marker line
			for lnum, line in ipairs(lines) do
				if line:match("^  ▶") then
					api.nvim_win_set_cursor(win, { lnum, 0 })
					break
				end
			end
		end)
	end

	-- Syntax highlights
	pcall(function()
		api.nvim_buf_call(buf, function()
			vim.cmd([[
        syntax match DwightReplayHeader /^[╔╚║].*$/
        syntax match DwightReplaySep /^  ─\+$/
        syntax match DwightReplayBar /[█░]\+/
        syntax match DwightReplayActive /^  ▶.*/
        syntax match DwightReplayStep /^   \d\+\./
        syntax match DwightReplayCmd /^  \$ .*/
        syntax match DwightReplayPath /^  [^ $].*/
      ]])
		end)
	end)

	local hl = api.nvim_set_hl
	hl(0, "DwightReplayHeader", { fg = "#bb9af7", bold = true, default = true })
	hl(0, "DwightReplaySep", { fg = "#565f89", default = true })
	hl(0, "DwightReplayBar", { fg = "#9ece6a", default = true })
	hl(0, "DwightReplayActive", { fg = "#7dcfff", bold = true, default = true })
	hl(0, "DwightReplayStep", { fg = "#7aa2f7", default = true })
	hl(0, "DwightReplayCmd", { fg = "#e0af68", default = true })

	-- Navigation functions
	local function go_to(idx)
		current = math.max(1, math.min(#events, idx))
		render()
	end

	local function next_step()
		go_to(current + 1)
	end
	local function prev_step()
		go_to(current - 1)
	end

	local function next_tool()
		for i = current + 1, #events do
			if events[i].type == "cc_tool" then
				go_to(i)
				return
			end
		end
		vim.notify("[dwight] No more tool calls.", vim.log.levels.INFO)
	end

	local function prev_tool()
		for i = current - 1, 1, -1 do
			if events[i].type == "cc_tool" then
				go_to(i)
				return
			end
		end
		vim.notify("[dwight] No earlier tool calls.", vim.log.levels.INFO)
	end

	local function first_step()
		go_to(1)
	end
	local function last_step()
		go_to(#events)
	end

	local function toggle_view()
		show_all = not show_all
		render()
	end

	local function close()
		pcall(api.nvim_win_close, win, true)
	end

	-- Keymaps
	local map_opts = { buffer = buf, nowait = true }
	vim.keymap.set("n", "j", next_step, map_opts)
	vim.keymap.set("n", "l", next_step, map_opts)
	vim.keymap.set("n", "<Right>", next_step, map_opts)
	vim.keymap.set("n", "<Space>", next_step, map_opts)
	vim.keymap.set("n", "k", prev_step, map_opts)
	vim.keymap.set("n", "h", prev_step, map_opts)
	vim.keymap.set("n", "<Left>", prev_step, map_opts)
	vim.keymap.set("n", "J", next_tool, map_opts)
	vim.keymap.set("n", "K", prev_tool, map_opts)
	vim.keymap.set("n", "gg", first_step, map_opts)
	vim.keymap.set("n", "G", last_step, map_opts)
	vim.keymap.set("n", "v", toggle_view, map_opts)
	vim.keymap.set("n", "q", close, map_opts)
	vim.keymap.set("n", "<Esc>", close, map_opts)

	-- Initial render
	render()
end

--------------------------------------------------------------------
-- Session picker
--------------------------------------------------------------------

--- Pick a session and start replay.
function M.pick(target)
	if target == "latest" then
		local sessions = M.list_sessions()
		if #sessions == 0 then
			vim.notify("[dwight] No session logs found. Run an agent task first.", vim.log.levels.INFO)
			return
		end
		M.replay(sessions[1].path)
		return
	end

	-- If target looks like a path or filename, try to use it directly
	if target and target ~= "" then
		local dir = logs_dir()
		if dir then
			-- Try exact filename match
			local path = dir .. "/" .. target
			if vim.fn.filereadable(path) == 1 then
				M.replay(path)
				return
			end
			-- Try partial match
			local sessions = M.list_sessions()
			for _, s in ipairs(sessions) do
				if s.filename:find(target, 1, true) or s.task_name:find(target, 1, true) then
					M.replay(s.path)
					return
				end
			end
		end
		vim.notify("[dwight] Session not found: " .. target, vim.log.levels.WARN)
		return
	end

	-- Interactive picker
	local sessions = M.list_sessions()
	if #sessions == 0 then
		vim.notify("[dwight] No session logs found. Run an agent task first.", vim.log.levels.INFO)
		return
	end

	-- Try Telescope
	local has_tel, pickers = pcall(require, "telescope.pickers")
	if has_tel then
		M._pick_telescope(sessions, pickers)
	else
		M._pick_fallback(sessions)
	end
end

--- Telescope picker for sessions.
function M._pick_telescope(sessions, pickers)
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")
	local previewers = require("telescope.previewers")

	pickers
		.new({}, {
			prompt_title = string.format("🔁 Session Replay (%d sessions)", #sessions),
			finder = finders.new_table({
				results = sessions,
				entry_maker = function(s)
					local display =
						string.format("%-20s %3d events  %s", s.timestamp or "?", s.event_count, s.task_name)
					return {
						value = s,
						display = display,
						ordinal = s.filename .. " " .. s.task_name,
					}
				end,
			}),
			sorter = conf.generic_sorter({}),
			previewer = previewers.new_buffer_previewer({
				title = "Session Events",
				define_preview = function(self, entry)
					local s = entry.value
					local events = M.parse_session(s.path)
					if not events then
						return
					end

					local lines = {
						"Session: " .. s.filename,
						"Task: " .. s.task_name,
						"Events: " .. #events,
						"",
						"── Event Timeline ──",
						"",
					}

					local session_start = events[1] and events[1].timestamp or 0
					for i, event in ipairs(events) do
						local rendered = render_event(event, i, #events, session_start)
						lines[#lines + 1] =
							string.format("%3d. %s %s%s", i, rendered.icon, rendered.title, rendered.offset)
						-- Show first line of detail
						if #rendered.lines > 1 then
							lines[#lines + 1] = rendered.lines[2]
						end
					end

					api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, require("dwight.util").flatten_lines(lines))
					vim.bo[self.state.bufnr].filetype = "markdown"
				end,
			}),
			attach_mappings = function(prompt_bufnr)
				actions.select_default:replace(function()
					local entry = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					if entry then
						M.replay(entry.value.path)
					end
				end)
				return true
			end,
		})
		:find()
end

--- Fallback picker for sessions (no Telescope).
function M._pick_fallback(sessions)
	local items = {}
	for _, s in ipairs(sessions) do
		items[#items + 1] = string.format("%s  %d events — %s", s.timestamp or "?", s.event_count, s.task_name)
	end

	require("dwight.select").pick(items, {
		prompt = "🔁 Replay which session?",
	}, function(_, idx)
		if idx then
			M.replay(sessions[idx].path)
		end
	end)
end

return M
