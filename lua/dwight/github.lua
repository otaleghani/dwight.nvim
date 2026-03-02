-- dwight/github.lua
-- GitHub issues integration: list, view, solve, and PR from Neovim.
-- Uses `gh` CLI for authentication and API access.
-- Workflow: pick issue → create branch → DwightAgent/DwightAuto → commit → PR.

local M = {}

local api = vim.api
local _flatten = require("dwight.util").flatten_lines
local uv = vim.loop or vim.uv

--------------------------------------------------------------------
-- gh CLI wrapper
--------------------------------------------------------------------

--- Run a gh command asynchronously.
--- callback(output_string, exit_code)
local function run_gh(args, callback)
  local chunks = {}
  local stderr_chunks = {}
  local stdout = uv.new_pipe(false)
  local stderr = uv.new_pipe(false)

  local handle
  handle = uv.spawn("gh", {
    args = args,
    stdio = { nil, stdout, stderr },
    cwd = vim.fn.getcwd(),
  }, function(code)
    if stdout then stdout:close() end
    if stderr then stderr:close() end
    if handle then handle:close() end
    vim.schedule(function()
      local out = table.concat(chunks, "")
      local err_out = table.concat(stderr_chunks, "")
      if code ~= 0 and out == "" then out = err_out end
      callback(out, code)
    end)
  end)

  if not handle then
    vim.schedule(function()
      callback("", -1)
    end)
    return
  end

  stdout:read_start(function(err, data)
    if not err and data then chunks[#chunks + 1] = data end
  end)
  stderr:read_start(function(err, data)
    if not err and data then stderr_chunks[#stderr_chunks + 1] = data end
  end)
end

--- Run gh synchronously (with timeout).
local function run_gh_sync(args, timeout_ms)
  local result, code_out, done = nil, nil, false
  run_gh(args, function(out, code)
    result = out; code_out = code; done = true
  end)
  vim.wait(timeout_ms or 10000, function() return done end, 50)
  return result, code_out
end

--- Run a git command synchronously.
local function run_git_sync(args, timeout_ms)
  local chunks = {}
  local stdout = uv.new_pipe(false)
  local result, done = nil, false

  local handle
  handle = uv.spawn("git", {
    args = args,
    stdio = { nil, stdout, nil },
    cwd = vim.fn.getcwd(),
  }, function(code)
    if stdout then stdout:close() end
    if handle then handle:close() end
    vim.schedule(function()
      result = code == 0 and table.concat(chunks, "") or nil
      done = true
    end)
  end)
  if not handle then return nil end
  stdout:read_start(function(err, data)
    if not err and data then chunks[#chunks + 1] = data end
  end)
  vim.wait(timeout_ms or 5000, function() return done end, 50)
  return result
end

--------------------------------------------------------------------
-- Preflight
--------------------------------------------------------------------

--- Parse cross-repo reference: "owner/repo#42" → { repo = "owner/repo", number = 42 }
--- Also handles: "42", "#42", "--repo owner/repo 42"
local function parse_issue_ref(raw)
  if not raw or raw == "" then return {} end
  -- owner/repo#42
  local repo, num = raw:match("^([%w%-%.]+/[%w%-%.]+)#(%d+)$")
  if repo and num then return { repo = repo, number = tonumber(num) } end
  -- Just a number
  num = raw:match("^#?(%d+)$")
  if num then return { number = tonumber(num) } end
  return {}
end

--- Build repo flag args for gh CLI.
--- Returns a table of args to prepend, e.g. {"-R", "owner/repo"} or {}.
local function repo_flag(repo)
  if not repo or repo == "" then return {} end
  return { "-R", repo }
end

--- Detect the current repo's owner/name from git remote.
function M.current_repo()
  local out = run_git_sync({ "remote", "get-url", "origin" }, 2000)
  if not out then return nil end
  -- git@github.com:owner/repo.git or https://github.com/owner/repo.git
  local owner, name = out:match("github%.com[:/]([%w%-%.]+)/([%w%-%.]+)")
  if owner and name then
    return owner .. "/" .. name:gsub("%.git%s*$", "")
  end
  return nil
end

--------------------------------------------------------------------
-- Label colors: map GitHub hex colors to Neovim highlights
--------------------------------------------------------------------

local _label_hl_cache = {}

--- Create a highlight group for a GitHub label color.
--- Returns the highlight group name.
local function label_hl(hex_color)
  if not hex_color or hex_color == "" then return nil end
  hex_color = hex_color:gsub("^#", "")
  if #hex_color ~= 6 then return nil end

  local hl_name = "DwightLabel_" .. hex_color
  if _label_hl_cache[hl_name] then return hl_name end

  -- Parse RGB to determine if we need light or dark foreground
  local r = tonumber(hex_color:sub(1, 2), 16) or 128
  local g = tonumber(hex_color:sub(3, 4), 16) or 128
  local b = tonumber(hex_color:sub(5, 6), 16) or 128
  local luminance = (0.299 * r + 0.587 * g + 0.114 * b) / 255
  local fg = luminance > 0.5 and "#1a1b26" or "#c0caf5"

  api.nvim_set_hl(0, hl_name, { fg = fg, bg = "#" .. hex_color, bold = true })
  _label_hl_cache[hl_name] = true
  return hl_name
end

--- Check if gh CLI is available and authenticated.
--- Returns { ok, detail }
function M.check()
  local path = vim.fn.exepath("gh")
  if path == "" then
    return { ok = false, detail = "gh CLI not found. Install from https://cli.github.com" }
  end

  local out, code = run_gh_sync({ "auth", "status" }, 5000)
  if code ~= 0 then
    return { ok = false, detail = "gh not authenticated. Run: gh auth login" }
  end

  return { ok = true, detail = "gh authenticated (" .. path .. ")" }
end

--- Check if we're in a GitHub repo (has remote pointing to github.com).
function M.is_github_repo()
  local out = run_git_sync({ "remote", "get-url", "origin" }, 2000)
  return out and out:match("github") ~= nil
end

--------------------------------------------------------------------
-- Issue API
--------------------------------------------------------------------

local ISSUE_FIELDS = "number,title,body,state,labels,assignees,comments,createdAt,author,milestone,url"

--- List open issues. Returns parsed table or nil.
--- opts.label — filter by label
--- opts.assignee — filter by assignee ("@me" for self)
--- opts.milestone — filter by milestone title
--- opts.limit — max issues (default 30)
--- opts.state — "open" (default), "closed", "all"
--- opts.repo — "owner/repo" for cross-repo (optional)
function M.list_issues(opts, callback)
  opts = opts or {}
  local args = repo_flag(opts.repo)
  vim.list_extend(args, {
    "issue", "list",
    "--json", ISSUE_FIELDS,
    "--limit", tostring(opts.limit or 30),
    "--state", opts.state or "open",
  })

  if opts.label then
    args[#args + 1] = "--label"
    args[#args + 1] = opts.label
  end
  if opts.assignee then
    args[#args + 1] = "--assignee"
    args[#args + 1] = opts.assignee
  end
  if opts.milestone then
    args[#args + 1] = "--milestone"
    args[#args + 1] = opts.milestone
  end

  run_gh(args, function(out, code)
    if code ~= 0 then
      callback(nil, "gh issue list failed: " .. (out or ""):sub(1, 200))
      return
    end
    local ok, data = pcall(vim.json.decode, out)
    if not ok or not data then
      callback(nil, "Failed to parse issue list")
      return
    end
    callback(data, nil)
  end)
end

--- Get a single issue with full detail.
--- opts.repo — "owner/repo" for cross-repo (optional)
function M.get_issue(number, callback, opts)
  opts = opts or {}
  local args = repo_flag(opts.repo)
  vim.list_extend(args, {
    "issue", "view", tostring(number),
    "--json", ISSUE_FIELDS,
  })
  run_gh(args, function(out, code)
    if code ~= 0 then
      callback(nil, "gh issue view failed: " .. (out or ""):sub(1, 200))
      return
    end
    local ok, data = pcall(vim.json.decode, out)
    if not ok or not data then
      callback(nil, "Failed to parse issue")
      return
    end
    -- Stamp repo if cross-repo
    if opts.repo then data._repo = opts.repo end
    callback(data, nil)
  end)
end

--------------------------------------------------------------------
-- Branch / PR helpers
--------------------------------------------------------------------

--- Create a feature branch for an issue.
--- Returns branch name.
function M.create_branch(issue)
  local slug = (issue.title or "issue"):sub(1, 40)
    :lower()
    :gsub("[^%w%s%-]", "")
    :gsub("%s+", "-")
    :gsub("%-+", "-")
    :gsub("^%-+", "")
    :gsub("%-+$", "")

  local branch = string.format("fix/%d-%s", issue.number, slug)

  -- Stash if dirty
  local status = run_git_sync({ "status", "--porcelain" }, 2000)
  local was_dirty = status and vim.trim(status) ~= ""
  if was_dirty then
    run_git_sync({ "stash", "push", "-m", "dwight: stash before issue #" .. issue.number }, 3000)
  end

  -- Create and checkout branch
  local out = run_git_sync({ "checkout", "-b", branch }, 3000)
  if not out and not run_git_sync({ "rev-parse", "--verify", branch }, 1000) then
    -- Branch might already exist, try switching
    run_git_sync({ "checkout", branch }, 3000)
  end

  if was_dirty then
    run_git_sync({ "stash", "pop" }, 3000)
  end

  return branch
end

--- Open a pull request for the current branch.
--- opts.issue — issue number (adds "Closes #N")
--- opts.title — PR title (default: "Fix #N: title")
--- opts.body — PR body (default: auto-generated)
--- opts.draft — true for draft PR
function M.create_pr(opts, callback)
  opts = opts or {}
  local args = repo_flag(opts.repo)
  vim.list_extend(args, { "pr", "create" })

  if opts.title then
    args[#args + 1] = "--title"
    args[#args + 1] = opts.title
  end

  local body = opts.body or ""
  if opts.issue then
    if body ~= "" then body = body .. "\n\n" end
    body = body .. "Closes #" .. opts.issue
  end
  if body ~= "" then
    args[#args + 1] = "--body"
    args[#args + 1] = body
  end

  if opts.draft then
    args[#args + 1] = "--draft"
  end

  -- Push first
  local branch = run_git_sync({ "rev-parse", "--abbrev-ref", "HEAD" }, 1000)
  if branch then
    branch = vim.trim(branch)
    run_git_sync({ "push", "-u", "origin", branch }, 15000)
  end

  run_gh(args, function(out, code)
    if code ~= 0 then
      callback(nil, "PR creation failed: " .. (out or ""):sub(1, 200))
    else
      callback(vim.trim(out), nil)
    end
  end)
end

--- Post a comment on an issue.
function M.comment(number, body, callback, opts)
  opts = opts or {}
  local args = repo_flag(opts.repo)
  vim.list_extend(args, { "issue", "comment", tostring(number), "--body", body })
  run_gh(args, function(out, code)
    if callback then callback(code == 0, out) end
  end)
end

--------------------------------------------------------------------
-- Context builder: issue → agent prompt
--------------------------------------------------------------------

--- Build a rich agent prompt from an issue.
--- Injects: issue body, comments, referenced files, feature context, skills, libs.
function M.build_issue_context(issue)
  local parts = {}

  -- Issue header
  parts[#parts + 1] = string.format("<github_issue number=\"%d\" url=\"%s\">",
    issue.number, issue.url or "")
  parts[#parts + 1] = string.format("  <title>%s</title>", issue.title or "")

  -- Labels
  if issue.labels and #issue.labels > 0 then
    local label_names = {}
    for _, l in ipairs(issue.labels) do
      label_names[#label_names + 1] = type(l) == "table" and l.name or tostring(l)
    end
    parts[#parts + 1] = string.format("  <labels>%s</labels>", table.concat(label_names, ", "))
  end

  -- Body
  local body = issue.body or ""
  if #body > 6000 then body = body:sub(1, 6000) .. "\n... (truncated)" end
  parts[#parts + 1] = "  <body>"
  parts[#parts + 1] = body
  parts[#parts + 1] = "  </body>"

  -- Comments (last 10)
  if issue.comments and #issue.comments > 0 then
    parts[#parts + 1] = "  <comments>"
    local start_idx = math.max(1, #issue.comments - 9)
    for i = start_idx, #issue.comments do
      local c = issue.comments[i]
      local author = type(c.author) == "table" and c.author.login or (c.author or "unknown")
      local comment_body = c.body or ""
      if #comment_body > 1500 then comment_body = comment_body:sub(1, 1500) .. "…" end
      parts[#parts + 1] = string.format('    <comment author="%s" date="%s">',
        author, c.createdAt or "")
      parts[#parts + 1] = "      " .. comment_body
      parts[#parts + 1] = "    </comment>"
    end
    parts[#parts + 1] = "  </comments>"
  end

  parts[#parts + 1] = "</github_issue>"

  -- Extract file references from issue body + comments
  local all_text = (issue.body or "")
  if issue.comments then
    for _, c in ipairs(issue.comments) do all_text = all_text .. "\n" .. (c.body or "") end
  end
  local referenced_files = M._extract_file_refs(all_text)
  if #referenced_files > 0 then
    parts[#parts + 1] = ""
    parts[#parts + 1] = "<referenced_files hint=\"Files mentioned in the issue\">"
    for _, ref in ipairs(referenced_files) do
      parts[#parts + 1] = "  <file>" .. ref .. "</file>"
    end
    parts[#parts + 1] = "</referenced_files>"
  end

  -- Feature context (if issue mentions $feature or touches feature files)
  local feature_names = M._detect_features(all_text, referenced_files)
  if #feature_names > 0 then
    pcall(function()
      local integration = require("dwight.integration")
      for _, fname in ipairs(feature_names) do
        local ctx = integration.build_feature_context("$" .. fname)
        if ctx then
          parts[#parts + 1] = ""
          parts[#parts + 1] = ctx
        end
      end
    end)
  end

  -- Skills + libs + pragma rules
  pcall(function()
    local integration = require("dwight.integration")
    local full_ctx = integration.build_full_context()
    if full_ctx then
      parts[#parts + 1] = ""
      parts[#parts + 1] = full_ctx
    end
  end)

  return table.concat(parts, "\n")
end

--- Extract file paths mentioned in text.
--- Looks for paths like src/foo.go, ./bar/baz.ts, pkg/auth/handler.go
function M._extract_file_refs(text)
  local refs = {}
  local seen = {}
  local cwd = vim.fn.getcwd()

  -- Match patterns like `path/to/file.ext` in backticks or standalone
  for path in text:gmatch("`([%w%.%-%_/]+%.[%w]+)`") do
    if not seen[path] then
      -- Verify the file actually exists
      local full = cwd .. "/" .. path
      if vim.fn.filereadable(full) == 1 then
        refs[#refs + 1] = path
        seen[path] = true
      end
    end
  end

  -- Also match stack trace patterns: at /path/file.go:123
  for path in text:gmatch("([%w%.%-%_/]+%.[%w]+):%d+") do
    if not seen[path] then
      local full = cwd .. "/" .. path
      if vim.fn.filereadable(full) == 1 then
        refs[#refs + 1] = path
        seen[path] = true
      end
    end
  end

  return refs
end

--- Detect feature names from text and file references.
function M._detect_features(text, file_refs)
  local names = {}
  local seen = {}

  -- $feature-name pattern
  for name in text:gmatch("%$([%w%-_]+)") do
    if not seen[name] then names[#names + 1] = name; seen[name] = true end
  end

  -- @feature:name pattern
  for name in text:gmatch("@feature:([%w%-_]+)") do
    if not seen[name] then names[#names + 1] = name; seen[name] = true end
  end

  -- Map referenced files to features
  pcall(function()
    local features = require("dwight.features")
    local all_features = features.all()
    if all_features then
      for feat_name, feat in pairs(all_features) do
        if not seen[feat_name] and feat.files then
          for _, ff in ipairs(feat.files) do
            for _, ref in ipairs(file_refs) do
              if ff:match(ref .. "$") or ref:match(vim.pesc(ff) .. "$") then
                names[#names + 1] = feat_name
                seen[feat_name] = true
                break
              end
            end
            if seen[feat_name] then break end
          end
        end
      end
    end
  end)

  return names
end

--------------------------------------------------------------------
-- Request builders
--------------------------------------------------------------------

--- Build the request string for DwightAgent (single task).
local function build_agent_request(issue)
  return string.format(
    "Solve GitHub issue #%d: %s\n\n" ..
    "Fix the issue described below. After fixing, ensure all existing tests pass " ..
    "and add new tests if appropriate.\n\n%s",
    issue.number, issue.title, M.build_issue_context(issue))
end

--- Build the request string for DwightAuto (multi-task decomposition).
local function build_auto_request(issue)
  return string.format(
    "Solve GitHub issue #%d: %s\n\n" ..
    "This may require multiple changes across several files. " ..
    "Fix the issue, add tests, and ensure everything compiles and passes.\n\n%s",
    issue.number, issue.title, M.build_issue_context(issue))
end

--------------------------------------------------------------------
-- Workflow actions
--------------------------------------------------------------------

--- Solve an issue via DwightAgent (single-shot agentic loop).
--- Creates branch, runs agent, offers PR on completion.
function M.solve_agent(issue)
  local branch = M.create_branch(issue)
  vim.notify(string.format("[dwight] 🌿 Branch: %s", branch), vim.log.levels.INFO)

  -- Store issue metadata for post-completion PR flow
  M._active_issue = issue
  M._active_branch = branch

  -- Run agent
  local request = build_agent_request(issue)
  require("dwight.agent").run(request, {
    on_complete = function(success)
      vim.schedule(function()
        M._offer_pr(issue, success)
      end)
    end,
  })
end

--- Solve an issue via DwightAuto (multi-task decomposition).
--- Creates branch, runs auto, offers PR on completion.
function M.solve_auto(issue)
  local branch = M.create_branch(issue)
  vim.notify(string.format("[dwight] 🌿 Branch: %s", branch), vim.log.levels.INFO)

  M._active_issue = issue
  M._active_branch = branch

  local request = build_auto_request(issue)
  require("dwight.auto").auto(request)
end

--- Analyze an issue without changing code.
--- Posts analysis as a comment on the issue.
function M.analyze(issue)
  local request = string.format(
    "Analyze GitHub issue #%d: %s\n\n" ..
    "DO NOT make any changes. Instead, analyze the codebase and describe:\n" ..
    "1. What's causing the issue (root cause)\n" ..
    "2. Which files need to change\n" ..
    "3. A proposed approach (step by step)\n" ..
    "4. Potential risks or side effects\n\n" ..
    "Output your analysis as markdown.\n\n%s",
    issue.number, issue.title, M.build_issue_context(issue))

  vim.notify(string.format("[dwight] 🔍 Analyzing issue #%d…", issue.number), vim.log.levels.INFO)

  require("dwight.skills")._run_llm(request, function(raw, code)
    if code ~= 0 or vim.trim(raw or "") == "" then
      vim.notify("[dwight] Analysis failed.", vim.log.levels.ERROR)
      return
    end

    -- Show analysis in a buffer
    local buf = api.nvim_create_buf(false, true)
    local lines = vim.split(raw, "\n", { plain = true })
    api.nvim_buf_set_lines(buf, 0, -1, false, _flatten(lines))
    vim.bo[buf].filetype = "markdown"
    vim.bo[buf].bufhidden = "wipe"
    api.nvim_buf_set_name(buf,
      string.format("dwight://issue/%d/analysis", issue.number))
    vim.cmd("botright split")
    api.nvim_win_set_buf(0, buf)

    -- Keymap: p to post as comment
    vim.keymap.set("n", "p", function()
      vim.ui.select({ "Post as comment", "Cancel" }, {
        prompt = "Post this analysis to issue #" .. issue.number .. "?",
      }, function(choice)
        if choice == "Post as comment" then
          local analysis = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
          local comment = "## 🤖 Dwight Analysis\n\n" .. analysis
          M.comment(issue.number, comment, function(ok)
            if ok then
              vim.notify(string.format("[dwight] 💬 Analysis posted to #%d", issue.number),
                vim.log.levels.INFO)
            else
              vim.notify("[dwight] Failed to post comment.", vim.log.levels.ERROR)
            end
          end)
        end
      end)
    end, { buffer = buf, desc = "Post analysis as issue comment" })

    vim.notify(string.format(
      "[dwight] 🔍 Analysis ready for #%d. Press p to post as comment.", issue.number),
      vim.log.levels.INFO)
  end)
end

--- Offer to create a PR after solving an issue.
function M._offer_pr(issue, success)
  if not issue then return end

  local status_msg = success and "✅ Issue solved!" or "⚠️ Completed with errors."
  require("dwight.select").pick({
    "Push & open PR",
    "Push & open draft PR",
    "Just push (no PR)",
    "Skip (don't push)",
  }, {
    prompt = string.format("%s Create PR for #%d?", status_msg, issue.number),
  }, function(choice)
    if not choice or choice == "Skip (don't push)" then return end

    if choice == "Just push (no PR)" then
      local branch = run_git_sync({ "rev-parse", "--abbrev-ref", "HEAD" }, 1000)
      if branch then
        run_git_sync({ "push", "-u", "origin", vim.trim(branch) }, 15000)
        vim.notify("[dwight] 🚀 Pushed to origin.", vim.log.levels.INFO)
      end
      return
    end

    local draft = choice:match("draft") ~= nil

    -- Build PR title and body
    local pr_title = string.format("Fix #%d: %s", issue.number, issue.title:sub(1, 60))

    -- Try to get a smart summary from the commit log
    local log = run_git_sync({
      "log", "main..HEAD", "--oneline", "--no-decorate",
    }, 2000) or run_git_sync({
      "log", "master..HEAD", "--oneline", "--no-decorate",
    }, 2000) or ""

    local pr_body = "## Summary\n\n"
    if vim.trim(log) ~= "" then
      pr_body = pr_body .. "Changes:\n"
      for line in log:gmatch("[^\n]+") do
        pr_body = pr_body .. "- " .. line .. "\n"
      end
      pr_body = pr_body .. "\n"
    end

    M.create_pr({
      issue = issue.number,
      title = pr_title,
      body = pr_body,
      draft = draft,
    }, function(url, err)
      if err then
        vim.notify("[dwight] " .. err, vim.log.levels.ERROR)
      else
        vim.notify(string.format("[dwight] 🎉 PR created: %s", url or ""), vim.log.levels.INFO)
        -- Check CI status after a delay
        M._show_ci_after_pr(url)
      end
    end)
  end)
end

--------------------------------------------------------------------
-- Telescope picker
--------------------------------------------------------------------

--- Format an issue for the picker display.
--- Returns { text, highlights } where highlights is a list of { hl_group, col_start, col_end }.
local function format_issue_display(issue)
  local parts = {}
  local highlights = {}

  -- Issue number
  local num_str = string.format("#%-5d ", issue.number)
  parts[#parts + 1] = num_str

  -- Title
  parts[#parts + 1] = issue.title or ""

  -- Assignees
  if issue.assignees and #issue.assignees > 0 then
    local names = {}
    for _, a in ipairs(issue.assignees) do
      names[#names + 1] = "@" .. (type(a) == "table" and a.login or tostring(a))
    end
    parts[#parts + 1] = " → " .. table.concat(names, ",")
  end

  -- Milestone
  if issue.milestone and type(issue.milestone) == "table" and issue.milestone.title then
    parts[#parts + 1] = " 📌" .. issue.milestone.title
  end

  -- Labels (with color tracking for highlights)
  local label_info = {}
  if issue.labels and #issue.labels > 0 then
    local label_strs = {}
    for _, l in ipairs(issue.labels) do
      local name = type(l) == "table" and l.name or tostring(l)
      local color = type(l) == "table" and l.color or nil
      label_strs[#label_strs + 1] = name
      label_info[#label_info + 1] = { name = name, color = color }
    end
    parts[#parts + 1] = " [" .. table.concat(label_strs, ", ") .. "]"
  end

  local text = table.concat(parts, "")

  -- Build highlight positions for labels
  if #label_info > 0 then
    local bracket_pos = text:find(" %[", 1, false)
    if bracket_pos then
      local pos = bracket_pos + 2  -- after " ["
      for _, li in ipairs(label_info) do
        local hl = label_hl(li.color)
        if hl then
          highlights[#highlights + 1] = { hl, pos, pos + #li.name }
        end
        pos = pos + #li.name + 2  -- ", "
      end
    end
  end

  return text, highlights
end

--- Format issue body for the preview window.
local function format_issue_preview(issue)
  local lines = {
    "# #" .. issue.number .. ": " .. (issue.title or ""),
    "",
  }

  if issue.labels and #issue.labels > 0 then
    local names = {}
    for _, l in ipairs(issue.labels) do
      names[#names + 1] = type(l) == "table" and l.name or tostring(l)
    end
    lines[#lines + 1] = "**Labels:** " .. table.concat(names, ", ")
  end

  if issue.assignees and #issue.assignees > 0 then
    local names = {}
    for _, a in ipairs(issue.assignees) do
      names[#names + 1] = "@" .. (type(a) == "table" and a.login or tostring(a))
    end
    lines[#lines + 1] = "**Assignees:** " .. table.concat(names, ", ")
  end

  if issue.milestone and type(issue.milestone) == "table" and issue.milestone.title then
    lines[#lines + 1] = "**Milestone:** " .. issue.milestone.title
  end

  local author = issue.author
  if type(author) == "table" then author = author.login end
  if author then lines[#lines + 1] = "**Author:** " .. author end
  if issue.createdAt then lines[#lines + 1] = "**Created:** " .. issue.createdAt:sub(1, 10) end
  if issue.url then lines[#lines + 1] = "**URL:** " .. issue.url end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "---"
  lines[#lines + 1] = ""

  if issue.body and issue.body ~= "" then
    for line in issue.body:gmatch("[^\n]*") do
      lines[#lines + 1] = line
    end
  else
    lines[#lines + 1] = "(no description)"
  end

  if issue.comments and #issue.comments > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "---"
    lines[#lines + 1] = string.format("## Comments (%d)", #issue.comments)
    lines[#lines + 1] = ""

    local start_idx = math.max(1, #issue.comments - 4)
    for i = start_idx, #issue.comments do
      local c = issue.comments[i]
      local c_author = type(c.author) == "table" and c.author.login or (c.author or "?")
      lines[#lines + 1] = string.format("**@%s** (%s):", c_author, (c.createdAt or ""):sub(1, 10))
      for line in (c.body or ""):gmatch("[^\n]*") do
        lines[#lines + 1] = line
      end
      lines[#lines + 1] = ""
    end
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "---"
  lines[#lines + 1] = "**s** solve (Agent) | **S** solve (Auto) | **a** analyze | **e** open in buffer"

  return lines
end

--- Open the Telescope picker for GitHub issues.
function M.pick(opts)
  opts = opts or {}

  -- Preflight
  local check = M.check()
  if not check.ok then
    vim.notify("[dwight] " .. check.detail, vim.log.levels.ERROR)
    return
  end

  if not opts.repo and not M.is_github_repo() then
    vim.notify("[dwight] Not a GitHub repository (origin doesn't point to github.com).",
      vim.log.levels.ERROR)
    return
  end

  local filter_parts = {}
  if opts.milestone then filter_parts[#filter_parts + 1] = "📌" .. opts.milestone end
  if opts.label then filter_parts[#filter_parts + 1] = "🏷️" .. opts.label end
  if opts.repo then filter_parts[#filter_parts + 1] = "📦" .. opts.repo end
  local filter_str = #filter_parts > 0 and (" " .. table.concat(filter_parts, " ")) or ""

  vim.notify("[dwight] 📋 Fetching issues…" .. filter_str, vim.log.levels.INFO)

  M.list_issues(opts, function(issues, err)
    if err then
      vim.notify("[dwight] " .. err, vim.log.levels.ERROR)
      return
    end

    if not issues or #issues == 0 then
      vim.notify("[dwight] No open issues found.", vim.log.levels.INFO)
      return
    end

    local has_tel, pickers = pcall(require, "telescope.pickers")
    if not has_tel then
      M._pick_fallback(issues)
      return
    end

    local finders = require("telescope.finders")
    local conf = require("telescope.config").values
    local actions = require("telescope.actions")
    local action_state = require("telescope.actions.state")
    local previewers = require("telescope.previewers")
    local entry_display = nil
    pcall(function() entry_display = require("telescope.pickers.entry_display") end)

    pickers.new({}, {
      prompt_title = string.format("📋 GitHub Issues (%d open)%s", #issues, filter_str),
      finder = finders.new_table({
        results = issues,
        entry_maker = function(issue)
          local text, highlights = format_issue_display(issue)
          return {
            value = issue,
            display = function(entry)
              -- Apply label color highlights if telescope supports it
              if highlights and #highlights > 0 then
                return text, highlights
              end
              return text
            end,
            ordinal = string.format("%d %s %s", issue.number, issue.title,
              issue.assignees and #issue.assignees > 0
                and (issue.assignees[1].login or "") or ""),
          }
        end,
      }),
      sorter = conf.generic_sorter({}),
      previewer = previewers.new_buffer_previewer({
        title = "Issue Preview  s=solve(Agent) S=solve(Auto) a=analyze e=open",
        define_preview = function(self, entry)
          local lines = format_issue_preview(entry.value)
          api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, _flatten(lines))
          vim.bo[self.state.bufnr].filetype = "markdown"
        end,
      }),
      attach_mappings = function(prompt_bufnr, map_fn)
        -- Enter: action picker
        actions.select_default:replace(function()
          local entry = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if entry then M._action_picker(entry.value) end
        end)

        -- s: solve with DwightAgent
        local function map_solve_agent()
          local entry = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if entry then M.solve_agent(entry.value) end
        end
        map_fn("i", "<C-s>", map_solve_agent)
        map_fn("n", "s", map_solve_agent)

        -- S: solve with DwightAuto
        local function map_solve_auto()
          local entry = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if entry then M.solve_auto(entry.value) end
        end
        map_fn("n", "S", map_solve_auto)

        -- a: analyze
        local function map_analyze()
          local entry = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if entry then M.analyze(entry.value) end
        end
        map_fn("i", "<C-a>", map_analyze)
        map_fn("n", "a", map_analyze)

        -- e: open in buffer
        local function map_open()
          local entry = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if entry then M._open_issue_buffer(entry.value) end
        end
        map_fn("i", "<C-e>", map_open)
        map_fn("n", "e", map_open)

        return true
      end,
    }):find()
  end)
end

--- Action picker after selecting an issue (when pressing Enter).
function M._action_picker(issue)
  require("dwight.select").pick({
    "🤖 Solve with DwightAgent (single task)",
    "🤖 Solve with DwightAuto (multi-task)",
    "🔍 Analyze (read-only, optional comment)",
    "📄 Open in buffer (manual work)",
  }, {
    prompt = string.format("Issue #%d: %s", issue.number, issue.title:sub(1, 50)),
  }, function(choice)
    if not choice then return end
    if choice:match("DwightAgent") then
      M.solve_agent(issue)
    elseif choice:match("DwightAuto") then
      M.solve_auto(issue)
    elseif choice:match("Analyze") then
      M.analyze(issue)
    elseif choice:match("Open in buffer") then
      M._open_issue_buffer(issue)
    end
  end)
end

--- Open an issue as a read-only buffer for context while working.
function M._open_issue_buffer(issue)
  local buf = api.nvim_create_buf(false, true)
  local lines = format_issue_preview(issue)
  api.nvim_buf_set_lines(buf, 0, -1, false, _flatten(lines))
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  api.nvim_buf_set_name(buf, string.format("dwight://issue/%d", issue.number))

  vim.cmd("botright vsplit")
  api.nvim_win_set_buf(0, buf)
  vim.wo[0].number = false
  vim.wo[0].relativenumber = false
  vim.wo[0].wrap = true
  vim.wo[0].winfixwidth = true
  api.nvim_win_set_width(0, 60)

  -- Keymaps in the issue buffer
  vim.keymap.set("n", "s", function()
    M.solve_agent(issue)
  end, { buffer = buf, desc = "Solve with DwightAgent" })

  vim.keymap.set("n", "S", function()
    M.solve_auto(issue)
  end, { buffer = buf, desc = "Solve with DwightAuto" })

  vim.keymap.set("n", "a", function()
    M.analyze(issue)
  end, { buffer = buf, desc = "Analyze issue" })

  vim.keymap.set("n", "q", function()
    if api.nvim_buf_is_valid(buf) then
      pcall(api.nvim_buf_delete, buf, { force = true })
    end
  end, { buffer = buf, desc = "Close issue buffer" })

  vim.notify(string.format(
    "[dwight] 📄 Issue #%d open. s=solve(Agent) S=solve(Auto) a=analyze q=close",
    issue.number), vim.log.levels.INFO)
end

--- Fallback picker when Telescope is not available.
function M._pick_fallback(issues)
  local items = {}
  for _, issue in ipairs(issues) do
    local text = format_issue_display(issue)
    items[#items + 1] = text
  end

  require("dwight.select").pick(items, {
    prompt = "Select issue:",
  }, function(_, idx)
    if idx then M._action_picker(issues[idx]) end
  end)
end

--------------------------------------------------------------------
-- Direct issue solve (for :DwightIssue N)
--------------------------------------------------------------------

--- Fetch and solve a specific issue by number.
--- opts.repo — "owner/repo" for cross-repo
function M.solve_by_number(number, mode, opts)
  mode = mode or "pick"
  opts = opts or {}

  local check = M.check()
  if not check.ok then
    vim.notify("[dwight] " .. check.detail, vim.log.levels.ERROR)
    return
  end

  local repo_str = opts.repo and (" in " .. opts.repo) or ""
  vim.notify(string.format("[dwight] 📋 Fetching issue #%d%s…", number, repo_str), vim.log.levels.INFO)

  M.get_issue(number, function(issue, err)
    if err then
      vim.notify("[dwight] " .. err, vim.log.levels.ERROR)
      return
    end

    if mode == "agent" then
      M.solve_agent(issue)
    elseif mode == "auto" then
      M.solve_auto(issue)
    elseif mode == "analyze" then
      M.analyze(issue)
    else
      M._action_picker(issue)
    end
  end, { repo = opts.repo })
end

--------------------------------------------------------------------
-- Post-solve: offer PR (called from agent/auto completion hooks)
--------------------------------------------------------------------

--- Check if there's an active issue and offer PR.
--- Called by integration.post_session or manually.
function M.maybe_offer_pr()
  if M._active_issue then
    M._offer_pr(M._active_issue, true)
    M._active_issue = nil
    M._active_branch = nil
  end
end

--------------------------------------------------------------------
-- Issue templates: use repo's .github/ISSUE_TEMPLATE/ when creating
--------------------------------------------------------------------

--- Fetch repo issue templates.
--- callback(templates) where templates = { { name, body, labels, about }, ... } or {}
function M.list_templates(callback, opts)
  opts = opts or {}
  -- gh api repos/{owner}/{repo}/contents/.github/ISSUE_TEMPLATE
  local repo = opts.repo or M.current_repo()
  if not repo then callback({}); return end

  run_gh({
    "api", "repos/" .. repo .. "/contents/.github/ISSUE_TEMPLATE",
    "--jq", '[.[] | select(.name | endswith(".md") or endswith(".yml") or endswith(".yaml")) | .download_url]',
  }, function(out, code)
    if code ~= 0 or not out or vim.trim(out) == "" then
      callback({})
      return
    end

    local ok, urls = pcall(vim.json.decode, out)
    if not ok or type(urls) ~= "table" then callback({}); return end

    -- Fetch each template
    local templates = {}
    local pending = #urls
    if pending == 0 then callback({}); return end

    for _, url in ipairs(urls) do
      run_gh({ "api", url, "--jq", "." }, function(raw, c)
        if c == 0 and raw and raw ~= "" then
          -- Parse YAML frontmatter
          local name = raw:match("name:%s*[\"']?([^\n\"']+)")
          local about = raw:match("about:%s*[\"']?([^\n\"']+)")
          local labels_str = raw:match("labels:%s*%[([^%]]+)%]")
            or raw:match("labels:%s*([^\n]+)")
          local body_start = raw:find("---", 4, true)
          local body = body_start and raw:sub(body_start + 4) or raw

          templates[#templates + 1] = {
            name = name or url:match("/([^/]+)$") or "template",
            about = about or "",
            body = vim.trim(body),
            labels = labels_str,
          }
        end

        pending = pending - 1
        if pending == 0 then
          table.sort(templates, function(a, b) return a.name < b.name end)
          callback(templates)
        end
      end)
    end
  end)
end

--- Create a new issue, optionally using a repo template.
function M.create_issue(opts, callback)
  opts = opts or {}

  -- If no template chosen yet, let user pick one
  if not opts.body and not opts._skip_template then
    M.list_templates(function(templates)
      if #templates == 0 then
        opts._skip_template = true
        M.create_issue(opts, callback)
        return
      end

      local items = { "📝 Blank issue" }
      for _, t in ipairs(templates) do
        items[#items + 1] = string.format("📋 %s — %s", t.name, t.about)
      end

      require("dwight.select").pick(items, {
        prompt = "Choose issue template:",
      }, function(choice, idx)
        if not choice then return end
        if idx == 1 then
          opts._skip_template = true
          M.create_issue(opts, callback)
        else
          local tmpl = templates[idx - 1]
          opts.body = tmpl.body
          if tmpl.labels and not opts.labels then
            opts.labels = tmpl.labels
          end
          M.create_issue(opts, callback)
        end
      end)
      return
    end, opts)
    return
  end

  -- Build gh issue create args
  local args = repo_flag(opts.repo)
  vim.list_extend(args, { "issue", "create" })

  if opts.title then
    args[#args + 1] = "--title"
    args[#args + 1] = opts.title
  end
  if opts.body then
    args[#args + 1] = "--body"
    args[#args + 1] = opts.body
  end
  if opts.labels then
    args[#args + 1] = "--label"
    args[#args + 1] = opts.labels
  end
  if opts.milestone then
    args[#args + 1] = "--milestone"
    args[#args + 1] = opts.milestone
  end
  if opts.assignee then
    args[#args + 1] = "--assignee"
    args[#args + 1] = opts.assignee
  end

  -- If no title, open gh interactive mode (--web or editor)
  if not opts.title then
    args[#args + 1] = "--web"
  end

  run_gh(args, function(out, code)
    if callback then
      callback(code == 0 and vim.trim(out) or nil, code ~= 0 and out or nil)
    end
    if code == 0 then
      vim.notify(string.format("[dwight] ✅ Issue created: %s", vim.trim(out or "")),
        vim.log.levels.INFO)
    end
  end)
end

--------------------------------------------------------------------
-- PR Review: AI-assisted review of incoming pull requests
--------------------------------------------------------------------

local PR_FIELDS = "number,title,body,state,author,baseRefName,headRefName,additions,deletions,changedFiles,files,url,labels,assignees,milestone,reviewDecision,reviews"

--- List open PRs.
function M.list_prs(opts, callback)
  opts = opts or {}
  local args = repo_flag(opts.repo)
  vim.list_extend(args, {
    "pr", "list",
    "--json", PR_FIELDS,
    "--limit", tostring(opts.limit or 20),
    "--state", opts.state or "open",
  })

  if opts.label then args[#args + 1] = "--label"; args[#args + 1] = opts.label end
  if opts.assignee then args[#args + 1] = "--assignee"; args[#args + 1] = opts.assignee end

  run_gh(args, function(out, code)
    if code ~= 0 then callback(nil, "gh pr list failed: " .. (out or ""):sub(1, 200)); return end
    local ok, data = pcall(vim.json.decode, out)
    if not ok then callback(nil, "Failed to parse PR list"); return end
    callback(data, nil)
  end)
end

--- Get the diff for a PR.
function M.get_pr_diff(number, callback, opts)
  opts = opts or {}
  local args = repo_flag(opts.repo)
  vim.list_extend(args, { "pr", "diff", tostring(number) })
  run_gh(args, function(out, code)
    callback(code == 0 and out or nil, code ~= 0 and out or nil)
  end)
end

--- Get full PR details.
function M.get_pr(number, callback, opts)
  opts = opts or {}
  local args = repo_flag(opts.repo)
  vim.list_extend(args, { "pr", "view", tostring(number), "--json", PR_FIELDS })
  run_gh(args, function(out, code)
    if code ~= 0 then callback(nil, out); return end
    local ok, data = pcall(vim.json.decode, out)
    if not ok then callback(nil, "parse error"); return end
    callback(data, nil)
  end)
end

--- Review a PR with AI analysis.
--- Shows diff, runs agentic analysis, displays findings.
function M.review_pr(number, opts)
  opts = opts or {}

  local check = M.check()
  if not check.ok then
    vim.notify("[dwight] " .. check.detail, vim.log.levels.ERROR)
    return
  end

  vim.notify(string.format("[dwight] 🔍 Fetching PR #%d for review…", number), vim.log.levels.INFO)

  -- Fetch PR details and diff in parallel
  local pr_data, diff_data, done_count = nil, nil, 0
  local function check_done()
    done_count = done_count + 1
    if done_count < 2 then return end

    if not pr_data then
      vim.notify("[dwight] Failed to fetch PR details.", vim.log.levels.ERROR)
      return
    end

    -- Build review prompt
    local diff_text = diff_data or "(diff unavailable)"
    if #diff_text > 40000 then
      diff_text = diff_text:sub(1, 40000) .. "\n... (diff truncated)"
    end

    local prompt = string.format([[
You are a senior engineer reviewing Pull Request #%d: "%s"

Branch: %s → %s
Changes: +%d -%d across %d file(s)

## PR Description
%s

## Diff
```diff
%s
```

## Your Review Task

Analyze this PR thoroughly and write your review to `.dwight/artifacts/pr-review.json` in this format:
```json
{
  "summary": "2-3 sentence overall assessment",
  "verdict": "approve|request_changes|comment",
  "findings": [
    {
      "file": "path/to/file.go",
      "line": 42,
      "severity": "CRITICAL|WARN|SUGGESTION|PRAISE",
      "comment": "detailed review comment"
    }
  ],
  "suggestions": ["overall suggestion 1", "overall suggestion 2"]
}
```

Focus on:
- Logic errors, bugs, edge cases
- Security vulnerabilities
- Performance issues
- Code style consistency
- Missing tests or error handling
- Good patterns worth praising (severity=PRAISE)

IMPORTANT: `mkdir -p .dwight/artifacts` before writing. Do NOT modify any source files.
]], pr_data.number, pr_data.title or "",
      pr_data.headRefName or "?", pr_data.baseRefName or "?",
      pr_data.additions or 0, pr_data.deletions or 0, pr_data.changedFiles or 0,
      (pr_data.body or "(no description)"):sub(1, 5000),
      diff_text)

    -- Run agentic review
    local agentic = require("dwight.agentic")
    local status_mod = require("dwight.agent_status")

    status_mod.open()
    status_mod.start_session(string.format("🔍 PR Review: #%d", number))
    status_mod.append(string.format("🔍 Reviewing PR #%d: %s", number, (pr_data.title or ""):sub(1, 50)))
    status_mod.append(string.format("   +%d -%d across %d files",
      pr_data.additions or 0, pr_data.deletions or 0, pr_data.changedFiles or 0))

    agentic.run({
      task = prompt,
      on_status = function(text)
        status_mod.stop_spin()
        status_mod.append(text)
      end,
      on_tool = function(desc)
        status_mod.spin(desc)
      end,
      on_complete = function(success)
        status_mod.stop_spin()
        if not success then
          status_mod.append("❌ PR review failed")
          return
        end

        -- Parse review result
        local project = require("dwight.project")
        local result_path = project.is_initialized()
          and (project.dir() .. "/artifacts/pr-review.json") or nil
        local review = nil
        if result_path then
          local f = io.open(result_path, "r")
          if f then
            local raw = f:read("*a"); f:close()
            os.remove(result_path)
            local parse_ok, parsed = pcall(vim.json.decode, raw)
            if parse_ok then review = parsed end
          end
        end

        if not review then
          status_mod.append("⚠️  Agent did not produce structured review")
          return
        end

        M._show_pr_review(pr_data, review)
      end,
    })
  end

  M.get_pr(number, function(data, err)
    if err then vim.notify("[dwight] PR fetch error: " .. tostring(err), vim.log.levels.WARN) end
    pr_data = data
    check_done()
  end, opts)

  M.get_pr_diff(number, function(diff, err)
    diff_data = diff
    check_done()
  end, opts)
end

--- Display PR review results in a buffer with action keybindings.
function M._show_pr_review(pr, review)
  local lines = {
    "╔══════════════════════════════════════════════════════════════╗",
    string.format("║  PR Review: #%d — %s", pr.number, (pr.title or ""):sub(1, 50)),
    "╚══════════════════════════════════════════════════════════════╝",
    "",
  }

  -- Verdict
  local verdict_icon = review.verdict == "approve" and "✅"
    or review.verdict == "request_changes" and "❌" or "💬"
  lines[#lines + 1] = string.format("  Verdict: %s %s", verdict_icon, review.verdict or "comment")
  lines[#lines + 1] = ""

  -- Summary
  if review.summary then
    lines[#lines + 1] = "  📝 " .. review.summary
    lines[#lines + 1] = ""
  end

  -- Findings
  local sev_icons = { CRITICAL = "🔴", WARN = "🟡", SUGGESTION = "💡", PRAISE = "🌟" }
  if review.findings and #review.findings > 0 then
    lines[#lines + 1] = "  ─── Findings ───"
    lines[#lines + 1] = ""
    local current_file = ""
    for _, f in ipairs(review.findings) do
      if f.file and f.file ~= current_file then
        current_file = f.file
        lines[#lines + 1] = string.format("  📄 %s", current_file)
      end
      local icon = sev_icons[f.severity] or "💬"
      lines[#lines + 1] = string.format("  %s L%d: %s",
        icon, f.line or 0, f.comment or "")
    end
    lines[#lines + 1] = ""
  end

  -- Suggestions
  if review.suggestions and #review.suggestions > 0 then
    lines[#lines + 1] = "  ─── Suggestions ───"
    for _, s in ipairs(review.suggestions) do
      lines[#lines + 1] = "  • " .. s
    end
    lines[#lines + 1] = ""
  end

  lines[#lines + 1] = "  ─── Actions ───"
  lines[#lines + 1] = "  p     Post review to GitHub"
  lines[#lines + 1] = "  q     Close"

  -- Display in split
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, _flatten(lines))
  vim.bo[buf].modifiable = false
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "dwight_review"

  vim.cmd("botright split")
  local win = api.nvim_get_current_win()
  api.nvim_win_set_buf(win, buf)
  api.nvim_win_set_height(win, math.min(#lines + 2, math.floor(vim.o.lines * 0.5)))

  local function safe_close()
    local wins = api.nvim_tabpage_list_wins(0)
    if #wins <= 1 then vim.cmd("enew") else api.nvim_win_close(win, true) end
  end

  -- p: Post review to GitHub
  vim.keymap.set("n", "p", function()
    -- Build review body
    local body_parts = { "## 🤖 Dwight PR Review\n" }
    if review.summary then body_parts[#body_parts + 1] = review.summary .. "\n" end

    if review.findings and #review.findings > 0 then
      body_parts[#body_parts + 1] = "\n### Findings\n"
      for _, f in ipairs(review.findings) do
        local icon = sev_icons[f.severity] or "💬"
        body_parts[#body_parts + 1] = string.format("- %s **%s:%d** — %s",
          icon, f.file or "?", f.line or 0, f.comment or "")
      end
    end

    if review.suggestions and #review.suggestions > 0 then
      body_parts[#body_parts + 1] = "\n### Suggestions\n"
      for _, s in ipairs(review.suggestions) do
        body_parts[#body_parts + 1] = "- " .. s
      end
    end

    local review_body = table.concat(body_parts, "\n")
    local event = review.verdict == "approve" and "APPROVE"
      or review.verdict == "request_changes" and "REQUEST_CHANGES"
      or "COMMENT"

    run_gh({
      "pr", "review", tostring(pr.number),
      "--" .. event:lower():gsub("_", "-"),
      "--body", review_body,
    }, function(out, code)
      if code == 0 then
        vim.notify(string.format("[dwight] ✅ Review posted to PR #%d (%s)", pr.number, event),
          vim.log.levels.INFO)
      else
        vim.notify("[dwight] ❌ Failed to post review: " .. (out or ""):sub(1, 200),
          vim.log.levels.ERROR)
      end
    end)
  end, { buffer = buf, desc = "Post review to GitHub" })

  -- q: Close
  vim.keymap.set("n", "q", safe_close, { buffer = buf, desc = "Close" })

  vim.notify(string.format("[dwight] 🔍 PR #%d review ready. p=post q=close", pr.number),
    vim.log.levels.INFO)
end

--------------------------------------------------------------------
-- PR review picker
--------------------------------------------------------------------

--- Open Telescope picker for PRs to review.
function M.pick_pr(opts)
  opts = opts or {}

  local check = M.check()
  if not check.ok then
    vim.notify("[dwight] " .. check.detail, vim.log.levels.ERROR)
    return
  end

  vim.notify("[dwight] 📋 Fetching PRs…", vim.log.levels.INFO)

  M.list_prs(opts, function(prs, err)
    if err then
      vim.notify("[dwight] " .. err, vim.log.levels.ERROR)
      return
    end
    if not prs or #prs == 0 then
      vim.notify("[dwight] No open PRs found.", vim.log.levels.INFO)
      return
    end

    local items = {}
    for _, pr in ipairs(prs) do
      local author = type(pr.author) == "table" and pr.author.login or (pr.author or "?")
      items[#items + 1] = string.format("#%-5d %s → %s  (+%d/-%d)  @%s  %s",
        pr.number, (pr.headRefName or "?"):sub(1, 20), (pr.baseRefName or "?"):sub(1, 10),
        pr.additions or 0, pr.deletions or 0, author,
        (pr.title or ""):sub(1, 40))
    end

    require("dwight.select").pick(items, {
      prompt = "Select PR to review:",
    }, function(_, idx)
      if idx then M.review_pr(prs[idx].number, opts) end
    end)
  end)
end

--------------------------------------------------------------------
-- CI/CD integration: status, logs, auto-fix
--------------------------------------------------------------------

--- Fetch CI/check status for the current branch (or a specific PR).
--- callback(checks, err) where checks = { overall, items = { { name, status, conclusion, url, run_id }, ... } }
function M.ci_status(opts, callback)
  opts = opts or {}
  local args = repo_flag(opts.repo)

  if opts.pr_number then
    -- Get checks for a specific PR
    vim.list_extend(args, {
      "pr", "checks", tostring(opts.pr_number),
      "--json", "name,state,conclusion,detailsUrl",
    })
  else
    -- Get checks for current branch
    local branch = run_git_sync({ "rev-parse", "--abbrev-ref", "HEAD" }, 1000)
    if not branch then
      callback(nil, "Not on a branch")
      return
    end
    branch = vim.trim(branch)

    -- Use `gh run list` for the current branch
    vim.list_extend(args, {
      "run", "list",
      "--branch", branch,
      "--limit", "10",
      "--json", "databaseId,name,status,conclusion,headBranch,event,createdAt,url",
    })
  end

  run_gh(args, function(out, code)
    if code ~= 0 then
      callback(nil, "Failed to fetch CI status: " .. (out or ""):sub(1, 200))
      return
    end

    local ok, data = pcall(vim.json.decode, out)
    if not ok or type(data) ~= "table" then
      callback(nil, "Failed to parse CI status")
      return
    end

    -- Normalize the data (pr checks vs run list have different shapes)
    local items = {}
    local overall = "success"  -- default until proven otherwise

    for _, entry in ipairs(data) do
      local status = entry.status or entry.state or "unknown"
      local conclusion = entry.conclusion or ""
      local name = entry.name or "unknown"

      -- Normalize status
      local normalized
      if status == "completed" then
        normalized = conclusion == "success" and "success"
          or conclusion == "failure" and "failure"
          or conclusion == "cancelled" and "cancelled"
          or conclusion == "skipped" and "skipped"
          or "unknown"
      elseif status == "in_progress" or status == "queued" or status == "waiting"
        or status == "pending" or status == "requested" then
        normalized = "running"
      else
        normalized = status:lower()
      end

      -- Track overall status
      if normalized == "failure" then overall = "failure"
      elseif normalized == "running" and overall ~= "failure" then overall = "running"
      end

      items[#items + 1] = {
        name = name,
        status = normalized,
        conclusion = conclusion,
        url = entry.url or entry.detailsUrl or "",
        run_id = entry.databaseId,
        event = entry.event,
        created_at = entry.createdAt,
      }
    end

    callback({
      overall = #items > 0 and overall or "none",
      items = items,
      branch = run_git_sync({ "rev-parse", "--abbrev-ref", "HEAD" }, 1000),
    }, nil)
  end)
end

--- Fetch logs for a failed CI run.
--- callback(logs, err)
function M.ci_logs(run_id, opts, callback)
  opts = opts or {}
  local args = repo_flag(opts.repo)
  vim.list_extend(args, { "run", "view", tostring(run_id), "--log-failed" })

  run_gh(args, function(out, code)
    if code ~= 0 then
      -- Try full log if --log-failed not available
      local args2 = repo_flag(opts.repo)
      vim.list_extend(args2, { "run", "view", tostring(run_id), "--log" })
      run_gh(args2, function(out2, code2)
        if code2 ~= 0 then
          callback(nil, "Failed to fetch CI logs")
        else
          -- Truncate to last 200 lines (full logs can be huge)
          local lines = vim.split(out2 or "", "\n", { plain = true })
          if #lines > 200 then
            local truncated = {}
            for i = #lines - 199, #lines do truncated[#truncated + 1] = lines[i] end
            callback(table.concat(truncated, "\n"), nil)
          else
            callback(out2 or "", nil)
          end
        end
      end)
    else
      callback(out or "", nil)
    end
  end)
end

--- Re-run a failed CI workflow.
--- callback(success, msg)
function M.ci_rerun(run_id, opts, callback)
  opts = opts or {}
  local args = repo_flag(opts.repo)
  vim.list_extend(args, { "run", "rerun", tostring(run_id), "--failed" })

  run_gh(args, function(out, code)
    if code ~= 0 then
      callback(false, "Re-run failed: " .. (out or ""):sub(1, 200))
    else
      callback(true, "Re-run triggered for run #" .. tostring(run_id))
    end
  end)
end

--- Show CI status in an interactive buffer.
function M.ci_show(opts)
  opts = opts or {}

  local check = M.check()
  if not check.ok then
    vim.notify("[dwight] " .. check.detail, vim.log.levels.ERROR)
    return
  end

  vim.notify("[dwight] 🔄 Fetching CI status…", vim.log.levels.INFO)

  M.ci_status(opts, function(checks, err)
    if err then
      vim.notify("[dwight] " .. err, vim.log.levels.ERROR)
      return
    end

    if not checks or #checks.items == 0 then
      vim.notify("[dwight] No CI runs found for this branch.", vim.log.levels.INFO)
      return
    end

    local branch = checks.branch and vim.trim(checks.branch) or "(unknown)"

    -- Status icons
    local icons = {
      success = "✅", failure = "❌", running = "🔄",
      cancelled = "⏹️", skipped = "⏭️", none = "⚪",
      unknown = "❓",
    }

    local overall_icon = icons[checks.overall] or "❓"

    local lines = {
      "═══════════════════════════════════════════════════",
      string.format("  %s CI Status: %s — %s", overall_icon, branch, checks.overall:upper()),
      "═══════════════════════════════════════════════════",
      "",
    }

    -- Find failed runs for action picking
    local failed_runs = {}

    for _, item in ipairs(checks.items) do
      local icon = icons[item.status] or "❓"
      local created = item.created_at and item.created_at:sub(1, 16):gsub("T", " ") or ""
      lines[#lines + 1] = string.format("  %s %-35s %s", icon, item.name:sub(1, 35), created)

      if item.status == "failure" and item.run_id then
        failed_runs[#failed_runs + 1] = item
        lines[#lines + 1] = string.format("     Run #%d — %s", item.run_id,
          item.url ~= "" and item.url or "(no URL)")
      end
    end

    lines[#lines + 1] = ""
    lines[#lines + 1] = "───────────────────────────────────────────────────"

    if #failed_runs > 0 then
      lines[#lines + 1] = "  Keybindings:"
      lines[#lines + 1] = "    l — View logs for first failed run"
      lines[#lines + 1] = "    f — Auto-fix: read logs → fix → push"
      lines[#lines + 1] = "    r — Re-run failed workflows"
      lines[#lines + 1] = "    o — Open in browser"
      lines[#lines + 1] = "    R — Refresh"
      lines[#lines + 1] = "    q — Close"
    else
      lines[#lines + 1] = "    o — Open in browser"
      lines[#lines + 1] = "    R — Refresh"
      lines[#lines + 1] = "    q — Close"
    end

    local buf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_name(buf, "dwight://ci-status/" .. branch)
    api.nvim_buf_set_lines(buf, 0, -1, false, require("dwight.util").flatten_lines(lines))
    vim.bo[buf].filetype = "markdown"
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].modifiable = false
    vim.bo[buf].bufhidden = "wipe"

    vim.cmd("botright split")
    local win = api.nvim_get_current_win()
    api.nvim_win_set_buf(win, buf)
    vim.cmd("resize " .. math.min(#lines + 2, 30))

    -- Keybindings
    local function close()
      pcall(api.nvim_win_close, win, true)
    end

    vim.keymap.set("n", "q", close, { buffer = buf })

    vim.keymap.set("n", "R", function()
      close()
      M.ci_show(opts)
    end, { buffer = buf, desc = "Refresh CI status" })

    vim.keymap.set("n", "o", function()
      if #checks.items > 0 and checks.items[1].url ~= "" then
        vim.fn.system({ "open", checks.items[1].url })
        vim.notify("[dwight] Opened in browser.", vim.log.levels.INFO)
      end
    end, { buffer = buf, desc = "Open in browser" })

    if #failed_runs > 0 then
      local first_failed = failed_runs[1]

      vim.keymap.set("n", "l", function()
        close()
        vim.notify("[dwight] 📜 Fetching CI logs for " .. first_failed.name .. "…", vim.log.levels.INFO)
        M.ci_logs(first_failed.run_id, opts, function(logs, log_err)
          if log_err then
            vim.notify("[dwight] " .. log_err, vim.log.levels.ERROR)
            return
          end

          -- Show logs in a buffer
          local log_buf = api.nvim_create_buf(false, true)
          api.nvim_buf_set_name(log_buf, "dwight://ci-logs/" .. first_failed.run_id)
          api.nvim_buf_set_lines(log_buf, 0, -1, false,
            vim.split(logs or "(no logs)", "\n", { plain = true }))
          vim.bo[log_buf].buftype = "nofile"
          vim.bo[log_buf].modifiable = false
          vim.bo[log_buf].bufhidden = "wipe"

          vim.cmd("botright split")
          local log_win = api.nvim_get_current_win()
          api.nvim_win_set_buf(log_win, log_buf)

          vim.keymap.set("n", "q", function()
            pcall(api.nvim_win_close, log_win, true)
          end, { buffer = log_buf })

          vim.keymap.set("n", "f", function()
            pcall(api.nvim_win_close, log_win, true)
            M.ci_fix(first_failed.run_id, opts)
          end, { buffer = log_buf, desc = "Auto-fix from these logs" })
        end)
      end, { buffer = buf, desc = "View CI logs" })

      vim.keymap.set("n", "f", function()
        close()
        M.ci_fix(first_failed.run_id, opts)
      end, { buffer = buf, desc = "Auto-fix CI failure" })

      vim.keymap.set("n", "r", function()
        close()
        vim.notify("[dwight] 🔄 Re-running failed workflows…", vim.log.levels.INFO)
        for _, fr in ipairs(failed_runs) do
          M.ci_rerun(fr.run_id, opts, function(ok, msg)
            vim.notify("[dwight] " .. msg, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
          end)
        end
      end, { buffer = buf, desc = "Re-run failed workflows" })
    end
  end)
end

--- Auto-fix a CI failure: fetch logs, agent fixes code, push.
function M.ci_fix(run_id, opts)
  opts = opts or {}

  vim.notify("[dwight] 🔧 Fetching CI logs for auto-fix…", vim.log.levels.INFO)

  M.ci_logs(run_id, opts, function(logs, err)
    if err then
      vim.notify("[dwight] " .. err, vim.log.levels.ERROR)
      return
    end

    -- Truncate logs if too long
    if #logs > 40000 then
      logs = "... (truncated — showing last 40K chars)\n" .. logs:sub(-40000)
    end

    local branch = run_git_sync({ "rev-parse", "--abbrev-ref", "HEAD" }, 1000)
    branch = branch and vim.trim(branch) or "current"

    local prompt = string.format([=[
You are fixing a CI/CD failure. The CI pipeline failed on branch '%s'.

## Failed CI Logs

```
%s
```

## Your Task — IN ORDER

### Step 1: Analyze the failure
Read the CI logs carefully and identify:
- Which step(s) failed
- The root cause (test failure, lint error, build error, type error, etc.)
- Which file(s) need to be fixed

### Step 2: Read the relevant source files
Read the files mentioned in the error logs to understand the context.

### Step 3: Fix the issue(s)
Apply the minimal fix needed to resolve the CI failure. Common fixes:
- Fix failing test assertions
- Fix lint errors (formatting, unused vars, etc.)
- Fix type errors or missing imports
- Fix build configuration issues
- Update dependency versions if needed

### Step 4: Verify the fix
If there's a way to run the failing check locally (test command, lint command), run it
to verify your fix works before pushing.

### Step 5: Commit and push
After fixing, commit with a descriptive message like:
  "fix: resolve CI failure — [brief description of what was wrong]"

Then push to the remote.

## Rules
- Make the MINIMUM changes needed to fix CI — don't refactor unrelated code
- If the fix requires changing tests, make sure the tests still test the right behavior
- If you can't determine the cause from the logs, say so
- Do NOT modify CI config files unless the failure is clearly a config issue
]=], branch, logs)

    vim.notify("[dwight] 🤖 Starting CI auto-fix agent…", vim.log.levels.INFO)

    local agent = require("dwight.agent")
    agent.run(prompt, {
      plan = false,  -- prompt IS the plan
      on_complete = function(success)
        vim.schedule(function()
          if success then
            vim.notify(
              "[dwight] 🤖 CI fix applied and pushed!\n" ..
              "Run :DwightCI to check if the new run passes.",
              vim.log.levels.INFO)
          else
            vim.notify(
              "[dwight] 🤖 CI fix had errors. Check :DwightAgentStatus for details.",
              vim.log.levels.WARN)
          end
        end)
      end,
    })
  end)
end

--- Show CI status inline after PR creation (called from _offer_pr flow).
function M._show_ci_after_pr(pr_url, opts)
  opts = opts or {}

  -- Extract PR number from URL
  local pr_number = pr_url and pr_url:match("/pull/(%d+)")
  if not pr_number then return end

  -- Wait a bit for CI to start, then poll
  vim.defer_fn(function()
    vim.notify("[dwight] 🔄 Checking CI status for PR #" .. pr_number .. "…", vim.log.levels.INFO)

    M.ci_status({ pr_number = tonumber(pr_number), repo = opts.repo }, function(checks, err)
      if err then return end
      if not checks or #checks.items == 0 then
        vim.notify("[dwight] No CI checks found yet for PR #" .. pr_number .. ". They may still be starting.", vim.log.levels.INFO)
        return
      end

      local icons = {
        success = "✅", failure = "❌", running = "🔄",
        cancelled = "⏹️", skipped = "⏭️", none = "⚪",
      }
      local overall_icon = icons[checks.overall] or "❓"

      local parts = { string.format("[dwight] %s CI for PR #%s: %s",
        overall_icon, pr_number, checks.overall:upper()) }

      for _, item in ipairs(checks.items) do
        local icon = icons[item.status] or "❓"
        parts[#parts + 1] = string.format("  %s %s", icon, item.name)
      end

      if checks.overall == "failure" then
        parts[#parts + 1] = ""
        parts[#parts + 1] = "Run :DwightCI to see details or press 'f' to auto-fix."
      end

      vim.notify(table.concat(parts, "\n"), vim.log.levels.INFO)
    end)
  end, 5000)  -- 5s delay for CI to register
end

return M
