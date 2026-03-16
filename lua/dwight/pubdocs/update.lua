-- dwight/pubdocs/update.lua
-- Update existing docs based on recent source changes.

local M = {}

local api = vim.api
local _flatten = require("dwight.util").flatten_lines

--- Build per-page agent prompt for updating an existing doc.
function M.build_update_prompt(page_info, changes, all_pages, adapter, fw, link_style)
	local helpers = require("dwight.pubdocs.helpers")
	local docs_dir = adapter.docs_dir()
	local parts = {}

	parts[#parts + 1] = string.format(
		[[
You are UPDATING an existing documentation page: %s
Title: %s
Framework: %s
Output directory: %s/

IMPORTANT: This page already exists. You are updating it, not rewriting from scratch.
Preserve the existing structure, tone, style, and link format. Only change what needs to change.
]],
		page_info.path,
		page_info.title,
		fw,
		docs_dir
	)

	-- Link format instructions (detected from existing docs)
	parts[#parts + 1] = helpers.link_style_instructions(link_style, all_pages)

	-- Cross-reference map
	parts[#parts + 1] = "## Other Documentation Pages (for cross-references)"
	if link_style == "wikilinks" then
		for _, p in ipairs(all_pages) do
			if p.path ~= page_info.path then
				parts[#parts + 1] = string.format(
					"  - %s — %s → [[%s]]",
					p.path,
					p.title or p.path,
					(p.title or p.path:gsub("%.md$", ""))
				)
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
	parts[#parts + 1] =
		string.format("## Source Changes Since Last Update (%d days ago)", page_info.staleness_days or 0)
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

	parts[#parts + 1] = string.format(
		[[
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
]],
		docs_dir,
		page_info.path,
		docs_dir,
		page_info.path
	)

	return table.concat(parts, "\n")
end

--- Run the update pipeline.
function M._run_update_pipeline(stale_pages, all_pages, adapter, fw, link_style)
	local scan = require("dwight.pubdocs.scan")
	local agentic = require("dwight.pubdocs.agentic")

	link_style = link_style or scan.detect_link_style(all_pages)
	local total = #stale_pages
	local updated = 0
	local errors = {}
	local status = require("dwight.agent_status")
	local docs_dir = adapter.docs_dir()

	status.start_session(string.format("DwightDocs --update: %d pages [%s]", total, fw))
	status.append_hl(string.format("Updating %d stale documentation pages", total), "DwightHeader")
	status.append_hl(string.format("  Link style: %s", link_style or "markdown"), "DwightDim")
	status.append("")

	local idx = 0

	local function next_page()
		idx = idx + 1
		if idx > total then
			vim.schedule(function()
				agentic._docs_post_generate(
					vim.tbl_map(function(s)
						return s.page
					end, stale_pages),
					adapter,
					fw,
					updated,
					errors,
					status
				)
			end)
			return
		end

		local entry = stale_pages[idx]
		local page = entry.page

		status.append_hl(string.format("── Page %d/%d: %s", idx, total, page.title), "DwightHeader")
		status.append_hl(
			string.format("  %s (%d changes, %d days stale)", page.path, entry.change_count, entry.staleness_days or 0),
			"DwightDim"
		)

		local prompt = M.build_update_prompt(
			vim.tbl_extend("force", page, { staleness_days = entry.staleness_days }),
			entry.changes,
			all_pages,
			adapter,
			fw,
			link_style
		)

		local agent = require("dwight.agent")
		agent.run(prompt, {
			plan = false,
			_skip_plan = true,
			on_complete = function(success)
				vim.schedule(function()
					if success and vim.fn.filereadable(page.full_path) == 1 then
						updated = updated + 1
						status.append_hl(string.format("  ● %s updated", page.path), "DwightOK")
					else
						errors[#errors + 1] = page.path
						status.append_hl(string.format("  ✗ %s failed", page.path), "DwightFail")
					end
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
	local adapters_mod = require("dwight.pubdocs.adapters")
	local scan = require("dwight.pubdocs.scan")

	local adapter, fw = adapters_mod.get_adapter()
	local docs_dir = adapter.docs_dir()

	if vim.fn.isdirectory(docs_dir) ~= 1 then
		vim.notify("[dwight] No docs directory found. Run :DwightDocs --agentic first.", vim.log.levels.WARN)
		return
	end

	local existing = scan.scan_existing_docs(adapter)
	if #existing == 0 then
		vim.notify("[dwight] No documentation pages found in " .. docs_dir, vim.log.levels.WARN)
		return
	end

	local link_style = scan.detect_link_style(existing)

	vim.notify(string.format("[dwight] 📄 Scanning %d pages for staleness…", #existing), vim.log.levels.INFO)

	local stale = scan._detect_stale_pages(existing, adapter)

	-- If a specific page was targeted, run directly
	if opts.target and opts.target ~= "" then
		local target = opts.target
		if not target:match("%.md$") then
			target = target .. ".md"
		end

		local found = nil
		for _, entry in ipairs(stale) do
			if entry.page.path == target or entry.page.path:match(vim.pesc(opts.target)) then
				found = entry
				break
			end
		end
		if not found then
			-- Check if the page exists but isn't stale
			local page_exists = false
			for _, p in ipairs(existing) do
				if p.path == target or p.path:match(vim.pesc(opts.target)) then
					page_exists = true
					break
				end
			end
			if page_exists then
				vim.notify("[dwight] ✅ " .. opts.target .. " is up to date.", vim.log.levels.INFO)
			else
				vim.notify("[dwight] Page not found: " .. opts.target, vim.log.levels.WARN)
			end
			return
		end

		vim.notify(
			string.format(
				"[dwight] 📝 Updating %s (%d changes, %d days stale)…",
				found.page.path,
				found.change_count,
				found.staleness_days or 0
			),
			vim.log.levels.INFO
		)
		M._run_update_pipeline({ found }, existing, adapter, fw, link_style)
		return
	end

	if #stale == 0 then
		vim.notify(
			string.format(
				"[dwight] ✅ All %d pages are up to date! No source changes since last docs update.",
				#existing
			),
			vim.log.levels.INFO
		)
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
			if not seen[c.file] then
				seen[c.file] = true
				unique_files[#unique_files + 1] = c.file
			end
		end
		local files_str = #unique_files <= 3 and table.concat(unique_files, ", ")
			or string.format(
				"%s (+%d more)",
				table.concat({ unique_files[1], unique_files[2] }, ", "),
				#unique_files - 2
			)

		plan_lines[#plan_lines + 1] = string.format(
			"📝 %s | %dd stale | %d changes | %s",
			p.path,
			entry.staleness_days or 0,
			entry.change_count,
			files_str
		)
	end

	plan_lines[#plan_lines + 1] = ""
	plan_lines[#plan_lines + 1] = "## What Each Agent Will Do"
	plan_lines[#plan_lines + 1] = "  1. Read the existing documentation page"
	plan_lines[#plan_lines + 1] = "  2. Read the source files that changed since last update"
	plan_lines[#plan_lines + 1] = "  3. Read git diffs to understand what changed"
	plan_lines[#plan_lines + 1] = "  4. Update the page: add new content, fix outdated info, remove stale sections"
	plan_lines[#plan_lines + 1] = ""
	plan_lines[#plan_lines + 1] =
		"────────────────────────────────────────────────────"
	plan_lines[#plan_lines + 1] = "  y/Enter = Run  |  e = Edit plan  |  q/n = Cancel"
	plan_lines[#plan_lines + 1] =
		"────────────────────────────────────────────────────"

	local buf = api.nvim_create_buf(false, true)
	pcall(function()
		api.nvim_buf_set_name(buf, "dwight://docs-update-plan")
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
		vim.notify("[dwight] Plan is editable. Delete lines to skip pages. Press 'y' when done.", vim.log.levels.INFO)
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
