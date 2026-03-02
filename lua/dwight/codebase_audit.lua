-- dwight/codebase_audit.lua
-- DwightAudit: deep codebase analysis per feature.
-- Phase 1: static analysis (treesitter + regex). Zero LLM calls.
-- Phase 2: targeted LLM review on flagged items only.
-- Output: ranked report buffer with actionable keybindings.

local M = {}

local api = vim.api
local _flatten = require("dwight.util").flatten_lines

--------------------------------------------------------------------
-- Severity levels
--------------------------------------------------------------------

local SEV = {
  CRITICAL = { icon = "🔴", label = "CRITICAL", sort = 1 },
  WARN     = { icon = "🟡", label = "WARN",     sort = 2 },
  INFO     = { icon = "🔵", label = "INFO",     sort = 3 },
}

--------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------

local MAX_FUNCTION_LINES   = 40   -- lines before flagging
local MAX_NESTING_DEPTH    = 4    -- nesting levels before flagging
local MAX_PARAMS           = 5    -- params before flagging
local MIN_DUPLICATION_LEN  = 8    -- min consecutive matching lines

-- Lines to skip entirely when checking duplication (structural noise)
local DUPLICATION_SKIP_PATTERNS = {
  "^package ",         -- Go package declarations
  "^import ",          -- single-line imports
  "^import%s*%(",      -- multi-line import block opener
  "^from ",            -- Python imports
  "^require%(",        -- Lua/JS require
  "^use ",             -- Rust use
  "^#?include ",       -- C/C++ includes
  "^@feature:",        -- Dwight pragmas
  "^@project",         -- Dwight pragmas
  "^@constraint",      -- Dwight pragmas
  "^@stack",           -- Dwight pragmas
  "^@convention",      -- Dwight pragmas
  "^//",               -- Comment-only lines
  "^#",                -- Comment-only lines
  "^%-%-",             -- Lua comments
  "^/%*",              -- Block comment openers
  "^%*",               -- Block comment continuations
  "^if%s+err%s*!=%s*nil",  -- Go idiomatic error check
  "^t%.Fatal",         -- Go test assertions
  "^t%.Error",         -- Go test assertions
  "^assert",           -- Generic assertions
  "^expect%(",         -- JS test assertions
  "^return ",          -- Simple returns
  "^}$",               -- Lone closing braces
  "^{$",               -- Lone opening braces
  "^%)$",              -- Lone closing parens
  "^end$",             -- Lua/Ruby block ends
}

-- Patterns that suggest hardcoded secrets
local SECRET_PATTERNS = {
  { pat = "['\"]%w*password['\"]%s*[:=]%s*['\"][^'\"]+['\"]",   label = "hardcoded password" },
  { pat = "['\"]%w*secret['\"]%s*[:=]%s*['\"][^'\"]+['\"]",     label = "hardcoded secret" },
  { pat = "['\"]%w*api_?key['\"]%s*[:=]%s*['\"][^'\"]+['\"]",   label = "hardcoded API key" },
  { pat = "['\"]%w*token['\"]%s*[:=]%s*['\"][^'\"]+['\"]",      label = "hardcoded token" },
  { pat = "-----BEGIN [A-Z]+ PRIVATE KEY-----",                  label = "embedded private key" },
  { pat = "sk%-[a-zA-Z0-9]{20,}",                                label = "possible API key literal" },
  { pat = "ghp_[a-zA-Z0-9]{36}",                                 label = "GitHub personal access token" },
}

-- Patterns that suggest swallowed errors
local SWALLOWED_ERROR_PATTERNS = {
  -- Go: if err != nil { } (empty or just return)
  { lang = "go",     pat = "if%s+err%s*!=%s*nil%s*{%s*}",       label = "empty error check" },
  -- JS/TS: catch (e) {} or catch {}
  { lang = "js",     pat = "catch%s*%(?[^)]*%)?%s*{%s*}",        label = "empty catch block" },
  -- Python: except: pass
  { lang = "python", pat = "except[^:]*:%s*\n%s*pass",           label = "bare except: pass" },
  -- Lua: pcall without checking return
  { lang = "lua",    pat = "pcall%(",                             label = "unchecked pcall (verify ok checked)" },
  -- Generic: _ = err
  { lang = "go",     pat = "_%s*=%s*err",                        label = "discarded error" },
}

-- Language detection from file extension
local EXT_TO_LANG = {
  [".go"]   = "go",     [".js"]  = "js",    [".ts"]  = "js",
  [".jsx"]  = "js",     [".tsx"] = "js",     [".py"]  = "python",
  [".lua"]  = "lua",    [".rs"]  = "rust",   [".rb"]  = "ruby",
  [".java"] = "java",   [".kt"]  = "kotlin", [".cs"]  = "csharp",
}

local function detect_lang(filepath)
  local ext = filepath:match("(%.[^.]+)$") or ""
  return EXT_TO_LANG[ext] or "unknown"
end

--------------------------------------------------------------------
-- Static analysis: per-file checks
--------------------------------------------------------------------

--- Read file lines. Returns lines array or nil.
local function read_lines(filepath)
  local cwd = vim.fn.getcwd()
  local full = filepath:sub(1, 1) == "/" and filepath or (cwd .. "/" .. filepath)
  local f = io.open(full, "r")
  if not f then return nil end
  local content = f:read("*a"); f:close()
  return vim.split(content, "\n", { plain = true })
