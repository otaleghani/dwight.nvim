-- dwight/inline/buffer.lua
-- Atomic buffer replacement with undo integration and highlight flash.

local M = {}

function M._replace_selection_atomic(bufnr, start_line, end_line, new_text)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	local new_lines = vim.split(new_text, "\n", { plain = true })

	-- Ensure buffer is modifiable
	local was_modifiable = vim.bo[bufnr].modifiable
	if not was_modifiable then
		vim.bo[bufnr].modifiable = true
	end

	local eventignore = vim.o.eventignore
	vim.o.eventignore = "all"

	local current_line_count = vim.api.nvim_buf_line_count(bufnr)
	if end_line > current_line_count then
		end_line = current_line_count
	end

	if vim.api.nvim_get_current_buf() == bufnr then
		pcall(vim.cmd, "undojoin")
	end
	vim.api.nvim_buf_set_lines(bufnr, start_line - 1, end_line, false, new_lines)
	vim.o.eventignore = eventignore

	-- Restore modifiable state if we changed it
	if not was_modifiable then
		vim.bo[bufnr].modifiable = was_modifiable
	end

	local ns = vim.api.nvim_create_namespace("dwight_replace_" .. start_line .. "_" .. os.time())
	local new_end = start_line - 1 + #new_lines
	for i = start_line - 1, math.min(new_end - 1, vim.api.nvim_buf_line_count(bufnr) - 1) do
		pcall(vim.api.nvim_buf_add_highlight, bufnr, ns, "DwightReplace", i, 0, -1)
	end
	vim.defer_fn(function()
		if vim.api.nvim_buf_is_valid(bufnr) then
			vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
		end
	end, 3000)
end

return M
