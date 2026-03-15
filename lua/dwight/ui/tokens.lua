-- dwight/ui/tokens.lua
-- Token parsing for the prompt buffer.

local M = {}

function M.parse_tokens(text)
	local skills = {}
	local symbols = {}
	local features = {}
	local libs = {}
	local mcp_refs = {}
	local files = {}
	local mode = nil
	local model_override = nil
	local audit_model = nil
	local think_depth = 1

	-- IMPORTANT: Extract +file tokens FIRST and mask them from the text
	-- before parsing /mode. Otherwise "/" in paths like +src/database/models.ts
	-- gets parsed as a mode.

	-- But first: extract +modifier keywords (e.g. +run) -- these are NOT file paths.
	local prompt_modifiers = {}
	local modifier_keywords = { run = true }
	for mod in text:gmatch("%+(%w+)") do
		if modifier_keywords[mod] then
			prompt_modifiers[mod] = true
		end
	end
	-- Remove modifier keywords from text before file parsing
	local file_text = text
	for kw in pairs(modifier_keywords) do
		file_text = file_text:gsub("%+" .. kw .. "%f[^%w]", "")
	end

	local masked_text = file_text
	for f in file_text:gmatch("%+([%w_%-]+[%./][%w_%-%./ ]*)") do
		f = vim.trim(f)
		if f ~= "" then
			files[#files + 1] = f
		end
	end
	-- Also capture !file:path tokens
	for fpath in text:gmatch("!file:([%w_%-%./:]+)") do
		files[#files + 1] = fpath
	end
	-- Mask +file and !file: tokens so their slashes don't interfere
	-- Mask +file and !file: tokens so their slashes don't interfere with /mode
	masked_text = masked_text:gsub("%+[%w_%-]+[%./][%w_%-%./ ]*", "")
	masked_text = masked_text:gsub("!file:[%w_%-%./:]+", "")

	-- Legacy sigils (still supported as shortcuts)
	for skill in text:gmatch("@([%w_%-%.]+)") do
		skills[#skills + 1] = skill
	end
	for sym in text:gmatch("#([%w_%-%.]+)") do
		symbols[#symbols + 1] = sym
	end
	for feat in text:gmatch("%$([%w_%-%.]+)") do
		features[#features + 1] = feat
	end
	for lib in text:gmatch("%%([%w_%-%.]+)") do
		libs[#libs + 1] = lib
	end
	for ref in text:gmatch("&([%w_%-%./:]+)") do
		mcp_refs[#mcp_refs + 1] = ref
	end

	-- Parse /mode on masked text (file paths removed)
	mode = masked_text:match("/(%w[%w_]*)")
	model_override = text:match("!([%w_%-%./:]+)")

	-- ~audit or ~audit:model
	local audit = text:match("~audit:([%w_%-%./:]+)")
	if audit then
		audit_model = audit
	elseif text:match("~audit") then
		audit_model = true -- use a different model from same provider
	end

	-- ^N think depth (^2, ^3, ^4 -- capped at 4)
	local depth_str = text:match("%^(%d+)")
	if depth_str then
		think_depth = math.min(math.max(tonumber(depth_str) or 1, 1), 4)
	end

	-- Unified modifier: !type:value (e.g. !mode:code, !skill:clean-code)
	-- These override/supplement the legacy sigils
	for mtype, mval in text:gmatch("!(%w+):([%w_%-%./:]+)") do
		mtype = mtype:lower()
		if mtype == "mode" then
			mode = mval
		elseif mtype == "model" then
			model_override = mval
		elseif mtype == "skill" then
			skills[#skills + 1] = mval
		elseif mtype == "symbol" then
			symbols[#symbols + 1] = mval
		elseif mtype == "feature" then
			features[#features + 1] = mval
		elseif mtype == "lib" then
			libs[#libs + 1] = mval
		elseif mtype == "file" then
			files[#files + 1] = mval
		elseif mtype == "depth" then
			think_depth = math.min(math.max(tonumber(mval) or 1, 1), 4)
		elseif mtype == "audit" then
			audit_model = mval
		end
	end

	-- If !type:value matched, don't also treat it as a bare !model_override
	if text:match("!%w+:[%w_%-%./:]+") then
		-- Check if there's also a bare ! model override (without colon in type position)
		local bare = text:match("!([%w_%-%.]+)%f[^:]")
		if bare and not bare:match("^%w+:") then
			model_override = bare
		end
	end

	local clean = text
	clean = clean:gsub("@[%w_%-%.]+", "")
	clean = clean:gsub("#[%w_%-%.]+", "")
	clean = clean:gsub("%$[%w_%-%.]+", "")
	clean = clean:gsub("%%[%w_%-%.]+", "")
	clean = clean:gsub("&[%w_%-%./:]+", "")
	-- Strip +modifier keywords (e.g. +run) -- just the keyword, not trailing text
	for kw in pairs(modifier_keywords) do
		clean = clean:gsub("%+" .. kw .. "%f[^%w]", "")
	end
	-- Strip +file paths (contain / or . to distinguish from modifiers)
	clean = clean:gsub("%+[%w_%-]+[%./][%w_%-%./ ]*", "")
	clean = clean:gsub("~audit[:%w_%-%./:]*", "")
	clean = clean:gsub("/%w[%w_]*", "")
	clean = clean:gsub("![%w_%-%./:]+", "")
	clean = clean:gsub("%^%d+", "")
	clean = vim.trim(clean:gsub("%s+", " "))

	return {
		skills = skills,
		symbols = symbols,
		features = features,
		libs = libs,
		mcp_refs = mcp_refs,
		files = files,
		mode = mode,
		model_override = model_override,
		audit_model = audit_model,
		think_depth = think_depth,
		modifiers = prompt_modifiers,
		clean_text = clean,
	}
end

return M