end

--- Count nesting depth at a line (braces/indentation).
local function nesting_at(line)
  local indent = #(line:match("^(%s*)") or "")
  -- Use indent as proxy: each 2/4 spaces = 1 level
  local tab_size = line:match("^\t") and 1 or (indent > 0 and (line:match("^    ") and 4 or 2) or 2)
  return math.floor(indent / tab_size)
end

--- Analyze functions in a file using treesitter.
--- Returns list of { name, start_line, end_line, line_count, max_nesting, param_count }
local function analyze_functions_ts(filepath)
  local cwd = vim.fn.getcwd()
  local full = filepath:sub(1, 1) == "/" and filepath or (cwd .. "/" .. filepath)
  local f_handle = io.open(full, "r")
  if not f_handle then return {} end
  local source = f_handle:read("*a"); f_handle:close()

  local ft = vim.filetype.match({ filename = full }) or ""
  local lang = vim.treesitter.language.get_lang(ft)
  if not lang then return {} end

  local ok, parser = pcall(vim.treesitter.get_string_parser, source, lang)
  if not ok or not parser then return {} end

  local tree = parser:parse()[1]
  if not tree then return {} end

  local root = tree:root()
  local lines = vim.split(source, "\n", { plain = true })
  local results = {}

  local FUNC_NODES = {
    function_declaration = true, function_definition = true,
    method_definition = true, method_declaration = true,
    function_item = true, function_statement = true,
    arrow_function = true, func_literal = true,
  }

  local function walk(node, depth)
    for child in node:iter_children() do
      local ctype = child:type()
      if FUNC_NODES[ctype] then
        local sr, _, er, _ = child:range()
        local line_count = er - sr + 1
        local sig_line = lines[sr + 1] or ""

        -- Extract function name (best effort)
        local name = sig_line:match("function%s+([%w_%.]+)")
          or sig_line:match("func%s+[%(%w%*%s%)]*([%w_]+)")
          or sig_line:match("def%s+([%w_]+)")
          or sig_line:match("fn%s+([%w_]+)")
          or sig_line:match("([%w_]+)%s*[:=]%s*function")
          or sig_line:match("([%w_]+)%s*[:=]%s*%(")
          or sig_line:match("([%w_]+)%s*[:=]%s*async")
          or "(anonymous)"

        -- Count params (rough: count commas + 1 inside first parens)
        local params_str = sig_line:match("%((.-)%)") or ""
        local param_count = 0
        if vim.trim(params_str) ~= "" then
          param_count = 1
          for _ in params_str:gmatch(",") do param_count = param_count + 1 end
        end

        -- Max nesting within function body
        local max_nest = 0
        local base_nest = nesting_at(lines[sr + 1] or "")
        for i = sr + 1, er + 1 do
          if lines[i] then
            local nest = nesting_at(lines[i]) - base_nest
            if nest > max_nest then max_nest = nest end
          end
        end

        results[#results + 1] = {
          name = name,
          start_line = sr + 1,
          end_line = er + 1,
          line_count = line_count,
          max_nesting = max_nest,
          param_count = param_count,
        }

        walk(child, depth + 1)
      else
        walk(child, depth)
      end
    end
  end

  walk(root, 0)
  return results
end

--- Check a file for hardcoded secrets.
local function check_secrets(filepath, lines)
  local findings = {}
  for i, line in ipairs(lines) do
    local lower = line:lower()
    for _, pat in ipairs(SECRET_PATTERNS) do
      if lower:match(pat.pat) then
        findings[#findings + 1] = {
          severity = SEV.CRITICAL,
          category = "security",
          file = filepath,
          line = i,
          message = pat.label,
          snippet = vim.trim(line):sub(1, 80),
        }
      end
    end
  end
  return findings
end

--- Check a file for swallowed errors.
local function check_errors(filepath, lines, lang)
  local findings = {}
  local content = table.concat(lines, "\n")
  for _, pat in ipairs(SWALLOWED_ERROR_PATTERNS) do
    if pat.lang == lang or pat.lang == "generic" then
      -- Find all occurrences
      local search_pos = 1
      while true do
        local s, e = content:find(pat.pat, search_pos)
        if not s then break end
        -- Convert byte position to line number
        local line_num = 1
        for _ in content:sub(1, s):gmatch("\n") do line_num = line_num + 1 end
        findings[#findings + 1] = {
          severity = SEV.CRITICAL,
          category = "error-handling",
          file = filepath,
          line = line_num,
          message = pat.label,
          snippet = vim.trim(lines[line_num] or ""):sub(1, 80),
        }
        search_pos = e + 1
      end
    end
  end
  return findings
end

