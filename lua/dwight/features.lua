-- dwight/features.lua  (v2 — code-driven)
-- Features are defined by pragma comments in source files: // @feature:auth
-- Signatures are extracted live via treesitter. No markdown files, no cache.
-- Use $auth in prompts to inject the live feature context.
-- :DwightFeatures shows a virtual preview of what the AI sees.

local M = {}

local api = vim.api
local _flatten = require("dwight.util").flatten_lines
local uv = vim.loop or vim.uv

--------------------------------------------------------------------
-- Pragma patterns: detect @feature:name and project-level pragmas
-- Supports: //  #  --  /*  <!--  "  ;  %  (*
--------------------------------------------------------------------

-- Feature pragmas: @feature:name
local FEATURE_PATTERN = "@feature:([%w_%-%.]+)"

-- Feature exclusion from docs: @feature-no-docs
local NO_DOCS_PATTERN = "@feature%-no%-docs"

-- Docs pragmas: @docs:route and @docs-title:Title
local DOCS_ROUTE_PATTERN = "@docs:([%w_%-%.%/]+)"
local DOCS_TITLE_PATTERN = "@docs%-title:%s*(.+)"

-- Project-level pragmas (no name, just a type)
local PROJECT_PRAGMAS = {
  project    = "@%s*project",
  constraint = "@%s*constraint",
  stack      = "@%s*stack",
  convention = "@%s*convention",
}

--- Check if a line is a comment.
local function is_comment(line)
  local trimmed = vim.trim(line)
  return trimmed:match("^//") or trimmed:match("^#") or trimmed:match("^%-%-")
    or trimmed:match("^/%*") or trimmed:match("^<!%-%-") or trimmed:match('^"')
    or trimmed:match("^;") or trimmed:match("^%%") or trimmed:match("^%(%*")
end

--- Check if a line contains a @feature pragma. Returns feature name or nil.
local function parse_pragma(line)
  if not is_comment(line) then return nil end
  return vim.trim(line):match(FEATURE_PATTERN)
end

--- Check if a line contains a project-level pragma. Returns pragma type or nil.
local function parse_project_pragma(line)
  if not is_comment(line) then return nil end
  local trimmed = vim.trim(line)
  for ptype, pattern in pairs(PROJECT_PRAGMAS) do
    if trimmed:match(pattern) then return ptype end
  end
  return nil
end

--- Strip comment prefix from a line.
local function strip_comment(trimmed)
  return trimmed:gsub("^//%s*", ""):gsub("^#%s*", ""):gsub("^%-%-%-?%s*", "")
    :gsub("^/%*%s*", ""):gsub("^%*/?%s*", ""):gsub("^<!%-%-", ""):gsub("%-%->$", "")
    :gsub('^"%s*', ""):gsub("^;+%s*", ""):gsub("^%%%s*", ""):gsub("^%(%*%s*", "")
end

--- Check if a line contains ANY pragma.
local function has_any_pragma(text)
  return text:match("@feature:") or text:match("@feature%-no%-docs")
    or text:match("@%s*project") or text:match("@%s*constraint")
    or text:match("@%s*stack") or text:match("@%s*convention")
    or text:match("@docs:") or text:match("@docs%-title:")
end

