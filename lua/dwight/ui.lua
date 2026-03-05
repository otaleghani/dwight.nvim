-- dwight/ui.lua
-- Floating prompt: scratch buffer with static help.
-- Tokens: @skill /mode #symbol !model $feature ^N(think depth)

local M = {}

local api = vim.api
local ns_hl = api.nvim_create_namespace("dwight_prompt_hl")

--------------------------------------------------------------------
-- Visual Selection
--------------------------------------------------------------------

function M.get_visual_selection()
	vim.cmd('noautocmd normal! "vy')
	local bufnr = api.nvim_get_current_buf()
	local start_pos = api.nvim_buf_get_mark(bufnr, "<")
	local end_pos = api.nvim_buf_get_mark(bufnr, ">")
	if start_pos[1] == 0 and end_pos[1] == 0 then
		return nil
	end

	local start_line = start_pos[1]
	local end_line = end_pos[1]
	local lines = api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
	if not lines or #lines == 0 then
		return nil
	end

	return {
		bufnr = bufnr,
		start_line = start_line,
		end_line = end_line,
		start_col = start_pos[2],
		end_col = end_pos[2],
		text = table.concat(lines, "\n"),
		lines = lines,
		filetype = vim.bo[bufnr].filetype,
		filepath = api.nvim_buf_get_name(bufnr),
	}
end

--------------------------------------------------------------------
-- Per-Job Processing Indicators
--------------------------------------------------------------------

M._job_indicators = {}
local spinner_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

function M.show_indicators(job_id, bufnr, start_line, end_line)
	if not api.nvim_buf_is_valid(bufnr) then
		return
	end
	local cfg = require("dwight").config
	local ns = api.nvim_create_namespace("dwight_job_" .. job_id)
	local sign_group = "dwight_job_" .. job_id
	local style = cfg.indicator_style

	if style == "sign" or style == "both" then
		for lnum = start_line, end_line do
			pcall(vim.fn.sign_place, 0, sign_group, "DwightProcessing", bufnr, { lnum = lnum })
		end
	end

	local frame = 1
	local timer = (vim.loop or vim.uv).new_timer()
	M._job_indicators[job_id] = {
		ns = ns,
		sign_group = sign_group,
		timer = timer,
		bufnr = bufnr,
		start_line = start_line,
		end_line = end_line,
	}

	timer:start(
		0,
		120,
		vim.schedule_wrap(function()
			if not api.nvim_buf_is_valid(bufnr) then
				M.clear_indicators(job_id)
				return
			end
			api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
			local ind = M._job_indicators[job_id]
			if not ind then
				return
			end
			local icon = spinner_frames[frame]
			local label = ind.custom_label or string.format("#%d processing…", job_id)
			local text = string.format(" %s %s", icon, label)
			for _, lnum in ipairs({ ind.start_line, ind.end_line }) do
				pcall(api.nvim_buf_set_extmark, bufnr, ns, lnum - 1, 0, {
					virt_text = { { text, "DwightProcessing" } },
					virt_text_pos = "eol",
				})
			end
			frame = frame % #spinner_frames + 1
		end)
	)
end

function M.clear_indicators(job_id)
	local ind = M._job_indicators[job_id]
	if not ind then
		return
	end
	pcall(function()
		ind.timer:stop()
		ind.timer:close()
	end)
	if api.nvim_buf_is_valid(ind.bufnr) then
		api.nvim_buf_clear_namespace(ind.bufnr, ind.ns, 0, -1)
	end
	pcall(vim.fn.sign_unplace, ind.sign_group, { buffer = ind.bufnr })
	M._job_indicators[job_id] = nil
end

function M.update_indicator_range(job_id, new_start, new_end)
	local ind = M._job_indicators[job_id]
	if ind then
		ind.start_line = new_start
		ind.end_line = new_end
	end
end

--- Update the text label shown in the spinning indicator (e.g. streaming progress).
function M.update_indicator_label(job_id, label)
	local ind = M._job_indicators[job_id]
	if ind then
		ind.custom_label = label
	end
end

--------------------------------------------------------------------
-- Token Parsing
--------------------------------------------------------------------

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

	-- But first: extract +modifier keywords (e.g. +run) — these are NOT file paths.
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

	-- ^N think depth (^2, ^3, ^4 — capped at 4)
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
	-- Strip +modifier keywords (e.g. +run) — just the keyword, not trailing text
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

