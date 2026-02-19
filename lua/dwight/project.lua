-- dwight/project.lua
-- Project initialization with AI-assisted scope generation.
-- :DwightInit asks user for a description, then AI generates project.md.

local M = {}

local uv = vim.loop or vim.uv

--------------------------------------------------------------------
-- Paths
--------------------------------------------------------------------

function M.root()
  return vim.fn.getcwd()
end

function M.dir()
  return M.root() .. "/.dwight"
end

function M.skills_dir()
  return M.dir() .. "/skills"
end

function M.project_file()
  return M.dir() .. "/project.md"
end

function M.tracker_file()
  return M.dir() .. "/usage.json"
end

function M.builtin_dir()
  local info = debug.getinfo(1, "S")
  if info and info.source then
    local path = info.source:gsub("^@", "")
    local dir = vim.fn.fnamemodify(path, ":h")
    return dir .. "/builtin"
  end
  return nil
end

function M.is_initialized()
  return vim.fn.isdirectory(M.dir()) == 1
    and vim.fn.filereadable(M.project_file()) == 1
end

--------------------------------------------------------------------
-- Init (AI-assisted)
--------------------------------------------------------------------

function M.init()
  if M.is_initialized() then
    vim.notify("[dwight] Already initialized. Opening project.md.", vim.log.levels.INFO)
    vim.cmd("edit " .. vim.fn.fnameescape(M.project_file()))
    return
  end

  vim.ui.input({ prompt = "Describe your project (tech stack, purpose, etc.): " }, function(desc)
    if not desc or desc == "" then
      -- Fall back to template if user cancels
      M._init_with_template()
      return
    end

    -- Create directory structure first
    vim.fn.mkdir(M.skills_dir(), "p")
    M._create_gitignore()

    -- Try AI generation
    vim.notify("[dwight] Generating project scope…", vim.log.levels.INFO)
    M._generate_scope(desc)
  end)
end

