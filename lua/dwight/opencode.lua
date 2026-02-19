-- dwight/opencode.lua
-- Two backends:
--   "api"      — Direct Claude API via curl. One request, zero overhead. Predictable cost.
--   "opencode" — opencode CLI (agent mode, higher token usage).
--
-- Default: "api" (set backend = "opencode" in setup to use the CLI).

local M = {}

local uv = vim.loop or vim.uv

local function get_config()
  return require("dwight").config
end

local function get_dwight()
  return require("dwight")
end

--------------------------------------------------------------------
-- Output Parsing (STRICT — fenced code blocks only)
--------------------------------------------------------------------

local function extract_code_block(raw)
  local blocks = {}
  for block in raw:gmatch("```[%w_]*%s*\n(.-)\n%s*```") do
    blocks[#blocks + 1] = block
  end
  if #blocks == 0 then
    for block in raw:gmatch("```[%w_]*%s*\n(.-)```") do
      blocks[#blocks + 1] = block
    end
  end
  if #blocks == 0 then return nil end

  local best = blocks[1]
  for i = 2, #blocks do
    if #blocks[i] > #best then best = blocks[i] end
  end
  return best
end

local function looks_like_monologue(text)
  local lines = vim.split(text, "\n", { plain = true })
  if #lines == 0 then return true end
  local signals, total = 0, 0
  for _, line in ipairs(lines) do
    local t = vim.trim(line)
    if t ~= "" then
      total = total + 1
      if t:match("^I['']ll ") or t:match("^I['']m ") or t:match("^I will ")
        or t:match("^Let me ") or t:match("^Now let") or t:match("^Here is")
        or t:match("^Here's") or t:match("^This code") or t:match("^The code")
        or t:match("^I need to") or t:match("^First,") or t:match("^Note:")
        or t:match("^Looking at") or t:match("^Based on") or t:match("^To implement")
        or t:match("^The changes") or t:match("^Key changes") or t:match("^Summary")
        or t:match("^I've ") or t:match("^I have ") or t:match("^Now,")
        or t:match("^%d+%.%s+[A-Z]") then
        signals = signals + 1
      end
    end
  end
  if total == 0 then return true end
  return (signals / total) > 0.4
end

local function parse_output(raw, original_text, _language)
  if not raw or raw == "" then return nil end
  local code = extract_code_block(raw)
  if not code then return nil end
  if looks_like_monologue(code) then return nil end
  code = code:gsub("^\n+", ""):gsub("\n+$", "")
  local orig_lines = #vim.split(original_text, "\n", { plain = true })
  local new_lines = #vim.split(code, "\n", { plain = true })
  if orig_lines > 5 and new_lines < orig_lines * 0.15 then return nil end
  return code
end

--------------------------------------------------------------------
-- Job ID
--------------------------------------------------------------------

local function new_job_id()
  return require("dwight.log")._next_id()
end

--------------------------------------------------------------------
-- Overlap / line adjustment
--------------------------------------------------------------------

local function has_overlap(bufnr, start_line, end_line)
  local dwight = get_dwight()
  for _, job in pairs(dwight._active_jobs) do
    if job.bufnr == bufnr then
      if start_line <= job.end_line and end_line >= job.start_line then return true end
    end
  end
  return false
end

local function adjust_other_jobs(exclude_job_id, bufnr, start_line, old_end_line, new_count)
  local dwight = get_dwight()
  local ui = require("dwight.ui")
  local old_count = old_end_line - start_line + 1
  local delta = new_count - old_count
  if delta == 0 then return end
  for id, job in pairs(dwight._active_jobs) do
    if id ~= exclude_job_id and job.bufnr == bufnr and job.start_line > old_end_line then
      job.start_line = job.start_line + delta
      job.end_line = job.end_line + delta
      ui.update_indicator_range(id, job.start_line, job.end_line)
    end
  end
end

--------------------------------------------------------------------
-- Shared: handle LLM response
--------------------------------------------------------------------

local function handle_response(job_id, raw_output, err_output, exit_code, selection, mode_name, prompt_text)
  local ui = require("dwight.ui")
  local dwight = get_dwight()
  local log = require("dwight.log")

  local bufnr = selection.bufnr
  local job = dwight._active_jobs[job_id]
  local cur_start = job and job.start_line or selection.start_line
  local cur_end = job and job.end_line or selection.end_line

  ui.clear_indicators(job_id)
  dwight._active_jobs[job_id] = nil

  if exit_code ~= 0 then
    local msg = string.format("Exit %d: %s", exit_code, err_output)
    log.finish(job_id, "error", raw_output, nil, msg)
    vim.notify("[dwight] Job #" .. job_id .. " failed: " .. err_output, vim.log.levels.ERROR)
    return
  end

  if raw_output == "" then
    log.finish(job_id, "error", "", nil, "Empty output")
    vim.notify("[dwight] Job #" .. job_id .. ": empty output.", vim.log.levels.WARN)
    return
  end

  local parsed_code = parse_output(raw_output, selection.text, selection.filetype)

  if not parsed_code then
    log.finish(job_id, "parse_fail", raw_output, nil, "No valid code block / monologue detected")
    vim.notify("[dwight] Job #" .. job_id .. ": no valid code block. Check :DwightLog.", vim.log.levels.WARN)
    return
  end

  local norm_orig = vim.trim(selection.text):gsub("%s+", " ")
  local norm_new = vim.trim(parsed_code):gsub("%s+", " ")
  if norm_orig == norm_new then
    log.finish(job_id, "no_change", raw_output, parsed_code, nil)
    vim.notify("[dwight] Job #" .. job_id .. ": no changes.", vim.log.levels.INFO)
    return
  end

  local new_lines = vim.split(parsed_code, "\n", { plain = true })
  M._replace_selection_atomic(bufnr, cur_start, cur_end, parsed_code)
  adjust_other_jobs(job_id, bufnr, cur_start, cur_end, #new_lines)

  log.finish(job_id, "success", raw_output, parsed_code, nil)
  pcall(function()
    require("dwight.tracker").record(mode_name or "custom", #prompt_text, #raw_output)
  end)

  local remaining = 0
  for _, j in pairs(dwight._active_jobs) do
    if j.bufnr == bufnr then remaining = remaining + 1 end
  end
  local msg = string.format("[dwight] ✅ Job #%d done (lines %d-%d).", job_id, cur_start, cur_end)
  if remaining > 0 then msg = msg .. string.format(" %d job(s) still running.", remaining) end
  vim.notify(msg, vim.log.levels.INFO)
end

--------------------------------------------------------------------
-- Backend: Direct Claude API (lean, one request)
--------------------------------------------------------------------

local function run_api(prompt_text, selection, cfg, mode_name, job_id)
  local dwight = get_dwight()
  local ui = require("dwight.ui")
  local log = require("dwight.log")

  local api_key = cfg.api_key or os.getenv("ANTHROPIC_API_KEY")
  if not api_key or api_key == "" then
    log.finish(job_id, "error", "", nil, "No ANTHROPIC_API_KEY")
    ui.clear_indicators(job_id)
    dwight._active_jobs[job_id] = nil
    vim.notify(
      "[dwight] No API key. Set ANTHROPIC_API_KEY env var or api_key in setup.",
      vim.log.levels.ERROR)
    return
  end

  local model = cfg.model or "claude-sonnet-4-20250514"
  local max_tokens = cfg.max_tokens or 4096

  -- Build JSON payload — minimal, no tools, no system prompt bloat
  local payload = vim.json.encode({
    model = model,
    max_tokens = max_tokens,
    messages = {
      { role = "user", content = prompt_text },
    },
  })

  -- Write payload to temp file (avoids shell escaping issues)
  local payload_file = vim.fn.tempname() .. "_dwight_payload.json"
  local f = io.open(payload_file, "w")
  if not f then
    log.finish(job_id, "error", "", nil, "Failed to write payload")
    ui.clear_indicators(job_id)
    dwight._active_jobs[job_id] = nil
    return
  end
  f:write(payload)
  f:close()

  local stdout_chunks = {}
  local stderr_chunks = {}
  local stdout = uv.new_pipe(false)
  local stderr = uv.new_pipe(false)

  local base_url = cfg.api_base_url or "https://api.anthropic.com"

  local handle
  handle = uv.spawn("curl", {
    args = {
      "-sS",
      "--max-time", tostring(math.floor(cfg.timeout / 1000)),
      "-X", "POST",
      base_url .. "/v1/messages",
      "-H", "Content-Type: application/json",
      "-H", "x-api-key: " .. api_key,
      "-H", "anthropic-version: 2023-06-01",
      "-d", "@" .. payload_file,
    },
    stdio = { nil, stdout, stderr },
  }, function(code, _signal)
    if stdout then stdout:close() end
    if stderr then stderr:close() end
    if handle then handle:close() end
    pcall(os.remove, payload_file)

    vim.schedule(function()
      local raw_json = table.concat(stdout_chunks, "")
      local err_output = table.concat(stderr_chunks, "")

      if code ~= 0 then
        handle_response(job_id, "", "curl failed: " .. err_output, code, selection, mode_name, prompt_text)
        return
      end

      -- Parse API response
      local ok, resp = pcall(vim.json.decode, raw_json)
      if not ok then
        handle_response(job_id, raw_json, "Invalid JSON response", 1, selection, mode_name, prompt_text)
        return
      end

      -- Check for API errors
      if resp.error then
        local err_msg = resp.error.message or vim.inspect(resp.error)
        handle_response(job_id, raw_json, err_msg, 1, selection, mode_name, prompt_text)
        return
      end

      -- Extract text from content blocks
      local text_parts = {}
      if resp.content then
        for _, block in ipairs(resp.content) do
          if block.type == "text" then
            text_parts[#text_parts + 1] = block.text
          end
        end
      end
      local raw_text = table.concat(text_parts, "\n")

      -- Log usage info
      if resp.usage then
        local u = resp.usage
        local usage_note = string.format("tokens: %d in, %d out",
          u.input_tokens or 0, u.output_tokens or 0)
        -- Append to log entry for visibility
        raw_text = raw_text .. "\n\n<!-- " .. usage_note .. " -->"
      end

      handle_response(job_id, raw_text, "", 0, selection, mode_name, prompt_text)
    end)
  end)

  if not handle then
    pcall(os.remove, payload_file)
    log.finish(job_id, "error", "", nil, "Failed to spawn curl")
    ui.clear_indicators(job_id)
    dwight._active_jobs[job_id] = nil
    return
  end

  stdout:read_start(function(err, data)
    if not err and data then stdout_chunks[#stdout_chunks + 1] = data end
  end)
  stderr:read_start(function(err, data)
    if not err and data then stderr_chunks[#stderr_chunks + 1] = data end
  end)
end

--------------------------------------------------------------------
-- Backend: opencode CLI
--------------------------------------------------------------------

local function run_opencode(prompt_text, selection, cfg, mode_name, job_id)
  local dwight = get_dwight()
  local ui = require("dwight.ui")
  local log = require("dwight.log")

  local prompt_file = vim.fn.tempname() .. "_dwight_prompt.md"
  local f = io.open(prompt_file, "w")
  if not f then
    log.finish(job_id, "error", "", nil, "Failed to write prompt")
    ui.clear_indicators(job_id)
    dwight._active_jobs[job_id] = nil
    return
  end
  f:write(prompt_text)
  f:close()

  local extra_flags = {}
  if cfg.model then
    extra_flags[#extra_flags + 1] = "--model"
    extra_flags[#extra_flags + 1] = cfg.model
  end
  for _, flag in ipairs(cfg.opencode_flags or {}) do
    extra_flags[#extra_flags + 1] = flag
  end

  local wrapper = vim.fn.tempname() .. "_dwight_run.sh"
  local wf = io.open(wrapper, "w")
  if not wf then
    os.remove(prompt_file)
    log.finish(job_id, "error", "", nil, "Failed to write wrapper")
    ui.clear_indicators(job_id)
    dwight._active_jobs[job_id] = nil
    return
  end
  wf:write('#!/bin/sh\n')
  wf:write(string.format('%s run', cfg.opencode_bin))
  for _, flag in ipairs(extra_flags) do
    wf:write(string.format(' %s', vim.fn.shellescape(flag)))
  end
  wf:write(string.format(' "$(cat %s)"\n', prompt_file))
  wf:close()
  os.execute("chmod +x " .. vim.fn.shellescape(wrapper))

  local stdout_chunks = {}
  local stderr_chunks = {}
  local stdout = uv.new_pipe(false)
  local stderr = uv.new_pipe(false)

  local handle
  handle = uv.spawn("sh", {
    args = { wrapper },
    stdio = { nil, stdout, stderr },
    cwd = vim.fn.getcwd(),
  }, function(code, _signal)
    if stdout then stdout:close() end
    if stderr then stderr:close() end
    if handle then handle:close() end
    pcall(os.remove, prompt_file)
    pcall(os.remove, wrapper)

    vim.schedule(function()
      handle_response(
        job_id,
        table.concat(stdout_chunks, ""),
        table.concat(stderr_chunks, ""),
        code, selection, mode_name, prompt_text)
    end)
  end)

  if not handle then
    pcall(os.remove, prompt_file)
    pcall(os.remove, wrapper)
    log.finish(job_id, "error", "", nil, "Failed to spawn opencode")
    ui.clear_indicators(job_id)
    dwight._active_jobs[job_id] = nil
    return
  end

  stdout:read_start(function(err, data)
    if not err and data then stdout_chunks[#stdout_chunks + 1] = data end
  end)
  stderr:read_start(function(err, data)
    if not err and data then stderr_chunks[#stderr_chunks + 1] = data end
  end)
end

--------------------------------------------------------------------
-- Public API: run
--------------------------------------------------------------------

function M.run(prompt_text, selection, cfg, mode_name)
  local ui = require("dwight.ui")
  local dwight = get_dwight()
  local log = require("dwight.log")

  local bufnr = selection.bufnr
  local start_line = selection.start_line
  local end_line = selection.end_line

  if has_overlap(bufnr, start_line, end_line) then
    vim.notify("[dwight] This selection overlaps with a running job.", vim.log.levels.WARN)
    return
  end

  local job_id = new_job_id()
  log.start(job_id, mode_name or "custom", bufnr, start_line, end_line, prompt_text)
  ui.show_indicators(job_id, bufnr, start_line, end_line)

  dwight._active_jobs[job_id] = {
    handle = nil, bufnr = bufnr, start_line = start_line, end_line = end_line,
    mode = mode_name or "custom", started = os.time(),
  }

  local backend = cfg.backend or "api"

  if backend == "api" then
    run_api(prompt_text, selection, cfg, mode_name, job_id)
  else
    run_opencode(prompt_text, selection, cfg, mode_name, job_id)
  end

  -- Timeout
  local timer = uv.new_timer()
  timer:start(cfg.timeout, 0, function()
    timer:close()
    local job = dwight._active_jobs[job_id]
    if job then
      if job.handle and not job.handle:is_closing() then job.handle:kill("sigterm") end
      vim.schedule(function()
        ui.clear_indicators(job_id)
        dwight._active_jobs[job_id] = nil
        log.finish(job_id, "timeout", "", nil, "Timed out")
        vim.notify("[dwight] Job #" .. job_id .. " timed out.", vim.log.levels.ERROR)
      end)
    end
  end)

  -- Parallel job notification
  local active_count = 0
  for _ in pairs(dwight._active_jobs) do active_count = active_count + 1 end
  if active_count > 1 then
    vim.notify(string.format("[dwight] Job #%d started (%d parallel).", job_id, active_count), vim.log.levels.INFO)
  end
end

--------------------------------------------------------------------
-- Atomic Buffer Replacement
--------------------------------------------------------------------

function M._replace_selection_atomic(bufnr, start_line, end_line, new_text)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  local new_lines = vim.split(new_text, "\n", { plain = true })

  local eventignore = vim.o.eventignore
  vim.o.eventignore = "all"

  local current_line_count = vim.api.nvim_buf_line_count(bufnr)
  if end_line > current_line_count then end_line = current_line_count end

  if vim.api.nvim_get_current_buf() == bufnr then pcall(vim.cmd, "undojoin") end
  vim.api.nvim_buf_set_lines(bufnr, start_line - 1, end_line, false, new_lines)
  vim.o.eventignore = eventignore

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
