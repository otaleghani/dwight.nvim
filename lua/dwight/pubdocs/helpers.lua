-- dwight/pubdocs/helpers.lua
-- Shared helper functions for pubdocs sub-modules.

local M = {}

--- Minimum word count for a page to not be considered "thin content".
M.THIN_CONTENT_THRESHOLD = 300

function M.read_existing_page(adapter, path)
	local full = adapter.docs_dir() .. "/" .. path
	if vim.fn.filereadable(full) ~= 1 then
		return nil
	end
	local f = io.open(full, "r")
	if not f then
		return nil
	end
	local content = f:read("*a")
	f:close()
	return content
end

function M.write_page(adapter, page, content)
	local full_path = adapter.docs_dir() .. "/" .. page.path
	local dir = vim.fn.fnamemodify(full_path, ":h")
	vim.fn.mkdir(dir, "p")
	local f = io.open(full_path, "w")
	if f then
		f:write(content)
		f:close()
		return true
	end
	return false
end

function M.build_project_context()
	local parts = {}

	-- Use integration module for rich context if available
	pcall(function()
		local integration = require("dwight.integration")
		local ctx = integration.build_full_context()
		if ctx then
			parts[#parts + 1] = ctx
		end
	end)

	-- Fall back to features project context
	if #parts == 0 then
		pcall(function()
			local features = require("dwight.features")
			local proj = features.build_project_context()
			if proj then
				parts[#parts + 1] = proj
			end
		end)
	end

	return table.concat(parts, "\n\n")
end

function M.build_feature_context(feature_name)
	-- Try integration module first (gives signatures + source snippets)
	local ctx
	pcall(function()
		local integration = require("dwight.integration")
		ctx = integration.build_feature_context("$" .. feature_name)
	end)
	if ctx then
		return ctx
	end

	-- Fall back to features XML
	local features = require("dwight.features")
	return features.read(feature_name) or ""
end

function M.build_route_context(entries)
	local parts = {}
	local cwd = vim.fn.getcwd()
	local ts_ok, ts = pcall(require, "dwight.treesitter")

	for _, entry in ipairs(entries) do
		local rel = entry.filepath
		if rel:sub(1, #cwd + 1) == cwd .. "/" then
			rel = rel:sub(#cwd + 2)
		end

		parts[#parts + 1] = string.format('<source path="%s" line="%d">', rel, entry.pragma_line)
		if entry.description then
			parts[#parts + 1] = "  <description>" .. entry.description .. "</description>"
		end
		if ts_ok then
			local minimap = ts.minimap(entry.filepath)
			if minimap then
				parts[#parts + 1] = "  <signatures>\n" .. minimap .. "\n  </signatures>"
			end
		end
		parts[#parts + 1] = "</source>"
	end
	return table.concat(parts, "\n")
end

--- Build a docs structure listing for the LLM to use in cross-references.
--- Shows all pages with pre-built example links from the current page.
function M.build_docs_structure(pages, adapter, current_page)
	local parts = { "Available documentation pages (use these for cross-references):" }
	for _, page in ipairs(pages) do
		if page.path ~= current_page.path then
			local link = adapter.link(current_page.path, page.path, page.title)
			parts[#parts + 1] = string.format("  - %s -> %s", page.path, link)
		end
	end
	return table.concat(parts, "\n")
end

--- Build link style instructions for agent prompts based on detected style.
--- Extracts examples from existing content to show the actual format in use.
function M.link_style_instructions(link_style, pages)
	if link_style == "wikilinks" then
		-- Find a real wikilink example from the docs
		local example = nil
		for _, p in ipairs(pages) do
			if p.wiki_link_count and p.wiki_link_count > 0 then
				local content = M.read_existing_page({
					docs_dir = function()
						return vim.fn.fnamemodify(p.full_path, ":h:h")
					end,
				}, p.path)
				-- Try reading directly
				if not content then
					local f = io.open(p.full_path, "r")
					if f then
						content = f:read("*a")
						f:close()
					end
				end
				if content then
					example = content:match("%[%[[^%]]+%]%]")
				end
				if example then
					break
				end
			end
		end
		return string.format(
			[==[
## Link Format -- CRITICAL
This documentation uses **wikilinks** (Obsidian/wiki style), NOT standard markdown links.

CORRECT: [[Page Name]] or [[Page Name|Display Text]]
WRONG:   [Display Text](./path/to/page.md)
WRONG:   [Display Text](../relative/path)

%s
You MUST use wikilinks for ALL internal links. Do NOT convert existing wikilinks
to markdown links. Do NOT use relative paths in parentheses.
If adding new links to other pages, use the same wikilink format as the existing docs.
]==],
			example and ("Example from existing docs: " .. example) or ""
		)
	end

	if link_style == "mixed" then
		return [==[
## Link Format -- CRITICAL
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

return M
