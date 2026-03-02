-- dwight/session_log.lua
-- Persistent activity log: every notification, job start/finish, and agent
-- event is appended to `.dwight/session.log` so the developer always has
-- a complete trail of what Dwight did.
--
-- Lifecycle:
--   init()  — called from M.setup(); opens the file and hooks vim.notify
--   close() — called on VimLeavePre; flushes and closes the file handle
--
-- The log is human-readable plain text, newest entries at the bottom,
-- suitable for `tail -f .dwight/session.log` in a split terminal.

local M = {}

local api = vim.api

M._file = nil       -- io file handle
M._path = nil       -- resolved file path
M._original_notify = nil  -- original vim.notify before our hook

--------------------------------------------------------------------
-- File management
--------------------------------------------------------------------

--- Open or re-open the session log file.
--- Returns true if the file is available for writing.
local function ensure_file()
  if M._file then return true end

  local ok, project = pcall(require, "dwight.project")
  if not ok or not project.is_initialized() then return false end

  local dir = project.dir()
  vim.fn.mkdir(dir, "p")
  M._path = dir .. "/session.log"

  local f, err = io.open(M._path, "a")
  if not f then
    -- Don't use vim.notify here — infinite loop risk
    return false
  end

  M._file = f
  return true
end

--- Write a line to the session log with timestamp.
function M.append(text)
  if not ensure_file() then return end

  local ts = os.date("%H:%M:%S")
  local line = string.format("[%s] %s\n", ts, text)
  pcall(function()
    M._file:write(line)
    M._file:flush()
  end)
end

--- Write a section separator.
function M.separator(title)
  if not ensure_file() then return end
  pcall(function()
    M._file:write(string.format(
      "\n%s ═══ %s ═══════════════════════════════════\n",
      os.date("%Y-%m-%d %H:%M:%S"), title))
    M._file:flush()
  end)
end

--- Close the file handle.
function M.close()
  if M._file then
    pcall(function()
      M._file:write(string.format("[%s] Session ended\n", os.date("%H:%M:%S")))
      M._file:flush()
      M._file:close()
    end)
    M._file = nil
  end
end

--------------------------------------------------------------------
-- vim.notify hook
--------------------------------------------------------------------

--- Install a transparent hook on vim.notify that captures [dwight] messages.
--- The original vim.notify is preserved and always called.
local function hook_notify()
  if M._original_notify then return end  -- already hooked

  M._original_notify = vim.notify

  vim.notify = function(msg, level, opts)
    -- Always pass through to original
    M._original_notify(msg, level, opts)

    -- Capture dwight messages to session log
    if type(msg) == "string" and msg:match("^%[dwight%]") then
      local level_tag = ""
      if level == vim.log.levels.ERROR then
        level_tag = " ❌"
      elseif level == vim.log.levels.WARN then
        level_tag = " ⚠️"
      end
      M.append(msg .. level_tag)
    end
  end
end

--------------------------------------------------------------------
-- Job log hooks
--------------------------------------------------------------------

--- Hook into dwight.log to capture job start/finish events.
function M._hook_job_log()
  local ok, log = pcall(require, "dwight.log")
  if not ok then return end

  -- Wrap log.start
  local orig_start = log.start
  log.start = function(job_id, mode, bufnr, start_line, end_line, prompt)
    local entry = orig_start(job_id, mode, bufnr, start_line, end_line, prompt)
    M.append(string.format("📝 Job #%d started: %s", job_id, mode))
    return entry
  end

  -- Wrap log.finish
  local orig_finish = log.finish
  log.finish = function(job_id, status, raw_response, parsed_code, error_msg)
    orig_finish(job_id, status, raw_response, parsed_code, error_msg)

    local entry = log.find(job_id)
    local elapsed = ""
    if entry and entry.started and entry.finished then
      elapsed = string.format(" (%ds)", entry.finished - entry.started)
    end

    local icon = ({
      success = "✅", error = "❌", parse_fail = "⚠️",
      no_change = "➖", cancelled = "🚫", timeout = "⏰",
    })[status] or "📋"

    local detail = ""
    if error_msg and error_msg ~= "" then
      detail = " — " .. error_msg:sub(1, 100)
    elseif parsed_code and parsed_code ~= "" then
      detail = " — " .. tostring(parsed_code):sub(1, 100)
    end

    M.append(string.format("%s Job #%d finished: %s [%s]%s%s",
      icon, job_id, entry and entry.mode or "?", status, elapsed, detail))
  end
end

--------------------------------------------------------------------
-- Initialization
--------------------------------------------------------------------

--- Initialize the session log. Call from dwight.setup().
function M.init()
  -- Write startup marker
  if ensure_file() then
    M.separator("Dwight started")
    M.append("Working directory: " .. vim.fn.getcwd())
  end

  -- Install hooks
  hook_notify()
  M._hook_job_log()

  -- Close on exit
  api.nvim_create_autocmd("VimLeavePre", {
    callback = function()
      M.close()
      -- Restore original notify
      if M._original_notify then
        vim.notify = M._original_notify
        M._original_notify = nil
      end
    end,
  })
end

return M
