-- dwight/ui.lua
-- Floating prompt: a proper scratch buffer with static help below the divider.

local M = {}

local api = vim.api
local ns_hl = api.nvim_create_namespace("dwight_prompt_hl")

--------------------------------------------------------------------
-- Visual Selection
--------------------------------------------------------------------

function M.get_visual_selection()
  vim.cmd('noautocmd normal! "vy')
  local bufnr = api.nvim_get_current_buf()
  local start_pos = api.nvim_buf_get_mark(bufnr, "<")
  local end_pos   = api.nvim_buf_get_mark(bufnr, ">")
  if start_pos[1] == 0 and end_pos[1] == 0 then return nil end

  local start_line = start_pos[1]
  local end_line   = end_pos[1]
  local lines = api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
  if not lines or #lines == 0 then return nil end

  return {
    bufnr      = bufnr,
    start_line = start_line,
    end_line   = end_line,
    start_col  = start_pos[2],
    end_col    = end_pos[2],
    text       = table.concat(lines, "\n"),
    lines      = lines,
    filetype   = vim.bo[bufnr].filetype,
    filepath   = api.nvim_buf_get_name(bufnr),
  }
end

--------------------------------------------------------------------
-- Per-Job Processing Indicators
--------------------------------------------------------------------

M._job_indicators = {}
local spinner_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

function M.show_indicators(job_id, bufnr, start_line, end_line)
  if not api.nvim_buf_is_valid(bufnr) then return end
  local cfg = require("dwight").config
  local ns = api.nvim_create_namespace("dwight_job_" .. job_id)
  local sign_group = "dwight_job_" .. job_id
  local style = cfg.indicator_style

  if style == "sign" or style == "both" then
    for lnum = start_line, end_line do
      pcall(vim.fn.sign_place, 0, sign_group, "DwightProcessing", bufnr, { lnum = lnum })
    end
  end

  local frame = 1
  local timer = (vim.loop or vim.uv).new_timer()
  M._job_indicators[job_id] = {
    ns = ns, sign_group = sign_group, timer = timer,
    bufnr = bufnr, start_line = start_line, end_line = end_line,
  }

  timer:start(0, 120, vim.schedule_wrap(function()
    if not api.nvim_buf_is_valid(bufnr) then M.clear_indicators(job_id); return end
    api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    local ind = M._job_indicators[job_id]
    if not ind then return end
    local icon = spinner_frames[frame]
    local text = string.format(" %s #%d processing…", icon, job_id)
    for _, lnum in ipairs({ ind.start_line, ind.end_line }) do
      pcall(api.nvim_buf_set_extmark, bufnr, ns, lnum - 1, 0, {
        virt_text = { { text, "DwightProcessing" } }, virt_text_pos = "eol",
      })
    end
    frame = frame % #spinner_frames + 1
  end))
end

function M.clear_indicators(job_id)
  local ind = M._job_indicators[job_id]
  if not ind then return end
  pcall(function() ind.timer:stop(); ind.timer:close() end)
  if api.nvim_buf_is_valid(ind.bufnr) then
    api.nvim_buf_clear_namespace(ind.bufnr, ind.ns, 0, -1)
  end
  pcall(vim.fn.sign_unplace, ind.sign_group, { buffer = ind.bufnr })
  M._job_indicators[job_id] = nil
end

function M.update_indicator_range(job_id, new_start, new_end)
  local ind = M._job_indicators[job_id]
  if ind then ind.start_line = new_start; ind.end_line = new_end end
end

