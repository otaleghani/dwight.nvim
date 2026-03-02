-- dwight/commit.lua
-- Commits with motive: reads staged diff + recent dwight job history
-- to generate commit messages that explain WHY, not just WHAT.
-- :DwightCommit generates message → opens for editing → commits on confirm.

local M = {}

local uv = vim.loop or vim.uv

local function git_sync(args, timeout_ms)
  local result, done = nil, false
  local chunks = {}
  local stdout = uv.new_pipe(false)
  local handle
  handle = uv.spawn("git", {
    args = args, stdio = { nil, stdout, nil }, cwd = vim.fn.getcwd(),
  }, function(code)
    if stdout then stdout:close() end
    if handle then handle:close() end
    vim.schedule(function() result = code == 0 and table.concat(chunks, "") or nil; done = true end)
  end)
  if not handle then return nil end
  stdout:read_start(function(e, d) if not e and d then chunks[#chunks + 1] = d end end)
  vim.wait(timeout_ms or 5000, function() return done end, 50)
  return result
end

--------------------------------------------------------------------
-- Gather commit context
--------------------------------------------------------------------

local function get_staged_diff()
  local diff = git_sync({ "diff", "--cached", "--stat", "-p", "--no-color" })
  if diff and #diff > 8000 then diff = diff:sub(1, 8000) .. "\n[truncated]" end
  return diff
end

local function get_staged_files()
  return git_sync({ "diff", "--cached", "--name-only" })
end

local function get_recent_jobs(max_jobs)
  max_jobs = max_jobs or 5
  local log = require("dwight.log")
  local jobs = log._entries or {}
  local recent = {}
  for i = #jobs, math.max(1, #jobs - max_jobs + 1), -1 do
    local j = jobs[i]
    if j and j.status == "success" then
      recent[#recent + 1] = string.format("- Mode: %s | Instructions: %s",
        j.mode or "?", (j.prompt or ""):sub(1, 200))
    end
  end
  return table.concat(recent, "\n")
end

--------------------------------------------------------------------
-- Generate commit message
--------------------------------------------------------------------

function M.generate()
  local diff = get_staged_diff()
  if not diff or vim.trim(diff) == "" then
    vim.notify("[dwight] No staged changes. Stage files with `git add` first.", vim.log.levels.WARN)
    return
  end

  local files = get_staged_files() or ""
  local jobs = get_recent_jobs(5)

  local prompt = string.format([[
Generate a git commit message for the following staged changes.

Staged files:
%s

Staged diff:
%s

Recent AI-assisted changes (context for WHY these changes were made):
%s

Rules:
1. First line: concise summary (max 72 chars), imperative mood ("Add", "Fix", "Refactor")
2. Blank line after summary
3. Body: explain WHY the changes were made, not just what changed
4. If AI-assisted changes context is available, use it to explain the motivation
5. Reference specific files/functions when relevant
6. Keep body lines under 80 chars
7. Use conventional commit format if the project uses it (feat:, fix:, refactor:, etc.)

Respond with ONLY the commit message. No fences, no preamble.
]], files, diff, jobs ~= "" and jobs or "(no recent AI changes)")

  vim.notify("[dwight] Generating commit message…", vim.log.levels.INFO)

  local log = require("dwight.log")
  local job_id = log._next_id()
  log.start(job_id, "commit", vim.api.nvim_get_current_buf(), 0, 0,
    "DwightCommit: " .. (files:sub(1, 200)) .. "\n\n" .. prompt:sub(1, 4000))

  require("dwight.skills")._run_llm(prompt, function(raw, exit_code)
    if exit_code ~= 0 or not raw or vim.trim(raw) == "" then
      log.finish(job_id, "error", raw or "", nil, "Commit message generation failed")
      vim.notify("[dwight] Commit message generation failed.", vim.log.levels.ERROR)
      return
    end

    -- Clean up: strip any accidental fences
    local msg = raw:gsub("^```%w*\n", ""):gsub("\n```%s*$", "")
    msg = vim.trim(msg)

    log.finish(job_id, "success", raw, msg:sub(1, 200), nil)
    M._open_commit_editor(msg)
  end)
end

--------------------------------------------------------------------
-- Commit editor: buffer with message, save to commit
--------------------------------------------------------------------

function M._open_commit_editor(message)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "gitcommit"
  vim.bo[buf].swapfile = false

  -- Use a unique temp path as the buffer name — this is required for
  -- BufWriteCmd to trigger on plain :w (without specifying a filename).
  local tmp_name = vim.fn.tempname() .. "_DWIGHT_COMMIT_MSG"
  vim.api.nvim_buf_set_name(buf, tmp_name)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"

  local lines = vim.split(message, "\n", { plain = true })
  -- Add instructions at bottom as comments
  lines[#lines + 1] = ""
  lines[#lines + 1] = "# ── dwight commit ──"
  lines[#lines + 1] = "# Edit the message above. :w to commit, :q to cancel."
  lines[#lines + 1] = "# Lines starting with # are ignored."

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false

  -- Open in a split
  vim.cmd("split")
  vim.api.nvim_win_set_buf(0, buf)
  vim.cmd("resize 15")

  -- :w triggers the commit
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    once = true,
    callback = function()
      local msg_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      -- Strip comment lines
      local clean = {}
      for _, l in ipairs(msg_lines) do
        if not l:match("^#") then clean[#clean + 1] = l end
      end
      local final_msg = vim.trim(table.concat(clean, "\n"))
      if final_msg == "" then
        vim.notify("[dwight] Empty commit message, aborting.", vim.log.levels.WARN)
        return
      end

      -- Write to temp file and commit
      local tmp = vim.fn.tempname()
      local f = io.open(tmp, "w")
      if f then f:write(final_msg); f:close() end

      local result = git_sync({ "commit", "-F", tmp }, 10000)
      pcall(os.remove, tmp)

      if result then
        vim.notify("[dwight] ✅ Committed!", vim.log.levels.INFO)
        -- Close the commit buffer
        pcall(vim.cmd, "bdelete!")
      else
        vim.notify("[dwight] Commit failed. Check git status.", vim.log.levels.ERROR)
      end
    end,
  })
end

return M
