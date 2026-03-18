-- dwight/agent_status.lua
-- Live agent status buffer: replaces vim.notify for agent execution.
-- Shows a scrolling log with spinner animation for active jobs.

local M = {}

local api = vim.api

-- State
M._bufnr = nil
M._winid = nil
M._timer = nil
M._spinner_idx = 0
M._spinner_line = nil -- line number of the active spinner
M._active = false
M._session_cost_start = nil -- tracker session cost at session start

local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

-- Namespace for extmark-based highlighting
M._ns = api.nvim_create_namespace("dwight_status")

--------------------------------------------------------------------
-- Buffer Management
--------------------------------------------------------------------

--- Open or focus the agent status buffer.
--- Returns bufnr, winid.
function M.open()
	-- Reuse existing buffer if valid
	if M._bufnr and api.nvim_buf_is_valid(M._bufnr) then
		-- If window is still visible, just return
		if M._winid and api.nvim_win_is_valid(M._winid) then
			return M._bufnr, M._winid
		end
		-- Buffer exists but window was closed — reopen
		vim.cmd("vertical botright 60split")
		M._winid = api.nvim_get_current_win()
		api.nvim_win_set_buf(M._winid, M._bufnr)
		M._setup_win(M._winid)
		-- Return focus to previous window
		vim.cmd("wincmd p")
		return M._bufnr, M._winid
	end

	-- Create new buffer
	local buf = api.nvim_create_buf(false, true) -- unlisted, scratch
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].swapfile = false
	vim.bo[buf].filetype = "dwight_status"
	pcall(function()
		api.nvim_buf_set_name(buf, "dwight://agent-status")
	end)

	-- Open in a right-side vertical split
	vim.cmd("vertical botright 60split")
	M._winid = api.nvim_get_current_win()
	api.nvim_win_set_buf(M._winid, buf)
	M._setup_win(M._winid)

	M._bufnr = buf

	-- Shared highlight groups
	require("dwight.util").ensure_highlights()

	-- Buffer-local syntax matches for the agent status filetype
	pcall(function()
		vim.cmd([[
      syntax match DwightStatusOK /^Done.*/
      syntax match DwightStatusFail /^FAILED.*/
      syntax match DwightStatusFail /\<FAILED\>/
      syntax match DwightStatusWarn /^WARN:.*/
      syntax match DwightStatusSpin /^[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏].*/
      syntax match DwightStatusHeader /^──.*$/
      syntax match DwightStatusHeader /^══.*$/

      highlight link DwightStatusOK DiagnosticOk
      highlight link DwightStatusFail DiagnosticError
      highlight link DwightStatusWarn DiagnosticWarn
      highlight link DwightStatusSpin DiagnosticInfo
      highlight link DwightStatusHeader Title
    ]])
	end)

	-- Return focus to previous window
	vim.cmd("wincmd p")

	return buf, M._winid
end

function M._setup_win(win)
	if not api.nvim_win_is_valid(win) then
		return
	end
	vim.wo[win].number = false
	vim.wo[win].relativenumber = false
	vim.wo[win].signcolumn = "no"
	vim.wo[win].winfixheight = false
	vim.wo[win].winfixwidth = true
	vim.wo[win].wrap = true
	vim.wo[win].cursorline = false
	vim.wo[win].foldmethod = "marker"
	vim.wo[win].foldmarker = "▸{{{,▸}}}"
	vim.wo[win].foldenable = true
	vim.wo[win].foldlevel = 0 -- all folds closed by default
	vim.wo[win].foldtext = "v:lua.require'dwight.agent_status'._foldtext()"
	-- Dynamic statusline with running cost
	vim.wo[win].statusline = "%#Title# Dwight Agent %#Normal#"
		.. " %{luaeval('require(\"dwight.agent_status\")._cost_label()')}"
		.. " %=%l/%L"
end

--- Close the status buffer window (but keep the buffer).
function M.close()
	M._stop_spinner()
	if M._winid and api.nvim_win_is_valid(M._winid) then
		api.nvim_win_close(M._winid, true)
	end
	M._winid = nil
	M._active = false
end

--- Toggle the status buffer visibility.
function M.toggle()
	if M._winid and api.nvim_win_is_valid(M._winid) then
		M.close()
	else
		M.open()
	end
end

