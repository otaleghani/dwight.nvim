-- dwight/split.lua
-- Split a large feature into smaller sub-features.
-- When a feature grows too big (too many files, too many symbols), the LLM
-- struggles to work with it. This module analyzes a feature and proposes a
-- logical split into 2-4 sub-features, then rewrites the @feature pragmas.
--
-- :DwightSplitFeature [name]   — analyze + propose + confirm + apply
-- :DwightSplitPreview [name]   — analyze + propose (preview only, no changes)

local M = {}

local api = vim.api
local _flatten = require("dwight.util").flatten_lines

--------------------------------------------------------------------
-- Analysis: measure feature complexity
--------------------------------------------------------------------

--- Analyze a feature's complexity.
--- Returns { name, file_count, total_lines, symbol_count, files = { ... } }
local function analyze_feature(name)
  local features = require("dwight.features")
  local feature = features.build_feature(name)
  if not feature then return nil end

  local cwd = vim.fn.getcwd()
  local total_lines = 0
  local symbol_count = 0
  local file_details = {}
  local seen_paths = {}

  for _, file in ipairs(feature.files) do
    -- Deduplicate: same file can appear multiple times if it has multiple pragma lines
    -- Normalize path: trim whitespace, remove leading ./
    local norm_path = vim.trim(file.path):gsub("^%./", "")
    if seen_paths[norm_path] then goto continue end
    seen_paths[norm_path] = true

    local full_path = norm_path
    if not full_path:match("^/") then full_path = cwd .. "/" .. full_path end

    -- Count lines
    local f = io.open(full_path, "r")
    local lines = 0
    local content = ""
    if f then
      content = f:read("*a")
      f:close()
      lines = select(2, content:gsub("\n", "\n")) + 1
    end
    total_lines = total_lines + lines

    -- Count symbols from signatures
    local sigs = file.signatures or ""
    local sig_count = 0
    for _ in sigs:gmatch("[^\n]+") do sig_count = sig_count + 1 end
    symbol_count = symbol_count + sig_count

    file_details[#file_details + 1] = {
      path = norm_path,
      full_path = full_path,
      lines = lines,
      symbols = sig_count,
      signatures = sigs,
      dependencies = file.dependencies or {},
      -- First 50 lines for LLM context (to understand what the file does)
      preview = content:sub(1, 2000),
    }
    ::continue::
  end

  return {
    name = name,
    description = feature.description,
    file_count = #file_details,
    total_lines = total_lines,
    symbol_count = symbol_count,
    files = file_details,
  }
end

--- Check if a feature should be split.
--- Returns true + reason if it's too big, false + nil if it's fine.
function M.should_split(name)
  local analysis = analyze_feature(name)
  if not analysis then return false, nil end

  -- Thresholds (tuned from experience with agentic loop)
  if analysis.file_count >= 8 then
    return true, string.format("%d files (threshold: 8)", analysis.file_count)
  end
  if analysis.total_lines >= 1500 then
    return true, string.format("%d total lines (threshold: 1500)", analysis.total_lines)
  end
  if analysis.symbol_count >= 40 then
    return true, string.format("%d symbols (threshold: 40)", analysis.symbol_count)
  end

  return false, nil
end

--------------------------------------------------------------------
-- LLM split proposal
--------------------------------------------------------------------

