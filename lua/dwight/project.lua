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
end

--------------------------------------------------------------------
-- Init (AI-assisted)
--------------------------------------------------------------------

function M.init()
  if M.is_initialized() then
    vim.notify("[dwight] Already initialized. Run :DwightBootstrap to add pragma comments.", vim.log.levels.INFO)
    return
  end

  -- Create directory structure
  vim.fn.mkdir(M.skills_dir(), "p")
  vim.fn.mkdir(M.dir() .. "/brainstorm", "p")
  M._create_gitignore()

  -- Copy built-in skills if available
  local copied = M._copy_builtin_skills()
  local msg = "📎 [dwight] Initialized! .dwight/ directory created."
  if #copied > 0 then
    msg = msg .. "\nBuilt-in skills: " ..
      table.concat(vim.tbl_map(function(n) return "@" .. n end, copied), ", ")
  end
  msg = msg .. "\n\nNext steps:"
  msg = msg .. "\n  :DwightBootstrap  — auto-add pragma comments (@feature, @project, etc.)"
  msg = msg .. "\n  Or manually add pragmas: // @project, // @feature:name, etc."
  vim.notify(msg, vim.log.levels.INFO)

  -- Auto-suggest skill packs based on detected project type
  pcall(function()
    require("dwight.marketplace").auto_suggest()
  end)
end

function M._generate_scope(description)
  local log = require("dwight.log")

  local prompt = string.format([[
Generate a project scope document for an AI coding assistant. The developer described their project as:

"%s"

Config files found: %s

Create practical markdown with: What This Project Does, Tech Stack, Architecture, Conventions, Important Constraints, Directory Structure Notes.
Under 80 lines. Reply with ONLY markdown in a fenced code block.
]], description, M._scan_project_hints())

  local job_id = log._next_id()
  log.start(job_id, "project-init", vim.api.nvim_get_current_buf(), 0, 0, prompt)

  require("dwight.skills")._run_llm(prompt, function(raw, code)
    if code ~= 0 or vim.trim(raw) == "" then
      log.finish(job_id, "error", raw, nil, "AI generation failed (exit " .. code .. ")")
      vim.notify("[dwight] AI generation failed. Creating template instead.", vim.log.levels.WARN)
      M._init_with_content("# Project Scope\n\n" .. description)
      return
    end

    local content
    local blocks = {}
    for block in raw:gmatch("```%w*\n(.-)\n```") do blocks[#blocks + 1] = block end
    if #blocks > 0 then
      content = blocks[1]
      for i = 2, #blocks do if #blocks[i] > #content then content = blocks[i] end end
    else
      content = raw:gsub("^[^\n]*[Hh]ere.-\n", "")
    end

    log.finish(job_id, "success", raw, content, nil)
    M._init_with_content(content)

    local copied = M._copy_builtin_skills()
    local msg = "📎 [dwight] Project initialized! Review and edit project.md."
    if #copied > 0 then
      msg = msg .. "\nBuilt-in skills: " ..
        table.concat(vim.tbl_map(function(n) return "@" .. n end, copied), ", ")
    end
    vim.notify(msg, vim.log.levels.INFO)

    -- Auto-suggest skill packs based on detected project type
    pcall(function()
      require("dwight.marketplace").auto_suggest()
    end)
  end)
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
  if gi then
    gi:write(table.concat({
      "# Private/session data — don't share",
      "usage.json",
      "session.log",
      "logs/",
      "runs/",
      "prompts/",
      "brainstorm/",
      "agent/",
      "artifacts/",
      "auto/",
      "audits/",
      "plans/",
      "whiteboard.md",
      "",
      "# Everything else (.dwight/skills/, libs/, templates/, dev/)",
      "# is safe and recommended to commit.",
    }, "\n") .. "\n")
    gi:close()
  end
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
  -- Try JIT project context from pragmas first
  local jit_ok, jit_context = pcall(function()
    local features = require("dwight.features")
    return features.build_project_context()
  end)
  if jit_ok and jit_context then return jit_context end

  -- Fallback: read project.md
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