--------------------------------------------------------------------
-- Logging to the buffer
--------------------------------------------------------------------

--- Append a line to the status buffer.
function M.append(text, opts)
	opts = opts or {}
	if not M._bufnr or not api.nvim_buf_is_valid(M._bufnr) then
		-- Auto-open on first message
		M.open()
	end

	local buf = M._bufnr
	if not buf then
		return
	end

	-- If replacing the spinner line, remove it first
	if M._spinner_line then
		local line_count = api.nvim_buf_line_count(buf)
		if M._spinner_line <= line_count then
			pcall(api.nvim_buf_set_lines, buf, M._spinner_line - 1, M._spinner_line, false, {})
		end
		M._spinner_line = nil
	end

	local full_text = text

	-- Append
	local line_count = api.nvim_buf_line_count(buf)
	-- If buffer only has one empty line, replace it
	-- Split text into lines — nvim_buf_set_lines rejects strings containing newlines
	local lines = {}
	for line in (full_text .. "\n"):gmatch("([^\n]*)\n") do
		lines[#lines + 1] = line
	end
	if #lines == 0 then
		lines = { full_text }
	end

	if line_count == 1 then
		local first = api.nvim_buf_get_lines(buf, 0, 1, false)[1]
		if first == "" then
			api.nvim_buf_set_lines(buf, 0, 1, false, lines)
			M._scroll_to_bottom()
			return
		end
	end

	api.nvim_buf_set_lines(buf, line_count, line_count, false, lines)
	M._scroll_to_bottom()

	-- Also write to persistent session log via session_log module
	pcall(function()
		require("dwight.session_log").append(text)
	end)
end

--- Append a line with a specific highlight group (via extmarks).
function M.append_hl(text, hl_group)
	M.append(text)
	if not hl_group or not M._bufnr or not api.nvim_buf_is_valid(M._bufnr) then
		return
	end
	-- Highlight the line we just appended
	local line_count = api.nvim_buf_line_count(M._bufnr)
	-- Find the last line(s) we appended — text may have contained newlines
	local nlines = 1
	for _ in text:gmatch("\n") do
		nlines = nlines + 1
	end
	for i = line_count - nlines + 1, line_count do
		if i >= 1 then
			pcall(api.nvim_buf_set_extmark, M._bufnr, M._ns, i - 1, 0, {
				end_row = i - 1,
				end_col = #(api.nvim_buf_get_lines(M._bufnr, i - 1, i, false)[1] or ""),
				hl_group = hl_group,
			})
		end
	end
end

--- Append a header/separator line.
function M.header(text)
	local pad = math.max(0, 40 - #text - 4)
	M.append(string.format("── %s %s", text, string.rep("─", pad)))
end

function M._scroll_to_bottom()
	if M._winid and api.nvim_win_is_valid(M._winid) and M._bufnr and api.nvim_buf_is_valid(M._bufnr) then
		local line_count = api.nvim_buf_line_count(M._bufnr)
		pcall(api.nvim_win_set_cursor, M._winid, { line_count, 0 })
	end
end

--------------------------------------------------------------------
-- Spinner animation for active work
--------------------------------------------------------------------

--- Start a spinner with a message (e.g., "Running step 3...")
--- If spinner is already active, updates the text in-place (no new line).
function M.spin(text)
	if not M._bufnr or not api.nvim_buf_is_valid(M._bufnr) then
		M.open()
	end

	local buf = M._bufnr
	M._spinner_text = text

	-- If spinner already active, just update text in-place (keep timer running)
	if M._spinner_line and M._timer then
		local char = SPINNER[(M._spinner_idx % #SPINNER) + 1]
		pcall(function()
			local lc = api.nvim_buf_line_count(buf)
			if M._spinner_line <= lc then
				api.nvim_buf_set_lines(buf, M._spinner_line - 1, M._spinner_line, false, { char .. " " .. text })
			end
		end)
		M._scroll_to_bottom()
		return
	end

	-- Create new spinner line
	M._spinner_idx = 0

	local line_count = api.nvim_buf_line_count(buf)
	local first = line_count == 1 and api.nvim_buf_get_lines(buf, 0, 1, false)[1] == ""
	if first then
		api.nvim_buf_set_lines(buf, 0, 1, false, { SPINNER[1] .. " " .. text })
		M._spinner_line = 1
	else
		api.nvim_buf_set_lines(buf, line_count, line_count, false, { SPINNER[1] .. " " .. text })
		M._spinner_line = line_count + 1
	end

	-- Start animation timer
	M._timer = (vim.loop or vim.uv).new_timer()
	M._timer:start(
		80,
		80,
		vim.schedule_wrap(function()
			if not M._bufnr or not api.nvim_buf_is_valid(M._bufnr) or not M._spinner_line then
				M._stop_spinner()
				return
			end

			M._spinner_idx = (M._spinner_idx + 1) % #SPINNER
			local char = SPINNER[M._spinner_idx + 1]
			local new_text = char .. " " .. (M._spinner_text or "")

			pcall(function()
				local lc = api.nvim_buf_line_count(M._bufnr)
				if M._spinner_line <= lc then
					api.nvim_buf_set_lines(M._bufnr, M._spinner_line - 1, M._spinner_line, false, { new_text })
				end
			end)
		end)
	)
end

function M._stop_spinner()
	if M._timer then
		pcall(function()
			M._timer:stop()
			M._timer:close()
		end)
		M._timer = nil
	end
	M._spinner_line = nil
	M._spinner_text = nil
end

--- Stop the spinner and remove its line from the buffer.
function M.stop_spin()
	-- Remove the spinner line from the buffer so it doesn't stay as a ghost
	if M._spinner_line and M._bufnr and api.nvim_buf_is_valid(M._bufnr) then
		pcall(function()
			local lc = api.nvim_buf_line_count(M._bufnr)
			if M._spinner_line <= lc then
				api.nvim_buf_set_lines(M._bufnr, M._spinner_line - 1, M._spinner_line, false, {})
			end
		end)
	end
	M._stop_spinner()
end

--------------------------------------------------------------------
-- Session helpers
--------------------------------------------------------------------

--- Start a new agent session in the status buffer.
function M.start_session(request)
	M.open()
	M._active = true
	-- Snapshot current session cost and chars for delta tracking
	pcall(function()
		local tracker = require("dwight.tracker")
		M._session_cost_start = tracker._session.cost or 0
		M._session_chars_sent_start = tracker._session.chars_sent or 0
		M._session_chars_received_start = tracker._session.chars_received or 0
	end)

	-- Mark session in persistent log
	pcall(function()
		local slog = require("dwight.session_log")
		slog.separator("Agent: " .. request:sub(1, 100))
	end)

	M.append("")
	M.header("Agent: " .. request:sub(1, 55))
	M.append("")
end

--- Get the cost incurred since session start.
function M.session_cost()
	local current = 0
	pcall(function()
		current = require("dwight.tracker")._session.cost or 0
	end)
	return current - (M._session_cost_start or 0)
end

--- Get approximate token counts since session start.
--- Returns { input = N, output = N, total = N }
function M.session_tokens()
	local result = { input = 0, output = 0, total = 0 }
	pcall(function()
		local tracker = require("dwight.tracker")
		local chars_in = (tracker._session.chars_sent or 0) - (M._session_chars_sent_start or 0)
		local chars_out = (tracker._session.chars_received or 0) - (M._session_chars_received_start or 0)
		result.input = math.floor(chars_in / 4)
		result.output = math.floor(chars_out / 4)
		result.total = result.input + result.output
	end)
	return result
end

--- Format a cost as a string.
local function fmt_cost(c)
	if not c or c <= 0 then
		return "$0.00"
	end
	if c < 0.01 then
		return string.format("$%.4f", c)
	end
	return string.format("$%.2f", c)
end

--- Format a token count as a human-readable string (e.g., "12.5k", "1.2M").
local function fmt_tokens(n)
	if not n or n <= 0 then
		return "0"
	end
	if n >= 1000000 then
		return string.format("%.1fM", n / 1000000)
	end
	if n >= 1000 then
		return string.format("%.1fk", n / 1000)
	end
	return tostring(n)
end

--- End the session.
function M.end_session(outcome, duration)
	M._stop_spinner()
	M._active = false
	local status = outcome and "Done" or "FAILED"
	local parts = { status }
	if duration then
		parts[#parts + 1] = string.format("(%ds)", duration)
	end
	local cost = M.session_cost()
	if cost > 0 then
		parts[#parts + 1] = "~" .. fmt_cost(cost)
	end
	local tokens = M.session_tokens()
	if tokens.total > 0 then
		parts[#parts + 1] = fmt_tokens(tokens.input) .. " in / " .. fmt_tokens(tokens.output) .. " out"
	end
	M.append(table.concat(parts, " | "))

	-- Mark end in persistent log
	pcall(function()
		require("dwight.session_log").separator("Agent ended: " .. table.concat(parts, " | "))
	end)
end

--- Check if a session is active.
function M.is_active()
	return M._active
end

--- Statusline cost label (called from statusline expression).
function M._cost_label()
	if not M._active then
		return ""
	end
	local cost = M.session_cost()
	local tokens = M.session_tokens()
	local parts = {}
	if cost > 0 then
		parts[#parts + 1] = "~" .. fmt_cost(cost)
	end
	if tokens.total > 0 then
		parts[#parts + 1] = fmt_tokens(tokens.total) .. " tok"
	end
	return table.concat(parts, " ")
end

--- Get the path to the session log file.
function M.session_log_path()
	local project_ok, project = pcall(require, "dwight.project")
	if project_ok and project.is_initialized() then
		return project.dir() .. "/session.log"
	end
	return nil
end

--- Open the session log in a buffer for viewing.
function M.view_session_log()
	local path = M.session_log_path()
	if not path then
		vim.notify("[dwight] No project initialized. Run :DwightInit first.", vim.log.levels.WARN)
		return
	end

	if vim.fn.filereadable(path) ~= 1 then
		vim.notify(
			"[dwight] No session log yet. Run :DwightAuto or :DwightAgentic to generate one.",
			vim.log.levels.INFO
		)
		return
	end

	-- Open in a new split (or reuse existing buffer)
	local buf_name = "dwight://session-log"
	for _, bufnr in ipairs(api.nvim_list_bufs()) do
		if api.nvim_buf_is_loaded(bufnr) and api.nvim_buf_get_name(bufnr) == buf_name then
			local win = vim.fn.bufwinid(bufnr)
			if win ~= -1 then
				api.nvim_set_current_win(win)
			else
				vim.cmd("botright split")
				api.nvim_win_set_buf(0, bufnr)
			end
			-- Refresh content
			vim.bo[bufnr].modifiable = true
			local f = io.open(path, "r")
			if f then
				local content = f:read("*a")
				f:close()
				api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(content, "\n", { plain = true }))
			end
			vim.bo[bufnr].modifiable = false
			-- Scroll to bottom
			local lc = api.nvim_buf_line_count(bufnr)
			pcall(api.nvim_win_set_cursor, 0, { lc, 0 })
			return
		end
	end

	-- Create new buffer
	local f = io.open(path, "r")
	if not f then
		vim.notify("[dwight] Cannot read session log.", vim.log.levels.ERROR)
		return
	end
	local content = f:read("*a")
	f:close()

	local buf = api.nvim_create_buf(false, true)
	api.nvim_buf_set_name(buf, buf_name)
	api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(content, "\n", { plain = true }))
	vim.bo[buf].filetype = "dwight_status"
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].modifiable = false
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false

	vim.cmd("botright split")
	api.nvim_win_set_buf(0, buf)
	vim.cmd("resize 20")

	-- Scroll to bottom
	local lc = api.nvim_buf_line_count(buf)
	pcall(api.nvim_win_set_cursor, 0, { lc, 0 })

	-- Keymaps
	vim.keymap.set("n", "q", function()
		pcall(api.nvim_win_close, api.nvim_get_current_win(), true)
	end, { buffer = buf, desc = "Close session log" })

	vim.keymap.set("n", "r", function()
		local rf = io.open(path, "r")
		if rf then
			local fresh = rf:read("*a")
			rf:close()
			vim.bo[buf].modifiable = true
			api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(fresh, "\n", { plain = true }))
			vim.bo[buf].modifiable = false
			local new_lc = api.nvim_buf_line_count(buf)
			pcall(api.nvim_win_set_cursor, 0, { new_lc, 0 })
			vim.notify("[dwight] Session log refreshed.", vim.log.levels.INFO)
		end
	end, { buffer = buf, desc = "Refresh session log" })
end

--------------------------------------------------------------------
-- Multi-spinner support (for DwightSwarm parallel agents)
--------------------------------------------------------------------

-- Map of task_id → { line_num, text, timer }
M._spinners = {}

--- Start a spinner for a specific task (multi-spinner mode).
--- Each task_id gets its own animated line in the status buffer.
function M.spin_multi(task_id, text)
	if not M._bufnr or not api.nvim_buf_is_valid(M._bufnr) then
		M.open()
	end

	local buf = M._bufnr
	local existing = M._spinners[task_id]

	if existing and existing.timer then
		-- Update text in place
		existing.text = text
		local char = SPINNER[(existing.idx % #SPINNER) + 1]
		pcall(function()
			local lc = api.nvim_buf_line_count(buf)
			if existing.line_num and existing.line_num <= lc then
				api.nvim_buf_set_lines(
					buf,
					existing.line_num - 1,
					existing.line_num,
					false,
					{ "  " .. char .. " " .. text }
				)
			end
		end)
		return
	end

	-- Create new spinner line
	local line_count = api.nvim_buf_line_count(buf)
	local first = line_count == 1 and api.nvim_buf_get_lines(buf, 0, 1, false)[1] == ""

	local line_num
	if first then
		api.nvim_buf_set_lines(buf, 0, 1, false, { "  " .. SPINNER[1] .. " " .. text })
		line_num = 1
	else
		api.nvim_buf_set_lines(buf, line_count, line_count, false, { "  " .. SPINNER[1] .. " " .. text })
		line_num = line_count + 1
	end

	local idx = 0
	local timer = (vim.loop or vim.uv).new_timer()
	M._spinners[task_id] = { line_num = line_num, text = text, timer = timer, idx = idx }

	timer:start(
		80,
		80,
		vim.schedule_wrap(function()
			local entry = M._spinners[task_id]
			if not entry or not M._bufnr or not api.nvim_buf_is_valid(M._bufnr) then
				if entry and entry.timer then
					pcall(function()
						entry.timer:stop()
						entry.timer:close()
					end)
				end
				M._spinners[task_id] = nil
				return
			end

			entry.idx = (entry.idx + 1) % #SPINNER
			local char = SPINNER[entry.idx + 1]
			pcall(function()
				local lc = api.nvim_buf_line_count(M._bufnr)
				if entry.line_num and entry.line_num <= lc then
					api.nvim_buf_set_lines(
						M._bufnr,
						entry.line_num - 1,
						entry.line_num,
						false,
						{ "  " .. char .. " " .. (entry.text or "") }
					)
				end
			end)
		end)
	)
end

--- Stop a specific task's spinner and replace its line with a final message.
function M.stop_spin_multi(task_id, final_text)
	local entry = M._spinners[task_id]
	if not entry then
		return
	end

	if entry.timer then
		pcall(function()
			entry.timer:stop()
			entry.timer:close()
		end)
	end

	-- Replace spinner line with final text
	if final_text and M._bufnr and api.nvim_buf_is_valid(M._bufnr) then
		pcall(function()
			local lc = api.nvim_buf_line_count(M._bufnr)
			if entry.line_num and entry.line_num <= lc then
				api.nvim_buf_set_lines(M._bufnr, entry.line_num - 1, entry.line_num, false, { "  " .. final_text })
			end
		end)
	end

	M._spinners[task_id] = nil
end

--- Stop all multi-spinners.
function M.stop_spin_all()
	for task_id in pairs(M._spinners) do
		M.stop_spin_multi(task_id)
	end
	M._spinners = {}
end

--------------------------------------------------------------------
-- Fold support
--------------------------------------------------------------------

--- Custom foldtext: shows the first line of the fold (the header).
function M._foldtext()
	local foldstart = vim.v.foldstart
	local line = vim.fn.getline(foldstart)
	local fold_size = vim.v.foldend - vim.v.foldstart
	return line .. string.format("  (%d lines)", fold_size)
end

--- Append a foldable detail section (closed by default).
--- header_line: the visible summary line (e.g., "  ▸ Details (12 tool calls)")
--- detail_lines: table of strings to fold away
function M.append_fold(header_line, detail_lines)
	if not detail_lines or #detail_lines == 0 then
		return
	end
	-- Open marker
	M.append(header_line .. " ▸{{{")
	for _, line in ipairs(detail_lines) do
		M.append("    " .. line)
	end
	-- Close marker
	M.append("  ▸}}}")
end

return M
