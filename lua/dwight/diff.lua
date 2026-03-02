-- dwight/diff.lua
-- Diff preview: show changes in a split before applying.
-- User accepts/rejects with keymaps. Replaces direct buffer writes.

local M = {}

local api = vim.api

--------------------------------------------------------------------
-- Show diff between original and proposed code
--------------------------------------------------------------------

--- Show a split diff for proposed changes.
--- Returns without applying — user accepts with <CR> or rejects with q.
function M.show(bufnr, start_line, end_line, new_text, on_accept, on_reject)
  if not api.nvim_buf_is_valid(bufnr) then return end

  local original_lines = api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
  local new_lines = vim.split(new_text, "\n", { plain = true })

  -- Quick check: no change
  if table.concat(original_lines, "\n") == table.concat(new_lines, "\n") then
    if on_reject then on_reject("no_change") end
    return
  end

  local source_name = api.nvim_buf_get_name(bufnr)
  local filetype = vim.bo[bufnr].filetype

  -- Create two scratch buffers
  local orig_buf = api.nvim_create_buf(false, true)
  local new_buf = api.nvim_create_buf(false, true)

  api.nvim_buf_set_lines(orig_buf, 0, -1, false, original_lines)
  api.nvim_buf_set_lines(new_buf, 0, -1, false, new_lines)

  vim.bo[orig_buf].filetype = filetype
  vim.bo[new_buf].filetype = filetype
  vim.bo[orig_buf].bufhidden = "wipe"
  vim.bo[new_buf].bufhidden = "wipe"
  vim.bo[orig_buf].modifiable = false
  vim.bo[new_buf].modifiable = false

  -- Save current window layout
  local prev_win = api.nvim_get_current_win()

  -- Open in a new tab to avoid disrupting layout
  vim.cmd("tabnew")
  local tab = api.nvim_get_current_tabpage()
  local left_win = api.nvim_get_current_win()

  api.nvim_win_set_buf(left_win, orig_buf)
  vim.cmd("diffthis")

  vim.cmd("vsplit")
  local right_win = api.nvim_get_current_win()
  api.nvim_win_set_buf(right_win, new_buf)
  vim.cmd("diffthis")

  -- Set titles
  pcall(function()
    api.nvim_buf_set_name(orig_buf, "dwight://original")
    api.nvim_buf_set_name(new_buf, "dwight://proposed")
  end)

  -- Status line info
  local short_file = vim.fn.fnamemodify(source_name, ":t")
  local info = string.format(" dwight diff · %s · lines %d-%d · %d→%d lines ",
    short_file, start_line, end_line, #original_lines, #new_lines)

  -- Keymaps: accept or reject
  local closed = false
  local function cleanup()
    if closed then return end
    closed = true
    pcall(function()
      vim.cmd("tabclose")
      if api.nvim_win_is_valid(prev_win) then
        api.nvim_set_current_win(prev_win)
      end
    end)
  end

  local function accept()
    cleanup()
    if on_accept then on_accept() end
  end

  local function reject()
    cleanup()
    if on_reject then on_reject("rejected") end
  end

  for _, buf in ipairs({ orig_buf, new_buf }) do
    vim.keymap.set("n", "<CR>", accept, { buffer = buf, desc = "Accept changes" })
    vim.keymap.set("n", "y", accept, { buffer = buf, desc = "Accept changes" })
    vim.keymap.set("n", "q", reject, { buffer = buf, desc = "Reject changes" })
    vim.keymap.set("n", "n", reject, { buffer = buf, desc = "Reject changes" })
    vim.keymap.set("n", "<Esc>", reject, { buffer = buf, desc = "Reject changes" })
  end

  -- Show instructions
  vim.schedule(function()
    vim.notify(info .. "  <CR>/y accept  |  q/n reject", vim.log.levels.INFO)
  end)
end

return M
