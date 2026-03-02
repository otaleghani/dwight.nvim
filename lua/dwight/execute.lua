-- dwight/execute.lua
-- ⚠️ DEPRECATED — This module implements the legacy plan→execute pipeline.
-- The agentic tool-use loop (agentic.lua) has replaced this architecture.
-- This file is kept for reference but is no longer called by any active code path.
-- It will be removed in a future version.
--
-- Original purpose:
-- Parse and execute @dwight: directives from a plan.
-- Supports: action, prompt, verify (with on-fail retry), delegate (recursive sub-plans).

local M = {}

local api = vim.api

-- Recursion and retry limits
M.MAX_RETRIES = 3
M.MAX_DEPTH = 3

--------------------------------------------------------------------
-- Session file registry: tracks all files touched during execution.
-- Injected into every prompt so the LLM knows what exists.
--------------------------------------------------------------------

local _session_registry = {}  -- { path = "created"|"edited"|"deleted" }

--- Reset the session registry. Called at the start of each execution.
function M._reset_registry()
  _session_registry = {}
end

--- Record a file in the session registry.
function M._register_file(path, verb)
  if not path or path == "" then return end
  -- Don't downgrade "created" to "edited" — the first verb wins
  if not _session_registry[path] then
    _session_registry[path] = verb
  end
end

