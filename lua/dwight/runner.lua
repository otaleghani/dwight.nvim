-- dwight/runner.lua
-- Run build/test commands and capture output for AI context.
-- :DwightRun <cmd> executes a command, stores output.
-- The /fix mode and @last-run inject this output into prompts.

local M = {}

local uv = vim.loop or vim.uv

--------------------------------------------------------------------
-- State
--------------------------------------------------------------------

M._last_run = nil  -- { cmd, exit_code, stdout, stderr, timestamp, duration }
M._history = {}    -- ring buffer of runs
M._max_history = 20

--------------------------------------------------------------------
-- Run a command
--------------------------------------------------------------------

--- Run a shell command, capture output, store for AI context.
---@param cmd string Shell command to run
---@param opts table|nil { cwd = string }
function M.run(cmd, opts)
  opts = opts or {}
  local cwd = opts.cwd or vim.fn.getcwd()

  vim.notify("[dwight] Running: " .. cmd, vim.log.levels.INFO)

  local stdout_chunks = {}
  local stderr_chunks = {}
  local stdout = uv.new_pipe(false)
  local stderr = uv.new_pipe(false)
  local started = os.time()

  local handle
  handle = uv.spawn("sh", {
    args = { "-c", cmd },
    stdio = { nil, stdout, stderr },
    cwd = cwd,
  }, function(code, _signal)
    if stdout then stdout:close() end
    if stderr then stderr:close() end
    if handle then handle:close() end

    vim.schedule(function()
      local result = {
        cmd       = cmd,
        exit_code = code,
        stdout    = table.concat(stdout_chunks, ""),
        stderr    = table.concat(stderr_chunks, ""),
        timestamp = started,
        duration  = os.time() - started,
      }

      -- Trim to last 5000 chars to avoid blowing up prompts
      if #result.stdout > 5000 then
        result.stdout = "... (truncated)\n" .. result.stdout:sub(-5000)
      end
      if #result.stderr > 5000 then
        result.stderr = "... (truncated)\n" .. result.stderr:sub(-5000)
      end

      M._last_run = result
      table.insert(M._history, 1, result)
      while #M._history > M._max_history do
        table.remove(M._history)
      end

      -- Log it
      pcall(function()
        local log = require("dwight.log")
        local job_id = log._next_id()
        log.start(job_id, "run:" .. cmd:sub(1, 30), vim.api.nvim_get_current_buf(), 0, 0, cmd)
        local status = code == 0 and "success" or "error"
        log.finish(job_id, status, result.stdout .. "\n" .. result.stderr, nil,
          code ~= 0 and ("Exit code " .. code) or nil)
      end)

      -- Notify
      local icon = code == 0 and "✅" or "❌"
      local output_preview = ""
      if code ~= 0 and result.stderr ~= "" then
        local first_line = result.stderr:match("^([^\n]+)")
        output_preview = first_line and (": " .. first_line) or ""
      end

      vim.notify(
        string.format("%s [dwight] '%s' finished (exit %d, %ds)%s",
          icon, cmd, code, result.duration, output_preview),
        code == 0 and vim.log.levels.INFO or vim.log.levels.WARN
      )
    end)
  end)

  if not handle then
    vim.notify("[dwight] Failed to run command.", vim.log.levels.ERROR)
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
-- Interactive run
--------------------------------------------------------------------

--- Prompt the user for a command if none given.
---@param cmd string|nil
function M.run_interactive(cmd)
  if cmd and cmd ~= "" then
    M.run(cmd)
    return
  end

  -- Try to detect a sensible default
  local default = M._detect_runner()

  vim.ui.input({
    prompt = "Command to run: ",
    default = default,
  }, function(input)
    if input and input ~= "" then
      M.run(input)
    end
  end)
end

--- Try to detect the project's test/build runner.
---@return string
function M._detect_runner()
  local cwd = vim.fn.getcwd()
  local checks = {
    { file = "Makefile",       cmd = "make" },
    { file = "package.json",   cmd = "npm test" },
    { file = "Cargo.toml",     cmd = "cargo test" },
    { file = "go.mod",         cmd = "go test ./..." },
    { file = "mix.exs",        cmd = "mix test" },
    { file = "Gemfile",        cmd = "bundle exec rspec" },
    { file = "pyproject.toml", cmd = "pytest" },
    { file = "setup.py",       cmd = "pytest" },
    { file = "flake.nix",      cmd = "nix build" },
    { file = "build.zig",      cmd = "zig build test" },
    { file = "CMakeLists.txt", cmd = "cmake --build build && ctest --test-dir build" },
  }

  for _, check in ipairs(checks) do
    if vim.fn.filereadable(cwd .. "/" .. check.file) == 1 then
      return check.cmd
    end
  end

  return ""
end

--------------------------------------------------------------------
-- Context for prompts
--------------------------------------------------------------------

--- Get the last run output formatted for prompt inclusion.
---@return string|nil
function M.last_run_context()
  if not M._last_run then return nil end
  local r = M._last_run

  local parts = {
    string.format("Command: %s", r.cmd),
    string.format("Exit code: %d", r.exit_code),
    string.format("Duration: %ds", r.duration),
  }

  if r.stdout ~= "" then
    parts[#parts + 1] = "\n── stdout ──"
    parts[#parts + 1] = r.stdout
  end

  if r.stderr ~= "" then
    parts[#parts + 1] = "\n── stderr ──"
    parts[#parts + 1] = r.stderr
  end

  return table.concat(parts, "\n")
end

--------------------------------------------------------------------
-- Display
--------------------------------------------------------------------

--- Show last run output in a floating window.
function M.show_output()
  if not M._last_run then
    vim.notify("[dwight] No runs yet. Use :DwightRun <cmd>", vim.log.levels.INFO)
    return
  end

  local r = M._last_run
  local lines = vim.split(
    string.format("$ %s  (exit %d, %ds)\n\n%s%s",
      r.cmd, r.exit_code, r.duration,
      r.stdout ~= "" and (r.stdout .. "\n") or "",
      r.stderr ~= "" and ("STDERR:\n" .. r.stderr) or ""),
    "\n"
  )

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"

  local width = math.min(100, vim.o.columns - 10)
  local height = math.min(#lines + 2, vim.o.lines - 6)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor", width = width, height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = require("dwight").config.border,
    title = " Last Run ", title_pos = "center",
  })

  vim.keymap.set("n", "q", function() vim.api.nvim_win_close(win, true) end, { buffer = buf })
  vim.keymap.set("n", "<Esc>", function() vim.api.nvim_win_close(win, true) end, { buffer = buf })
end

return M
