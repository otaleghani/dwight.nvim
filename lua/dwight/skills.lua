-- dwight/skills.lua
-- Project-scoped skill management with logged AI generation.

local M = {}

local uv = vim.loop or vim.uv

local function skills_dir()
  return require("dwight.project").skills_dir()
end

--------------------------------------------------------------------
-- List / Resolve
--------------------------------------------------------------------

function M.list()
  local dir = skills_dir()
  local skills = {}
  if vim.fn.isdirectory(dir) ~= 1 then return skills end
  local handle = uv.fs_scandir(dir)
  if not handle then return skills end
  while true do
    local name, ftype = uv.fs_scandir_next(handle)
    if not name then break end
    if ftype == "file" and name:match("%.md$") then
      skills[#skills + 1] = { name = name:gsub("%.md$", ""), path = dir .. "/" .. name }
    end
  end
  table.sort(skills, function(a, b) return a.name < b.name end)
  return skills
end

function M.names()
  local r = {}
  for _, s in ipairs(M.list()) do r[#r + 1] = s.name end
  return r
end

function M.resolve(name)
  local path = skills_dir() .. "/" .. name .. ".md"
  if vim.fn.filereadable(path) == 1 then return path end
  return nil
end

function M.read(name)
  local path = M.resolve(name)
  if not path then return nil end
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*a"); f:close()
  return content
end

function M.resolve_many(names)
  local paths = {}
  for _, name in ipairs(names) do
    local path = M.resolve(name)
    if path then paths[#paths + 1] = path
    else vim.notify("[dwight] Skill '@" .. name .. "' not found.", vim.log.levels.WARN) end
  end
  return paths
end

--------------------------------------------------------------------
-- Picker
--------------------------------------------------------------------

function M.pick()
  local skills = M.list()
  if #skills == 0 then
    vim.notify("[dwight] No skills. Use :DwightGenSkill or :DwightDocs.", vim.log.levels.INFO)
    return
  end
  local has_telescope = pcall(require, "telescope")
  if has_telescope then M._pick_telescope(skills) else M._pick_native(skills) end
end

function M._pick_native(skills)
  local items = {}
  for _, s in ipairs(skills) do items[#items + 1] = "@" .. s.name end
  vim.ui.select(items, { prompt = "Skills:" }, function(choice)
    if choice then
      vim.cmd("edit " .. vim.fn.fnameescape(skills_dir() .. "/" .. choice:sub(2) .. ".md"))
    end
  end)
end

function M._pick_telescope(skills)
  local pickers    = require("telescope.pickers")
  local finders    = require("telescope.finders")
  local conf       = require("telescope.config").values
  local actions    = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local previewers = require("telescope.previewers")

  pickers.new({}, {
    prompt_title = "🔧 Skills",
    finder = finders.new_table({
      results = skills,
      entry_maker = function(skill)
        return { value = skill, display = "@" .. skill.name, ordinal = skill.name, path = skill.path }
      end,
    }),
    sorter = conf.generic_sorter({}),
    previewer = previewers.new_buffer_previewer({
      define_preview = function(self, entry)
        local ok, lines = pcall(function()
          local f = io.open(entry.value.path, "r")
          if not f then return {} end
          local c = f:read("*a"); f:close()
          return vim.split(c, "\n")
        end)
        if ok and lines then
          vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
          vim.bo[self.state.bufnr].filetype = "markdown"
        end
      end,
    }),
    attach_mappings = function(prompt_bufnr)
      actions.select_default:replace(function()
        local entry = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if entry then vim.cmd("edit " .. vim.fn.fnameescape(entry.value.path)) end
      end)
      return true
    end,
  }):find()
end

--------------------------------------------------------------------
-- Generate (AI, logged)
--------------------------------------------------------------------

function M.generate()
  local cfg = require("dwight").config
  local project = require("dwight.project")
  local log = require("dwight.log")

  if not project.is_initialized() then
    vim.notify("[dwight] Run :DwightInit first.", vim.log.levels.WARN)
    return
  end

  vim.ui.input({ prompt = "Skill name (e.g., 'react-hooks'): " }, function(name)
    if not name or name == "" then return end
    name = name:gsub("[^%w%-_]", "-"):lower()

    vim.ui.input({ prompt = "What should this skill cover? " }, function(desc)
      if not desc or desc == "" then return end

      vim.ui.input({ prompt = "Specific rules? (optional, Enter to skip): " }, function(patterns)
        patterns = patterns or ""
        local output_path = project.skills_dir() .. "/" .. name .. ".md"

        local prompt = string.format([[
Generate a coding skill guide called "%s".
Description: %s
%s

Practical markdown with:
- Brief overview (2-3 sentences)
- Numbered guidelines (specific, actionable)
- Code pattern examples (good patterns)
- Anti-patterns to avoid (with explanation)
- Style rules

Under 150 lines. Focus on what an AI assistant needs to produce correct code.
Reply with ONLY markdown inside a fenced code block.
]], name, desc, patterns ~= "" and ("Additional: " .. patterns) or "")

        vim.notify("[dwight] Generating skill '@" .. name .. "'…", vim.log.levels.INFO)

        local job_id = log._next_id()
        log.start(job_id, "gen-skill:" .. name, vim.api.nvim_get_current_buf(), 0, 0, prompt)

        M._run_opencode(prompt, function(raw, code)
          if code ~= 0 or vim.trim(raw) == "" then
            log.finish(job_id, "error", raw, nil, "Generation failed")
            M._write_template(output_path, name, desc, patterns)
            return
          end

          local blocks = {}
          for block in raw:gmatch("```%w*\n(.-)\n```") do blocks[#blocks + 1] = block end
          local content
          if #blocks > 0 then
            content = blocks[1]
            for i = 2, #blocks do if #blocks[i] > #content then content = blocks[i] end end
          else
            content = raw:gsub("^[^\n]*[Hh]ere.-\n", "")
          end

          local out = io.open(output_path, "w")
          if out then
            out:write(content); out:close()
            log.finish(job_id, "success", raw, content, nil)
            vim.notify("✅ [dwight] Skill '@" .. name .. "' created!", vim.log.levels.INFO)
            vim.cmd("edit " .. vim.fn.fnameescape(output_path))
          else
            log.finish(job_id, "error", raw, nil, "Failed to write file")
          end
        end)
      end)
    end)
  end)
end

--- Shared helper to run opencode and return output.
function M._run_opencode(prompt, callback)
  local cfg = require("dwight").config

  local tmpfile = vim.fn.tempname() .. "_dwight_prompt.md"
  local f = io.open(tmpfile, "w")
  if not f then callback("", 1); return end
  f:write(prompt); f:close()

  local wrapper = vim.fn.tempname() .. "_dwight_run.sh"
  local wf = io.open(wrapper, "w")
  if not wf then os.remove(tmpfile); callback("", 1); return end
  wf:write("#!/bin/sh\n")
  wf:write(string.format('%s run "$(cat %s)"\n', cfg.opencode_bin, tmpfile))
  wf:close()
  os.execute("chmod +x " .. vim.fn.shellescape(wrapper))

  local stdout_chunks = {}
  local stdout = uv.new_pipe(false)
  local stderr = uv.new_pipe(false)

  local handle
  handle = uv.spawn("sh", {
    args = { wrapper }, stdio = { nil, stdout, stderr }, cwd = vim.fn.getcwd(),
  }, function(code)
    if stdout then stdout:close() end
    if stderr then stderr:close() end
    if handle then handle:close() end
    pcall(os.remove, tmpfile)
    pcall(os.remove, wrapper)
    vim.schedule(function()
      callback(table.concat(stdout_chunks, ""), code)
    end)
  end)

  if not handle then
    pcall(os.remove, tmpfile); pcall(os.remove, wrapper)
    callback("", 1)
    return
  end

  stdout:read_start(function(err, data) if not err and data then stdout_chunks[#stdout_chunks + 1] = data end end)
  stderr:read_start(function() end)
end

function M._write_template(path, name, desc, patterns)
  local title = name:gsub("-", " "):gsub("(%a)([%w_']*)", function(a, b) return a:upper() .. b end)
  local f = io.open(path, "w")
  if f then
    f:write(string.format("# %s\n\n## Overview\n%s\n\n## Guidelines\n1. \n\n## Patterns\n```\n```\n\n## Anti-Patterns\n```\n```\n%s\n",
      title, desc, patterns ~= "" and ("\n## Notes\n" .. patterns) or ""))
    f:close()
    vim.notify("[dwight] Template '@" .. name .. "' created.", vim.log.levels.INFO)
    vim.cmd("edit " .. vim.fn.fnameescape(path))
  end
end

return M
