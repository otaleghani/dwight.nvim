-- dwight/tracker.lua
-- Tracks usage statistics: invocation count, characters sent/received,
-- per-mode breakdown, and model info.
-- Data persists in .dwight/usage.json per project.

local M = {}

--------------------------------------------------------------------
-- State
--------------------------------------------------------------------

M._session = {
  invocations = 0,
  chars_sent = 0,
  chars_received = 0,
  by_mode = {},
  model = nil,
  started = os.time(),
}

--------------------------------------------------------------------
-- Persistence
--------------------------------------------------------------------

local function tracker_path()
  local project = require("dwight.project")
  return project.tracker_file()
end

local function read_data()
  local path = tracker_path()
  local f = io.open(path, "r")
  if not f then return { lifetime = { invocations = 0, chars_sent = 0, chars_received = 0, by_mode = {} } } end
  local raw = f:read("*a")
  f:close()
  local ok, data = pcall(vim.fn.json_decode, raw)
  if ok and data then return data end
  return { lifetime = { invocations = 0, chars_sent = 0, chars_received = 0, by_mode = {} } }
end

local function write_data(data)
  local path = tracker_path()
  -- Only write if project is initialized
  local project = require("dwight.project")
  if not project.is_initialized() then return end

  local f = io.open(path, "w")
  if not f then return end
  local ok, json = pcall(vim.fn.json_encode, data)
  if ok then f:write(json) end
  f:close()
end

--------------------------------------------------------------------
-- Recording
--------------------------------------------------------------------

--- Record an invocation.
---@param mode_name string Mode that was used
---@param chars_sent number Characters in the prompt
---@param chars_received number Characters in the response
function M.record(mode_name, chars_sent, chars_received)
  -- Session stats
  M._session.invocations = M._session.invocations + 1
  M._session.chars_sent = M._session.chars_sent + chars_sent
  M._session.chars_received = M._session.chars_received + chars_received
  M._session.by_mode[mode_name] = (M._session.by_mode[mode_name] or 0) + 1

  -- Persist to lifetime stats
  local data = read_data()
  local lt = data.lifetime
  lt.invocations = lt.invocations + 1
  lt.chars_sent = lt.chars_sent + chars_sent
  lt.chars_received = lt.chars_received + chars_received
  lt.by_mode[mode_name] = (lt.by_mode[mode_name] or 0) + 1
  data.last_used = os.date("%Y-%m-%d %H:%M:%S")
  write_data(data)
end

--- Set the current model name.
---@param model string
function M.set_model(model)
  M._session.model = model
end

--- Get the current model name.
---@return string
function M.get_model()
  local cfg = require("dwight").config
  return M._session.model or cfg.model or "(opencode default)"
end

--------------------------------------------------------------------
-- Display
--------------------------------------------------------------------

--- Format a character count as approximate tokens (1 token ≈ 4 chars).
local function chars_to_tokens(chars)
  return math.floor(chars / 4)
end

--- Format a number with commas.
local function fmt_num(n)
  local s = tostring(math.floor(n))
  local result = ""
  local len = #s
  for i = 1, len do
    if i > 1 and (len - i + 1) % 3 == 0 then
      result = result .. ","
    end
    result = result .. s:sub(i, i)
  end
  return result
end

--- Show usage statistics in a floating window.
function M.show()
  local data = read_data()
  local lt = data.lifetime
  local s = M._session

  local lines = {
    "╔══════════════════════════════════════╗",
    "║         Dwight Usage Stats          ║",
    "╚══════════════════════════════════════╝",
    "",
    "🔧 Model: " .. M.get_model(),
    "",
    "── This Session ──",
    string.format("  Invocations:    %s", fmt_num(s.invocations)),
    string.format("  Tokens sent:    ~%s", fmt_num(chars_to_tokens(s.chars_sent))),
    string.format("  Tokens received:~%s", fmt_num(chars_to_tokens(s.chars_received))),
    "",
    "── Lifetime (this project) ──",
    string.format("  Invocations:    %s", fmt_num(lt.invocations)),
    string.format("  Tokens sent:    ~%s", fmt_num(chars_to_tokens(lt.chars_sent))),
    string.format("  Tokens received:~%s", fmt_num(chars_to_tokens(lt.chars_received))),
  }

  -- Per-mode breakdown
  if not vim.tbl_isempty(lt.by_mode) then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "── By Mode (lifetime) ──"
    local sorted = {}
    for k, v in pairs(lt.by_mode) do
      sorted[#sorted + 1] = { k, v }
    end
    table.sort(sorted, function(a, b) return a[2] > b[2] end)
    for _, pair in ipairs(sorted) do
      lines[#lines + 1] = string.format("  %-16s %s", pair[1], fmt_num(pair[2]))
    end
  end

  if data.last_used then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Last used: " .. data.last_used
  end

  -- Show in floating window
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"

  local width = 42
  local height = #lines
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = require("dwight").config.border,
    title = " 📊 Usage ",
    title_pos = "center",
  })

  vim.wo[win].winhl = "Normal:Normal,FloatBorder:DwightBorder,FloatTitle:DwightTitle"

  -- Close on any key
  vim.keymap.set("n", "q", function() vim.api.nvim_win_close(win, true) end, { buffer = buf })
  vim.keymap.set("n", "<Esc>", function() vim.api.nvim_win_close(win, true) end, { buffer = buf })
end

return M
