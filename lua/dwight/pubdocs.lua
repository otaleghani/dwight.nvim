-- dwight/pubdocs.lua
-- Public-facing documentation generator.
-- Generates standard markdown files compatible with Docusaurus, MkDocs, VitePress, or plain.
-- Auto-detects the docs framework from project root files.
-- Driven by pragma comments: @feature:, @docs:route, @docs-title:, @feature-no-docs.
-- Always generates: index.md, getting-started.md.
-- Uses standard markdown links (relative paths) for cross-references.
-- Generates framework-specific navigation metadata (_category_.json, nav snippets).

local M = {}

local api = vim.api
local _flatten = require("dwight.util").flatten_lines

--------------------------------------------------------------------
-- Framework detection
--------------------------------------------------------------------

--- Detect which docs framework the project uses.
--- Returns "docusaurus" | "mkdocs" | "vitepress" | "plain"
function M.detect_framework()
  local cwd = vim.fn.getcwd()

  -- Check for explicit config in .dwight/manifest
  local manifest_fw
  pcall(function()
    local project = require("dwight.project")
    local manifest = project.read_manifest()
    if manifest and manifest.docs_framework then
      manifest_fw = manifest.docs_framework
    end
  end)
  if manifest_fw then return manifest_fw end

  -- Docusaurus: docusaurus.config.js or .ts
  if vim.fn.filereadable(cwd .. "/docusaurus.config.js") == 1
    or vim.fn.filereadable(cwd .. "/docusaurus.config.ts") == 1 then
    return "docusaurus"
  end

  -- MkDocs: mkdocs.yml
  if vim.fn.filereadable(cwd .. "/mkdocs.yml") == 1
    or vim.fn.filereadable(cwd .. "/mkdocs.yaml") == 1 then
    return "mkdocs"
  end

  -- VitePress: .vitepress/config.ts or .js or .mts
  if vim.fn.isdirectory(cwd .. "/.vitepress") == 1 then
    return "vitepress"
  end

  return "plain"
end

--------------------------------------------------------------------
-- Framework adapters
--------------------------------------------------------------------

--- Each adapter provides:
---   docs_dir()        → where to write docs
---   frontmatter(page, position) → YAML frontmatter string
---   link(from_path, to_path, title) → markdown link
---   write_nav(pages, docs_dir)  → generate nav metadata, return list of files written
---   link_instructions() → prompt text explaining link format

local adapters = {}