--------------------------------------------------------------------
-- Prompt Highlighting
--------------------------------------------------------------------

local function highlight_prompt_buf(buf, editable_end)
	if not api.nvim_buf_is_valid(buf) then
		return
	end
	api.nvim_buf_clear_namespace(buf, ns_hl, 0, -1)

	local lines = api.nvim_buf_get_lines(buf, 0, editable_end, false)
	local skill_names = require("dwight.skills").names()
	local skill_set = {}
	for _, n in ipairs(skill_names) do
		skill_set[n] = true
	end
	local mode_names = require("dwight.modes").list()
	local mode_set = {}
	for _, n in ipairs(mode_names) do
		mode_set[n] = true
	end
	local feat_set = {}
	pcall(function()
		for _, n in ipairs(require("dwight.features").names()) do
			feat_set[n] = true
		end
	end)
	local lib_set = {}
	pcall(function()
		for _, n in ipairs(require("dwight.libs").names()) do
			lib_set[n] = true
		end
	end)

	for i, line in ipairs(lines) do
		local row = i - 1
		-- @skills
		local pos = 1
		while true do
			local s, e, name = line:find("@([%w_%-%.]+)", pos)
			if not s then
				break
			end
			local hl = skill_set[name] and "DwightSkill" or "DwightSkillInvalid"
			api.nvim_buf_add_highlight(buf, ns_hl, hl, row, s - 1, e)
			pos = e + 1
		end
		-- /modes
		pos = 1
		while true do
			local s, e, name = line:find("/(%w[%w_]*)", pos)
			if not s then
				break
			end
			if mode_set[name] or name == "tdd" then
				api.nvim_buf_add_highlight(buf, ns_hl, "DwightMode", row, s - 1, e)
			end
			pos = e + 1
		end
		-- +modifiers (+run)
		pos = 1
		while true do
			local s, e, name = line:find("%+(%w+)", pos)
			if not s then
				break
			end
			if name == "run" then
				api.nvim_buf_add_highlight(buf, ns_hl, "DwightMode", row, s - 1, e)
			end
			pos = e + 1
		end
		-- #symbols
		pos = 1
		while true do
			local s, e = line:find("#[%w_%-%.]+", pos)
			if not s then
				break
			end
			api.nvim_buf_add_highlight(buf, ns_hl, "DwightSymbol", row, s - 1, e)
			pos = e + 1
		end
		-- !model
		pos = 1
		while true do
			local s, e = line:find("![%w_%-%./:]+", pos)
			if not s then
				break
			end
			api.nvim_buf_add_highlight(buf, ns_hl, "DwightModel", row, s - 1, e)
			pos = e + 1
		end
		-- $features
		pos = 1
		while true do
			local s, e, name = line:find("%$([%w_%-%.]+)", pos)
			if not s then
				break
			end
			local hl = feat_set[name] and "DwightFeature" or "DwightSkillInvalid"
			api.nvim_buf_add_highlight(buf, ns_hl, hl, row, s - 1, e)
			pos = e + 1
		end
		-- %libs
		pos = 1
		while true do
			local s, e, name = line:find("%%([%w_%-%.]+)", pos)
			if not s then
				break
			end
			local hl = lib_set[name] and "DwightLib" or "DwightSkillInvalid"
			api.nvim_buf_add_highlight(buf, ns_hl, hl, row, s - 1, e)
			pos = e + 1
		end
		-- &mcp resources
		pos = 1
		while true do
			local s, e = line:find("&[%w_%-%./:]+", pos)
			if not s then
				break
			end
			api.nvim_buf_add_highlight(buf, ns_hl, "DwightMcp", row, s - 1, e)
			pos = e + 1
		end
		-- ^N think depth
		pos = 1
		while true do
			local s, e = line:find("%^%d+", pos)
			if not s then
				break
			end
			api.nvim_buf_add_highlight(buf, ns_hl, "DwightThink", row, s - 1, e)
			pos = e + 1
		end
		-- +files
		pos = 1
		while true do
			local s, e = line:find("%+[%w_%-%./ ]+", pos)
			if not s then
				break
			end
			api.nvim_buf_add_highlight(buf, ns_hl, "DwightFile", row, s - 1, e)
			pos = e + 1
		end
		-- ~audit
		pos = 1
		while true do
			local s, e = line:find("~audit[:%w_%-%./:]*", pos)
			if not s then
				break
			end
			api.nvim_buf_add_highlight(buf, ns_hl, "DwightAudit", row, s - 1, e)
			pos = e + 1
		end
	end