local SPLIT_PROMPT = [=[
You are analyzing a code feature that has grown too large for an AI coding agent to work with
effectively. Your job is to propose how to SPLIT it into 2-4 smaller, cohesive sub-features.

## Feature: $%s
%s

## Files in this feature:
%s

## Rules
1. Each sub-feature should be COHESIVE: files that work together stay together.
2. Sub-feature names should be kebab-case: parent-subname (e.g., auth-handlers, auth-store).
3. Keep the parent name as prefix for discoverability (auth → auth-handlers, auth-middleware).
4. Every file must be assigned to exactly ONE sub-feature.
5. Aim for 2-4 sub-features. Fewer is better — only split if there's a clear logical boundary.
6. Each sub-feature should have a one-sentence description.
7. Consider these natural boundaries:
   - Data/storage layer vs business logic vs API/handler layer
   - Core types/interfaces vs implementations
   - Main functionality vs middleware/helpers
   - Tests should follow their source files (same sub-feature).

## SINGLE-FILE FEATURES
If this feature has only ONE file, you CANNOT split it using the XML format below (each file can only
go to one sub-feature). In this case, respond with ONLY this XML:

<split>
<cannot_split reason="Single file feature. Use :DwightSplitFeature --agentic to refactor the file into multiple files first." />
</split>

Do NOT explain why. Do NOT analyze the file contents. Just output the XML above.

## MULTI-FILE FEATURES
Respond in this EXACT format and NOTHING ELSE before or after — no explanation, no analysis, no preamble.
Output ONLY the <split> XML block. Any text outside the XML will cause a parse error:

<split>
<sub_feature name="PARENT-SUBNAME" description="One sentence describing this sub-feature.">
  <file path="relative/path/to/file.go" />
  <file path="relative/path/to/file_test.go" />
</sub_feature>
<sub_feature name="PARENT-SUBNAME2" description="One sentence describing this sub-feature.">
  <file path="relative/path/to/other.go" />
</sub_feature>
</split>
]=]

