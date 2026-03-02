-- dwight/multifile.lua
-- Multi-file change engine. Parses structured output, applies across buffers,
-- shows changes in quickfix list, supports atomic undo.
-- Used by: code generation, bootstrap, execute.

local M = {}

local api = vim.api

--------------------------------------------------------------------
-- Parse multi-file output
-- Supports two formats:
--   1. XML: <changes><file path="..." action="...">...</file></changes>
--   2. Fenced: ```lang:filepath\n...\n```  (legacy, 2+ files)
--------------------------------------------------------------------

--- Parse XML <changes> format.
--- Returns list of { path, action, content, lines } or nil.
function M.parse_xml(raw)
  if not raw or not raw:find("<changes>") then return nil end

  local changes_block = raw:match("<changes>(.-)</changes>")
  if not changes_block then return nil end

  local files = {}
  -- Match <file path="..." action="..." lines="...">...</file>
  for attrs, content in changes_block:gmatch('<file%s+(.-)>(.-)</file>') do
    local path = attrs:match('path="([^"]+)"')
    local action = attrs:match('action="([^"]+)"') or "edit"
    local lines_range = attrs:match('lines="([^"]+)"')

    if path then
      local entry = {
        path = vim.trim(path),
        action = action:lower(),
        content = vim.trim(content),
      }

      if lines_range then
        local s, e = lines_range:match("(%d+)%-(%d+)")
        if s then
          entry.start_line = tonumber(s)
          entry.end_line = tonumber(e)
        end
      end

      files[#files + 1] = entry
    end
  end

  if #files == 0 then return nil end
  return files
end

--- Parse fenced code block format: ```lang:filepath
--- Returns list or nil (only if 2+ files found).
function M.parse_fenced(raw)
  if not raw then return nil end
  local files = {}
  for lang, path, code in raw:gmatch("```(%w+):([^\n]+)\n(.-)\n```") do
    path = vim.trim(path)
    code = code:gsub("^\n+", ""):gsub("\n+$", "")
    if path ~= "" and code ~= "" then
      files[#files + 1] = {
        path = path,
        action = "create",  -- fenced format implies full file
        content = code,
        lang = lang,
      }
    end
  end
  if #files < 2 then return nil end
  return files
end

--- Try both parsers. XML takes priority.
function M.parse(raw)
  return M.parse_xml(raw) or M.parse_fenced(raw)
end

--------------------------------------------------------------------
-- Undo tracking: save changenr per buffer before changes,
-- plus track created files (delete on undo) and deleted files (restore on undo).
--------------------------------------------------------------------

local _undo_state = {}

local function save_undo_state(buffers)
  local state = {
    buffers = {},       -- bufnr → changenr (for vim undo of edits)
    created_files = {}, -- list of full paths created (delete on undo)
    deleted_files = {}, -- list of { path = full_path, content = file_content } (restore on undo)
  }
  for _, bufnr in ipairs(buffers) do
    if api.nvim_buf_is_valid(bufnr) then
      api.nvim_buf_call(bufnr, function()
        state.buffers[bufnr] = vim.fn.changenr()
      end)
    end
  end
  _undo_state = state
  return state
end

--- Track a file that was created during this operation (will be deleted on undo).
local function track_created_file(full_path)
  if not _undo_state.created_files then _undo_state.created_files = {} end
  _undo_state.created_files[#_undo_state.created_files + 1] = full_path
end

--- Snapshot a file's content before it's deleted (will be restored on undo).
local function track_deleted_file(full_path)
  if not _undo_state.deleted_files then _undo_state.deleted_files = {} end
  local f = io.open(full_path, "r")
  if f then
    local content = f:read("*a")
    f:close()
    _undo_state.deleted_files[#_undo_state.deleted_files + 1] = {
      path = full_path,
      content = content,
    }
  end
end

--- Revert all buffers to their pre-change state, delete created files, restore deleted files.
--- If an agent snapshot exists, use that instead (covers entire agent session).
function M.undo_all()
  -- Agent snapshot takes priority — it covers the entire execution
  if M.has_agent_snapshot() then
    local ok, restored, deleted = M.undo_agent()
    if ok then
      local parts = {}
      if restored > 0 then parts[#parts + 1] = string.format("restored %d file(s)", restored) end
      if deleted > 0 then parts[#parts + 1] = string.format("removed %d created file(s)", deleted) end
      if #parts == 0 then parts[#parts + 1] = "no changes found" end
      vim.notify("[dwight] Agent undo: " .. table.concat(parts, ", ") .. ".", vim.log.levels.INFO)
      _undo_state = {}
      return
    end
  end

  if not _undo_state.buffers and not _undo_state.created_files and not _undo_state.deleted_files then
    vim.notify("[dwight] No multi-file changes to undo.", vim.log.levels.INFO)
    return
  end

  local reverted = 0

  -- 1. Revert buffer edits
  for bufnr, changenr in pairs(_undo_state.buffers or {}) do
    if api.nvim_buf_is_valid(bufnr) then
      api.nvim_buf_call(bufnr, function()
        pcall(vim.cmd, "undo " .. changenr)
        pcall(vim.cmd, "silent! write")
      end)
      reverted = reverted + 1
    end
  end

  -- 2. Delete files that were created
  local deleted = 0
  for _, full_path in ipairs(_undo_state.created_files or {}) do
    if vim.fn.filereadable(full_path) == 1 then
      -- Close any open buffer for this file
      for _, bufnr in ipairs(api.nvim_list_bufs()) do
        if api.nvim_buf_is_loaded(bufnr) and api.nvim_buf_get_name(bufnr) == full_path then
          pcall(api.nvim_buf_delete, bufnr, { force = true })
        end
      end
      os.remove(full_path)
      deleted = deleted + 1
    end
  end

  -- 3. Restore files that were deleted
  local restored = 0
  for _, entry in ipairs(_undo_state.deleted_files or {}) do
    local dir = vim.fn.fnamemodify(entry.path, ":h")
    vim.fn.mkdir(dir, "p")
    local f = io.open(entry.path, "w")
    if f then
      f:write(entry.content)
      f:close()
      restored = restored + 1
    end
  end

  _undo_state = {}

  local parts = {}
  if reverted > 0 then parts[#parts + 1] = string.format("reverted %d edit(s)", reverted) end
  if deleted > 0 then parts[#parts + 1] = string.format("removed %d created file(s)", deleted) end
  if restored > 0 then parts[#parts + 1] = string.format("restored %d deleted file(s)", restored) end
  vim.notify("[dwight] Undo: " .. table.concat(parts, ", ") .. ".", vim.log.levels.INFO)
end

--------------------------------------------------------------------
-- Agent snapshot: pre-execution filesystem state for full undo
-- Used by DwightAgent to snapshot all files before execution begins,
-- so DwightMultiUndo can restore the entire repo to pre-agent state.
--------------------------------------------------------------------

local _agent_snapshot = nil

--- Snapshot files that will be touched by an agent plan.
--- Call this BEFORE execution starts with all file paths from the plan's actions.
--- @param paths table list of relative file paths from plan actions
function M.snapshot_agent(paths)
  local cwd = vim.fn.getcwd() .. "/"
  local snapshot = {
    originals = {},    -- { path = full_path, content = string } for existing files
    new_paths = {},    -- full paths of files that don't exist yet (to delete on undo)
  }

  local seen = {}
  for _, path in ipairs(paths) do
    local full = path:match("^/") and path or (cwd .. path)
    if not seen[full] then
      seen[full] = true
      if vim.fn.filereadable(full) == 1 then
        local f = io.open(full, "r")
        if f then
          snapshot.originals[#snapshot.originals + 1] = { path = full, content = f:read("*a") }
          f:close()
        end
      else
        snapshot.new_paths[#snapshot.new_paths + 1] = full
      end
    end
  end

  _agent_snapshot = snapshot
end

--- Undo all agent changes: restore original files, delete created files.
--- Called by DwightMultiUndo when an agent snapshot exists.
function M.undo_agent()
  if not _agent_snapshot then return false end

  local restored = 0
  local deleted = 0

  -- Restore original file contents
  for _, entry in ipairs(_agent_snapshot.originals) do
    local f = io.open(entry.path, "w")
    if f then
      f:write(entry.content)
      f:close()
      restored = restored + 1
      -- Reload buffer if open
      for _, bufnr in ipairs(api.nvim_list_bufs()) do
        if api.nvim_buf_is_loaded(bufnr) and api.nvim_buf_get_name(bufnr) == entry.path then
          pcall(function()
            api.nvim_buf_call(bufnr, function() vim.cmd("edit!") end)
          end)
        end
      end
    end
  end

  -- Delete files that were created by the agent
  for _, full_path in ipairs(_agent_snapshot.new_paths) do
    if vim.fn.filereadable(full_path) == 1 then
      -- Close buffer
      for _, bufnr in ipairs(api.nvim_list_bufs()) do
        if api.nvim_buf_is_loaded(bufnr) and api.nvim_buf_get_name(bufnr) == full_path then
          pcall(api.nvim_buf_delete, bufnr, { force = true })
        end
      end
      os.remove(full_path)
      deleted = deleted + 1
    end
  end

  _agent_snapshot = nil
  return true, restored, deleted
end

--- Check if an agent snapshot exists.
function M.has_agent_snapshot()
  return _agent_snapshot ~= nil
end

--------------------------------------------------------------------
-- Apply changes: create/edit/delete files, populate quickfix
--------------------------------------------------------------------

--- Resolve path relative to cwd.
local function resolve_path(path)
  if path:match("^/") then return path end
  return vim.fn.getcwd() .. "/" .. path
end

--- Get or create a buffer for a file path.
local function get_or_create_buffer(path)
  local full = resolve_path(path)

  -- Check if already open
  for _, bufnr in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(bufnr) and api.nvim_buf_get_name(bufnr) == full then
      return bufnr
    end
  end

  -- Ensure directory exists
  local dir = vim.fn.fnamemodify(full, ":h")
  vim.fn.mkdir(dir, "p")

  -- Create file if it doesn't exist
  if vim.fn.filereadable(full) ~= 1 then
    local f = io.open(full, "w")
    if f then f:write(""); f:close() end
  end

  -- Open buffer
  local bufnr = vim.fn.bufadd(full)
  vim.fn.bufload(bufnr)
  return bufnr
end

--- Apply a single file change. Returns quickfix entry or nil.
function M.apply_one(change)
  local full_path = resolve_path(change.path)
  local rel_path = change.path

  if change.action == "delete" then
    -- Snapshot content before deletion (for undo restore)
    track_deleted_file(full_path)
    os.remove(full_path)
    -- Close any open buffer
    for _, bufnr in ipairs(api.nvim_list_bufs()) do
      if api.nvim_buf_is_loaded(bufnr) and api.nvim_buf_get_name(bufnr) == full_path then
        pcall(api.nvim_buf_delete, bufnr, { force = true })
      end
    end
    return { filename = full_path, lnum = 1, text = "[deleted] " .. rel_path }
  end

  if change.action == "create" then
    local dir = vim.fn.fnamemodify(full_path, ":h")
    vim.fn.mkdir(dir, "p")

    -- Track for undo: if this file didn't exist before, mark it as created
    local is_new = vim.fn.filereadable(full_path) ~= 1
    local f = io.open(full_path, "w")
    if not f then return nil end
    f:write(change.content .. "\n"); f:close()
    if is_new then track_created_file(full_path) end

    -- Reload buffer if open
    local bufnr = vim.fn.bufadd(full_path)
    vim.fn.bufload(bufnr)
    pcall(function()
      api.nvim_buf_call(bufnr, function() vim.cmd("edit!") end)
    end)

    local line_count = select(2, change.content:gsub("\n", "")) + 1
    return { filename = full_path, lnum = 1, text = string.format("[created] %s (%d lines)", rel_path, line_count) }
  end

  if change.action == "edit" then
    local bufnr = get_or_create_buffer(change.path)
    if not api.nvim_buf_is_valid(bufnr) then return nil end

    local new_lines = vim.split(change.content, "\n", { plain = true })

    if change.start_line and change.end_line then
      -- Replace specific line range
      local line_count = api.nvim_buf_line_count(bufnr)
      local s = math.max(0, change.start_line - 1)
      local e = math.min(line_count, change.end_line)
      api.nvim_buf_set_lines(bufnr, s, e, false, new_lines)

      return {
        filename = full_path,
        lnum = change.start_line,
        text = string.format("[edited] %s lines %d-%d (%d → %d lines)",
          rel_path, change.start_line, change.end_line,
          change.end_line - change.start_line + 1, #new_lines),
      }
    else
      -- Replace entire file content
      api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)
      return {
        filename = full_path,
        lnum = 1,
        text = string.format("[edited] %s (full file, %d lines)", rel_path, #new_lines),
      }
    end
  end

  -- Unknown action: treat as create
  return M.apply_one(vim.tbl_extend("force", change, { action = "create" }))
end

--- Apply all changes. Returns { applied_count, qf_entries }.
--- Saves undo state before applying, writes all changes to disk.
function M.apply_all(changes, opts)
  opts = opts or {}
  local qf_entries = {}

  -- Collect buffers that will be affected
  local affected_buffers = {}
  for _, change in ipairs(changes) do
    if change.action ~= "delete" then
      local full = resolve_path(change.path)
      for _, bufnr in ipairs(api.nvim_list_bufs()) do
        if api.nvim_buf_is_loaded(bufnr) and api.nvim_buf_get_name(bufnr) == full then
          affected_buffers[#affected_buffers + 1] = bufnr
        end
      end
    end
  end

  -- Save undo state
  save_undo_state(affected_buffers)

  -- Apply each change
  local applied = 0
  local modified_buffers = {}
  for _, change in ipairs(changes) do
    local entry = M.apply_one(change)
    if entry then
      qf_entries[#qf_entries + 1] = entry
      applied = applied + 1
      -- Track buffers that were modified (for disk write)
      if change.action == "edit" then
        local full = resolve_path(change.path)
        for _, bufnr in ipairs(api.nvim_list_bufs()) do
          if api.nvim_buf_is_loaded(bufnr) and api.nvim_buf_get_name(bufnr) == full then
            modified_buffers[bufnr] = true
          end
        end
      end
    end
  end

  -- Write all modified buffers to disk (create already writes via io.open)
  for bufnr, _ in pairs(modified_buffers) do
    if api.nvim_buf_is_valid(bufnr) then
      pcall(function()
        api.nvim_buf_call(bufnr, function() vim.cmd("silent! write") end)
      end)
    end
  end

  -- Populate quickfix list
  if #qf_entries > 0 and opts.quickfix ~= false then
    vim.fn.setqflist({}, "r", {
      title = "dwight: multi-file changes",
      items = qf_entries,
    })
    vim.cmd("copen")
    vim.notify(string.format("[dwight] ✅ Applied %d change(s). Quickfix open. :DwightMultiUndo to revert.",
      applied), vim.log.levels.INFO)
  end

  return applied, qf_entries
end

--------------------------------------------------------------------
-- Diff preview: show all changes before applying
--------------------------------------------------------------------

--- Show a preview of all changes in a scratch buffer.
--- User accepts or rejects from there.
function M.preview(changes, on_accept, on_reject)
  if not changes or #changes == 0 then
    if on_reject then on_reject() end
    return
  end

  -- Build quickfix entries from changes
  local qf_items = {}
  local cwd = vim.fn.getcwd()

  for i, change in ipairs(changes) do
    local icon = ({ create = "🆕", edit = "✏️", delete = "🗑️" })[change.action] or "📄"
    local preview_text = ""
    if change.content then
      local first_lines = {}
      local n = 0
      for line in change.content:gmatch("[^\n]+") do
        first_lines[#first_lines + 1] = line
        n = n + 1
        if n >= 3 then break end
      end
      local total = select(2, change.content:gsub("\n", "")) + 1
      preview_text = table.concat(first_lines, " │ ")
      if total > 3 then
        preview_text = preview_text .. string.format(" (+%d lines)", total - 3)
      end
    end

    local lnum = change.start_line or 1
    local full_path = change.path
    if full_path:sub(1, 1) ~= "/" then
      full_path = cwd .. "/" .. full_path
    end

    qf_items[#qf_items + 1] = {
      filename = full_path,
      lnum = lnum,
      text = string.format("%s [%s] %s", icon, change.action, preview_text),
    }
  end

  -- Set quickfix list
  vim.fn.setqflist({}, "r", {
    title = string.format("Dwight: %d file change(s)  —  :DwightAccept / :DwightReject", #changes),
    items = qf_items,
  })
  vim.cmd("botright copen")

  -- Summary line in status
  local summary_parts = {}
  local counts = { create = 0, edit = 0, delete = 0 }
  for _, c in ipairs(changes) do counts[c.action] = (counts[c.action] or 0) + 1 end
  if counts.create > 0 then summary_parts[#summary_parts + 1] = counts.create .. " new" end
  if counts.edit > 0 then summary_parts[#summary_parts + 1] = counts.edit .. " edit" end
  if counts.delete > 0 then summary_parts[#summary_parts + 1] = counts.delete .. " delete" end

  vim.notify(string.format(
    "[dwight] 📋 %d file change(s) (%s). Review in quickfix.\n" ..
    "  :DwightAccept to apply  |  :DwightReject to discard  |  <CR> to jump to file",
    #changes, table.concat(summary_parts, ", ")),
    vim.log.levels.INFO)

  -- Register one-shot commands for accept/reject
  local resolved = false
  local function resolve(accept)
    if resolved then return end
    resolved = true
    -- Clean up commands
    pcall(vim.api.nvim_del_user_command, "DwightAccept")
    pcall(vim.api.nvim_del_user_command, "DwightReject")
    vim.cmd("cclose")
    if accept and on_accept then
      on_accept()
    elseif on_reject then
      on_reject()
    end
  end

  -- Create temporary global commands
  pcall(vim.api.nvim_del_user_command, "DwightAccept")
  pcall(vim.api.nvim_del_user_command, "DwightReject")
  vim.api.nvim_create_user_command("DwightAccept", function() resolve(true) end,
    { desc = "Accept multi-file changes" })
  vim.api.nvim_create_user_command("DwightReject", function() resolve(false) end,
    { desc = "Reject multi-file changes" })

  -- Also set buffer-local keymaps in the quickfix window
  vim.schedule(function()
    local qf_win = vim.fn.getqflist({ winid = 0 }).winid
    if qf_win and qf_win > 0 then
      local qf_buf = api.nvim_win_get_buf(qf_win)
      vim.keymap.set("n", "y", function() resolve(true) end,
        { buffer = qf_buf, desc = "Accept changes" })
      vim.keymap.set("n", "n", function() resolve(false) end,
        { buffer = qf_buf, desc = "Reject changes" })
      vim.keymap.set("n", "<Esc>", function() resolve(false) end,
        { buffer = qf_buf, desc = "Reject changes" })
    end
  end)
end

return M
