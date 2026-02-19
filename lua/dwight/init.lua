-- dwight.nvim: "I'm not superstitious, but I am a little stitious." — Michael Scott
-- A developer-centered AI coding assistant for Neovim.

local M = {}

M._version = "1.0.0"

local function require_mod(name)
  return require("dwight." .. name)
end

M.defaults = {
  opencode_bin = "opencode",
  default_skills = {},
  lsp_context_lines = 80,
  include_diagnostics = true,
  include_type_info = true,
  include_references = true,
  max_references = 10,
  indicator_style = "both",
  indicator_sign = "⟳",
  indicator_text = " ⏳ dwight processing…",
  indicator_hl = "DwightProcessing",
  border = "rounded",
  comment_styles = nil,
  model = nil,
  opencode_flags = {},
  timeout = 120000,
}

M.config = {}
M._active_jobs = {}

--------------------------------------------------------------------
-- Setup
--------------------------------------------------------------------

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", {}, M.defaults, opts or {})

  local hl = vim.api.nvim_set_hl
  hl(0, "DwightProcessing",  { fg = "#e0af68", bold = true, italic = true, default = true })
  hl(0, "DwightSkill",       { fg = "#7dcfff", bold = true, underline = true, default = true })
  hl(0, "DwightSkillInvalid",{ fg = "#f7768e", bold = true, strikethrough = true, default = true })
  hl(0, "DwightMode",        { fg = "#e0af68", bold = true, default = true })
  hl(0, "DwightSymbol",      { fg = "#bb9af7", bold = true, underline = true, default = true })
  hl(0, "DwightReplace",     { fg = "#9ece6a", italic = true, default = true })
  hl(0, "DwightBorder",      { fg = "#7aa2f7", default = true })
  hl(0, "DwightTitle",       { fg = "#bb9af7", bold = true, default = true })

  vim.fn.sign_define("DwightProcessing", {
    text = M.config.indicator_sign, texthl = "DwightProcessing",
  })

  M._register_commands()
end

--------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------

function M._register_commands()
  local cmd = vim.api.nvim_create_user_command

  cmd("DwightInvoke", function() M.invoke() end,
    { range = true, desc = "Invoke with prompt" })

  cmd("DwightMode", function(o) M.invoke_mode(o.args) end,
    { nargs = 1, range = true,
      complete = function() return require_mod("modes").list() end,
      desc = "Invoke a mode" })

  cmd("DwightCancel", function(o)
    if o.args == "all" then M.cancel_all() else M.cancel() end
  end, { nargs = "?", complete = function() return { "all" } end, desc = "Cancel job(s)" })

  -- Project
  cmd("DwightInit", function() require_mod("project").init() end, { desc = "Initialize project" })

  -- Skills
  cmd("DwightSkills", function() require_mod("skills").pick() end, { desc = "Browse skills" })
  cmd("DwightGenSkill", function() require_mod("skills").generate() end, { desc = "Generate skill" })
  cmd("DwightInstallSkills", function() require_mod("project").install_builtins() end, { desc = "Install built-in skills" })

  -- Docs
  cmd("DwightDocs", function() require_mod("docs").generate_from_url() end, { desc = "Skill from docs URL" })

  -- Log
  cmd("DwightLog", function() require_mod("log").show() end, { desc = "Job log" })

  -- Runner (build/test)
  cmd("DwightRun", function(o) require_mod("runner").run_interactive(o.args) end,
    { nargs = "?", desc = "Run build/test command" })
  cmd("DwightRunOutput", function() require_mod("runner").show_output() end,
    { desc = "Show last run output" })

  -- Info
  cmd("DwightUsage", function() require_mod("tracker").show() end, { desc = "Usage stats" })
  cmd("DwightModel", function()
    vim.notify("[dwight] Model: " .. require_mod("tracker").get_model(), vim.log.levels.INFO)
  end, { desc = "Show model" })
  cmd("DwightStatus", function() M.status() end, { desc = "Full status" })
end

--------------------------------------------------------------------
-- Core API
--------------------------------------------------------------------