--- Check for test coverage: does this source file have a corresponding test file?
local function check_test_coverage(filepath)
  local cwd = vim.fn.getcwd()
  local base = filepath:match("([^/]+)$") or filepath
  local dir = filepath:match("^(.+)/") or ""
  local name, ext = base:match("^(.+)(%.[^.]+)$")
  if not name then return nil end

  -- Common test file patterns
  local test_patterns = {
    dir .. "/" .. name .. "_test" .. ext,        -- Go: foo_test.go
    dir .. "/" .. name .. ".test" .. ext,         -- JS: foo.test.ts
    dir .. "/" .. name .. ".spec" .. ext,         -- JS: foo.spec.ts
    dir .. "/__tests__/" .. name .. ext,          -- JS: __tests__/foo.ts
    dir .. "/test_" .. name .. ext,               -- Python: test_foo.py
    "tests/" .. name .. "_test" .. ext,           -- tests/foo_test.go
    "test/" .. name .. "_test" .. ext,            -- test/foo_test.go
    "spec/" .. name .. "_spec" .. ext,            -- Ruby: spec/foo_spec.rb
  }

  for _, test_path in ipairs(test_patterns) do
    local full = cwd .. "/" .. test_path
    local f = io.open(full, "r")
    if f then f:close(); return nil end  -- test file exists, no finding
  end

  return {
    severity = SEV.INFO,
    category = "test-coverage",
    file = filepath,
    line = 1,
    message = "no test file found",
    snippet = "expected: " .. name .. "_test" .. ext .. " or " .. name .. ".test" .. ext,
  }
end

