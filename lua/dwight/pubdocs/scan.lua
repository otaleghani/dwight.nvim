-- dwight/pubdocs/scan.lua
-- Scan existing docs directory, detect link style, detect stale pages.

local M = {}

--------------------------------------------------------------------
-- Scan existing docs directory (framework-agnostic)
--------------------------------------------------------------------

--- Scan the docs directory and return a list of existing pages with metadata.
--- Works with ANY docs, not just Dwight-generated ones.
function M.scan_existing_docs(adapter)
	local dir = adapter.docs_dir()
	if vim.fn.isdirectory(dir) ~= 1 then
		return {}
	end

	local uv = vim.loop or vim.uv
	local pages = {}

	local function scan(d, prefix)
		local handle = uv.fs_scandir(d)
		if not handle then
			return
		end
		while true do
			local name, ftype = uv.fs_scandir_next(handle)
			if not name then
				break
			end
			if name:match("^[_%.]") then
				goto continue
			end
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
					local content = f:read("*a")
					f:close()
					body = content

					-- Frontmatter title
					title = content:match('^%-%-%-.-\ntitle:%s*"?([^"\n]+)"?')
						or content:match("^%-%-%-.-\ntitle:%s*([^\n]+)")
					description = content:match('^%-%-%-.-\ndescription:%s*"?([^"\n]+)"?')
						or content:match("^%-%-%-.-\ndescription:%s*([^\n]+)")
					-- Fallback: first # heading
					if not title then
						title = content:match("^#%s+([^\n]+)") or content:match("\n#%s+([^\n]+)")
					end
					if not title then
						title = name:gsub("%.md$", "")
					end

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
					if fl then
						table.insert(headings, 1, { level = #fl, text = vim.trim(ft) })
					end

					-- Count internal links (both styles)
					link_count = 0
					local md_link_count = 0
					local wiki_link_count = 0
					for _ in content:gmatch("%]%(.-%.md") do
						md_link_count = md_link_count + 1
					end
					-- Also count markdown links without .md extension (Docusaurus style)
					for _ in content:gmatch("%]%([%.%/][^%)]+%)") do
						md_link_count = md_link_count + 1
					end
					-- Wikilinks: [[Page Name]] or [[Page Name|Display Text]]
					for _ in content:gmatch("%[%[[^%]]+%]%]") do
						wiki_link_count = wiki_link_count + 1
					end
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
	table.sort(pages, function(a, b)
		return a.path < b.path
	end)
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
	if total_wiki > 0 and total_md == 0 then
		return "wikilinks"
	end
	if total_md > 0 and total_wiki == 0 then
		return "markdown"
	end
	if total_wiki > total_md then
		return "wikilinks"
	end
	if total_md > total_wiki then
		return "markdown"
	end
	if total_md == 0 and total_wiki == 0 then
		return "markdown"
	end
	return "mixed"
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
			since_ts,
			adapter.docs_dir():gsub("^" .. vim.pesc(vim.fn.getcwd()) .. "/?", "")
		)
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
	table.sort(stale, function(a, b)
		return a.change_count > b.change_count
	end)
	return stale
end

return M
