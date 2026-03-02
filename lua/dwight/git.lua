-- dwight/git.lua
-- Git-aware context injection for prompts.
-- Provides recent diffs, file blame, and commit context.

local M = {}

local function run_git(args, callback)
  local chunks = {}
  local stdout = (vim.loop or vim.uv).new_pipe(false)
  local handle
  handle = (vim.loop or vim.uv).spawn("git", {
    args = args,
    stdio = { nil, stdout, nil },
    cwd = vim.fn.getcwd(),
  }, function(code)
    if stdout then stdout:close() end
    if handle then handle:close() end
    vim.schedule(function()
      callback(code == 0 and table.concat(chunks, "") or nil)
    end)
  end)
  if not handle then callback(nil); return end
  stdout:read_start(function(err, data) if not err and data then chunks[#chunks + 1] = data end end)
end

local function run_git_sync(args, timeout_ms)
  local result, done = nil, false
  run_git(args, function(out) result = out; done = true end)
  vim.wait(timeout_ms or 3000, function() return done end, 50)
  return result
end

--------------------------------------------------------------------
-- Context gathering
--------------------------------------------------------------------

--- Get unstaged diff for a file (or all files if nil).
function M.diff_unstaged(filepath)
  local args = { "diff", "--no-color", "--stat", "-p" }
  if filepath then args[#args + 1] = filepath end
  local out = run_git_sync(args)
  if out and #out > 5000 then out = out:sub(1, 5000) .. "\n[truncated]" end
  return out
end

--- Get staged diff.
function M.diff_staged(filepath)
  local args = { "diff", "--cached", "--no-color", "--stat", "-p" }
  if filepath then args[#args + 1] = filepath end
  local out = run_git_sync(args)
  if out and #out > 5000 then out = out:sub(1, 5000) .. "\n[truncated]" end
  return out
end

--- Get diff from HEAD (staged + unstaged).
function M.diff_head(filepath)
  local args = { "diff", "HEAD", "--no-color", "-p" }
  if filepath then args[#args + 1] = filepath end
  local out = run_git_sync(args)
  if out and #out > 5000 then out = out:sub(1, 5000) .. "\n[truncated]" end
  return out
end

--- Get recent commits (last N).
function M.recent_commits(n)
  n = n or 5
  return run_git_sync({ "log", "--oneline", "--no-decorate", "-n", tostring(n) })
end

--- Get blame for specific lines of a file.
function M.blame_lines(filepath, start_line, end_line)
  if not filepath then return nil end
  local args = { "blame", "--no-progress", "-L",
    tostring(start_line) .. "," .. tostring(end_line),
    "--", filepath }
  return run_git_sync(args)
end

--- Check if we're in a git repo.
function M.is_repo()
  local out = run_git_sync({ "rev-parse", "--is-inside-work-tree" }, 1000)
  return out and vim.trim(out) == "true"
end

--- Get current branch name.
function M.branch()
  local out = run_git_sync({ "rev-parse", "--abbrev-ref", "HEAD" }, 1000)
  return out and vim.trim(out) or nil
end

--------------------------------------------------------------------
-- Prompt context builder
--------------------------------------------------------------------

--- Build git context for a selection. Returns string or nil.
function M.context_for_selection(selection)
  if not M.is_repo() then return nil end

  local parts = {}
  local filepath = selection and selection.filepath or nil
  local rel_path = filepath and vim.fn.fnamemodify(filepath, ":.") or nil

  -- Diff for this file (shows what changed recently)
  if rel_path then
    local diff = M.diff_head(rel_path)
    if diff and vim.trim(diff) ~= "" then
      parts[#parts + 1] = "Git diff (uncommitted changes to this file):\n" .. diff
    end
  end

  -- Blame for selected lines (shows who wrote it and when)
  if rel_path and selection.start_line and selection.end_line then
    local blame = M.blame_lines(rel_path, selection.start_line, selection.end_line)
    if blame and vim.trim(blame) ~= "" then
      -- Trim blame to just first 20 lines
      local blame_lines = vim.split(blame, "\n", { plain = true })
      if #blame_lines > 20 then
        blame = table.concat(vim.list_slice(blame_lines, 1, 20), "\n") .. "\n[...]"
      end
      parts[#parts + 1] = "Git blame (selected lines):\n" .. blame
    end
  end

  if #parts == 0 then return nil end
  return table.concat(parts, "\n\n")
end

return M
