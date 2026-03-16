-- dwight/pubdocs/agentic.lua
-- Agentic docs: planned multi-step generation.
-- Phase 1: Build plan from features + let user edit
-- Phase 2: Per-page agent calls that read source -> write page
-- Phase 3: Link verification + navigation metadata

local M = {}

local api = vim.api
local _flatten = require("dwight.util").flatten_lines

--- Build a focused agent prompt for generating a single documentation page.
--- The agent reads source files, existing docs, and writes ONE page.
function M.build_page_agent_prompt(page, all_pages, adapter, fw, link_style)
	local features = require("dwight.features")
	local helpers = require("dwight.pubdocs.helpers")
	local docs_dir = adapter.docs_dir()
	local parts = {}

	-- Page identity
	parts[#parts + 1] = string.format(
		[[
You are writing ONE documentation page: %s
Page title: %s
Page type: %s
Framework: %s
Output directory: %s/
]],
		page.path,
		page.title,
		page.page_type,
		fw,
		docs_dir
	)

	-- Link format instructions (if detected from existing docs)
	if link_style and link_style ~= "markdown" then
		parts[#parts + 1] = helpers.link_style_instructions(link_style, all_pages)
	end

	-- Cross-reference map (so the agent writes correct links)
	parts[#parts + 1] = "## All Documentation Pages (for cross-references)"
	if link_style == "wikilinks" then
		parts[#parts + 1] = "Use wikilinks between pages (matching the existing docs). Available pages:"
		for _, p in ipairs(all_pages) do
			if p.path ~= page.path then
				parts[#parts + 1] =
					string.format("  - %s — %s → [[%s]]", p.path, p.title, (p.title or p.path:gsub("%.md$", "")))
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
	local existing = helpers.read_existing_page(adapter, page.path)
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
				local other = helpers.read_existing_page(adapter, p.path)
				if other then
					style_ref = other:sub(1, 1500)
					parts[#parts + 1] =
						string.format("## Style Reference (from %s — match this tone and formatting)", p.path)
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

		feature = string.format(
			[[
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
Write for END USERS. Minimize implementation details.]],
			page.feature_name or "?"
		),

		reference = [[
## Writing Instructions
Create an API reference page. Be precise and compact.

For each function/method: signature, parameters, return type, description, example.
Read the source files and extract REAL signatures — do not guess.
Use code blocks for signatures and examples.]],

		guide = [[
## Writing Instructions
Create a how-to guide. Focus on practical steps.

Structure: prerequisites -> numbered steps with code -> troubleshooting.
Be step-by-step. Show working code at each step.]],

		concept = [[
## Writing Instructions
Create a concept/explanation page. Help users understand WHY, not just HOW.

Structure: what it is -> background -> how it works -> implications.
Be clear, educational. Use analogies if helpful.]],
	}

	parts[#parts + 1] = type_instructions[page.page_type]
		or [[
## Writing Instructions
Create a documentation page based on the source context.
Read the relevant source files first. Be clear, user-focused, include real examples.]]

	local link_hint = link_style == "wikilinks" and "Use wikilinks for cross-references (matching existing docs style)."
		or "Use correct relative links to other pages (see cross-reference map above)."

	parts[#parts + 1] = string.format(
		[[

## Output
Write the page to: %s/%s
Include proper frontmatter for %s framework.
%s
Do NOT modify any source code files.
Do NOT create any files other than the one documentation page.
]],
		docs_dir,
		page.path,
		fw,
		link_hint
	)

	return table.concat(parts, "\n")
end

--- Execute the docs pipeline: generate pages sequentially, one agent per page.
function M._run_docs_pipeline(pages, adapter, fw, opts)
	opts = opts or {}
	local helpers = require("dwight.pubdocs.helpers")
	local scan = require("dwight.pubdocs.scan")
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
	status.append_hl(string.format("Generating %d documentation pages", total), "DwightHeader")
	status.append_hl(string.format("  Framework: %s → %s/", fw, docs_dir), "DwightDim")
	if link_style ~= "markdown" then
		status.append_hl(string.format("  Link style: %s", link_style), "DwightDim")
	end
	status.append("")

	-- Sequential execution: one page at a time
	local idx = 0

	local function next_page()
		idx = idx + 1
		if idx > total then
			-- All pages done -> post-generation: nav metadata + link verification + quickfix
			vim.schedule(function()
				M._docs_post_generate(pages, adapter, fw, generated, errors, status)
			end)
			return
		end

		local page = pages[idx]
		local icon = ({
			index = "📖",
			["getting-started"] = "🚀",
			feature = "⚙️",
			reference = "📋",
			guide = "📝",
			concept = "💡",
		})[page.page_type] or "📄"

		status.append_hl(string.format("── Page %d/%d: %s", idx, total, page.title), "DwightHeader")
		status.append_hl(string.format("  %s", page.path), "DwightDim")

		local prompt = M.build_page_agent_prompt(page, pages, adapter, fw, link_style)

		local agent = require("dwight.agent")
		agent.run(prompt, {
			plan = false,
			_skip_plan = true,
			on_complete = function(success)
				vim.schedule(function()
					local full_path = docs_dir .. "/" .. page.path
					if success and vim.fn.filereadable(full_path) == 1 then
						generated = generated + 1
						status.append_hl(string.format("  ● %s written", page.path), "DwightOK")
					else
						errors[#errors + 1] = page.path
						if success then
							status.append_hl(string.format("  ✗ %s not created", page.path), "DwightWarn")
						else
							status.append_hl(string.format("  ✗ %s failed", page.path), "DwightFail")
						end
					end

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
	local scan = require("dwight.pubdocs.scan")
	local docs_dir = adapter.docs_dir()

	status.append("")
	status.append(string.rep("═", 40))
	status.append_hl("  Post-Generation", "DwightHeader")

	-- Generate navigation metadata
	local nav_files = {}
	pcall(function()
		nav_files = adapter.write_nav(pages, docs_dir)
		if #nav_files > 0 then
			status.append_hl(string.format("  ● %d navigation file(s)", #nav_files), "DwightDim")
		end
	end)

	-- Link verification: check both markdown links and wikilinks
	local broken_links = {}
	local link_style = scan.detect_link_style(pages)
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
					local content = f:read("*a")
					f:close()
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
									file = full,
									lnum = line_num,
									text = string.format(
										"Broken link: [...](%s) → %s not found",
										link_path,
										resolved
									),
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
								if
									not known_paths[as_path]
									and not known_paths[as_path2]
									and not known_paths[target_name]
									and not known_paths[target_name .. ".md"]
								then
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
											if not name then
												break
											end
											if ftype == "directory" then
												search_paths[#search_paths + 1] = docs_dir
													.. "/"
													.. name
													.. "/"
													.. as_path2
												search_paths[#search_paths + 1] = docs_dir
													.. "/"
													.. name
													.. "/"
													.. as_path
											end
										end
									end
									for _, sp in ipairs(search_paths) do
										if vim.fn.filereadable(sp) == 1 then
											found_on_disk = true
											break
										end
									end
									if not found_on_disk then
										broken_links[#broken_links + 1] = {
											file = full,
											lnum = line_num,
											text = string.format(
												"Broken wikilink: [[%s]] → no matching page found",
												wikilink
											),
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
		status.append_hl(string.format("  ✗ %d broken link(s)", #broken_links), "DwightWarn")
		local link_lines = {}
		for _, bl in ipairs(broken_links) do
			link_lines[#link_lines + 1] = bl.text
		end
		status.append_fold("    ▸ Broken links", link_lines)
	else
		status.append_hl("  ● All links verified", "DwightOK")
	end

	-- Build quickfix
	local qf_items = {}
	for _, p in ipairs(pages) do
		local full_path = docs_dir .. "/" .. p.path
		local is_err = false
		for _, e in ipairs(errors) do
			if e == p.path then
				is_err = true
				break
			end
		end
		if vim.fn.filereadable(full_path) == 1 then
			qf_items[#qf_items + 1] = {
				filename = full_path,
				lnum = 1,
				text = "✅ " .. (p.title or p.path) .. " [" .. (p.page_type or "docs") .. "]",
				type = "I",
			}
		elseif is_err then
			qf_items[#qf_items + 1] = {
				filename = full_path,
				lnum = 1,
				text = "❌ " .. (p.title or p.path) .. " (not generated)",
				type = "E",
			}
		end
	end

	-- Add broken links to quickfix
	for _, bl in ipairs(broken_links) do
		qf_items[#qf_items + 1] = {
			filename = bl.file,
			lnum = bl.lnum,
			text = bl.text,
			type = "W",
		}
	end

	if #qf_items > 0 then
		vim.fn.setqflist(qf_items, "r")
		vim.fn.setqflist({}, "a", {
			title = string.format("Dwight Docs: %d/%d pages, %d broken links", generated, #pages, #broken_links),
		})
		vim.defer_fn(function()
			vim.cmd("botright copen")
		end, 300)
	end

	-- Summary
	status.append("")
	status.append(string.rep("═", 40))
	if #errors == 0 then
		status.append_hl(string.format("  ● All %d pages generated", generated), "DwightOK")
	else
		status.append_hl(string.format("  %d/%d pages generated, %d failed", generated, #pages, #errors), "DwightWarn")
	end
	if #broken_links > 0 then
		status.append_hl(string.format("  %d broken link(s)", #broken_links), "DwightWarn")
	end
	status.append_hl("  :DwightDocsBrowse to review", "DwightDim")
	status.append(string.rep("═", 40))

	vim.notify(
		string.format(
			"[dwight] 📄 Docs complete! %d/%d pages in %s/\n"
				.. "%s\n"
				.. "Run :DwightDocsBrowse to review, :copen for quickfix.",
			generated,
			#pages,
			docs_dir:match("[^/]+$"),
			#broken_links > 0 and string.format("⚠️  %d broken link(s)", #broken_links) or "✅ All links valid"
		),
		vim.log.levels.INFO
	)

	if generated > 0 and vim.fn.filereadable(docs_dir .. "/index.md") == 1 then
		vim.cmd("edit " .. vim.fn.fnameescape(docs_dir .. "/index.md"))
	end
end

--- Run agentic docs generation with plan -> review -> per-page execution.
function M.generate_agentic(opts)
	opts = opts or {}
	local adapters_mod = require("dwight.pubdocs.adapters")
	local scan = require("dwight.pubdocs.scan")
	local plan_mod = require("dwight.pubdocs.plan")

	local project = require("dwight.project")
	if not project.is_initialized() then
		vim.notify("[dwight] Run :DwightInit first.", vim.log.levels.WARN)
		return
	end

	local plan = plan_mod.build_plan()
	if #plan == 0 then
		vim.notify("[dwight] No pages to generate. Add @feature: or @docs: pragmas.", vim.log.levels.WARN)
		return
	end

	local adapter, fw = adapters_mod.get_adapter()
	vim.fn.mkdir(adapter.docs_dir(), "p")

	-- Detect link style from existing docs (if any)
	local existing = scan.scan_existing_docs(adapter)
	local link_style = #existing > 0 and scan.detect_link_style(existing) or "markdown"
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
		if exists then
			existing_count = existing_count + 1
		end
		local icon = ({
			index = "📖",
			["getting-started"] = "🚀",
			feature = "⚙️",
			reference = "📋",
			guide = "📝",
			concept = "💡",
		})[p.page_type] or "📄"
		local marker = exists and " (overwrite)" or " (new)"
		local feat_str = p.feature_name and (" ← $" .. p.feature_name) or ""
		plan_lines[#plan_lines + 1] =
			string.format("%s %s | %s | %s%s%s", icon, p.path, p.page_type, p.title, feat_str, marker)
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
	plan_lines[#plan_lines + 1] =
		"────────────────────────────────────────────────────"
	plan_lines[#plan_lines + 1] = "  y/Enter = Run  |  e = Edit plan  |  q/n = Cancel"
	plan_lines[#plan_lines + 1] =
		"────────────────────────────────────────────────────"

	local buf = api.nvim_create_buf(false, true)
	pcall(function()
		api.nvim_buf_set_name(buf, "dwight://docs-plan")
	end)
	api.nvim_buf_set_lines(buf, 0, -1, false, _flatten(plan_lines))
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].modifiable = false
	vim.bo[buf].filetype = "markdown"

	vim.cmd("botright split")
	local win = api.nvim_get_current_win()
	api.nvim_win_set_buf(win, buf)
	api.nvim_win_set_height(win, math.min(#plan_lines + 2, 35))

	local function close()
		pcall(api.nvim_win_close, win, true)
	end

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

		vim.notify(
			string.format("[dwight] 📄 Starting agentic docs: %d pages [%s]", #final_pages, fw),
			vim.log.levels.INFO
		)

		M._run_docs_pipeline(final_pages, adapter, fw, opts)
	end

	local function enable_edit()
		vim.bo[buf].modifiable = true
		vim.notify(
			"[dwight] Plan is now editable. Delete lines to skip pages. Press 'y' when done.",
			vim.log.levels.INFO
		)
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