function M._generate_scope(description)
  local cfg = require("dwight").config
  local log = require("dwight.log")

  local prompt = string.format([[
Generate a project scope document for an AI coding assistant. The developer described their project as:

"%s"

Also, here are some files in the project root that might help you understand the stack:
%s

Create a practical markdown document with these sections:
- ## What This Project Does (2-3 sentences)
- ## Tech Stack (list the key technologies, frameworks, versions)
- ## Architecture (brief overview of how the code is organized)
- ## Conventions (coding style, naming, patterns the team follows)
- ## Important Constraints (things the AI should never do or always do)
- ## Directory Structure Notes (what lives where)

Be specific and actionable. This document will be read by an AI to produce better code.
Keep it under 80 lines. Reply with ONLY the markdown inside a fenced code block.
]], description, M._scan_project_hints())

  local tmpfile = vim.fn.tempname() .. "_init_prompt.md"
  local f = io.open(tmpfile, "w")
  if not f then M._init_with_content("# Project Scope\n\n" .. description); return end
  f:write(prompt)
  f:close()

  local wrapper = vim.fn.tempname() .. "_init_run.sh"
  local wf = io.open(wrapper, "w")
  if not wf then os.remove(tmpfile); M._init_with_content("# Project Scope\n\n" .. description); return end
  wf:write("#!/bin/sh\n")
  wf:write(string.format('%s run "$(cat %s)"\n', cfg.opencode_bin, tmpfile))
  wf:close()
  os.execute("chmod +x " .. vim.fn.shellescape(wrapper))

  -- Log it
  local job_id = log._next_id()
  log.start(job_id, "project-init", vim.api.nvim_get_current_buf(), 0, 0, prompt)

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
    pcall(os.remove, tmpfile)
    pcall(os.remove, wrapper)

    vim.schedule(function()
      local raw = table.concat(stdout_chunks, "")

      if code ~= 0 or vim.trim(raw) == "" then
        log.finish(job_id, "error", raw, nil, "AI generation failed (exit " .. code .. ")")
        vim.notify("[dwight] AI generation failed. Creating template instead.", vim.log.levels.WARN)
        M._init_with_content("# Project Scope\n\n" .. description)
        return
      end

      -- Extract from fences
      local content
      local blocks = {}
      for block in raw:gmatch("```%w*\n(.-)\n```") do blocks[#blocks + 1] = block end
      if #blocks > 0 then
        content = blocks[1]
        for i = 2, #blocks do
          if #blocks[i] > #content then content = blocks[i] end
        end
      else
        content = raw:gsub("^[^\n]*[Hh]ere.-\n", "")
      end

      log.finish(job_id, "success", raw, content, nil)
      M._init_with_content(content)

      -- Copy built-in skills
      local copied = M._copy_builtin_skills()

      local msg = "📎 [dwight] Project initialized! Review and edit project.md."
      if #copied > 0 then
        msg = msg .. "\nBuilt-in skills: " ..
          table.concat(vim.tbl_map(function(n) return "@" .. n end, copied), ", ")
      end
      vim.notify(msg, vim.log.levels.INFO)
    end)
  end)

  if not handle then
    pcall(os.remove, tmpfile)
    pcall(os.remove, wrapper)
    M._init_with_content("# Project Scope\n\n" .. description)
    return
  end

  stdout:read_start(function(err, data) if not err and data then stdout_chunks[#stdout_chunks + 1] = data end end)
  stderr:read_start(function(err, data) if not err and data then stderr_chunks[#stderr_chunks + 1] = data end end)
end

--- Scan project root for hint files (package.json, Cargo.toml, etc.)
function M._scan_project_hints()
  local root = M.root()
  local hints = {}
  local check = {
    "package.json", "Cargo.toml", "go.mod", "pyproject.toml", "mix.exs",
    "Gemfile", "flake.nix", "build.zig", "CMakeLists.txt", "Makefile",
    "tsconfig.json", "setup.py", "requirements.txt", "pom.xml", "build.gradle",
    "composer.json", "pubspec.yaml", "deno.json",
  }
  for _, file in ipairs(check) do
    if vim.fn.filereadable(root .. "/" .. file) == 1 then
      hints[#hints + 1] = file
    end
  end
  return #hints > 0 and table.concat(hints, ", ") or "(no config files detected)"
end

--- Write content to project.md and open it.
function M._init_with_content(content)
  vim.fn.mkdir(M.skills_dir(), "p")
  M._create_gitignore()

  local f = io.open(M.project_file(), "w")
  if f then
    f:write(content)
    f:close()
  end
  vim.cmd("edit " .. vim.fn.fnameescape(M.project_file()))
end

--- Fallback: write a template if user cancels the description prompt.
function M._init_with_template()
  local template = [[
# Project Scope

## What This Project Does


## Tech Stack


## Architecture


## Conventions

- 
- 

## Important Constraints

- 

## Directory Structure Notes

]]
  vim.fn.mkdir(M.skills_dir(), "p")
  M._create_gitignore()
  M._init_with_content(template)

  local copied = M._copy_builtin_skills()
  local msg = "[dwight] Project initialized with blank template."
  if #copied > 0 then
    msg = msg .. " Built-in skills installed."
  end
  vim.notify(msg, vim.log.levels.INFO)
end

function M._create_gitignore()
  local gi = io.open(M.dir() .. "/.gitignore", "w")
  if gi then gi:write("usage.json\n"); gi:close() end
end

--------------------------------------------------------------------
-- Built-in Skills
--------------------------------------------------------------------

function M._copy_builtin_skills()
  local builtin = M.builtin_dir()
  if not builtin or vim.fn.isdirectory(builtin) ~= 1 then return {} end

  local handle = uv.fs_scandir(builtin)
  if not handle then return {} end

  local copied = {}
  while true do
    local name, ftype = uv.fs_scandir_next(handle)
    if not name then break end
    if ftype == "file" and name:match("%.md$") then
      local dest = M.skills_dir() .. "/" .. name
      if vim.fn.filereadable(dest) ~= 1 then
        local src = io.open(builtin .. "/" .. name, "r")
        if src then
          local content = src:read("*a"); src:close()
          local dst = io.open(dest, "w")
          if dst then dst:write(content); dst:close(); copied[#copied + 1] = name:gsub("%.md$", "") end
        end
      end
    end
  end

  table.sort(copied)
  return copied
end

function M.install_builtins()
  if not M.is_initialized() then
    vim.notify("[dwight] Run :DwightInit first.", vim.log.levels.WARN)
    return
  end
  local copied = M._copy_builtin_skills()
  if #copied > 0 then
    vim.notify("📎 [dwight] Installed: " ..
      table.concat(vim.tbl_map(function(n) return "@" .. n end, copied), ", "), vim.log.levels.INFO)
  else
    vim.notify("[dwight] All built-in skills already installed.", vim.log.levels.INFO)
  end
end

--------------------------------------------------------------------
-- Read project scope
--------------------------------------------------------------------

function M.read_scope()
  if not M.is_initialized() then return nil end
  local f = io.open(M.project_file(), "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()

  content = content:gsub("<!%-%-.-%-%->", "")
  content = content:gsub("\n%s*\n%s*\n", "\n\n")

  local trimmed = vim.trim(content)
  if trimmed == "" or trimmed == "# Project Scope" then return nil end
  return content
end

return M
