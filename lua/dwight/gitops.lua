-- dwight/gitops.lua
-- Unified git workflow: stage, commit, stash, push, branch, cleanup.
-- Consolidates scattered git operations into :DwightGit.

local M = {}

local api = vim.api
local _flatten = require("dwight.util").flatten_lines

--------------------------------------------------------------------
-- Git helpers (sync, with timeout)
--------------------------------------------------------------------

local function git(args, timeout_ms)
  local chunks = {}
  local stdout = (vim.loop or vim.uv).new_pipe(false)
  local result, done = nil, false

  local handle
  handle = (vim.loop or vim.uv).spawn("git", {
    args = args,
    stdio = { nil, stdout, nil },
    cwd = vim.fn.getcwd(),
  }, function(code)
    if stdout then stdout:close() end
    if handle then handle:close() end
    vim.schedule(function()
      result = { output = table.concat(chunks, ""), code = code }
      done = true
    end)
  end)

  if not handle then return { output = "", code = -1 } end
  stdout:read_start(function(err, data)
    if not err and data then chunks[#chunks + 1] = data end
  end)
  vim.wait(timeout_ms or 5000, function() return done end, 50)
  return result or { output = "", code = -1 }
end

--- Run git and return output string (nil on error).
local function git_ok(args, timeout_ms)
  local r = git(args, timeout_ms)
  return r.code == 0 and r.output or nil
end

--------------------------------------------------------------------
-- Status
--------------------------------------------------------------------

--- Get working tree status as structured data.
function M.status()
  local out = git_ok({ "status", "--porcelain", "-b" })
  if not out then return nil end

  local result = {
    branch = nil,
    staged = {},
    unstaged = {},
    untracked = {},
    conflicts = {},
  }

  for line in out:gmatch("[^\n]+") do
    if line:match("^## ") then
      result.branch = line:match("^## ([^%.]+)") or line:sub(4)
    elseif line:match("^UU ") or line:match("^AA ") then
      result.conflicts[#result.conflicts + 1] = line:sub(4)
    elseif line:match("^%?%? ") then
      result.untracked[#result.untracked + 1] = line:sub(4)
    else
      local x, y = line:sub(1, 1), line:sub(2, 2)
      local file = line:sub(4)
      if x ~= " " and x ~= "?" then
        result.staged[#result.staged + 1] = { status = x, file = file }
      end
      if y ~= " " and y ~= "?" then
        result.unstaged[#result.unstaged + 1] = { status = y, file = file }
      end
    end
  end

  return result
end

--------------------------------------------------------------------
-- Stash
--------------------------------------------------------------------

--- Stash working changes with an auto-generated message.
function M.stash(msg)
  msg = msg or ("dwight: stash " .. os.date("%H:%M:%S"))
  local r = git({ "stash", "push", "-m", msg })
  if r.code == 0 then
    vim.notify("[dwight] 📦 Stashed: " .. msg, vim.log.levels.INFO)
    return true
  else
    vim.notify("[dwight] Stash failed: " .. (r.output or ""):sub(1, 100), vim.log.levels.ERROR)
    return false
  end
end

--- Pop the last stash.
function M.stash_pop()
  local r = git({ "stash", "pop" })
  if r.code == 0 then
    vim.notify("[dwight] 📦 Stash popped.", vim.log.levels.INFO)
    return true
  else
    vim.notify("[dwight] Stash pop failed: " .. (r.output or ""):sub(1, 100), vim.log.levels.ERROR)
    return false
  end
end

--- List stashes.
function M.stash_list()
  return git_ok({ "stash", "list" }) or ""
end

--------------------------------------------------------------------
-- Branch
--------------------------------------------------------------------

--- List branches.
function M.branches()
  local out = git_ok({ "branch", "--format=%(refname:short) %(HEAD)" })
  if not out then return {} end

  local branches = {}
  for line in out:gmatch("[^\n]+") do
    local name, head = line:match("^(%S+)%s*(%*?)")
    if name then
      branches[#branches + 1] = { name = name, current = head == "*" }
    end
  end
  return branches
end

--- Switch to a branch.
function M.checkout(branch)
  local r = git({ "checkout", branch })
  if r.code == 0 then
    vim.notify("[dwight] 🌿 Switched to " .. branch, vim.log.levels.INFO)
    return true
  else
    vim.notify("[dwight] Checkout failed: " .. (r.output or ""):sub(1, 100), vim.log.levels.ERROR)
    return false
  end
end

--- Create and switch to a new branch.
function M.create_branch(name)
  local r = git({ "checkout", "-b", name })
  if r.code == 0 then
    vim.notify("[dwight] 🌿 Created branch: " .. name, vim.log.levels.INFO)
    return true
  else
    vim.notify("[dwight] Branch creation failed: " .. (r.output or ""):sub(1, 100), vim.log.levels.ERROR)
    return false
  end
end

--------------------------------------------------------------------
-- Stage / Commit
--------------------------------------------------------------------

--- Stage specific files.
function M.stage(files)
  if type(files) == "string" then files = { files } end
  local args = { "add" }
  for _, f in ipairs(files) do args[#args + 1] = f end
  local r = git(args)
  if r.code == 0 then
    vim.notify(string.format("[dwight] ✅ Staged %d file(s)", #files), vim.log.levels.INFO)
  end
  return r.code == 0
end

--- Stage all changes.
function M.stage_all()
  return git({ "add", "-A" }).code == 0
end

--- Commit with message.
function M.commit(msg)
  local r = git({ "commit", "-m", msg }, 10000)
  if r.code == 0 then
    vim.notify("[dwight] ✅ Committed: " .. msg:sub(1, 60), vim.log.levels.INFO)
    return true
  end
  vim.notify("[dwight] Commit failed: " .. (r.output or ""):sub(1, 100), vim.log.levels.ERROR)
  return false
end

--- Smart commit: stage all + LLM-generated commit message.
function M.smart_commit()
  local commit_mod = require("dwight.commit")
  commit_mod.generate()
end

--------------------------------------------------------------------
-- Push / Pull
--------------------------------------------------------------------

--- Push current branch to origin.
function M.push(opts)
  opts = opts or {}
  local branch = git_ok({ "rev-parse", "--abbrev-ref", "HEAD" }, 1000)
  if not branch then
    vim.notify("[dwight] Not on a branch.", vim.log.levels.ERROR)
    return false
  end
  branch = vim.trim(branch)

  local args = { "push" }
  if opts.set_upstream then
    args[#args + 1] = "-u"
    args[#args + 1] = "origin"
    args[#args + 1] = branch
  elseif opts.force then
    args[#args + 1] = "--force-with-lease"
  end

  vim.notify("[dwight] 🚀 Pushing " .. branch .. "…", vim.log.levels.INFO)
  local r = git(args, 30000)
  if r.code == 0 then
    vim.notify("[dwight] 🚀 Pushed to origin/" .. branch, vim.log.levels.INFO)
    return true
  end
  -- Might need --set-upstream
  if r.output:match("no upstream branch") then
    return M.push({ set_upstream = true })
  end
  vim.notify("[dwight] Push failed: " .. (r.output or ""):sub(1, 200), vim.log.levels.ERROR)
  return false
end

--- Pull current branch.
function M.pull()
  vim.notify("[dwight] ⬇️  Pulling…", vim.log.levels.INFO)
  local r = git({ "pull", "--rebase" }, 30000)
  if r.code == 0 then
    vim.notify("[dwight] ⬇️  Pull complete.", vim.log.levels.INFO)
    return true
  end
  vim.notify("[dwight] Pull failed: " .. (r.output or ""):sub(1, 200), vim.log.levels.ERROR)
  return false
end

--------------------------------------------------------------------
-- Cleanup: squash + push + PR in one flow
--------------------------------------------------------------------

--- Full cleanup flow: squash checkpoints → push → create PR.
function M.cleanup()
  require("dwight.select").pick({
    "🧹 Squash + push",
    "🧹 Squash + push + PR",
    "🧹 Squash + push + draft PR",
    "🚀 Just push",
  }, {
    prompt = "Git cleanup:",
  }, function(choice)
    if not choice then return end

    if choice:match("Squash") then
      -- Squash first
      pcall(function()
        require("dwight.integration").squash()
      end)
      -- Wait for squash to complete, then push
      vim.defer_fn(function()
        M.push()
        if choice:match("PR") then
          vim.defer_fn(function()
            local draft = choice:match("draft") ~= nil
            pcall(function()
              local gh = require("dwight.github")
              local branch = vim.trim(git_ok({ "rev-parse", "--abbrev-ref", "HEAD" }, 1000) or "")
              gh.create_pr({
                title = branch,
                draft = draft,
              }, function(url, err)
                if err then
                  vim.notify("[dwight] " .. err, vim.log.levels.ERROR)
                else
                  vim.notify("[dwight] 🎉 PR: " .. (url or ""), vim.log.levels.INFO)
                end
              end)
            end)
          end, 2000)
        end
      end, 1000)
    else
      M.push()
    end
  end)
end

--------------------------------------------------------------------
-- Conflict resolution
--------------------------------------------------------------------

--- List conflict files and open in quickfix.
function M.conflicts()
  local status = M.status()
  if not status or #status.conflicts == 0 then
    vim.notify("[dwight] No merge conflicts.", vim.log.levels.INFO)
    return
  end

  local items = {}
  for _, f in ipairs(status.conflicts) do
    items[#items + 1] = { filename = f, lnum = 1, text = "merge conflict" }
  end

  vim.fn.setqflist(items, "r")
  vim.cmd("copen")
  vim.notify(string.format("[dwight] %d conflict(s) in quickfix.", #items), vim.log.levels.WARN)
end

--- AI-assisted conflict resolution for current file.
function M.resolve_conflict()
  local filepath = vim.fn.expand("%:p")
  if filepath == "" then
    vim.notify("[dwight] No file open.", vim.log.levels.WARN)
    return
  end

  -- Check if file has conflict markers
  local content = table.concat(api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  if not content:match("<<<<<<< ") then
    vim.notify("[dwight] No conflict markers found in this file.", vim.log.levels.INFO)
    return
  end

  -- Use agent to resolve
  local request = string.format(
    "Resolve the merge conflicts in `%s`.\n\n" ..
    "The file has <<<<<<< / ======= / >>>>>>> conflict markers.\n" ..
    "Read the file, understand both sides of each conflict, and write the resolved version.\n" ..
    "Keep the best of both sides. Ensure the result compiles and is correct.\n" ..
    "After resolving, run tests to verify.",
    vim.fn.fnamemodify(filepath, ":."))

  require("dwight.agent").run(request)
end

--------------------------------------------------------------------
-- Telescope picker: main DwightGit UI
--------------------------------------------------------------------

function M.pick(subcmd)
  -- Handle direct subcommands
  if subcmd and subcmd ~= "" then
    subcmd = vim.trim(subcmd)
    if subcmd == "stash" then return M.stash() end
    if subcmd == "pop" then return M.stash_pop() end
    if subcmd == "push" then return M.push() end
    if subcmd == "pull" then return M.pull() end
    if subcmd == "commit" then return M.smart_commit() end
    if subcmd == "cleanup" then return M.cleanup() end
    if subcmd == "conflict" or subcmd == "conflicts" then return M.conflicts() end
    if subcmd == "resolve" then return M.resolve_conflict() end
    if subcmd == "status" then return M._show_status_buffer() end
    vim.notify("[dwight] Unknown git subcommand: " .. subcmd, vim.log.levels.WARN)
    return
  end

  -- Interactive picker
  local status = M.status()
  if not status then
    vim.notify("[dwight] Not in a git repo.", vim.log.levels.ERROR)
    return
  end

  local dirty_count = #status.staged + #status.unstaged + #status.untracked
  local conflict_count = #status.conflicts

  local items = {}
  items[#items + 1] = string.format("📊 Status (%s, %d changes)", status.branch or "?", dirty_count)
  items[#items + 1] = "✍️  Smart commit (stage all + AI message)"

  if dirty_count > 0 then
    items[#items + 1] = "📦 Stash changes"
  end

  local stashes = M.stash_list()
  if stashes ~= "" then
    items[#items + 1] = "📦 Pop stash"
  end

  items[#items + 1] = "🚀 Push"
  items[#items + 1] = "⬇️  Pull (rebase)"
  items[#items + 1] = "🧹 Cleanup (squash + push + PR)"

  if conflict_count > 0 then
    items[#items + 1] = string.format("⚔️  Resolve conflicts (%d files)", conflict_count)
  end

  items[#items + 1] = "🌿 Switch branch"
  items[#items + 1] = "🌿 New branch"

  require("dwight.select").pick(items, {
    prompt = string.format("🐙 Git (%s):", status.branch or "?"),
  }, function(choice)
    if not choice then return end

    if choice:match("Status") then M._show_status_buffer()
    elseif choice:match("Smart commit") then M.smart_commit()
    elseif choice:match("Stash changes") then M.stash()
    elseif choice:match("Pop stash") then M.stash_pop()
    elseif choice:match("Push") then M.push()
    elseif choice:match("Pull") then M.pull()
    elseif choice:match("Cleanup") then M.cleanup()
    elseif choice:match("Resolve") then M.conflicts()
    elseif choice:match("Switch branch") then M._pick_branch()
    elseif choice:match("New branch") then
      vim.ui.input({ prompt = "Branch name: " }, function(name)
        if name and name ~= "" then M.create_branch(name) end
      end)
    end
  end)
end

--- Show git status in a scratch buffer.
function M._show_status_buffer()
  local status = M.status()
  if not status then return end

  local lines = {
    "# 🐙 Git Status",
    "",
    "**Branch:** " .. (status.branch or "unknown"),
    "",
  }

  if #status.staged > 0 then
    lines[#lines + 1] = "## Staged"
    for _, f in ipairs(status.staged) do
      lines[#lines + 1] = "  " .. f.status .. " " .. f.file
    end
    lines[#lines + 1] = ""
  end

  if #status.unstaged > 0 then
    lines[#lines + 1] = "## Unstaged"
    for _, f in ipairs(status.unstaged) do
      lines[#lines + 1] = "  " .. f.status .. " " .. f.file
    end
    lines[#lines + 1] = ""
  end

  if #status.untracked > 0 then
    lines[#lines + 1] = "## Untracked"
    for _, f in ipairs(status.untracked) do
      lines[#lines + 1] = "  ? " .. f
    end
    lines[#lines + 1] = ""
  end

  if #status.conflicts > 0 then
    lines[#lines + 1] = "## Conflicts"
    for _, f in ipairs(status.conflicts) do
      lines[#lines + 1] = "  ⚔️  " .. f
    end
    lines[#lines + 1] = ""
  end

  if #status.staged == 0 and #status.unstaged == 0
     and #status.untracked == 0 and #status.conflicts == 0 then
    lines[#lines + 1] = "✨ Working tree clean"
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "---"
  lines[#lines + 1] = "**c** commit | **s** stash | **p** push | **q** close"

  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, _flatten(lines))
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  pcall(function() api.nvim_buf_set_name(buf, "dwight://git-status") end)

  vim.cmd("botright split")
  api.nvim_win_set_buf(0, buf)
  api.nvim_win_set_height(0, math.min(#lines + 2, 25))

  -- Keymaps
  local function kmap(key, fn, desc)
    vim.keymap.set("n", key, fn, { buffer = buf, desc = desc })
  end

  kmap("c", function()
    pcall(api.nvim_buf_delete, buf, { force = true })
    M.smart_commit()
  end, "Smart commit")

  kmap("s", function()
    pcall(api.nvim_buf_delete, buf, { force = true })
    M.stash()
  end, "Stash")

  kmap("p", function()
    pcall(api.nvim_buf_delete, buf, { force = true })
    M.push()
  end, "Push")

  kmap("q", function()
    pcall(api.nvim_buf_delete, buf, { force = true })
  end, "Close")
end

--- Branch picker using Telescope.
function M._pick_branch()
  local branches = M.branches()
  if #branches == 0 then
    vim.notify("[dwight] No branches found.", vim.log.levels.WARN)
    return
  end

  local items = {}
  for _, b in ipairs(branches) do
    items[#items + 1] = (b.current and "* " or "  ") .. b.name
  end

  require("dwight.select").pick(items, {
    prompt = "Switch branch:",
  }, function(_, idx)
    if idx then
      M.checkout(branches[idx].name)
    end
  end)
end

return M
