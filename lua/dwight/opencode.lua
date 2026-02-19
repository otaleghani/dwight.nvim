-- dwight/opencode.lua
-- Integration with the opencode CLI.
-- Supports PARALLEL jobs with per-job indicators, logging, and dedup.

local M = {}

local uv = vim.loop or vim.uv

local function get_config()
  return require("dwight").config
end

local function get_dwight()
  return require("dwight")
end

--------------------------------------------------------------------
-- Output Parsing
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
  if #blocks > 0 then
    local best = blocks[1]
    for i = 2, #blocks do
      if #blocks[i] > #best then best = blocks[i] end
    end
    return best
  end
  return nil
end

local function looks_like_code(text, _language)
  local lines = vim.split(text, "\n", { plain = true })
  if #lines == 0 then return false end
  local code_ind, prose_ind = 0, 0
  for _, line in ipairs(lines) do
    local t = vim.trim(line)
    if t == "" then
      -- skip
    elseif t:match("^%-%-") or t:match("^#") or t:match("^//") or t:match("^/%*") or t:match("^;") then
      code_ind = code_ind + 1
    elseif t:match("^[%w_%.%:%(%)%{%}%[%]%=%;%,<>%+%-%*%&%|%!%~%@%%]") then
      code_ind = code_ind + 1
    elseif t:match("^This ") or t:match("^The ") or t:match("^I ") or
           t:match("^Here ") or t:match("^Note") or t:match("^In ") then
      prose_ind = prose_ind + 1
    else
      code_ind = code_ind + 0.5
    end
  end
  local total = code_ind + prose_ind
  if total == 0 then return false end
  return (prose_ind / total) < 0.3
end

local function parse_output(raw, original_text, language)
  if not raw or raw == "" then return nil end

  local code = extract_code_block(raw)
  if not code then
    local stripped = raw
    stripped = stripped:gsub("^.-\n([\t ]*[%w_])", "%1")
    stripped = stripped:gsub("\n\n[A-Z][^\n]*$", "")
    if looks_like_code(stripped, language) then code = stripped end
  end
  if not code and looks_like_code(raw, language) then code = raw end
  if not code then return nil end

  code = code:gsub("^\n+", ""):gsub("\n+$", "")

  local orig_lines = #vim.split(original_text, "\n", { plain = true })
  local new_lines = #vim.split(code, "\n", { plain = true })
  if orig_lines > 5 and new_lines < orig_lines * 0.2 then return nil end

  return code
end

--------------------------------------------------------------------
-- Job ID generation & dedup
--------------------------------------------------------------------

local function new_job_id()
  return require("dwight.log")._next_id()
end

--- Content hash for dedup: prevents firing the same selection twice.
---@param bufnr number
---@param start_line number
---@param end_line number
---@return string
local function selection_key(bufnr, start_line, end_line)
  return string.format("%d:%d:%d", bufnr, start_line, end_line)
end

--------------------------------------------------------------------
-- Overlap / adjustment
--------------------------------------------------------------------

local function has_overlap(bufnr, start_line, end_line)
  local dwight = get_dwight()
  for _, job in pairs(dwight._active_jobs) do
    if job.bufnr == bufnr then
      if start_line <= job.end_line and end_line >= job.start_line then
        return true
      end
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
    if id ~= exclude_job_id and job.bufnr == bufnr then
      if job.start_line > old_end_line then
        job.start_line = job.start_line + delta
        job.end_line = job.end_line + delta
        -- Update indicator positions
        ui.update_indicator_range(id, job.start_line, job.end_line)
      end
    end
  end
end

--------------------------------------------------------------------
-- Write prompt to temp file
--------------------------------------------------------------------

local function write_prompt_file(prompt_text)
  local tmpfile = vim.fn.tempname() .. "_dwight_prompt.md"
  local f = io.open(tmpfile, "w")
  if not f then
    vim.notify("[dwight] Failed to create temp prompt file", vim.log.levels.ERROR)
    return nil
  end
  f:write(prompt_text)
  f:close()
  return tmpfile
end

--------------------------------------------------------------------
-- Run opencode (parallel-safe, logged, per-job indicators)
--------------------------------------------------------------------

