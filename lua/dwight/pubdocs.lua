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
local function build_page_agent_prompt(page, all_pages, adapter, fw, link_style)
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

  -- Link format instructions (if detected from existing docs)
  if link_style and link_style ~= "markdown" then
    parts[#parts + 1] = link_style_instructions(link_style, all_pages)
  end

  -- Cross-reference map (so the agent writes correct links)
  parts[#parts + 1] = "## All Documentation Pages (for cross-references)"
  if link_style == "wikilinks" then
    parts[#parts + 1] = "Use wikilinks between pages (matching the existing docs). Available pages:"
    for _, p in ipairs(all_pages) do
      if p.path ~= page.path then
        parts[#parts + 1] = string.format("  - %s — %s → [[%s]]",
          p.path, p.title, (p.title or p.path:gsub("%.md$", "")))
      end
    end
  else
    parts[#parts + 1] = "Use relative markdown links between pages. Available pages:"
    for _, p in ipairs(all_pages) do
      if p.path ~= page.path then
        local link = adapter.link(page.path, p.path, p.title)
        parts[#parts + 1] = string.format("  - %s — %s → link: %s", p.path, p.title, link)
      end
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

  local link_hint = link_style == "wikilinks"
    and "Use wikilinks for cross-references (matching existing docs style)."
    or "Use correct relative links to other pages (see cross-reference map above)."

  parts[#parts + 1] = string.format([[

## Output
Write the page to: %s/%s
Include proper frontmatter for %s framework.
%s
Do NOT modify any source code files.
Do NOT create any files other than the one documentation page.
]], docs_dir, page.path, fw, link_hint)

  return table.concat(parts, "\n")
end

--- Execute the docs pipeline: generate pages sequentially, one agent per page.
function M._run_docs_pipeline(pages, adapter, fw, opts)
  opts = opts or {}
  local link_style = opts.link_style or "markdown"
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
  if link_style ~= "markdown" then
    status.append(string.format("   Link style: %s (preserving existing format)", link_style))
  end
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

    local prompt = build_page_agent_prompt(page, pages, adapter, fw, link_style)

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

  -- Link verification: check both markdown links and wikilinks
  local broken_links = {}
  local link_style = M.detect_link_style(pages)
  pcall(function()
    -- Build a lookup of known page titles (for wikilink resolution)
    local known_titles = {}
    local known_paths = {}
    for _, kp in ipairs(pages) do
      local path_no_ext = kp.path:gsub("%.md$", "")
      local basename = vim.fn.fnamemodify(kp.path, ":t"):gsub("%.md$", "")
      known_titles[(kp.title or ""):lower()] = kp.path
      known_paths[kp.path] = true
      known_paths[path_no_ext] = true
      known_titles[basename:lower()] = kp.path
    end

    for _, p in ipairs(pages) do
      local full = docs_dir .. "/" .. p.path
      if vim.fn.filereadable(full) == 1 then
        local f = io.open(full, "r")
        if f then
          local content = f:read("*a"); f:close()
          local line_num = 0
          for line in content:gmatch("[^\n]+") do
            line_num = line_num + 1

            -- Check markdown links: [text](path.md) or [text](../path.md)
            for link_path in line:gmatch("%]%(([^%)]+%.md[^%)]*)%)") do
              local page_dir = vim.fn.fnamemodify(p.path, ":h")
              local resolved
              if page_dir == "." then
                resolved = link_path
              else
                resolved = page_dir .. "/" .. link_path
              end
              resolved = resolved:gsub("[^/]+/%.%./", "")
              resolved = resolved:gsub("#.*$", "")

              local target = docs_dir .. "/" .. resolved
              if vim.fn.filereadable(target) ~= 1 then
                broken_links[#broken_links + 1] = {
                  file = full, lnum = line_num,
                  text = string.format("Broken link: [...](%s) → %s not found", link_path, resolved),
                }
              end
            end

            -- Check wikilinks: [[Page Name]] or [[Page Name|Display Text]]
            for wikilink in line:gmatch("%[%[([^%]]+)%]%]") do
              local target_name = wikilink:match("^([^|]+)") or wikilink
              target_name = vim.trim(target_name)
              -- Try to resolve: exact title match, basename match, or path match
              local resolved = known_titles[target_name:lower()]
              if not resolved then
                -- Try as file path
                local as_path = target_name:gsub(" ", "-") .. ".md"
                local as_path2 = target_name .. ".md"
                if not known_paths[as_path] and not known_paths[as_path2]
                  and not known_paths[target_name] and not known_paths[target_name .. ".md"] then
                  -- Check if file exists on disk (might not be in our pages list)
                  local found_on_disk = false
                  local search_paths = {
                    docs_dir .. "/" .. as_path2,
                    docs_dir .. "/" .. as_path,
                    docs_dir .. "/" .. target_name .. ".md",
                    docs_dir .. "/" .. target_name,
                  }
                  -- Also search subdirectories
                  local dir_handle = (vim.loop or vim.uv).fs_scandir(docs_dir)
                  if dir_handle then
                    while true do
                      local name, ftype = (vim.loop or vim.uv).fs_scandir_next(dir_handle)
                      if not name then break end
                      if ftype == "directory" then
                        search_paths[#search_paths + 1] = docs_dir .. "/" .. name .. "/" .. as_path2
                        search_paths[#search_paths + 1] = docs_dir .. "/" .. name .. "/" .. as_path
                      end
                    end
                  end
                  for _, sp in ipairs(search_paths) do
                    if vim.fn.filereadable(sp) == 1 then found_on_disk = true; break end
                  end
                  if not found_on_disk then
                    broken_links[#broken_links + 1] = {
                      file = full, lnum = line_num,
                      text = string.format("Broken wikilink: [[%s]] → no matching page found", wikilink),
                    }
                  end
                end
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
        text = "✅ " .. (p.title or p.path) .. " [" .. (p.page_type or "docs") .. "]",
        type = "I",
      }
    elseif is_err then
      qf_items[#qf_items + 1] = {
        filename = full_path, lnum = 1,
        text = "❌ " .. (p.title or p.path) .. " (not generated)",
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

  -- Detect link style from existing docs (if any)
  local existing = M.scan_existing_docs(adapter)
  local link_style = #existing > 0 and M.detect_link_style(existing) or "markdown"
  opts.link_style = link_style

  -- Build the editable plan buffer
  local plan_lines = {}
  plan_lines[#plan_lines + 1] = "# 📄 DwightDocs — Agentic Documentation Plan"
  plan_lines[#plan_lines + 1] = ""
  local ls_str = link_style ~= "markdown" and (" | Link style: " .. link_style) or ""
  plan_lines[#plan_lines + 1] = string.format("Framework: %s | Output: %s/%s", fw, adapter.docs_dir(), ls_str)
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

--------------------------------------------------------------------
-- Scan existing docs directory (framework-agnostic)
--------------------------------------------------------------------

--- Scan the docs directory and return a list of existing pages with metadata.
--- Works with ANY docs, not just Dwight-generated ones.
function M.scan_existing_docs(adapter)
  local dir = adapter.docs_dir()
  if vim.fn.isdirectory(dir) ~= 1 then return {} end

  local uv = vim.loop or vim.uv
  local pages = {}

  local function scan(d, prefix)
    local handle = uv.fs_scandir(d)
    if not handle then return end
    while true do
      local name, ftype = uv.fs_scandir_next(handle)
      if not name then break end
      if name:match("^[_%.]") then goto continue end
      local rel = prefix ~= "" and (prefix .. "/" .. name) or name
      if ftype == "directory" then
        scan(d .. "/" .. name, rel)
      elseif ftype == "file" and name:match("%.md$") then
        local full = d .. "/" .. name
        local stat = uv.fs_stat(full)
        local mtime = stat and stat.mtime and stat.mtime.sec or 0

        local title, description, word_count, headings, link_count, body
        local f = io.open(full, "r")
        if f then
          local content = f:read("*a"); f:close()
          body = content

          -- Frontmatter title
          title = content:match("^%-%-%-.-\ntitle:%s*\"?([^\"\n]+)\"?")
            or content:match("^%-%-%-.-\ntitle:%s*([^\n]+)")
          description = content:match("^%-%-%-.-\ndescription:%s*\"?([^\"\n]+)\"?")
            or content:match("^%-%-%-.-\ndescription:%s*([^\n]+)")
          -- Fallback: first # heading
          if not title then
            title = content:match("^#%s+([^\n]+)") or content:match("\n#%s+([^\n]+)")
          end
          if not title then title = name:gsub("%.md$", "") end

          -- Strip frontmatter for analysis
          local body_text = content:gsub("^%-%-%-.-%-%-%-\n?", "")
          -- Strip code blocks for word count
          local prose = body_text:gsub("```.-```", ""):gsub("`[^`]+`", "")
          word_count = select(2, prose:gsub("%S+", "")) or 0

          -- Extract headings
          headings = {}
          for level, text in body_text:gmatch("\n(#+)%s+([^\n]+)") do
            headings[#headings + 1] = { level = #level, text = vim.trim(text) }
          end
          -- Also first heading if at start of body
          local fl, ft = body_text:match("^(#+)%s+([^\n]+)")
          if fl then table.insert(headings, 1, { level = #fl, text = vim.trim(ft) }) end

          -- Count internal links (both styles)
          link_count = 0
          local md_link_count = 0
          local wiki_link_count = 0
          for _ in content:gmatch("%]%(.-%.md") do md_link_count = md_link_count + 1 end
          -- Also count markdown links without .md extension (Docusaurus style)
          for _ in content:gmatch("%]%([%.%/][^%)]+%)") do md_link_count = md_link_count + 1 end
          -- Wikilinks: [[Page Name]] or [[Page Name|Display Text]]
          for _ in content:gmatch("%[%[[^%]]+%]%]") do wiki_link_count = wiki_link_count + 1 end
          link_count = md_link_count + wiki_link_count
        end

        pages[#pages + 1] = {
          path = rel,
          full_path = full,
          title = vim.trim(title or ""),
          description = description and vim.trim(description) or nil,
          mtime = mtime,
          word_count = word_count or 0,
          headings = headings or {},
          link_count = link_count or 0,
          md_link_count = md_link_count or 0,
          wiki_link_count = wiki_link_count or 0,
        }
      end
      ::continue::
    end
  end
  scan(dir, "")
  table.sort(pages, function(a, b) return a.path < b.path end)
  return pages
end

--------------------------------------------------------------------
-- Link style detection: wikilinks vs markdown links
--------------------------------------------------------------------

--- Detect the dominant link style across all existing pages.
--- Returns "wikilinks" | "markdown" | "mixed"
function M.detect_link_style(pages)
  local total_md = 0
  local total_wiki = 0
  for _, p in ipairs(pages) do
    total_md = total_md + (p.md_link_count or 0)
    total_wiki = total_wiki + (p.wiki_link_count or 0)
  end
  if total_wiki > 0 and total_md == 0 then return "wikilinks" end
  if total_md > 0 and total_wiki == 0 then return "markdown" end
  if total_wiki > total_md then return "wikilinks" end
  if total_md > total_wiki then return "markdown" end
  if total_md == 0 and total_wiki == 0 then return "markdown" end
  return "mixed"
end

--- Build link style instructions for agent prompts based on detected style.
--- Extracts examples from existing content to show the actual format in use.
local function link_style_instructions(link_style, pages)
  if link_style == "wikilinks" then
    -- Find a real wikilink example from the docs
    local example = nil
    for _, p in ipairs(pages) do
      if p.wiki_link_count and p.wiki_link_count > 0 then
        local content = read_existing_page({ docs_dir = function()
          return vim.fn.fnamemodify(p.full_path, ":h:h")
        end }, p.path)
        -- Try reading directly
        if not content then
          local f = io.open(p.full_path, "r")
          if f then content = f:read("*a"); f:close() end
        end
        if content then
          example = content:match("%[%[[^%]]+%]%]")
        end
        if example then break end
      end
    end
    return string.format([==[
## Link Format — CRITICAL
This documentation uses **wikilinks** (Obsidian/wiki style), NOT standard markdown links.

CORRECT: [[Page Name]] or [[Page Name|Display Text]]
WRONG:   [Display Text](./path/to/page.md)
WRONG:   [Display Text](../relative/path)

%s
You MUST use wikilinks for ALL internal links. Do NOT convert existing wikilinks
to markdown links. Do NOT use relative paths in parentheses.
If adding new links to other pages, use the same wikilink format as the existing docs.
]==], example and ("Example from existing docs: " .. example) or "")
  end

  if link_style == "mixed" then
    return [==[
## Link Format — CRITICAL
This documentation uses a MIX of link styles. PRESERVE whatever link format
each page already uses. Do NOT convert between formats.

If a page uses wikilinks like [[Page Name]], keep using wikilinks.
If a page uses markdown links like [Text](./path.md), keep using markdown links.
Match the EXISTING style of the page you are editing.
]==]
  end

  -- Default: standard markdown
  return [[
## Link Format
Use standard markdown links with relative paths for cross-references.
Example: [Getting Started](./getting-started.md) or [Auth](../features/auth.md)
]]
end

--------------------------------------------------------------------
-- Detect stale pages: compare doc mtime with source file changes
--------------------------------------------------------------------

--- For each doc page, find recent source changes that may affect it.
--- Returns a list of { page, changes = { ... }, staleness_days }
function M._detect_stale_pages(existing_pages, adapter)
  local uv = vim.loop or vim.uv
  local stale = {}

  for _, page in ipairs(existing_pages) do
    -- Get git commits that touched files since the doc was last modified
    local since_ts = os.date("!%Y-%m-%dT%H:%M:%SZ", page.mtime)
    local cmd = string.format(
      "git log --since='%s' --name-only --pretty=format:'%%h %%s' -- . ':!%s' 2>/dev/null",
      since_ts, adapter.docs_dir():gsub("^" .. vim.pesc(vim.fn.getcwd()) .. "/?", ""))
    local output = vim.fn.system(cmd)

    if output and vim.trim(output) ~= "" then
      local changes = {}
      local current_commit = nil
      for line in output:gmatch("[^\n]+") do
        if line:match("^%x+%s") then
          current_commit = line
        elseif vim.trim(line) ~= "" and current_commit then
          changes[#changes + 1] = { commit = current_commit, file = vim.trim(line) }
        end
      end

      if #changes > 0 then
        local days_stale = math.floor((os.time() - page.mtime) / 86400)
        stale[#stale + 1] = {
          page = page,
          changes = changes,
          staleness_days = days_stale,
          change_count = #changes,
        }
      end
    end
  end

  -- Sort by staleness (most stale first)
  table.sort(stale, function(a, b) return a.change_count > b.change_count end)
  return stale
end

--------------------------------------------------------------------
-- :DwightDocs --update — update existing docs based on recent changes
--------------------------------------------------------------------

--- Build per-page agent prompt for updating an existing doc.
local function build_update_prompt(page_info, changes, all_pages, adapter, fw, link_style)
  local docs_dir = adapter.docs_dir()
  local parts = {}

  parts[#parts + 1] = string.format([[
You are UPDATING an existing documentation page: %s
Title: %s
Framework: %s
Output directory: %s/

IMPORTANT: This page already exists. You are updating it, not rewriting from scratch.
Preserve the existing structure, tone, style, and link format. Only change what needs to change.
]], page_info.path, page_info.title, fw, docs_dir)

  -- Link format instructions (detected from existing docs)
  parts[#parts + 1] = link_style_instructions(link_style, all_pages)

  -- Cross-reference map
  parts[#parts + 1] = "## Other Documentation Pages (for cross-references)"
  if link_style == "wikilinks" then
    for _, p in ipairs(all_pages) do
      if p.path ~= page_info.path then
        parts[#parts + 1] = string.format("  - %s — %s → [[%s]]",
          p.path, p.title or p.path, (p.title or p.path:gsub("%.md$", "")))
      end
    end
  else
    for _, p in ipairs(all_pages) do
      if p.path ~= page_info.path then
        local link = adapter.link(page_info.path, p.path, p.title or p.path)
        parts[#parts + 1] = string.format("  - %s → %s", p.path, link)
      end
    end
  end
  parts[#parts + 1] = ""

  -- Changes since last update
  parts[#parts + 1] = string.format("## Source Changes Since Last Update (%d days ago)", page_info.staleness_days or 0)
  parts[#parts + 1] = "These source files changed after the documentation was last modified:"
  local seen_files = {}
  local change_files = {}
  for _, c in ipairs(changes) do
    if not seen_files[c.file] then
      seen_files[c.file] = true
      change_files[#change_files + 1] = c.file
    end
  end
  for _, f in ipairs(change_files) do
    parts[#parts + 1] = "  - " .. f
  end
  parts[#parts + 1] = ""

  -- List commits for context
  local seen_commits = {}
  parts[#parts + 1] = "## Recent Commits"
  for _, c in ipairs(changes) do
    if not seen_commits[c.commit] then
      seen_commits[c.commit] = true
      parts[#parts + 1] = "  - " .. c.commit
    end
  end
  parts[#parts + 1] = ""

  parts[#parts + 1] = string.format([[
## Your Task

1. **Read the existing documentation page**: %s/%s
2. **Read the changed source files** listed above to understand what changed
3. **Read the git diffs** for the changed files: run `git diff HEAD~10..HEAD -- <file>` for each changed file (or use `git log -p` for specific commits)
4. **Update the documentation page** to reflect the changes:
   - Add documentation for new features, functions, or behaviors
   - Update examples that reference changed APIs
   - Remove documentation for removed features
   - Update any descriptions that are no longer accurate
   - Add cross-references to new pages if relevant

## Writing Guidelines
- Focus on WHAT the software does, from the user's perspective
- Do NOT explain implementation details, internal architecture, or design decisions
- Show concrete usage examples with real commands and code
- Keep the existing page structure — only add/modify sections as needed
- Preserve the tone and formatting style of the existing page
- Keep frontmatter intact (update description if page content changed significantly)
- Preserve the existing link format — do NOT convert between wikilinks and markdown links

## Output
Write the updated page to: %s/%s
Do NOT create any other files. Do NOT modify source code.
]], docs_dir, page_info.path, docs_dir, page_info.path)

  return table.concat(parts, "\n")
end

--- Run the update pipeline.
function M._run_update_pipeline(stale_pages, all_pages, adapter, fw, link_style)
  link_style = link_style or M.detect_link_style(all_pages)
  local total = #stale_pages
  local updated = 0
  local errors = {}
  local status = require("dwight.agent_status")
  local docs_dir = adapter.docs_dir()

  status.start_session(string.format("DwightDocs --update: %d pages [%s]", total, fw))
  status.append(string.format("📄 Updating %d stale documentation pages", total))
  status.append(string.format("   Link style detected: %s", link_style or "markdown"))
  status.append("")

  local idx = 0

  local function next_page()
    idx = idx + 1
    if idx > total then
      vim.schedule(function()
        M._docs_post_generate(
          vim.tbl_map(function(s) return s.page end, stale_pages),
          adapter, fw, updated, errors, status)
      end)
      return
    end

    local entry = stale_pages[idx]
    local page = entry.page

    status.append(string.format("── Page %d/%d ──────────────────────────────────", idx, total))
    status.append(string.format("  📝 %s — %s (%d changes, %d days stale)",
      page.path, page.title, entry.change_count, entry.staleness_days or 0))

    local prompt = build_update_prompt(
      vim.tbl_extend("force", page, { staleness_days = entry.staleness_days }),
      entry.changes, all_pages, adapter, fw, link_style)

    local agent = require("dwight.agent")
    agent.run(prompt, {
      plan = false,
      _skip_plan = true,
      on_complete = function(success)
        vim.schedule(function()
          if success and vim.fn.filereadable(page.full_path) == 1 then
            updated = updated + 1
            status.append(string.format("  ✅ %s updated", page.path))
          else
            errors[#errors + 1] = page.path
            status.append(string.format("  ❌ Failed to update %s", page.path))
          end
          status.append("")
          next_page()
        end)
      end,
    })
  end

  next_page()
end

--- :DwightDocs --update entry point.
function M.update_docs(opts)
  opts = opts or {}
  local adapter, fw = M.get_adapter()
  local docs_dir = adapter.docs_dir()

  if vim.fn.isdirectory(docs_dir) ~= 1 then
    vim.notify("[dwight] No docs directory found. Run :DwightDocs --agentic first.", vim.log.levels.WARN)
    return
  end

  local existing = M.scan_existing_docs(adapter)
  if #existing == 0 then
    vim.notify("[dwight] No documentation pages found in " .. docs_dir, vim.log.levels.WARN)
    return
  end

  local link_style = M.detect_link_style(existing)

  vim.notify(string.format("[dwight] 📄 Scanning %d pages for staleness…", #existing), vim.log.levels.INFO)

  local stale = M._detect_stale_pages(existing, adapter)

  -- If a specific page was targeted, run directly
  if opts.target and opts.target ~= "" then
    local target = opts.target
    if not target:match("%.md$") then target = target .. ".md" end

    local found = nil
    for _, entry in ipairs(stale) do
      if entry.page.path == target or entry.page.path:match(vim.pesc(opts.target)) then
        found = entry; break
      end
    end
    if not found then
      -- Check if the page exists but isn't stale
      local page_exists = false
      for _, p in ipairs(existing) do
        if p.path == target or p.path:match(vim.pesc(opts.target)) then
          page_exists = true; break
        end
      end
      if page_exists then
        vim.notify("[dwight] ✅ " .. opts.target .. " is up to date.", vim.log.levels.INFO)
      else
        vim.notify("[dwight] Page not found: " .. opts.target, vim.log.levels.WARN)
      end
      return
    end

    vim.notify(string.format("[dwight] 📝 Updating %s (%d changes, %d days stale)…",
      found.page.path, found.change_count, found.staleness_days or 0), vim.log.levels.INFO)
    M._run_update_pipeline({ found }, existing, adapter, fw, link_style)
    return
  end

  if #stale == 0 then
    vim.notify(string.format(
      "[dwight] ✅ All %d pages are up to date! No source changes since last docs update.",
      #existing), vim.log.levels.INFO)
    return
  end

  -- Build plan buffer
  local plan_lines = {}
  plan_lines[#plan_lines + 1] = "# 📝 DwightDocs — Update Stale Pages"
  plan_lines[#plan_lines + 1] = ""
  plan_lines[#plan_lines + 1] = string.format("Framework: %s | Docs: %s/ | Link style: %s", fw, docs_dir, link_style)
  plan_lines[#plan_lines + 1] = string.format("Scanned: %d pages | Stale: %d", #existing, #stale)
  plan_lines[#plan_lines + 1] = ""
  plan_lines[#plan_lines + 1] = "## Pages to Update"
  plan_lines[#plan_lines + 1] = "Remove lines to skip pages. Each page runs as a focused agent call."
  plan_lines[#plan_lines + 1] = ""

  for _, entry in ipairs(stale) do
    local p = entry.page
    local unique_files = {}
    local seen = {}
    for _, c in ipairs(entry.changes) do
      if not seen[c.file] then seen[c.file] = true; unique_files[#unique_files + 1] = c.file end
    end
    local files_str = #unique_files <= 3
      and table.concat(unique_files, ", ")
      or string.format("%s (+%d more)", table.concat({unique_files[1], unique_files[2]}, ", "), #unique_files - 2)

    plan_lines[#plan_lines + 1] = string.format("📝 %s | %dd stale | %d changes | %s",
      p.path, entry.staleness_days or 0, entry.change_count, files_str)
  end

  plan_lines[#plan_lines + 1] = ""
  plan_lines[#plan_lines + 1] = "## What Each Agent Will Do"
  plan_lines[#plan_lines + 1] = "  1. Read the existing documentation page"
  plan_lines[#plan_lines + 1] = "  2. Read the source files that changed since last update"
  plan_lines[#plan_lines + 1] = "  3. Read git diffs to understand what changed"
  plan_lines[#plan_lines + 1] = "  4. Update the page: add new content, fix outdated info, remove stale sections"
  plan_lines[#plan_lines + 1] = ""
  plan_lines[#plan_lines + 1] = "────────────────────────────────────────────────────"
  plan_lines[#plan_lines + 1] = "  y/Enter = Run  |  e = Edit plan  |  q/n = Cancel"
  plan_lines[#plan_lines + 1] = "────────────────────────────────────────────────────"

  local buf = api.nvim_create_buf(false, true)
  pcall(function() api.nvim_buf_set_name(buf, "dwight://docs-update-plan") end)
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

  local function parse_plan()
    local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
    local selected = {}
    for _, line in ipairs(lines) do
      local path = line:match("^📝%s+(%S+%.md)%s+|")
      if path then
        for _, entry in ipairs(stale) do
          if entry.page.path == path then
            selected[#selected + 1] = entry
            break
          end
        end
      end
    end
    return selected
  end

  local function run_pipeline()
    local selected = parse_plan()
    close()
    if #selected == 0 then
      vim.notify("[dwight] No pages selected.", vim.log.levels.WARN)
      return
    end
    vim.notify(string.format("[dwight] 📝 Updating %d stale page(s)…", #selected), vim.log.levels.INFO)
    M._run_update_pipeline(selected, existing, adapter, fw, link_style)
  end

  local function enable_edit()
    vim.bo[buf].modifiable = true
    vim.notify("[dwight] Plan is editable. Delete lines to skip pages. Press 'y' when done.",
      vim.log.levels.INFO)
  end

  local map_opts = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set("n", "y", run_pipeline, map_opts)
  vim.keymap.set("n", "<CR>", run_pipeline, map_opts)
  vim.keymap.set("n", "e", enable_edit, map_opts)
  vim.keymap.set("n", "q", close, map_opts)
  vim.keymap.set("n", "n", close, map_opts)
  vim.keymap.set("n", "<Esc>", close, map_opts)
end

--------------------------------------------------------------------
-- SEO Audit: comprehensive page analysis
--------------------------------------------------------------------

--- Minimum word count for a page to not be considered "thin content".
local THIN_CONTENT_THRESHOLD = 300

--- Run a full SEO audit on all pages. Returns enriched page list.
function M._seo_audit(existing_pages, adapter)
  for _, page in ipairs(existing_pages) do
    local issues = {}

    -- Meta description
    if not page.description or page.description == "" then
      issues[#issues + 1] = "no meta description"
    elseif #page.description < 50 then
      issues[#issues + 1] = "short description (" .. #page.description .. " chars)"
    elseif #page.description > 160 then
      issues[#issues + 1] = "long description (" .. #page.description .. " chars, truncated in SERP)"
    end

    -- Title
    if page.title and #page.title < 10 then
      issues[#issues + 1] = "short title"
    elseif page.title and #page.title > 60 then
      issues[#issues + 1] = "long title (" .. #page.title .. " chars, truncated in SERP)"
    end

    -- Internal links
    if page.link_count < 2 then
      issues[#issues + 1] = page.link_count == 0 and "no internal links" or "1 internal link"
    end

    -- Thin content
    if page.word_count < THIN_CONTENT_THRESHOLD then
      issues[#issues + 1] = string.format("thin content (%d words, min %d)", page.word_count, THIN_CONTENT_THRESHOLD)
    end

    -- Heading structure
    if #page.headings == 0 then
      issues[#issues + 1] = "no headings"
    else
      local has_h1 = false
      for _, h in ipairs(page.headings) do
        if h.level == 1 then has_h1 = true; break end
      end
      if not has_h1 then issues[#issues + 1] = "no H1 heading" end
    end

    page.seo_issues = issues
  end

  -- Detect merge candidates: pages with overlapping headings or in the same directory with low word count
  local merge_groups = {}
  for i, pa in ipairs(existing_pages) do
    for j = i + 1, #existing_pages do
      local pb = existing_pages[j]
      local score = 0

      -- Same directory → related topics
      local dir_a = pa.path:match("^(.+)/") or ""
      local dir_b = pb.path:match("^(.+)/") or ""
      if dir_a == dir_b and dir_a ~= "" then score = score + 1 end

      -- Both thin → strong merge candidate
      if pa.word_count < THIN_CONTENT_THRESHOLD and pb.word_count < THIN_CONTENT_THRESHOLD then
        score = score + 2
      elseif pa.word_count < THIN_CONTENT_THRESHOLD or pb.word_count < THIN_CONTENT_THRESHOLD then
        score = score + 1
      end

      -- Overlapping headings (normalized lowercase comparison)
      local headings_a = {}
      for _, h in ipairs(pa.headings) do
        headings_a[h.text:lower():gsub("[^%w%s]", "")] = true
      end
      for _, h in ipairs(pb.headings) do
        local normalized = h.text:lower():gsub("[^%w%s]", "")
        if headings_a[normalized] then score = score + 2 end
      end

      -- Title word overlap
      local words_a = {}
      for w in pa.title:lower():gmatch("%w+") do
        if #w > 3 then words_a[w] = true end  -- skip short words
      end
      local overlap = 0
      for w in pb.title:lower():gmatch("%w+") do
        if #w > 3 and words_a[w] then overlap = overlap + 1 end
      end
      if overlap >= 2 then score = score + 2
      elseif overlap >= 1 then score = score + 1
      end

      if score >= 3 then
        merge_groups[#merge_groups + 1] = {
          page_a = pa, page_b = pb, score = score,
          reason = (pa.word_count < THIN_CONTENT_THRESHOLD or pb.word_count < THIN_CONTENT_THRESHOLD)
            and "thin + related"
            or "overlapping content",
        }
      end
    end
  end
  table.sort(merge_groups, function(a, b) return a.score > b.score end)

  return merge_groups
end

--------------------------------------------------------------------
-- :DwightDocs --seo — optimize existing docs for SEO
--------------------------------------------------------------------

--- Build per-page agent prompt for SEO optimization.
local function build_seo_prompt(page_info, all_pages, adapter, fw, merge_candidates, link_style)
  local docs_dir = adapter.docs_dir()
  local parts = {}

  parts[#parts + 1] = string.format([[
You are optimizing an existing documentation page for SEO and discoverability: %s
Title: %s
Framework: %s
Output directory: %s/
Word count: %d words
Internal links: %d
]], page_info.path, page_info.title, fw, docs_dir,
    page_info.word_count or 0, page_info.link_count or 0)

  -- Link format instructions (detected from existing docs)
  parts[#parts + 1] = link_style_instructions(link_style, all_pages)

  -- SEO issues found
  if page_info.seo_issues and #page_info.seo_issues > 0 then
    parts[#parts + 1] = "## SEO Issues Detected"
    for _, issue in ipairs(page_info.seo_issues) do
      parts[#parts + 1] = "  ⚠️  " .. issue
    end
    parts[#parts + 1] = ""
  end

  -- Cross-reference map for internal linking
  parts[#parts + 1] = "## All Documentation Pages (for internal linking)"
  parts[#parts + 1] = "Internal links are critical for SEO. Link to related pages where natural:"
  if link_style == "wikilinks" then
    for _, p in ipairs(all_pages) do
      if p.path ~= page_info.path then
        local extra = ""
        if p.word_count and p.word_count > 0 then
          extra = string.format(" (%d words)", p.word_count)
        end
        parts[#parts + 1] = string.format("  - %s — %s%s → [[%s]]",
          p.path, p.title or "", extra, (p.title or p.path:gsub("%.md$", "")))
      end
    end
  else
    for _, p in ipairs(all_pages) do
      if p.path ~= page_info.path then
        local link = adapter.link(page_info.path, p.path, p.title or p.path)
        local extra = ""
        if p.word_count and p.word_count > 0 then
          extra = string.format(" (%d words)", p.word_count)
        end
        parts[#parts + 1] = string.format("  - %s — %s%s → %s", p.path, p.title or "", extra, link)
      end
    end
  end
  parts[#parts + 1] = ""

  -- Merge candidates
  if merge_candidates and #merge_candidates > 0 then
    parts[#parts + 1] = "## Merge Candidates"
    parts[#parts + 1] = "These pages overlap with this one and could be absorbed into it:"
    for _, mc in ipairs(merge_candidates) do
      local other = mc.page_a.path == page_info.path and mc.page_b or mc.page_a
      parts[#parts + 1] = string.format("  - %s — \"%s\" (%d words) — reason: %s",
        other.path, other.title, other.word_count or 0, mc.reason)
      -- Show headings of the merge candidate
      if other.headings and #other.headings > 0 then
        local heading_strs = {}
        for _, h in ipairs(other.headings) do
          heading_strs[#heading_strs + 1] = string.rep("#", h.level) .. " " .. h.text
        end
        parts[#parts + 1] = "    Headings: " .. table.concat(heading_strs, " | ")
      end
    end
    parts[#parts + 1] = ""
    parts[#parts + 1] = [[
If a merge candidate is truly redundant with this page:
  1. READ the candidate page to get its unique content
  2. INCORPORATE any useful content from it into this page
  3. DELETE the candidate page (remove the file)
  4. Any other pages that linked to the deleted page should be updated
     to point to this page instead — but only update THIS page's links for now.
Only merge if it genuinely makes sense. Don't merge unrelated pages.]]
    parts[#parts + 1] = ""
  end

  -- Thin content specific instructions
  local is_thin = page_info.word_count and page_info.word_count < THIN_CONTENT_THRESHOLD
  if is_thin then
    parts[#parts + 1] = string.format([[
## ⚠️  Thin Content — This Page Needs Expansion

This page has only %d words (minimum recommended: %d).
Thin pages hurt SEO ranking and provide poor user experience.

To expand this page:
1. Read the SOURCE CODE for features this page documents
2. Add practical, real-world examples with code snippets
3. Add a "Common Use Cases" or "Examples" section
4. Expand any terse descriptions into full explanations
5. Add FAQ-style subsections for questions users commonly ask
6. If this page covers a feature, show complete usage workflows

Do NOT pad with filler. Every sentence must add real value.
Read the actual source files to find content worth documenting.
]], page_info.word_count, THIN_CONTENT_THRESHOLD)
  end

  -- Current description status
  if page_info.description then
    parts[#parts + 1] = "Current meta description: " .. page_info.description
  else
    parts[#parts + 1] = "⚠️  No meta description found — this is critical for SEO."
  end
  parts[#parts + 1] = ""

  parts[#parts + 1] = string.format([[
## Your Task

1. **Read the existing page**: %s/%s%s
2. **Optimize it for search engines** while preserving accuracy and readability:

### Frontmatter
- Ensure `title:` is descriptive, includes key terms users would search for (50-60 chars)
- Ensure `description:` is a compelling summary for search results (120-155 chars)
- The description should answer "what does this page help me do?"

### Content Structure
- The H1 should match the title but can be slightly different (more human-readable)
- Use H2/H3 headings that contain searchable phrases (what users actually type)
- Every heading should describe WHAT something does, not HOW it works internally
- First paragraph should be a clear, keyword-rich summary of the page topic
- Bad: "Architecture of the Authentication Module"
- Good: "User Authentication — Login, Registration, and Session Management"

### Internal Linking
- Add natural links to related pages throughout the content
- Use descriptive anchor text (not "click here" or "see docs")
- Every page should link to at least 2-3 other pages
- PRESERVE the existing link format used in these docs (see Link Format section above)
]], docs_dir, page_info.path,
    is_thin and "\n3. **Read source code** to find real content to expand this page with" or "")

  -- Add link-format-specific examples
  if link_style == "wikilinks" then
    parts[#parts + 1] = [==[
- Good: "Once authenticated, users can [[API Key Management|manage their API keys]] from the dashboard."
- Bad: "For more info, see [[API Keys|here]]."
- WRONG: "users can [manage their API keys](./api-keys)" — do NOT use markdown links
]==]
  else
    parts[#parts + 1] = [[
- Good: "Once authenticated, users can [manage their API keys](./api-keys) from the dashboard."
- Bad: "For more info, see [here](./api-keys)."
]]
  end

  parts[#parts + 1] = string.format([[
### Content Quality
- Lead with WHAT the feature does from the user's perspective
- Remove implementation details, internal architecture explanations, and developer-facing jargon
- Add practical examples that show real usage
- Ensure code examples are complete and copy-pasteable
- Remove filler phrases: "In this section we will discuss…", "As mentioned above…"
- Every sentence should add value for the reader

### Keywords
- Use natural variations of key terms throughout (don't keyword-stuff)
- Include the primary topic in the first 100 words
- Use related terms that users might search for

## Writing Guidelines
- Focus on WHAT the software does from the user's perspective
- Write for users searching Google/docs for how to accomplish a task
- Do NOT explain internal implementation, design patterns, or architecture
- Keep the same overall page structure — optimize within it
- Preserve all existing information that is accurate and user-relevant
- Preserve the existing link format — do NOT convert between wikilinks and markdown links
- Keep frontmatter format appropriate for %s framework

## Output
Write the optimized page to: %s/%s
]], fw, docs_dir, page_info.path)

  if merge_candidates and #merge_candidates > 0 then
    parts[#parts + 1] = "If you merged a candidate page, delete that file too."
  end
  parts[#parts + 1] = "Do NOT create any new files (other than this page). Do NOT modify source code."

  return table.concat(parts, "\n")
end

--- Run the SEO optimization pipeline.
function M._run_seo_pipeline(pages, all_pages, adapter, fw, merge_groups, link_style)
  link_style = link_style or M.detect_link_style(all_pages)
  local total = #pages
  local optimized = 0
  local errors = {}
  local status = require("dwight.agent_status")
  local docs_dir = adapter.docs_dir()

  status.start_session(string.format("DwightDocs --seo: %d pages [%s]", total, fw))
  status.append(string.format("🔍 Optimizing %d documentation pages for SEO", total))
  status.append(string.format("   Link style detected: %s", link_style or "markdown"))
  status.append("")

  local idx = 0

  local function next_page()
    idx = idx + 1
    if idx > total then
      vim.schedule(function()
        M._docs_post_generate(pages, adapter, fw, optimized, errors, status)
      end)
      return
    end

    local page = pages[idx]
    local is_thin = page.word_count and page.word_count < THIN_CONTENT_THRESHOLD

    status.append(string.format("── Page %d/%d ──────────────────────────────────", idx, total))
    local extra = is_thin
      and string.format(" ⚠️ thin (%d words)", page.word_count)
      or string.format(" (%d words)", page.word_count or 0)
    status.append(string.format("  🔍 %s — %s%s", page.path, page.title, extra))

    -- Find merge candidates relevant to this page
    local page_merges = {}
    if merge_groups then
      for _, mg in ipairs(merge_groups) do
        if mg.page_a.path == page.path or mg.page_b.path == page.path then
          page_merges[#page_merges + 1] = mg
        end
      end
    end
    if #page_merges > 0 then
      for _, mg in ipairs(page_merges) do
        local other = mg.page_a.path == page.path and mg.page_b or mg.page_a
        status.append(string.format("    → merge candidate: %s (%s)", other.path, mg.reason))
      end
    end

    local prompt = build_seo_prompt(page, all_pages, adapter, fw, page_merges, link_style)

    local agent = require("dwight.agent")
    agent.run(prompt, {
      plan = false,
      _skip_plan = true,
      on_complete = function(success)
        vim.schedule(function()
          if success and vim.fn.filereadable(page.full_path) == 1 then
            optimized = optimized + 1
            status.append(string.format("  ✅ %s optimized", page.path))
          else
            errors[#errors + 1] = page.path
            status.append(string.format("  ❌ Failed to optimize %s", page.path))
          end
          status.append("")
          next_page()
        end)
      end,
    })
  end

  next_page()
end

--- :DwightDocs --seo [page] entry point.
function M.seo_optimize(opts)
  opts = opts or {}
  local adapter, fw = M.get_adapter()
  local docs_dir = adapter.docs_dir()

  if vim.fn.isdirectory(docs_dir) ~= 1 then
    vim.notify("[dwight] No docs directory found.", vim.log.levels.WARN)
    return
  end

  local existing = M.scan_existing_docs(adapter)
  if #existing == 0 then
    vim.notify("[dwight] No documentation pages found in " .. docs_dir, vim.log.levels.WARN)
    return
  end

  -- Run full SEO audit
  local merge_groups = M._seo_audit(existing, adapter)
  local link_style = M.detect_link_style(existing)

  -- If a specific page was targeted, run directly (no plan buffer)
  if opts.target and opts.target ~= "" then
    local target = opts.target
    -- Normalize: allow "features/auth" or "features/auth.md"
    if not target:match("%.md$") then target = target .. ".md" end

    local found = nil
    for _, p in ipairs(existing) do
      if p.path == target or p.path:match(vim.pesc(opts.target)) then
        found = p; break
      end
    end
    if not found then
      vim.notify("[dwight] Page not found: " .. opts.target, vim.log.levels.WARN)
      return
    end

    local issue_str = found.seo_issues and #found.seo_issues > 0
      and ": " .. table.concat(found.seo_issues, ", ")
      or " (no issues detected, optimizing anyway)"
    vim.notify(string.format("[dwight] 🔍 SEO optimizing %s%s", found.path, issue_str),
      vim.log.levels.INFO)

    M._run_seo_pipeline({ found }, existing, adapter, fw, merge_groups, link_style)
    return
  end

  -- Count issues
  local issue_count = 0
  local thin_count = 0
  for _, p in ipairs(existing) do
    if p.seo_issues and #p.seo_issues > 0 then issue_count = issue_count + 1 end
    if p.word_count < THIN_CONTENT_THRESHOLD then thin_count = thin_count + 1 end
  end

  -- Build plan buffer
  local plan_lines = {}
  plan_lines[#plan_lines + 1] = "# 🔍 DwightDocs — SEO Optimization"
  plan_lines[#plan_lines + 1] = ""
  plan_lines[#plan_lines + 1] = string.format("Framework: %s | Docs: %s/ | Link style: %s", fw, docs_dir, link_style)
  plan_lines[#plan_lines + 1] = string.format(
    "Total pages: %d | Issues: %d | Thin content: %d | Merge candidates: %d",
    #existing, issue_count, thin_count, #merge_groups)
  plan_lines[#plan_lines + 1] = ""

  -- Merge candidates section
  if #merge_groups > 0 then
    plan_lines[#plan_lines + 1] = "## Merge Candidates"
    plan_lines[#plan_lines + 1] = "These page pairs overlap and the agent may merge them:"
    for _, mg in ipairs(merge_groups) do
      plan_lines[#plan_lines + 1] = string.format("  %s ↔ %s — %s (score %d)",
        mg.page_a.path, mg.page_b.path, mg.reason, mg.score)
    end
    plan_lines[#plan_lines + 1] = ""
  end

  plan_lines[#plan_lines + 1] = "## Pages to Optimize"
  plan_lines[#plan_lines + 1] = "Remove lines to skip pages. Each page runs as a focused agent call."
  plan_lines[#plan_lines + 1] = ""

  -- Sort: pages with issues first
  local sorted = vim.deepcopy(existing)
  table.sort(sorted, function(a, b)
    local a_issues = a.seo_issues and #a.seo_issues or 0
    local b_issues = b.seo_issues and #b.seo_issues or 0
    if a_issues ~= b_issues then return a_issues > b_issues end
    return (a.word_count or 0) < (b.word_count or 0)
  end)

  for _, page in ipairs(sorted) do
    local flags = {}
    if page.word_count < THIN_CONTENT_THRESHOLD then
      flags[#flags + 1] = string.format("⚠️ thin(%dw)", page.word_count)
    end
    if not page.description or page.description == "" then
      flags[#flags + 1] = "⚠️ no desc"
    end
    if page.link_count < 2 then
      flags[#flags + 1] = "⚠️ links:" .. page.link_count
    end
    -- Check if this page is a merge candidate
    for _, mg in ipairs(merge_groups) do
      if mg.page_a.path == page.path or mg.page_b.path == page.path then
        local other = mg.page_a.path == page.path and mg.page_b or mg.page_a
        flags[#flags + 1] = "↔ " .. other.path
        break  -- show only first merge match
      end
    end

    local flag_str = #flags > 0 and " " .. table.concat(flags, " | ") or " ✓"
    plan_lines[#plan_lines + 1] = string.format("🔍 %s | %dw | %s%s",
      page.path, page.word_count, page.title, flag_str)
  end

  plan_lines[#plan_lines + 1] = ""
  plan_lines[#plan_lines + 1] = "## What Each Agent Will Do"
  plan_lines[#plan_lines + 1] = "  1. Read the existing page"
  plan_lines[#plan_lines + 1] = "  2. Optimize title and meta description for search"
  plan_lines[#plan_lines + 1] = "  3. Improve headings to match user search intent"
  plan_lines[#plan_lines + 1] = "  4. Add internal links to related pages"
  plan_lines[#plan_lines + 1] = "  5. Tighten content: lead with WHAT, not HOW or WHY"
  if thin_count > 0 then
    plan_lines[#plan_lines + 1] = "  6. Expand thin pages by reading source code for real content"
  end
  if #merge_groups > 0 then
    plan_lines[#plan_lines + 1] = string.format(
      "  %d. Merge overlapping pages where it makes sense",
      thin_count > 0 and 7 or 6)
  end
  plan_lines[#plan_lines + 1] = ""
  plan_lines[#plan_lines + 1] = "────────────────────────────────────────────────────"
  plan_lines[#plan_lines + 1] = "  y/Enter = Run  |  e = Edit plan  |  q/n = Cancel"
  plan_lines[#plan_lines + 1] = "────────────────────────────────────────────────────"

  local buf = api.nvim_create_buf(false, true)
  pcall(function() api.nvim_buf_set_name(buf, "dwight://docs-seo-plan") end)
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

  local function parse_plan()
    local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
    local selected = {}
    for _, line in ipairs(lines) do
      local path = line:match("^🔍%s+(%S+%.md)%s+|")
      if path then
        for _, p in ipairs(sorted) do
          if p.path == path then
            selected[#selected + 1] = p
            break
          end
        end
      end
    end
    return selected
  end

  local function run_pipeline()
    local selected = parse_plan()
    close()
    if #selected == 0 then
      vim.notify("[dwight] No pages selected.", vim.log.levels.WARN)
      return
    end
    vim.notify(string.format("[dwight] 🔍 Optimizing %d page(s) for SEO…", #selected), vim.log.levels.INFO)
    M._run_seo_pipeline(selected, existing, adapter, fw, merge_groups, link_style)
  end

  local function enable_edit()
    vim.bo[buf].modifiable = true
    vim.notify("[dwight] Plan is editable. Delete lines to skip pages. Press 'y' when done.",
      vim.log.levels.INFO)
  end

  local map_opts = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set("n", "y", run_pipeline, map_opts)
  vim.keymap.set("n", "<CR>", run_pipeline, map_opts)
  vim.keymap.set("n", "e", enable_edit, map_opts)
  vim.keymap.set("n", "q", close, map_opts)
  vim.keymap.set("n", "n", close, map_opts)
  vim.keymap.set("n", "<Esc>", close, map_opts)
end

return M