--- Get a one-liner summary of the session registry for prompt injection.
--- Returns nil if empty.
function M._registry_summary()
  local parts = {}
  for path, verb in pairs(_session_registry) do
    parts[#parts + 1] = verb .. " " .. path
  end
  if #parts == 0 then return nil end
  table.sort(parts)
  return "Files modified in this session: " .. table.concat(parts, ", ") .. "."
end

--------------------------------------------------------------------
-- Build gate: validate LLM output BEFORE writing to disk.
-- If the proposed code doesn't compile, reject it and retry.
--------------------------------------------------------------------

--- Detect the build check command for a file based on extension/project.
--- Returns { cmd = "...", cwd = "..." } or nil if no checker available.
function M._detect_build_check(filepath)
  if not filepath or filepath == "" then return nil end

  local ext = filepath:match("%.([^%.]+)$")
  if not ext then return nil end
  ext = ext:lower()

  local cwd = vim.fn.getcwd()

  -- Go: use go vet on the package
  if ext == "go" then
    local dir = vim.fn.fnamemodify(filepath, ":h")
    if dir == "" or dir == "." then dir = "." end
    -- Use go vet which catches more issues than go build
    return { cmd = "go vet ./" .. dir .. "/...", cwd = cwd }
  end

  -- TypeScript / JavaScript
  if ext == "ts" or ext == "tsx" then
    if vim.fn.filereadable(cwd .. "/tsconfig.json") == 1 then
      return { cmd = "npx tsc --noEmit", cwd = cwd }
    end
  end

  -- Python
  if ext == "py" then
    return { cmd = "python -m py_compile " .. filepath, cwd = cwd }
  end

  -- Rust
  if ext == "rs" then
    if vim.fn.filereadable(cwd .. "/Cargo.toml") == 1 then
      return { cmd = "cargo check --quiet 2>&1 | head -20", cwd = cwd }
    end
  end

  return nil
end

--- Run a build gate check on a file. Saves the file first, runs the check,
--- returns { ok = bool, output = string }.
local function run_build_gate(filepath, callback)
  local check = M._detect_build_check(filepath)
  if not check then
    callback({ ok = true, output = "", skipped = true })
    return
  end

  vim.fn.jobstart(check.cmd, {
    cwd = check.cwd,
    stdout_buffered = true,
    stderr_buffered = true,
    on_exit = function(_, exit_code)
      vim.schedule(function()
        callback({
          ok = exit_code == 0,
          output = "", -- simplified: we get the output from verify anyway
          exit_code = exit_code,
        })
      end)
    end,
  })
end

--------------------------------------------------------------------
-- Step snapshots: capture file content before each step for diff-retry.
--------------------------------------------------------------------

local _step_snapshots = {}  -- { path = content_string }

--- Snapshot all writable files in a step before the LLM edits them.
function M._snapshot_step(step)
  _step_snapshots = {}
  for _, action in ipairs(step.actions or {}) do
    if action.path and (action.verb == "create" or action.verb == "edit") then
      local full_path = action.path
      if not full_path:match("^/") then
        full_path = vim.fn.getcwd() .. "/" .. full_path
      end
      if vim.fn.filereadable(full_path) == 1 then
        local f = io.open(full_path, "r")
        if f then
          _step_snapshots[action.path] = f:read("*a")
          f:close()
        end
      else
        _step_snapshots[action.path] = nil  -- new file, no prior content
      end
    end
  end
end

--- Compute a unified diff between the pre-step snapshot and current file content.
--- Returns a compact diff string or nil if no meaningful changes.
function M._compute_step_diff()
  local diffs = {}

  for path, old_content in pairs(_step_snapshots) do
    local full_path = path
    if not full_path:match("^/") then
      full_path = vim.fn.getcwd() .. "/" .. full_path
    end

    local new_content = ""
    if vim.fn.filereadable(full_path) == 1 then
      local f = io.open(full_path, "r")
      if f then new_content = f:read("*a"); f:close() end
    end

    if old_content ~= new_content then
      -- Generate a simple line diff
      local old_lines = vim.split(old_content or "", "\n", { plain = true })
      local new_lines = vim.split(new_content, "\n", { plain = true })

      -- Find first and last differing lines
      local first_diff = nil
      local last_diff_old = nil
      local last_diff_new = nil
      local max_len = math.max(#old_lines, #new_lines)

      for i = 1, max_len do
        if old_lines[i] ~= new_lines[i] then
          if not first_diff then first_diff = i end
          if i <= #old_lines then last_diff_old = i end
          if i <= #new_lines then last_diff_new = i end
        end
      end

      if first_diff then
        local diff_parts = { string.format("--- %s (before edit)", path) }
        diff_parts[#diff_parts + 1] = string.format("+++ %s (after edit)", path)

        -- Show context: 2 lines before, the changed region, 2 lines after
        local ctx_start = math.max(1, first_diff - 2)
        local old_end = last_diff_old or first_diff
        local new_end = last_diff_new or first_diff
        local ctx_end_old = math.min(#old_lines, old_end + 2)
        local ctx_end_new = math.min(#new_lines, new_end + 2)

        diff_parts[#diff_parts + 1] = string.format("@@ -%d,%d +%d,%d @@",
          ctx_start, ctx_end_old - ctx_start + 1,
          ctx_start, ctx_end_new - ctx_start + 1)

        -- Context before
        for i = ctx_start, first_diff - 1 do
          if old_lines[i] then
            diff_parts[#diff_parts + 1] = " " .. old_lines[i]
          end
        end
        -- Removed lines
        for i = first_diff, old_end do
          if old_lines[i] then
            diff_parts[#diff_parts + 1] = "-" .. old_lines[i]
          end
        end
        -- Added lines
        for i = first_diff, new_end do
          if new_lines[i] then
            diff_parts[#diff_parts + 1] = "+" .. new_lines[i]
          end
        end
        -- Context after
        for i = math.max(old_end, new_end) + 1, math.max(ctx_end_old, ctx_end_new) do
          local line = new_lines[i] or old_lines[i]
          if line then
            diff_parts[#diff_parts + 1] = " " .. line
          end
        end

        diffs[#diffs + 1] = table.concat(diff_parts, "\n")
      end
    end
  end

  -- Also include files that were created (no old content)
  for path, old_content in pairs(_step_snapshots) do
    if old_content == nil then
      local full_path = path
      if not full_path:match("^/") then
        full_path = vim.fn.getcwd() .. "/" .. full_path
      end
      if vim.fn.filereadable(full_path) == 1 then
        local f = io.open(full_path, "r")
        if f then
          local content = f:read("*a")
          f:close()
          local lines = select(2, content:gsub("\n", "")) + 1
          diffs[#diffs + 1] = string.format("--- /dev/null\n+++ %s (NEW FILE, %d lines)", path, lines)
        end
      end
    end
  end

  if #diffs == 0 then return nil end
  return table.concat(diffs, "\n\n")
end

--- Restore a file from step snapshot (used by build gate rejection).
function M._restore_from_snapshot(path)
  local old_content = _step_snapshots[path]
  if not old_content then return false end

  local full_path = path
  if not full_path:match("^/") then
    full_path = vim.fn.getcwd() .. "/" .. full_path
  end

  local f = io.open(full_path, "w")
  if not f then return false end
  f:write(old_content)
  f:close()

  -- Reload buffer
  for _, bufnr in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(bufnr) and api.nvim_buf_get_name(bufnr) == full_path then
      pcall(function()
        api.nvim_buf_call(bufnr, function() vim.cmd("edit!") end)
      end)
    end
  end

  return true
end

--------------------------------------------------------------------
-- Parse plan: extract steps from markdown with HTML comment directives
--------------------------------------------------------------------

--- Parse a plan buffer/text into executable steps.
--- Returns { { title, actions, prompts, verify, on_fail, delegates } ... }
function M.parse_plan(text)
  local steps = {}
  local current_step = nil

  -- Pre-create a default step for directives that appear before any ### header
  local orphan_step = {
    number = 0,
    title = "Ungrouped directives",
    actions = {},
    prompts = {},
    verify = nil,
    on_fail = nil,
    delegates = {},
    smoke_tests = {},
  }

  for line in text:gmatch("[^\n]+") do
    -- New step: ### N. Title  OR  ## N. Title  OR  **N.** Title
    local step_num, title = line:match("^###?%s+(%d+)%.%s+(.+)")
    if not step_num then
      step_num, title = line:match("^%*%*(%d+)%.?%*%*%s+(.+)")
    end
    if step_num then
      current_step = {
        number = tonumber(step_num),
        title = vim.trim(title),
        actions = {},
        prompts = {},
        verify = nil,
        on_fail = nil,
        delegates = {},
        smoke_tests = {},
      }
      steps[#steps + 1] = current_step
    end

    -- Determine target step (current or orphan)
    local target = current_step or orphan_step

    -- Action directive: <!-- @dwight:action verb path -->
    local action_str = line:match("<!%-%-%s*@dwight:action%s+(.-)%s*%-%->")
    if action_str then
      local action = M._parse_action(action_str)
      if action then
        target.actions[#target.actions + 1] = action
      end
    end

    -- Prompt directive: <!-- @dwight:prompt /mode $feat instructions -->
    local prompt_str = line:match("<!%-%-%s*@dwight:prompt%s+(.-)%s*%-%->")
    if prompt_str then
      local prompt = M._parse_prompt(prompt_str)
      if prompt then
        target.prompts[#target.prompts + 1] = prompt
      end
    end

    -- Verify directive: <!-- @dwight:verify run command -->
    local verify_str = line:match("<!%-%-%s*@dwight:verify%s+(.-)%s*%-%->")
    if verify_str then
      local verify_cmd = verify_str:match("^run%s+(.+)$") or verify_str
      target.verify = { command = vim.trim(verify_cmd), expect_fail = false }
    end

    -- Verify-fail directive: <!-- @dwight:verify-fail run command -->
    -- Expects tests to FAIL (red phase TDD). Only build errors trigger on-fail.
    local verify_fail_str = line:match("<!%-%-%s*@dwight:verify%-fail%s+(.-)%s*%-%->")
    if verify_fail_str then
      local verify_cmd = verify_fail_str:match("^run%s+(.+)$") or verify_fail_str
      target.verify = { command = vim.trim(verify_cmd), expect_fail = true }
    end

    -- On-fail directive: <!-- @dwight:on-fail /mode instructions -->
    local on_fail_str = line:match("<!%-%-%s*@dwight:on%-fail%s+(.-)%s*%-%->")
    if on_fail_str then
      target.on_fail = M._parse_prompt(on_fail_str)
    end

    -- Delegate directive: <!-- @dwight:delegate description -->
    local delegate_str = line:match("<!%-%-%s*@dwight:delegate%s+(.-)%s*%-%->")
    if delegate_str then
      target.delegates[#target.delegates + 1] = vim.trim(delegate_str)
    end

    -- Smoke test directive: <!-- @dwight:smoke run command -->
    -- End-to-end validation: build the binary and run it with real args.
    -- All smoke commands must pass (exit 0). Failures trigger on-fail.
    local smoke_str = line:match("<!%-%-%s*@dwight:smoke%s+(.-)%s*%-%->")
    if smoke_str then
      local smoke_cmd = smoke_str:match("^run%s+(.+)$") or smoke_str
      if not target.smoke_tests then target.smoke_tests = {} end
      target.smoke_tests[#target.smoke_tests + 1] = { command = vim.trim(smoke_cmd) }
    end
  end

  -- If orphan step collected anything, prepend it
  if #orphan_step.actions > 0 or #orphan_step.prompts > 0
     or orphan_step.verify or #orphan_step.delegates > 0
     or (orphan_step.smoke_tests and #orphan_step.smoke_tests > 0) then
    orphan_step.number = 0
    table.insert(steps, 1, orphan_step)
  end

  -- Renumber steps sequentially
  for i, step in ipairs(steps) do step.number = i end

  return steps
end

--- Validate a parsed plan for structural issues that cause agent failures.
--- Returns { ok = bool, warnings = {string}, errors = {string} }.
--- Errors are blockers; warnings are advisory.
function M.validate_plan(steps)
  local errors = {}
  local warnings = {}

  -- Track all created/edited files across steps for cross-step validation
  local all_created = {}
  local all_edited = {}

  for _, step in ipairs(steps) do
    local label = string.format("Step %d (%s)", step.number, step.title)

    -- Every step with a prompt MUST have a verify
    if #step.prompts > 0 and not step.verify then
      errors[#errors + 1] = label .. ": has prompt(s) but no @dwight:verify — failures will go undetected."
    end

    -- Every verify MUST have an on-fail
    if step.verify and not step.on_fail then
      errors[#errors + 1] = label .. ": has verify but no @dwight:on-fail — cannot recover from failures."
    end

    -- No step should have both create and edit for the same file
    local creates = {}
    local edits = {}
    for _, action in ipairs(step.actions) do
      if action.path then
        if action.verb == "create" then creates[action.path] = true end
        if action.verb == "edit" then edits[action.path] = true end
      end
    end
    for path in pairs(creates) do
      if edits[path] then
        errors[#errors + 1] = label .. ": both creates and edits '" .. path .. "' — use create OR edit, not both."
      end
    end

    -- Track cross-step file operations
    for path in pairs(creates) do
      all_created[path] = (all_created[path] or 0) + 1
    end
    for path in pairs(edits) do
      all_edited[path] = (all_edited[path] or 0) + 1
    end

    -- Too many prompts in one step (complexity flag)
    if #step.prompts > 2 then
      warnings[#warnings + 1] = label .. ": has " .. #step.prompts .. " prompts — split into smaller steps for reliability."
    end

    -- Too many create/edit files in one step (multi-file corruption risk)
    local write_count = 0
    for _ in pairs(creates) do write_count = write_count + 1 end
    for _ in pairs(edits) do write_count = write_count + 1 end
    if write_count > 2 and #step.prompts > 0 then
      warnings[#warnings + 1] = label .. ": modifies " .. write_count .. " files with prompts — split into one-file-per-step for reliability."
    end

    -- Smoke tests: check for `go build -o ... ./...` anti-pattern
    for _, smoke in ipairs(step.smoke_tests or {}) do
      if smoke.command:match("go%s+build%s+%-o%s+%S+%s+%./%.\\.%.")
        or smoke.command:match("go%s+build%s+%-o%s+%S+%s+%./%.%.%.")  then
        errors[#errors + 1] = label .. ": smoke uses 'go build -o <file> ./...' — this fails with multi-package projects. Use 'go build -o <file> .' instead."
      end
    end

    -- Steps with smoke but no on-fail
    if step.smoke_tests and #step.smoke_tests > 0 and not step.on_fail then
      errors[#errors + 1] = label .. ": has smoke test(s) but no @dwight:on-fail — cannot recover from smoke failures."
    end

    -- Prompt with edit but no corresponding edit action
    if #step.prompts > 0 then
      local has_write_action = false
      for _, action in ipairs(step.actions) do
        if action.verb == "create" or action.verb == "edit" then
          has_write_action = true; break
        end
      end
      if not has_write_action and #step.delegates == 0 then
        warnings[#warnings + 1] = label .. ": has prompt(s) but no create/edit action — prompt may have no target file."
      end
    end
  end

  -- Cross-step validation: file created in one step and edited in a later step
  -- should use "edit" not "create" (which would overwrite)
  for path, count in pairs(all_created) do
    if count > 1 then
      warnings[#warnings + 1] = string.format("File '%s' is created in %d steps — later steps should use 'edit' instead of 'create'.", path, count)
    end
  end

  -- Plan size warning
  if #steps > 6 then
    warnings[#warnings + 1] = string.format("Plan has %d steps (recommended max 6). Consider using @dwight:delegate for sub-tasks.", #steps)
  end

  return {
    ok = #errors == 0,
    warnings = warnings,
    errors = errors,
  }
end

--- Parse an action string like "create src/auth/index.ts" or "run npm test"
function M._parse_action(str)
  str = vim.trim(str)

  -- "read path1 path2 ..." — load files for context (multiple paths allowed)
  local read_rest = str:match("^read%s+(.+)$")
  if read_rest then
    local paths = {}
    for path in read_rest:gmatch("%S+") do
      -- Skip tokens that look like modifiers (+rewrite, etc.)
      if not path:match("^%+") then
        paths[#paths + 1] = path
      end
    end
    return { verb = "read", paths = paths }
  end

  -- "run command args..." — must match before create/edit to avoid false positives
  local run_cmd = str:match("^run%s+(.+)$")
  if run_cmd then
    return { verb = "run", command = run_cmd }
  end

  -- "move src/old.ts src/new.ts" — exactly 3 tokens starting with "move"
  local move_src, move_dst = str:match("^move%s+(%S+)%s+(%S+)%s*$")
  if move_src and move_dst then
    return { verb = "move", source = move_src, target = move_dst }
  end

  -- "create|edit|delete path [+ignored tokens]"
  -- Strip any +modifiers or extra tokens after the path (e.g., "+rewrite")
  local verb_multi, path_multi = str:match("^(%w+)%s+(%S+)")
  if verb_multi and path_multi then
    local v = verb_multi:lower()
    -- Only accept known verbs
    if v == "create" or v == "edit" or v == "delete" then
      return { verb = v, path = path_multi }
    end
  end

  -- Single word: verb only
  local verb = str:match("^(%w+)$")
  if verb then
    return { verb = verb:lower() }
  end

  return nil
end

--- Parse a prompt string like "/code +run $auth Implement login handler"
--- Modifiers:
---   +run  — inject last build/test output into the prompt
function M._parse_prompt(str)
  str = vim.trim(str)

  local mode = str:match("^/(%w+)")
  local features = {}
  for feat in str:gmatch("%$([%w_%-]+)") do
    features[#features + 1] = feat
  end

  -- Parse modifiers (+run, etc.)
  local modifiers = {}
  for mod in str:gmatch("%+(%w+)") do
    modifiers[mod] = true
  end

  -- Instructions: everything after mode, modifiers, and features
  local instructions = str:gsub("^/%w+%s*", ""):gsub("%+%w+%s*", ""):gsub("%$[%w_%-]+%s*", "")
  instructions = vim.trim(instructions)

  return {
    mode = mode or "code",
    features = features,
    modifiers = modifiers,
    instructions = instructions,
    raw = str,
  }
end

--------------------------------------------------------------------
-- Shared helpers
--------------------------------------------------------------------

--- Wait for a job to complete by polling _active_jobs.
local function wait_for_job(job_id, timeout_s, callback)
  local dwight = require("dwight")
  local uv = vim.loop or vim.uv
  local timer = uv.new_timer()
  local elapsed = 0
  local interval = 500

  timer:start(interval, interval, vim.schedule_wrap(function()
    elapsed = elapsed + interval
    if not dwight._active_jobs[job_id] then
      timer:stop(); timer:close()
      -- Check if the job FAILED by examining the log.
      -- handle_response sets status before removing from _active_jobs.
      local log = require("dwight.log")
      local failed = false
      for _, entry in ipairs(log._entries) do
        if entry.id == job_id then
          if entry.status == "error" or entry.status == "timeout"
            or entry.status == "parse_fail" or entry.status == "pre_check_fail" then
            failed = true
          end
          break
        end
      end
      callback(not failed, failed and "error" or nil)
    elseif elapsed >= (timeout_s * 1000) then
      timer:stop(); timer:close()
      callback(false, "timeout")
    end
  end))
end

--- Save a buffer to disk.
local function save_buffer(bufnr)
  if not api.nvim_buf_is_valid(bufnr) then return end
  local name = api.nvim_buf_get_name(bufnr)
  if name == "" then return end
  local lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
  if #lines == 0 or (#lines == 1 and lines[1] == "") then return end
  pcall(function()
    api.nvim_buf_call(bufnr, function() vim.cmd("silent! write") end)
  end)
end

--- Save ALL modified buffers to disk. This catches cases where the LLM
--- wrote to files via multifile or other paths beyond the target buffer.
local function save_all_modified_buffers()
  for _, bufnr in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].modified then
      save_buffer(bufnr)
    end
  end
end

--- Check if a file on disk has content (not empty).
local function file_has_content(path)
  if not path or path == "" then return false end
  local f = io.open(path, "r")
  if not f then return false end
  local content = f:read("*a")
  f:close()
  if not content then return false end
  local trimmed = vim.trim(content)
  if trimmed == "" then return false end

  -- Detect seed-only content (minimal placeholder from _seed_content).
  -- These are effectively empty — the LLM didn't write anything real.
  local seed_patterns = {
    "^package%s+%w+%s*$",             -- Go: just "package main"
    "^// TODO: implement$",           -- JS/TS/Java/C/Swift/default
    "^# TODO: implement$",           -- Python
    "^# frozen_string_literal: true$", -- Ruby
    "^%-%- TODO: implement$",        -- SQL single-line
    "^<!%-%- TODO: implement %-%->$", -- HTML
    "^#!/usr/bin/env bash$",          -- Shell
    "^%-%- TODO: implement\nlocal M = {}\nreturn M$", -- Lua module seed
  }
  for _, pat in ipairs(seed_patterns) do
    if trimmed:match(pat) then return false end
  end

  return true
end

--- Run a shell command async via runner (stores output for prompt injection).
--- Calls callback(result) with { ok, output, exit_code, job_id }.
local function run_command_async(cmd, callback)
  require("dwight.runner").run(cmd, nil, function(result)
    callback({
      ok = result.exit_code == 0,
      output = result.stdout .. "\n" .. result.stderr,
      exit_code = result.exit_code,
      job_id = result.job_id,
    })
  end)
end

--- Open or create a buffer for a file path.
local function open_buffer(path)
  local full = path
  if not full:match("^/") then full = vim.fn.getcwd() .. "/" .. full end
  vim.fn.mkdir(vim.fn.fnamemodify(full, ":h"), "p")
  if vim.fn.filereadable(full) ~= 1 then
    local f = io.open(full, "w"); if f then f:write(""); f:close() end
  end
  local bufnr = vim.fn.bufadd(full)
  vim.fn.bufload(bufnr)
  vim.bo[bufnr].modifiable = true
  return bufnr
end

--- Build a selection table for an entire buffer.
local function buf_selection(bufnr)
  local line_count = api.nvim_buf_line_count(bufnr)
  local all_lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return {
    bufnr = bufnr,
    filepath = api.nvim_buf_get_name(bufnr),
    filetype = vim.bo[bufnr].filetype or "",
    start_line = 1,
    end_line = line_count,
    text = table.concat(all_lines, "\n"),
  }
end

--------------------------------------------------------------------
-- Execute a single prompt and wait for completion
--------------------------------------------------------------------

--- Run a single prompt directive. Calls callback(qf_entry, err) when done.
function M._run_prompt(prompt_def, target_path, callback)
  local mode = require("dwight.modes").get(prompt_def.mode)
  if not mode then
    mode = { name = "Code", task = "Implement:\n" .. prompt_def.instructions, context = "code" }
  end

  -- Apply modifiers: +run injects last build/test output
  local modifiers = prompt_def.modifiers or {}
  if modifiers.run then
    mode = vim.tbl_extend("force", mode, { inject_run_output = true })
  end

  -- Apply mode overrides (e.g., skip_rag, skip_git for agent retries)
  if prompt_def.mode_overrides then
    mode = vim.tbl_extend("force", mode, prompt_def.mode_overrides)
  end

  -- Agent prompts: strip expensive/noisy context that the plan's read actions already provide.
  -- The agent's explicit read actions give exactly the context needed — RAG search,
  -- git blame, and file_structure minimap add noise and waste tokens.
  if prompt_def._is_agent then
    mode = vim.tbl_extend("force", mode, {
      skip_rag = true,
      skip_git = true,
      skip_minimap = true,
    })
  end

  -- Resolve features
  local resolved_features = {}
  pcall(function()
    resolved_features = require("dwight.features").resolve_many(prompt_def.features)
  end)

  -- Open target buffer
  local bufnr
  if target_path then
    bufnr = open_buffer(target_path)
  else
    bufnr = api.nvim_get_current_buf()
    if not vim.bo[bufnr].modifiable then
      callback({ text = "⚠️ Skipped (read-only): " .. prompt_def.raw }, "Buffer not modifiable")
      return
    end
  end

  local selection = buf_selection(bufnr)

  -- Inject extra context (multi-file on-fail visibility) into instructions
  local instructions = prompt_def.instructions
  if prompt_def.extra_context then
    instructions = instructions .. "\n\n" .. prompt_def.extra_context
  end

  -- Agent-mode preamble: when editing existing files, explicitly tell the LLM to
  -- preserve existing code. This prevents the LLM from dropping or duplicating functions
  -- when making targeted additions to large files.
  if target_path then
    local check_path = target_path
    if not check_path:match("^/") then check_path = vim.fn.getcwd() .. "/" .. check_path end
    if vim.fn.filereadable(check_path) == 1 then
      local line_count = 0
      pcall(function()
        line_count = api.nvim_buf_line_count(bufnr)
      end)

      -- SURGICAL EDIT MODE: For agent edits on large files, use line-range XML format
      -- instead of full-file replacement. The LLM outputs ONLY the changed sections,
      -- so existing functions can't be dropped, duplicated, or corrupted.
      if line_count > 80 and prompt_def._is_agent then
        -- Switch to multi-file mode so handle_response routes through multifile.apply_one
        mode = vim.tbl_extend("force", mode, { is_multi = true })

        -- Build a concise file summary showing line ranges of each function/section
        local file_map = ""
        pcall(function()
          local ts = require("dwight.treesitter")
          local minimap = ts.minimap(check_path)
          if minimap and minimap ~= "" then
            file_map = "\n\nFILE STRUCTURE (line numbers for targeting your edits):\n" .. minimap
          end
        end)

        instructions = string.format(
          "SURGICAL EDIT MODE — You are editing %s (%d lines).\n"
          .. "Output ONLY a <changes> block with targeted line-range edits.\n"
          .. "Do NOT output the entire file. Only output the sections you are changing.\n\n"
          .. "Format:\n"
          .. "<changes>\n"
          .. '<file path="%s" action="edit" lines="START-END">\n'
          .. "(replacement code for those lines)\n"
          .. "</file>\n"
          .. "</changes>\n\n"
          .. "You may include multiple <file> blocks for non-contiguous edits.\n"
          .. "Each block replaces EXACTLY lines START through END (inclusive, 1-indexed).\n"
          .. "To ADD new code at end of file, use lines=\"%d-%d\" with the new content.\n"
          .. "IMPORTANT: Keep surrounding code (the lines you are NOT targeting) EXACTLY as-is.\n"
          .. "%s\n\n"
          .. "TASK: %s",
          target_path, line_count,
          target_path,
          line_count, line_count,
          file_map,
          instructions
        )

        -- Override the SCOPE if present
        if mode.task and mode.task:find("SCOPE %(mandatory%)") then
          local agent_scope = "\nSCOPE (mandatory):\n"
            .. "- Use <changes> XML with line ranges. Do NOT output the entire file.\n"
            .. "- Each <file> block replaces EXACTLY the specified line range.\n"
            .. "- ADD new code by targeting the end of the file or inserting at specific lines.\n"
            .. "- Do NOT restructure, reorder, or rename existing code.\n"
          local new_task = mode.task:gsub(
            "\n?SCOPE %(mandatory%):.-If you need something that doesn't exist, leave a TODO comment%.",
            agent_scope)
          mode = vim.tbl_extend("force", mode, { task = new_task })
        end

      elseif line_count > 50 then
        -- Fallback for non-agent edits or smaller files: full-file with preservation warning
        instructions = "IMPORTANT: You are editing an existing file with " .. line_count
          .. " lines. Output the COMPLETE file with your changes applied. "
          .. "Do NOT drop, duplicate, or reorder any existing functions or code blocks. "
          .. "Keep all unchanged code EXACTLY as-is.\n\n" .. instructions

        -- Override the SCOPE in the mode's task text. The default SCOPE says
        -- "Do NOT add new functions" which contradicts agent edit instructions
        -- that say "Add new functions to this file." Replace with agent-safe rules.
        if mode.task and mode.task:find("SCOPE %(mandatory%)") then
          local agent_scope = "\nSCOPE (mandatory):\n"
            .. "- Your output replaces the ENTIRE file.\n"
            .. "- Keep ALL existing functions, imports, and code EXACTLY as-is.\n"
            .. "- ADD the requested new code in the appropriate location.\n"
            .. "- Do NOT restructure, reorder, or rename existing code.\n"
            .. "- Do NOT remove any existing functions even if they seem unused.\n"
          -- Replace the SCOPE block (from "SCOPE (mandatory):" to the last "- " rule before a blank line)
          local new_task = mode.task:gsub(
            "\n?SCOPE %(mandatory%):.-If you need something that doesn't exist, leave a TODO comment%.",
            agent_scope)
          mode = vim.tbl_extend("force", mode, { task = new_task })
        end
      end
    end
  end

  -- Auto-inject companion file context (test↔source) when +run is active.
  -- This is the KEY stability feature: when implementing code to make tests pass,
  -- the LLM needs to SEE the test file to know what's expected.
  -- Skip if extra_context already contains file context (e.g., retry 3 wire mode)
  -- to prevent duplicate file content inflating the prompt.
  local has_files_in_context = prompt_def.extra_context
    and prompt_def.extra_context:match("<related_files>")
  if mode.inject_run_output and target_path and not prompt_def._skip_companion
    and not has_files_in_context then
    local companions = M._find_companion_files(target_path)
    if #companions > 0 then
      local comp_ctx = M._gather_files_context(companions)
      if comp_ctx then
        instructions = instructions .. "\n\n"
          .. "The following companion files are provided for reference. "
          .. "Read them carefully to understand what is expected:\n"
          .. comp_ctx
      end
    end
  end

  -- Agent self-review preamble: instruct the LLM to verify its own output
  -- before finalizing. This catches obvious omissions without extra LLM calls.
  if prompt_def._is_agent then
    instructions = instructions .. "\n\n"
      .. "BEFORE YOU FINALIZE YOUR OUTPUT, self-review:\n"
      .. "1. Re-read the task above. Did you implement ALL requested functions?\n"
      .. "2. Are all imports/requires present for the code you wrote?\n"
      .. "3. Are error cases handled (not silently ignored)?\n"
      .. "4. Did you write ONLY what was requested? No extra helpers, no gold-plating.\n"
      .. "If anything is missing, fix it now. If you added anything extra, remove it."
  end

  -- Build prompt
  local lsp = require("dwight.lsp")
  local ctx = lsp.gather_context(selection)
  local prompt_text = require("dwight.prompt").build(
    mode, selection, ctx, instructions,
    {}, {}, resolved_features, 1, {}, {}, {})

  -- Run it
  local cfg = require("dwight").config
  local model_override = require("dwight.modes").resolve_model(prompt_def.mode)
  local job_id = require("dwight.opencode").run(prompt_text, selection, cfg, prompt_def.mode, model_override, 1, {
    is_multi = mode.is_multi,
    is_prose = mode.context == "prose",
  })

  if not job_id then
    callback({ text = "❌ Failed to start: " .. prompt_def.raw, type = "E" }, "Failed to start")
    return
  end

  local job_ref = string.format(" (job #%d)", job_id)

  local timeout = (cfg.timeout or 120000) / 1000
  -- Scale timeout for large-file agent edits (big prompts take longer)
  if target_path then
    pcall(function()
      local lc = api.nvim_buf_line_count(bufnr)
      if lc > 200 then timeout = timeout * 2 end
    end)
  end
  -- Apply explicit timeout scaling (e.g., retry 3 wire mode needs more time)
  if prompt_def.mode_overrides and prompt_def.mode_overrides.timeout_scale then
    timeout = timeout * prompt_def.mode_overrides.timeout_scale
  end
  wait_for_job(job_id, timeout, function(ok, err_reason)
    if not ok then
      if err_reason == "error" then
        -- LLM returned an error (exit code != 0, timeout/kill, etc.)
        -- Check the log for details
        local error_detail = "LLM error"
        pcall(function()
          local log_mod = require("dwight.log")
          for _, entry in ipairs(log_mod._entries) do
            if entry.id == job_id and entry.error then
              error_detail = entry.error
              break
            end
          end
        end)
        callback({
          text = string.format("❌ LLM error: %s%s", error_detail, job_ref),
          type = "E",
        }, "LLM error: " .. error_detail)
      else
        callback({ text = "⏱️ Timeout: " .. prompt_def.raw .. job_ref, type = "E" }, "Timeout")
      end
      return
    end

    -- Save ALL modified buffers (the LLM might have written to files
    -- via multifile or other paths, not just the target buffer)
    save_all_modified_buffers()

    -- Also force-save the specific target buffer
    save_buffer(bufnr)

    -- ═══ BUILD GATE ═══
    -- For agent edits, validate the output compiles BEFORE accepting it.
    -- If the build gate fails, restore from snapshot and report the error
    -- so the verify loop can fix it with full diff context.
    local filepath = api.nvim_buf_get_name(bufnr)
    if prompt_def._is_agent and target_path and not prompt_def._skip_build_gate then
      run_build_gate(filepath, function(gate_result)
        if not gate_result.ok and not gate_result.skipped then
          -- Build gate failed — the LLM produced code that doesn't compile.
          -- DON'T restore (let verify loop handle it with the broken state so
          -- it has the actual error). But flag it clearly for the retry loop.
          vim.notify(string.format("[dwight] 🚧 Build gate failed for %s (exit %d) — verify loop will fix.",
            target_path, gate_result.exit_code or -1), vim.log.levels.WARN)

          -- Register in session anyway (file was touched)
          M._register_file(target_path, "edited")

          callback({
            filename = filepath,
            lnum = 1,
            text = "🚧 " .. prompt_def.raw .. job_ref .. " (build gate: FAIL)",
          }, nil)  -- non-fatal: let verify loop catch and fix
          return
        end

        -- Build gate passed (or skipped for unsupported language)
        M._register_file(target_path, _step_snapshots[target_path] and "edited" or "created")

        -- Check for empty file (existing logic)
        if not file_has_content(filepath) then
          if not prompt_def._is_retry then
            vim.notify("[dwight] ⚠️ File empty after prompt — retrying with explicit instruction…",
              vim.log.levels.WARN)
            local retry_prompt = {
              raw = prompt_def.raw .. " (retry)",
              mode = prompt_def.mode,
              features = prompt_def.features,
              instructions = "IMPORTANT: The target file is currently EMPTY. "
                .. "You MUST write the COMPLETE file content. "
                .. "Wrap your code in a fenced code block (```). "
                .. "Do NOT skip any part.\n\n"
                .. "Original task: " .. prompt_def.instructions,
              _is_retry = true,
              _is_agent = true,
              _skip_build_gate = true,
            }
            M._run_prompt(retry_prompt, target_path, callback)
            return
          end
          vim.notify(string.format("[dwight] ⚠️ Target file still empty after retry: %s", target_path),
            vim.log.levels.WARN)
          callback({
            filename = filepath, lnum = 1,
            text = "⚠️ File empty after prompt+retry: " .. prompt_def.raw .. job_ref,
            type = "W",
          }, nil)
          return
        end

        callback({
          filename = filepath, lnum = 1,
          text = "🤖 " .. prompt_def.raw .. job_ref,
        }, nil)
      end)
      return  -- async path — callback handles the rest
    end

    -- Non-agent path: original logic (synchronous)

    -- Track file in registry
    if target_path then
      M._register_file(target_path, "edited")
    end

    -- Verify the target file has content (catch silent write failures)
    if target_path and not file_has_content(filepath) then
      -- Layer 2: Auto-retry ONCE with explicit instruction
      if not prompt_def._is_retry then
        vim.notify("[dwight] ⚠️ File empty after prompt — retrying with explicit instruction…",
          vim.log.levels.WARN)
        local retry_prompt = {
          raw = prompt_def.raw .. " (retry)",
          mode = prompt_def.mode,
          features = prompt_def.features,
          instructions = "IMPORTANT: The target file is currently EMPTY. "
            .. "You MUST write the COMPLETE file content. "
            .. "Wrap your code in a fenced code block (```). "
            .. "Do NOT skip any part.\n\n"
            .. "Original task: " .. prompt_def.instructions,
          _is_retry = true,
        }
        M._run_prompt(retry_prompt, target_path, callback)
        return
      end

      -- Already retried — give up with warning
      vim.notify(string.format("[dwight] ⚠️ Target file still empty after retry: %s", target_path),
        vim.log.levels.WARN)
      callback({
        filename = filepath,
        lnum = 1,
        text = "⚠️ File empty after prompt+retry: " .. prompt_def.raw .. job_ref,
        type = "W",
      }, nil)  -- non-fatal warning, don't abort the whole plan
      return
    end

    callback({
      filename = filepath,
      lnum = 1,
      text = "🤖 " .. prompt_def.raw .. job_ref,
    }, nil)
  end)
end

--- Run multiple prompts sequentially. Calls callback(entries, err) when all done.
function M._run_prompts_seq(prompts, target_path, callback)
  local entries = {}
  local idx = 1

  local function next_prompt()
    if idx > #prompts then
      callback(entries, nil)
      return
    end
    M._run_prompt(prompts[idx], target_path, function(entry, err)
      entries[#entries + 1] = entry
      if err then
        callback(entries, err)
        return
      end
      idx = idx + 1
      vim.schedule(next_prompt)
    end)
  end

  next_prompt()
end

--------------------------------------------------------------------
-- Seed content for new files (prevent 0-byte files)
--------------------------------------------------------------------

--- Generate minimal valid file content for a given path.
--- This ensures files are never truly empty, which causes compilation
--- errors in strict languages like Go, Rust, etc.
function M._seed_content(path)
  local ext = path:match("%.([^%.]+)$") or ""
  ext = ext:lower()

  -- Go: must have package declaration (derive from directory name)
  if ext == "go" then
    local dir = vim.fn.fnamemodify(path, ":h:t")
    -- Test files in Go use the same package
    local pkg = dir:gsub("[^%w_]", "")
    if pkg == "" or pkg == "." then pkg = "main" end
    if path:match("_test%.go$") then
      return string.format("package %s\n", pkg)
    end
    return string.format("package %s\n", pkg)
  end

  -- Rust
  if ext == "rs" then
    return "// TODO: implement\n"
  end

  -- Python
  if ext == "py" then
    return "# TODO: implement\n"
  end

  -- TypeScript / JavaScript
  if ext == "ts" or ext == "tsx" or ext == "js" or ext == "jsx" or ext == "mjs" or ext == "mts" then
    return "// TODO: implement\n"
  end

  -- Java
  if ext == "java" then
    return "// TODO: implement\n"
  end

  -- C / C++
  if ext == "c" or ext == "h" or ext == "cpp" or ext == "hpp" or ext == "cc" then
    return "// TODO: implement\n"
  end

  -- Swift
  if ext == "swift" then
    return "// TODO: implement\n"
  end

  -- Ruby
  if ext == "rb" then
    return "# frozen_string_literal: true\n"
  end

  -- Lua
  if ext == "lua" then
    return "-- TODO: implement\nlocal M = {}\nreturn M\n"
  end

  -- Shell
  if ext == "sh" or ext == "bash" or ext == "zsh" then
    return "#!/usr/bin/env bash\n"
  end

  -- SQL
  if ext == "sql" then
    return "-- TODO: implement\n"
  end

  -- HTML / XML / templates
  if ext == "html" or ext == "htm" then
    return "<!-- TODO: implement -->\n"
  end

  -- YAML / TOML / JSON — leave truly empty (these are data, not compiled)
  if ext == "yaml" or ext == "yml" or ext == "toml" or ext == "json" then
    return ""
  end

  -- Markdown
  if ext == "md" then
    return ""
  end

  -- Default: a comment for unknown source files
  return "// TODO: implement\n"
end

--------------------------------------------------------------------
-- Execute a file action
--------------------------------------------------------------------

function M._execute_action(action)
  local cwd = vim.fn.getcwd() .. "/"

  if action.verb == "create" and action.path then
    local full = cwd .. action.path
    vim.fn.mkdir(vim.fn.fnamemodify(full, ":h"), "p")
    if vim.fn.filereadable(full) ~= 1 then
      local f = io.open(full, "w")
      if f then
        f:write(M._seed_content(action.path))
        f:close()
      end
    end
    return { filename = full, lnum = 1, text = "🆕 created " .. action.path }
  end

  if action.verb == "edit" and action.path then
    local full = cwd .. action.path
    if vim.fn.filereadable(full) == 1 then
      open_buffer(full)
      return { filename = full, lnum = 1, text = "📝 editing " .. action.path }
    end
    return { text = "⚠️ edit: file not found: " .. action.path, type = "W" }
  end

  if action.verb == "read" then
    -- Load files into buffers for context. With companion file injection,
    -- these are often auto-detected, but explicit reads ensure visibility.
    local paths = action.paths or (action.path and { action.path } or {})
    local loaded = {}
    for _, path in ipairs(paths) do
      local full = cwd .. path
      if vim.fn.filereadable(full) == 1 then
        open_buffer(full)
        loaded[#loaded + 1] = path
      end
    end
    if #loaded > 0 then
      return { text = "📖 read " .. table.concat(loaded, ", ") }
    end
    return { text = "⚠️ read: no files found", type = "W" }
  end

  if action.verb == "delete" and action.path then
    local full = cwd .. action.path
    os.remove(full)
    return { filename = full, lnum = 1, text = "🗑️ deleted " .. action.path }
  end

  if action.verb == "move" and action.source and action.target then
    local src = cwd .. action.source
    local dst = cwd .. action.target
    vim.fn.mkdir(vim.fn.fnamemodify(dst, ":h"), "p")
    os.rename(src, dst)
    return { filename = dst, lnum = 1, text = "📦 moved " .. action.source .. " → " .. action.target }
  end

  if action.verb == "run" and action.command then
    local output = vim.fn.system(action.command)
    local ok = vim.v.shell_error == 0
    return {
      text = (ok and "✅ " or "❌ ") .. "run: " .. action.command,
      type = ok and "I" or "E",
    }
  end

  return nil
end

--- Extract ALL file paths from compiler/test error output.
--- Returns list of unique relative paths, ordered by frequency (most-referenced first).
--- Handles: Go, Rust, C/C++, TypeScript, Python, Java error formats.
function M._extract_error_files(output)
  if not output or output == "" then return {} end
  local cwd = vim.fn.getcwd() .. "/"
  local counts = {}   -- file → count
  local order = {}    -- preserves first-seen order

  for line in output:gmatch("[^\n]+") do
    local file = line:match("^%s*([%w_/%-%.]+%.[%w]+):%d+:%d+:")
    if not file then file = line:match("^%s*([%w_/%-%.]+%.[%w]+):%d+:") end
    if not file then file = line:match("^%s*([%w_/%-%.]+%.[%w]+)%(%d+,%d+%):") end
    if not file then file = line:match('File "([^"]+)"') end

    if file and not file:match("^/") and not file:match("^%.%.") then
      if vim.fn.filereadable(cwd .. file) == 1 then
        if not counts[file] then
          counts[file] = 0
          order[#order + 1] = file
        end
        counts[file] = counts[file] + 1
      end
    end
  end

  -- Sort by frequency (most errors first)
  table.sort(order, function(a, b) return counts[a] > counts[b] end)
  return order
end

--- Backwards-compatible: return first error file or nil.
function M._extract_error_file(output)
  local files = M._extract_error_files(output)
  return files[1]
end

--- Gather file contents from a list of relative paths.
--- Returns XML string with all file contents for context injection.
function M._gather_files_context(paths, exclude_path)
  if not paths or #paths == 0 then return nil end
  local cwd = vim.fn.getcwd() .. "/"
  local parts = { "<related_files>" }
  for _, path in ipairs(paths) do
    -- Skip the target file — it's already in the prompt's <code> block.
    -- Including it here would duplicate content and inflate prompt size.
    if exclude_path and path == exclude_path then goto continue end
    local full = cwd .. path
    local f = io.open(full, "r")
    if f then
      local content = f:read("*a"); f:close()
      if content and #content < 10000 then  -- skip huge files
        parts[#parts + 1] = string.format('<file path="%s">\n%s\n</file>', path, content)
      else
        parts[#parts + 1] = string.format('<file path="%s">(too large, %d bytes)</file>', path, #(content or ""))
      end
    end
    ::continue::
  end
  parts[#parts + 1] = "</related_files>"
  return #parts > 2 and table.concat(parts, "\n") or nil
end

--- Collect ALL file paths touched by a step and optionally recent prior steps.
--- Used to give on-fail prompts full visibility.
function M._collect_step_files(step, all_steps, step_idx)
  local seen = {}
  local files = {}

  local function add(path)
    if path and not seen[path] then
      seen[path] = true
      files[#files + 1] = path
    end
  end

  -- Current step's files
  for _, action in ipairs(step.actions) do
    if action.path then add(action.path) end
  end

  -- Walk backwards through recent steps (up to 3 prior)
  if all_steps and step_idx then
    for i = step_idx - 1, math.max(1, step_idx - 3), -1 do
      for _, action in ipairs(all_steps[i].actions) do
        if action.path then add(action.path) end
      end
    end
  end

  return files
end

--------------------------------------------------------------------
-- Companion file detection: auto-inject test↔source context
--------------------------------------------------------------------

--- Find companion files for a given source file.
--- When editing source, returns the test file. When editing tests, returns the source.
--- Returns list of existing companion file paths (relative).
function M._find_companion_files(filepath)
  if not filepath or filepath == "" then return {} end
  local cwd = vim.fn.getcwd() .. "/"
  local companions = {}

  local function try(path)
    if vim.fn.filereadable(cwd .. path) == 1 then
      companions[#companions + 1] = path
    end
  end

  local dir = vim.fn.fnamemodify(filepath, ":h")
  local base = vim.fn.fnamemodify(filepath, ":t")
  local ext = vim.fn.fnamemodify(filepath, ":e")
  local stem = base:gsub("%." .. ext .. "$", "")
  local prefix = dir ~= "." and (dir .. "/") or ""

  -- Go: foo.go ↔ foo_test.go
  if ext == "go" then
    if stem:match("_test$") then
      try(prefix .. stem:gsub("_test$", "") .. ".go")
    else
      try(prefix .. stem .. "_test.go")
    end

  -- JS/TS: foo.ts ↔ foo.test.ts, foo.spec.ts, __tests__/foo.test.ts
  elseif ext == "ts" or ext == "tsx" or ext == "js" or ext == "jsx" then
    local clean_stem = stem:gsub("%.test$", ""):gsub("%.spec$", "")
    if stem:match("%.test$") or stem:match("%.spec$") then
      -- Test → source
      try(prefix .. clean_stem .. "." .. ext)
      -- May be in __tests__/ subdirectory
      if dir:match("__tests__$") then
        local parent = vim.fn.fnamemodify(dir, ":h")
        local pp = parent ~= "." and (parent .. "/") or ""
        try(pp .. clean_stem .. "." .. ext)
      end
    else
      -- Source → test
      try(prefix .. stem .. ".test." .. ext)
      try(prefix .. stem .. ".spec." .. ext)
      try(prefix .. "__tests__/" .. stem .. ".test." .. ext)
      try(prefix .. "__tests__/" .. stem .. ".spec." .. ext)
    end

  -- Python: foo.py ↔ test_foo.py, tests/test_foo.py
  elseif ext == "py" then
    if stem:match("^test_") then
      try(prefix .. stem:gsub("^test_", "") .. ".py")
      -- May be in tests/ subdirectory
      if dir:match("tests?$") then
        local parent = vim.fn.fnamemodify(dir, ":h")
        local pp = parent ~= "." and (parent .. "/") or ""
        try(pp .. stem:gsub("^test_", "") .. ".py")
      end
    else
      try(prefix .. "test_" .. stem .. ".py")
      try(prefix .. "tests/test_" .. stem .. ".py")
      try(prefix .. "test/test_" .. stem .. ".py")
    end

  -- Rust: same file (tests inline), or tests/foo.rs
  elseif ext == "rs" then
    if dir:match("tests$") then
      local parent = vim.fn.fnamemodify(dir, ":h")
      local pp = parent ~= "." and (parent .. "/src/") or "src/"
      try(pp .. stem .. ".rs")
      try(pp .. "lib.rs")
    else
      try(prefix:gsub("src/", "tests/") .. stem .. ".rs")
    end
  end

  return companions
end

--- Classify test/build output to distinguish compilation errors from test failures.
--- Returns: "build_error" | "test_failure" | "test_pass"
--- This is language-agnostic — checks common patterns from all major toolchains.
function M._classify_test_output(output, exit_code)
  if not output or output == "" then
    return exit_code == 0 and "test_pass" or "build_error"
  end

  -- If exit code 0, tests passed regardless of output
  if exit_code == 0 then return "test_pass" end

  -- ── Build error patterns (compilation/import/syntax failures) ──
  local build_patterns = {
    -- Go
    "%[build failed%]",
    "%[setup failed%]",               -- Go: test binary didn't compile
    "cannot find package",
    "undefined:",
    "imported and not used",
    "declared and not used",
    "syntax error:",
    "expected .-, found",
    "redeclared in this block",        -- duplicate declarations/methods
    "does not implement",              -- interface compliance failure
    "too many arguments",
    "not enough arguments",
    "cannot use .+ as .+ in",          -- type mismatch
    "has no field or method",
    "duplicate method",
    "missing return",
    -- Rust
    "error%[E%d+%]",
    "could not compile",
    "aborting due to %d+ previous error",
    -- Python
    "SyntaxError:",
    "ImportError:",
    "ModuleNotFoundError:",
    "IndentationError:",
    "NameError:.+not defined",
    -- JS/TS
    "SyntaxError:",
    "Cannot find module",
    "TS%d%d%d%d:",
    "Module not found",
    "ReferenceError:.+is not defined",
    -- Java
    "error: cannot find symbol",
    "error: package .+ does not exist",
    -- C/C++
    "error: .+undeclared",
    "fatal error: .+No such file",
    -- General
    "compilation failed",
    "compile error",
  }

  -- ── Test failure patterns (tests ran but assertions failed) ──
  local test_patterns = {
    -- Go
    "%-%-%- FAIL:",
    "FAIL%s+%S+%s+%[",           -- FAIL package [time]
    "FAIL$",
    "got .+, want",               -- Go test output
    -- Rust
    "test result: FAILED",
    "failures:",
    "thread .+ panicked at",
    -- Python (pytest)
    "FAILED",
    "AssertionError",
    "assert .+ ==",
    "%d+ failed",
    -- Python (unittest)
    "failures=%d+",
    "FAIL: test",
    -- JS/TS (Jest/Vitest/Mocha)
    "Tests?:.-failed",
    "✕",
    "✗",
    "expect%(.-%)%.",              -- expect().to / expect().toBe
    "AssertionError",
    -- General
    "test failed",
    "FAILED",
    "assertion failed",
  }

  local has_build_error = false
  local has_test_failure = false

  for _, pat in ipairs(build_patterns) do
    if output:match(pat) then
      has_build_error = true
      break
    end
  end

  for _, pat in ipairs(test_patterns) do
    if output:match(pat) then
      has_test_failure = true
      break
    end
  end

  -- Build errors take precedence: if code doesn't compile, tests can't run.
  -- Exception: Go outputs both build errors AND "FAIL" on compilation failure,
  -- so we check build_error first.
  if has_build_error and not has_test_failure then
    return "build_error"
  end

  -- Both present: look for definitive Go patterns that prove tests never ran.
  -- [build failed] = go build failure, [setup failed] = test binary compile failure.
  -- Also: if we see file:line compiler error messages, it's definitely a build error.
  if has_build_error and has_test_failure then
    if output:match("%[build failed%]")
      or output:match("%[setup failed%]")
      or output:match("%.go:%d+:%d+:") -- Go compiler error format (file.go:line:col:)
      or output:match("%.rs:%d+:%d+:")  -- Rust compiler error format
      or output:match("%.py\", line %d+") -- Python traceback format
      or output:match("%.ts%(%d+,%d+%)") -- TypeScript error format
    then
      return "build_error"
    end
    return "test_failure"
  end

  if has_test_failure then
    return "test_failure"
  end

  -- No recognizable pattern — assume build error (safer default for retry)
  return "build_error"
end

--------------------------------------------------------------------
-- Smoke tests: end-to-end validation after verify passes
--------------------------------------------------------------------

--- Run all smoke test commands sequentially. If any fails, enter retry loop.
--- Calls callback(qf_entries, smoke_failed).
function M._run_smoke_loop(step, qf_entries, callback, fallback_target, all_steps, step_idx)
  local smoke_tests = step.smoke_tests or {}
  if #smoke_tests == 0 then
    callback(qf_entries, false)
    return
  end

  local max_retries = M.MAX_RETRIES
  local attempt = 0
  local last_error_output = nil

  local step_files = M._collect_step_files(step, all_steps, step_idx)

  local target_path = nil
  for _, action in ipairs(step.actions) do
    if action.path and (action.verb == "create" or action.verb == "edit") then
      target_path = action.path
      break
    end
  end

  local function try_smoke()
    attempt = attempt + 1
    local smoke_idx = 1
    local smoke_failed = false
    local failed_output = ""

    local function run_next_smoke()
      if smoke_idx > #smoke_tests then
        -- All smoke tests passed
        qf_entries[#qf_entries + 1] = {
          text = string.format("✅ 🔥 smoke: all %d commands passed", #smoke_tests),
          type = "I",
        }
        callback(qf_entries, false)
        return
      end

      local smoke = smoke_tests[smoke_idx]
      local label = attempt == 1 and "smoke" or string.format("smoke (retry %d/%d)", attempt - 1, max_retries)

      run_command_async(smoke.command, function(result)
        local job_ref = result.job_id and string.format(" (job #%d)", result.job_id) or ""

        if result.ok then
          qf_entries[#qf_entries + 1] = {
            text = string.format("✅ 🔥 %s: %s (exit 0)%s", label, smoke.command, job_ref),
            type = "I",
          }
          smoke_idx = smoke_idx + 1
          vim.schedule(run_next_smoke)
        else
          -- Smoke test failed
          qf_entries[#qf_entries + 1] = {
            text = string.format("❌ 🔥 %s: %s (exit %d)%s", label, smoke.command, result.exit_code, job_ref),
            type = "W",
          }
          smoke_failed = true
          failed_output = result.output or ""

          -- Check if we should retry
          if not step.on_fail then
            qf_entries[#qf_entries + 1] = { text = "⚠️ No @dwight:on-fail — cannot fix smoke failure", type = "W" }
            callback(qf_entries, true)
            return
          end

          -- Identical error detection
          local trimmed = vim.trim(failed_output)
          if last_error_output and trimmed == last_error_output and attempt > 2 then
            qf_entries[#qf_entries + 1] = {
              text = "⚠️ Identical smoke error — stopping retries",
              type = "W",
            }
            callback(qf_entries, true)
            return
          end
          last_error_output = trimmed

          if attempt > max_retries then
            qf_entries[#qf_entries + 1] = {
              text = string.format("❌ Smoke failed after %d retries: %s", max_retries, smoke.command),
              type = "E",
            }
            callback(qf_entries, true)
            return
          end

          -- Build on-fail prompt with smoke context
          local retry_level = attempt
          local error_files = M._extract_error_files(failed_output)
          local on_fail_target = error_files[1] or target_path or fallback_target

          if not on_fail_target then
            qf_entries[#qf_entries + 1] = {
              text = "⚠️ No target file for smoke on-fail — stopping",
              type = "W",
            }
            callback(qf_entries, true)
            return
          end

          local on_fail_prompt = vim.tbl_extend("force", step.on_fail, {})
          on_fail_prompt.mode_overrides = { skip_rag = true, skip_git = true }
          -- Use specialized fix_smoke mode for smoke test failures
          on_fail_prompt.mode = "fix_smoke"
          on_fail_prompt._is_agent = true

          -- Inject step journal for cross-step awareness
          if step._journal and #step._journal > 0 then
            on_fail_prompt.extra_context = (on_fail_prompt.extra_context or "")
              .. "\nPREVIOUS STEPS IN THIS SESSION:\n"
              .. table.concat(step._journal, "\n") .. "\n"
          end

          -- Prepend smoke context to instructions
          local smoke_context = string.format(
            "SMOKE TEST FAILED: `%s` (exit %d).\n"
            .. "The unit tests pass but the application fails at runtime.\n"
            .. "This usually means: missing initialization (migrations not called), "
            .. "missing wiring (dependencies not connected), or wrong function signatures in production code path.\n"
            .. "Error output:\n```\n%s\n```\n\n",
            smoke.command, result.exit_code, (failed_output or ""):sub(1, 2000))

          on_fail_prompt.instructions = smoke_context .. (on_fail_prompt.instructions or "Fix the smoke test failure.")

          if retry_level >= 2 then
            local context_files = {}
            local seen = {}
            for _, f in ipairs(error_files) do
              if not seen[f] then seen[f] = true; context_files[#context_files + 1] = f end
            end
            for _, f in ipairs(step_files) do
              if not seen[f] then seen[f] = true; context_files[#context_files + 1] = f end
            end
            local files_ctx = M._gather_files_context(context_files)
            if files_ctx then
              on_fail_prompt.extra_context = "ALL related files:\n" .. files_ctx
            end
          end

          if retry_level >= 3 then
            on_fail_prompt.mode = "wire"  -- final attempt: focus on wiring
            on_fail_prompt.mode_overrides.is_multi = true
          end

          vim.notify(string.format("[dwight] 🔥 Smoke retry %d/%d: fixing %s",
            retry_level, max_retries, on_fail_target), vim.log.levels.INFO)

          M._run_prompt(on_fail_prompt, on_fail_target, function(entry, err)
            qf_entries[#qf_entries + 1] = entry
            if err then
              qf_entries[#qf_entries + 1] = { text = "❌ smoke on-fail prompt failed: " .. err, type = "E" }
              -- LLM errors may be transient — continue to next retry level
              if attempt <= max_retries then
                qf_entries[#qf_entries + 1] = {
                  text = string.format("🔄 LLM error on smoke retry %d — will escalate", attempt),
                  type = "W",
                }
                vim.schedule(try_smoke)
              else
                callback(qf_entries, true)
              end
              return
            end
            -- Re-run ALL smoke tests from the beginning
            vim.schedule(try_smoke)
          end)
        end
      end)
    end

    run_next_smoke()
  end

  try_smoke()
end

--------------------------------------------------------------------
-- Spec compliance check: verify output matches plan intent
--------------------------------------------------------------------

--- Build a spec compliance check prompt for a step.
--- Returns a prompt string or nil if not enough context.
local function build_spec_check_prompt(step)
  -- Gather what the step asked for (the "spec")
  local spec_parts = {}
  spec_parts[#spec_parts + 1] = "Step title: " .. (step.title or "?")

  for _, prompt in ipairs(step.prompts) do
    if prompt.instructions then
      spec_parts[#spec_parts + 1] = "Task: " .. prompt.instructions:sub(1, 500)
    end
  end

  if #spec_parts < 2 then return nil end -- no prompts = nothing to check

  -- Gather what was produced (read the actual files)
  local file_summaries = {}
  for _, action in ipairs(step.actions) do
    if action.path and (action.verb == "create" or action.verb == "edit") then
      local full_path = action.path
      if not full_path:match("^/") then full_path = vim.fn.getcwd() .. "/" .. full_path end
      if vim.fn.filereadable(full_path) == 1 then
        local f = io.open(full_path, "r")
        if f then
          local content = f:read("*a")
          f:close()
          -- Only include first 80 lines to keep prompt small
          local lines = vim.split(content, "\n", { plain = true })
          local preview = table.concat(lines, "\n", 1, math.min(80, #lines))
          if #lines > 80 then
            preview = preview .. string.format("\n... (%d more lines)", #lines - 80)
          end
          file_summaries[#file_summaries + 1] = string.format(
            "--- FILE: %s (%d lines) ---\n%s", action.path, #lines, preview)
        end
      end
    end
  end

  if #file_summaries == 0 then return nil end

  return string.format(
    "SPEC COMPLIANCE CHECK — answer in ONE line.\n\n"
    .. "SPEC (what was requested):\n%s\n\n"
    .. "OUTPUT (what was produced):\n%s\n\n"
    .. "Does the output match the spec? Check:\n"
    .. "1. Are ALL requested functions/types present?\n"
    .. "2. Is there anything EXTRA that wasn't requested?\n"
    .. "3. Do function signatures match what was specified?\n\n"
    .. "Reply with EXACTLY one of:\n"
    .. "COMPLIANT: All requirements met.\n"
    .. "DRIFT: <what diverged from spec>\n"
    .. "MISSING: <what was not implemented>",
    table.concat(spec_parts, "\n"),
    table.concat(file_summaries, "\n\n"))
end

--- Run a lightweight spec compliance check after a step's verify passes.
--- Calls callback(drift_note) where drift_note is nil (compliant) or a string.
--- This is NON-BLOCKING — drift is a warning, not a failure.
function M._run_spec_check(step, callback)
  local prompt = build_spec_check_prompt(step)
  if not prompt then
    callback(nil)
    return
  end

  -- Use the skills LLM runner for a quick one-shot check
  local ok = pcall(function()
    local log = require("dwight.log")
    local job_id = log._next_id()
    log.start(job_id, "execute:spec-check", vim.api.nvim_get_current_buf(), 0, 0, prompt:sub(1, 2000))

    require("dwight.skills")._run_llm(prompt, function(raw, code)
      if code ~= 0 or not raw then
        log.finish(job_id, "error", raw or "", nil, "spec check failed")
        callback(nil) -- spec check failed to run, skip silently
        return
      end

      local response = vim.trim(raw)
      if response:match("^COMPLIANT") then
        log.finish(job_id, "success", raw, "COMPLIANT", nil)
        callback(nil)
      elseif response:match("^DRIFT:") then
        local note = response:match("^DRIFT:%s*(.+)")
        log.finish(job_id, "success", raw, "DRIFT: " .. (note or ""), nil)
        callback("⚠️ Spec drift: " .. (note or "unknown"))
      elseif response:match("^MISSING:") then
        local note = response:match("^MISSING:%s*(.+)")
        log.finish(job_id, "success", raw, "MISSING: " .. (note or ""), nil)
        callback("⚠️ Spec gap: " .. (note or "unknown"))
      else
        log.finish(job_id, "success", raw, "ambiguous", nil)
        -- Ambiguous response, skip
        callback(nil)
      end
    end)
  end)

  -- If pcall failed (e.g., skills module not available), call back immediately
  if not ok then
    callback(nil)
  end
end

--------------------------------------------------------------------
-- Verify + on-fail retry loop
--------------------------------------------------------------------

--- Remove empty or seed-only files created by actions in this step.
--- Returns list of removed files (for logging). Language-agnostic:
--- any compiler/linter will choke on truly empty source files.
local function cleanup_empty_files(step)
  local cwd = vim.fn.getcwd() .. "/"
  local removed = {}
  for _, action in ipairs(step.actions) do
    if action.path and action.verb == "create" then
      local full = cwd .. action.path
      if vim.fn.filereadable(full) == 1 and not file_has_content(full) then
        os.remove(full)
        -- Also wipe the buffer if loaded (so it doesn't linger)
        local bufnr = vim.fn.bufnr(full)
        if bufnr ~= -1 then
          pcall(api.nvim_buf_delete, bufnr, { force = true })
        end
        removed[#removed + 1] = action.path
      end
    end
  end
  return removed
end

--- Run verify command with escalating retry strategy.
--- Supports two modes:
---   verify.expect_fail = false (default): expects exit 0 (green phase)
---   verify.expect_fail = true: expects test failures but NOT build errors (red phase)
---
--- Escalating retry strategy:
---   Retry 1: target error file, single-file fix
---   Retry 2: target error file with ALL step files as context
---   Retry 3: multi-file mode, can edit any file
---
--- Calls callback(entries, had_error) when done.
function M._run_verify_loop(step, qf_entries, callback, fallback_target, all_steps, step_idx)
  if not step.verify then
    callback(qf_entries, false)
    return
  end

  -- Layer 3: Clean up any empty files before verify.
  local removed = cleanup_empty_files(step)
  for _, path in ipairs(removed) do
    qf_entries[#qf_entries + 1] = {
      text = "🧹 Removed empty file: " .. path,
      type = "W",
    }
    vim.notify("[dwight] 🧹 Removed empty file before verify: " .. path, vim.log.levels.WARN)
  end

  local max_retries = M.MAX_RETRIES
  local attempt = 0
  local expect_fail = step.verify.expect_fail or false
  local last_error_output = nil  -- for identical error detection (F)

  -- Collect all files from this step + recent steps for context (A)
  local step_files = M._collect_step_files(step, all_steps, step_idx)

  -- Find target path for on-fail prompts.
  local target_path = nil
  for _, action in ipairs(step.actions) do
    if action.path and (action.verb == "create" or action.verb == "edit") then
      target_path = action.path
      break
    end
  end

  local function try_verify()
    attempt = attempt + 1
    local phase_label = expect_fail and "verify-fail" or "verify"
    local label = attempt == 1 and phase_label
      or string.format("%s (retry %d/%d)", phase_label, attempt - 1, max_retries)

    run_command_async(step.verify.command, function(result)
      local job_ref = result.job_id and string.format(" (job #%d)", result.job_id) or ""

      if expect_fail then
        -- ═══ RED PHASE ═══
        local classification = M._classify_test_output(result.output, result.exit_code)

        if classification == "test_pass" then
          qf_entries[#qf_entries + 1] = {
            text = string.format("⚠️ 🔍 %s: tests PASSED unexpectedly (exit %d)%s",
              label, result.exit_code, job_ref),
            type = "W",
          }
          callback(qf_entries, false)
          return
        end

        if classification == "test_failure" then
          qf_entries[#qf_entries + 1] = {
            text = string.format("✅ 🔴 %s: tests fail as expected (exit %d)%s — red phase confirmed",
              label, result.exit_code, job_ref),
            type = "I",
          }
          callback(qf_entries, false)
          return
        end

        -- build_error — fall through to retry
        qf_entries[#qf_entries + 1] = {
          text = string.format("❌ 🔍 %s: BUILD ERROR (exit %d)%s",
            label, result.exit_code, job_ref),
          type = "W",
        }

      else
        -- ═══ GREEN PHASE ═══
        qf_entries[#qf_entries + 1] = {
          text = string.format("%s 🔍 %s: %s (exit %d)%s",
            result.ok and "✅" or "❌", label, step.verify.command, result.exit_code, job_ref),
          type = result.ok and "I" or "W",
        }

        if result.ok then
          callback(qf_entries, false)
          return
        end
      end

      -- ═══ Shared retry logic ═══

      if not step.on_fail then
        qf_entries[#qf_entries + 1] = { text = "⚠️ No @dwight:on-fail — skipping retry", type = "W" }
        callback(qf_entries, false)
        return
      end

      -- (F) Identical error detection: if error output is the same as last attempt, bail early.
      -- Only check after all retry levels have had a chance (don't short-circuit wire mode).
      local trimmed_output = vim.trim(result.output or "")
      if last_error_output and trimmed_output == last_error_output and attempt > max_retries then
        qf_entries[#qf_entries + 1] = {
          text = "⚠️ Identical error output — stopping retries (same error won't fix itself)",
          type = "W",
        }
        qf_entries[#qf_entries + 1] = {
          text = "💡 Use :DwightAgentResume to retry after manual fixes",
          type = "I",
        }
        callback(qf_entries, true)
        return
      end
      last_error_output = trimmed_output

      if attempt > max_retries then
        qf_entries[#qf_entries + 1] = {
          text = string.format("❌ Failed after %d retries: %s", max_retries, step.verify.command),
          type = "E",
        }
        callback(qf_entries, true)
        return
      end

      -- (B) Escalating retry strategy
      -- attempt=1 → level 1 (single file), attempt=2 → level 2 (full context),
      -- attempt=3 → level 3 (wire mode)
      local retry_level = attempt

      -- Resolve target: error file → step target → fallback
      local error_files = M._extract_error_files(result.output)

      -- (G) All-404 detection: when every failing test gets 404, routes aren't registered.
      -- The fix is in the server/router file, not in the handler file.
      local all_404 = false
      if classification == "test_failure" and result.output then
        local fail_count = 0
        local four04_count = 0
        for line in result.output:gmatch("[^\n]+") do
          if line:match("%-%-%-% FAIL:") then fail_count = fail_count + 1 end
          if line:match("got 404") or line:match("status 404") then four04_count = four04_count + 1 end
        end
        all_404 = fail_count > 0 and four04_count >= fail_count
      end

      if all_404 then
        -- Look for server/router files in the step's file context
        local server_files = {}
        for _, f in ipairs(step_files) do
          if f:match("server%.go$") or f:match("router%.go$") or f:match("routes%.go$")
            or f:match("app%.go$") or f:match("main%.go$")
            or f:match("server%.ts$") or f:match("app%.ts$") or f:match("routes%.ts$") then
            server_files[#server_files + 1] = f
          end
        end
        -- Prepend server files to error_files so they get targeted first
        for i = #server_files, 1, -1 do
          table.insert(error_files, 1, server_files[i])
        end
      end

      -- (H) Template error detection: when errors mention template execution/parsing,
      -- include template files (.html, .tmpl, .gohtml) so the fix can see actual template names.
      local has_template_error = false
      if result.output then
        has_template_error = result.output:match("template:") ~= nil
          or result.output:match("is not defined") ~= nil
          or result.output:match("ExecuteTemplate") ~= nil
          or result.output:match("no template") ~= nil
          or result.output:match("html/template") ~= nil
          or result.output:match("template%.Must") ~= nil
          or result.output:match("template execution") ~= nil
      end

      if has_template_error then
        local template_files = {}
        for _, f in ipairs(step_files) do
          if f:match("%.html$") or f:match("%.tmpl$") or f:match("%.gohtml$") then
            template_files[#template_files + 1] = f
          end
        end
        -- Also look for server/render files that call ExecuteTemplate
        for _, f in ipairs(step_files) do
          if f:match("server%.go$") or f:match("render%.go$") or f:match("handler") then
            local seen = false
            for _, ef in ipairs(error_files) do if ef == f then seen = true; break end end
            if not seen then error_files[#error_files + 1] = f end
          end
        end
        for _, f in ipairs(template_files) do
          local seen = false
          for _, ef in ipairs(error_files) do if ef == f then seen = true; break end end
          if not seen then error_files[#error_files + 1] = f end
        end
      end

      local on_fail_target = error_files[1] or target_path or fallback_target

      if not on_fail_target then
        qf_entries[#qf_entries + 1] = {
          text = "⚠️ No target file for on-fail prompt — skipping retry",
          type = "W",
        }
        callback(qf_entries, false)
        return
      end

      -- Build the on-fail prompt with escalating context
      local on_fail_prompt = vim.tbl_extend("force", step.on_fail, {})
      -- Agent retries skip expensive/noisy context (RAG, git)
      on_fail_prompt.mode_overrides = { skip_rag = true, skip_git = true }

      -- Auto-upgrade mode based on error classification (if user didn't specify a mode)
      local user_mode = on_fail_prompt.mode
      if classification == "build_error" and (not user_mode or user_mode == "code" or user_mode == "fix") then
        on_fail_prompt.mode = "fix_build"
      elseif classification == "test_failure" and (not user_mode or user_mode == "code" or user_mode == "fix") then
        on_fail_prompt.mode = "fix_test"
      end

      -- Inject step journal for cross-step awareness (capped to last 2 entries)
      if step._journal and #step._journal > 0 then
        local j = step._journal
        local recent_start = math.max(1, #j - 1)
        local recent = {}
        for i = recent_start, #j do recent[#recent + 1] = j[i] end
        on_fail_prompt.extra_context = (on_fail_prompt.extra_context or "")
          .. "\nPREVIOUS STEPS (recent):\n"
          .. table.concat(recent, "\n") .. "\n"
      end

      -- Inject diff context: show the on-fail handler EXACTLY what was changed
      -- so it can fix targeted issues instead of guessing.
      -- Capped to 60 lines to prevent context pollution on large edits.
      local step_diff = M._compute_step_diff()
      if step_diff then
        local diff_lines = vim.split(step_diff, "\n", { plain = true })
        local capped_diff = step_diff
        if #diff_lines > 60 then
          local truncated = {}
          for i = 1, 60 do truncated[#truncated + 1] = diff_lines[i] end
          truncated[#truncated + 1] = string.format("... (%d more lines truncated)", #diff_lines - 60)
          capped_diff = table.concat(truncated, "\n")
        end
        on_fail_prompt.extra_context = (on_fail_prompt.extra_context or "")
          .. "\nCHANGES MADE BY THE PREVIOUS EDIT (diff):\n"
          .. "```diff\n" .. capped_diff .. "\n```\n"
          .. "Focus your fix on the lines that were changed above.\n"
      end

      -- Mark on-fail prompts as agent prompts (enables build gate, surgical edits)
      on_fail_prompt._is_agent = true

      -- Systematic debugging preamble: give the LLM a reasoning framework
      -- instead of just "fix it". Inspired by superpowers' 4-phase debugging.
      local error_snippet = (result.output or ""):sub(1, 1500)
      local debug_preamble = string.format(
        "SYSTEMATIC FIX — follow these steps:\n"
        .. "1. ERROR: %s (exit %d)\n"
        .. "2. IDENTIFY: Which specific line(s) in the code cause this error?\n"
        .. "3. HYPOTHESIS: WHY does it fail? (wrong type, missing import, logic error, etc.)\n"
        .. "4. MINIMAL FIX: Change ONLY the lines needed to fix this. Do NOT refactor.\n"
        .. "   Do NOT add unrelated improvements. Do NOT reorganize code.\n\n"
        .. "Error output:\n```\n%s\n```\n\n",
        classification or "unknown", result.exit_code or -1, error_snippet)
      on_fail_prompt.instructions = debug_preamble .. (on_fail_prompt.instructions or "Fix the error.")

      -- (G) Inject routing hint when all-404 detected
      if all_404 then
        on_fail_prompt.instructions = on_fail_prompt.instructions
          .. "\n\n⚠️ ALL failing tests return 404 (Not Found). This almost always means "
          .. "the routes/endpoints are not registered in the server/router. "
          .. "Check that the handler functions are wired to the mux/router in the server "
          .. "setup code (e.g., NewServer, routes(), app.use, etc.). "
          .. "The handler implementations are likely correct — the issue is route registration."
      end

      -- (H) Inject template hint when template errors detected
      if has_template_error then
        on_fail_prompt.instructions = on_fail_prompt.instructions
          .. "\n\n⚠️ Template execution error detected. Common causes: "
          .. "(1) Template name mismatch — the name in ExecuteTemplate(w, NAME, data) must match "
          .. "the {{define \"NAME\"}} in the .html file exactly. Check the template files. "
          .. "(2) Template not loaded — ensure templates are loaded via embed.FS or ParseGlob. "
          .. "(3) Nil data — ensure the data struct matches what the template expects. "
          .. "The template .html files are included in the context — read them to find the correct names."
      end

      if retry_level == 1 then
        -- Retry 1: single file, just error output
        -- Exception: if all-404 or template error detected, escalate immediately to multi-file
        -- since the fix needs to see files beyond the error file.
        if (all_404 or has_template_error) then
          local escalation_reason = all_404 and "all-404" or "template-error"
          vim.notify(string.format("[dwight] 🔄 Retry 1/%d: /%s %s (%s → multi-file)",
            max_retries, on_fail_prompt.mode or "fix", on_fail_target, escalation_reason), vim.log.levels.INFO)
          on_fail_prompt.mode_overrides = on_fail_prompt.mode_overrides or {}
          on_fail_prompt.mode_overrides.is_multi = true
          -- Include both handler and server files
          local context_files = {}
          local seen = {}
          for _, f in ipairs(error_files) do
            if not seen[f] then seen[f] = true; context_files[#context_files + 1] = f end
          end
          if target_path and not seen[target_path] then
            context_files[#context_files + 1] = target_path
          end
          local files_ctx = M._gather_files_context(context_files, on_fail_target)
          if files_ctx then
            on_fail_prompt.extra_context = (on_fail_prompt.extra_context or "") .. "\n" .. files_ctx
          end
          -- Cap context to prevent prompt bloat/timeouts (same as retry 3)
          local ctx = on_fail_prompt.extra_context or ""
          if #ctx > 15000 then
            on_fail_prompt.extra_context = ctx:sub(1, 15000)
              .. "\n... (context truncated to prevent timeout)\n"
          end
        else
          vim.notify(string.format("[dwight] 🔄 Retry 1/%d: /%s %s", max_retries,
            on_fail_prompt.mode or "fix", on_fail_target), vim.log.levels.INFO)
        end

      elseif retry_level == 2 then
        -- Retry 2: inject ALL related files as context (A)
        vim.notify(string.format("[dwight] 🔄 Retry 2/%d: /%s %s with full context (%d files)",
          max_retries, on_fail_prompt.mode or "fix", on_fail_target, #step_files),
          vim.log.levels.INFO)

        -- Merge error-referenced files + step files
        local context_files = {}
        local seen = {}
        for _, f in ipairs(error_files) do
          if not seen[f] then seen[f] = true; context_files[#context_files + 1] = f end
        end
        for _, f in ipairs(step_files) do
          if not seen[f] then seen[f] = true; context_files[#context_files + 1] = f end
        end

        local files_ctx = M._gather_files_context(context_files, on_fail_target)
        if files_ctx then
          on_fail_prompt.extra_context = (on_fail_prompt.extra_context or "")
            .. "\nHere are ALL related files for context:\n" .. files_ctx
        end

      else
        -- Retry 3: multi-file wire mode (can edit ANY file)
        -- FRESH START: strip accumulated journal/diff context. By retry 3,
        -- the prior context is noise — the LLM needs just the error + files.
        if not user_mode or user_mode == "code" or user_mode == "fix" then
          on_fail_prompt.mode = "wire"
        end
        vim.notify(string.format("[dwight] 🔄 Retry 3/%d: /%s fresh-start multi-file mode", max_retries,
          on_fail_prompt.mode or "wire"), vim.log.levels.INFO)

        -- Clear accumulated context — start fresh with just error + files
        on_fail_prompt.extra_context = ""

        local context_files = {}
        local seen = {}
        for _, f in ipairs(error_files) do
          if not seen[f] then seen[f] = true; context_files[#context_files + 1] = f end
        end
        for _, f in ipairs(step_files) do
          if not seen[f] then seen[f] = true; context_files[#context_files + 1] = f end
        end

        local files_ctx = M._gather_files_context(context_files, on_fail_target)
        on_fail_prompt.extra_context = (on_fail_prompt.extra_context or "")
          .. "\nIMPORTANT: You may need to edit MULTIPLE files to fix this. Use multi-file output format.\n"
          .. (files_ctx or "")

        -- Cap total extra_context to prevent prompt bloat/timeouts
        local ctx = on_fail_prompt.extra_context or ""
        if #ctx > 15000 then
          on_fail_prompt.extra_context = ctx:sub(1, 15000)
            .. "\n... (context truncated to prevent timeout)\n"
        end

        -- Switch mode to allow multi-file output
        on_fail_prompt.mode_overrides = on_fail_prompt.mode_overrides or {}
        on_fail_prompt.mode_overrides.is_multi = true
        -- Wire mode needs more time since it processes multiple files
        on_fail_prompt.mode_overrides.timeout_scale = 2
      end

      M._run_prompt(on_fail_prompt, on_fail_target, function(entry, err)
        qf_entries[#qf_entries + 1] = entry
        if err then
          qf_entries[#qf_entries + 1] = { text = "❌ on-fail prompt failed: " .. err, type = "E" }
          -- LLM errors may be transient (timeout, overload) — don't kill all retries.
          -- Continue to next retry level which may use a different/smaller prompt.
          if attempt <= max_retries then
            qf_entries[#qf_entries + 1] = {
              text = string.format("🔄 LLM error on retry %d — will escalate to retry %d", attempt - 1, attempt),
              type = "W",
            }
            vim.schedule(try_verify)
          else
            callback(qf_entries, true)
          end
          return
        end
        vim.schedule(try_verify)
      end)
    end)
  end

  try_verify()
end

--------------------------------------------------------------------
-- Delegate: recursive sub-plan generation + execution
--------------------------------------------------------------------

--- Generate a sub-plan for a delegate description, then execute it.
--- Calls callback(entries, had_error) when done.
function M._run_delegate(description, depth, qf_entries, callback)
  if depth >= M.MAX_DEPTH then
    qf_entries[#qf_entries + 1] = {
      text = string.format("⚠️ Max recursion depth (%d) — skipping delegate: %s", M.MAX_DEPTH, description),
      type = "W",
    }
    vim.notify("[dwight] Max recursion depth reached. Skipping: " .. description, vim.log.levels.WARN)
    callback(qf_entries, false)
    return
  end

  vim.notify(string.format("[dwight] 🔀 Delegate (depth %d): %s", depth + 1, description), vim.log.levels.INFO)

  -- Generate a sub-plan via agent
  local agent = require("dwight.agent")
  agent.generate_plan(description, function(plan_text, err)
    if err or not plan_text or vim.trim(plan_text) == "" then
      qf_entries[#qf_entries + 1] = {
        text = "❌ Delegate plan generation failed: " .. (err or "empty"),
        type = "E",
      }
      callback(qf_entries, true)
      return
    end

    qf_entries[#qf_entries + 1] = { text = "🔀 delegate: " .. description }

    -- Parse and execute the sub-plan
    local sub_steps = M.parse_plan(plan_text)
    if #sub_steps == 0 then
      qf_entries[#qf_entries + 1] = { text = "⚠️ Delegate produced no steps", type = "W" }
      callback(qf_entries, false)
      return
    end

    M._execute_steps(sub_steps, depth + 1, function(sub_entries, had_error)
      for _, e in ipairs(sub_entries) do qf_entries[#qf_entries + 1] = e end
      callback(qf_entries, had_error)
    end)
  end)
end

--------------------------------------------------------------------
-- Core execution loop (supports recursion depth)
--------------------------------------------------------------------

--- Extract all file paths a step touches (creates, edits, reads, prompts target).
--- Returns { write = {path,...}, read = {path,...}, has_run = bool, has_delegate = bool }
function M._step_file_sets(step)
  local writes = {}
  local reads = {}
  local has_run = false
  local has_delegate = #step.delegates > 0

  for _, action in ipairs(step.actions) do
    if action.verb == "create" or action.verb == "edit" then
      if action.path then writes[action.path] = true end
    elseif action.verb == "read" then
      local paths = action.paths or (action.path and { action.path } or {})
      for _, p in ipairs(paths) do reads[p] = true end
    elseif action.verb == "run" then
      has_run = true
    elseif action.verb == "move" then
      if action.src then reads[action.src] = true end
      if action.dest then writes[action.dest] = true end
    end
  end

  -- Prompt targets are writes
  for _, prompt in ipairs(step.prompts) do
    -- Target is resolved at runtime, but we can infer from actions
    for _, action in ipairs(step.actions) do
      if action.path and (action.verb == "create" or action.verb == "edit") then
        writes[action.path] = true
        break
      end
    end
  end

  return {
    write = writes,
    read = reads,
    has_run = has_run,
    has_delegate = has_delegate,
    has_verify = step.verify ~= nil,
    has_smoke = step.smoke_tests and #step.smoke_tests > 0,
  }
end

--- Compute parallel groups: consecutive steps with non-overlapping file sets.
--- Steps with run actions, delegates, verify, or smoke are always serialized.
--- Returns { { step_indices }, { step_indices }, ... }
function M._compute_parallel_groups(steps)
  local groups = {}
  local current_group = {}
  local current_writes = {}  -- all writes in current group
  local current_reads = {}   -- all reads in current group

  for i, step in ipairs(steps) do
    local sets = M._step_file_sets(step)

    -- Barrier conditions: step must run alone (sequentially)
    local is_barrier = sets.has_run or sets.has_delegate or sets.has_verify or sets.has_smoke
      or #step.prompts > 0  -- prompts are slow and complex, serialize them

    if is_barrier then
      -- Flush current group
      if #current_group > 0 then
        groups[#groups + 1] = current_group
      end
      -- This step runs alone
      groups[#groups + 1] = { i }
      current_group = {}
      current_writes = {}
      current_reads = {}
    else
      -- Check for file conflicts with current group
      local conflicts = false
      for path in pairs(sets.write) do
        if current_writes[path] or current_reads[path] then
          conflicts = true; break
        end
      end
      if not conflicts then
        for path in pairs(sets.read) do
          if current_writes[path] then
            conflicts = true; break
          end
        end
      end

      if conflicts then
        -- Flush and start new group
        if #current_group > 0 then
          groups[#groups + 1] = current_group
        end
        current_group = { i }
        current_writes = vim.tbl_extend("force", {}, sets.write)
        current_reads = vim.tbl_extend("force", {}, sets.read)
      else
        -- Add to current group
        current_group[#current_group + 1] = i
        for path in pairs(sets.write) do current_writes[path] = true end
        for path in pairs(sets.read) do current_reads[path] = true end
      end
    end
  end

  -- Flush remaining
  if #current_group > 0 then
    groups[#groups + 1] = current_group
  end

  return groups
end

--- Execute steps sequentially with verify/retry/delegate support.
--- Calls callback(qf_entries, had_error) when done.
--- on_step(step_idx, total, title): called when a step starts.
--- on_entry(entry): called when a log entry is produced.
function M._execute_steps(steps, depth, callback, on_step, on_entry, opts)
  opts = opts or {}
  local qf_entries = {}
  local step_idx = 1
  local had_error = false
  local last_target_path = nil  -- persists across steps for verify-only steps

  -- Step journal: accumulates context across steps for subsequent LLM calls.
  -- Each entry is a short summary of what happened in a completed step.
  local journal = opts.journal or {}

  --- Tag an entry with the current step number and notify status buffer.
  local function tag(entry)
    if entry and entry.text then
      entry.text = string.format("[Step %d] %s", steps[step_idx].number, entry.text)
    end
    if on_entry and entry then pcall(on_entry, entry) end
    return entry
  end

  --- Tag all entries in a list (from sub-calls like prompts, verify).
  local function tag_entries(entries, step_num)
    for _, e in ipairs(entries) do
      if e.text and not e.text:match("^%[Step ") then
        e.text = string.format("[Step %d] %s", step_num, e.text)
      end
      if on_entry then pcall(on_entry, e) end
    end
  end

  --- Build a journal entry for a completed step.
  local function journal_entry(step, outcome, verify_output)
    local actions_summary = {}
    for _, action in ipairs(step.actions) do
      if action.verb == "create" then actions_summary[#actions_summary + 1] = "created " .. (action.path or "?")
      elseif action.verb == "edit" then actions_summary[#actions_summary + 1] = "edited " .. (action.path or "?")
      elseif action.verb == "read" then
        local paths = action.paths or {}
        actions_summary[#actions_summary + 1] = "read " .. table.concat(paths, ", ")
      elseif action.verb == "run" then actions_summary[#actions_summary + 1] = "ran " .. (action.command or "?")
      end
    end

    local entry = string.format("Step %d (%s): %s.",
      step.number, step.title, outcome)
    if #actions_summary > 0 then
      entry = entry .. " Actions: " .. table.concat(actions_summary, "; ") .. "."
    end
    if step.verify then
      local verify_status = verify_output or "unknown"
      entry = entry .. " Verify: " .. step.verify.command .. " → " .. verify_status .. "."
    end
    return entry
  end

  --- Inject journal into all prompts for the current step.
  --- Also marks all prompts as agent prompts and injects session registry.
  --- CONTEXT CAPPING: Only inject the last 3 journal entries to keep prompts lean.
  --- Accumulated context causes drift — each prompt should see minimal history.
  local function inject_journal(step)
    for _, prompt in ipairs(step.prompts) do
      -- Mark as agent prompt (enables build gate, surgical edits, etc.)
      prompt._is_agent = true

      -- Inject session file registry
      local reg = M._registry_summary()
      if reg then
        prompt.extra_context = (prompt.extra_context or "")
          .. "\n" .. reg .. "\n"
      end
    end

    if #journal == 0 then return end

    -- Context capping: only inject the LAST 3 journal entries.
    -- Full history causes context pollution — the LLM gets confused by old errors
    -- and irrelevant details from steps that completed long ago.
    local recent_start = math.max(1, #journal - 2)
    local recent_journal = {}
    for i = recent_start, #journal do
      recent_journal[#recent_journal + 1] = journal[i]
    end

    local journal_text = string.format(
      "PREVIOUS STEPS (%d of %d, most recent):\n",
      #recent_journal, #journal)
      .. table.concat(recent_journal, "\n") .. "\n"
    for _, prompt in ipairs(step.prompts) do
      prompt.extra_context = journal_text .. (prompt.extra_context or "")
    end
  end

  local function run_next_step()
    if step_idx > #steps or had_error then
      local failed_num = had_error and steps[step_idx] and steps[step_idx].number or nil

      -- Adaptive replanning: if we failed and a replan callback exists, try to replan
      if had_error and opts.replan_fn and not opts._replanned then
        local failed_step = steps[step_idx]
        local remaining_steps = {}
        for i = step_idx + 1, #steps do remaining_steps[#remaining_steps + 1] = steps[i] end

        -- Get the last error output from qf_entries
        local last_error = ""
        for i = #qf_entries, math.max(1, #qf_entries - 5), -1 do
          if qf_entries[i] and qf_entries[i].text then
            last_error = qf_entries[i].text .. "\n" .. last_error
          end
        end

        vim.notify("[dwight] 🔄 Attempting adaptive replan…", vim.log.levels.INFO)
        if on_entry then
          pcall(on_entry, { text = "🔄 Adaptive replan: generating new steps for remaining work…" })
        end

        opts.replan_fn(journal, failed_step, remaining_steps, last_error, function(new_steps, err)
          if err or not new_steps or #new_steps == 0 then
            -- Replan failed, report original error
            if on_entry then
              pcall(on_entry, { text = "⚠️ Replan failed: " .. (err or "no steps generated") })
            end
            callback(qf_entries, had_error, failed_num, journal)
            return
          end

          -- Execute the new steps with _replanned=true to prevent infinite loop
          local new_opts = vim.tbl_extend("force", opts, {
            _replanned = true,
            journal = journal,  -- carry over the journal
          })

          if on_entry then
            pcall(on_entry, { text = string.format("🔄 Replan: executing %d new steps", #new_steps) })
          end

          M._execute_steps(new_steps, depth, function(new_entries, new_error, new_failed, updated_journal)
            -- Merge entries
            for _, e in ipairs(new_entries) do qf_entries[#qf_entries + 1] = e end
            callback(qf_entries, new_error, new_error and new_failed or nil, updated_journal or journal)
          end, on_step, on_entry, new_opts)
        end)
        return
      end

      callback(qf_entries, had_error, failed_num, journal)
      return
    end

    local step = steps[step_idx]
    vim.notify(string.format("[dwight] Step %d/%d: %s", step_idx, #steps, step.title), vim.log.levels.INFO)

    -- Notify status buffer
    if on_step then pcall(on_step, step_idx, #steps, step.title) end

    -- Inject journal context into this step's prompts
    inject_journal(step)

    -- Snapshot step files for diff-retry (captures content before LLM edits)
    M._snapshot_step(step)

    -- Phase 1: File actions (create, delete, move, run)
    for _, action in ipairs(step.actions) do
      local entry = M._execute_action(action)
      if entry then
        qf_entries[#qf_entries + 1] = tag(entry)
        -- Register file in session registry
        if action.path and action.verb then
          M._register_file(action.path, action.verb)
        end
        if entry.type == "E" then
          had_error = true
          callback(qf_entries, had_error, step.number, journal)
          return
        end
      end
    end

    -- Find target path for prompts (from step's file actions)
    local target_path = nil
    for _, action in ipairs(step.actions) do
      if action.path and (action.verb == "create" or action.verb == "edit") then
        target_path = action.path
        break
      end
    end

    -- Collect read files for context injection into prompts
    local read_files = {}
    for _, action in ipairs(step.actions) do
      if action.verb == "read" then
        local paths = action.paths or (action.path and { action.path } or {})
        for _, p in ipairs(paths) do read_files[#read_files + 1] = p end
      end
    end
    -- If we have read files, inject them as extra context on all prompts in this step
    if #read_files > 0 then
      local read_ctx = M._gather_files_context(read_files)
      if read_ctx then
        for _, prompt in ipairs(step.prompts) do
          prompt.extra_context = (prompt.extra_context or "")
            .. "\nThe following files were loaded for reference:\n" .. read_ctx
        end
      end
    end

    -- Update rolling target for verify-only steps to fall back on
    if target_path then
      last_target_path = target_path
    end

    local current_step_num = step.number

    -- Attach journal to step for on-fail context injection
    step._journal = journal

    -- Phase 2: Prompts → Phase 3: Delegates → Phase 4: Verify
    local function after_prompts()
      local function after_delegates()
        -- Phase 4: Verify + on-fail retry loop (pass context for escalation)
        local pre_verify_count = #qf_entries
        M._run_verify_loop(step, qf_entries, function(updated_entries, verify_failed)
          qf_entries = updated_entries
          -- Tag any new entries added by the verify loop + notify status
          for i = pre_verify_count + 1, #qf_entries do
            if qf_entries[i].text and not qf_entries[i].text:match("^%[Step ") then
              qf_entries[i].text = string.format("[Step %d] %s", current_step_num, qf_entries[i].text)
            end
            if on_entry then pcall(on_entry, qf_entries[i]) end
          end
          if verify_failed then
            had_error = true
            journal[#journal + 1] = journal_entry(step, "❌ FAILED (verify)", "all retries exhausted")
            callback(qf_entries, had_error, current_step_num, journal)
            return
          end

          -- Phase 4b: Spec compliance check (non-blocking)
          -- After verify passes, check if the output matches the plan's intent.
          -- Drift warnings get injected into the journal for subsequent steps.
          local function after_spec_check(drift_note)
            if drift_note then
              qf_entries[#qf_entries + 1] = tag({
                text = drift_note,
                type = "W",
              })
              -- Inject drift into journal so next steps are aware
              journal[#journal + 1] = string.format(
                "Step %d (%s): DRIFT WARNING — %s",
                step.number, step.title, drift_note)
            end

            -- Phase 5: Smoke tests (end-to-end validation)
            local smoke_tests = step.smoke_tests or {}
            if #smoke_tests > 0 then
              if on_entry then
                pcall(on_entry, { text = string.format("[Step %d] 🔥 Running %d smoke test(s)…",
                  current_step_num, #smoke_tests) })
              end
              local pre_smoke_count = #qf_entries
              M._run_smoke_loop(step, qf_entries, function(smoke_entries, smoke_failed)
                qf_entries = smoke_entries
                -- Tag smoke entries
                for i = pre_smoke_count + 1, #qf_entries do
                  if qf_entries[i].text and not qf_entries[i].text:match("^%[Step ") then
                    qf_entries[i].text = string.format("[Step %d] %s", current_step_num, qf_entries[i].text)
                  end
                  if on_entry then pcall(on_entry, qf_entries[i]) end
                end
                if smoke_failed then
                  had_error = true
                  journal[#journal + 1] = journal_entry(step, "❌ FAILED (smoke)", "smoke test failed")
                  callback(qf_entries, had_error, current_step_num, journal)
                  return
                end
                journal[#journal + 1] = journal_entry(step, "✅ passed", "exit 0 (with smoke)")
                step_idx = step_idx + 1
                vim.schedule(run_next_step)
              end, last_target_path, steps, step_idx)
            else
              journal[#journal + 1] = journal_entry(step, "✅ passed", "exit 0")
              step_idx = step_idx + 1
              vim.schedule(run_next_step)
            end
          end

          -- Run spec check (async, non-blocking — calls after_spec_check when done)
          if #step.prompts > 0 then
            M._run_spec_check(step, function(drift_note)
              vim.schedule(function() after_spec_check(drift_note) end)
            end)
          else
            after_spec_check(nil)
          end
        end, last_target_path, steps, step_idx)
      end

      -- Phase 3: Delegates (recursive sub-plans)
      if #step.delegates > 0 then
        local delegate_idx = 1
        local function next_delegate()
          if delegate_idx > #step.delegates then
            after_delegates()
            return
          end
          M._run_delegate(step.delegates[delegate_idx], depth, qf_entries, function(updated_entries, del_error)
            qf_entries = updated_entries
            if del_error then
              had_error = true
              callback(qf_entries, had_error, current_step_num, journal)
              return
            end
            delegate_idx = delegate_idx + 1
            vim.schedule(next_delegate)
          end)
        end
        next_delegate()
      else
        after_delegates()
      end
    end

    -- Phase 2: Prompts
    if #step.prompts > 0 then
      M._run_prompts_seq(step.prompts, target_path, function(entries, err)
        for _, e in ipairs(entries) do
          if e.text and not e.text:match("^%[Step ") then
            e.text = string.format("[Step %d] %s", current_step_num, e.text)
          end
          qf_entries[#qf_entries + 1] = e
        end
        if err then
          had_error = true
          callback(qf_entries, had_error, current_step_num, journal)
          return
        end
        vim.schedule(after_prompts)
      end)
    else
      after_prompts()
    end
  end

  run_next_step()
end

--------------------------------------------------------------------
-- Post-execution review: catch wiring bugs
--------------------------------------------------------------------

local REVIEW_PROMPT = [=[
You are reviewing code that was just implemented. All unit tests pass, but there may be
WIRING ISSUES — places where components are not properly connected in the production code path.

Common problems to look for:
1. **Missing migrations**: A model/table struct exists but AutoMigrate is never called in the
   production Open()/Init() function. Tests work because they set up their own in-memory DB.
2. **Missing initialization**: A function exists but the main entry point never calls it.
3. **Interface not wired**: An interface is defined but the concrete type is never created in main.go.
4. **Import missing**: A package is imported in tests but not in the production code that needs it.
5. **Configuration gap**: A function needs a parameter that's never passed in the real call chain.

Here are ALL files that were created or modified:

%s

INSTRUCTIONS:
- Trace the execution path from the entry point (main.go or equivalent) through to each feature.
- For EACH model/table/struct: verify that its migration/initialization IS called in production code.
- For EACH interface: verify a concrete implementation IS created and passed to consumers.
- For EACH new function: verify it IS reachable from the entry point.

If you find issues, output the FIXED file(s) using multi-file format:
--- FILE: path/to/file.go ---
```go
(complete fixed file content)
```

If everything looks correct, output ONLY the word: LGTM
Do NOT explain. Output ONLY fixed files or LGTM.
]=]

--- Collect all file paths that were touched (created/edited) across all steps.
function M._collect_all_touched_files(steps)
  local files = {}
  local seen = {}
  for _, step in ipairs(steps) do
    for _, action in ipairs(step.actions) do
      if action.path and (action.verb == "create" or action.verb == "edit") then
        if not seen[action.path] then
          seen[action.path] = true
          files[#files + 1] = action.path
        end
      end
    end
  end
  return files
end

--- Run a post-execution review to catch wiring bugs.
--- Calls callback(qf_entries, had_issues) when done.
function M._run_post_review(steps, qf_entries, on_entry, callback)
  local touched = M._collect_all_touched_files(steps)
  if #touched == 0 then
    callback(qf_entries, false)
    return
  end

  -- Also include main entry point files
  local cwd = vim.fn.getcwd() .. "/"
  local entry_candidates = { "main.go", "cmd/main.go", "src/main.ts", "src/index.ts",
    "src/main.py", "main.py", "app.py", "src/main.rs", "src/lib.rs" }
  local seen = {}
  for _, f in ipairs(touched) do seen[f] = true end
  for _, candidate in ipairs(entry_candidates) do
    if not seen[candidate] and vim.fn.filereadable(cwd .. candidate) == 1 then
      touched[#touched + 1] = candidate
      seen[candidate] = true
    end
  end

  -- Gather file contents
  local files_ctx = M._gather_files_context(touched)
  if not files_ctx or files_ctx == "" then
    callback(qf_entries, false)
    return
  end

  local prompt = string.format(REVIEW_PROMPT, files_ctx)

  local entry = { text = "🔎 Post-execution review: checking wiring…" }
  qf_entries[#qf_entries + 1] = entry
  if on_entry then pcall(on_entry, entry) end

  vim.notify("[dwight] 🔎 Running post-execution review…", vim.log.levels.INFO)

  local log = require("dwight.log")
  local job_id = log._next_id()
  log.start(job_id, "execute:post-review", vim.api.nvim_get_current_buf(), 0, 0, prompt:sub(1, 4000))

  require("dwight.skills")._run_llm(prompt, function(raw, code)
    if code ~= 0 or not raw or vim.trim(raw) == "" then
      log.finish(job_id, "error", raw or "", nil, "Post-review LLM call failed")
      local e = { text = "⚠️ Post-review: LLM call failed (non-critical)", type = "W" }
      qf_entries[#qf_entries + 1] = e
      if on_entry then pcall(on_entry, e) end
      callback(qf_entries, false)  -- non-critical, don't block
      return
    end

    local trimmed = vim.trim(raw)

    -- Check if the review found no issues
    if trimmed == "LGTM" or trimmed:match("^LGTM") then
      log.finish(job_id, "success", raw, "LGTM", nil)
      local e = { text = "✅ 🔎 Post-review: LGTM — no wiring issues found" }
      qf_entries[#qf_entries + 1] = e
      if on_entry then pcall(on_entry, e) end
      callback(qf_entries, false)
      return
    end

    -- The review found issues — try to apply multi-file output
    local multi_files = nil
    pcall(function()
      multi_files = require("dwight.multifile").parse(raw)
    end)

    -- Fallback: try our own simple parser for --- FILE: path --- blocks
    if not multi_files then
      multi_files = {}
      for path, content in raw:gmatch("%-%-%-% FILE:%s*(%S+)%s*%-%-%-\n```%w*\n(.-)\n```") do
        multi_files[#multi_files + 1] = { path = path, content = content }
      end
      if #multi_files == 0 then multi_files = nil end
    end

    if multi_files and #multi_files > 0 then
      log.finish(job_id, "success", raw,
        string.format("Post-review: %d file fix(es)", #multi_files), nil)
      local e = { text = string.format("🔧 🔎 Post-review: fixing %d file(s)", #multi_files) }
      qf_entries[#qf_entries + 1] = e
      if on_entry then pcall(on_entry, e) end

      -- Apply fixes using the multifile module
      pcall(function()
        local multifile = require("dwight.multifile")
        local count = multifile.apply_all(multi_files)
        local ae = { text = string.format("  📝 Applied %d file fix(es)", count or #multi_files) }
        qf_entries[#qf_entries + 1] = ae
        if on_entry then pcall(on_entry, ae) end
      end)

      -- Re-verify: try to build after fixes
      local verify_cmd = nil
      -- Find last verify command from the plan
      for i = #steps, 1, -1 do
        if steps[i].verify and not steps[i].verify.expect_fail then
          verify_cmd = steps[i].verify.command
          break
        end
      end

      if verify_cmd then
        local ve = { text = "🔍 Re-verifying after review fixes: " .. verify_cmd }
        qf_entries[#qf_entries + 1] = ve
        if on_entry then pcall(on_entry, ve) end

        run_command_async(verify_cmd, function(result)
          local job_ref = result.job_id and string.format(" (job #%d)", result.job_id) or ""
          if result.ok then
            local ok_e = { text = "✅ 🔎 Post-review: fixes verified" .. job_ref }
            qf_entries[#qf_entries + 1] = ok_e
            if on_entry then pcall(on_entry, ok_e) end
            callback(qf_entries, false)
          else
            local fail_e = {
              text = string.format("❌ 🔎 Post-review: fixes broke build (exit %d)%s — manual fix needed",
                result.exit_code, job_ref),
              type = "W",
            }
            qf_entries[#qf_entries + 1] = fail_e
            if on_entry then pcall(on_entry, fail_e) end
            callback(qf_entries, true)
          end
        end)
      else
        callback(qf_entries, false)
      end
    else
      -- LLM returned something but not parseable fixes — log it
      log.finish(job_id, "success", raw, "Post-review: issues found but not parseable", nil)
      local e = { text = "⚠️ 🔎 Post-review: found potential issues but couldn't parse fixes", type = "W" }
      qf_entries[#qf_entries + 1] = e
      if on_entry then pcall(on_entry, e) end
      callback(qf_entries, false)
    end
  end)
end

--------------------------------------------------------------------
-- Public entry points
--------------------------------------------------------------------

--- Execute a parsed plan (top-level). Shows quickfix on completion.
--- opts.start_step: (optional) step number to start from (for resume)
--- opts.on_complete: (optional) callback(qf_entries, had_error, failed_step_idx)
function M.execute(steps, opts)
  opts = opts or {}

  if #steps == 0 then
    vim.notify("[dwight] No executable steps found in plan.", vim.log.levels.WARN)
    return
  end

  -- Reset session state for this execution
  M._reset_registry()

  -- If resuming, skip steps before start_step
  local start_from = opts.start_step or 1
  local exec_steps = steps
  if start_from > 1 then
    exec_steps = {}
    for i = start_from, #steps do
      exec_steps[#exec_steps + 1] = steps[i]
    end
    vim.notify(string.format("[dwight] ▶️ Resuming from step %d/%d", start_from, #steps), vim.log.levels.INFO)
  end

  -- Summary
  local total_actions, total_prompts, total_verifies, total_delegates, total_smokes = 0, 0, 0, 0, 0
  for _, s in ipairs(exec_steps) do
    total_actions = total_actions + #s.actions
    total_prompts = total_prompts + #s.prompts
    if s.verify then total_verifies = total_verifies + 1 end
    total_delegates = total_delegates + #s.delegates
    total_smokes = total_smokes + #(s.smoke_tests or {})
  end

  -- Compute parallel groups and batch action-only steps
  local cfg = require("dwight").config
  local parallel_groups = M._compute_parallel_groups(exec_steps)
  local batched_count = 0
  if cfg.parallel_steps ~= false and #parallel_groups < #exec_steps then
    -- Merge action-only parallel groups into single batched steps
    local merged_steps = {}
    for _, group in ipairs(parallel_groups) do
      if #group > 1 then
        -- Check if ALL steps in group are action-only (no prompts, no verify, etc.)
        local all_action_only = true
        for _, idx in ipairs(group) do
          local s = exec_steps[idx]
          if #s.prompts > 0 or s.verify or #s.delegates > 0
            or (s.smoke_tests and #s.smoke_tests > 0) then
            all_action_only = false; break
          end
        end

        if all_action_only then
          -- Merge into a single batched step
          local combined = {
            number = exec_steps[group[1]].number,
            title = string.format("Batch: %s + %d more",
              exec_steps[group[1]].title, #group - 1),
            actions = {},
            prompts = {},
            verify = nil,
            on_fail = nil,
            delegates = {},
            smoke_tests = {},
            _batched_from = {},
          }
          for _, idx in ipairs(group) do
            for _, a in ipairs(exec_steps[idx].actions) do
              combined.actions[#combined.actions + 1] = a
            end
            combined._batched_from[#combined._batched_from + 1] = exec_steps[idx].number
          end
          merged_steps[#merged_steps + 1] = combined
          batched_count = batched_count + (#group - 1)
        else
          -- Can't merge — add individually
          for _, idx in ipairs(group) do
            merged_steps[#merged_steps + 1] = exec_steps[idx]
          end
        end
      else
        merged_steps[#merged_steps + 1] = exec_steps[group[1]]
      end
    end
    exec_steps = merged_steps
  end

  local step_list = {}
  for _, step in ipairs(exec_steps) do
    local parts = {}
    if #step.actions > 0 then parts[#parts + 1] = #step.actions .. " action(s)" end
    if #step.prompts > 0 then parts[#parts + 1] = #step.prompts .. " prompt(s)" end
    if step.verify then
      parts[#parts + 1] = step.verify.expect_fail and "verify-fail" or "verify"
    end
    if #step.delegates > 0 then parts[#parts + 1] = #step.delegates .. " delegate(s)" end
    local smokes = step.smoke_tests or {}
    if #smokes > 0 then parts[#parts + 1] = #smokes .. " smoke(s)" end
    if step._batched_from then
      parts[#parts + 1] = "⚡batched(" .. table.concat(step._batched_from, ",") .. ")"
    end
    step_list[#step_list + 1] = string.format("  %d. %s — %s",
      step.number, step.title, table.concat(parts, ", "))
  end

  local parallel_note = batched_count > 0
    and string.format(", %d batched", batched_count) or ""
  vim.notify(string.format(
    "[dwight] 🚀 Executing plan: %d steps, %d actions, %d prompts, %d verifies, %d smokes, %d delegates%s.\n%s",
    #exec_steps, total_actions, total_prompts, total_verifies, total_smokes, total_delegates,
    parallel_note, table.concat(step_list, "\n")),
    vim.log.levels.INFO)

  -- Disable diff preview during automated execution
  local saved_diff_preview = cfg.diff_preview
  cfg.diff_preview = false

  -- Snapshot all files that will be touched (for DwightMultiUndo)
  local snapshot_paths = {}
  for _, step in ipairs(exec_steps) do
    for _, action in ipairs(step.actions) do
      if action.path and (action.verb == "create" or action.verb == "edit") then
        snapshot_paths[#snapshot_paths + 1] = action.path
      end
    end
  end
  if #snapshot_paths > 0 then
    pcall(function()
      require("dwight.multifile").snapshot_agent(snapshot_paths)
    end)
  end

  -- Thread callbacks for status buffer
  local on_step = opts.on_step
  local on_entry = opts.on_entry

  -- Build execution opts for _execute_steps
  local exec_opts = {
    replan_fn = opts.replan_fn,
    journal = opts.journal or {},
  }

  M._execute_steps(exec_steps, 0, function(qf_entries, had_error, failed_step_idx, journal)
    -- Restore diff preview
    cfg.diff_preview = saved_diff_preview

    local function finalize(final_entries, final_error, final_failed_idx)
      -- Show quickfix
      if #final_entries > 0 then
        vim.fn.setqflist({}, "r", {
          title = final_error and "dwight: execution (FAILED)" or "dwight: execution complete",
          items = final_entries,
        })
        vim.cmd("copen")
      end

      if final_error then
        vim.notify("[dwight] ❌ Execution failed. Use :DwightAgentResume to retry or :DwightMultiUndo to revert.",
          vim.log.levels.ERROR)
      else
        vim.notify(string.format("[dwight] ✅ Complete! %d steps executed.", #exec_steps), vim.log.levels.INFO)
      end

      -- Callback for agent integration (pass journal for session learning)
      if opts.on_complete then
        opts.on_complete(final_entries, final_error, final_failed_idx, journal)
      end
    end

    -- Post-execution review: catch wiring bugs (only when enabled and all steps passed)
    if not had_error and opts.post_review then
      M._run_post_review(exec_steps, qf_entries, on_entry, function(reviewed_entries, review_error)
        finalize(reviewed_entries, review_error, review_error and -1 or nil)
      end)
    else
      finalize(qf_entries, had_error, failed_step_idx)
    end
  end, on_step, on_entry, exec_opts)
end

--- :DwightExecute — run from current buffer or selection
function M.run(opts)
  opts = opts or {}

  local bufnr = api.nvim_get_current_buf()
  local text

  if opts.range and opts.range > 0 then
    local s = vim.fn.line("'<") or 1
    local e = vim.fn.line("'>") or vim.fn.line("$")
    local lines = api.nvim_buf_get_lines(bufnr, s - 1, e, false)
    text = table.concat(lines, "\n")
  else
    local lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
    text = table.concat(lines, "\n")
  end

  local steps = M.parse_plan(text)
  if #steps == 0 then
    vim.notify("[dwight] No @dwight: directives found. Use /plan to generate an executable plan first.", vim.log.levels.WARN)
    return
  end

  M.execute(steps)
end

return M