function M.run(prompt_text, selection, cfg, mode_name)
  local ui = require("dwight.ui")
  local dwight = get_dwight()
  local log = require("dwight.log")

  local bufnr = selection.bufnr
  local start_line = selection.start_line
  local end_line = selection.end_line

  -- Dedup: prevent exact same selection from being processed twice
  if has_overlap(bufnr, start_line, end_line) then
    vim.notify("[dwight] This selection overlaps with a running job. Wait or cancel first.",
      vim.log.levels.WARN)
    return
  end

  -- Write prompt
  local prompt_file = write_prompt_file(prompt_text)
  if not prompt_file then return end

  local job_id = new_job_id()

  -- Log the start
  log.start(job_id, mode_name or "custom", bufnr, start_line, end_line, prompt_text)

  -- Show per-job indicators
  ui.show_indicators(job_id, bufnr, start_line, end_line)

  -- Build flags
  local extra_flags = {}
  if cfg.model then
    extra_flags[#extra_flags + 1] = "--model"
    extra_flags[#extra_flags + 1] = cfg.model
  end
  for _, flag in ipairs(cfg.opencode_flags) do
    extra_flags[#extra_flags + 1] = flag
  end

  -- Wrapper script
  local wrapper = vim.fn.tempname() .. "_dwight_run.sh"
  local wf = io.open(wrapper, "w")
  if not wf then
    vim.notify("[dwight] Failed to create wrapper script", vim.log.levels.ERROR)
    os.remove(prompt_file)
    ui.clear_indicators(job_id)
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

  local original_text = selection.text
  local language = selection.filetype or "text"

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
      local job = dwight._active_jobs[job_id]
      local cur_start = job and job.start_line or start_line
      local cur_end = job and job.end_line or end_line

      -- Clear this job's indicators
      ui.clear_indicators(job_id)
      dwight._active_jobs[job_id] = nil

      local raw_output = table.concat(stdout_chunks, "")
      local err_output = table.concat(stderr_chunks, "")

      if code ~= 0 then
        local msg = string.format("opencode exit %d: %s", code, err_output)
        log.finish(job_id, "error", raw_output, nil, msg)
        vim.notify("[dwight] Job #" .. job_id .. " failed: " .. err_output, vim.log.levels.ERROR)
        return
      end

      if raw_output == "" then
        log.finish(job_id, "error", "", nil, "Empty output")
        vim.notify("[dwight] Job #" .. job_id .. ": empty output.", vim.log.levels.WARN)
        return
      end

      local parsed_code = parse_output(raw_output, original_text, language)

      if not parsed_code then
        log.finish(job_id, "parse_fail", raw_output, nil, "Could not extract code")
        vim.notify(
          "[dwight] Job #" .. job_id .. ": couldn't extract code. Check :DwightLog for details.",
          vim.log.levels.WARN)
        vim.fn.setreg("+", raw_output)
        return
      end

      -- No-change check
      local norm_orig = vim.trim(original_text):gsub("%s+", " ")
      local norm_new = vim.trim(parsed_code):gsub("%s+", " ")
      if norm_orig == norm_new then
        log.finish(job_id, "no_change", raw_output, parsed_code, nil)
        vim.notify("[dwight] Job #" .. job_id .. ": no changes.", vim.log.levels.INFO)
        return
      end

      -- Replace and adjust
      local new_lines = vim.split(parsed_code, "\n", { plain = true })
      M._replace_selection_atomic(bufnr, cur_start, cur_end, parsed_code)
      adjust_other_jobs(job_id, bufnr, cur_start, cur_end, #new_lines)

      -- Log success
      log.finish(job_id, "success", raw_output, parsed_code, nil)

      -- Track usage
      pcall(function()
        require("dwight.tracker").record(mode_name or "custom", #prompt_text, #raw_output)
      end)

      local remaining = 0
      for _, j in pairs(dwight._active_jobs) do
        if j.bufnr == bufnr then remaining = remaining + 1 end
      end

      local msg = string.format("[dwight] ✅ Job #%d done (lines %d-%d).", job_id, cur_start, cur_end)
      if remaining > 0 then
        msg = msg .. string.format(" %d job(s) still running.", remaining)
      end
      vim.notify(msg, vim.log.levels.INFO)
    end)
  end)

  if not handle then
    vim.notify("[dwight] Failed to spawn opencode.", vim.log.levels.ERROR)
    ui.clear_indicators(job_id)
    pcall(os.remove, prompt_file)
    pcall(os.remove, wrapper)
    log.finish(job_id, "error", "", nil, "Failed to spawn")
    return
  end

  -- Track
  dwight._active_jobs[job_id] = {
    handle     = handle,
    bufnr      = bufnr,
    start_line = start_line,
    end_line   = end_line,
    mode       = mode_name or "custom",
    started    = os.time(),
  }

  stdout:read_start(function(err, data)
    if err then return end
    if data then stdout_chunks[#stdout_chunks + 1] = data end
  end)

  stderr:read_start(function(err, data)
    if err then return end
    if data then stderr_chunks[#stderr_chunks + 1] = data end
  end)

  -- Timeout
  local timer = uv.new_timer()
  timer:start(cfg.timeout, 0, function()
    timer:close()
    if handle and not handle:is_closing() then
      handle:kill("sigterm")
      vim.schedule(function()
        log.finish(job_id, "timeout", table.concat(stdout_chunks, ""), nil, "Timed out")
        vim.notify("[dwight] Job #" .. job_id .. " timed out.", vim.log.levels.ERROR)
      end)
    end
  end)

  -- Notify
  local active_count = 0
  for _ in pairs(dwight._active_jobs) do active_count = active_count + 1 end
  if active_count > 1 then
    vim.notify(string.format("[dwight] Job #%d started (lines %d-%d). %d parallel jobs.",
      job_id, start_line, end_line, active_count), vim.log.levels.INFO)
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

  local current_buf = vim.api.nvim_get_current_buf()
  if current_buf == bufnr then pcall(vim.cmd, "undojoin") end

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

--------------------------------------------------------------------
-- Direct API fallback
--------------------------------------------------------------------

function M.run_api(prompt_text, selection, api_config)
  local ui = require("dwight.ui")
  local bufnr = selection.bufnr
  local job_id = new_job_id()

  ui.show_indicators(job_id, bufnr, selection.start_line, selection.end_line)

  local body
  if api_config.provider == "anthropic" then
    body = vim.fn.json_encode({
      model = api_config.model or "claude-sonnet-4-20250514",
      max_tokens = 8192,
      messages = { { role = "user", content = prompt_text } },
    })
  else
    body = vim.fn.json_encode({
      model = api_config.model or "gpt-4o",
      messages = { { role = "user", content = prompt_text } },
      max_tokens = 8192,
    })
  end

  local tmpbody = vim.fn.tempname() .. ".json"
  local f = io.open(tmpbody, "w")
  if f then f:write(body); f:close() end

  local endpoint = api_config.endpoint
  local auth_header
  if api_config.provider == "anthropic" then
    endpoint = endpoint or "https://api.anthropic.com/v1/messages"
    auth_header = string.format("-H 'x-api-key: %s' -H 'anthropic-version: 2023-06-01'", api_config.api_key)
  else
    endpoint = endpoint or "https://api.openai.com/v1/chat/completions"
    auth_header = string.format("-H 'Authorization: Bearer %s'", api_config.api_key)
  end

  local curl_cmd = string.format(
    "curl -s -X POST %s %s -H 'Content-Type: application/json' -d @%s",
    endpoint, auth_header, vim.fn.shellescape(tmpbody))

  vim.fn.jobstart(curl_cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      vim.schedule(function()
        os.remove(tmpbody)
        ui.clear_indicators(job_id)
        local raw = table.concat(data, "\n")
        local ok, resp = pcall(vim.fn.json_decode, raw)
        if not ok then
          vim.notify("[dwight] Failed to parse API response", vim.log.levels.ERROR)
          return
        end
        local output
        if api_config.provider == "anthropic" then
          output = resp.content and resp.content[1] and resp.content[1].text or ""
        else
          output = resp.choices and resp.choices[1] and resp.choices[1].message
            and resp.choices[1].message.content or ""
        end
        local parsed = parse_output(output, selection.text, selection.filetype or "text")
        if parsed then
          M._replace_selection_atomic(bufnr, selection.start_line, selection.end_line, parsed)
          vim.notify("[dwight] Code updated.", vim.log.levels.INFO)
        else
          vim.notify("[dwight] Could not extract valid code.", vim.log.levels.WARN)
        end
      end)
    end,
  })
end

return M
