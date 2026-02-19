-- dwight/ui.lua
-- Minimal floating prompt with fuzzy inline completion for @skills /modes #symbols.
-- No header clutter. Press ? to toggle help. Just type and go.

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
-- Token Parsing (now with #symbols)
--------------------------------------------------------------------

function M.parse_tokens(text)
  local skills = {}
  local symbols = {}
  local mode = nil

  for skill in text:gmatch("@([%w_%-%.]+)") do
    skills[#skills + 1] = skill
  end
  for sym in text:gmatch("#([%w_%-%.]+)") do
    symbols[#symbols + 1] = sym
  end
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

local function highlight_prompt_buf(buf)
  if not api.nvim_buf_is_valid(buf) then return end
  api.nvim_buf_clear_namespace(buf, ns_hl, 0, -1)

  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  local skill_names = require("dwight.skills").names()
  local skill_set = {}
  for _, n in ipairs(skill_names) do skill_set[n] = true end

  local mode_names = require("dwight.modes").list()
  local mode_set = {}
  for _, n in ipairs(mode_names) do mode_set[n] = true end

  for i, line in ipairs(lines) do
    local row = i - 1
    -- @skill tokens
    local pos = 1
    while true do
      local s, e, name = line:find("@([%w_%-%.]+)", pos)
      if not s then break end
      local hl = skill_set[name] and "DwightSkill" or "DwightSkillInvalid"
      api.nvim_buf_add_highlight(buf, ns_hl, hl, row, s - 1, e)
      pos = e + 1
    end
    -- /mode tokens
    pos = 1
    while true do
      local s, e, name = line:find("/(%w[%w_]*)", pos)
      if not s then break end
      if mode_set[name] then
        api.nvim_buf_add_highlight(buf, ns_hl, "DwightMode", row, s - 1, e)
      end
      pos = e + 1
    end
    -- #symbol tokens
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
-- Fuzzy Completion Engine
--------------------------------------------------------------------

--- Build completion items matching a prefix with fuzzy logic.
---@param trigger string "@", "/", or "#"
---@param typed string What the user typed after the trigger
---@return table[] Completion items { word, menu, info }
local function get_completions(trigger, typed)
  local items = {}
  typed = typed:lower()

  if trigger == "@" then
    for _, name in ipairs(require("dwight.skills").names()) do
      if typed == "" or name:lower():find(typed, 1, true) then
        items[#items + 1] = { word = "@" .. name, menu = "[skill]" }
      end
    end
  elseif trigger == "/" then
    local modes = require("dwight.modes")
    for _, name in ipairs(modes.list()) do
      if typed == "" or name:lower():find(typed, 1, true) then
        local m = modes.get(name)
        items[#items + 1] = { word = "/" .. name, menu = m.icon .. " " .. m.name }
      end
    end
  elseif trigger == "#" then
    -- Workspace symbol search (debounced — only search if >= 2 chars)
    if #typed >= 2 then
      local syms = require("dwight.symbols").search(typed, 15)
      for _, s in ipairs(syms) do
        local file = vim.fn.fnamemodify(s.filepath, ":t")
        items[#items + 1] = {
          word = "#" .. s.name,
          menu = string.format("[%s] %s:%d", s.kind, file, s.line),
        }
      end
    end
  end

  return items
end

--- Find the current token being typed (the @/# /word under cursor).
---@param buf number
---@return string|nil trigger, string typed, number start_col
local function get_current_token(buf)
  local line = api.nvim_get_current_line()
  local col = api.nvim_win_get_cursor(0)[2]  -- 0-indexed byte position

  -- Walk backwards to find @, /, or #
  local start = col
  while start > 0 do
    local c = line:sub(start, start)
    if c == "@" or c == "/" or c == "#" then
      local trigger = c
      local typed = line:sub(start + 1, col)
      return trigger, typed, start - 1  -- start_col is 0-indexed
    end
    if not c:match("[%w_%-%.@/#]") then break end
    start = start - 1
  end

  return nil, "", col
end

--------------------------------------------------------------------
-- Manual Completion Popup (replaces broken omnifunc)
--------------------------------------------------------------------

local _completion_ns = api.nvim_create_namespace("dwight_completion")

local function show_completion_popup(buf, win)
  local trigger, typed, start_col = get_current_token(buf)
  if not trigger then return end

  local items = get_completions(trigger, typed)
  if #items == 0 then return end

  -- Use vim.fn.complete() which handles the popup natively
  -- The col argument is 1-indexed byte position of where the completed text starts
  vim.fn.complete(start_col + 1, vim.tbl_map(function(item)
    return {
      word = item.word,
      menu = item.menu or "",
      icase = 1,
    }
  end, items))
end

--------------------------------------------------------------------
-- Floating Prompt Window
--------------------------------------------------------------------

function M.open_prompt(selection, _preset_mode)
  local cfg = require("dwight").config

  local width = math.floor(vim.o.columns * 0.55)
  local height = 5  -- Minimal: just the input area
  width = math.max(width, 50)

  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].filetype = "dwight_prompt"
  vim.bo[buf].bufhidden = "wipe"

  local file_info = string.format("%d lines · %s",
    selection.end_line - selection.start_line + 1,
    vim.fn.fnamemodify(selection.filepath or "", ":t"))

  -- Minimal: just input lines, no header box
  local prefill = {
    "",
    "",
    "",
    "─── " .. file_info .. " ───",
    "",
  }

  api.nvim_buf_set_lines(buf, 0, -1, false, prefill)

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

  api.nvim_win_set_cursor(win, { 1, 0 })
  vim.cmd("startinsert")

  -- Live highlighting
  highlight_prompt_buf(buf)
  api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
    buffer = buf,
    callback = function() highlight_prompt_buf(buf) end,
  })

  -- Fuzzy completion: trigger on @, /, # and continue as user types
  api.nvim_create_autocmd("TextChangedI", {
    buffer = buf,
    callback = function()
      -- Only trigger if popup not already visible
      if vim.fn.pumvisible() == 1 then return end
      local trigger = get_current_token(buf)
      if trigger then
        vim.schedule(function()
          if api.nvim_buf_is_valid(buf) then
            show_completion_popup(buf, win)
          end
        end)
      end
    end,
  })

  -- Key: trigger completion on @, /, #
  api.nvim_create_autocmd("InsertCharPre", {
    buffer = buf,
    callback = function()
      local char = vim.v.char
      if char == "@" or char == "/" or char == "#" then
        vim.schedule(function()
          if api.nvim_buf_is_valid(buf) then
            show_completion_popup(buf, win)
          end
        end)
      end
    end,
  })

  local opts = { buffer = buf, noremap = true, silent = true }

  -- Tab: cycle completions or trigger
  vim.keymap.set("i", "<Tab>", function()
    if vim.fn.pumvisible() == 1 then
      return api.nvim_replace_termcodes("<C-n>", true, false, true)
    end
    show_completion_popup(buf, win)
    return ""
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
      local input_lines = api.nvim_buf_get_lines(buf, 0, 3, false)
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

  -- ? toggle help overlay
  local help_visible = false
  local help_ns = api.nvim_create_namespace("dwight_help")

  local function toggle_help()
    if help_visible then
      api.nvim_buf_clear_namespace(buf, help_ns, 0, -1)
      help_visible = false
    else
      local help_lines = {
        { { "  @skill ", "DwightSkill" }, { "load a skill  ", "Comment" } },
        { { "  /mode  ", "DwightMode" }, { "set operation  ", "Comment" } },
        { { "  #symbol", "DwightSymbol" }, { "include code   ", "Comment" } },
        { { "  <CR>   ", "Special" }, { "submit  ", "Comment" },
          { "  <Esc>/q ", "Special" }, { "cancel", "Comment" } },
      }
      -- Show as virtual lines at end of buffer
      local last_line = api.nvim_buf_line_count(buf) - 1
      for i, chunks in ipairs(help_lines) do
        pcall(api.nvim_buf_set_extmark, buf, help_ns, last_line, 0, {
          virt_lines = { chunks },
          virt_lines_above = false,
        })
        last_line = last_line  -- all append after last
      end
      help_visible = true
    end
  end

  vim.keymap.set("n", "?", toggle_help, opts)
  vim.keymap.set("i", "<C-?>", toggle_help, { buffer = buf })

  -- Escape / q to close
  vim.keymap.set("n", "<Esc>", function()
    if api.nvim_win_is_valid(win) then api.nvim_win_close(win, true) end
  end, opts)
  vim.keymap.set("n", "q", function()
    if api.nvim_win_is_valid(win) then api.nvim_win_close(win, true) end
  end, opts)
end

return M
