-- dwight/log.lua
-- Job logging. Every prompt is saved to a tmp file for review.
-- :DwightLog shows Telescope picker with key hints.

local M = {}

local _flatten = require("dwight.util").flatten_lines

M._entries = {}
M._max = 200
M._job_counter = 0

function M._next_id()
  M._job_counter = M._job_counter + 1
  return M._job_counter
end

local status_icons = {
  running    = "⏳",
  success    = "✅",
  no_change  = "➖",
  parse_fail = "⚠️",
  error      = "❌",
  cancelled  = "🚫",
  timeout    = "⏰",
}

--------------------------------------------------------------------
-- Recording
--------------------------------------------------------------------

function M.start(job_id, mode, bufnr, start_line, end_line, prompt)
  -- Save prompts to .dwight/prompts/ for persistence and review
  local prompt_dir
  local project_ok, project = pcall(require, "dwight.project")
  if project_ok and project.is_initialized() then
    prompt_dir = project.dir() .. "/prompts"
  else
    prompt_dir = vim.fn.stdpath("data") .. "/dwight/prompts"
  end
  vim.fn.mkdir(prompt_dir, "p")

  local timestamp = os.date("%Y%m%d-%H%M%S")
  local prompt_file = string.format("%s/%s_%s_%d.md", prompt_dir, timestamp, mode:gsub("[^%w_%-]", "-"), job_id)
  local f = io.open(prompt_file, "w")
  if f then
    f:write(string.format("-- Dwight Job #%d | Mode: %s | %s\n-- Lines %d-%d | %s\n\n",
      job_id, mode, os.date("%Y-%m-%d %H:%M:%S"),
      start_line, end_line,
      bufnr > 0 and vim.api.nvim_buf_get_name(bufnr) or "(n/a)"))
    f:write(prompt)
    f:close()
  end

  local entry = {
    id            = job_id,
    status        = "running",
    mode          = mode or "custom",
    bufnr         = bufnr,
    filepath      = bufnr > 0 and vim.api.nvim_buf_get_name(bufnr) or "",
    start_line    = start_line,
    end_line      = end_line,
    prompt        = prompt,
    prompt_file   = prompt_file,
    raw_response  = "",
    parsed_code   = nil,
    error_msg     = nil,
    started       = os.time(),
    finished      = nil,
    chars_sent    = #prompt,
    chars_received = 0,
  }

  table.insert(M._entries, 1, entry)
  while #M._entries > M._max do table.remove(M._entries) end
  return entry
end

function M.find(job_id)
  for _, entry in ipairs(M._entries) do
    if entry.id == job_id then return entry end
  end
  return nil
end

function M.finish(job_id, status, raw_response, parsed_code, error_msg)
  local entry = M.find(job_id)
  if not entry then return end
  entry.status = status
  entry.raw_response = raw_response or ""
  entry.parsed_code = parsed_code
  entry.error_msg = error_msg
  entry.finished = os.time()
  entry.chars_received = #(raw_response or "")

  if entry.prompt_file then
    local f = io.open(entry.prompt_file, "a")
    if f then
      f:write("\n\n-- ═══ RESPONSE ═══\n")
      f:write(string.format("-- Status: %s | Received: %d chars\n\n", status, entry.chars_received))
      f:write(raw_response or "")
      if error_msg then f:write("\n\n-- ERROR: " .. error_msg) end
      f:close()
    end
  end
end

function M.append_note(job_id, note)
  local entry = M.find(job_id)
  if not entry then return end
  if entry.prompt_file then
    local f = io.open(entry.prompt_file, "a")
    if f then
      f:write("\n\n-- ─── NOTE ───\n")
      f:write(note or "")
      f:close()
    end
  end
end

--- Set metadata on a log entry (model, backend, tokens, cost, etc.)
function M.set_metadata(job_id, meta)
  local entry = M.find(job_id)
  if not entry then return end
  if meta.model then entry.model = meta.model end
  if meta.backend then entry.backend = meta.backend end
  if meta.provider_name then entry.provider_name = meta.provider_name end
  if meta.tokens_in then entry.tokens_in = meta.tokens_in end
  if meta.tokens_out then entry.tokens_out = meta.tokens_out end
  if meta.cost then entry.cost = meta.cost end
end

--------------------------------------------------------------------
-- Display
--------------------------------------------------------------------

