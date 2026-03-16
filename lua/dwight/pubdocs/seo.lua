-- dwight/pubdocs/seo.lua
-- SEO audit: comprehensive page analysis and optimization.

local M = {}

local api = vim.api
local _flatten = require("dwight.util").flatten_lines

--- Run a full SEO audit on all pages. Returns enriched page list.
function M._seo_audit(existing_pages, adapter)
	local helpers = require("dwight.pubdocs.helpers")
	local THIN_CONTENT_THRESHOLD = helpers.THIN_CONTENT_THRESHOLD

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
			issues[#issues + 1] =
				string.format("thin content (%d words, min %d)", page.word_count, THIN_CONTENT_THRESHOLD)
		end

		-- Heading structure
		if #page.headings == 0 then
			issues[#issues + 1] = "no headings"
		else
			local has_h1 = false
			for _, h in ipairs(page.headings) do
				if h.level == 1 then
					has_h1 = true
					break
				end
			end
			if not has_h1 then
				issues[#issues + 1] = "no H1 heading"
			end
		end

		page.seo_issues = issues
	end

	-- Detect merge candidates: pages with overlapping headings or in the same directory with low word count
	local merge_groups = {}
	for i, pa in ipairs(existing_pages) do
		for j = i + 1, #existing_pages do
			local pb = existing_pages[j]
			local score = 0

			-- Same directory -> related topics
			local dir_a = pa.path:match("^(.+)/") or ""
			local dir_b = pb.path:match("^(.+)/") or ""
			if dir_a == dir_b and dir_a ~= "" then
				score = score + 1
			end

			-- Both thin -> strong merge candidate
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
				if headings_a[normalized] then
					score = score + 2
				end
			end

			-- Title word overlap
			local words_a = {}
			for w in pa.title:lower():gmatch("%w+") do
				if #w > 3 then
					words_a[w] = true
				end -- skip short words
			end
			local overlap = 0
			for w in pb.title:lower():gmatch("%w+") do
				if #w > 3 and words_a[w] then
					overlap = overlap + 1
				end
			end
			if overlap >= 2 then
				score = score + 2
			elseif overlap >= 1 then
				score = score + 1
			end

			if score >= 3 then
				merge_groups[#merge_groups + 1] = {
					page_a = pa,
					page_b = pb,
					score = score,
					reason = (pa.word_count < THIN_CONTENT_THRESHOLD or pb.word_count < THIN_CONTENT_THRESHOLD)
							and "thin + related"
						or "overlapping content",
				}
			end
		end
	end
	table.sort(merge_groups, function(a, b)
		return a.score > b.score
	end)

	return merge_groups
end

--- Build per-page agent prompt for SEO optimization.
function M.build_seo_prompt(page_info, all_pages, adapter, fw, merge_candidates, link_style)
	local helpers = require("dwight.pubdocs.helpers")
	local THIN_CONTENT_THRESHOLD = helpers.THIN_CONTENT_THRESHOLD
	local docs_dir = adapter.docs_dir()
	local parts = {}

	parts[#parts + 1] = string.format(
		[[
You are optimizing an existing documentation page for SEO and discoverability: %s
Title: %s
Framework: %s
Output directory: %s/
Word count: %d words
Internal links: %d
]],
		page_info.path,
		page_info.title,
		fw,
		docs_dir,
		page_info.word_count or 0,
		page_info.link_count or 0
	)

	-- Link format instructions (detected from existing docs)
	parts[#parts + 1] = helpers.link_style_instructions(link_style, all_pages)

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
				parts[#parts + 1] = string.format(
					"  - %s — %s%s → [[%s]]",
					p.path,
					p.title or "",
					extra,
					(p.title or p.path:gsub("%.md$", ""))
				)
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
			parts[#parts + 1] = string.format(
				'  - %s — "%s" (%d words) — reason: %s',
				other.path,
				other.title,
				other.word_count or 0,
				mc.reason
			)
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
		parts[#parts + 1] = string.format(
			[[
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
]],
			page_info.word_count,
			THIN_CONTENT_THRESHOLD
		)
	end

	-- Current description status
	if page_info.description then
		parts[#parts + 1] = "Current meta description: " .. page_info.description
	else
		parts[#parts + 1] = "⚠️  No meta description found — this is critical for SEO."
	end
	parts[#parts + 1] = ""

	parts[#parts + 1] = string.format(
		[[
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
]],
		docs_dir,
		page_info.path,
		is_thin and "\n3. **Read source code** to find real content to expand this page with" or ""
	)

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

	parts[#parts + 1] = string.format(
		[[
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
]],
		fw,
		docs_dir,
		page_info.path
	)

	if merge_candidates and #merge_candidates > 0 then
		parts[#parts + 1] = "If you merged a candidate page, delete that file too."
	end
	parts[#parts + 1] = "Do NOT create any new files (other than this page). Do NOT modify source code."

	return table.concat(parts, "\n")
end

--- Run the SEO optimization pipeline.
function M._run_seo_pipeline(pages, all_pages, adapter, fw, merge_groups, link_style)
	local scan = require("dwight.pubdocs.scan")
	local agentic = require("dwight.pubdocs.agentic")
	local helpers = require("dwight.pubdocs.helpers")
	local THIN_CONTENT_THRESHOLD = helpers.THIN_CONTENT_THRESHOLD

	link_style = link_style or scan.detect_link_style(all_pages)
	local total = #pages
	local optimized = 0
	local errors = {}
	local status = require("dwight.agent_status")
	local docs_dir = adapter.docs_dir()

	status.start_session(string.format("DwightDocs --seo: %d pages [%s]", total, fw))
	status.append_hl(string.format("Optimizing %d pages for SEO", total), "DwightHeader")
	status.append_hl(string.format("  Link style: %s", link_style or "markdown"), "DwightDim")
	status.append("")

	local idx = 0

	local function next_page()
		idx = idx + 1
		if idx > total then
			vim.schedule(function()
				agentic._docs_post_generate(pages, adapter, fw, optimized, errors, status)
			end)
			return
		end

		local page = pages[idx]
		local is_thin = page.word_count and page.word_count < THIN_CONTENT_THRESHOLD

		status.append_hl(string.format("── Page %d/%d: %s", idx, total, page.title), "DwightHeader")
		local extra = is_thin and string.format(" [thin: %d words]", page.word_count)
			or string.format(" [%d words]", page.word_count or 0)
		status.append_hl(string.format("  %s%s", page.path, extra), is_thin and "DwightWarn" or "DwightDim")

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
				status.append_hl(string.format("    merge candidate: %s (%s)", other.path, mg.reason), "DwightDim")
			end
		end

		local prompt = M.build_seo_prompt(page, all_pages, adapter, fw, page_merges, link_style)

		local agent = require("dwight.agent")
		agent.run(prompt, {
			plan = false,
			_skip_plan = true,
			on_complete = function(success)
				vim.schedule(function()
					if success and vim.fn.filereadable(page.full_path) == 1 then
						optimized = optimized + 1
						status.append_hl(string.format("  ● %s optimized", page.path), "DwightOK")
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

--- :DwightDocs --seo [page] entry point.
function M.seo_optimize(opts)
	opts = opts or {}
	local adapters_mod = require("dwight.pubdocs.adapters")
	local scan = require("dwight.pubdocs.scan")
	local helpers = require("dwight.pubdocs.helpers")
	local THIN_CONTENT_THRESHOLD = helpers.THIN_CONTENT_THRESHOLD

	local adapter, fw = adapters_mod.get_adapter()
	local docs_dir = adapter.docs_dir()

	if vim.fn.isdirectory(docs_dir) ~= 1 then
		vim.notify("[dwight] No docs directory found.", vim.log.levels.WARN)
		return
	end

	local existing = scan.scan_existing_docs(adapter)
	if #existing == 0 then
		vim.notify("[dwight] No documentation pages found in " .. docs_dir, vim.log.levels.WARN)
		return
	end

	-- Run full SEO audit
	local merge_groups = M._seo_audit(existing, adapter)
	local link_style = scan.detect_link_style(existing)

	-- If a specific page was targeted, run directly (no plan buffer)
	if opts.target and opts.target ~= "" then
		local target = opts.target
		-- Normalize: allow "features/auth" or "features/auth.md"
		if not target:match("%.md$") then
			target = target .. ".md"
		end

		local found = nil
		for _, p in ipairs(existing) do
			if p.path == target or p.path:match(vim.pesc(opts.target)) then
				found = p
				break
			end
		end
		if not found then
			vim.notify("[dwight] Page not found: " .. opts.target, vim.log.levels.WARN)
			return
		end

		local issue_str = found.seo_issues and #found.seo_issues > 0 and ": " .. table.concat(found.seo_issues, ", ")
			or " (no issues detected, optimizing anyway)"
		vim.notify(string.format("[dwight] 🔍 SEO optimizing %s%s", found.path, issue_str), vim.log.levels.INFO)

		M._run_seo_pipeline({ found }, existing, adapter, fw, merge_groups, link_style)
		return
	end

	-- Count issues
	local issue_count = 0
	local thin_count = 0
	for _, p in ipairs(existing) do
		if p.seo_issues and #p.seo_issues > 0 then
			issue_count = issue_count + 1
		end
		if p.word_count < THIN_CONTENT_THRESHOLD then
			thin_count = thin_count + 1
		end
	end

	-- Build plan buffer
	local plan_lines = {}
	plan_lines[#plan_lines + 1] = "# 🔍 DwightDocs — SEO Optimization"
	plan_lines[#plan_lines + 1] = ""
	plan_lines[#plan_lines + 1] = string.format("Framework: %s | Docs: %s/ | Link style: %s", fw, docs_dir, link_style)
	plan_lines[#plan_lines + 1] = string.format(
		"Total pages: %d | Issues: %d | Thin content: %d | Merge candidates: %d",
		#existing,
		issue_count,
		thin_count,
		#merge_groups
	)
	plan_lines[#plan_lines + 1] = ""

	-- Merge candidates section
	if #merge_groups > 0 then
		plan_lines[#plan_lines + 1] = "## Merge Candidates"
		plan_lines[#plan_lines + 1] = "These page pairs overlap and the agent may merge them:"
		for _, mg in ipairs(merge_groups) do
			plan_lines[#plan_lines + 1] =
				string.format("  %s ↔ %s — %s (score %d)", mg.page_a.path, mg.page_b.path, mg.reason, mg.score)
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
		if a_issues ~= b_issues then
			return a_issues > b_issues
		end
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
				break -- show only first merge match
			end
		end

		local flag_str = #flags > 0 and " " .. table.concat(flags, " | ") or " ✓"
		plan_lines[#plan_lines + 1] =
			string.format("🔍 %s | %dw | %s%s", page.path, page.word_count, page.title, flag_str)
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
		plan_lines[#plan_lines + 1] =
			string.format("  %d. Merge overlapping pages where it makes sense", thin_count > 0 and 7 or 6)
	end
	plan_lines[#plan_lines + 1] = ""
	plan_lines[#plan_lines + 1] =
		"────────────────────────────────────────────────────"
	plan_lines[#plan_lines + 1] = "  y/Enter = Run  |  e = Edit plan  |  q/n = Cancel"
	plan_lines[#plan_lines + 1] =
		"────────────────────────────────────────────────────"

	local buf = api.nvim_create_buf(false, true)
	pcall(function()
		api.nvim_buf_set_name(buf, "dwight://docs-seo-plan")
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