function M.invoke()
  local selection = require_mod("ui").get_visual_selection()
  if not selection then
    vim.notify("[dwight] Select code in visual mode first.", vim.log.levels.WARN)
    return
  end
  require_mod("ui").open_prompt(selection, nil)
end

function M.invoke_mode(mode_name)
  local modes = require_mod("modes")
  local mode = modes.get(mode_name)
  if not mode then
    vim.notify("[dwight] Unknown mode: " .. tostring(mode_name), vim.log.levels.ERROR)
    return
  end

  local selection = require_mod("ui").get_visual_selection()
  if not selection then
    vim.notify("[dwight] Select code in visual mode first.", vim.log.levels.WARN)
    return
  end

  local ctx = require_mod("lsp").gather_context(selection)
  local prompt_text = require_mod("prompt").build(mode, selection, ctx)
  require_mod("opencode").run(prompt_text, selection, M.config, mode_name)
end

--------------------------------------------------------------------
-- Cancel
--------------------------------------------------------------------

function M.cancel()
  local bufnr = vim.api.nvim_get_current_buf()
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]

  local buffer_jobs = {}
  for id, job in pairs(M._active_jobs) do
    if job.bufnr == bufnr then buffer_jobs[#buffer_jobs + 1] = { id = id, job = job } end
  end

  if #buffer_jobs == 0 then
    vim.notify("[dwight] No active jobs here.", vim.log.levels.INFO)
    return
  end

  local nearest = buffer_jobs[1]
  local nearest_dist = math.huge
  for _, bj in ipairs(buffer_jobs) do
    local dist = math.min(math.abs(cursor_line - bj.job.start_line), math.abs(cursor_line - bj.job.end_line))
    if cursor_line >= bj.job.start_line and cursor_line <= bj.job.end_line then dist = 0 end
    if dist < nearest_dist then nearest_dist = dist; nearest = bj end
  end

  M._kill_job(nearest.id, nearest.job)
  vim.notify("[dwight] Job #" .. nearest.id .. " cancelled.", vim.log.levels.INFO)
end

function M.cancel_all()
  if vim.tbl_isempty(M._active_jobs) then
    vim.notify("[dwight] No active jobs.", vim.log.levels.INFO); return
  end
  local count = 0
  for id, job in pairs(M._active_jobs) do M._kill_job(id, job); count = count + 1 end
  vim.notify(string.format("[dwight] Cancelled %d job(s).", count), vim.log.levels.INFO)
end

function M._kill_job(id, job)
  if job.handle and not job.handle:is_closing() then job.handle:kill("sigterm") end
  require_mod("ui").clear_indicators(id)
  pcall(function() require_mod("log").finish(id, "cancelled", "", nil, "Cancelled") end)
  M._active_jobs[id] = nil
end

--------------------------------------------------------------------
-- Status
--------------------------------------------------------------------

function M.status()
  local tracker = require_mod("tracker")
  local project = require_mod("project")
  local runner  = require_mod("runner")
  local lines = {
    "Model: " .. tracker.get_model(),
    "Project: " .. (project.is_initialized() and "✅ " .. project.dir() or "❌ :DwightInit"),
    "Skills: " .. #require_mod("skills").list(),
    "Session: " .. tracker._session.invocations .. " invocations",
    "Logged: " .. #require_mod("log")._entries .. " jobs",
  }

  if runner._last_run then
    local r = runner._last_run
    local icon = r.exit_code == 0 and "✅" or "❌"
    lines[#lines + 1] = string.format("Last run: %s '%s' (exit %d)", icon, r.cmd, r.exit_code)
  end

  local job_count = 0
  for id, job in pairs(M._active_jobs) do
    job_count = job_count + 1
    local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(job.bufnr), ":t")
    lines[#lines + 1] = string.format("  #%d: %s %d-%d (%s, %ds)",
      id, name, job.start_line, job.end_line, job.mode, os.time() - (job.started or os.time()))
  end

  lines[#lines + 1] = job_count > 0 and (job_count .. " jobs running") or "No active jobs"
  vim.notify("[dwight]\n" .. table.concat(lines, "\n"), vim.log.levels.INFO)
end

return M