local function format_entry(entry)
  local icon = status_icons[entry.status] or "?"
  local file = entry.filepath ~= "" and vim.fn.fnamemodify(entry.filepath, ":t") or "—"
  local elapsed = entry.finished and (entry.finished - entry.started) or (os.time() - entry.started)
  local meta = ""
  if entry.model then meta = " [" .. entry.model .. "]" end
  if entry.tokens_in and entry.tokens_out then
    meta = meta .. string.format(" (%d→%d tok)", entry.tokens_in, entry.tokens_out)
  end
  return string.format("%s #%d %s %s:%d-%d (%ds)%s [%s]",
    icon, entry.id, entry.mode, file, entry.start_line, entry.end_line, elapsed, meta, entry.status)
end

function M.show()
  if #M._entries == 0 then
    vim.notify("[dwight] No jobs logged yet.", vim.log.levels.INFO)
    return
  end
  local has_telescope, _ = pcall(require, "telescope")
  if has_telescope then M._show_telescope() else M._show_native() end
end

function M._show_native()
  local items = {}
  for _, entry in ipairs(M._entries) do items[#items + 1] = format_entry(entry) end
  require("dwight.select").pick(items, { prompt = "Job Log:" }, function(_, idx)
    if idx then M._inspect(M._entries[idx]) end
  end)
end

function M._show_telescope()
  local pickers     = require("telescope.pickers")
  local finders     = require("telescope.finders")
  local conf        = require("telescope.config").values
  local actions     = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local previewers  = require("telescope.previewers")

  pickers.new({}, {
    -- KEY HINTS: shown directly in the Telescope prompt title
    prompt_title = "🗂 Dwight Log  ⏎ jump  ^O open file  ^K kill  ^Y copy response",
    finder = finders.new_table({
      results = M._entries,
      entry_maker = function(entry)
        return {
          value = entry, display = format_entry(entry),
          ordinal = string.format("%d %s %s", entry.id, entry.mode, entry.status),
        }
      end,
    }),
    sorter = conf.generic_sorter({}),
    previewer = previewers.new_buffer_previewer({
      title = "Job Details  (^O open prompt file)",
      define_preview = function(self, telescope_entry)
        local raw_lines = M._format_detail(telescope_entry.value)
        -- Flatten: some fields (error_msg, etc.) may contain embedded newlines
        -- which nvim_buf_set_lines rejects
        local lines = {}
        for _, line in ipairs(raw_lines) do
          if line:find("\n") then
            for sub in (line .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = sub end
          else
            lines[#lines + 1] = line
          end
        end
        vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, _flatten(lines))
        vim.bo[self.state.bufnr].filetype = "markdown"
      end,
    }),
    attach_mappings = function(prompt_bufnr, map_fn)
      -- Enter: jump to the code location
      actions.select_default:replace(function()
        local entry = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if entry then M._jump_to(entry.value) end
      end)

      -- Ctrl-O: open the full prompt+response tmp file
      map_fn("i", "<C-o>", function()
        local entry = action_state.get_selected_entry()
        if entry and entry.value.prompt_file then
          actions.close(prompt_bufnr)
          vim.cmd("edit " .. vim.fn.fnameescape(entry.value.prompt_file))
        end
      end)
      map_fn("n", "<C-o>", function()
        local entry = action_state.get_selected_entry()
        if entry and entry.value.prompt_file then
          actions.close(prompt_bufnr)
          vim.cmd("edit " .. vim.fn.fnameescape(entry.value.prompt_file))
        end
      end)

      -- Ctrl-K: kill a running job
      map_fn("i", "<C-k>", function()
        local entry = action_state.get_selected_entry()
        if entry and entry.value.status == "running" then
          local dwight = require("dwight")
          local job = dwight._active_jobs[entry.value.id]
          if job then
            dwight._kill_job(entry.value.id, job)
            vim.notify("[dwight] Job #" .. entry.value.id .. " cancelled.", vim.log.levels.INFO)
          end
        end
      end)

      -- Ctrl-Y: yank the raw response to clipboard
      map_fn("i", "<C-y>", function()
        local entry = action_state.get_selected_entry()
        if entry and entry.value.raw_response ~= "" then
          vim.fn.setreg("+", entry.value.raw_response)
          vim.notify("[dwight] Response copied to clipboard.", vim.log.levels.INFO)
        end
      end)

      return true
    end,
  }):find()
end

function M._format_detail(e)
  local lines = {
    "# Job #" .. e.id,
    "",
    "**Status:** " .. (status_icons[e.status] or "") .. " " .. e.status,
    "**Mode:** " .. e.mode,
    "**File:** " .. (e.filepath ~= "" and e.filepath or "n/a"),
    "**Lines:** " .. e.start_line .. "-" .. e.end_line,
    "**Duration:** " .. (e.finished and (e.finished - e.started) .. "s" or "running…"),
    "**Prompt file:** " .. (e.prompt_file or "n/a"),
  }

  -- Metadata: model, backend, tokens (if set)
  if e.model or e.backend or e.tokens_in then
    lines[#lines + 1] = ""
    if e.backend then lines[#lines + 1] = "**Backend:** " .. e.backend end
    if e.model then lines[#lines + 1] = "**Model:** " .. e.model end
    if e.provider_name then lines[#lines + 1] = "**Provider:** " .. e.provider_name end
    if e.tokens_in and e.tokens_out then
      lines[#lines + 1] = string.format("**Tokens:** %d in / %d out", e.tokens_in, e.tokens_out)
    end
    if e.cost and e.cost > 0 then
      lines[#lines + 1] = string.format("**Cost:** $%.4f", e.cost)
    end
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "---"
  lines[#lines + 1] = "Keys: **^O** open prompt file | **^K** kill job | **^Y** copy response"
  lines[#lines + 1] = "---"
  lines[#lines + 1] = ""

  if e.error_msg then
    lines[#lines + 1] = "## Error"
    lines[#lines + 1] = "```"
    lines[#lines + 1] = e.error_msg
    lines[#lines + 1] = "```"
    lines[#lines + 1] = ""
  end

  lines[#lines + 1] = "## Prompt (first 60 lines)"
  lines[#lines + 1] = "```"
  local prompt_lines = vim.split(e.prompt, "\n")
  for i = 1, math.min(60, #prompt_lines) do lines[#lines + 1] = prompt_lines[i] end
  if #prompt_lines > 60 then lines[#lines + 1] = "... (" .. (#prompt_lines - 60) .. " more)" end
  lines[#lines + 1] = "```"
  lines[#lines + 1] = ""

  if e.raw_response ~= "" then
    lines[#lines + 1] = "## Response (first 40 lines)"
    lines[#lines + 1] = "```"
    local resp_lines = vim.split(e.raw_response, "\n")
    for i = 1, math.min(40, #resp_lines) do lines[#lines + 1] = resp_lines[i] end
    if #resp_lines > 40 then lines[#lines + 1] = "... (" .. (#resp_lines - 40) .. " more)" end
    lines[#lines + 1] = "```"
  end

  return lines
end

function M._inspect(entry)
  local raw_lines = M._format_detail(entry)
  local lines = {}
  for _, line in ipairs(raw_lines) do
    if line:find("\n") then
      for sub in (line .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = sub end
    else
      lines[#lines + 1] = line
    end
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, _flatten(lines))
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"

  local width = math.min(100, vim.o.columns - 10)
  local height = math.min(#lines + 2, vim.o.lines - 6)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor", width = width, height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal", border = require("dwight").config.border,
    title = " Job #" .. entry.id .. " · o: open file · g: go to code · q: close ",
    title_pos = "center",
  })

  local opts = { buffer = buf }
  vim.keymap.set("n", "q", function() vim.api.nvim_win_close(win, true) end, opts)
  vim.keymap.set("n", "<Esc>", function() vim.api.nvim_win_close(win, true) end, opts)
  vim.keymap.set("n", "o", function()
    vim.api.nvim_win_close(win, true)
    if entry.prompt_file then
      vim.cmd("edit " .. vim.fn.fnameescape(entry.prompt_file))
    end
  end, opts)
  vim.keymap.set("n", "g", function()
    vim.api.nvim_win_close(win, true)
    M._jump_to(entry)
  end, opts)
end

function M._jump_to(entry)
  if entry.filepath and entry.filepath ~= "" then
    local buf = vim.fn.bufnr(entry.filepath)
    if buf == -1 then
      vim.cmd("edit " .. vim.fn.fnameescape(entry.filepath))
    else
      vim.api.nvim_set_current_buf(buf)
    end
    if entry.start_line > 0 then
      pcall(vim.api.nvim_win_set_cursor, 0, { entry.start_line, 0 })
    end
  end
end

return M
