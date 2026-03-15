-- dwight/ui/selection.lua
-- Visual selection capture.

local M = {}

local api = vim.api

function M.get_visual_selection()
	vim.cmd('noautocmd normal! "vy')
	local bufnr = api.nvim_get_current_buf()
	local start_pos = api.nvim_buf_get_mark(bufnr, "<")
	local end_pos = api.nvim_buf_get_mark(bufnr, ">")
	if start_pos[1] == 0 and end_pos[1] == 0 then
		return nil
	end

	local start_line = start_pos[1]
	local end_line = end_pos[1]
	local lines = api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
	if not lines or #lines == 0 then
		return nil
	end

	return {
		bufnr = bufnr,
		start_line = start_line,
		end_line = end_line,
		start_col = start_pos[2],
		end_col = end_pos[2],
		text = table.concat(lines, "\n"),
		lines = lines,
		filetype = vim.bo[bufnr].filetype,
		filepath = api.nvim_buf_get_name(bufnr),
	}
end

return M
