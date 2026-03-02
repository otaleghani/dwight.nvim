-- dwight/bootstrap.lua
-- Bootstrap an existing project with dwight pragma comments.
-- Scans project structure, asks LLM to suggest pragmas, previews + applies.

local M = {}

local api = vim.api

--------------------------------------------------------------------
-- Scan: build a project snapshot for the LLM
--------------------------------------------------------------------

local SKIP_DIRS = {
  node_modules = true, [".git"] = true, dist = true, build = true,
  vendor = true, [".dwight"] = true, __pycache__ = true,
  [".next"] = true, [".nuxt"] = true, target = true, out = true,
  docs = true, coverage = true,
}

local SKIP_EXT = {
  [".png"] = true, [".jpg"] = true, [".jpeg"] = true, [".gif"] = true,
  [".svg"] = true, [".ico"] = true, [".woff"] = true, [".woff2"] = true,
  [".ttf"] = true, [".eot"] = true, [".mp3"] = true, [".mp4"] = true,
  [".zip"] = true, [".tar"] = true, [".gz"] = true, [".lock"] = true,
  [".min.js"] = true, [".min.css"] = true, [".map"] = true,
}

--- Scan project and build a snapshot for the LLM.
function M.scan()
  local cwd = vim.fn.getcwd()
  local uv = vim.loop or vim.uv
  local tree = {}
  local entry_files = {}
  local config_files = {}

  -- Entry point patterns
  local ENTRY_PATTERNS = {
    "^main%.", "^index%.", "^app%.", "^server%.", "^mod%.",
    "^lib%.", "^cmd/", "^src/main", "^src/index", "^src/app",
    "^src/lib", "^package%.json$", "^Cargo%.toml$", "^go%.mod$",
    "^pyproject%.toml$", "^setup%.py$", "^Makefile$", "^CMakeLists",
  }

  -- Config patterns
  local CONFIG_PATTERNS = {
    "%.config%.", "%.json$", "%.toml$", "%.yaml$", "%.yml$",
    "tsconfig", "webpack", "vite%.config", "next%.config",
    "Dockerfile", "docker%-compose",
  }

  local function is_entry(rel)
    for _, pat in ipairs(ENTRY_PATTERNS) do
      if rel:match(pat) then return true end
    end
    return false
  end

  local function is_config(rel)
    for _, pat in ipairs(CONFIG_PATTERNS) do
      if rel:match(pat) then return true end
    end
    return false
  end

  local function walk(dir, prefix)
    local handle = uv.fs_scandir(dir)
    if not handle then return end
    while true do
      local name, ftype = uv.fs_scandir_next(handle)
      if not name then break end
      if name:sub(1, 1) ~= "." and not SKIP_DIRS[name] then
        local rel = prefix ~= "" and (prefix .. "/" .. name) or name
        local full = dir .. "/" .. name
        if ftype == "directory" then
          tree[#tree + 1] = rel .. "/"
          walk(full, rel)
        elseif ftype == "file" then
          local ext = name:match("(%.[^.]+)$") or ""
          if not SKIP_EXT[ext] then
            tree[#tree + 1] = rel
            if is_entry(rel) then entry_files[#entry_files + 1] = rel end
            if is_config(rel) then config_files[#config_files + 1] = rel end
          end
        end
      end
    end
  end

  walk(cwd, "")
  table.sort(tree)

  -- Read first 30 lines of entry files for context
  local entry_snippets = {}
  for _, rel in ipairs(entry_files) do
    local f = io.open(cwd .. "/" .. rel, "r")
    if f then
      local lines = {}
      for i = 1, 30 do
        local line = f:read("*l")
        if not line then break end
        lines[#lines + 1] = line
      end
      f:close()
      if #lines > 0 then
        entry_snippets[#entry_snippets + 1] = {
          path = rel,
          content = table.concat(lines, "\n"),
        }
      end
    end
  end

  return {
    tree = tree,
    entry_files = entry_files,
    config_files = config_files,
    entry_snippets = entry_snippets,
  }
end

--------------------------------------------------------------------
-- Coverage: check pragma coverage across source files
--------------------------------------------------------------------

--- Scan project and compute pragma coverage.
--- Returns { total_files, tagged_files, untagged_files, features, coverage_pct,
---           untagged = { "path/to/file.go", ... }, tagged = { "path/to/file.go", ... } }
function M.coverage()
  local cwd = vim.fn.getcwd()
  local uv = vim.loop or vim.uv
  local features = require("dwight.features")

  -- Source file extensions we expect to be tagged
  local SOURCE_EXT = {
    [".go"] = true, [".js"] = true, [".ts"] = true, [".jsx"] = true, [".tsx"] = true,
    [".py"] = true, [".lua"] = true, [".rb"] = true, [".rs"] = true, [".java"] = true,
    [".kt"] = true, [".cs"] = true, [".c"] = true, [".cpp"] = true, [".cc"] = true,
    [".h"] = true, [".hpp"] = true, [".swift"] = true, [".php"] = true, [".ex"] = true,
    [".exs"] = true, [".scala"] = true, [".hs"] = true, [".zig"] = true, [".ml"] = true,
    [".clj"] = true, [".r"] = true, [".R"] = true, [".sh"] = true, [".bash"] = true,
    [".dart"] = true, [".erl"] = true, [".vue"] = true, [".svelte"] = true,
  }

  -- Collect all source files
  local all_source = {}
  local function walk_cov(dir, prefix)
    local handle = uv.fs_scandir(dir)
    if not handle then return end
    while true do
      local name, ftype = uv.fs_scandir_next(handle)
      if not name then break end
      if name:sub(1, 1) ~= "." and not SKIP_DIRS[name] then
        local rel = prefix ~= "" and (prefix .. "/" .. name) or name
        local full = dir .. "/" .. name
        if ftype == "directory" then
          walk_cov(full, rel)
        elseif ftype == "file" then
          local ext = name:match("(%.[^.]+)$") or ""
          if SOURCE_EXT[ext] then
            -- Skip test files
            if not rel:match("_test%.") and not rel:match("%.test%.")
              and not rel:match("%.spec%.") and not rel:match("^test/")
              and not rel:match("^tests/") and not rel:match("__tests__/")
              and not rel:match("test_") then
              all_source[#all_source + 1] = rel
            end
          end
        end
      end
    end
  end
  walk_cov(cwd, "")
  table.sort(all_source)

  -- Check each file for pragma presence
  local tagged = {}
  local untagged = {}

  for _, rel in ipairs(all_source) do
    local f = io.open(cwd .. "/" .. rel, "r")
    local has_pragma = false
    if f then
      -- Only check first 5 lines (pragmas go at top)
      for _ = 1, 5 do
        local line = f:read("*l")
        if not line then break end
        if line:match("@feature:") or line:match("@project")
          or line:match("@stack") or line:match("@constraint")
          or line:match("@convention") then
          has_pragma = true
          break
        end
      end
      f:close()
    end

    if has_pragma then
      tagged[#tagged + 1] = rel
    else
      untagged[#untagged + 1] = rel
    end
  end

  local feature_names = features.names()
  local total = #all_source
  local pct = total > 0 and (#tagged / total * 100) or 0

  return {
    total_files = total,
    tagged_files = #tagged,
    untagged_files = #untagged,
    features = feature_names,
    coverage_pct = pct,
    tagged = tagged,
    untagged = untagged,
  }
end

--------------------------------------------------------------------
-- Generate pragma suggestions via LLM
--------------------------------------------------------------------

local BOOTSTRAP_PROMPT = [=[
You are analyzing a project to add dwight pragma comments for AI-assisted development.

Project structure:
%s

Entry/config files found: %s

Entry file previews:
%s

Suggest pragma comments to add to this project. For each suggestion, output in this EXACT format:

<changes>
<file path="src/index.ts" action="edit" lines="1-1">
// REST API for task management with real-time updates. @project
// TypeScript, Express, PostgreSQL, Redis. @stack
// Must handle 10k concurrent users. GDPR compliant. @constraint
// Use dependency injection. All errors typed. No any. @convention
(original line 1 content here)
</file>
<file path="src/auth/index.ts" action="edit" lines="1-1">
// JWT-based authentication and session management. @feature:auth
(original line 1 content here)
</file>
</changes>

RULES:
- Add @project, @stack, @constraint, @convention pragmas to the MAIN entry point only.
- Add @feature:name pragmas to EACH distinct module/feature directory.
- Feature names should be short, lowercase, kebab-case (e.g. auth, payments, user-mgmt).
- Each pragma comment goes ABOVE the first line of the file.
- For "edit" actions, set lines="1-1" and include the pragma comment(s) PLUS the original first line.
- Use the comment style appropriate for the language (// for JS/TS/Go, # for Python, -- for Lua, etc.)
- Only suggest pragmas for files that represent distinct features. Skip utils, helpers, configs.
- Be conservative: 1 @project, 1 @stack, 1-3 @constraint, 1-3 @convention, 3-10 @feature.
- Descriptions should be ONE concise sentence.
]=]

function M.generate(callback)
  local scan = M.scan()

  local tree_str = table.concat(scan.tree, "\n")
  if #tree_str > 3000 then tree_str = tree_str:sub(1, 3000) .. "\n... (truncated)" end

  local entries_str = table.concat(scan.entry_files, ", ")
  if entries_str == "" then entries_str = "(none detected)" end

  local snippets_parts = {}
  for _, s in ipairs(scan.entry_snippets) do
    snippets_parts[#snippets_parts + 1] = string.format("--- %s ---\n%s", s.path, s.content)
  end
  local snippets_str = table.concat(snippets_parts, "\n\n")
  if snippets_str == "" then snippets_str = "(no entry files found)" end

  local prompt = string.format(BOOTSTRAP_PROMPT, tree_str, entries_str, snippets_str)

  -- Log to DwightLog
  local log = require("dwight.log")
  local job_id = log._next_id()
  log.start(job_id, "bootstrap", api.nvim_get_current_buf(), 0, 0,
    "DwightBootstrap: " .. #scan.tree .. " files scanned\n\n" .. prompt:sub(1, 4000))

  require("dwight.skills")._run_llm(prompt, function(raw, code)
    if code ~= 0 or vim.trim(raw or "") == "" then
      log.finish(job_id, "error", raw or "", nil, "LLM generation failed")
      callback(nil, "LLM generation failed")
      return
    end
    -- Parse multi-file changes
    local multifile = require("dwight.multifile")
    local changes = multifile.parse_xml(raw)
    if not changes then
      log.finish(job_id, "parse_fail", raw or "", nil, "Could not parse pragma suggestions")
      callback(nil, "Could not parse pragma suggestions. Raw:\n" .. (raw or ""):sub(1, 500))
      return
    end
    log.finish(job_id, "success", raw,
      string.format("%d file(s) to annotate with pragmas", #changes), nil)
    callback(changes, nil)
  end)
end

--------------------------------------------------------------------
-- :DwightBootstrap — interactive pragma bootstrapping
--------------------------------------------------------------------

function M.bootstrap(opts)
  opts = opts or {}
  local project = require("dwight.project")
  if not project.is_initialized() then
    vim.notify("[dwight] Run :DwightInit first to create .dwight/.", vim.log.levels.WARN)
    return
  end

  -- Incremental mode: skip the "already has pragmas" warning, it's the point
  if opts.incremental then
    local cov = M.coverage()
    if cov.untagged_files == 0 then
      vim.notify(string.format(
        "[dwight] ✅ Full coverage! All %d source files are tagged (%d features).",
        cov.total_files, #cov.features), vim.log.levels.INFO)
      return
    end
    vim.notify(string.format(
      "[dwight] 📊 Pragma coverage: %d/%d files (%.0f%%) — %d untagged\n" ..
      "   Features: %s",
      cov.tagged_files, cov.total_files, cov.coverage_pct, cov.untagged_files,
      #cov.features > 0 and table.concat(cov.features, ", ") or "(none)"),
      vim.log.levels.INFO)
    M._pick_mode(opts)
    return
  end

  -- Check if project already has pragmas
  local features = require("dwight.features")
  local existing = features.names()
  if #existing > 0 and not opts.force then
    -- Suggest incremental instead
    local cov = M.coverage()
    require("dwight.select").pick({
      string.format("📈 Incremental — tag %d untagged files (keep existing)", cov.untagged_files),
      "🔄 Full re-bootstrap (may duplicate pragmas)",
      "❌ Cancel",
    }, {
      prompt = string.format("Project has %d feature(s) (%d/%d files tagged). What to do?",
        #existing, cov.tagged_files, cov.total_files),
    }, function(choice)
      if not choice or choice:match("Cancel") then return end
      if choice:match("Incremental") then
        opts.incremental = true
        M._pick_mode(opts)
      else
        opts.force = true
        M._pick_mode(opts)
      end
    end)
    return
  end

  M._pick_mode(opts)
end

--- Let user choose bootstrap mode.
function M._pick_mode(opts)
  if opts and opts.mode then
    if opts.mode == "agentic" then
      if opts.incremental then
        M._run_bootstrap_incremental_agentic()
      else
        M._run_bootstrap_agentic()
      end
    else
      if opts.incremental then
        M._run_bootstrap_incremental()
      else
        M._run_bootstrap()
      end
    end
    return
  end

  local choices = opts.incremental and {
    "🤖 Agentic incremental (reads code, comprehensive — recommended)",
    "⚡ Quick incremental (directory scan only, faster but shallower)",
  } or {
    "🤖 Agentic (reads code, comprehensive — recommended)",
    "⚡ Quick (directory scan only, faster but shallower)",
  }

  require("dwight.select").pick(choices, {
    prompt = "Bootstrap mode:",
  }, function(choice)
    if not choice then return end
    if choice:match("Agentic") then
      if opts.incremental then
        M._run_bootstrap_incremental_agentic()
      else
        M._run_bootstrap_agentic()
      end
    else
      if opts.incremental then
        M._run_bootstrap_incremental()
      else
        M._run_bootstrap()
      end
    end
  end)
end

--- Legacy single-shot bootstrap (fast but shallow).
function M._run_bootstrap()
  vim.notify("[dwight] ⚡ Quick bootstrap: scanning project…", vim.log.levels.INFO)

  M.generate(function(changes, err)
    if err then
      vim.notify("[dwight] Bootstrap failed: " .. err, vim.log.levels.ERROR)
      return
    end

    vim.notify(string.format("[dwight] Found %d files to annotate.", #changes), vim.log.levels.INFO)

    local multifile = require("dwight.multifile")
    local count = multifile.apply_all(changes)
    vim.notify(string.format(
      "[dwight] ✅ Bootstrap complete! Added pragmas to %d file(s). Run :DwightFeatures to verify.\n" ..
      "Use :DwightMultiUndo to revert all, or undo per-file with u.",
      count), vim.log.levels.INFO)
  end)
end

--------------------------------------------------------------------
-- Agentic bootstrap: uses DwightAgent to read code and tag files
--------------------------------------------------------------------

local AGENTIC_BOOTSTRAP_PROMPT = [=[
You are bootstrapping a project with dwight pragma comments for AI-assisted development.

## What are dwight pragmas?

Pragma comments are special inline comments that help the AI understand the codebase structure.
They are placed at the TOP of source files (line 1 or 2), using the file's native comment syntax.

Available pragma types:

1. **@project** — ONE file only (main entry point). Describes what the project does.
   Example: `// Todo app with REST API and WebSocket notifications. @project`

2. **@stack** — ONE file only (same as @project). Lists the tech stack.
   Example: `// Go 1.22, GORM, SQLite, JWT, Cobra CLI. @stack`

3. **@constraint** — ONE file only (same as @project). Project constraints.
   Example: `// GDPR compliant. No global state. 100%% test coverage on core. @constraint`

4. **@convention** — ONE file only (same as @project). Coding conventions.
   Example: `// Use dependency injection. Error wrapping with %%w. Table-driven tests. @convention`

5. **@feature:name** — MANY files. Groups files into logical features.
   Example: `// JWT authentication and session management. @feature:auth`
   - Name: lowercase, kebab-case (auth, user-mgmt, billing, api-routes)
   - Description: ONE sentence explaining what this feature does
   - Every source file that belongs to a feature should have this pragma

## Your task

1. **Read the directory tree** to understand project structure
2. **Read key files** — entry points, package definitions, main modules — to understand architecture
3. **Identify features** — logical groupings of files (auth, database, routing, UI, etc.)
4. **Add pragmas to ALL relevant source files:**
   - @project + @stack + @constraint + @convention on the main entry point
   - @feature:name on EVERY file that belongs to a feature
5. **Verify coverage** by listing what you tagged

## Rules

- Use the file's comment syntax (// for Go/JS/TS, # for Python, -- for Lua, etc.)
- Add pragma as the FIRST line of the file (prepend before existing content)
- If the file already has a pragma, skip it
- Be THOROUGH: tag 80%%+ of source files. Skip only utilities, generated code, and configs.
- Feature names: 3-15 features for a medium project. Group related files together.
- Descriptions: ONE concise sentence per pragma.
- Do NOT modify any actual code — only add comment lines at the top.
- Skip: test files, vendor/, node_modules/, .git/, binary files, config files (json/yaml/toml)
- After tagging, list all features you created with file counts.

## Pragma format by language

Go:     `// Description. @feature:name`
JS/TS:  `// Description. @feature:name`
Python: `# Description. @feature:name`
Lua:    `-- Description. @feature:name`
Ruby:   `# Description. @feature:name`
Rust:   `// Description. @feature:name`
C/C++:  `// Description. @feature:name`
Java:   `// Description. @feature:name`
Shell:  `# Description. @feature:name`

Start by reading the project structure, then read key files to understand the architecture.
Then systematically add pragmas file by file.
]=]

function M._run_bootstrap_agentic()
  vim.notify("[dwight] 🤖 Agentic bootstrap: scanning project…", vim.log.levels.INFO)

  -- Pre-scan project to give the agent a head start (avoid wasting tokens on ls)
  local scan = M.scan()
  local tree_str = table.concat(scan.tree, "\n")
  if #tree_str > 6000 then tree_str = tree_str:sub(1, 6000) .. "\n... (truncated)" end

  local entries_str = table.concat(scan.entry_files, ", ")
  if entries_str == "" then entries_str = "(none detected)" end

  local snippets_parts = {}
  for _, s in ipairs(scan.entry_snippets) do
    snippets_parts[#snippets_parts + 1] = string.format("--- %s ---\n%s", s.path, s.content)
  end
  local snippets_str = table.concat(snippets_parts, "\n\n")
  if snippets_str == "" then snippets_str = "(no entry files found)" end

  local file_count = 0
  for _, entry in ipairs(scan.tree) do
    if not entry:match("/$") then file_count = file_count + 1 end
  end

  local prompt = AGENTIC_BOOTSTRAP_PROMPT .. string.format([=[

## Project scan (pre-computed — do NOT waste time running ls or find)

Total files: %d
Entry/config files: %s

Directory tree:
```
%s
```

Entry file previews:
```
%s
```

Now proceed: read key source files to understand the architecture, then add pragmas.
Target: tag at least %d files (80%% of %d source files).
]=], file_count, entries_str, tree_str, snippets_str,
    math.floor(file_count * 0.8), file_count)

  vim.notify(string.format(
    "[dwight] 🤖 Agentic bootstrap: %d files found, starting agent…", file_count),
    vim.log.levels.INFO)

  local agent = require("dwight.agent")
  agent.run(prompt, {
    on_complete = function(success)
      vim.schedule(function()
        if success then
          -- Rebuild feature index
          pcall(function()
            local features = require("dwight.features")
            local names = features.names()
            local total_tagged = 0
            for _, name in ipairs(names) do
              local feature = features.build_feature(name)
              if feature and feature.files then
                total_tagged = total_tagged + #feature.files
              end
            end
            vim.notify(string.format(
              "[dwight] 🤖 Bootstrap complete!\n" ..
              "  Features: %d (%s)\n" ..
              "  Tagged: %d/%d files (%.0f%%)\n" ..
              "Run :DwightFeatures to explore.",
              #names, table.concat(names, ", "),
              total_tagged, file_count,
              file_count > 0 and (total_tagged / file_count * 100) or 0),
              vim.log.levels.INFO)
          end)
        else
          vim.notify("[dwight] 🤖 Bootstrap had errors. Check :DwightAgentStatus for details.",
            vim.log.levels.WARN)
        end
      end)
    end,
  })
end

--------------------------------------------------------------------
-- Incremental bootstrap: only tag untagged files
--------------------------------------------------------------------

local INCREMENTAL_PROMPT = [=[
You are adding dwight pragma comments to UNTAGGED files in a project that already has partial coverage.

## Existing features in the project
%s

## Files that ALREADY have pragmas (DO NOT touch these)
%s

## Files that NEED pragmas (YOUR TARGETS)
%s

## Entry file previews (for context)
%s

Suggest pragma comments ONLY for the untagged files listed above.
For each file, output in this EXACT format:

<changes>
<file path="src/utils/helper.go" action="edit" lines="1-1">
// Shared utility functions for string and error handling. @feature:utils
(original line 1 content here)
</file>
</changes>

RULES:
- ONLY tag files from the "NEED pragmas" list. Do NOT touch already-tagged files.
- Assign each file to an EXISTING feature if it fits, or create a NEW feature if needed.
- Use the same comment style and naming conventions as existing pragmas.
- If a file doesn't clearly belong to any feature, use a general one like @feature:core or @feature:utils.
- Descriptions should be ONE concise sentence.
- Do NOT add @project/@stack/@constraint/@convention — those already exist.
]=]

--- Quick incremental bootstrap (single-shot LLM).
function M._run_bootstrap_incremental()
  local cov = M.coverage()
  if cov.untagged_files == 0 then
    vim.notify("[dwight] ✅ All files already tagged!", vim.log.levels.INFO)
    return
  end

  vim.notify(string.format(
    "[dwight] ⚡ Incremental bootstrap: %d untagged files to tag…", cov.untagged_files),
    vim.log.levels.INFO)

  -- Build context from existing coverage
  local features_str = #cov.features > 0
    and table.concat(cov.features, ", ") or "(none)"
  local tagged_str = table.concat(cov.tagged, "\n")
  if #tagged_str > 2000 then tagged_str = tagged_str:sub(1, 2000) .. "\n... (truncated)" end
  local untagged_str = table.concat(cov.untagged, "\n")
  if #untagged_str > 3000 then untagged_str = untagged_str:sub(1, 3000) .. "\n... (truncated)" end

  -- Read first lines of a few untagged files for context
  local cwd = vim.fn.getcwd()
  local snippets = {}
  for i, rel in ipairs(cov.untagged) do
    if i > 10 then break end  -- cap at 10 snippets
    local f = io.open(cwd .. "/" .. rel, "r")
    if f then
      local lines = {}
      for j = 1, 15 do
        local line = f:read("*l")
        if not line then break end
        lines[#lines + 1] = line
      end
      f:close()
      if #lines > 0 then
        snippets[#snippets + 1] = string.format("--- %s ---\n%s", rel, table.concat(lines, "\n"))
      end
    end
  end
  local snippets_str = #snippets > 0 and table.concat(snippets, "\n\n") or "(none)"

  local prompt = string.format(INCREMENTAL_PROMPT,
    features_str, tagged_str, untagged_str, snippets_str)

  local log = require("dwight.log")
  local job_id = log._next_id()
  log.start(job_id, "bootstrap-incremental", api.nvim_get_current_buf(), 0, 0,
    string.format("Incremental bootstrap: %d untagged files\n\n%s",
      cov.untagged_files, prompt:sub(1, 4000)))

  require("dwight.skills")._run_llm(prompt, function(raw, code)
    if code ~= 0 or vim.trim(raw or "") == "" then
      log.finish(job_id, "error", raw or "", nil, "LLM generation failed")
      vim.notify("[dwight] Incremental bootstrap failed.", vim.log.levels.ERROR)
      return
    end

    local multifile = require("dwight.multifile")
    local changes = multifile.parse_xml(raw)
    if not changes then
      log.finish(job_id, "parse_fail", raw or "", nil, "Could not parse suggestions")
      vim.notify("[dwight] Could not parse pragma suggestions.", vim.log.levels.ERROR)
      return
    end

    log.finish(job_id, "success", raw,
      string.format("%d file(s) to annotate", #changes), nil)

    local count = multifile.apply_all(changes)

    -- Show before/after coverage
    local after = M.coverage()
    vim.notify(string.format(
      "[dwight] ✅ Incremental bootstrap complete!\n" ..
      "  Before: %d/%d files (%.0f%%)\n" ..
      "  After:  %d/%d files (%.0f%%)\n" ..
      "  Tagged: %d new file(s), %d feature(s)\n" ..
      "Use :DwightMultiUndo to revert, or :DwightBootstrap --incremental to tag more.",
      cov.tagged_files, cov.total_files, cov.coverage_pct,
      after.tagged_files, after.total_files, after.coverage_pct,
      count, #after.features),
      vim.log.levels.INFO)
  end)
end

--- Agentic incremental bootstrap.
function M._run_bootstrap_incremental_agentic()
  local cov = M.coverage()
  if cov.untagged_files == 0 then
    vim.notify("[dwight] ✅ All files already tagged!", vim.log.levels.INFO)
    return
  end

  local before_tagged = cov.tagged_files
  local before_total = cov.total_files
  local before_pct = cov.coverage_pct

  vim.notify(string.format(
    "[dwight] 🤖 Incremental agentic bootstrap: %d untagged files to tag…",
    cov.untagged_files), vim.log.levels.INFO)

  -- Build the untagged file list for the agent
  local untagged_str = table.concat(cov.untagged, "\n")
  if #untagged_str > 8000 then
    untagged_str = untagged_str:sub(1, 8000) .. "\n... (truncated)"
  end

  local features_str = #cov.features > 0
    and table.concat(cov.features, ", ") or "(none)"

  local prompt = AGENTIC_BOOTSTRAP_PROMPT .. string.format([=[

## INCREMENTAL MODE — IMPORTANT

This project ALREADY has partial pragma coverage. Your job is to tag ONLY the untagged files.

Current coverage: %d/%d files (%.0f%%)
Existing features: %s

### Files that ALREADY have pragmas (DO NOT modify)
There are %d files that already have pragmas. Do NOT touch them.

### Files that NEED pragmas (YOUR TARGETS — tag ALL of these)
```
%s
```

CRITICAL RULES for incremental mode:
- Do NOT touch files that already have pragmas — you'll create duplicates.
- Assign files to EXISTING features when they fit.
- Create new features only when files don't fit any existing feature.
- Use the same comment style and naming conventions as existing pragmas.
- Do NOT re-add @project/@stack/@constraint/@convention — they already exist.
- Only add @feature:name pragmas to the untagged files.
- Read a few already-tagged files first to understand the existing naming pattern.
- Target: tag ALL %d untagged files.

Start by reading 2-3 already-tagged files to see the existing pragma style, then systematically tag the untagged files.
]=], cov.tagged_files, cov.total_files, cov.coverage_pct,
    features_str, cov.tagged_files, untagged_str, cov.untagged_files)

  local agent = require("dwight.agent")
  agent.run(prompt, {
    plan = false,  -- skip planning, the prompt IS the plan
    on_complete = function(success)
      vim.schedule(function()
        if success then
          local after = M.coverage()
          local new_tagged = after.tagged_files - before_tagged
          vim.notify(string.format(
            "[dwight] 🤖 Incremental bootstrap complete!\n" ..
            "  Before: %d/%d files (%.0f%%)\n" ..
            "  After:  %d/%d files (%.0f%%)\n" ..
            "  Tagged: +%d file(s), %d feature(s)\n" ..
            "  %s\n" ..
            "Run :DwightFeatures to explore, :DwightBootstrap --incremental to tag more.",
            before_tagged, before_total, before_pct,
            after.tagged_files, after.total_files, after.coverage_pct,
            new_tagged, #after.features,
            after.untagged_files == 0
              and "✅ Full coverage achieved!"
              or string.format("📊 %d files still untagged", after.untagged_files)),
            vim.log.levels.INFO)
        else
          vim.notify("[dwight] 🤖 Incremental bootstrap had errors. Check :DwightAgentStatus.",
            vim.log.levels.WARN)
        end
      end)
    end,
  })
end

--------------------------------------------------------------------
-- Coverage display command
--------------------------------------------------------------------

--- Show coverage report.
function M.show_coverage()
  local cov = M.coverage()
  local lines = {
    string.format("📊 Pragma Coverage: %d/%d files (%.0f%%)",
      cov.tagged_files, cov.total_files, cov.coverage_pct),
    string.format("   Features: %d — %s",
      #cov.features, #cov.features > 0 and table.concat(cov.features, ", ") or "(none)"),
  }

  if cov.untagged_files > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = string.format("   Untagged (%d):", cov.untagged_files)
    local max_show = math.min(cov.untagged_files, 20)
    for i = 1, max_show do
      lines[#lines + 1] = "     " .. cov.untagged[i]
    end
    if cov.untagged_files > max_show then
      lines[#lines + 1] = string.format("     ... and %d more", cov.untagged_files - max_show)
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "   Run :DwightBootstrap --incremental to tag untagged files."
  else
    lines[#lines + 1] = "   ✅ Full coverage!"
  end

  vim.notify("[dwight]\n" .. table.concat(lines, "\n"), vim.log.levels.INFO)
end

return M
