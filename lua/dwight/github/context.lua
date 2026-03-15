-- dwight/github/context.lua
-- Context builder: issue -> agent prompt with file refs and feature detection.

local M = {}

--- Build a rich agent prompt from an issue.
--- Injects: issue body, comments, referenced files, feature context, skills, libs.
function M.build_issue_context(issue)
	local parts = {}

	-- Issue header
	parts[#parts + 1] = string.format('<github_issue number="%d" url="%s">', issue.number, issue.url or "")
	parts[#parts + 1] = string.format("  <title>%s</title>", issue.title or "")

	-- Labels
	if issue.labels and #issue.labels > 0 then
		local label_names = {}
		for _, l in ipairs(issue.labels) do
			label_names[#label_names + 1] = type(l) == "table" and l.name or tostring(l)
		end
		parts[#parts + 1] = string.format("  <labels>%s</labels>", table.concat(label_names, ", "))
	end

	-- Body
	local body = issue.body or ""
	if #body > 6000 then
		body = body:sub(1, 6000) .. "\n... (truncated)"
	end
	parts[#parts + 1] = "  <body>"
	parts[#parts + 1] = body
	parts[#parts + 1] = "  </body>"

	-- Comments (last 10)
	if issue.comments and #issue.comments > 0 then
		parts[#parts + 1] = "  <comments>"
		local start_idx = math.max(1, #issue.comments - 9)
		for i = start_idx, #issue.comments do
			local c = issue.comments[i]
			local author = type(c.author) == "table" and c.author.login or (c.author or "unknown")
			local comment_body = c.body or ""
			if #comment_body > 1500 then
				comment_body = comment_body:sub(1, 1500) .. "\226\128\166"
			end
			parts[#parts + 1] = string.format('    <comment author="%s" date="%s">', author, c.createdAt or "")
			parts[#parts + 1] = "      " .. comment_body
			parts[#parts + 1] = "    </comment>"
		end
		parts[#parts + 1] = "  </comments>"
	end

	parts[#parts + 1] = "</github_issue>"

	-- Extract file references from issue body + comments
	local all_text = (issue.body or "")
	if issue.comments then
		for _, c in ipairs(issue.comments) do
			all_text = all_text .. "\n" .. (c.body or "")
		end
	end
	local referenced_files = M._extract_file_refs(all_text)
	if #referenced_files > 0 then
		parts[#parts + 1] = ""
		parts[#parts + 1] = '<referenced_files hint="Files mentioned in the issue">'
		for _, ref in ipairs(referenced_files) do
			parts[#parts + 1] = "  <file>" .. ref .. "</file>"
		end
		parts[#parts + 1] = "</referenced_files>"
	end

	-- Feature context (if issue mentions $feature or touches feature files)
	local feature_names = M._detect_features(all_text, referenced_files)
	if #feature_names > 0 then
		pcall(function()
			local integration = require("dwight.integration")
			for _, fname in ipairs(feature_names) do
				local ctx = integration.build_feature_context("$" .. fname)
				if ctx then
					parts[#parts + 1] = ""
					parts[#parts + 1] = ctx
				end
			end
		end)
	end

	-- Skills + libs + pragma rules
	pcall(function()
		local integration = require("dwight.integration")
		local full_ctx = integration.build_full_context()
		if full_ctx then
			parts[#parts + 1] = ""
			parts[#parts + 1] = full_ctx
		end
	end)

	return table.concat(parts, "\n")
end

--- Extract file paths mentioned in text.
--- Looks for paths like src/foo.go, ./bar/baz.ts, pkg/auth/handler.go
function M._extract_file_refs(text)
	local refs = {}
	local seen = {}
	local cwd = vim.fn.getcwd()

	-- Match patterns like `path/to/file.ext` in backticks or standalone
	for path in text:gmatch("`([%w%.%-%_/]+%.[%w]+)`") do
		if not seen[path] then
			-- Verify the file actually exists
			local full = cwd .. "/" .. path
			if vim.fn.filereadable(full) == 1 then
				refs[#refs + 1] = path
				seen[path] = true
			end
		end
	end

	-- Also match stack trace patterns: at /path/file.go:123
	for path in text:gmatch("([%w%.%-%_/]+%.[%w]+):%d+") do
		if not seen[path] then
			local full = cwd .. "/" .. path
			if vim.fn.filereadable(full) == 1 then
				refs[#refs + 1] = path
				seen[path] = true
			end
		end
	end

	return refs
end

--- Detect feature names from text and file references.
function M._detect_features(text, file_refs)
	local names = {}
	local seen = {}

	-- $feature-name pattern
	for name in text:gmatch("%$([%w%-_]+)") do
		if not seen[name] then
			names[#names + 1] = name
			seen[name] = true
		end
	end

	-- @feature:name pattern
	for name in text:gmatch("@feature:([%w%-_]+)") do
		if not seen[name] then
			names[#names + 1] = name
			seen[name] = true
		end
	end

	-- Map referenced files to features
	pcall(function()
		local features = require("dwight.features")
		local all_features = features.all()
		if all_features then
			for feat_name, feat in pairs(all_features) do
				if not seen[feat_name] and feat.files then
					for _, ff in ipairs(feat.files) do
						for _, ref in ipairs(file_refs) do
							if ff:match(ref .. "$") or ref:match(vim.pesc(ff) .. "$") then
								names[#names + 1] = feat_name
								seen[feat_name] = true
								break
							end
						end
						if seen[feat_name] then
							break
						end
					end
				end
			end
		end
	end)

	return names
end

return M