adapters.docusaurus = {
  docs_dir = function()
    return vim.fn.getcwd() .. "/docs"
  end,

  frontmatter = function(page, position)
    local parts = { "---" }
    parts[#parts + 1] = string.format('title: "%s"', (page.title or ""):gsub('"', '\\"'))
    if page.sidebar_label then
      parts[#parts + 1] = string.format('sidebar_label: "%s"', page.sidebar_label:gsub('"', '\\"'))
    end
    if position then
      parts[#parts + 1] = string.format("sidebar_position: %d", position)
    end
    if page.description and page.description ~= "" then
      parts[#parts + 1] = string.format('description: "%s"',
        page.description:sub(1, 155):gsub('"', '\\"'))
    end
    parts[#parts + 1] = "---"
    return table.concat(parts, "\n")
  end,

  link = function(from_path, to_path, title)
    local rel = M._relative_link(from_path, to_path):gsub("%.md$", "")
    return string.format("[%s](%s)", title, rel)
  end,

  link_instructions = function()
    return [[
Use standard markdown links with relative paths WITHOUT the .md extension.
Example from features/auth.md to getting-started: [Getting Started](../getting-started)
Example from index.md to features/auth: [Authentication](./features/auth)
Do NOT use wikilinks. Do NOT use absolute paths.]]
  end,

  write_nav = function(pages, target_dir)
    local categories = {}
    for _, page in ipairs(pages) do
      local dir = page.path:match("^([^/]+)/")
      if dir and not categories[dir] then categories[dir] = true end
    end

    local labels = {
      features = "Features", reference = "API Reference",
      guides = "Guides", concepts = "Concepts",
    }
    local positions = {
      features = 3, guides = 4, reference = 5, concepts = 6,
    }

    local written = {}
    for dir_name in pairs(categories) do
      local cat_path = target_dir .. "/" .. dir_name .. "/_category_.json"
      vim.fn.mkdir(target_dir .. "/" .. dir_name, "p")
      local cat = vim.json.encode({
        label = labels[dir_name] or dir_name:gsub("^%l", string.upper),
        position = positions[dir_name] or 10,
        collapsed = false,
      })
      local f = io.open(cat_path, "w")
      if f then f:write(cat .. "\n"); f:close() end
      written[#written + 1] = dir_name .. "/_category_.json"
    end
    return written
  end,
}

adapters.mkdocs = {
  docs_dir = function()
    return vim.fn.getcwd() .. "/docs"
  end,

  frontmatter = function(page, _position)
    local parts = { "---" }
    parts[#parts + 1] = string.format('title: "%s"', (page.title or ""):gsub('"', '\\"'))
    if page.description and page.description ~= "" then
      parts[#parts + 1] = string.format('description: "%s"',
        page.description:sub(1, 155):gsub('"', '\\"'))
    end
    parts[#parts + 1] = "---"
    return table.concat(parts, "\n")
  end,

  link = function(from_path, to_path, title)
    return string.format("[%s](%s)", title, M._relative_link(from_path, to_path))
  end,

  link_instructions = function()
    return [[
Use standard markdown links with relative paths INCLUDING the .md extension.
Example from features/auth.md to getting-started: [Getting Started](../getting-started.md)
Example from index.md to features/auth: [Authentication](./features/auth.md)
Do NOT use wikilinks. Do NOT use absolute paths.]]
  end,

  write_nav = function(pages, target_dir)
    local nav = { "# Paste this into your mkdocs.yml under 'nav:'", "nav:" }
    nav[#nav + 1] = "  - Home: index.md"
    nav[#nav + 1] = "  - Getting Started: getting-started.md"

    local groups = {}
    local group_order = { "features", "guides", "reference", "concepts" }
    for _, page in ipairs(pages) do
      local dir = page.path:match("^([^/]+)/")
      if dir then
        if not groups[dir] then groups[dir] = {} end
        groups[dir][#groups[dir] + 1] = page
      end
    end

    local labels = {
      features = "Features", guides = "Guides",
      reference = "API Reference", concepts = "Concepts",
    }
    for _, dir_name in ipairs(group_order) do
      local group = groups[dir_name]
      if group then
        nav[#nav + 1] = string.format("  - %s:", labels[dir_name] or dir_name)
        for _, page in ipairs(group) do
          nav[#nav + 1] = string.format("    - %s: %s", page.title, page.path)
        end
      end
    end

    local snippet_path = target_dir .. "/_nav_snippet.yml"
    local f = io.open(snippet_path, "w")
    if f then f:write(table.concat(nav, "\n") .. "\n"); f:close() end
    return { "_nav_snippet.yml" }
  end,
}

adapters.vitepress = {
  docs_dir = function()
    local cwd = vim.fn.getcwd()
    if vim.fn.isdirectory(cwd .. "/docs/.vitepress") == 1 then return cwd .. "/docs" end
    return cwd .. "/docs"
  end,

  frontmatter = function(page, _position)
    local parts = { "---" }
    parts[#parts + 1] = string.format('title: "%s"', (page.title or ""):gsub('"', '\\"'))
    if page.description and page.description ~= "" then
      parts[#parts + 1] = string.format('description: "%s"',
        page.description:sub(1, 155):gsub('"', '\\"'))
    end
    parts[#parts + 1] = "---"
    return table.concat(parts, "\n")
  end,

  link = function(from_path, to_path, title)
    return string.format("[%s](%s)", title, M._relative_link(from_path, to_path))
  end,

  link_instructions = function()
    return [[
Use standard markdown links with relative paths INCLUDING the .md extension.
Example from features/auth.md to getting-started: [Getting Started](../getting-started.md)
Example from index.md to features/auth: [Authentication](./features/auth.md)
Do NOT use wikilinks. Do NOT use absolute paths.]]
  end,

  write_nav = function(pages, target_dir)
    local groups = {}
    local group_order = { "features", "guides", "reference", "concepts" }
    for _, page in ipairs(pages) do
      local dir = page.path:match("^([^/]+)/")
      if dir then
        if not groups[dir] then groups[dir] = {} end
        groups[dir][#groups[dir] + 1] = page
      end
    end

    local labels = {
      features = "Features", guides = "Guides",
      reference = "API Reference", concepts = "Concepts",
    }

    local lines = {
      "// Paste into .vitepress/config.ts → themeConfig.sidebar",
      "sidebar: [",
      "  {",
      '    text: "Getting Started",',
      "    items: [",
      '      { text: "Home", link: "/index" },',
      '      { text: "Getting Started", link: "/getting-started" },',
      "    ],",
      "  },",
    }
    for _, dir_name in ipairs(group_order) do
      local group = groups[dir_name]
      if group then
        lines[#lines + 1] = "  {"
        lines[#lines + 1] = string.format('    text: "%s",', labels[dir_name] or dir_name)
        lines[#lines + 1] = "    items: ["
        for _, page in ipairs(group) do
          local link = "/" .. page.path:gsub("%.md$", "")
          lines[#lines + 1] = string.format('      { text: "%s", link: "%s" },',
            page.title:gsub('"', '\\"'), link)
        end
        lines[#lines + 1] = "    ],"
        lines[#lines + 1] = "  },"
      end
    end
    lines[#lines + 1] = "]"

    local snippet_path = target_dir .. "/_sidebar_snippet.ts"
    local f = io.open(snippet_path, "w")
    if f then f:write(table.concat(lines, "\n") .. "\n"); f:close() end
    return { "_sidebar_snippet.ts" }
  end,
}

adapters.plain = {
  docs_dir = function()
    return vim.fn.getcwd() .. "/docs"
  end,

  frontmatter = function(page, _position)
    local parts = { "---" }
    parts[#parts + 1] = string.format('title: "%s"', (page.title or ""):gsub('"', '\\"'))
    if page.description and page.description ~= "" then
      parts[#parts + 1] = string.format('description: "%s"',
        page.description:sub(1, 155):gsub('"', '\\"'))
    end
    parts[#parts + 1] = "---"
    return table.concat(parts, "\n")
  end,

  link = function(from_path, to_path, title)
    return string.format("[%s](%s)", title, M._relative_link(from_path, to_path))
  end,

  link_instructions = function()
    return [[
Use standard markdown links with relative paths INCLUDING the .md extension.
Example from features/auth.md to getting-started: [Getting Started](../getting-started.md)
Example from index.md to features/auth: [Authentication](./features/auth.md)
Do NOT use wikilinks. Do NOT use absolute paths.]]
  end,

  write_nav = function(_pages, _target_dir)
    return {}
  end,
}

--- Get the adapter for the detected (or configured) framework.
function M.get_adapter()
  local fw = M.detect_framework()
  return adapters[fw] or adapters.plain, fw
end

--------------------------------------------------------------------
-- Link helpers
--------------------------------------------------------------------

--- Compute a relative link from one doc path to another.
--- e.g. _relative_link("features/auth.md", "getting-started.md") → "../getting-started.md"
function M._relative_link(from_path, to_path)
  local from_parts = {}
  for part in from_path:gmatch("[^/]+") do from_parts[#from_parts + 1] = part end

  local to_parts = {}
  for part in to_path:gmatch("[^/]+") do to_parts[#to_parts + 1] = part end

  -- Find common prefix length (directory parts only, not filenames)
  local common = 0
  for i = 1, math.min(#from_parts - 1, #to_parts - 1) do
    if from_parts[i] == to_parts[i] then
      common = common + 1
    else
      break
    end
  end

  -- Number of directories to go up from 'from' (exclude the filename)
  local ups = (#from_parts - 1) - common
  local result = {}

  if ups == 0 then
    result[#result + 1] = "./"
  else
    for _ = 1, ups do result[#result + 1] = "../" end
  end

  -- Append remaining path components after the common prefix
  for i = common + 1, #to_parts do
    if i > common + 1 then result[#result + 1] = "/" end
    result[#result + 1] = to_parts[i]
  end

  return table.concat(result)
end

--------------------------------------------------------------------
-- Page plan: build the full list of doc pages to generate
--------------------------------------------------------------------

--- Build the plan: all pages that should exist based on pragmas.
--- Returns { { path, title, page_type, description, ... } ... }
function M.build_plan()
  local features = require("dwight.features")
  local pages = {}

  -- 1. Always-generated pages
  pages[#pages + 1] = {
    path = "index.md",
    title = "Documentation",
    page_type = "index",
    description = "Project documentation home page",
  }
  pages[#pages + 1] = {
    path = "getting-started.md",
    title = "Getting Started",
    page_type = "getting-started",
    description = "Quick start guide for new users",
  }

  -- 2. Feature pages (excluding @feature-no-docs)
  local doc_features = features.documentable_features()
  for _, name in ipairs(doc_features) do
    local feat = features.build_feature(name)
    local title = feat and feat.description or name
    title = title:match("^([^%.]+)") or title
    if #title > 80 then title = title:sub(1, 77) .. "..." end
    pages[#pages + 1] = {
      path = "features/" .. name .. ".md",
      title = title,
      page_type = "feature",
      feature_name = name,
      description = feat and feat.description or "",
    }
  end

  -- 3. @docs:route pages (merged by route)
  local docs_pragmas = features.scan_docs()
  local route_groups = {}
  for _, dp in ipairs(docs_pragmas) do
    if not route_groups[dp.route] then route_groups[dp.route] = {} end
    route_groups[dp.route][#route_groups[dp.route] + 1] = dp
  end
  for route, entries in pairs(route_groups) do
    local page_type = "generic"
    if route:match("^reference/") then page_type = "reference"
    elseif route:match("^guides/") then page_type = "guide"
    elseif route:match("^concepts/") then page_type = "concept"
    end

    local title = entries[1].title
    if not title then
      local slug = route:match("[^/]+$") or route
      title = slug:gsub("%-", " "):gsub("^%l", string.upper)
        :gsub(" %l", function(c) return c:upper() end)
    end

    pages[#pages + 1] = {
      path = route .. ".md",
      title = title,
      page_type = page_type,
      docs_entries = entries,
      description = "",
    }
  end

  return pages
end

--------------------------------------------------------------------
-- Context builders
--------------------------------------------------------------------

local function build_project_context()
  local parts = {}

  -- Use integration module for rich context if available
  pcall(function()
    local integration = require("dwight.integration")
    local ctx = integration.build_full_context()
    if ctx then parts[#parts + 1] = ctx end
  end)

  -- Fall back to features project context
  if #parts == 0 then
    pcall(function()
      local features = require("dwight.features")
      local proj = features.build_project_context()
      if proj then parts[#parts + 1] = proj end
    end)
  end

  return table.concat(parts, "\n\n")
end

local function build_feature_context(feature_name)
  -- Try integration module first (gives signatures + source snippets)
  local ctx
  pcall(function()
    local integration = require("dwight.integration")
    ctx = integration.build_feature_context("$" .. feature_name)
  end)
  if ctx then return ctx end

  -- Fall back to features XML
  local features = require("dwight.features")
  return features.read(feature_name) or ""
end

local function build_route_context(entries)
  local parts = {}
  local cwd = vim.fn.getcwd()
  local ts_ok, ts = pcall(require, "dwight.treesitter")

  for _, entry in ipairs(entries) do
    local rel = entry.filepath
    if rel:sub(1, #cwd + 1) == cwd .. "/" then rel = rel:sub(#cwd + 2) end

    parts[#parts + 1] = string.format('<source path="%s" line="%d">', rel, entry.pragma_line)
    if entry.description then
      parts[#parts + 1] = "  <description>" .. entry.description .. "</description>"
    end
    if ts_ok then
      local minimap = ts.minimap(entry.filepath)
      if minimap then parts[#parts + 1] = "  <signatures>\n" .. minimap .. "\n  </signatures>" end
    end
    parts[#parts + 1] = "</source>"
  end
  return table.concat(parts, "\n")
end

local function read_existing_page(adapter, path)
  local full = adapter.docs_dir() .. "/" .. path
  if vim.fn.filereadable(full) ~= 1 then return nil end
  local f = io.open(full, "r")
  if not f then return nil end
  local content = f:read("*a"); f:close()
  return content
end

--- Build a docs structure listing for the LLM to use in cross-references.
--- Shows all pages with pre-built example links from the current page.
local function build_docs_structure(pages, adapter, current_page)
  local parts = { "Available documentation pages (use these for cross-references):" }
  for _, page in ipairs(pages) do
    if page.path ~= current_page.path then
      local link = adapter.link(current_page.path, page.path, page.title)
      parts[#parts + 1] = string.format("  - %s → %s", page.path, link)
    end
  end
  return table.concat(parts, "\n")
end

--------------------------------------------------------------------
-- Prompt templates
--------------------------------------------------------------------

local function base_prompt(page, adapter, docs_structure, project_ctx, specific_ctx, existing)
  local parts = {}

  parts[#parts + 1] = string.format("Generate documentation page: %s\n", page.path)
  parts[#parts + 1] = "FRONTMATTER: The system will add YAML frontmatter automatically. "
    .. "Do NOT include --- fences. Just write the content body.\n"
  parts[#parts + 1] = adapter.link_instructions() .. "\n"

  if docs_structure then
    parts[#parts + 1] = docs_structure .. "\n"
  end

  if project_ctx and project_ctx ~= "" then
    parts[#parts + 1] = "Project context:\n" .. project_ctx .. "\n"
  end

  if specific_ctx and specific_ctx ~= "" then
    parts[#parts + 1] = "Page-specific context:\n" .. specific_ctx .. "\n"
  end

  if existing then
    parts[#parts + 1] = "Current version (update it, preserve user edits):\n"
      .. "```markdown\n" .. existing .. "\n```\n"
  end

  return table.concat(parts, "\n")
end

local PAGE_PROMPTS = {
  index = function(page, adapter, struct, proj, existing)
    return base_prompt(page, adapter, struct, proj, nil, existing) .. [=[
Create a project documentation index page. This is the main entry point.

Structure:
# Project Name
Brief overview (2-3 sentences from user's perspective).

## Quick Links
Links to the most important pages.

## Features
Brief list of features with links to detail pages.

## Getting Started
Brief teaser + link to Getting Started page.

Be welcoming, clear, concise. For END USERS, not developers.
Respond with ONLY the markdown content (no frontmatter, no fences).
]=]
  end,

  ["getting-started"] = function(page, adapter, struct, proj, existing)
    return base_prompt(page, adapter, struct, proj, nil, existing) .. [=[
Create a "Getting Started" guide for new users.

Structure:
# Getting Started

## Prerequisites
What the user needs.

## Installation
Step-by-step.

## First Steps
Walk through basic usage (3-5 steps).

## Next Steps
Point to feature pages.

Be friendly, practical. Assume the user knows nothing.
Respond with ONLY the markdown content (no frontmatter, no fences).
]=]
  end,

  feature = function(page, adapter, struct, proj, existing)
    local ctx = build_feature_context(page.feature_name)
    return base_prompt(page, adapter, struct, proj, ctx, existing) .. string.format([=[
Create user-facing documentation for the "%s" feature.

Structure:
# %s
What this feature does (user's perspective).

## Overview
The problem it solves.

## Usage
How to use it with concrete examples.

## Configuration
Options, settings (if any).

## Examples
2-3 practical examples.

Write for END USERS. No implementation details.
Respond with ONLY the markdown content (no frontmatter, no fences).
]=], page.feature_name, page.title)
  end,

  reference = function(page, adapter, struct, proj, existing)
    local ctx = build_route_context(page.docs_entries or {})
    return base_prompt(page, adapter, struct, proj, ctx, existing) .. [[
Create an API reference page. Be precise and compact.

For each function/method: signature, parameters, return type, description, example.
Include key types/interfaces.
Use code blocks for signatures and examples.
Respond with ONLY the markdown content (no frontmatter, no fences).
]]
  end,

  guide = function(page, adapter, struct, proj, existing)
    local ctx = build_route_context(page.docs_entries or {})
    return base_prompt(page, adapter, struct, proj, ctx, existing) .. [[
Create a how-to guide. Focus on practical steps.

Structure: prerequisites → numbered steps with code → troubleshooting.
Be step-by-step. Show code at each step.
Respond with ONLY the markdown content (no frontmatter, no fences).
]]
  end,

  concept = function(page, adapter, struct, proj, existing)
    local ctx = build_route_context(page.docs_entries or {})
    return base_prompt(page, adapter, struct, proj, ctx, existing) .. [[
Create a concept/explanation page. Help understand WHY, not just HOW.

Structure: what it is → background → how it works → implications.
Be clear, educational. Use analogies if helpful.
Respond with ONLY the markdown content (no frontmatter, no fences).
]]
  end,

  generic = function(page, adapter, struct, proj, existing)
    local ctx = build_route_context(page.docs_entries or {})
    return base_prompt(page, adapter, struct, proj, ctx, existing) .. [[
Create a documentation page based on the source context provided.
Infer the appropriate style. Be clear, user-focused, include examples.
Respond with ONLY the markdown content (no frontmatter, no fences).
]]
  end,
}

--------------------------------------------------------------------
-- Generate a single page
--------------------------------------------------------------------

function M.generate_page(page, callback)
  local adapter, fw = M.get_adapter()
  local plan = M.build_plan()
  local docs_structure = build_docs_structure(plan, adapter, page)
  local project_ctx = build_project_context()
  local existing = read_existing_page(adapter, page.path)

  local position = nil
  for i, p in ipairs(plan) do
    if p.path == page.path then position = i; break end
  end

  local prompt_fn = PAGE_PROMPTS[page.page_type] or PAGE_PROMPTS.generic
  local prompt = prompt_fn(page, adapter, docs_structure, project_ctx, existing)

  local log_ok, log = pcall(require, "dwight.log")
  local job_id
  if log_ok then
    job_id = log._next_id()
    log.start(job_id, "docs:" .. page.path, api.nvim_get_current_buf(), 0, 0,
      string.format("Framework: %s\n\n%s", fw, prompt:sub(1, 4000)))
  end

  require("dwight.skills")._run_llm(prompt, function(raw, code)
    if code ~= 0 or vim.trim(raw or "") == "" then
      if job_id then log.finish(job_id, "error", raw or "", nil, "Generation failed") end
      callback(nil, "Generation failed for " .. page.path)
      return
    end

    -- Strip fences if the LLM wrapped it
    local content = raw:gsub("^```%w*%s*\n", ""):gsub("\n```%s*$", "")
    content = content:gsub("^~~~%w*%s*\n", ""):gsub("\n~~~%s*$", "")

    -- Strip frontmatter if the LLM included it (we generate our own)
    content = content:gsub("^%-%-%-.-%-%-%-\n*", "")
    content = vim.trim(content)

    -- Prepend framework-specific frontmatter
    local frontmatter = adapter.frontmatter(page, position)
    content = frontmatter .. "\n\n" .. content

    if not content:match("\n$") then content = content .. "\n" end

    if job_id then log.finish(job_id, "success", raw, content:sub(1, 500), nil) end
    callback(content, nil)
  end)
end

local function write_page(adapter, page, content)
  local full_path = adapter.docs_dir() .. "/" .. page.path
  local dir = vim.fn.fnamemodify(full_path, ":h")
  vim.fn.mkdir(dir, "p")
  local f = io.open(full_path, "w")
  if f then f:write(content); f:close(); return true end
  return false
end

--------------------------------------------------------------------
-- :DwightDocs [page|all] — generate documentation
--------------------------------------------------------------------

function M.generate(opts)
  local project = require("dwight.project")
  if not project.is_initialized() then
    vim.notify("[dwight] Run :DwightInit first.", vim.log.levels.WARN)
    return
  end

  local plan = M.build_plan()
  if #plan == 0 then
    vim.notify("[dwight] No pages to generate. Add @feature: or @docs: pragmas.", vim.log.levels.WARN)
    return
  end

  local adapter, fw = M.get_adapter()
  vim.notify(string.format("[dwight] 📄 Docs framework: %s → %s/",
    fw, adapter.docs_dir():match("[^/]+$")), vim.log.levels.INFO)

  opts = opts or {}

  -- :DwightDocs all — show plan, then generate everything
  if opts.target == "all" then
    -- Show plan preview
    local plan_lines = {
      string.format("📄 DwightDocs — Generate %d pages [%s]", #plan, fw),
      "",
    }
    local existing_count = 0
    for _, p in ipairs(plan) do
      local exists = vim.fn.filereadable(adapter.docs_dir() .. "/" .. p.path) == 1
      if exists then existing_count = existing_count + 1 end
      local icon = ({ index = "📖", ["getting-started"] = "🚀", feature = "⚙️",
        reference = "📋", guide = "📝", concept = "💡" })[p.page_type] or "📄"
      local marker = exists and " (overwrite)" or " (new)"
      plan_lines[#plan_lines + 1] = string.format("  %s %s — %s%s", icon, p.path, p.title, marker)
    end
    plan_lines[#plan_lines + 1] = ""
    plan_lines[#plan_lines + 1] = string.format("  Output: %s/", adapter.docs_dir())
    if existing_count > 0 then
      plan_lines[#plan_lines + 1] = string.format("  ⚠️  %d existing page(s) will be overwritten", existing_count)
    end

    require("dwight.select").pick({
      string.format("✅ Generate all %d pages", #plan),
      "❌ Cancel",
    }, {
      prompt = table.concat(plan_lines, "\n"),
    }, function(choice)
      if choice and choice:match("Generate") then
        M._generate_many(plan)
      end
    end)
    return
  end

  -- :DwightDocs {page} — generate a specific page
  if opts.target and opts.target ~= "" then
    for _, page in ipairs(plan) do
      if page.path:match(opts.target) or page.page_type == opts.target
        or (page.feature_name and page.feature_name == opts.target) then
        vim.notify("[dwight] 📄 Generating " .. page.path .. "…", vim.log.levels.INFO)

        M.generate_page(page, function(content, err)
          if err then
            vim.notify("[dwight] " .. err, vim.log.levels.ERROR)
          else
            write_page(adapter, page, content)
            vim.notify("[dwight] ✅ " .. page.path .. " generated!", vim.log.levels.INFO)
            vim.cmd("edit " .. vim.fn.fnameescape(adapter.docs_dir() .. "/" .. page.path))
          end
        end)
        return
      end
    end
    vim.notify("[dwight] Page not found: " .. opts.target, vim.log.levels.WARN)
    return
  end

  -- :DwightDocs (no args) — Telescope picker
  local has_tel, pickers = pcall(require, "telescope.pickers")
  if has_tel then
    local finders = require("telescope.finders")
    local conf = require("telescope.config").values
    local actions = require("telescope.actions")
    local action_state = require("telescope.actions.state")
    local previewers = require("telescope.previewers")

    local picker_items = { { path = "(all)", title = "Generate ALL pages", page_type = "all" } }
    for _, p in ipairs(plan) do picker_items[#picker_items + 1] = p end

    pickers.new({}, {
      prompt_title = string.format("📄 DwightDocs [%s] — select pages", fw),
      finder = finders.new_table({
        results = picker_items,
        entry_maker = function(page)
          local icon = ({ index = "📖", ["getting-started"] = "🚀", feature = "⚙️",
            reference = "📋", guide = "📝", concept = "💡", generic = "📄",
            all = "✨" })[page.page_type] or "📄"
          local exists = page.path ~= "(all)"
            and vim.fn.filereadable(adapter.docs_dir() .. "/" .. page.path) == 1
          local marker = exists and " ✓" or ""
          return {
            value = page,
            display = icon .. " " .. page.path .. marker .. " — " .. page.title,
            ordinal = page.path .. " " .. page.title,
          }
        end,
      }),
      sorter = conf.generic_sorter({}),
      previewer = previewers.new_buffer_previewer({
        define_preview = function(self, entry)
          local page = entry.value
          if page.page_type == "all" then
            local lines = { "Generate ALL documentation pages:", "", "Framework: " .. fw, "" }
            for _, p in ipairs(plan) do
              lines[#lines + 1] = "  " .. p.path .. " — " .. p.title
            end
            api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, _flatten(lines))
          else
            local existing = read_existing_page(adapter, page.path)
            if existing then
              api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false,
                vim.split(existing, "\n", { plain = true }))
              vim.bo[self.state.bufnr].filetype = "markdown"
            else
              api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, {
                "📄 " .. page.path .. " (will be generated)",
                "",
                "Framework: " .. fw,
                "Type: " .. page.page_type,
                "Title: " .. page.title,
                page.feature_name and ("Feature: $" .. page.feature_name) or "",
              })
            end
          end
        end,
      }),
      attach_mappings = function(pb, map)
        map("i", "<Tab>", actions.toggle_selection + actions.move_selection_worse)
        map("n", "<Tab>", actions.toggle_selection + actions.move_selection_worse)
        actions.select_default:replace(function()
          local picker = action_state.get_current_picker(pb)
          local selections = picker:get_multi_selection()
          actions.close(pb)

          local targets = {}
          if #selections > 0 then
            for _, sel in ipairs(selections) do targets[#targets + 1] = sel.value end
          else
            local sel = action_state.get_selected_entry()
            if sel then targets[#targets + 1] = sel.value end
          end

          if #targets == 1 and targets[1].page_type == "all" then
            M._generate_many(plan)
          elseif #targets > 0 then
            local filtered = {}
            for _, t in ipairs(targets) do
              if t.page_type ~= "all" then filtered[#filtered + 1] = t end
            end
            if #filtered > 0 then M._generate_many(filtered) end
          end
        end)
        return true
      end,
    }):find()
  else
    M._generate_many(plan)
  end
end

--------------------------------------------------------------------
-- Generate multiple pages + navigation metadata
--------------------------------------------------------------------

function M._generate_many(pages)
  local adapter, fw = M.get_adapter()
  vim.notify(string.format("[dwight] 📄 Generating %d page(s) [%s]…", #pages, fw),
    vim.log.levels.INFO)

  local pending = #pages
  local generated = 0
  local errors = {}

  for _, page in ipairs(pages) do
    M.generate_page(page, function(content, err)
      pending = pending - 1
      if content then
        if write_page(adapter, page, content) then generated = generated + 1 end
      else
        errors[#errors + 1] = err or page.path
      end
      if pending == 0 then
        -- Generate navigation metadata after all pages are written
        local nav_files = adapter.write_nav(pages, adapter.docs_dir())

        local msg = string.format("[dwight] ✅ Generated %d/%d docs in %s/",
          generated, #pages, adapter.docs_dir():match("[^/]+$"))
        if #nav_files > 0 then
          msg = msg .. string.format(" + %d nav file(s)", #nav_files)
        end
        if #errors > 0 then
          msg = msg .. string.format(" (%d failed)", #errors)
        end
        vim.notify(msg, vim.log.levels.INFO)

        -- Populate quickfix with generated/failed pages
        local qf_items = {}
        for _, page in ipairs(pages) do
          local full_path = adapter.docs_dir() .. "/" .. page.path
          local is_err = false
          for _, e in ipairs(errors) do
            if e:match(vim.pesc(page.path)) then is_err = true; break end
          end
          if vim.fn.filereadable(full_path) == 1 or is_err then
            qf_items[#qf_items + 1] = {
              filename = full_path,
              lnum = 1,
              text = (is_err and "❌ " or "✅ ") .. page.title .. " [" .. page.page_type .. "]",
              type = is_err and "E" or "I",
            }
          end
        end
        if #qf_items > 0 then
          vim.fn.setqflist(qf_items, "r")
          vim.fn.setqflist({}, "a", { title = "Dwight Docs: " .. #qf_items .. " page(s)" })
          vim.defer_fn(function() vim.cmd("botright copen") end, 300)
        end

        -- Hint about nav snippets that need manual integration
        for _, nf in ipairs(nav_files) do
          if nf:match("_nav_snippet") then
            vim.notify("[dwight] 📋 " .. nf .. " — paste into mkdocs.yml nav section",
              vim.log.levels.INFO)
          elseif nf:match("_sidebar_snippet") then
            vim.notify("[dwight] 📋 " .. nf .. " — paste into .vitepress/config.ts sidebar",
              vim.log.levels.INFO)
          end
        end

        if generated > 0 and vim.fn.filereadable(adapter.docs_dir() .. "/index.md") == 1 then
          vim.cmd("edit " .. vim.fn.fnameescape(adapter.docs_dir() .. "/index.md"))
        end
      end
    end)
  end
end

--------------------------------------------------------------------
-- :DwightDocsBrowse — browse existing docs
--------------------------------------------------------------------

function M.browse()
  local adapter = M.get_adapter()
  local dir = adapter.docs_dir()

  if vim.fn.isdirectory(dir) ~= 1 then
    vim.notify("[dwight] No docs yet. Run :DwightDocs to generate.", vim.log.levels.INFO)
    return
  end

  local files = {}
  local uv = vim.loop or vim.uv

  local function scan(d, prefix)
    local handle = uv.fs_scandir(d)
    if not handle then return end
    while true do
      local name, ftype = uv.fs_scandir_next(handle)
      if not name then break end
      if name:match("^_") then goto continue end  -- skip nav snippets / _category_.json
      local rel = prefix ~= "" and (prefix .. "/" .. name) or name
      if ftype == "directory" then
        scan(d .. "/" .. name, rel)
      elseif ftype == "file" and name:match("%.md$") then
        files[#files + 1] = rel
      end
      ::continue::
    end
  end
  scan(dir, "")
  table.sort(files)

  if #files == 0 then
    vim.notify("[dwight] No docs found.", vim.log.levels.INFO)
    return
  end

  local has_tel, pickers = pcall(require, "telescope.pickers")
  if has_tel then
    local finders = require("telescope.finders")
    local conf = require("telescope.config").values
    local actions = require("telescope.actions")
    local action_state = require("telescope.actions.state")
    local previewers = require("telescope.previewers")

    pickers.new({}, {
      prompt_title = "📄 Docs (" .. dir:match("[^/]+$") .. "/)",
      finder = finders.new_table({ results = files }),
      sorter = conf.generic_sorter({}),
      previewer = previewers.new_buffer_previewer({
        define_preview = function(self, entry)
          conf.buffer_previewer_maker(dir .. "/" .. entry[1], self.state.bufnr, {})
        end,
      }),
      attach_mappings = function(pb)
        actions.select_default:replace(function()
          local sel = action_state.get_selected_entry()
          actions.close(pb)
          if sel then vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/" .. sel[1])) end
        end)
        return true
      end,
    }):find()
  else
    for i, name in ipairs(files) do
      vim.notify(string.format("  %d. %s", i, name))
    end
  end
end

--------------------------------------------------------------------
-- Agentic docs: planned multi-step generation
-- Phase 1: Build plan from features + let user edit
-- Phase 2: Per-page agent calls that read source → write page
-- Phase 3: Link verification + navigation metadata
--------------------------------------------------------------------

--- Build a focused agent prompt for generating a single documentation page.
--- The agent reads source files, existing docs, and writes ONE page.
local function build_page_agent_prompt(page, all_pages, adapter, fw)
  local features = require("dwight.features")
  local docs_dir = adapter.docs_dir()
  local parts = {}

  -- Page identity
  parts[#parts + 1] = string.format([[
You are writing ONE documentation page: %s
Page title: %s
Page type: %s
Framework: %s
Output directory: %s/
]], page.path, page.title, page.page_type, fw, docs_dir)

  -- Cross-reference map (so the agent writes correct links)
  parts[#parts + 1] = "## All Documentation Pages (for cross-references)"
  parts[#parts + 1] = "Use relative markdown links between pages. Available pages:"
  for _, p in ipairs(all_pages) do
    if p.path ~= page.path then
      local link = adapter.link(page.path, p.path, p.title)
      parts[#parts + 1] = string.format("  - %s — %s → link: %s", p.path, p.title, link)
    end
  end
  parts[#parts + 1] = ""

  -- Source files to read (feature pages get specific files)
  if page.feature_name then
    local feat = features.build_feature(page.feature_name)
    if feat and feat.files then
      parts[#parts + 1] = string.format("## Source Files for $%s", page.feature_name)
      parts[#parts + 1] = "Read these files to understand the feature before writing docs:"
      for _, ff in ipairs(feat.files) do
        local path = ff.path or ff
        parts[#parts + 1] = "  - " .. path
      end
      if feat.description then
        parts[#parts + 1] = ""
        parts[#parts + 1] = "Feature description: " .. feat.description
      end
      parts[#parts + 1] = ""
    end
  elseif page.page_type == "index" or page.page_type == "getting-started" then
    -- For index/getting-started, read entry points and project context
    parts[#parts + 1] = "## Source Context"
    parts[#parts + 1] = "Read the project's entry point files and README to understand the project."
    parts[#parts + 1] = "Look for: main entry points, package.json/go.mod/Cargo.toml, README.md"
    parts[#parts + 1] = ""
  elseif page.docs_entries then
    -- Route-based pages: list source files from @docs: pragmas
    parts[#parts + 1] = "## Source Files"
    for _, entry in ipairs(page.docs_entries) do
      parts[#parts + 1] = "  - " .. (entry.filepath or "?")
    end
    parts[#parts + 1] = ""
  end

  -- Existing page content (for style matching and updates)
  local existing = read_existing_page(adapter, page.path)
  if existing then
    parts[#parts + 1] = "## Existing Page (match this style and tone, preserve user edits)"
    parts[#parts + 1] = "```markdown"
    if #existing > 4000 then
      parts[#parts + 1] = existing:sub(1, 4000) .. "\n[truncated]"
    else
      parts[#parts + 1] = existing
    end
    parts[#parts + 1] = "```"
    parts[#parts + 1] = ""
  end

  -- Also check if other pages exist already (for style reference)
  local style_ref = nil
  if not existing then
    for _, p in ipairs(all_pages) do
      if p.path ~= page.path then
        local other = read_existing_page(adapter, p.path)
        if other then
          style_ref = other:sub(1, 1500)
          parts[#parts + 1] = string.format(
            "## Style Reference (from %s — match this tone and formatting)", p.path)
          parts[#parts + 1] = "```markdown"
          parts[#parts + 1] = style_ref
          parts[#parts + 1] = "```"
          parts[#parts + 1] = ""
          break
        end
      end
    end
  end

  -- Framework-specific frontmatter instructions
  local fm_instructions = adapter.frontmatter_instructions and adapter.frontmatter_instructions()
  if fm_instructions then
    parts[#parts + 1] = "## Frontmatter\n" .. fm_instructions .. "\n"
  end

  -- Page-type-specific writing instructions
  local type_instructions = {
    index = [[
## Writing Instructions
Create the project's documentation home page.

Structure:
1. # Project Name — brief overview (2-3 sentences, user's perspective)
2. ## Quick Links — links to the most important pages
3. ## Features — brief list with links to feature detail pages
4. ## Getting Started — teaser + link to Getting Started page

Be welcoming, clear, concise. Write for END USERS, not developers.]],

    ["getting-started"] = [[
## Writing Instructions
Create a Getting Started guide for new users.

Structure:
1. # Getting Started
2. ## Prerequisites — what the user needs before starting
3. ## Installation — step-by-step with code blocks
4. ## First Steps — walk through basic usage (3-5 steps with real commands)
5. ## Next Steps — point to feature pages for deeper dives

Be friendly, practical. Assume the user knows nothing about this project.]],

    feature = string.format([[
## Writing Instructions
Create user-facing documentation for the "%s" feature.

YOUR PROCESS:
1. Read the source files listed above — understand the ACTUAL public API
2. Write documentation based on what the code REALLY does
3. Include REAL function signatures, types, and code examples from the source

Structure:
1. # Feature Title — what this feature does (user's perspective)
2. ## Overview — the problem it solves
3. ## Usage — how to use it with concrete, real examples
4. ## Configuration — options, settings (if any, from actual code)
5. ## Examples — 2-3 practical, verified examples

CRITICAL: Every code example must come from the actual source code. No guesses.
Write for END USERS. Minimize implementation details.]], page.feature_name or "?"),

    reference = [[
## Writing Instructions
Create an API reference page. Be precise and compact.

For each function/method: signature, parameters, return type, description, example.
Read the source files and extract REAL signatures — do not guess.
Use code blocks for signatures and examples.]],

    guide = [[
## Writing Instructions
Create a how-to guide. Focus on practical steps.

Structure: prerequisites → numbered steps with code → troubleshooting.
Be step-by-step. Show working code at each step.]],

    concept = [[
## Writing Instructions
Create a concept/explanation page. Help users understand WHY, not just HOW.

Structure: what it is → background → how it works → implications.
Be clear, educational. Use analogies if helpful.]],
  }

  parts[#parts + 1] = type_instructions[page.page_type] or [[
## Writing Instructions
Create a documentation page based on the source context.
Read the relevant source files first. Be clear, user-focused, include real examples.]]

  parts[#parts + 1] = string.format([[

## Output
Write the page to: %s/%s
Include proper frontmatter for %s framework.
Use correct relative links to other pages (see cross-reference map above).
Do NOT modify any source code files.
Do NOT create any files other than the one documentation page.
]], docs_dir, page.path, fw)

  return table.concat(parts, "\n")
end

--- Execute the docs pipeline: generate pages sequentially, one agent per page.
function M._run_docs_pipeline(pages, adapter, fw, opts)
  opts = opts or {}
  local total = #pages
  local generated = 0
  local errors = {}
  local status = require("dwight.agent_status")
  local docs_dir = adapter.docs_dir()

  -- Ensure docs directory exists
  vim.fn.mkdir(docs_dir, "p")
  vim.fn.mkdir(docs_dir .. "/features", "p")

  status.start_session(string.format("DwightDocs: %d pages [%s]", total, fw))
  status.append(string.format("📄 Generating %d documentation pages", total))
  status.append(string.format("   Framework: %s → %s/", fw, docs_dir))
  status.append("")

  -- Sequential execution: one page at a time
  local idx = 0

  local function next_page()
    idx = idx + 1
    if idx > total then
      -- All pages done → post-generation: nav metadata + link verification + quickfix
      vim.schedule(function()
        M._docs_post_generate(pages, adapter, fw, generated, errors, status)
      end)
      return
    end

    local page = pages[idx]
    local icon = ({ index = "📖", ["getting-started"] = "🚀", feature = "⚙️",
      reference = "📋", guide = "📝", concept = "💡" })[page.page_type] or "📄"

    status.append(string.format("── Page %d/%d ──────────────────────────────────", idx, total))
    status.append(string.format("  %s %s — %s", icon, page.path, page.title))

    local prompt = build_page_agent_prompt(page, pages, adapter, fw)

    local agent = require("dwight.agent")
    agent.run(prompt, {
      plan = false,
      _skip_plan = true,
      on_complete = function(success)
        vim.schedule(function()
          local full_path = docs_dir .. "/" .. page.path
          if success and vim.fn.filereadable(full_path) == 1 then
            generated = generated + 1
            status.append(string.format("  ✅ %s written", page.path))
          else
            errors[#errors + 1] = page.path
            if success then
              status.append(string.format("  ⚠️  Agent finished but %s was not created", page.path))
            else
              status.append(string.format("  ❌ Agent failed for %s", page.path))
            end
          end
          status.append("")

          -- Continue to next page
          next_page()
        end)
      end,
    })
  end

  -- Start the pipeline
  next_page()
end

--- Post-generation: write nav metadata, verify links, build quickfix.
function M._docs_post_generate(pages, adapter, fw, generated, errors, status)
  local docs_dir = adapter.docs_dir()

  status.append("═══════════════════════════════════════════════")
  status.append("  📄 Post-Generation")
  status.append("═══════════════════════════════════════════════")

  -- Generate navigation metadata
  local nav_files = {}
  pcall(function()
    nav_files = adapter.write_nav(pages, docs_dir)
    if #nav_files > 0 then
      status.append(string.format("  📋 Generated %d navigation file(s)", #nav_files))
    end
  end)

  -- Link verification: grep for markdown links and check targets
  local broken_links = {}
  pcall(function()
    for _, p in ipairs(pages) do
      local full = docs_dir .. "/" .. p.path
      if vim.fn.filereadable(full) == 1 then
        local f = io.open(full, "r")
        if f then
          local content = f:read("*a"); f:close()
          local line_num = 0
          for line in content:gmatch("[^\n]+") do
            line_num = line_num + 1
            -- Match markdown links: [text](path.md) or [text](../path.md)
            for link_path in line:gmatch("%]%(([^%)]+%.md[^%)]*)%)") do
              -- Resolve relative path
              local page_dir = vim.fn.fnamemodify(p.path, ":h")
              local resolved
              if page_dir == "." then
                resolved = link_path
              else
                resolved = page_dir .. "/" .. link_path
              end
              -- Normalize ../ references
              resolved = resolved:gsub("[^/]+/%.%./", "")
              -- Strip anchors
              resolved = resolved:gsub("#.*$", "")

              local target = docs_dir .. "/" .. resolved
              if vim.fn.filereadable(target) ~= 1 then
                broken_links[#broken_links + 1] = {
                  file = full, lnum = line_num,
                  text = string.format("Broken link: [...](%s) → %s not found", link_path, resolved),
                }
              end
            end
          end
        end
      end
    end
  end)

  if #broken_links > 0 then
    status.append(string.format("  ⚠️  %d broken link(s) found:", #broken_links))
    for _, bl in ipairs(broken_links) do
      status.append("    " .. bl.text)
    end
  else
    status.append("  ✅ All links verified")
  end

  -- Build quickfix
  local qf_items = {}
  for _, p in ipairs(pages) do
    local full_path = docs_dir .. "/" .. p.path
    local is_err = false
    for _, e in ipairs(errors) do
      if e == p.path then is_err = true; break end
    end
    if vim.fn.filereadable(full_path) == 1 then
      qf_items[#qf_items + 1] = {
        filename = full_path, lnum = 1,
        text = "✅ " .. p.title .. " [" .. p.page_type .. "]",
        type = "I",
      }
    elseif is_err then
      qf_items[#qf_items + 1] = {
        filename = full_path, lnum = 1,
        text = "❌ " .. p.title .. " (not generated)",
        type = "E",
      }
    end
  end

  -- Add broken links to quickfix
  for _, bl in ipairs(broken_links) do
    qf_items[#qf_items + 1] = {
      filename = bl.file, lnum = bl.lnum,
      text = bl.text, type = "W",
    }
  end

  if #qf_items > 0 then
    vim.fn.setqflist(qf_items, "r")
    vim.fn.setqflist({}, "a", {
      title = string.format("Dwight Docs: %d/%d pages, %d broken links",
        generated, #pages, #broken_links)
    })
    vim.defer_fn(function() vim.cmd("botright copen") end, 300)
  end

  -- Summary
  status.append("")
  status.append("═══════════════════════════════════════════════")
  if #errors == 0 then
    status.append(string.format("  ✅ All %d pages generated successfully!", generated))
  else
    status.append(string.format("  📄 %d/%d pages generated, %d failed", generated, #pages, #errors))
  end
  if #broken_links > 0 then
    status.append(string.format("  ⚠️  %d broken link(s) — fix manually or re-run", #broken_links))
  end
  status.append("  Run :DwightDocsBrowse to review")
  status.append("═══════════════════════════════════════════════")

  vim.notify(string.format(
    "[dwight] 📄 Docs complete! %d/%d pages in %s/\n" ..
    "%s\n" ..
    "Run :DwightDocsBrowse to review, :copen for quickfix.",
    generated, #pages, docs_dir:match("[^/]+$"),
    #broken_links > 0
      and string.format("⚠️  %d broken link(s)", #broken_links)
      or "✅ All links valid"),
    vim.log.levels.INFO)

  if generated > 0 and vim.fn.filereadable(docs_dir .. "/index.md") == 1 then
    vim.cmd("edit " .. vim.fn.fnameescape(docs_dir .. "/index.md"))
  end
end

--- Run agentic docs generation with plan → review → per-page execution.
function M.generate_agentic(opts)
  opts = opts or {}
  local project = require("dwight.project")
  if not project.is_initialized() then
    vim.notify("[dwight] Run :DwightInit first.", vim.log.levels.WARN)
    return
  end

  local plan = M.build_plan()
  if #plan == 0 then
    vim.notify("[dwight] No pages to generate. Add @feature: or @docs: pragmas.", vim.log.levels.WARN)
    return
  end

  local adapter, fw = M.get_adapter()
  vim.fn.mkdir(adapter.docs_dir(), "p")

  -- Build the editable plan buffer
  local plan_lines = {}
  plan_lines[#plan_lines + 1] = "# 📄 DwightDocs — Agentic Documentation Plan"
  plan_lines[#plan_lines + 1] = ""
  plan_lines[#plan_lines + 1] = string.format("Framework: %s | Output: %s/", fw, adapter.docs_dir())
  plan_lines[#plan_lines + 1] = ""
  plan_lines[#plan_lines + 1] = "## Pages to Generate"
  plan_lines[#plan_lines + 1] = "Edit this list: remove lines to skip pages, reorder as needed."
  plan_lines[#plan_lines + 1] = "Each page runs as a separate agent call that reads source code."
  plan_lines[#plan_lines + 1] = ""

  local existing_count = 0
  for _, p in ipairs(plan) do
    local exists = vim.fn.filereadable(adapter.docs_dir() .. "/" .. p.path) == 1
    if exists then existing_count = existing_count + 1 end
    local icon = ({ index = "📖", ["getting-started"] = "🚀", feature = "⚙️",
      reference = "📋", guide = "📝", concept = "💡" })[p.page_type] or "📄"
    local marker = exists and " (overwrite)" or " (new)"
    local feat_str = p.feature_name and (" ← $" .. p.feature_name) or ""
    plan_lines[#plan_lines + 1] = string.format("%s %s | %s | %s%s%s",
      icon, p.path, p.page_type, p.title, feat_str, marker)
  end

  plan_lines[#plan_lines + 1] = ""
  if existing_count > 0 then
    plan_lines[#plan_lines + 1] = string.format("⚠️  %d existing page(s) will be overwritten.", existing_count)
    plan_lines[#plan_lines + 1] = ""
  end
  plan_lines[#plan_lines + 1] = "## How It Works"
  plan_lines[#plan_lines + 1] = "For each page, a dedicated agent will:"
  plan_lines[#plan_lines + 1] = "  1. Read the source files for that feature"
  plan_lines[#plan_lines + 1] = "  2. Read existing docs for style/tone"
  plan_lines[#plan_lines + 1] = "  3. Write one focused documentation page"
  plan_lines[#plan_lines + 1] = "  4. Use correct cross-references to other pages"
  plan_lines[#plan_lines + 1] = ""
  plan_lines[#plan_lines + 1] = "After all pages: navigation metadata + link verification."
  plan_lines[#plan_lines + 1] = ""
  plan_lines[#plan_lines + 1] = "────────────────────────────────────────────────────"
  plan_lines[#plan_lines + 1] = "  y/Enter = Run  |  e = Edit plan  |  q/n = Cancel"
  plan_lines[#plan_lines + 1] = "────────────────────────────────────────────────────"

  local buf = api.nvim_create_buf(false, true)
  pcall(function() api.nvim_buf_set_name(buf, "dwight://docs-plan") end)
  api.nvim_buf_set_lines(buf, 0, -1, false, _flatten(plan_lines))
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "markdown"

  vim.cmd("botright split")
  local win = api.nvim_get_current_win()
  api.nvim_win_set_buf(win, buf)
  api.nvim_win_set_height(win, math.min(#plan_lines + 2, 35))

  local function close() pcall(api.nvim_win_close, win, true) end

  --- Parse the buffer to extract the page list (after user edits).
  local function parse_plan_from_buffer()
    local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
    local parsed_pages = {}
    for _, line in ipairs(lines) do
      -- Match: icon path | page_type | title...
      local path, page_type = line:match("^.%s+(%S+%.md)%s+|%s+(%S+)%s+|")
      if path and page_type then
        -- Find the original page data
        for _, p in ipairs(plan) do
          if p.path == path then
            parsed_pages[#parsed_pages + 1] = p
            break
          end
        end
      end
    end
    return parsed_pages
  end

  local function run_pipeline()
    local final_pages = parse_plan_from_buffer()
    close()

    if #final_pages == 0 then
      vim.notify("[dwight] No pages in plan. Aborting.", vim.log.levels.WARN)
      return
    end

    vim.notify(string.format(
      "[dwight] 📄 Starting agentic docs: %d pages [%s]", #final_pages, fw),
      vim.log.levels.INFO)

    M._run_docs_pipeline(final_pages, adapter, fw, opts)
  end

  local function enable_edit()
    vim.bo[buf].modifiable = true
    vim.notify("[dwight] Plan is now editable. Delete lines to skip pages. Press 'y' when done.",
      vim.log.levels.INFO)
  end

  -- Keybindings
  local map_opts = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set("n", "y", run_pipeline, map_opts)
  vim.keymap.set("n", "<CR>", run_pipeline, map_opts)
  vim.keymap.set("n", "e", enable_edit, map_opts)
  vim.keymap.set("n", "q", close, map_opts)
  vim.keymap.set("n", "n", close, map_opts)
  vim.keymap.set("n", "<Esc>", close, map_opts)
end

return M