--- Extract the description from comments around a pragma line.
--- Reads the same line (both before AND after the pragma), plus adjacent comment lines.
--- Handles both styles:
---   // Must handle 10k users. @constraint   (description BEFORE pragma)
---   // @constraint Must handle 10k users.   (description AFTER pragma)
local function extract_description(lines, pragma_line_idx)
  local parts = {}

  -- Look backwards for consecutive comment lines above the pragma
  local i = pragma_line_idx - 1
  while i >= 1 do
    local trimmed = vim.trim(lines[i])
    if trimmed == "" then
      i = i - 1
    elseif is_comment(trimmed) or trimmed:match("^%*") then
      local text = strip_comment(trimmed)
      if has_any_pragma(text) then break end
      table.insert(parts, 1, text)
      i = i - 1
    else
      break
    end
  end

  -- Inline description on the pragma line itself
  local pragma_line = lines[pragma_line_idx]
  local stripped = strip_comment(vim.trim(pragma_line))

  -- Strategy 1: text AFTER the pragma tag (// @constraint Must handle 10k users)
  local inline = stripped:match("@feature:[%w_%-%.]+%s+(.+)")
  if not inline then
    for _, pat in pairs(PROJECT_PRAGMAS) do
      inline = stripped:match(pat .. "%s+(.+)")
      if inline then break end
    end
  end

  -- Strategy 2: text BEFORE the pragma tag (// Must handle 10k users. @constraint)
  if not inline then
    -- Remove ALL pragma tags from the line, keep whatever text remains
    local text_without_pragmas = stripped
    text_without_pragmas = text_without_pragmas:gsub("@feature:[%w_%-%.]+", "")
    for _, pat in pairs(PROJECT_PRAGMAS) do
      text_without_pragmas = text_without_pragmas:gsub(pat, "")
    end
    text_without_pragmas = text_without_pragmas:gsub("@docs:[%w_%-%.%/]+", "")
    text_without_pragmas = text_without_pragmas:gsub("@docs%-title:%s*.+", "")
    text_without_pragmas = text_without_pragmas:gsub("@feature%-no%-docs", "")
    text_without_pragmas = vim.trim(text_without_pragmas:gsub("%*/$", ""):gsub("%-%-!>$", ""))
    if text_without_pragmas ~= "" then
      inline = text_without_pragmas
    end
  end

  if inline then
    inline = vim.trim(inline:gsub("%*/$", ""):gsub("%-%-!>$", ""))
    if inline ~= "" then parts[#parts + 1] = inline end
  end

  -- Look forward for continuation comment lines
  local j = pragma_line_idx + 1
  local max_look = math.min(pragma_line_idx + 10, #lines)
  while j <= max_look do
    local trimmed = vim.trim(lines[j])
    if is_comment(trimmed) or trimmed:match("^%*") then
      local text = strip_comment(trimmed)
      if has_any_pragma(text) then break end
      if text ~= "" then parts[#parts + 1] = text end
    else
      break
    end
    j = j + 1
  end

  if #parts == 0 then return nil end
  return table.concat(parts, " ")
end

--- Extract import/require/use statements from file lines.
local function extract_dependencies(lines)
  local deps = {}
  local seen = {}
  for _, line in ipairs(lines) do
    local trimmed = vim.trim(line)
    -- JS/TS: import ... from "..."
    local mod = trimmed:match('^import.-from%s+["\']([^"\']+)["\']')
    -- Python: from X import / import X
    if not mod then mod = trimmed:match('^from%s+([%w_%.]+)%s+import') end
    if not mod then mod = trimmed:match('^import%s+([%w_%.]+)') end
    -- Go: import "..."
    if not mod then mod = trimmed:match('^import%s+["\']([^"\']+)["\']') end
    -- Rust: use ...
    if not mod then mod = trimmed:match('^use%s+([%w_:]+)') end
    -- Lua: require("...")
    if not mod then mod = trimmed:match('require%s*%(?["\']([^"\']+)["\']') end

    if mod and not seen[mod] then
      seen[mod] = true
      deps[#deps + 1] = trimmed
    end
  end
  return deps
end

--------------------------------------------------------------------
-- Scanner: find all pragmas across the project
--------------------------------------------------------------------

--- Scan a single file for all pragma types.
--- Returns features, project_pragmas, docs_pragmas, no_docs_features
local function scan_file(filepath)
  local f = io.open(filepath, "r")
  if not f then return {}, {}, {}, {} end
  local content = f:read("*a"); f:close()
  local lines = vim.split(content, "\n", { plain = true })

  local features = {}
  local proj_pragmas = {}
  local docs_pragmas = {}
  local no_docs = {}

  for i, line in ipairs(lines) do
    local trimmed = vim.trim(line)

    -- @feature:name
    local fname = parse_pragma(line)
    if fname then
      features[#features + 1] = {
        name = fname,
        filepath = filepath,
        pragma_line = i,
        description = extract_description(lines, i),
      }
    end

    -- @feature-no-docs
    if is_comment(line) and trimmed:match(NO_DOCS_PATTERN) then
      -- Find nearest feature pragma above or on same line
      local feat_name = trimmed:match(FEATURE_PATTERN)
      if not feat_name then
        -- Look backwards for the feature this belongs to
        for j = i - 1, math.max(1, i - 5), -1 do
          feat_name = vim.trim(lines[j]):match(FEATURE_PATTERN)
          if feat_name then break end
        end
      end
      if feat_name then no_docs[feat_name] = true end
    end

    -- @docs:route
    if is_comment(line) then
      local route = trimmed:match(DOCS_ROUTE_PATTERN)
      if route then
        -- Look for @docs-title on nearby lines
        local title = nil
        for j = math.max(1, i - 3), math.min(#lines, i + 3) do
          local t = vim.trim(lines[j]):match(DOCS_TITLE_PATTERN)
          if t then title = vim.trim(t:gsub("%*/$", "")); break end
        end
        docs_pragmas[#docs_pragmas + 1] = {
          route = route,
          filepath = filepath,
          pragma_line = i,
          title = title,
          description = extract_description(lines, i),
        }
      end
    end

    -- Project-level pragmas
    local ptype = parse_project_pragma(line)
    if ptype then
      proj_pragmas[#proj_pragmas + 1] = {
        pragma_type = ptype,
        filepath = filepath,
        pragma_line = i,
        description = extract_description(lines, i),
      }
    end
  end
  return features, proj_pragmas, docs_pragmas, no_docs
end

--- Scan project for all pragmas.
--- Returns all_features, all_project_pragmas, all_docs_pragmas, all_no_docs
local function scan_project()
  local cwd = vim.fn.getcwd()
  local all_features = {}
  local all_proj = {}
  local all_docs = {}
  local all_no_docs = {}

  -- Fast path: use ripgrep to find files with any pragma
  if vim.fn.executable("rg") == 1 then
    local cmd = string.format(
      "rg --no-heading -l -e '@feature:' -e '@project' -e '@constraint' -e '@stack' -e '@convention' -e '@docs:' -e '@docs-title:' -e '@feature-no-docs' --glob '!node_modules' --glob '!.git' --glob '!dist' --glob '!build' --glob '!vendor' --glob '!__pycache__' --glob '!.dwight' --glob '!docs' %s 2>/dev/null",
      vim.fn.shellescape(cwd))
    local output = vim.fn.system(cmd)
    if vim.v.shell_error ~= 0 and vim.trim(output) == "" then
      return all_features, all_proj, all_docs, all_no_docs
    end

    for filepath in output:gmatch("[^\n]+") do
      filepath = vim.trim(filepath)
      if filepath ~= "" then
        local feats, projs, docs, no_docs = scan_file(filepath)
        for _, p in ipairs(feats) do all_features[#all_features + 1] = p end
        for _, p in ipairs(projs) do all_proj[#all_proj + 1] = p end
        for _, p in ipairs(docs) do all_docs[#all_docs + 1] = p end
        for k, v in pairs(no_docs) do all_no_docs[k] = v end
      end
    end
    return all_features, all_proj, all_docs, all_no_docs
  end

  -- Slow path: walk directories
  local skip = { node_modules = true, [".git"] = true, dist = true, build = true,
                 vendor = true, [".dwight"] = true, docs = true }

  local function walk(dir)
    local handle = uv.fs_scandir(dir)
    if not handle then return end
    while true do
      local name, ftype = uv.fs_scandir_next(handle)
      if not name then break end
      if name:sub(1, 1) ~= "." and not skip[name] then
        local full = dir .. "/" .. name
        if ftype == "directory" then
          walk(full)
        elseif ftype == "file" then
          local feats, projs, docs, no_docs = scan_file(full)
          for _, p in ipairs(feats) do all_features[#all_features + 1] = p end
          for _, p in ipairs(projs) do all_proj[#all_proj + 1] = p end
          for _, p in ipairs(docs) do all_docs[#all_docs + 1] = p end
          for k, v in pairs(no_docs) do all_no_docs[k] = v end
        end
      end
    end
  end

  walk(cwd)
  return all_features, all_proj, all_docs, all_no_docs
end

--------------------------------------------------------------------
-- Feature assembly: group pragmas + extract signatures
--------------------------------------------------------------------

--- Group pragmas by feature name. Returns { name = { pragmas... } }
local function group_pragmas(pragmas)
  local groups = {}
  for _, p in ipairs(pragmas) do
    if not groups[p.name] then groups[p.name] = {} end
    groups[p.name][#groups[p.name] + 1] = p
  end
  return groups
end

--- Build full feature context for a feature name.
--- Returns { name, description, files = { { path, signatures, dependencies } } }
function M.build_feature(name)
  local feature_pragmas = scan_project()  -- only need features (first return)
  local groups = group_pragmas(feature_pragmas)
  local group = groups[name]
  if not group then return nil end

  local ts_ok, ts = pcall(require, "dwight.treesitter")
  local description_parts = {}
  local files = {}
  local cwd = vim.fn.getcwd()
  local seen_paths = {}

  for _, pragma in ipairs(group) do
    -- Collect descriptions
    if pragma.description then
      description_parts[#description_parts + 1] = pragma.description
    end

    local rel_path = pragma.filepath
    if rel_path:sub(1, #cwd + 1) == cwd .. "/" then
      rel_path = rel_path:sub(#cwd + 2)
    end

    -- Deduplicate: same file can have multiple pragma lines for one feature
    if seen_paths[rel_path] then goto continue end
    seen_paths[rel_path] = true

    -- Get treesitter minimap for this file
    local signatures = ""
    if ts_ok then
      signatures = ts.minimap(pragma.filepath) or ""
    end

    -- Get dependencies
    local f = io.open(pragma.filepath, "r")
    local deps = {}
    if f then
      local content = f:read("*a"); f:close()
      local lines = vim.split(content, "\n", { plain = true })
      deps = extract_dependencies(lines)
    end

    files[#files + 1] = {
      path = rel_path,
      signatures = signatures,
      dependencies = deps,
    }
    ::continue::
  end

  -- Deduplicate descriptions (same description from multiple pragma lines)
  local seen_descs = {}
  local unique_descs = {}
  for _, d in ipairs(description_parts) do
    if not seen_descs[d] then
      seen_descs[d] = true
      unique_descs[#unique_descs + 1] = d
    end
  end

  return {
    name = name,
    description = #unique_descs > 0 and table.concat(unique_descs, ". ") or nil,
    files = files,
  }
end

--------------------------------------------------------------------
-- LLM-optimized output: XML format
--------------------------------------------------------------------

--- Format a feature as XML for LLM consumption.
function M.format_xml(feature)
  if not feature then return nil end
  local parts = {}
  parts[#parts + 1] = string.format('<feature name="%s">', feature.name)

  if feature.description then
    parts[#parts + 1] = "  <description>" .. feature.description .. "</description>"
  end

  if #feature.files > 0 then
    parts[#parts + 1] = "  <files>"
    for _, file in ipairs(feature.files) do
      parts[#parts + 1] = string.format('    <file path="%s">', file.path)
      if file.signatures and file.signatures ~= "" then
        parts[#parts + 1] = "      <signatures>"
        parts[#parts + 1] = file.signatures
        parts[#parts + 1] = "      </signatures>"
      end
      if #file.dependencies > 0 then
        parts[#parts + 1] = "      <dependencies>"
        for _, dep in ipairs(file.dependencies) do
          parts[#parts + 1] = "        " .. dep
        end
        parts[#parts + 1] = "      </dependencies>"
      end
      parts[#parts + 1] = "    </file>"
    end
    parts[#parts + 1] = "  </files>"
  end

  parts[#parts + 1] = "</feature>"
  return table.concat(parts, "\n")
end

--- Format a feature as a compact one-liner for the auto-index.
function M.format_index_line(feature)
  if not feature then return nil end
  local desc = feature.description or "no description"
  local file_count = #feature.files
  local sig_count = 0
  for _, f in ipairs(feature.files) do
    if f.signatures then
      -- Count lines that look like signatures
      for _ in f.signatures:gmatch("[^\n]+") do sig_count = sig_count + 1 end
    end
  end
  return string.format("$%s: %s (%d files, ~%d symbols)", feature.name, desc:sub(1, 100), file_count, sig_count)
end

--------------------------------------------------------------------
-- Public API: names, list, resolve, read
--------------------------------------------------------------------

--- Get all feature names found in the project.
function M.names()
  local feature_pragmas = scan_project()
  local groups = group_pragmas(feature_pragmas)
  local names = {}
  for name in pairs(groups) do names[#names + 1] = name end
  table.sort(names)
  return names
end

function M.list()
  return M.names()
end

--- Read a feature's full XML context (used by $token resolution).
function M.read(name)
  local feature = M.build_feature(name)
  if not feature then return nil end
  return M.format_xml(feature)
end

--- Resolve feature names to { name, content } for prompt injection.
function M.resolve_many(feature_names)
  local results = {}
  for _, name in ipairs(feature_names or {}) do
    local content = M.read(name)
    if content then
      results[#results + 1] = { name = name, content = content }
    end
  end
  return results
end

--- Build a compressed feature index (one-liners for all features).
function M.build_index()
  local all_names = M.names()
  if #all_names == 0 then return nil end

  local parts = {}
  for _, name in ipairs(all_names) do
    local feature = M.build_feature(name)
    if feature then
      local line = M.format_index_line(feature)
      if line then parts[#parts + 1] = line end
    end
  end

  if #parts == 0 then return nil end
  return table.concat(parts, "\n")
end

--------------------------------------------------------------------
-- :DwightFeatures — browse features with Telescope / virtual preview
--------------------------------------------------------------------

function M.pick()
  local feature_names = M.names()
  if #feature_names == 0 then
    vim.notify("[dwight] No features found. Add // @feature:name pragmas to your source files.", vim.log.levels.INFO)
    return
  end

  local has_telescope, pickers = pcall(require, "telescope.pickers")
  if has_telescope then
    local finders = require("telescope.finders")
    local conf = require("telescope.config").values
    local actions = require("telescope.actions")
    local action_state = require("telescope.actions.state")
    local previewers = require("telescope.previewers")

    pickers.new({}, {
      prompt_title = "🏗 Dwight Features (live from code)",
      finder = finders.new_table({
        results = feature_names,
        entry_maker = function(name)
          local feature = M.build_feature(name)
          local desc = feature and feature.description or ""
          local files = feature and #feature.files or 0
          return {
            value = name,
            display = string.format("$%s — %s (%d files)", name, desc:sub(1, 60), files),
            ordinal = name .. " " .. desc,
          }
        end,
      }),
      sorter = conf.generic_sorter({}),
      previewer = previewers.new_buffer_previewer({
        define_preview = function(self, entry)
          local feature = M.build_feature(entry.value)
          if not feature then return end
          local xml = M.format_xml(feature)
          local lines = vim.split(xml or "", "\n", { plain = true })
          api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, _flatten(lines))
          vim.bo[self.state.bufnr].filetype = "xml"
        end,
      }),
      attach_mappings = function(prompt_bufnr)
        actions.select_default:replace(function()
          local sel = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if sel then M.show_virtual(sel.value) end
        end)
        return true
      end,
    }):find()
  else
    -- Native fallback
    local items = {}
    for i, name in ipairs(feature_names) do
      items[#items + 1] = string.format("%d. $%s", i, name)
    end
    vim.ui.input({ prompt = table.concat(items, " | ") .. " > " }, function(choice)
      if not choice then return end
      local idx = tonumber(choice)
      if idx and feature_names[idx] then M.show_virtual(feature_names[idx]) end
    end)
  end
end

--------------------------------------------------------------------
-- Virtual buffer: dwight://feature/name — see what the AI sees
--------------------------------------------------------------------

function M.show_virtual(name)
  local feature = M.build_feature(name)
  if not feature then
    vim.notify("[dwight] Feature '$" .. name .. "' not found in codebase.", vim.log.levels.WARN)
    return
  end

  local xml = M.format_xml(feature)
  if not xml then return end

  -- Check if buffer already exists
  local buf_name = "dwight://feature/" .. name
  for _, bufnr in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(bufnr) and api.nvim_buf_get_name(bufnr) == buf_name then
      -- Refresh content and focus
      api.nvim_buf_set_option(bufnr, "modifiable", true)
      api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(xml, "\n", { plain = true }))
      api.nvim_buf_set_option(bufnr, "modifiable", false)
      local win = vim.fn.bufwinid(bufnr)
      if win ~= -1 then api.nvim_set_current_win(win) end
      return
    end
  end

  -- Create new virtual buffer
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_name(buf, buf_name)
  api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(xml, "\n", { plain = true }))
  vim.bo[buf].filetype = "xml"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false

  vim.cmd("vsplit")
  api.nvim_win_set_buf(0, buf)
  vim.cmd("vertical resize 70")

  -- Keymap: q to close, r to refresh
  vim.keymap.set("n", "q", function()
    local win = api.nvim_get_current_win()
    api.nvim_win_close(win, true)
  end, { buffer = buf, desc = "Close feature preview" })

  vim.keymap.set("n", "r", function()
    local fresh = M.build_feature(name)
    if fresh then
      local fresh_xml = M.format_xml(fresh)
      vim.bo[buf].modifiable = true
      api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(fresh_xml or "", "\n", { plain = true }))
      vim.bo[buf].modifiable = false
      vim.notify("[dwight] Feature '$" .. name .. "' refreshed.", vim.log.levels.INFO)
    end
  end, { buffer = buf, desc = "Refresh feature preview" })
end

--------------------------------------------------------------------
-- JIT Project Context: @project, @constraint, @stack, @convention
--------------------------------------------------------------------

--- Build structured XML project context from pragmas in source code.
--- Falls back to project.md if no pragmas found.
function M.build_project_context()
  local _, proj_pragmas = scan_project()
  local feature_names = M.names()

  -- Group project pragmas by type
  local grouped = {}
  for _, p in ipairs(proj_pragmas) do
    if not grouped[p.pragma_type] then grouped[p.pragma_type] = {} end
    if p.description then
      grouped[p.pragma_type][#grouped[p.pragma_type] + 1] = p.description
    end
  end

  -- If no pragmas found, return nil (caller falls back to project.md)
  local has_pragmas = next(grouped) ~= nil
  if not has_pragmas and #feature_names == 0 then return nil end

  local parts = { "<project>" }

  if grouped.project then
    parts[#parts + 1] = "  <description>"
    parts[#parts + 1] = "    " .. table.concat(grouped.project, " ")
    parts[#parts + 1] = "  </description>"
  end

  if grouped.stack then
    parts[#parts + 1] = "  <stack>"
    for _, s in ipairs(grouped.stack) do
      parts[#parts + 1] = "    " .. s
    end
    parts[#parts + 1] = "  </stack>"
  end

  if grouped.constraint then
    parts[#parts + 1] = "  <constraints>"
    for _, c in ipairs(grouped.constraint) do
      parts[#parts + 1] = "    <constraint>" .. c .. "</constraint>"
    end
    parts[#parts + 1] = "  </constraints>"
  end

  if grouped.convention then
    parts[#parts + 1] = "  <conventions>"
    for _, c in ipairs(grouped.convention) do
      parts[#parts + 1] = "    <convention>" .. c .. "</convention>"
    end
    parts[#parts + 1] = "  </conventions>"
  end

  -- Include feature index
  if #feature_names > 0 then
    parts[#parts + 1] = "  <features>"
    for _, name in ipairs(feature_names) do
      local feature = M.build_feature(name)
      if feature then
        local desc = feature.description or "no description"
        local file_count = #feature.files
        parts[#parts + 1] = string.format('    <feature name="%s" files="%d">%s</feature>',
          name, file_count, desc:sub(1, 120))
      end
    end
    parts[#parts + 1] = "  </features>"
  end

  parts[#parts + 1] = "</project>"
  return table.concat(parts, "\n")
end

--- Preview the full project context in a virtual buffer (dwight://project).
function M.show_project_context()
  local xml = M.build_project_context()

  -- Also try project.md as fallback info
  local md_info = ""
  pcall(function()
    local scope = require("dwight.project").read_scope()
    if scope then md_info = "\n\n<!-- Fallback: project.md -->\n" .. scope end
  end)

  if not xml and md_info == "" then
    vim.notify("[dwight] No project context found. Add @project, @constraint, @stack, @convention pragmas to your code.", vim.log.levels.INFO)
    return
  end

  local content = (xml or "<!-- no pragmas found -->") .. md_info

  local buf_name = "dwight://project"
  for _, bufnr in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(bufnr) and api.nvim_buf_get_name(bufnr) == buf_name then
      vim.bo[bufnr].modifiable = true
      api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(content, "\n", { plain = true }))
      vim.bo[bufnr].modifiable = false
      local win = vim.fn.bufwinid(bufnr)
      if win ~= -1 then api.nvim_set_current_win(win) end
      return
    end
  end

  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_name(buf, buf_name)
  api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(content, "\n", { plain = true }))
  vim.bo[buf].filetype = "xml"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"

  vim.cmd("vsplit")
  api.nvim_win_set_buf(0, buf)
  vim.cmd("vertical resize 70")

  vim.keymap.set("n", "q", function()
    api.nvim_win_close(api.nvim_get_current_win(), true)
  end, { buffer = buf })

  vim.keymap.set("n", "r", function()
    local fresh = M.build_project_context()
    if fresh then
      vim.bo[buf].modifiable = true
      api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(fresh, "\n", { plain = true }))
      vim.bo[buf].modifiable = false
      vim.notify("[dwight] Project context refreshed.", vim.log.levels.INFO)
    end
  end, { buffer = buf })
end

--------------------------------------------------------------------
-- Docs API: expose docs pragmas, no-docs, structure
--------------------------------------------------------------------

--- Get all docs pragmas and no-docs exclusions.
function M.scan_docs()
  local _, _, docs_pragmas, no_docs = scan_project()
  return docs_pragmas, no_docs
end

--- Get feature names that should appear in docs (excluding @feature-no-docs).
function M.documentable_features()
  local _, _, _, no_docs = scan_project()
  local all = M.names()
  local result = {}
  for _, name in ipairs(all) do
    if not no_docs[name] then result[#result + 1] = name end
  end
  return result
end

--- Build a docs structure XML for prompt injection.
--- Lists all doc pages that exist or will be generated.
function M.build_docs_structure()
  local docs_pragmas, no_docs = M.scan_docs()
  local doc_features = M.documentable_features()

  local parts = { "<docs_structure>" }

  -- Always-generated pages
  parts[#parts + 1] = '  <page path="index.md" title="Project Documentation" always="true" />'
  parts[#parts + 1] = '  <page path="getting-started.md" title="Getting Started" always="true" />'

  -- Feature pages
  for _, name in ipairs(doc_features) do
    local feat = M.build_feature(name)
    local desc = feat and feat.description or ""
    parts[#parts + 1] = string.format('  <page path="features/%s.md" title="%s" feature="%s" />',
      name, desc:sub(1, 80):gsub('"', "'"), name)
  end

  -- @docs:route pages (grouped by route to handle merging)
  local route_groups = {}
  for _, dp in ipairs(docs_pragmas) do
    if not route_groups[dp.route] then route_groups[dp.route] = {} end
    route_groups[dp.route][#route_groups[dp.route] + 1] = dp
  end
  for route, entries in pairs(route_groups) do
    local title = entries[1].title or route:match("[^/]+$") or route
    local sources = {}
    for _, e in ipairs(entries) do
      local cwd = vim.fn.getcwd()
      local rel = e.filepath
      if rel:sub(1, #cwd + 1) == cwd .. "/" then rel = rel:sub(#cwd + 2) end
      sources[#sources + 1] = rel .. ":" .. e.pragma_line
    end
    parts[#parts + 1] = string.format('  <page path="%s.md" title="%s" source="%s" />',
      route, title:gsub('"', "'"), table.concat(sources, ", "))
  end

  -- Check existing docs/ files for user-modified content
  local docs_dir = vim.fn.getcwd() .. "/docs"
  if vim.fn.isdirectory(docs_dir) == 1 then
    local uv = vim.loop or vim.uv
    local function scan_docs_files(dir, prefix)
      local handle = uv.fs_scandir(dir)
      if not handle then return end
      while true do
        local name, ftype = uv.fs_scandir_next(handle)
        if not name then break end
        local rel = prefix ~= "" and (prefix .. "/" .. name) or name
        if ftype == "directory" then
          scan_docs_files(dir .. "/" .. name, rel)
        elseif ftype == "file" and name:match("%.md$") then
          -- Check if this page is already listed (from pragmas)
          local already = false
          for _, p in ipairs(parts) do
            if p:find(rel, 1, true) then already = true; break end
          end
          if not already then
            parts[#parts + 1] = string.format('  <page path="%s" existing="true" />', rel)
          end
        end
      end
    end
    scan_docs_files(docs_dir, "")
  end

  parts[#parts + 1] = "</docs_structure>"
  return table.concat(parts, "\n")
end

return M
