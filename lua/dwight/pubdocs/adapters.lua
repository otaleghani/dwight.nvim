-- dwight/pubdocs/adapters.lua
-- Framework detection, adapter table, relative link helper.

local M = {}

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
	if manifest_fw then
		return manifest_fw
	end

	-- Docusaurus: docusaurus.config.js or .ts
	if
		vim.fn.filereadable(cwd .. "/docusaurus.config.js") == 1
		or vim.fn.filereadable(cwd .. "/docusaurus.config.ts") == 1
	then
		return "docusaurus"
	end

	-- MkDocs: mkdocs.yml
	if vim.fn.filereadable(cwd .. "/mkdocs.yml") == 1 or vim.fn.filereadable(cwd .. "/mkdocs.yaml") == 1 then
		return "mkdocs"
	end

	-- VitePress: .vitepress/config.ts or .js or .mts
	if vim.fn.isdirectory(cwd .. "/.vitepress") == 1 then
		return "vitepress"
	end

	return "plain"
end

--------------------------------------------------------------------
-- Link helpers
--------------------------------------------------------------------

--- Compute a relative link from one doc path to another.
--- e.g. _relative_link("features/auth.md", "getting-started.md") -> "../getting-started.md"
function M._relative_link(from_path, to_path)
	local from_parts = {}
	for part in from_path:gmatch("[^/]+") do
		from_parts[#from_parts + 1] = part
	end

	local to_parts = {}
	for part in to_path:gmatch("[^/]+") do
		to_parts[#to_parts + 1] = part
	end

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
		for _ = 1, ups do
			result[#result + 1] = "../"
		end
	end

	-- Append remaining path components after the common prefix
	for i = common + 1, #to_parts do
		if i > common + 1 then
			result[#result + 1] = "/"
		end
		result[#result + 1] = to_parts[i]
	end

	return table.concat(result)
end

--------------------------------------------------------------------
-- Framework adapters
--------------------------------------------------------------------

--- Each adapter provides:
---   docs_dir()        -> where to write docs
---   frontmatter(page, position) -> YAML frontmatter string
---   link(from_path, to_path, title) -> markdown link
---   write_nav(pages, docs_dir)  -> generate nav metadata, return list of files written
---   link_instructions() -> prompt text explaining link format

M.adapters = {}

M.adapters.docusaurus = {
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
			parts[#parts + 1] = string.format('description: "%s"', page.description:sub(1, 155):gsub('"', '\\"'))
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
			if dir and not categories[dir] then
				categories[dir] = true
			end
		end

		local labels = {
			features = "Features",
			reference = "API Reference",
			guides = "Guides",
			concepts = "Concepts",
		}
		local positions = {
			features = 3,
			guides = 4,
			reference = 5,
			concepts = 6,
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
			if f then
				f:write(cat .. "\n")
				f:close()
			end
			written[#written + 1] = dir_name .. "/_category_.json"
		end
		return written
	end,
}

M.adapters.mkdocs = {
	docs_dir = function()
		return vim.fn.getcwd() .. "/docs"
	end,

	frontmatter = function(page, _position)
		local parts = { "---" }
		parts[#parts + 1] = string.format('title: "%s"', (page.title or ""):gsub('"', '\\"'))
		if page.description and page.description ~= "" then
			parts[#parts + 1] = string.format('description: "%s"', page.description:sub(1, 155):gsub('"', '\\"'))
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
				if not groups[dir] then
					groups[dir] = {}
				end
				groups[dir][#groups[dir] + 1] = page
			end
		end

		local labels = {
			features = "Features",
			guides = "Guides",
			reference = "API Reference",
			concepts = "Concepts",
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
		if f then
			f:write(table.concat(nav, "\n") .. "\n")
			f:close()
		end
		return { "_nav_snippet.yml" }
	end,
}

M.adapters.vitepress = {
	docs_dir = function()
		local cwd = vim.fn.getcwd()
		if vim.fn.isdirectory(cwd .. "/docs/.vitepress") == 1 then
			return cwd .. "/docs"
		end
		return cwd .. "/docs"
	end,

	frontmatter = function(page, _position)
		local parts = { "---" }
		parts[#parts + 1] = string.format('title: "%s"', (page.title or ""):gsub('"', '\\"'))
		if page.description and page.description ~= "" then
			parts[#parts + 1] = string.format('description: "%s"', page.description:sub(1, 155):gsub('"', '\\"'))
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
				if not groups[dir] then
					groups[dir] = {}
				end
				groups[dir][#groups[dir] + 1] = page
			end
		end

		local labels = {
			features = "Features",
			guides = "Guides",
			reference = "API Reference",
			concepts = "Concepts",
		}

		local lines = {
			"// Paste into .vitepress/config.ts -> themeConfig.sidebar",
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
					lines[#lines + 1] =
						string.format('      { text: "%s", link: "%s" },', page.title:gsub('"', '\\"'), link)
				end
				lines[#lines + 1] = "    ],"
				lines[#lines + 1] = "  },"
			end
		end
		lines[#lines + 1] = "]"

		local snippet_path = target_dir .. "/_sidebar_snippet.ts"
		local f = io.open(snippet_path, "w")
		if f then
			f:write(table.concat(lines, "\n") .. "\n")
			f:close()
		end
		return { "_sidebar_snippet.ts" }
	end,
}

M.adapters.plain = {
	docs_dir = function()
		return vim.fn.getcwd() .. "/docs"
	end,

	frontmatter = function(page, _position)
		local parts = { "---" }
		parts[#parts + 1] = string.format('title: "%s"', (page.title or ""):gsub('"', '\\"'))
		if page.description and page.description ~= "" then
			parts[#parts + 1] = string.format('description: "%s"', page.description:sub(1, 155):gsub('"', '\\"'))
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
	return M.adapters[fw] or M.adapters.plain, fw
end

return M
