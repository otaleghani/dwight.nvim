-- dwight/util.lua
-- Shared utilities used across Dwight modules.

local M = {}

local api = vim.api

--------------------------------------------------------------------
-- Safe buffer line operations
--------------------------------------------------------------------

--- Flatten a lines array so no element contains embedded newlines.
--- nvim_buf_set_lines will error if any string in the array has \n.
--- This is the root cause of a recurring crash pattern across Dwight.
---
--- @param lines string[] — array of strings, some may contain \n
--- @return string[] — flat array where every element is a single line
function M.flatten_lines(lines)
	local out = {}
	for _, line in ipairs(lines) do
		if type(line) ~= "string" then
			out[#out + 1] = tostring(line)
		elseif line:find("\n") then
			for sub in (line .. "\n"):gmatch("([^\n]*)\n") do
				out[#out + 1] = sub
			end
		else
			out[#out + 1] = line
		end
	end
	return out
end

--- Safe wrapper around nvim_buf_set_lines.
--- Automatically flattens any embedded newlines in the lines array.
--- Drop-in replacement: same signature as nvim_buf_set_lines.
---
--- @param bufnr integer
--- @param start integer — 0-indexed start line
--- @param end_ integer — 0-indexed end line (-1 for end of buffer)
--- @param strict boolean
--- @param lines string[]
function M.buf_set_lines(bufnr, start, end_, strict, lines)
	api.nvim_buf_set_lines(bufnr, start, end_, strict, M.flatten_lines(lines))
end

--- Sanitize a string for use in a single nvim_buf_set_lines element.
--- Replaces newlines with spaces. Useful for titles, labels, spinner text.
---
--- @param s string
--- @return string
function M.oneline(s)
	if not s then
		return ""
	end
	return tostring(s):gsub("\n", " "):gsub("\r", "")
end

--------------------------------------------------------------------
-- Shared TUI helpers
--------------------------------------------------------------------

--- Define shared highlight groups. Idempotent — safe to call from anywhere.
function M.ensure_highlights()
	vim.cmd([[
    highlight default link DwightOK DiagnosticOk
    highlight default link DwightFail DiagnosticError
    highlight default link DwightSkip Comment
    highlight default link DwightDim NonText
    highlight default link DwightHeader Title
    highlight default link DwightSpin DiagnosticInfo
    highlight default link DwightWarn DiagnosticWarn
    highlight default link DwightCost Special
  ]])
end

--- Return a TUI header string: "── Text ────────────"
--- @param text string
--- @param width? integer default 60
--- @return string
function M.tui_header(text, width)
	width = width or 60
	local prefix = "── " .. text .. " "
	local pad = math.max(0, width - #prefix)
	return prefix .. string.rep("─", pad)
end

--- Apply shared TUI syntax highlighting to a buffer.
--- @param buf integer
function M.apply_tui_syntax(buf)
	M.ensure_highlights()
	pcall(function()
		api.nvim_buf_call(buf, function()
			vim.cmd([[
        syntax match DwightHeader /^──.*$/
        syntax match DwightOK /.*●.*/
        syntax match DwightFail /.*✗.*/
        syntax match DwightSkip /.*○.*/
        syntax match DwightCost /\$[0-9,.]\+/
        syntax match DwightWarn /◐/
        syntax match DwightOK /[█░]\+/
      ]])
		end)
	end)
end

--- Configure a window for the TUI style (folds, no line numbers, etc.).
--- @param win integer
--- @param opts? { foldlevel?: integer }
function M.setup_tui_win(win, opts)
	opts = opts or {}
	if not api.nvim_win_is_valid(win) then
		return
	end
	vim.wo[win].number = false
	vim.wo[win].relativenumber = false
	vim.wo[win].signcolumn = "no"
	vim.wo[win].wrap = true
	vim.wo[win].cursorline = false
	vim.wo[win].foldmethod = "marker"
	vim.wo[win].foldmarker = "▸{{{,▸}}}"
	vim.wo[win].foldenable = true
	vim.wo[win].foldlevel = opts.foldlevel or 0
end

return M