--------------------------------------------------------------------
-- Token Parsing (with #symbols)
--------------------------------------------------------------------

function M.parse_tokens(text)
  local skills = {}
  local symbols = {}
  local mode = nil

  for skill in text:gmatch("@([%w_%-%.]+)") do skills[#skills + 1] = skill end
  for sym in text:gmatch("#([%w_%-%.]+)") do symbols[#symbols + 1] = sym end
  mode = text:match("/(%w[%w_]*)")

  local clean = text
  clean = clean:gsub("@[%w_%-%.]+", "")
  clean = clean:gsub("#[%w_%-%.]+", "")
  clean = clean:gsub("/%w[%w_]*", "")
  clean = vim.trim(clean:gsub("%s+", " "))

  return { skills = skills, symbols = symbols, mode = mode, clean_text = clean }
end

--------------------------------------------------------------------
-- Prompt Highlighting
--------------------------------------------------------------------

local function highlight_prompt_buf(buf, editable_end)
  if not api.nvim_buf_is_valid(buf) then return end
  api.nvim_buf_clear_namespace(buf, ns_hl, 0, -1)

  local lines = api.nvim_buf_get_lines(buf, 0, editable_end, false)
  local skill_names = require("dwight.skills").names()
  local skill_set = {}
  for _, n in ipairs(skill_names) do skill_set[n] = true end
  local mode_names = require("dwight.modes").list()
  local mode_set = {}
  for _, n in ipairs(mode_names) do mode_set[n] = true end

  for i, line in ipairs(lines) do
    local row = i - 1
    local pos = 1
    while true do
      local s, e, name = line:find("@([%w_%-%.]+)", pos)
      if not s then break end
      local hl = skill_set[name] and "DwightSkill" or "DwightSkillInvalid"
      api.nvim_buf_add_highlight(buf, ns_hl, hl, row, s - 1, e)
      pos = e + 1
    end
    pos = 1
    while true do
      local s, e, name = line:find("/(%w[%w_]*)", pos)
      if not s then break end
      if mode_set[name] then
        api.nvim_buf_add_highlight(buf, ns_hl, "DwightMode", row, s - 1, e)
      end
      pos = e + 1
    end
    pos = 1
    while true do
      local s, e = line:find("#[%w_%-%.]+", pos)
      if not s then break end
      api.nvim_buf_add_highlight(buf, ns_hl, "DwightSymbol", row, s - 1, e)
      pos = e + 1
    end
  end
end

--------------------------------------------------------------------
-- Completion: omnifunc with noselect
--------------------------------------------------------------------

M._source_bufnr = nil

local function find_token_at_cursor()
  local line = api.nvim_get_current_line()
  local col = api.nvim_win_get_cursor(0)[2]
  local start = col
  while start > 0 do
    local c = line:sub(start, start)
    if c == "@" or c == "/" or c == "#" then
      return c, line:sub(start + 1, col), start
    end
    if not c:match("[%w_%-%.@/#]") then break end
    start = start - 1
  end
  return nil, "", col
end

function M.omnifunc(findstart, base)
  if findstart == 1 then
    local trigger, _, start_pos = find_token_at_cursor()
    if trigger then return start_pos - 1 end
    return -3
  end

  local items = {}
  local trigger = base:sub(1, 1)
  local typed = base:sub(2):lower()

  if trigger == "@" then
    for _, name in ipairs(require("dwight.skills").names()) do
      if typed == "" or name:lower():find(typed, 1, true) then
        items[#items + 1] = { word = "@" .. name, menu = "[skill]", icase = 1 }
      end
    end
  elseif trigger == "/" then
    local modes = require("dwight.modes")
    for _, name in ipairs(modes.list()) do
      if typed == "" or name:lower():find(typed, 1, true) then
        local m = modes.get(name)
        items[#items + 1] = { word = "/" .. name, menu = m.icon .. " " .. m.name, icase = 1 }
      end
    end
  elseif trigger == "#" then
    if #typed >= 1 then
      local ok, syms = pcall(function()
        return require("dwight.symbols").search(typed, 20, M._source_bufnr)
      end)
      if ok and syms then
        for _, s in ipairs(syms) do
          local file = vim.fn.fnamemodify(s.filepath, ":t")
          items[#items + 1] = {
            word = "#" .. s.name,
            menu = string.format("[%s] %s:%d", s.kind, file, s.line),
            icase = 1,
          }
        end
      end
    end
  end

  return items
end

--------------------------------------------------------------------
-- Floating Prompt Window
--------------------------------------------------------------------

--- The divider line index (0-based) — everything above is editable, at and below is read-only help.
local EDITABLE_LINES = 6

function M.open_prompt(selection, _preset_mode)
  local cfg = require("dwight").config
  M._source_bufnr = selection.bufnr

  local width = math.floor(vim.o.columns * 0.6)
  width = math.max(width, 55)
  local height = EDITABLE_LINES + 6  -- editable + divider + help lines

  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].filetype = "dwight_prompt"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].omnifunc = "v:lua.require'dwight.ui'.omnifunc"

  local file_info = string.format("%d lines · %s",
    selection.end_line - selection.start_line + 1,
    vim.fn.fnamemodify(selection.filepath or "", ":t"))

  -- Build buffer content: editable area + divider + static help
  local content = {}
  -- Editable lines (user types here)
  for _ = 1, EDITABLE_LINES do
    content[#content + 1] = ""
  end
  -- Divider (read-only below this)
  content[#content + 1] = "─── " .. file_info .. " ───"
  -- Static help
  content[#content + 1] = "  @skill    load coding guidelines"
  content[#content + 1] = "  /mode     refactor · fix · code · document · optimize …"
  content[#content + 1] = "  #symbol   include function/type from other files"
  content[#content + 1] = "  <CR> submit   <Esc> normal   q quit   <Tab> complete"
  content[#content + 1] = ""

  api.nvim_buf_set_lines(buf, 0, -1, false, content)

  local win = api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width, height = height,
    row = row, col = col,
    style = "minimal",
    border = cfg.border,
    title = " dwight ",
    title_pos = "center",
  })

  vim.wo[win].winhl      = "Normal:Normal,FloatBorder:DwightBorder,FloatTitle:DwightTitle"
  vim.wo[win].cursorline = false
  vim.wo[win].wrap       = true
  vim.wo[win].linebreak  = true

  -- Highlight the help area as comments (dimmed)
  local help_ns = api.nvim_create_namespace("dwight_help_hl")
  for i = EDITABLE_LINES, #content - 1 do
    api.nvim_buf_add_highlight(buf, help_ns, "Comment", i, 0, -1)
  end

  -- Protect help lines: prevent cursor from entering read-only zone
  api.nvim_create_autocmd("CursorMoved", {
    buffer = buf,
    callback = function()
      local cursor = api.nvim_win_get_cursor(win)
      if cursor[1] > EDITABLE_LINES then
        api.nvim_win_set_cursor(win, { EDITABLE_LINES, cursor[2] })
      end
    end,
  })
  api.nvim_create_autocmd("CursorMovedI", {
    buffer = buf,
    callback = function()
      local cursor = api.nvim_win_get_cursor(win)
      if cursor[1] > EDITABLE_LINES then
        api.nvim_win_set_cursor(win, { EDITABLE_LINES, cursor[2] })
      end
    end,
  })

  -- Set completeopt, restore on close
  local saved_completeopt = vim.o.completeopt
  vim.opt.completeopt = "menuone,noinsert,noselect"

  api.nvim_create_autocmd("BufWipeout", {
    buffer = buf, once = true,
    callback = function() vim.opt.completeopt = saved_completeopt end,
  })

  api.nvim_win_set_cursor(win, { 1, 0 })
  vim.cmd("startinsert")

  -- Live highlighting (only editable area)
  highlight_prompt_buf(buf, EDITABLE_LINES)
  api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
    buffer = buf,
    callback = function() highlight_prompt_buf(buf, EDITABLE_LINES) end,
  })

  -- Trigger omnifunc on @, /, #
  api.nvim_create_autocmd("InsertCharPre", {
    buffer = buf,
    callback = function()
      local char = vim.v.char
      if char == "@" or char == "/" or char == "#" then
        vim.schedule(function()
          if api.nvim_buf_is_valid(buf) and vim.fn.pumvisible() == 0 then
            vim.fn.feedkeys(api.nvim_replace_termcodes("<C-x><C-o>", true, false, true), "n")
          end
        end)
      end
    end,
  })

  -- Re-trigger as user types after trigger char
  api.nvim_create_autocmd("TextChangedI", {
    buffer = buf,
    callback = function()
      if vim.fn.pumvisible() == 1 then return end
      local trigger = find_token_at_cursor()
      if trigger then
        vim.schedule(function()
          if api.nvim_buf_is_valid(buf) then
            vim.fn.feedkeys(api.nvim_replace_termcodes("<C-x><C-o>", true, false, true), "n")
          end
        end)
      end
    end,
  })

  -- Tab / S-Tab
  vim.keymap.set("i", "<Tab>", function()
    if vim.fn.pumvisible() == 1 then
      return api.nvim_replace_termcodes("<C-n>", true, false, true)
    else
      return api.nvim_replace_termcodes("<C-x><C-o>", true, false, true)
    end
  end, { buffer = buf, expr = true })

  vim.keymap.set("i", "<S-Tab>", function()
    if vim.fn.pumvisible() == 1 then
      return api.nvim_replace_termcodes("<C-p>", true, false, true)
    end
    return ""
  end, { buffer = buf, expr = true })

  -- Enter: accept completion or submit
  vim.keymap.set("i", "<CR>", function()
    if vim.fn.pumvisible() == 1 then
      return api.nvim_replace_termcodes("<C-y>", true, false, true)
    end

    vim.schedule(function()
      -- Read only the editable lines
      local input_lines = api.nvim_buf_get_lines(buf, 0, EDITABLE_LINES, false)
      local raw_text = vim.trim(table.concat(input_lines, " "))

      if api.nvim_win_is_valid(win) then api.nvim_win_close(win, true) end

      if raw_text == "" then
        vim.notify("[dwight] Empty prompt.", vim.log.levels.INFO)
        return
      end

      local parsed = M.parse_tokens(raw_text)
      local skill_paths = require("dwight.skills").resolve_many(parsed.skills)
      local resolved_symbols = require("dwight.symbols").resolve_many(parsed.symbols)

      vim.schedule(function()
        if parsed.mode then
          local mode = require("dwight.modes").get(parsed.mode)
          if mode then
            local ctx = require("dwight.lsp").gather_context(selection)
            local prompt_text = require("dwight.prompt").build(
              mode, selection, ctx, parsed.clean_text, skill_paths, resolved_symbols)
            require("dwight.opencode").run(prompt_text, selection, cfg, parsed.mode)
          else
            vim.notify("[dwight] Unknown mode: /" .. parsed.mode, vim.log.levels.ERROR)
          end
        else
          local prompt_text = require("dwight.prompt").build_freeform(
            parsed.clean_text, selection, skill_paths, resolved_symbols)
          require("dwight.opencode").run(prompt_text, selection, cfg, "custom")
        end
      end)
    end)

    return ""
  end, { buffer = buf, expr = true })

  -- Esc: go to normal mode (so user can navigate, press q)
  vim.keymap.set("i", "<Esc>", function()
    if vim.fn.pumvisible() == 1 then
      return api.nvim_replace_termcodes("<C-e>", true, false, true)
    end
    vim.cmd("stopinsert")
    return ""
  end, { buffer = buf, expr = true })

  -- q: close (normal mode only)
  vim.keymap.set("n", "q", function()
    if api.nvim_win_is_valid(win) then api.nvim_win_close(win, true) end
  end, { buffer = buf, noremap = true, silent = true })

  -- i to re-enter insert (standard vim, but make sure cursor stays in editable zone)
  vim.keymap.set("n", "i", function()
    local cursor = api.nvim_win_get_cursor(win)
    if cursor[1] > EDITABLE_LINES then
      api.nvim_win_set_cursor(win, { EDITABLE_LINES, 0 })
    end
    vim.cmd("startinsert")
  end, { buffer = buf, noremap = true })
end

return M
