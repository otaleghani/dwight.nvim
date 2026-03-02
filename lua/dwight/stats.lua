-- dwight/stats.lua
-- Telemetry dashboard: usage over time, per-feature stats, success rates, export.
-- Reads from tracker (usage.json) and log entries for comprehensive analytics.
--
-- :DwightStats           — full dashboard in split buffer
-- :DwightStats export    — export to CSV/JSON
-- :DwightStats features  — feature-only view

local M = {}

local api = vim.api
local _flatten = require("dwight.util").flatten_lines

--------------------------------------------------------------------
-- Data collection: merge tracker + log data
--------------------------------------------------------------------

--- Collect comprehensive stats from all sources.
--- Returns { lifetime, session, daily, features, modes, models, log_summary }
function M.collect()
  local tracker = require("dwight.tracker")
  local data = tracker._read_data()
  local lt = data.lifetime or {}
  local session = tracker._session

  -- Per-feature from tracker data
  local features = {}
  if lt.by_feature then
    for name, stats in pairs(lt.by_feature) do
      features[#features + 1] = {
        name = name,
        invocations = stats.invocations or 0,
        cost = stats.cost or 0,
        success = stats.success or 0,
        failure = stats.failure or 0,
        chars_sent = stats.chars_sent or 0,
        chars_received = stats.chars_received or 0,
        duration = stats.duration or 0,
        first_seen = stats.first_seen,
        last_used = stats.last_used,
      }
    end
  end

  -- Enrich from log entries (in-memory only, current session)
  local log_ok, log = pcall(require, "dwight.log")
  local log_summary = { total = 0, success = 0, error = 0, parse_fail = 0, running = 0 }
  local log_modes = {}
  local log_features_from_mode = {}

  if log_ok and log._entries then
    for _, entry in ipairs(log._entries) do
      log_summary.total = log_summary.total + 1
      local s = entry.status or "unknown"
      if s == "success" then log_summary.success = log_summary.success + 1
      elseif s == "error" then log_summary.error = log_summary.error + 1
      elseif s == "parse_fail" then log_summary.parse_fail = log_summary.parse_fail + 1
      elseif s == "running" then log_summary.running = log_summary.running + 1
      end

      -- Track by mode from log
      local mode = entry.mode or "unknown"
      if not log_modes[mode] then
        log_modes[mode] = { total = 0, success = 0, failure = 0, total_duration = 0 }
      end
      log_modes[mode].total = log_modes[mode].total + 1
      if s == "success" then log_modes[mode].success = log_modes[mode].success + 1
      elseif s == "error" or s == "parse_fail" then log_modes[mode].failure = log_modes[mode].failure + 1
      end
      if entry.started and entry.finished then
        log_modes[mode].total_duration = log_modes[mode].total_duration + (entry.finished - entry.started)
      end

      -- Try to extract feature from mode (e.g. "docs:auth" → "auth", "feature:auth" → "auth")
      local feat_from_mode = mode:match(":([%w_%-]+)$")
      if feat_from_mode and feat_from_mode ~= "" then
        if not log_features_from_mode[feat_from_mode] then
          log_features_from_mode[feat_from_mode] = { invocations = 0, success = 0, failure = 0 }
        end
        log_features_from_mode[feat_from_mode].invocations = log_features_from_mode[feat_from_mode].invocations + 1
        if s == "success" then log_features_from_mode[feat_from_mode].success = log_features_from_mode[feat_from_mode].success + 1
        elseif s == "error" or s == "parse_fail" then log_features_from_mode[feat_from_mode].failure = log_features_from_mode[feat_from_mode].failure + 1
        end
      end
    end
  end

  -- Merge log feature data into features list
  local feature_set = {}
  for _, f in ipairs(features) do feature_set[f.name] = f end
  for name, stats in pairs(log_features_from_mode) do
    if not feature_set[name] then
      features[#features + 1] = {
        name = name,
        invocations = stats.invocations,
        cost = 0,
        success = stats.success,
        failure = stats.failure,
        chars_sent = 0, chars_received = 0, duration = 0,
      }
    end
  end

  -- Sort features by cost (most expensive first)
  table.sort(features, function(a, b) return a.cost > b.cost end)

  -- Daily trends (last 14 days)
  local daily = {}
  for day, cost in pairs(data.daily_cost or {}) do
    local invocations = (data.daily_invocations or {})[day] or 0
    local status = (data.daily_status or {})[day] or {}
    daily[#daily + 1] = {
      date = day,
      cost = cost,
      invocations = invocations,
      success = status.success or 0,
      failure = status.failure or 0,
    }
  end
  table.sort(daily, function(a, b) return a.date > b.date end)

  -- Modes from lifetime
  local modes = {}
  for mode, count in pairs(lt.by_mode or {}) do
    modes[#modes + 1] = { name = mode, count = count }
  end
  table.sort(modes, function(a, b) return a.count > b.count end)

  -- Models from lifetime
  local models = {}
  for model, stats in pairs(lt.by_model or {}) do
    models[#models + 1] = { model = model, stats = stats }
  end
  table.sort(models, function(a, b) return (a.stats.cost or 0) > (b.stats.cost or 0) end)

  return {
    lifetime = lt,
    session = session,
    daily = daily,
    features = features,
    modes = modes,
    models = models,
    log_summary = log_summary,
    log_modes = log_modes,
    data = data,  -- raw for export
  }
end

--------------------------------------------------------------------
-- Dashboard rendering
--------------------------------------------------------------------

local function bar(value, max_value, width)
  if max_value == 0 then return "" end
  local filled = math.min(width, math.floor(value / max_value * width))
  return string.rep("█", filled) .. string.rep("░", width - filled)
end

local function pct(n, total)
  if total == 0 then return "–" end
  return string.format("%.0f%%", n / total * 100)
end

--- Render the full dashboard.
function M.show(target)
  if target == "export" or target == "csv" or target == "json" then
    M.export(target)
    return
  end

  if target == "features" then
    M.show_features()
    return
  end

  local stats = M.collect()
  local tracker = require("dwight.tracker")
  local fmt_cost = tracker._fmt_cost
  local fmt_num = tracker._fmt_num
  local fmt_tkn = tracker._fmt_tkn

  local lt = stats.lifetime
  local s = stats.session
  local lines = {}

  -- Header
  lines[#lines + 1] = "╔══════════════════════════════════════════════════════════════════╗"
  lines[#lines + 1] = "║                    Dwight Telemetry Dashboard                    ║"
  lines[#lines + 1] = "╚══════════════════════════════════════════════════════════════════╝"
  lines[#lines + 1] = ""

  -- Overview cards
  local total_success = (lt.by_status or {}).success or 0
  local total_fail = ((lt.by_status or {}).error or 0) + ((lt.by_status or {}).parse_fail or 0)
  local total_tracked = total_success + total_fail
  local success_rate = total_tracked > 0 and (total_success / total_tracked * 100) or 0

  lines[#lines + 1] = "  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐"
  lines[#lines + 1] = string.format(
    "  │ %11s │  │ %11s │  │ %10s%% │  │ %11s │",
    fmt_num(lt.invocations or 0), fmt_cost(lt.cost or 0),
    string.format("%.0f", success_rate), fmt_tkn((lt.chars_sent or 0) + (lt.chars_received or 0)))
  lines[#lines + 1] = "  │ invocations │  │  total cost │  │success rate│  │total tokens│"
  lines[#lines + 1] = "  └─────────────┘  └─────────────┘  └─────────────┘  └─────────────┘"
  lines[#lines + 1] = ""

  -- Session summary
  lines[#lines + 1] = "── Session ─────────────────────────────────────────────────────────"
  local session_duration = os.time() - (s.started or os.time())
  local hours = math.floor(session_duration / 3600)
  local mins = math.floor((session_duration % 3600) / 60)
  lines[#lines + 1] = string.format(
    "  Duration: %dh %dm  |  Calls: %s  |  Cost: %s  |  Tokens: %s in / %s out",
    hours, mins, fmt_num(s.invocations), fmt_cost(s.cost or 0),
    fmt_tkn(s.chars_sent), fmt_tkn(s.chars_received))
  lines[#lines + 1] = ""

  -- Daily trend (last 14 days, sparkline-style)
  if #stats.daily > 0 then
    lines[#lines + 1] = "── Daily Trend (last 14 days) ──────────────────────────────────────"
    local max_cost = 0
    local max_inv = 0
    local show_days = math.min(14, #stats.daily)
    for i = 1, show_days do
      if stats.daily[i].cost > max_cost then max_cost = stats.daily[i].cost end
      if stats.daily[i].invocations > max_inv then max_inv = stats.daily[i].invocations end
    end

    lines[#lines + 1] = string.format("  %-12s %8s %6s %6s %5s  %-20s",
      "Date", "Cost", "Calls", "OK", "Fail", "")
    lines[#lines + 1] = "  " .. string.rep("─", 65)

    for i = 1, show_days do
      local d = stats.daily[i]
      local sr = d.success + d.failure > 0
        and string.format("%.0f%%", d.success / (d.success + d.failure) * 100) or "–"
      lines[#lines + 1] = string.format("  %-12s %8s %6s %6d %5d  %s  %s",
        d.date, fmt_cost(d.cost), fmt_num(d.invocations),
        d.success, d.failure,
        bar(d.cost, max_cost, 15), sr)
    end
    lines[#lines + 1] = ""
  end

  -- Feature breakdown
  if #stats.features > 0 then
    lines[#lines + 1] = "── Per-Feature Stats ───────────────────────────────────────────────"
    lines[#lines + 1] = string.format("  %-20s %6s %8s %6s %5s %8s %10s",
      "Feature", "Calls", "Cost", "OK", "Fail", "Rate", "Tokens")
    lines[#lines + 1] = "  " .. string.rep("─", 72)

    local max_feat_cost = 0
    for _, f in ipairs(stats.features) do
      if f.cost > max_feat_cost then max_feat_cost = f.cost end
    end

    for _, f in ipairs(stats.features) do
      local rate = f.success + f.failure > 0
        and string.format("%.0f%%", f.success / (f.success + f.failure) * 100) or "–"
      local tokens = fmt_tkn((f.chars_sent or 0) + (f.chars_received or 0))
      lines[#lines + 1] = string.format("  $%-19s %6s %8s %6d %5d %7s %10s  %s",
        f.name:sub(1, 19), fmt_num(f.invocations), fmt_cost(f.cost),
        f.success, f.failure, rate, tokens,
        bar(f.cost, max_feat_cost, 10))
    end
    lines[#lines + 1] = ""
  end

  -- Mode breakdown
  if #stats.modes > 0 then
    lines[#lines + 1] = "── By Mode ─────────────────────────────────────────────────────────"
    local max_mode = stats.modes[1] and stats.modes[1].count or 1
    local mode_lines = {}
    for _, m in ipairs(stats.modes) do
      mode_lines[#mode_lines + 1] = string.format("  %-20s %6s  %s",
        m.name, fmt_num(m.count), bar(m.count, max_mode, 25))
    end
    -- Show in two columns if many modes
    if #mode_lines > 10 then
      local half = math.ceil(#mode_lines / 2)
      for i = 1, half do
        local left = mode_lines[i] or ""
        local right = mode_lines[i + half] or ""
        lines[#lines + 1] = left .. string.rep(" ", math.max(1, 45 - #left)) .. right
      end
    else
      for _, ml in ipairs(mode_lines) do lines[#lines + 1] = ml end
    end
    lines[#lines + 1] = ""
  end

  -- Model breakdown (from log modes for session)
  if next(stats.log_modes) then
    lines[#lines + 1] = "── Session Log Summary ─────────────────────────────────────────────"
    local ls = stats.log_summary
    lines[#lines + 1] = string.format(
      "  Total: %d  |  ✅ %d success  |  ❌ %d error  |  ⚠️ %d parse_fail  |  🔄 %d running",
      ls.total, ls.success, ls.error, ls.parse_fail, ls.running)
    lines[#lines + 1] = ""

    -- Top modes by failure rate (session)
    local risky_modes = {}
    for mode, ms in pairs(stats.log_modes) do
      if ms.total >= 2 and ms.failure > 0 then
        risky_modes[#risky_modes + 1] = {
          mode = mode, total = ms.total, failure = ms.failure,
          rate = ms.failure / ms.total * 100,
          avg_dur = ms.total_duration > 0 and ms.total_duration / ms.total or 0,
        }
      end
    end
    if #risky_modes > 0 then
      table.sort(risky_modes, function(a, b) return a.rate > b.rate end)
      lines[#lines + 1] = "  ⚠️  Modes with failures this session:"
      for _, rm in ipairs(risky_modes) do
        lines[#lines + 1] = string.format("     %-25s %d/%d failed (%.0f%%)",
          rm.mode, rm.failure, rm.total, rm.rate)
      end
      lines[#lines + 1] = ""
    end
  end

  -- Time savings estimate
  local total_tokens = (lt.chars_sent or 0) + (lt.chars_received or 0)
  if total_tokens > 0 then
    lines[#lines + 1] = "── Estimated Impact ────────────────────────────────────────────────"
    -- Rough heuristic: 1 token ≈ 0.75 words, avg developer types 40 words/min,
    -- AI output that would take ~3x longer to write manually
    local words_generated = (lt.chars_received or 0) / 4 * 0.75
    local manual_minutes = words_generated / 40 * 3
    local manual_hours = manual_minutes / 60

    lines[#lines + 1] = string.format("  ~%.0f words of code/text generated", words_generated)
    lines[#lines + 1] = string.format("  ~%.1f hours of manual work saved (rough estimate)", manual_hours)
    lines[#lines + 1] = string.format("  Cost efficiency: %s per estimated hour saved",
      manual_hours > 0 and fmt_cost((lt.cost or 0) / manual_hours) or "–")
    lines[#lines + 1] = ""
  end

  -- Footer
  lines[#lines + 1] = "── Actions ─────────────────────────────────────────────────────────"
  lines[#lines + 1] = "  :DwightStats features    Per-feature detail"
  lines[#lines + 1] = "  :DwightStats export      Export to .dwight/stats-export.json"
  lines[#lines + 1] = "  :DwightStats csv         Export to .dwight/stats-export.csv"
  lines[#lines + 1] = "  :DwightUsage             Model pricing & cost breakdown"
  lines[#lines + 1] = ""
  lines[#lines + 1] = "  Press 'e' to export JSON  |  'c' to export CSV  |  'q' to close"

  -- Display in split buffer
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, _flatten(lines))
  vim.bo[buf].modifiable = false
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "dwight_stats"

  -- Syntax highlights
  pcall(function()
    api.nvim_buf_call(buf, function()
      vim.cmd([[
        syntax match DwightStatsHeader /^[╔╚║].*$/
        syntax match DwightStatsSection /^──.*──$/
        syntax match DwightStatsSep /^  ─\+$/
        syntax match DwightStatsBar /[█░]\+/
        syntax match DwightStatsCost /\$[0-9,.]\+/
        syntax match DwightStatsFeature /\$[a-z][a-z0-9_-]*/
        syntax match DwightStatsSuccess /✅/
        syntax match DwightStatsError /❌/
        syntax match DwightStatsWarn /⚠️/
        syntax match DwightStatsBox /[┌┐└┘│─]/
      ]])
    end)
  end)

  local hl = api.nvim_set_hl
  hl(0, "DwightStatsHeader",  { fg = "#bb9af7", bold = true, default = true })
  hl(0, "DwightStatsSection", { fg = "#7aa2f7", bold = true, default = true })
  hl(0, "DwightStatsSep",     { fg = "#565f89", default = true })
  hl(0, "DwightStatsBar",     { fg = "#9ece6a", default = true })
  hl(0, "DwightStatsCost",    { fg = "#e0af68", default = true })
  hl(0, "DwightStatsFeature", { fg = "#7dcfff", default = true })
  hl(0, "DwightStatsBox",     { fg = "#565f89", default = true })

  vim.cmd("botright split")
  local win = api.nvim_get_current_win()
  api.nvim_win_set_buf(win, buf)
  api.nvim_win_set_height(win, math.min(#lines + 2, math.floor(vim.o.lines * 0.6)))

  -- Keymaps
  local function close()
    pcall(api.nvim_win_close, win, true)
  end

  vim.keymap.set("n", "q", close, { buffer = buf, desc = "Close" })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, desc = "Close" })
  vim.keymap.set("n", "e", function()
    close()
    M.export("json")
  end, { buffer = buf, desc = "Export JSON" })
  vim.keymap.set("n", "c", function()
    close()
    M.export("csv")
  end, { buffer = buf, desc = "Export CSV" })
end

--------------------------------------------------------------------
-- Feature detail view
--------------------------------------------------------------------

function M.show_features()
  local stats = M.collect()
  local tracker = require("dwight.tracker")
  local fmt_cost = tracker._fmt_cost
  local fmt_num = tracker._fmt_num
  local fmt_tkn = tracker._fmt_tkn

  if #stats.features == 0 then
    vim.notify("[dwight] No per-feature data yet. Use :DwightIssue or agent commands to generate data.", vim.log.levels.INFO)
    return
  end

  local lines = {
    "╔══════════════════════════════════════════════════════════════════╗",
    "║                     Feature Telemetry                           ║",
    "╚══════════════════════════════════════════════════════════════════╝",
    "",
  }

  -- Sort options
  local by_cost = vim.deepcopy(stats.features)
  table.sort(by_cost, function(a, b) return a.cost > b.cost end)

  local by_calls = vim.deepcopy(stats.features)
  table.sort(by_calls, function(a, b) return a.invocations > b.invocations end)

  -- Most expensive features
  lines[#lines + 1] = "── By Cost (most expensive) ────────────────────────────────────────"
  for i, f in ipairs(by_cost) do
    if i > 10 then break end
    local rate = f.success + f.failure > 0
      and string.format("%.0f%%", f.success / (f.success + f.failure) * 100) or "–"
    lines[#lines + 1] = string.format("  %2d. $%-18s %8s  %5s calls  %5s success  %s tokens",
      i, f.name:sub(1, 18), fmt_cost(f.cost), fmt_num(f.invocations), rate,
      fmt_tkn((f.chars_sent or 0) + (f.chars_received or 0)))
    if f.first_seen or f.last_used then
      lines[#lines + 1] = string.format("      First: %s  |  Last: %s",
        f.first_seen or "–", f.last_used or "–")
    end
  end
  lines[#lines + 1] = ""

  -- Most active features
  lines[#lines + 1] = "── By Activity (most calls) ────────────────────────────────────────"
  for i, f in ipairs(by_calls) do
    if i > 10 then break end
    local max_calls = by_calls[1].invocations
    lines[#lines + 1] = string.format("  %2d. $%-18s %5s calls  %8s  %s",
      i, f.name:sub(1, 18), fmt_num(f.invocations), fmt_cost(f.cost),
      bar(f.invocations, max_calls, 20))
  end
  lines[#lines + 1] = ""

  -- Features with low success rates
  local risky = {}
  for _, f in ipairs(stats.features) do
    local total = f.success + f.failure
    if total >= 3 then
      local rate = f.success / total * 100
      if rate < 80 then
        risky[#risky + 1] = { name = f.name, rate = rate, total = total, failure = f.failure }
      end
    end
  end
  if #risky > 0 then
    table.sort(risky, function(a, b) return a.rate < b.rate end)
    lines[#lines + 1] = "── ⚠️ Features with Low Success Rate (<80%) ────────────────────────"
    for _, r in ipairs(risky) do
      lines[#lines + 1] = string.format("  $%-20s %.0f%% success (%d failures / %d total)",
        r.name, r.rate, r.failure, r.total)
    end
    lines[#lines + 1] = ""
  end

  -- Summary
  local total_cost = 0
  local total_calls = 0
  for _, f in ipairs(stats.features) do
    total_cost = total_cost + f.cost
    total_calls = total_calls + f.invocations
  end
  lines[#lines + 1] = string.format("  Total: %d features  |  %s calls  |  %s cost",
    #stats.features, fmt_num(total_calls), fmt_cost(total_cost))

  -- Display
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, _flatten(lines))
  vim.bo[buf].modifiable = false
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"

  vim.cmd("botright split")
  local win = api.nvim_get_current_win()
  api.nvim_win_set_buf(win, buf)
  api.nvim_win_set_height(win, math.min(#lines + 2, math.floor(vim.o.lines * 0.5)))

  vim.keymap.set("n", "q", function()
    pcall(api.nvim_win_close, win, true)
  end, { buffer = buf })
end

--------------------------------------------------------------------
-- Export
--------------------------------------------------------------------

--- Export stats to JSON or CSV.
function M.export(format)
  format = format or "json"
  local stats = M.collect()
  local project = require("dwight.project")

  if not project.is_initialized() then
    vim.notify("[dwight] Run :DwightInit first.", vim.log.levels.WARN)
    return
  end

  local export_dir = project.dir()
  local timestamp = os.date("%Y%m%d-%H%M%S")

  if format == "json" then
    local path = export_dir .. "/stats-export.json"
    local export_data = {
      exported_at = os.date("%Y-%m-%dT%H:%M:%S"),
      project = vim.fn.getcwd():match("([^/]+)$") or "unknown",
      summary = {
        total_invocations = (stats.lifetime.invocations or 0),
        total_cost = stats.lifetime.cost or 0,
        total_tokens_in = math.floor((stats.lifetime.chars_sent or 0) / 4),
        total_tokens_out = math.floor((stats.lifetime.chars_received or 0) / 4),
        success_count = (stats.lifetime.by_status or {}).success or 0,
        failure_count = ((stats.lifetime.by_status or {}).error or 0) +
                       ((stats.lifetime.by_status or {}).parse_fail or 0),
      },
      features = {},
      daily = {},
      modes = {},
      models = {},
    }

    for _, f in ipairs(stats.features) do
      export_data.features[#export_data.features + 1] = {
        name = f.name,
        invocations = f.invocations,
        cost = f.cost,
        success = f.success,
        failure = f.failure,
        success_rate = f.success + f.failure > 0
          and (f.success / (f.success + f.failure) * 100) or nil,
        tokens_in = math.floor((f.chars_sent or 0) / 4),
        tokens_out = math.floor((f.chars_received or 0) / 4),
        first_seen = f.first_seen,
        last_used = f.last_used,
      }
    end

    for _, d in ipairs(stats.daily) do
      export_data.daily[#export_data.daily + 1] = {
        date = d.date,
        cost = d.cost,
        invocations = d.invocations,
        success = d.success,
        failure = d.failure,
      }
    end

    for _, m in ipairs(stats.modes) do
      export_data.modes[#export_data.modes + 1] = { mode = m.name, count = m.count }
    end

    for _, m in ipairs(stats.models) do
      export_data.models[#export_data.models + 1] = {
        model = m.model,
        invocations = m.stats.invocations,
        cost = m.stats.cost,
        tokens_in = math.floor((m.stats.chars_sent or 0) / 4),
        tokens_out = math.floor((m.stats.chars_received or 0) / 4),
      }
    end

    local ok, json = pcall(vim.json.encode, export_data)
    if ok then
      -- Pretty-print (basic indentation)
      json = json:gsub("{", "{\n  "):gsub("}", "\n}"):gsub(",", ",\n  ")
      local f = io.open(path, "w")
      if f then
        f:write(json .. "\n"); f:close()
        vim.notify("[dwight] ✅ Exported stats to " .. path, vim.log.levels.INFO)
        vim.cmd("edit " .. vim.fn.fnameescape(path))
      end
    end

  elseif format == "csv" then
    -- Export multiple CSV files
    local files_written = {}

    -- Daily CSV
    local daily_path = export_dir .. "/stats-daily.csv"
    local f = io.open(daily_path, "w")
    if f then
      f:write("date,cost,invocations,success,failure,success_rate\n")
      for _, d in ipairs(stats.daily) do
        local rate = d.success + d.failure > 0
          and string.format("%.1f", d.success / (d.success + d.failure) * 100) or ""
        f:write(string.format("%s,%.4f,%d,%d,%d,%s\n",
          d.date, d.cost, d.invocations, d.success, d.failure, rate))
      end
      f:close()
      files_written[#files_written + 1] = daily_path
    end

    -- Features CSV
    local feat_path = export_dir .. "/stats-features.csv"
    f = io.open(feat_path, "w")
    if f then
      f:write("feature,invocations,cost,success,failure,success_rate,tokens_in,tokens_out,first_seen,last_used\n")
      for _, feat in ipairs(stats.features) do
        local rate = feat.success + feat.failure > 0
          and string.format("%.1f", feat.success / (feat.success + feat.failure) * 100) or ""
        f:write(string.format("%s,%d,%.4f,%d,%d,%s,%d,%d,%s,%s\n",
          feat.name, feat.invocations, feat.cost, feat.success, feat.failure, rate,
          math.floor((feat.chars_sent or 0) / 4), math.floor((feat.chars_received or 0) / 4),
          feat.first_seen or "", feat.last_used or ""))
      end
      f:close()
      files_written[#files_written + 1] = feat_path
    end

    -- Modes CSV
    local mode_path = export_dir .. "/stats-modes.csv"
    f = io.open(mode_path, "w")
    if f then
      f:write("mode,count\n")
      for _, m in ipairs(stats.modes) do
        f:write(string.format("%s,%d\n", m.name, m.count))
      end
      f:close()
      files_written[#files_written + 1] = mode_path
    end

    if #files_written > 0 then
      vim.notify(string.format("[dwight] ✅ Exported %d CSV files to %s/\n  %s",
        #files_written, export_dir:match("[^/]+$"),
        table.concat(vim.tbl_map(function(p) return p:match("[^/]+$") end, files_written), ", ")),
        vim.log.levels.INFO)
    end
  end
end

return M