--- Find code duplication within a set of files.
--- Returns findings for blocks of MIN_DUPLICATION_LEN+ identical consecutive lines.
--- Skips structural noise (imports, pragmas, error checks, assertions).
--- Deduplicates: reports each unique block once with all locations.
local function check_duplication(files_with_lines)
  local findings = {}

  -- Check if a line is structural noise that shouldn't count for duplication
  local function is_skip_line(line)
    local trimmed = vim.trim(line)
    if #trimmed <= 10 then return true end
    if trimmed:match("^[%s{}%(%)%[%];,]$") then return true end
    for _, pat in ipairs(DUPLICATION_SKIP_PATTERNS) do
      if trimmed:match(pat) then return true end
    end
    return false
  end

  -- Build normalized content per file: only meaningful lines, with original line numbers
  -- Each entry: { orig_line = N, content = "trimmed line" }
  local file_meaningful = {}
  for filepath, lines in pairs(files_with_lines) do
    local meaningful = {}
    for i, line in ipairs(lines) do
      if not is_skip_line(line) then
        meaningful[#meaningful + 1] = { orig_line = i, content = vim.trim(line) }
      end
    end
    file_meaningful[filepath] = meaningful
  end

  -- Build a hash of each meaningful line → locations
  local line_index = {}
  for filepath, meaningful in pairs(file_meaningful) do
    for idx, entry in ipairs(meaningful) do
      local hash = entry.content
      if not line_index[hash] then line_index[hash] = {} end
      line_index[hash][#line_index[hash] + 1] = {
        file = filepath, orig_line = entry.orig_line, meaningful_idx = idx,
      }
    end
  end

  -- Find consecutive matching blocks using meaningful-line indices.
  -- Track unique blocks by their content fingerprint to avoid reporting the same block N² times.
  local reported_blocks = {}  -- fingerprint → { locations = { {file, line}, ... }, length = N }

  for _, locs in pairs(line_index) do
    if #locs < 2 then goto continue end

    for a = 1, #locs do
      for b = a + 1, #locs do
        local la, lb = locs[a], locs[b]
        -- Skip same-file matches that are close together (overlapping)
        if la.file == lb.file and math.abs(la.meaningful_idx - lb.meaningful_idx) < MIN_DUPLICATION_LEN then
          goto next_pair
        end

        -- Count consecutive meaningful-line matches
        local ma = file_meaningful[la.file]
        local mb = file_meaningful[lb.file]
        local count = 0
        while la.meaningful_idx + count <= #ma
          and lb.meaningful_idx + count <= #mb
          and ma[la.meaningful_idx + count].content == mb[lb.meaningful_idx + count].content do
          count = count + 1
        end

        if count >= MIN_DUPLICATION_LEN then
          -- Build a content fingerprint from the first few lines
          local fp_parts = {}
          for k = 0, math.min(3, count - 1) do
            fp_parts[#fp_parts + 1] = ma[la.meaningful_idx + k].content:sub(1, 40)
          end
          local fingerprint = table.concat(fp_parts, "|")

          if not reported_blocks[fingerprint] then
            reported_blocks[fingerprint] = {
              locations = {},
              length = count,
              snippet = ma[la.meaningful_idx].content:sub(1, 60),
            }
          end
          -- Add both locations (deduplicated by file:line)
          local block = reported_blocks[fingerprint]
          local function add_loc(file, line)
            for _, existing in ipairs(block.locations) do
              if existing.file == file and existing.line == line then return end
            end
            block.locations[#block.locations + 1] = { file = file, line = line }
          end
          add_loc(la.file, ma[la.meaningful_idx].orig_line)
          add_loc(lb.file, mb[lb.meaningful_idx].orig_line)
        end

        ::next_pair::
      end
    end

    ::continue::
  end

  -- Convert deduplicated blocks to findings (one per unique block)
  for _, block in pairs(reported_blocks) do
    if #block.locations >= 2 then
      -- Report on the first location, mention all others
      local primary = block.locations[1]
      local others = {}
      for i = 2, #block.locations do
        others[#others + 1] = string.format("%s:%d", block.locations[i].file, block.locations[i].line)
      end

      findings[#findings + 1] = {
        severity = SEV.WARN,
        category = "duplication",
        file = primary.file,
        line = primary.line,
        message = string.format("%d duplicated lines across %d locations (also at %s)",
          block.length, #block.locations, table.concat(others, ", ")),
        snippet = block.snippet .. " …",
      }
    end
  end

  return findings
end

--------------------------------------------------------------------
-- Phase 1: Full static analysis for a feature
--------------------------------------------------------------------

--- Run all static checks on a set of files.
--- Returns { findings = {...}, stats = {...} }
function M._static_analysis(feature_files)
  local all_findings = {}
  local stats = {
    files = 0, functions = 0,
    long_functions = 0, deep_functions = 0, many_params = 0,
    secrets = 0, error_issues = 0, no_tests = 0, duplication = 0,
  }

  local files_with_lines = {}

  for _, file_info in ipairs(feature_files) do
    local filepath = file_info.path
    local lines = read_lines(filepath)
    if lines then
      stats.files = stats.files + 1
      files_with_lines[filepath] = lines
      local lang = detect_lang(filepath)

      -- 1. Function analysis (treesitter)
      local funcs = analyze_functions_ts(filepath)
      for _, fn in ipairs(funcs) do
        stats.functions = stats.functions + 1

        if fn.line_count > MAX_FUNCTION_LINES then
          stats.long_functions = stats.long_functions + 1
          all_findings[#all_findings + 1] = {
            severity = SEV.WARN,
            category = "complexity",
            file = filepath,
            line = fn.start_line,
            message = string.format("function '%s' is %d lines (max %d)",
              fn.name, fn.line_count, MAX_FUNCTION_LINES),
            snippet = fn.name,
          }
        end

        if fn.max_nesting > MAX_NESTING_DEPTH then
          stats.deep_functions = stats.deep_functions + 1
          all_findings[#all_findings + 1] = {
            severity = SEV.WARN,
            category = "complexity",
            file = filepath,
            line = fn.start_line,
            message = string.format("function '%s' has nesting depth %d (max %d)",
              fn.name, fn.max_nesting, MAX_NESTING_DEPTH),
            snippet = fn.name,
          }
        end

        if fn.param_count > MAX_PARAMS then
          stats.many_params = stats.many_params + 1
          all_findings[#all_findings + 1] = {
            severity = SEV.INFO,
            category = "clean-code",
            file = filepath,
            line = fn.start_line,
            message = string.format("function '%s' has %d parameters (max %d)",
              fn.name, fn.param_count, MAX_PARAMS),
            snippet = fn.name,
          }
        end
      end

      -- 2. Hardcoded secrets
      local secrets = check_secrets(filepath, lines)
      stats.secrets = stats.secrets + #secrets
      for _, s in ipairs(secrets) do all_findings[#all_findings + 1] = s end

      -- 3. Swallowed errors
      local errors = check_errors(filepath, lines, lang)
      stats.error_issues = stats.error_issues + #errors
      for _, e in ipairs(errors) do all_findings[#all_findings + 1] = e end

      -- 4. Test coverage
      -- Skip test files themselves
      if not filepath:match("_test%.") and not filepath:match("%.test%.")
        and not filepath:match("%.spec%.") and not filepath:match("test_")
        and not filepath:match("__tests__/") then
        local missing = check_test_coverage(filepath)
        if missing then
          stats.no_tests = stats.no_tests + 1
          all_findings[#all_findings + 1] = missing
        end
      end
    end
  end

  -- 5. Cross-file duplication
  local dupes = check_duplication(files_with_lines)
  stats.duplication = #dupes
  for _, d in ipairs(dupes) do all_findings[#all_findings + 1] = d end

  -- Sort by severity then file then line
  table.sort(all_findings, function(a, b)
    if a.severity.sort ~= b.severity.sort then return a.severity.sort < b.severity.sort end
    if a.file ~= b.file then return a.file < b.file end
    return a.line < b.line
  end)

  return { findings = all_findings, stats = stats }
end

--------------------------------------------------------------------
-- Phase 2: Agentic deep review (reads files, runs tests, verifies)
--------------------------------------------------------------------

--- Build the agentic audit prompt.
--- Gives the agent static analysis findings + file list and instructs it
--- to read files, run tests, verify findings, and produce structured output.
local function build_audit_prompt(feature_name, feature_files, static_result)
  local lang = require("dwight.languages")
  local detected = lang.detect()
  local test_cmd = lang.test_cmd(detected) or "run tests"
  local coverage = lang.coverage_cmd(detected)

  -- Format static findings as context
  local finding_lines = {}
  for _, f in ipairs(static_result.findings) do
    finding_lines[#finding_lines + 1] = string.format(
      "- %s [%s] %s:%d — %s",
      f.severity.icon, f.category, f.file, f.line, f.message)
  end

  -- Format file list
  local file_list = {}
  for _, fi in ipairs(feature_files) do
    file_list[#file_list + 1] = "  " .. fi.path
  end

  local parts = {}

  parts[#parts + 1] = string.format([[
You are a senior engineer performing a deep code audit of the "$%s" feature.

## Files in this feature
%s

## Static Analysis Results (%d findings)
%s

## Your Task

Perform a thorough audit by doing the following IN ORDER:

### Step 1: Read ALL source files
Read every file listed above. Understand the architecture, data flow, and dependencies.

### Step 2: Run tests and coverage
Run the test suite: `%s`
]], feature_name,
    table.concat(file_list, "\n"),
    #static_result.findings,
    #finding_lines > 0 and table.concat(finding_lines, "\n") or "(none)",
    test_cmd)

  if coverage then
    parts[#parts + 1] = string.format("Run coverage: `%s`\n", coverage.cmd)
  end

  parts[#parts + 1] = [[
### Step 3: Verify static analysis findings
For each finding above, read the actual code and determine:
- Is this a true positive? Explain WHY the code is problematic.
- Is this a false positive? Mark it as such with a reason.

### Step 4: Find NEW issues the static analysis missed
Look for:
- Logic errors and edge cases
- Race conditions or concurrency issues
- Missing input validation
- API contract violations
- Resource leaks (unclosed files, connections)
- Security vulnerabilities
- Dead code or unreachable branches
- Missing error handling that static analysis couldn't detect
- Inconsistencies with the rest of the codebase

### Step 5: Write structured output
Write your findings to `.dwight/artifacts/audit-result.json` in this EXACT format:
```json
{
  "verified": [
    {"file": "path/to/file.go", "line": 42, "severity": "CRITICAL|WARN|INFO", "category": "category", "message": "description", "fix": "suggested fix"}
  ],
  "false_positives": [
    {"file": "path/to/file.go", "line": 42, "reason": "why this is not an issue"}
  ],
  "new_findings": [
    {"file": "path/to/file.go", "line": 42, "severity": "CRITICAL|WARN|INFO", "category": "category", "message": "description", "fix": "suggested fix"}
  ],
  "test_results": {
    "passed": true,
    "output_summary": "brief summary of test output",
    "coverage_pct": 85.2
  },
  "summary": "2-3 sentence overall assessment"
}
```

IMPORTANT:
- `mkdir -p .dwight/artifacts` before writing
- Use EXACT field names. "fix" should be a specific, actionable suggestion with the code change needed.
- The "line" field must be the actual line number in the current file, not the line from static analysis.
- Do NOT create any other files. Do NOT modify source code. This is READ-ONLY audit.
]]

  return table.concat(parts, "\n")
end

--- Parse the agent's structured audit output from .dwight/artifacts/audit-result.json
--- Returns { verified, false_positives, new_findings, test_results, summary } or nil
local function parse_agent_audit_result()
  local project = require("dwight.project")
  if not project.is_initialized() then return nil end

  local path = project.dir() .. "/artifacts/audit-result.json"
  local file = io.open(path, "r")
  if not file then return nil end
  local raw = file:read("*a"); file:close()

  -- Clean up — remove the file after reading
  os.remove(path)

  local ok, data = pcall(vim.json.decode, raw)
  if not ok or type(data) ~= "table" then return nil end
  return data
end

--- Merge agentic results into static analysis result.
--- Removes false positives, updates verified findings with fixes, adds new findings.
local function merge_agent_results(static_result, agent_data)
  if not agent_data then return static_result end

  -- Index false positives by file:line for fast lookup
  local fp_set = {}
  for _, fp in ipairs(agent_data.false_positives or {}) do
    local key = (fp.file or "") .. ":" .. (fp.line or 0)
    fp_set[key] = fp.reason or "agent verified as false positive"
  end

  -- Index verified findings by file:line for fix suggestions
  local verified_map = {}
  for _, v in ipairs(agent_data.verified or {}) do
    local key = (v.file or "") .. ":" .. (v.line or 0)
    verified_map[key] = v
  end

  -- Filter false positives from static findings, enrich verified ones
  local filtered = {}
  for _, f in ipairs(static_result.findings) do
    local key = f.file .. ":" .. f.line
    if fp_set[key] then
      -- Skip false positive (but count it)
    else
      -- Check if agent verified and has a fix suggestion
      local v = verified_map[key]
      if v then
        f.agent_verified = true
        if v.fix and v.fix ~= "" then
          f.fix = v.fix
        end
        -- Agent may have re-categorized severity
        if v.severity and SEV[v.severity] then
          f.severity = SEV[v.severity]
        end
      end
      filtered[#filtered + 1] = f
    end
  end

  -- Add new findings from the agent
  for _, nf in ipairs(agent_data.new_findings or {}) do
    filtered[#filtered + 1] = {
      severity = SEV[nf.severity] or SEV.WARN,
      category = nf.category or "agent-finding",
      file = nf.file or "",
      line = tonumber(nf.line) or 0,
      message = nf.message or "",
      fix = nf.fix,
      snippet = "",
      agent_verified = true,
    }
  end

  -- Re-sort
  table.sort(filtered, function(a, b)
    if a.severity.sort ~= b.severity.sort then return a.severity.sort < b.severity.sort end
    if a.file ~= b.file then return a.file < b.file end
    return a.line < b.line
  end)

  -- Update stats
  static_result.findings = filtered
  static_result.agent_review = {
    verified = #(agent_data.verified or {}),
    false_positives = #(agent_data.false_positives or {}),
    new_findings = #(agent_data.new_findings or {}),
    test_results = agent_data.test_results,
    summary = agent_data.summary,
  }

  return static_result
end

--- Run agentic deep audit on a feature.
--- callback(result) called when done.
function M._agentic_review(feature_name, feature_files, static_result, callback)
  local agentic = require("dwight.agentic")
  local status_mod = require("dwight.agent_status")

  status_mod.open()
  status_mod.start_session("🔍 Deep audit: $" .. feature_name)
  status_mod.append("🔍 Agentic deep audit: $" .. feature_name)
  status_mod.append(string.format("   %d files, %d static findings to verify",
    #feature_files, #static_result.findings))
  status_mod.append("🤖 Starting agent session...")

  local task = build_audit_prompt(feature_name, feature_files, static_result)

  local tool_counts = { read = 0, write = 0, run = 0 }

  agentic.run({
    task = task,

    on_status = function(text)
      status_mod.stop_spin()
      status_mod.append(text)
    end,

    on_tool = function(desc)
      local tt = desc:match("^📖") and "read"
        or desc:match("^📝") and "write"
        or desc:match("^🔧 run") and "run"
        or desc:match("^🔍") and "search"
        or "other"
      tool_counts[tt] = (tool_counts[tt] or 0) + 1

      local should_persist = tt == "write" or tt == "run" or tt == "search"
        or (tt == "read" and (tool_counts.read == 1 or tool_counts.read % 3 == 0))
      if should_persist then
        status_mod.stop_spin()
        status_mod.append(desc)
      end
      status_mod.spin(desc)
    end,

    on_complete = function(success, _data)
      status_mod.stop_spin()

      if not success then
        status_mod.append("❌ Agentic audit failed")
        callback(static_result)
        return
      end

      -- Parse structured output
      local agent_data = parse_agent_audit_result()
      if not agent_data then
        status_mod.append("⚠️  Agent did not produce structured output — showing static results only")
        callback(static_result)
        return
      end

      -- Merge agent results
      local merged = merge_agent_results(static_result, agent_data)

      local review = merged.agent_review or {}
      status_mod.append("")
      status_mod.append("✅ Deep audit complete:")
      status_mod.append(string.format("   Verified: %d  │  False positives: %d  │  New: %d",
        review.verified or 0, review.false_positives or 0, review.new_findings or 0))

      if review.test_results then
        local tr = review.test_results
        local status_icon = tr.passed and "✅" or "❌"
        local cov_str = tr.coverage_pct and string.format(" │ Coverage: %.1f%%", tr.coverage_pct) or ""
        status_mod.append(string.format("   Tests: %s%s", status_icon, cov_str))
      end

      if review.summary then
        status_mod.append("   " .. (review.summary or ""):sub(1, 200))
      end

      callback(merged)
    end,
  })
end

--------------------------------------------------------------------
-- Report generation and display
--------------------------------------------------------------------

--- Build report lines for display buffer.
function M._build_report_lines(feature_name, result)
  local findings = result.findings
  local stats = result.stats
  local lines = {}

  -- Header
  lines[#lines + 1] = "╔══════════════════════════════════════════════════════════════╗"
  lines[#lines + 1] = string.format("║  DwightAudit: $%s", feature_name)
  lines[#lines + 1] = "╚══════════════════════════════════════════════════════════════╝"
  lines[#lines + 1] = ""

  -- Stats
  lines[#lines + 1] = string.format("  Files: %d  │  Functions: %d  │  Findings: %d",
    stats.files, stats.functions, #findings)
  lines[#lines + 1] = string.format("  🔴 Critical: %d  │  🟡 Warnings: %d  │  🔵 Info: %d",
    stats.secrets + stats.error_issues,
    stats.long_functions + stats.deep_functions + stats.duplication,
    stats.many_params + stats.no_tests)

  -- Agent review stats (if available)
  local review = result.agent_review
  if review then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "  ─── Agent Deep Review ───"
    lines[#lines + 1] = string.format("  Verified: %d  │  False positives removed: %d  │  New findings: %d",
      review.verified or 0, review.false_positives or 0, review.new_findings or 0)

    if review.test_results then
      local tr = review.test_results
      local status_icon = tr.passed and "✅" or "❌"
      local cov_str = tr.coverage_pct and string.format("  │  Coverage: %.1f%%", tr.coverage_pct) or ""
      lines[#lines + 1] = string.format("  Tests: %s %s%s",
        status_icon, (tr.output_summary or ""):sub(1, 60), cov_str)
    end

    if review.summary then
      lines[#lines + 1] = ""
      lines[#lines + 1] = "  📝 " .. (review.summary or "")
    end
  end

  lines[#lines + 1] = ""

  if #findings == 0 then
    lines[#lines + 1] = "  ✅ No issues found. This feature looks clean."
    lines[#lines + 1] = ""
    return lines
  end

  lines[#lines + 1] = "  ─── Findings (sorted by severity) ───"
  lines[#lines + 1] = ""

  -- Finding lines — each finding gets a data line we can use for keybindings
  local current_file = ""
  for i, f in ipairs(findings) do
    if f.file ~= current_file then
      current_file = f.file
      lines[#lines + 1] = ""
      lines[#lines + 1] = string.format("  📄 %s", current_file)
    end

    local verified = f.agent_verified and " ✓agent" or (f.llm_reviewed and " ✓" or "")
    lines[#lines + 1] = string.format("  %s [%s] L%d: %s%s",
      f.severity.icon, f.category, f.line, f.message, verified)

    if f.snippet and f.snippet ~= "" then
      lines[#lines + 1] = string.format("      │ %s", f.snippet)
    end

    -- Show fix suggestion if agent provided one
    if f.fix and f.fix ~= "" then
      -- Wrap fix text to ~70 chars
      local fix_text = f.fix:gsub("\n", " "):sub(1, 200)
      lines[#lines + 1] = string.format("      💡 Fix: %s", fix_text)
    end

    -- Marker for keybinding lookup
    lines[#lines + 1] = string.format("      [%d] <CR>=goto  h=heal  i=ignore", i)
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "  ─── Keybindings ───"
  lines[#lines + 1] = "  <CR>  Jump to file:line"
  lines[#lines + 1] = "  h     Start DwightHeal for this finding"
  lines[#lines + 1] = "  H     Start DwightHeal for entire feature"
  lines[#lines + 1] = "  i     Ignore this finding"
  lines[#lines + 1] = "  a     Run agentic deep review (reads code, runs tests)"
  lines[#lines + 1] = "  q     Close"

  return lines
end

--- Find which finding index a buffer line corresponds to.
local function finding_at_cursor(buf_lines, cursor_line)
  -- Walk backwards from cursor to find the nearest [N] marker
  for i = cursor_line, math.max(1, cursor_line - 5), -1 do
    local line = buf_lines[i] or ""
    local idx = line:match("%[(%d+)%]%s*<CR>")
    if idx then return tonumber(idx) end
  end
  return nil
end

--- Show the audit report in a floating buffer with keybindings.
function M._show_report(feature_name, result)
  local report_lines = M._build_report_lines(feature_name, result)

  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, _flatten(report_lines))
  vim.bo[buf].modifiable = false
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "dwight_audit"

  -- Open as a split (not float — report can be long)
  vim.cmd("botright split")
  local win = api.nvim_get_current_win()
  api.nvim_win_set_buf(win, buf)
  api.nvim_win_set_height(win, math.min(#report_lines + 2, math.floor(vim.o.lines * 0.5)))

  -- Store state for keybindings
  vim.b[buf] = vim.b[buf] or {}
  api.nvim_buf_set_var(buf, "dwight_audit_feature", feature_name)
  api.nvim_buf_set_var(buf, "dwight_audit_result", result)

  -- Keybindings
  local function get_finding()
    local cursor = api.nvim_win_get_cursor(win)
    local idx = finding_at_cursor(report_lines, cursor[1])
    if not idx or not result.findings[idx] then
      vim.notify("[dwight] No finding at cursor", vim.log.levels.WARN)
      return nil
    end
    return result.findings[idx], idx
  end

  --- Close audit window safely (handles last-window case).
  --- If this is the last window, replace buffer instead of closing.
  local function safe_close()
    local wins = api.nvim_tabpage_list_wins(0)
    if #wins <= 1 then
      -- Can't close the last window — switch to an empty buffer
      vim.cmd("enew")
    else
      api.nvim_win_close(win, true)
    end
  end

  -- <CR> Jump to file:line
  vim.keymap.set("n", "<CR>", function()
    local f = get_finding()
    if not f then return end
    safe_close()
    vim.cmd("edit " .. vim.fn.fnameescape(f.file))
    pcall(api.nvim_win_set_cursor, 0, { f.line, 0 })
    vim.cmd("normal! zz")
  end, { buffer = buf, desc = "Jump to finding" })

  -- h: Heal single finding
  vim.keymap.set("n", "h", function()
    local f = get_finding()
    if not f then return end
    safe_close()
    require("dwight.codebase_heal").heal_finding(feature_name, f)
  end, { buffer = buf, desc = "Heal this finding" })

  -- H: Heal entire feature
  vim.keymap.set("n", "H", function()
    safe_close()
    require("dwight.codebase_heal").heal(feature_name, { findings = result.findings })
  end, { buffer = buf, desc = "Heal entire feature" })

  -- i: Ignore finding
  vim.keymap.set("n", "i", function()
    local f, idx = get_finding()
    if not f then return end
    table.remove(result.findings, idx)
    -- Refresh report
    local new_lines = M._build_report_lines(feature_name, result)
    vim.bo[buf].modifiable = true
    api.nvim_buf_set_lines(buf, 0, -1, false, _flatten(new_lines))
    vim.bo[buf].modifiable = false
    report_lines = new_lines
    vim.notify(string.format("[dwight] Ignored: %s", f.message), vim.log.levels.INFO)
  end, { buffer = buf, desc = "Ignore finding" })

  -- a: Agentic deep review
  vim.keymap.set("n", "a", function()
    local feat = feature_name
    safe_close()
    M.audit(feat, { agentic = true })
  end, { buffer = buf, desc = "Agentic deep review" })

  -- q: Close
  vim.keymap.set("n", "q", function()
    safe_close()
  end, { buffer = buf, desc = "Close" })

  -- Populate quickfix with findings
  if #result.findings > 0 then
    local qf_items = {}
    local cwd = vim.fn.getcwd()
    for _, f in ipairs(result.findings) do
      local fix_text = ""
      if f.fix then fix_text = " 💡 " .. f.fix:gsub("\n", " "):sub(1, 100) end
      qf_items[#qf_items + 1] = {
        filename = f.file:match("^/") and f.file or (cwd .. "/" .. f.file),
        lnum = f.line,
        col = 1,
        type = f.severity.sort == 1 and "E" or (f.severity.sort == 2 and "W" or "I"),
        text = string.format("[%s] %s%s", f.category, f.message, fix_text),
      }
    end
    vim.fn.setqflist(qf_items, "r")
    vim.fn.setqflist({}, "a", {
      title = string.format("DwightAudit: $%s — %d finding(s)", feature_name, #qf_items),
    })
  end

  return buf
end

--------------------------------------------------------------------
-- Save/load audit results
--------------------------------------------------------------------

--- Save audit result to .dwight/audits/feature-name.json
local AUDIT_VERSION = 3

function M._save_audit(feature_name, result)
  local project = require("dwight.project")
  if not project.is_initialized() then return end

  local dir = project.dir() .. "/audits"
  vim.fn.mkdir(dir, "p")

  -- Serialize findings (convert severity refs to strings)
  local serializable = {
    version = AUDIT_VERSION,
    timestamp = os.time(),
    stats = result.stats,
    agent_review = result.agent_review,
    findings = {},
  }
  for _, f in ipairs(result.findings) do
    serializable.findings[#serializable.findings + 1] = {
      severity = f.severity.label,
      category = f.category,
      file = f.file,
      line = f.line,
      message = f.message,
      snippet = f.snippet or "",
      fix = f.fix,
      agent_verified = f.agent_verified or false,
      llm_reviewed = f.llm_reviewed or false,
    }
  end

  local path = dir .. "/" .. feature_name .. ".json"
  local file = io.open(path, "w")
  if file then
    file:write(vim.json.encode(serializable))
    file:close()
  end
end

--- Load saved audit result.
--- Returns nil if not found, wrong version, or too old (>7 days).
function M._load_audit(feature_name)
  local project = require("dwight.project")
  if not project.is_initialized() then return nil end

  local path = project.dir() .. "/audits/" .. feature_name .. ".json"
  local file = io.open(path, "r")
  if not file then return nil end
  local raw = file:read("*a"); file:close()

  local ok, data = pcall(vim.json.decode, raw)
  if not ok then return nil end

  -- Version check: discard audits from old format
  if (data.version or 0) < AUDIT_VERSION then
    vim.notify(string.format(
      "[dwight] ⚠️ Cached audit for $%s is from an older version — re-run :DwightAudit",
      feature_name), vim.log.levels.WARN)
    return nil
  end

  -- Staleness check: warn if older than 7 days
  if data.timestamp and (os.time() - data.timestamp) > 7 * 86400 then
    vim.notify(string.format(
      "[dwight] ⚠️ Cached audit for $%s is %d days old — consider re-running :DwightAudit",
      feature_name, math.floor((os.time() - data.timestamp) / 86400)),
      vim.log.levels.WARN)
  end

  -- Reconstitute severity references
  local sev_map = { CRITICAL = SEV.CRITICAL, WARN = SEV.WARN, INFO = SEV.INFO }
  for _, f in ipairs(data.findings or {}) do
    f.severity = sev_map[f.severity] or SEV.WARN
  end

  -- Carry over agent_review if present
  data.agent_review = data.agent_review or nil

  return data
end

--------------------------------------------------------------------
-- Main entry: :DwightAudit [feature-name]
--------------------------------------------------------------------

--- Run audit on a feature. Options:
---   agentic = true   → run Phase 2 agentic deep review after static analysis
function M.audit(feature_name, opts)
  opts = opts or {}
  local features = require("dwight.features")

  -- If no feature name, let user pick
  if not feature_name or feature_name == "" then
    local names = features.names()
    if #names == 0 then
      vim.notify("[dwight] No features found. Tag your code with @feature:name pragmas first.", vim.log.levels.WARN)
      return
    end

    require("dwight.select").pick(names, { prompt = "Audit which feature?" }, function(choice)
      if choice then M.audit(choice, opts) end
    end)
    return
  end

  -- Build feature (gets file list)
  local feature = features.build_feature(feature_name)
  if not feature then
    vim.notify(string.format("[dwight] Feature '%s' not found.", feature_name), vim.log.levels.ERROR)
    return
  end

  vim.notify(string.format("[dwight] 🔍 Auditing $%s (%d files)…",
    feature_name, #feature.files), vim.log.levels.INFO)

  -- Phase 1: Static analysis (always runs — fast, free)
  local result = M._static_analysis(feature.files)

  vim.notify(string.format("[dwight] 🔍 Static analysis: %d findings across %d files, %d functions.",
    #result.findings, result.stats.files, result.stats.functions), vim.log.levels.INFO)

  -- Phase 2: Agentic deep review (optional)
  if opts.agentic then
    vim.notify(string.format("[dwight] 🤖 Starting agentic deep review on $%s…", feature_name),
      vim.log.levels.INFO)

    M._agentic_review(feature_name, feature.files, result, function(merged_result)
      M._save_audit(feature_name, merged_result)
      M._show_report(feature_name, merged_result)
    end)
    return  -- async path
  end

  -- Sync path (static only)
  M._save_audit(feature_name, result)
  M._show_report(feature_name, result)
end

return M