--- Generate a split proposal via LLM.
--- callback(proposal, err) where proposal = { sub_features = { { name, description, files } } }
function M._propose_split(name, callback)
  local analysis = analyze_feature(name)
  if not analysis then
    callback(nil, "Feature '" .. name .. "' not found")
    return
  end

  -- Single-file features cannot be split by pragma reassignment
  if analysis.file_count <= 1 then
    callback(nil, string.format(
      "$%s has only %d file — cannot split by file assignment.\n" ..
      "Use :DwightSplitFeature %s --agentic to refactor the file into multiple files first.",
      name, analysis.file_count, name))
    return
  end

  -- Build file context for the LLM
  local file_parts = {}
  for _, file in ipairs(analysis.files) do
    local entry = string.format(
      "### %s (%d lines, %d symbols)",
      file.path, file.lines, file.symbols)
    if file.signatures and file.signatures ~= "" then
      entry = entry .. "\nSignatures:\n" .. file.signatures
    end
    if #file.dependencies > 0 then
      local deps = {}
      for _, d in ipairs(file.dependencies) do deps[#deps + 1] = "  " .. d end
      entry = entry .. "\nImports:\n" .. table.concat(deps, "\n")
    end
    file_parts[#file_parts + 1] = entry
  end

  local desc = analysis.description
    and string.format("Description: %s\n%d files, %d lines, %d symbols",
        analysis.description, analysis.file_count, analysis.total_lines, analysis.symbol_count)
    or string.format("%d files, %d lines, %d symbols",
        analysis.file_count, analysis.total_lines, analysis.symbol_count)

  local prompt = string.format(SPLIT_PROMPT, name, desc, table.concat(file_parts, "\n\n"))

  local log = require("dwight.log")
  local job_id = log._next_id()
  log.start(job_id, "split:propose", vim.api.nvim_get_current_buf(), 0, 0,
    "DwightSplit for $" .. name .. "\n\n" .. prompt:sub(1, 4000))

  require("dwight.skills")._run_llm(prompt, function(raw, code)
    if code ~= 0 or not raw or vim.trim(raw) == "" then
      log.finish(job_id, "error", raw or "", nil, "LLM proposal failed")
      callback(nil, "LLM proposal failed (exit " .. tostring(code) .. ")")
      return
    end

    -- Parse the <split> XML
    local proposal, parse_reason = M._parse_proposal(raw, name)
    if not proposal then
      local reason = parse_reason or "Failed to parse split proposal"
      log.finish(job_id, "parse_fail", raw, nil, reason)
      if parse_reason then
        -- cannot_split or other structured reason
        callback(nil, reason)
      else
        callback(nil, "Failed to parse split proposal. Raw:\n" .. (raw or ""):sub(1, 500))
      end
      return
    end

    -- Validate: every original file must be assigned
    local assigned = {}
    for _, sf in ipairs(proposal.sub_features) do
      for _, fp in ipairs(sf.files) do
        assigned[fp] = sf.name
      end
    end

    local missing = {}
    for _, file in ipairs(analysis.files) do
      if not assigned[file.path] then
        missing[#missing + 1] = file.path
      end
    end

    if #missing > 0 then
      log.finish(job_id, "error", raw, nil, "Proposal missing files: " .. table.concat(missing, ", "))
      callback(nil, "Proposal missing files: " .. table.concat(missing, ", "))
      return
    end

    log.finish(job_id, "success", raw,
      string.format("Split $%s into %d sub-features", name, #proposal.sub_features), nil)
    proposal.analysis = analysis
    callback(proposal, nil)
  end)
end

--- Parse the LLM's <split> response.
function M._parse_proposal(raw, parent_name)
  if not raw or not raw:find("<split>") then return nil end

  -- Check for <cannot_split> response
  if raw:find("<cannot_split") then
    local reason = raw:match('<cannot_split%s+reason="([^"]*)"') or "Feature cannot be split"
    return nil, reason
  end

  -- Find ALL <split>...</split> blocks (LLM may output multiple attempts)
  local best_result = nil
  for split_block in raw:gmatch("<split>(.-)</split>") do
    local sub_features = {}
    for attrs, body in split_block:gmatch('<sub_feature%s+(.-)>(.-)</sub_feature>') do
      local name = attrs:match('name="([^"]+)"')
      local desc = attrs:match('description="([^"]*)"')

      if name then
        local files = {}
        for file_path in body:gmatch('<file%s+path="([^"]+)"') do
          files[#files + 1] = vim.trim(file_path)
        end

        sub_features[#sub_features + 1] = {
          name = name,
          description = desc or "",
          files = files,
        }
      end
    end

    -- Keep the block with the most sub-features (≥2)
    if #sub_features >= 2 then
      if not best_result or #sub_features > #best_result then
        best_result = sub_features
      end
    end
  end

  if not best_result then return nil end

  return {
    parent = parent_name,
    sub_features = best_result,
  }
end

--------------------------------------------------------------------
-- Preview: show the split proposal in a buffer
--------------------------------------------------------------------

--- Format a proposal as readable text.
local function format_proposal(proposal)
  local parts = {}
  local a = proposal.analysis

  parts[#parts + 1] = string.format("═══════════════════════════════════════════════")
  parts[#parts + 1] = string.format("  DwightSplitFeature: $%s", proposal.parent)
  parts[#parts + 1] = string.format("═══════════════════════════════════════════════")
  parts[#parts + 1] = ""

  if a then
    parts[#parts + 1] = string.format("Current: %d files, %d lines, %d symbols",
      a.file_count, a.total_lines, a.symbol_count)
    if a.description then
      parts[#parts + 1] = string.format("Description: %s", a.description)
    end
  end

  parts[#parts + 1] = ""
  parts[#parts + 1] = string.format("Proposed split into %d sub-features:", #proposal.sub_features)
  parts[#parts + 1] = ""

  for i, sf in ipairs(proposal.sub_features) do
    parts[#parts + 1] = string.format("  %d. $%s", i, sf.name)
    parts[#parts + 1] = string.format("     %s", sf.description)
    parts[#parts + 1] = string.format("     Files (%d):", #sf.files)
    for _, fp in ipairs(sf.files) do
      -- Find line count from analysis
      local lines = "?"
      if a then
        for _, af in ipairs(a.files) do
          if af.path == fp then lines = tostring(af.lines); break end
        end
      end
      parts[#parts + 1] = string.format("       - %s (%s lines)", fp, lines)
    end
    parts[#parts + 1] = ""
  end

  parts[#parts + 1] = "───────────────────────────────────────────────"
  parts[#parts + 1] = "  Press 'y' to apply, 'n' to cancel, 'q' to close"
  parts[#parts + 1] = "───────────────────────────────────────────────"

  return table.concat(parts, "\n")
end

--- Show proposal in a preview buffer with confirm/cancel keybinds.
local function show_proposal_buffer(proposal, on_confirm, on_cancel)
  local text = format_proposal(proposal)
  local lines = vim.split(text, "\n", { plain = true })

  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_name(buf, "dwight://split-preview/" .. proposal.parent)
  api.nvim_buf_set_lines(buf, 0, -1, false, _flatten(lines))
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false

  -- Open in a split
  vim.cmd("botright split")
  api.nvim_win_set_buf(0, buf)
  vim.cmd("resize " .. math.min(#lines + 2, 30))

  -- Keymaps
  local function close()
    local win = api.nvim_get_current_win()
    pcall(api.nvim_win_close, win, true)
  end

  vim.keymap.set("n", "y", function()
    close()
    if on_confirm then on_confirm() end
  end, { buffer = buf, desc = "Apply split" })

  vim.keymap.set("n", "n", function()
    close()
    if on_cancel then on_cancel() end
  end, { buffer = buf, desc = "Cancel split" })

  vim.keymap.set("n", "q", close, { buffer = buf, desc = "Close preview" })
end

--------------------------------------------------------------------
-- Apply: rewrite @feature pragmas in source files
--------------------------------------------------------------------

--- Apply a split proposal: replace @feature:parent with @feature:sub in each file.
--- Returns the number of files modified.
function M._apply_split(proposal)
  local cwd = vim.fn.getcwd()
  local modified = 0

  -- Build reverse lookup: file_path → new sub-feature name
  local file_mapping = {}
  for _, sf in ipairs(proposal.sub_features) do
    for _, fp in ipairs(sf.files) do
      file_mapping[fp] = sf
    end
  end

  local parent_name = proposal.parent

  -- Process each file
  for file_path, sf in pairs(file_mapping) do
    local full_path = file_path
    if not full_path:match("^/") then full_path = cwd .. "/" .. full_path end

    local f = io.open(full_path, "r")
    if not f then goto continue end

    local content = f:read("*a")
    f:close()

    -- Replace @feature:parent_name with @feature:new_name
    -- Match the exact feature name to avoid partial matches
    -- (e.g., @feature:auth should not match @feature:auth-middleware)
    local new_content, count = content:gsub(
      "(@feature:)" .. vim.pesc(parent_name) .. "(%s)",
      "%1" .. sf.name .. "%2")

    -- Also handle end-of-line case (no trailing space)
    if count == 0 then
      new_content, count = content:gsub(
        "(@feature:)" .. vim.pesc(parent_name) .. "$",
        "%1" .. sf.name)
    end

    -- Handle case where pragma is at end of a comment line: // @feature:auth\n
    if count == 0 then
      new_content, count = content:gsub(
        "(@feature:)" .. vim.pesc(parent_name) .. "(\n)",
        "%1" .. sf.name .. "%2")
    end

    -- Handle case where pragma is followed by other pragmas or punctuation
    if count == 0 then
      new_content, count = content:gsub(
        "(@feature:)" .. vim.pesc(parent_name) .. "([^%w_%-%.%s])",
        "%1" .. sf.name .. "%2")
    end

    if count == 0 then goto continue end

    -- Add sub-feature description if the file doesn't already have one
    -- Only add if the sub-feature description differs from the parent
    if sf.description and sf.description ~= "" then
      -- Check if there's already a description on the pragma line
      local has_desc = false
      for line in new_content:gmatch("[^\n]+") do
        if line:match("@feature:" .. vim.pesc(sf.name)) then
          -- Check if there's text besides the pragma
          local stripped = line:gsub("@feature:" .. vim.pesc(sf.name), "")
          stripped = stripped:gsub("^[/%*#%-;%%%(]+%s*", ""):gsub("%s*[%*/)%-;%%]+$", "")
          if vim.trim(stripped) ~= "" then has_desc = true end
          break
        end
      end

      if not has_desc then
        -- Detect comment style from the pragma line
        local comment_prefix = "//"
        for line in new_content:gmatch("[^\n]+") do
          if line:match("@feature:" .. vim.pesc(sf.name)) then
            if line:match("^%s*#") then comment_prefix = "#"
            elseif line:match("^%s*%-%-") then comment_prefix = "--"
            elseif line:match("^%s*//") then comment_prefix = "//"
            end
            break
          end
        end

        -- Append description after the pragma tag on the same line
        new_content = new_content:gsub(
          "(@feature:" .. vim.pesc(sf.name) .. ")",
          "%1 " .. sf.description)
      end
    end

    -- Write back
    local wf = io.open(full_path, "w")
    if wf then
      wf:write(new_content)
      wf:close()
      modified = modified + 1

      -- Refresh Neovim buffer if open
      vim.schedule(function()
        for _, bufnr in ipairs(api.nvim_list_bufs()) do
          if api.nvim_buf_is_loaded(bufnr) and api.nvim_buf_get_name(bufnr) == full_path then
            api.nvim_buf_call(bufnr, function() vim.cmd("edit!") end)
          end
        end
      end)
    end

    ::continue::
  end

  return modified
end

--------------------------------------------------------------------
-- Public API: split, preview, auto-suggest
--------------------------------------------------------------------

--- Split a feature interactively: analyze → propose → preview → confirm → apply.
function M.split(name)
  if not name or name == "" then
    -- Pick from available features
    local features = require("dwight.features")
    local names = features.names()
    if #names == 0 then
      vim.notify("[dwight] No features found. Add // @feature:name pragmas first.", vim.log.levels.WARN)
      return
    end

    -- Build feature data for picker
    local picker_items = {}
    for _, n in ipairs(names) do
      local a = analyze_feature(n)
      if a then
        local should, reason = M.should_split(n)
        picker_items[#picker_items + 1] = {
          name = n, analysis = a, should_split = should, reason = reason,
        }
      end
    end

    -- Sort: features needing split first
    table.sort(picker_items, function(a, b)
      if a.should_split and not b.should_split then return true end
      if not a.should_split and b.should_split then return false end
      return a.analysis.total_lines > b.analysis.total_lines
    end)

    local has_tel, pickers = pcall(require, "telescope.pickers")
    if has_tel then
      local finders = require("telescope.finders")
      local conf = require("telescope.config").values
      local actions = require("telescope.actions")
      local action_state = require("telescope.actions.state")
      local previewers = require("telescope.previewers")

      pickers.new({}, {
        prompt_title = "🔀 Split Feature",
        finder = finders.new_table({
          results = picker_items,
          entry_maker = function(item)
            local marker = item.should_split and "⚠️ " or "  "
            local reason_str = item.reason and (" — " .. item.reason) or ""
            return {
              value = item,
              display = string.format("%s$%s (%d files, %d lines)%s",
                marker, item.name, item.analysis.file_count, item.analysis.total_lines, reason_str),
              ordinal = item.name,
            }
          end,
        }),
        sorter = conf.generic_sorter({}),
        previewer = previewers.new_buffer_previewer({
          title = "Feature Details",
          define_preview = function(self, entry)
            local a = entry.value.analysis
            local lines = {
              "Feature: $" .. a.name,
              string.format("Files: %d | Lines: %d | Symbols: %d", a.file_count, a.total_lines, a.symbol_count),
              a.description and ("Description: " .. a.description) or "",
              "",
              "── Files ──",
            }
            for _, f in ipairs(a.files) do
              lines[#lines + 1] = string.format("  %s (%d lines, %d symbols)", f.path, f.lines, f.symbols)
              if f.signatures and f.signatures ~= "" then
                for sig_line in f.signatures:gmatch("[^\n]+") do
                  lines[#lines + 1] = "    " .. sig_line:sub(1, 90)
                end
              end
            end
            if entry.value.should_split then
              lines[#lines + 1] = ""
              lines[#lines + 1] = "⚠️  " .. entry.value.reason
            end
            if a.file_count <= 1 then
              lines[#lines + 1] = ""
              lines[#lines + 1] = "⚠️  Single-file feature: use --agentic mode to refactor into multiple files first."
            end
            api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, _flatten(lines))
          end,
        }),
        attach_mappings = function(pb)
          actions.select_default:replace(function()
            local entry = action_state.get_selected_entry()
            actions.close(pb)
            if entry then M.split(entry.value.name) end
          end)
          return true
        end,
      }):find()
    else
      -- Fallback: dwight.select
      local items = {}
      for _, item in ipairs(picker_items) do
        local marker = item.should_split and "⚠️ " or ""
        items[#items + 1] = string.format("%s$%s (%d files, %d lines)",
          marker, item.name, item.analysis.file_count, item.analysis.total_lines)
      end
      require("dwight.select").pick(items, {
        prompt = "Split which feature?",
      }, function(_, idx)
        if idx then M.split(picker_items[idx].name) end
      end)
    end
    return
  end

  -- Validate the feature exists
  local analysis = analyze_feature(name)
  if not analysis then
    vim.notify("[dwight] Feature '$" .. name .. "' not found.", vim.log.levels.WARN)
    return
  end

  vim.notify(string.format(
    "[dwight] Analyzing $%s (%d files, %d lines, %d symbols)...",
    name, analysis.file_count, analysis.total_lines, analysis.symbol_count),
    vim.log.levels.INFO)

  -- Single-file features can't be split by pragma reassignment — need file-level refactoring
  if analysis.file_count == 1 then
    local file = analysis.files[1]
    vim.notify(string.format(
      "[dwight] $%s has only 1 file (%s, %d lines).\n"
      .. "Pragma-based splitting requires multiple files.\n"
      .. "Use :DwightSplitFeature %s --agentic to refactor the file into multiple files first.",
      name, file.path, file.lines, name),
      vim.log.levels.WARN)
    return
  end

  -- Generate proposal
  M._propose_split(name, function(proposal, err)
    if err then
      vim.notify("[dwight] Split failed: " .. err, vim.log.levels.ERROR)
      return
    end

    -- Show preview with confirm/cancel
    show_proposal_buffer(proposal,
      -- On confirm
      function()
        local count = M._apply_split(proposal)
        vim.notify(string.format(
          "[dwight] ✅ Split $%s into %d sub-features (%d files modified).\n"
          .. "New features: %s\n"
          .. "Use :DwightFeatures to verify. Undo with git checkout or per-file undo.",
          name, #proposal.sub_features, count,
          table.concat(
            vim.tbl_map(function(sf) return "$" .. sf.name end, proposal.sub_features),
            ", ")),
          vim.log.levels.INFO)
      end,
      -- On cancel
      function()
        vim.notify("[dwight] Split cancelled.", vim.log.levels.INFO)
      end)
  end)
end

--- Preview-only: show what a split would look like without applying.
function M.preview(name)
  if not name or name == "" then
    local features = require("dwight.features")
    local names = features.names()
    local picker_items = {}
    for _, n in ipairs(names) do
      local a = analyze_feature(n)
      if a then
        local should, reason = M.should_split(n)
        picker_items[#picker_items + 1] = { name = n, analysis = a, should_split = should, reason = reason }
      end
    end

    local has_tel, pickers = pcall(require, "telescope.pickers")
    if has_tel then
      local finders = require("telescope.finders")
      local conf = require("telescope.config").values
      local actions = require("telescope.actions")
      local action_state = require("telescope.actions.state")

      pickers.new({}, {
        prompt_title = "🔍 Preview Split",
        finder = finders.new_table({
          results = picker_items,
          entry_maker = function(item)
            local marker = item.should_split and "⚠️ " or "  "
            return {
              value = item,
              display = string.format("%s$%s (%d files, %d lines)",
                marker, item.name, item.analysis.file_count, item.analysis.total_lines),
              ordinal = item.name,
            }
          end,
        }),
        sorter = conf.generic_sorter({}),
        attach_mappings = function(pb)
          actions.select_default:replace(function()
            local entry = action_state.get_selected_entry()
            actions.close(pb)
            if entry then M.preview(entry.value.name) end
          end)
          return true
        end,
      }):find()
    else
      local items = {}
      for _, item in ipairs(picker_items) do
        items[#items + 1] = string.format("$%s (%d files, %d lines)",
          item.name, item.analysis.file_count, item.analysis.total_lines)
      end
      require("dwight.select").pick(items, {
        prompt = "Preview split for which feature?",
      }, function(_, idx)
        if idx then M.preview(picker_items[idx].name) end
      end)
    end
    return
  end

  vim.notify("[dwight] Generating split preview for $" .. name .. "...", vim.log.levels.INFO)

  -- Single-file features can't be split meaningfully
  local analysis = analyze_feature(name)
  if analysis and analysis.file_count == 1 then
    vim.notify(string.format(
      "[dwight] $%s has only 1 file — pragma-based split not possible.\n"
      .. "Use :DwightSplitFeature %s --agentic to refactor into multiple files.",
      name, name), vim.log.levels.WARN)
    return
  end

  M._propose_split(name, function(proposal, err)
    if err then
      vim.notify("[dwight] Preview failed: " .. err, vim.log.levels.ERROR)
      return
    end

    -- Show in a buffer (no confirm action)
    show_proposal_buffer(proposal, nil, nil)
  end)
end

--- Check all features and report which ones might need splitting.
--- Returns list of { name, reason, analysis }
function M.audit()
  local features = require("dwight.features")
  local names = features.names()
  local results = {}

  for _, name in ipairs(names) do
    local should, reason = M.should_split(name)
    if should then
      results[#results + 1] = {
        name = name,
        reason = reason,
        analysis = analyze_feature(name),
      }
    end
  end

  return results
end

--- Interactive audit: show which features need splitting.
function M.audit_interactive()
  local results = M.audit()

  if #results == 0 then
    vim.notify("[dwight] All features are within size limits. No splits needed.", vim.log.levels.INFO)
    return
  end

  local parts = { "⚠️ Features that may benefit from splitting:\n" }
  for _, r in ipairs(results) do
    local a = r.analysis
    parts[#parts + 1] = string.format("  $%s — %s (%d files, %d lines, %d symbols)",
      r.name, r.reason, a.file_count, a.total_lines, a.symbol_count)
  end
  parts[#parts + 1] = "\nRun :DwightSplitFeature <name> to split."

  vim.notify(table.concat(parts, "\n"), vim.log.levels.WARN)
end

--------------------------------------------------------------------
-- Agentic split: reads code, identifies boundaries, applies split
--------------------------------------------------------------------

--- Build the agentic split prompt.
local function build_agentic_split_prompt(name, analysis)
  -- Build file list with paths
  local file_list = {}
  for _, f in ipairs(analysis.files) do
    file_list[#file_list + 1] = string.format("  %s (%d lines, %d symbols)",
      f.path, f.lines, f.symbols)
  end

  return string.format([=[
You are splitting a large code feature into smaller, cohesive sub-features.

## Feature: $%s
%s
Files: %d | Lines: %d | Symbols: %d

### Files
%s

## Your Task — IN ORDER

### Step 1: Read ALL source files
Read every file in this feature completely. Understand:
- What each file does (its responsibility)
- Import/dependency relationships between files
- Shared types, interfaces, constants used across files
- Call patterns: which files call functions in which other files
- Test files and which source files they test

### Step 2: Identify natural split boundaries
Look for these patterns to find cohesive groups:
- **Layer boundaries**: data/storage vs business logic vs handlers/routes
- **Domain boundaries**: files dealing with the same domain concept
- **Dependency clusters**: files that import each other heavily should stay together
- **Type ownership**: files defining types and files consuming them
- **Test co-location**: test files must stay with their source files

### Step 3: Propose the split
Decide on 2-4 sub-features. Each should be:
- **Cohesive**: files within a sub-feature are tightly coupled
- **Loosely coupled**: minimal dependencies between sub-features
- **Named clearly**: use prefix "%s-" (e.g., %s-handlers, %s-store, %s-types)
- **Balanced**: avoid one huge group and several tiny ones

### Step 4: Apply the split
For EACH file, edit the pragma comment at the top:
- Replace `@feature:%s` with `@feature:{new-sub-feature-name}`
- Add or update the description to reflect the sub-feature's purpose
- Keep the same comment syntax (// for Go/JS, # for Python, -- for Lua)
- Do NOT change any actual code — only modify the pragma comment line

Example: Change `// JWT auth handlers. @feature:%s` to `// JWT auth request handlers. @feature:%s-handlers`

### Step 5: Verify integrity
After applying all changes:
1. List all sub-features you created with their file counts
2. Verify every original file got assigned (no orphans)
3. Verify no file has the old `@feature:%s` pragma anymore
4. Read 2-3 modified files to confirm the pragmas are correct

Write a summary to stdout showing:
- Sub-features created (name, description, file count)
- Files per sub-feature
- Any issues found during verification

## Rules
- Every file MUST be assigned to exactly ONE sub-feature
- Sub-feature names: lowercase, kebab-case, prefixed with "%s-"
- Do NOT create more than 4 sub-features
- Do NOT modify any actual code — only pragma comment lines
- Test files go with their corresponding source files
- If a file is genuinely shared infrastructure, put it in a "-core" or "-types" sub-feature
]=], name,
    analysis.description or "(no description)",
    analysis.file_count, analysis.total_lines, analysis.symbol_count,
    table.concat(file_list, "\n"),
    name, name, name, name,
    name, name, name .. "-handlers",
    name, name)
end

--- Run agentic split: reads code, identifies boundaries, applies changes.
function M.split_agentic(name)
  if not name or name == "" then
    -- Pick from features that need splitting
    local features = require("dwight.features")
    local names = features.names()
    if #names == 0 then
      vim.notify("[dwight] No features found.", vim.log.levels.WARN)
      return
    end

    local items = {}
    for _, n in ipairs(names) do
      local a = analyze_feature(n)
      if a then
        local should, reason = M.should_split(n)
        local marker = should and " ⚠️ " .. reason or ""
        items[#items + 1] = string.format("$%s (%d files, %d lines)%s",
          n, a.file_count, a.total_lines, marker)
      end
    end

    require("dwight.select").pick(items, {
      prompt = "Agentic split which feature?",
    }, function(choice)
      if choice then
        local name_match = choice:match("^%$([%w_%-]+)")
        if name_match then M.split_agentic(name_match) end
      end
    end)
    return
  end

  local analysis = analyze_feature(name)
  if not analysis then
    vim.notify("[dwight] Feature '$" .. name .. "' not found.", vim.log.levels.WARN)
    return
  end

  vim.notify(string.format(
    "[dwight] 🤖 Agentic split: $%s (%d files, %d lines, %d symbols)",
    name, analysis.file_count, analysis.total_lines, analysis.symbol_count),
    vim.log.levels.INFO)

  local prompt = build_agentic_split_prompt(name, analysis)

  local before_features = require("dwight.features").names()

  local agent = require("dwight.agent")
  agent.run(prompt, {
    on_complete = function(success)
      vim.schedule(function()
        if success then
          -- Rebuild feature index and show results
          local features = require("dwight.features")

          -- Force re-scan by clearing any cache
          pcall(function() features._clear_cache() end)

          local after_features = features.names()

          -- Find new sub-features (those starting with name-)
          local new_subs = {}
          local before_set = {}
          for _, n in ipairs(before_features) do before_set[n] = true end
          for _, n in ipairs(after_features) do
            if not before_set[n] and n:match("^" .. vim.pesc(name) .. "%-") then
              new_subs[#new_subs + 1] = n
            end
          end

          -- Check if old feature still exists
          local old_exists = false
          for _, n in ipairs(after_features) do
            if n == name then old_exists = true; break end
          end

          if #new_subs > 0 then
            -- Build summary
            local sub_info = {}
            for _, sn in ipairs(new_subs) do
              local feat = features.build_feature(sn)
              local fc = feat and feat.files and #feat.files or 0
              sub_info[#sub_info + 1] = string.format("  $%s (%d files)", sn, fc)
            end

            local msg = string.format(
              "[dwight] 🤖 Split complete! $%s → %d sub-features:\n%s",
              name, #new_subs, table.concat(sub_info, "\n"))

            if old_exists then
              msg = msg .. string.format(
                "\n\n  ⚠️  $%s still has files — agent may not have split everything.\n" ..
                "  Run :DwightSplitFeature %s --agentic to finish.", name, name)
            end

            msg = msg .. "\n\nRun :DwightFeatures to explore. Undo with git checkout."
            vim.notify(msg, vim.log.levels.INFO)
          else
            vim.notify(
              "[dwight] 🤖 Agentic split completed but no new sub-features detected.\n" ..
              "Check :DwightAgentStatus for details. The agent may have encountered issues.",
              vim.log.levels.WARN)
          end
        else
          vim.notify(
            "[dwight] 🤖 Agentic split had errors. Check :DwightAgentStatus for details.",
            vim.log.levels.WARN)
        end
      end)
    end,
  })
end

return M
