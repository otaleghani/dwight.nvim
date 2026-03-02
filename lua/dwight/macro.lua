-- dwight/macro.lua
-- Handles /macro mode output: parses commands, stores in register,
-- shows a floating preview with execute keymaps.

local M = {}

local api = vim.api

--------------------------------------------------------------------
-- Parse macro output
--------------------------------------------------------------------

--- Strip fences and extract executable commands from AI output.
--- Returns { commands = { ":%s/...", ... }, raw = "full text with comments" }
function M.parse_output(raw)
  if not raw or raw == "" then return nil end

  -- Strip code fences if present
  local text = raw:gsub("```%w*%s*\n?", ""):gsub("\n?```", "")
  text = vim.trim(text)
  if text == "" then return nil end

  local commands = {}
  for line in text:gmatch("[^\n]+") do
    local trimmed = vim.trim(line)
    -- Skip comments and empty lines
    if trimmed ~= "" and not trimmed:match('^"') and not trimmed:match("^%-%-")
      and not trimmed:match("^#") and not trimmed:match("^//") then
      commands[#commands + 1] = trimmed
    end
  end

  return { commands = commands, raw = text }
end

--------------------------------------------------------------------
-- Show macro preview + store in register
--------------------------------------------------------------------

--- Handle /macro response: show in floating window, store in register 'd'.
--- Returns true if handled.
function M.handle_macro_response(raw_output, selection)
  local parsed = M.parse_output(raw_output)
  if not parsed or #parsed.commands == 0 then
    vim.notify("[dwight] 🎹 Macro: no executable commands found.", vim.log.levels.WARN)
    return true
  end

  -- Store commands in register 'd' (for dwight)
  local cmd_text = table.concat(parsed.commands, "\n")
  vim.fn.setreg("d", cmd_text)

  -- Also store as a sequence that can be replayed in normal mode
  -- For single commands, store without newlines for @d execution
  if #parsed.commands == 1 then
    vim.fn.setreg("d", parsed.commands[1] .. "\n")
  end

  -- Show in floating preview
  local lines = vim.split(parsed.raw, "\n", { plain = true })
  -- Add header and footer
  table.insert(lines, 1, "🎹 Macro commands (stored in register \"d\")")
  table.insert(lines, 2, string.rep("─", 50))
  lines[#lines + 1] = ""
  lines[#lines + 1] = string.rep("─", 50)
  lines[#lines + 1] = "<CR> execute all  |  y yank  |  1-9 execute Nth  |  q close"

  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "vim"

  local width = math.min(80, vim.o.columns - 10)
  local height = math.min(#lines + 2, vim.o.lines - 6)
  local win = api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width, height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = require("dwight").config.border,
    title = " dwight macro ", title_pos = "center",
  })

  -- Keymaps
  local function close()
    if api.nvim_win_is_valid(win) then api.nvim_win_close(win, true) end
  end

  -- q: close
  vim.keymap.set("n", "q", close, { buffer = buf, nowait = true })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, nowait = true })

  -- y: yank all commands to clipboard
  vim.keymap.set("n", "y", function()
    vim.fn.setreg("+", cmd_text)
    vim.notify("[dwight] 🎹 Commands copied to clipboard.", vim.log.levels.INFO)
    close()
  end, { buffer = buf, nowait = true })

  -- <CR>: execute all commands in order
  vim.keymap.set("n", "<CR>", function()
    close()
    vim.schedule(function()
      for _, cmd in ipairs(parsed.commands) do
        local ok, err = pcall(vim.cmd, cmd)
        if not ok then
          vim.notify("[dwight] 🎹 Error executing: " .. cmd .. "\n" .. tostring(err), vim.log.levels.ERROR)
          break
        end
      end
      vim.notify(string.format("[dwight] 🎹 Executed %d command(s).", #parsed.commands), vim.log.levels.INFO)
    end)
  end, { buffer = buf, nowait = true })

  -- 1-9: execute Nth command
  for i = 1, math.min(9, #parsed.commands) do
    vim.keymap.set("n", tostring(i), function()
      close()
      vim.schedule(function()
        local cmd = parsed.commands[i]
        local ok, err = pcall(vim.cmd, cmd)
        if ok then
          vim.notify("[dwight] 🎹 Executed: " .. cmd, vim.log.levels.INFO)
        else
          vim.notify("[dwight] 🎹 Error: " .. tostring(err), vim.log.levels.ERROR)
        end
      end)
    end, { buffer = buf, nowait = true })
  end

  vim.notify(string.format(
    "[dwight] 🎹 %d command(s) stored in register \"d\". Execute with @d or use the preview.",
    #parsed.commands
  ), vim.log.levels.INFO)

  return true
end

return M