end

--------------------------------------------------------------------
-- Completion: omnifunc
--------------------------------------------------------------------

M._source_bufnr = nil

local function find_token_at_cursor()
	local line = api.nvim_get_current_line()
	local col = api.nvim_win_get_cursor(0)[2]
	local start = col
	while start > 0 do
		local c = line:sub(start, start)
		if
			c == "@"
			or c == "/"
			or c == "#"
			or c == "!"
			or c == "$"
			or c == "^"
			or c == "%"
			or c == "&"
			or c == "+"
			or c == "~"
		then
			return c, line:sub(start + 1, col), start
		end
		if not c:match("[%w_%-%.@/#!$%%&%^:/+~]") then
			break
		end
		start = start - 1
	end
	return nil, "", col
end

function M.omnifunc(findstart, base)
	if findstart == 1 then
		local trigger, _, start_pos = find_token_at_cursor()
		if trigger then
			return start_pos - 1
		end
		return -3
	end

	local items = {}
	local trigger = base:sub(1, 1)
	local typed = base:sub(2):lower()

	if trigger == "@" then
		for _, name in ipairs(require("dwight.skills").names()) do
			if typed == "" or name:lower():find(typed, 1, true) then
				items[#items + 1] = { word = "@" .. name, menu = "[skill]", icase = 1 }
			end
		end
	elseif trigger == "/" then
		local modes = require("dwight.modes")
		-- Filter modes by the source buffer's filetype
		local source_ft = nil
		if M._source_bufnr and api.nvim_buf_is_valid(M._source_bufnr) then
			source_ft = vim.bo[M._source_bufnr].filetype
		end
		for _, name in ipairs(modes.list_for_filetype(source_ft)) do
			if typed == "" or name:lower():find(typed, 1, true) then
				local m = modes.get(name)
				items[#items + 1] = { word = "/" .. name, menu = m.icon .. " " .. m.name, icase = 1 }
			end
		end
	elseif trigger == "#" then
		if #typed >= 1 then
			local ok, syms = pcall(function()
				return require("dwight.symbols").search(typed, 20, M._source_bufnr)
			end)
			if ok and syms then
				for _, s in ipairs(syms) do
					local file = vim.fn.fnamemodify(s.filepath, ":t")
					items[#items + 1] = {
						word = "#" .. s.name,
						menu = string.format("[%s] %s:%d", s.kind, file, s.line),
						icase = 1,
					}
				end
			end
		end
	elseif trigger == "!" then
		-- Unified modifier: !type: or legacy !model
		if typed:match("^%w+:") then
			-- User typed !type:value — complete the value
			local mtype, mval = typed:match("^(%w+):(.*)$")
			mtype = (mtype or ""):lower()
			mval = (mval or ""):lower()
			if mtype == "mode" then
				for _, name in ipairs(require("dwight.modes").list()) do
					if mval == "" or name:lower():find(mval, 1, true) then
						items[#items + 1] = { word = "!mode:" .. name, menu = "[mode]", icase = 1 }
					end
				end
			elseif mtype == "skill" then
				for _, name in ipairs(require("dwight.skills").names()) do
					if mval == "" or name:lower():find(mval, 1, true) then
						items[#items + 1] = { word = "!skill:" .. name, menu = "[skill]", icase = 1 }
					end
				end
			elseif mtype == "model" then
				pcall(function()
					for _, name in ipairs(require("dwight.providers").all_model_names()) do
						if mval == "" or name:lower():find(mval, 1, true) then
							items[#items + 1] = { word = "!model:" .. name, menu = "[model]", icase = 1 }
						end
					end
				end)
			elseif mtype == "feature" then
				pcall(function()
					for _, name in ipairs(require("dwight.features").names()) do
						if mval == "" or name:lower():find(mval, 1, true) then
							items[#items + 1] = { word = "!feature:" .. name, menu = "[feature]", icase = 1 }
						end
					end
				end)
			elseif mtype == "lib" then
				pcall(function()
					for _, name in ipairs(require("dwight.libs").names()) do
						if mval == "" or name:lower():find(mval, 1, true) then
							items[#items + 1] = { word = "!lib:" .. name, menu = "[lib]", icase = 1 }
						end
					end
				end)
			elseif mtype == "file" then
				pcall(function()
					for _, f in ipairs(require("dwight.treesitter").project_files(mval)) do
						items[#items + 1] = { word = "!file:" .. f, menu = "[file]", icase = 1 }
					end
				end)
			elseif mtype == "symbol" then
				pcall(function()
					local syms = require("dwight.symbols").search(mval, 20, M._source_bufnr)
					for _, s in ipairs(syms or {}) do
						items[#items + 1] = { word = "!symbol:" .. s.name, menu = "[" .. s.kind .. "]", icase = 1 }
					end
				end)
			end
		else
			-- User typed ! — show type picker first, then legacy model names
			local modifier_types = {
				{ word = "!mode:", menu = "🎯 pick mode" },
				{ word = "!model:", menu = "🤖 pick model" },
				{ word = "!skill:", menu = "📘 pick skill" },
				{ word = "!symbol:", menu = "🔗 pick symbol" },
				{ word = "!feature:", menu = "📋 pick feature" },
				{ word = "!lib:", menu = "📚 pick library" },
				{ word = "!file:", menu = "📁 pick file" },
				{ word = "!depth:", menu = "🧠 think depth" },
				{ word = "!audit:", menu = "👁️ peer review model" },
			}
			for _, mt in ipairs(modifier_types) do
				if typed == "" or mt.word:sub(2):lower():find(typed, 1, true) then
					items[#items + 1] = { word = mt.word, menu = mt.menu, icase = 1 }
				end
			end
			-- Also show legacy model names
			pcall(function()
				for _, name in ipairs(require("dwight.providers").all_model_names()) do
					if typed ~= "" and name:lower():find(typed, 1, true) then
						items[#items + 1] = { word = "!" .. name, menu = "[model]", icase = 1 }
					end
				end
			end)
		end
	elseif trigger == "$" then
		local ok, names = pcall(function()
			return require("dwight.features").names()
		end)
		if ok and names then
			for _, name in ipairs(names) do
				if typed == "" or name:lower():find(typed, 1, true) then
					items[#items + 1] = { word = "$" .. name, menu = "[feature]", icase = 1 }
				end
			end
		end
	elseif trigger == "^" then
		items = {
			{ word = "^2", menu = "🧠 chain-of-thought", icase = 1 },
			{ word = "^3", menu = "🧠🧠 analyze → code (2 passes)", icase = 1 },
			{ word = "^4", menu = "🧠🧠🧠 analyze → plan → code (3 passes)", icase = 1 },
		}
	elseif trigger == "%" then
		local ok, names = pcall(function()
			return require("dwight.libs").names()
		end)
		if ok and names then
			for _, name in ipairs(names) do
				if typed == "" or name:lower():find(typed, 1, true) then
					items[#items + 1] = { word = "%" .. name, menu = "[lib]", icase = 1 }
				end
			end
		end
	elseif trigger == "&" then
		local ok, names = pcall(function()
			return require("dwight.mcp").server_names()
		end)
		if ok and names then
			for _, name in ipairs(names) do
				if typed == "" or name:lower():find(typed, 1, true) then
					items[#items + 1] = { word = "&" .. name .. ":", menu = "[mcp]", icase = 1 }
				end
			end
		end
	elseif trigger == "+" then
		-- File/folder completion
		pcall(function()
			local ts = require("dwight.treesitter")
			for _, f in ipairs(ts.project_files(typed)) do
				if typed == "" or f:lower():find(typed, 1, true) then
					items[#items + 1] = { word = "+" .. f, menu = "[file]", icase = 1 }
				end
				if #items >= 30 then
					break
				end -- limit for performance
			end
		end)
	elseif trigger == "~" then
		-- ~audit completion
		items[#items + 1] = { word = "~audit", menu = "👁️ peer review (default model)", icase = 1 }
		pcall(function()
			for _, name in ipairs(require("dwight.providers").all_model_names()) do
				if typed == "" or ("audit:" .. name):lower():find(typed, 1, true) then
					items[#items + 1] = { word = "~audit:" .. name, menu = "👁️ review with " .. name, icase = 1 }
				end
			end
		end)
	end

	return items
end

--------------------------------------------------------------------
-- Agent/Auto Request Builder
--------------------------------------------------------------------

--- Build a context-enriched request string for agent/auto dispatch.
--- Agent backends accept a plain string, so we append resolved context
--- (features, files, symbols) to the user's clean text.
local function build_agent_request(clean_text, parsed, resolved_features, resolved_files, resolved_symbols)
	local parts = { clean_text }

	-- $feature: append feature file lists
	if #resolved_features > 0 then
		local feat_lines = { "\n\nRelevant feature files:" }
		for _, feat in ipairs(resolved_features) do
			if feat.content then
				feat_lines[#feat_lines + 1] = feat.content
			end
		end
		parts[#parts + 1] = table.concat(feat_lines, "\n")
	end

	-- +file: append attached file contents
	if #resolved_files > 0 then
		local file_lines = { "\n\nAttached files:" }
		for _, f in ipairs(resolved_files) do
			file_lines[#file_lines + 1] = "--- " .. f.name .. " ---\n" .. f.content
		end
		parts[#parts + 1] = table.concat(file_lines, "\n")
	end

	-- #sym: append referenced symbol locations
	if #resolved_symbols > 0 then
		local sym_lines = { "\n\nReferenced symbols:" }
		for _, sym in ipairs(resolved_symbols) do
			local loc = sym.filepath
					and sym.line
					and string.format("%s:%d", vim.fn.fnamemodify(sym.filepath, ":."), sym.line)
				or "unknown"
			sym_lines[#sym_lines + 1] = "- " .. sym.name .. " (" .. loc .. ")"
		end
		parts[#parts + 1] = table.concat(sym_lines, "\n")
	end

	return table.concat(parts)
end

--------------------------------------------------------------------
-- Floating Prompt Window
--------------------------------------------------------------------

local EDITABLE_LINES = 6

function M.open_prompt(selection, opts)
	opts = opts or {}
	local dispatch = opts.dispatch or "invoke"

	local cfg = require("dwight").config
	if selection then
		M._source_bufnr = selection.bufnr
	end

	local width = math.floor(vim.o.columns * 0.65)
	width = math.max(width, 60)
	local height = EDITABLE_LINES + 1 -- editable + status bar

	local row = math.floor((vim.o.lines - height) / 2)
	local col = math.floor((vim.o.columns - width) / 2)

	local buf = api.nvim_create_buf(false, true)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].filetype = "dwight_prompt"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].omnifunc = "v:lua.require'dwight.ui'.omnifunc"

	local file_info
	if selection then
		file_info = string.format(
			"%d lines · %s",
			selection.end_line - selection.start_line + 1,
			vim.fn.fnamemodify(selection.filepath or "", ":t")
		)
	else
		file_info = dispatch
	end

	local model_display = "default"
	pcall(function()
		local backend = cfg.backend or "api"
		if backend == "claude_code" then
			model_display = "claude_code/" .. (cfg.claude_code_model or "sonnet")
		elseif backend == "opencode" then
			model_display = "opencode/" .. (cfg.model or "default")
		else
			local resolved = require("dwight.providers").resolve_model(nil)
			local alias = resolved.model_id or ""
			local short = alias:match("([^/]+)$") or alias
			if #short > 20 then
				short = short:sub(1, 17) .. "…"
			end
			model_display = resolved.provider_name .. "/" .. short
		end
	end)

	local content = {}
	for _ = 1, EDITABLE_LINES do
		content[#content + 1] = ""
	end
	-- Build status bar with box-drawing characters
	local left = "╰─ "
	local mid_sep = " ─── "
	local right_cap = " ─╯"
	local help_hint = "? help"
	-- Compute padding to fill the width
	local inner = left .. file_info .. " · " .. model_display .. mid_sep .. help_hint .. right_cap
	local inner_len = vim.fn.strdisplaywidth(inner)
	local pad = ""
	if inner_len < width then
		pad = string.rep("─", width - inner_len)
	end
	local status_line = left
		.. file_info
		.. " · "
		.. model_display
		.. " ─"
		.. pad
		.. "── "
		.. help_hint
		.. " ─╯"
	content[#content + 1] = status_line

	api.nvim_buf_set_lines(buf, 0, -1, false, content)

	local win = api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = row,
		col = col,
		style = "minimal",
		border = cfg.border,
		title = dispatch == "invoke" and " dwight " or (" dwight:" .. dispatch .. " "),
		title_pos = "center",
	})

	vim.wo[win].winhl = "Normal:Normal,FloatBorder:DwightBorder,FloatTitle:DwightTitle"
	vim.wo[win].cursorline = false
	vim.wo[win].wrap = true
	vim.wo[win].linebreak = true

	-- Highlight status bar segments with extmarks
	local help_ns = api.nvim_create_namespace("dwight_help_hl")
	local sl = status_line
	-- Base: entire line as Comment (border chars)
	api.nvim_buf_add_highlight(buf, help_ns, "Comment", EDITABLE_LINES, 0, -1)
	-- File info segment (search after the leading box-drawing chars)
	local fi_start = sl:find(file_info, #left, true)
	if fi_start then
		api.nvim_buf_add_highlight(buf, help_ns, "DwightFile", EDITABLE_LINES, fi_start - 1, fi_start - 1 + #file_info)
	end
	-- Model segment (search after file_info)
	local md_start = sl:find(model_display, (fi_start or 1) + #file_info, true)
	if md_start then
		api.nvim_buf_add_highlight(
			buf,
			help_ns,
			"DwightModel",
			EDITABLE_LINES,
			md_start - 1,
			md_start - 1 + #model_display
		)
	end
	-- Help hint (search from the end portion)
	local hh_start = sl:find(help_hint, (md_start or 1) + #model_display, true)
	if hh_start then
		api.nvim_buf_add_highlight(
			buf,
			help_ns,
			"DwightHelpHint",
			EDITABLE_LINES,
			hh_start - 1,
			hh_start - 1 + #help_hint
		)
	end

	-- Protect help lines
	api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
		buffer = buf,
		callback = function()
			local cursor = api.nvim_win_get_cursor(win)
			if cursor[1] > EDITABLE_LINES then
				api.nvim_win_set_cursor(win, { EDITABLE_LINES, cursor[2] })
			end
		end,
	})

	-- Help popup
	local help_win = nil
	local help_buf = nil

	local function toggle_help()
		if help_win and api.nvim_win_is_valid(help_win) then
			api.nvim_win_close(help_win, true)
			help_win = nil
			help_buf = nil
			return
		end

		local help_width = 35
		local help_row = row
		local help_col = col + width + 2

		help_buf = api.nvim_create_buf(false, true)
		vim.bo[help_buf].buftype = "nofile"
		vim.bo[help_buf].bufhidden = "wipe"
		local help_lines = {
			" Tokens",
			"  /mode   fix test stub …",
			"  @skill  pick a skill",
			"  $feat   project feature",
			"  #sym    code symbol",
			"  %lib    library docs",
			"  &mcp    mcp resource",
			"  +file   attach file",
			"  ~audit  peer review",
			"  ^N      think depth",
			"  !model  override model",
			"",
			" Keys",
			"  <CR> submit   <Tab> complete",
			"  <Esc> normal  q close",
		}
		api.nvim_buf_set_lines(help_buf, 0, -1, false, help_lines)

		help_win = api.nvim_open_win(help_buf, false, {
			relative = "editor",
			width = help_width,
			height = #help_lines,
			row = help_row,
			col = help_col,
			style = "minimal",
			border = "rounded",
			title = " help ",
			title_pos = "center",
		})

		vim.wo[help_win].winhl = "Normal:Normal,FloatBorder:DwightBorder"
		local hl_ns = api.nvim_create_namespace("dwight_help_popup_hl")
		-- Base: all lines as Comment
		for i = 0, #help_lines - 1 do
			api.nvim_buf_add_highlight(help_buf, hl_ns, "Comment", i, 0, -1)
		end
		-- Section titles → DwightTitle
		api.nvim_buf_add_highlight(help_buf, hl_ns, "DwightTitle", 0, 0, -1)
		api.nvim_buf_add_highlight(help_buf, hl_ns, "DwightTitle", 12, 0, -1)
		-- Token sigils: highlight the sigil+keyword in each row
		-- { line_idx, col_start (byte), col_end (byte), hl_group }
		local sigil_hls = {
			{ 1, 2, 7, "DwightMode" }, -- /mode
			{ 2, 2, 8, "DwightSkill" }, -- @skill
			{ 3, 2, 7, "DwightFeature" }, -- $feat
			{ 4, 2, 6, "DwightSymbol" }, -- #sym
			{ 5, 2, 6, "DwightLib" }, -- %lib
			{ 6, 2, 6, "DwightMcp" }, -- &mcp
			{ 7, 2, 7, "DwightFile" }, -- +file
			{ 8, 2, 8, "DwightAudit" }, -- ~audit
			{ 9, 2, 4, "DwightThink" }, -- ^N
			{ 10, 2, 8, "DwightModel" }, -- !model
		}
		for _, h in ipairs(sigil_hls) do
			api.nvim_buf_add_highlight(help_buf, hl_ns, h[4], h[1], h[2], h[3])
		end
	end

	-- completeopt
	local saved_completeopt = vim.o.completeopt
	vim.opt.completeopt = "menuone,noinsert,noselect"
	api.nvim_create_autocmd("BufWipeout", {
		buffer = buf,
		once = true,
		callback = function()
			vim.opt.completeopt = saved_completeopt
			if help_win and api.nvim_win_is_valid(help_win) then
				api.nvim_win_close(help_win, true)
				help_win = nil
			end
		end,
	})

	api.nvim_win_set_cursor(win, { 1, 0 })
	vim.cmd("startinsert")

	-- Live highlighting
	highlight_prompt_buf(buf, EDITABLE_LINES)
	api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
		buffer = buf,
		callback = function()
			highlight_prompt_buf(buf, EDITABLE_LINES)
		end,
	})

	-- Trigger omnifunc on token chars
	api.nvim_create_autocmd("InsertCharPre", {
		buffer = buf,
		callback = function()
			local char = vim.v.char
			if
				char == "@"
				or char == "/"
				or char == "#"
				or char == "!"
				or char == "$"
				or char == "^"
				or char == "%"
				or char == "&"
			then
				vim.schedule(function()
					if api.nvim_buf_is_valid(buf) and vim.fn.pumvisible() == 0 then
						vim.fn.feedkeys(api.nvim_replace_termcodes("<C-x><C-o>", true, false, true), "n")
					end
				end)
			end
		end,
	})

	-- Re-trigger as user types
	api.nvim_create_autocmd("TextChangedI", {
		buffer = buf,
		callback = function()
			if vim.fn.pumvisible() == 1 then
				return
			end
			local trigger = find_token_at_cursor()
			if trigger then
				vim.schedule(function()
					if api.nvim_buf_is_valid(buf) then
						vim.fn.feedkeys(api.nvim_replace_termcodes("<C-x><C-o>", true, false, true), "n")
					end
				end)
			end
		end,
	})

	-- Tab / S-Tab
	vim.keymap.set("i", "<Tab>", function()
		if vim.fn.pumvisible() == 1 then
			return api.nvim_replace_termcodes("<C-n>", true, false, true)
		else
			return api.nvim_replace_termcodes("<C-x><C-o>", true, false, true)
		end
	end, { buffer = buf, expr = true })

	vim.keymap.set("i", "<S-Tab>", function()
		if vim.fn.pumvisible() == 1 then
			return api.nvim_replace_termcodes("<C-p>", true, false, true)
		end
		return ""
	end, { buffer = buf, expr = true })

	-- Enter: accept completion or submit
	vim.keymap.set("i", "<CR>", function()
		if vim.fn.pumvisible() == 1 then
			return api.nvim_replace_termcodes("<C-y>", true, false, true)
		end

		vim.schedule(function()
			local input_lines = api.nvim_buf_get_lines(buf, 0, EDITABLE_LINES, false)
			local raw_text = vim.trim(table.concat(input_lines, " "))

			if api.nvim_win_is_valid(win) then
				api.nvim_win_close(win, true)
			end

			if raw_text == "" then
				vim.notify("[dwight] Empty prompt.", vim.log.levels.INFO)
				return
			end

			local parsed = M.parse_tokens(raw_text)
			local skill_paths = require("dwight.skills").resolve_many(parsed.skills)
			local resolved_symbols = require("dwight.symbols").resolve_many(parsed.symbols)
			local resolved_features = require("dwight.features").resolve_many(parsed.features)
			local resolved_libs = require("dwight.libs").resolve_many(parsed.libs)
			local resolved_mcp = require("dwight.mcp").resolve_many(parsed.mcp_refs)

			-- Resolve +file tokens → treesitter minimaps or full files
			local resolved_files = {}
			for _, fpath in ipairs(parsed.files or {}) do
				pcall(function()
					local ts = require("dwight.treesitter")
					local cwd = vim.fn.getcwd() .. "/"
					local full = fpath:match("^/") and fpath or (cwd .. fpath)
					if vim.fn.isdirectory(full) == 1 then
						local content = ts.minimap_dir(full)
						if content then
							resolved_files[#resolved_files + 1] = { name = fpath, content = content }
						end
					else
						local content = ts.minimap(full)
						if content then
							resolved_files[#resolved_files + 1] = { name = fpath, content = content }
						end
					end
				end)
			end

			vim.schedule(function()
				if dispatch == "agent" or dispatch == "auto" then
					local request = build_agent_request(
						parsed.clean_text,
						parsed,
						resolved_features,
						resolved_files,
						resolved_symbols
					)
					if dispatch == "agent" then
						require("dwight.agent").run(request, opts.agent_opts or {})
					else
						require("dwight.auto").auto(request)
					end
				elseif parsed.mode then
					local mode = require("dwight.modes").get(parsed.mode)
					if mode then
						-- Apply +run modifier: inject last build/test output
						if parsed.modifiers and parsed.modifiers.run then
							mode = vim.tbl_extend("force", mode, { inject_run_output = true })
						end
						local ctx = require("dwight.lsp").gather_context(selection)
						local prompt_text = require("dwight.prompt").build(
							mode,
							selection,
							ctx,
							parsed.clean_text,
							skill_paths,
							resolved_symbols,
							resolved_features,
							parsed.think_depth,
							resolved_libs,
							resolved_mcp,
							resolved_files
						)
						require("dwight.inline").run(
							prompt_text,
							selection,
							cfg,
							parsed.mode,
							parsed.model_override,
							parsed.think_depth,
							{
								audit_model = parsed.audit_model,
								is_lint = mode.is_lint,
								is_macro = mode.is_macro,
								is_docs = mode.is_docs,
								is_prose = mode.context == "prose",
								is_plan = mode.is_plan,
								is_multi = mode.is_multi,
							}
						)
					else
						vim.notify("[dwight] Unknown mode: /" .. parsed.mode, vim.log.levels.ERROR)
					end
				else
					local prompt_text = require("dwight.prompt").build_freeform(
						parsed.clean_text,
						selection,
						skill_paths,
						resolved_symbols,
						resolved_features,
						parsed.think_depth,
						resolved_libs,
						resolved_mcp,
						resolved_files
					)
					require("dwight.inline").run(
						prompt_text,
						selection,
						cfg,
						"custom",
						parsed.model_override,
						parsed.think_depth,
						{ audit_model = parsed.audit_model }
					)
				end
			end)
		end)

		return ""
	end, { buffer = buf, expr = true })

	-- Esc: normal mode
	vim.keymap.set("i", "<Esc>", function()
		if vim.fn.pumvisible() == 1 then
			return api.nvim_replace_termcodes("<C-e>", true, false, true)
		end
		vim.cmd("stopinsert")
		return ""
	end, { buffer = buf, expr = true })

	-- q: close
	vim.keymap.set("n", "q", function()
		if api.nvim_win_is_valid(win) then
			api.nvim_win_close(win, true)
		end
	end, { buffer = buf, noremap = true, silent = true })

	-- i to re-enter insert
	vim.keymap.set("n", "i", function()
		local cursor = api.nvim_win_get_cursor(win)
		if cursor[1] > EDITABLE_LINES then
			api.nvim_win_set_cursor(win, { EDITABLE_LINES, 0 })
		end
		vim.cmd("startinsert")
	end, { buffer = buf, noremap = true })

	-- ?: toggle help popup
	vim.keymap.set("n", "?", toggle_help, { buffer = buf, noremap = true, silent = true })
	vim.keymap.set("i", "?", function()
		vim.schedule(toggle_help)
		return ""
	end, { buffer = buf, expr = true })
end

return M
