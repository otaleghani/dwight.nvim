-- dwight/codebase_audit/checks.lua
-- Per-file static checks: function analysis, secrets, errors, test coverage, duplication.

local M = {}

--------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------

--- Read file lines. Returns lines array or nil.
function M.read_lines(filepath)
	local cwd = vim.fn.getcwd()
	local full = filepath:sub(1, 1) == "/" and filepath or (cwd .. "/" .. filepath)
	local f = io.open(full, "r")
	if not f then
		return nil
	end
	local content = f:read("*a")
	f:close()
	return vim.split(content, "\n", { plain = true })
end

--- Count nesting depth at a line (braces/indentation).
function M.nesting_at(line)
	local indent = #(line:match("^(%s*)") or "")
	-- Use indent as proxy: each 2/4 spaces = 1 level
	local tab_size = line:match("^\t") and 1 or (indent > 0 and (line:match("^    ") and 4 or 2) or 2)
	return math.floor(indent / tab_size)
end

--- Analyze functions in a file using treesitter.
--- Returns list of { name, start_line, end_line, line_count, max_nesting, param_count }
function M.analyze_functions_ts(filepath)
	local cwd = vim.fn.getcwd()
	local full = filepath:sub(1, 1) == "/" and filepath or (cwd .. "/" .. filepath)
	local f_handle = io.open(full, "r")
	if not f_handle then
		return {}
	end
	local source = f_handle:read("*a")
	f_handle:close()

	local ft = vim.filetype.match({ filename = full }) or ""
	local lang = vim.treesitter.language.get_lang(ft)
	if not lang then
		return {}
	end

	local ok, parser = pcall(vim.treesitter.get_string_parser, source, lang)
	if not ok or not parser then
		return {}
	end

	local tree = parser:parse()[1]
	if not tree then
		return {}
	end

	local root = tree:root()
	local lines = vim.split(source, "\n", { plain = true })
	local results = {}

	local FUNC_NODES = {
		function_declaration = true,
		function_definition = true,
		method_definition = true,
		method_declaration = true,
		function_item = true,
		function_statement = true,
		arrow_function = true,
		func_literal = true,
	}

	local function walk(node, depth)
		for child in node:iter_children() do
			local ctype = child:type()
			if FUNC_NODES[ctype] then
				local sr, _, er, _ = child:range()
				local line_count = er - sr + 1
				local sig_line = lines[sr + 1] or ""

				-- Extract function name (best effort)
				local name = sig_line:match("function%s+([%w_%.]+)")
					or sig_line:match("func%s+[%(%w%*%s%)]*([%w_]+)")
					or sig_line:match("def%s+([%w_]+)")
					or sig_line:match("fn%s+([%w_]+)")
					or sig_line:match("([%w_]+)%s*[:=]%s*function")
					or sig_line:match("([%w_]+)%s*[:=]%s*%(")
					or sig_line:match("([%w_]+)%s*[:=]%s*async")
					or "(anonymous)"

				-- Count params (rough: count commas + 1 inside first parens)
				local params_str = sig_line:match("%((.-)%)") or ""
				local param_count = 0
				if vim.trim(params_str) ~= "" then
					param_count = 1
					for _ in params_str:gmatch(",") do
						param_count = param_count + 1
					end
				end

				-- Max nesting within function body
				local max_nest = 0
				local base_nest = M.nesting_at(lines[sr + 1] or "")
				for i = sr + 1, er + 1 do
					if lines[i] then
						local nest = M.nesting_at(lines[i]) - base_nest
						if nest > max_nest then
							max_nest = nest
						end
					end
				end

				results[#results + 1] = {
					name = name,
					start_line = sr + 1,
					end_line = er + 1,
					line_count = line_count,
					max_nesting = max_nest,
					param_count = param_count,
				}

				walk(child, depth + 1)
			else
				walk(child, depth)
			end
		end
	end

	walk(root, 0)
	return results
end

--- Check a file for hardcoded secrets.
function M.check_secrets(filepath, lines)
	local constants = require("dwight.codebase_audit.constants")
	local SEV = constants.SEV
	local SECRET_PATTERNS = constants.SECRET_PATTERNS

	local findings = {}
	for i, line in ipairs(lines) do
		local lower = line:lower()
		for _, pat in ipairs(SECRET_PATTERNS) do
			if lower:match(pat.pat) then
				findings[#findings + 1] = {
					severity = SEV.CRITICAL,
					category = "security",
					file = filepath,
					line = i,
					message = pat.label,
					snippet = vim.trim(line):sub(1, 80),
				}
			end
		end
	end
	return findings
end

--- Check a file for swallowed errors.
function M.check_errors(filepath, lines, lang)
	local constants = require("dwight.codebase_audit.constants")
	local SEV = constants.SEV
	local SWALLOWED_ERROR_PATTERNS = constants.SWALLOWED_ERROR_PATTERNS

	local findings = {}
	local content = table.concat(lines, "\n")
	for _, pat in ipairs(SWALLOWED_ERROR_PATTERNS) do
		if pat.lang == lang or pat.lang == "generic" then
			-- Find all occurrences
			local search_pos = 1
			while true do
				local s, e = content:find(pat.pat, search_pos)
				if not s then
					break
				end
				-- Convert byte position to line number
				local line_num = 1
				for _ in content:sub(1, s):gmatch("\n") do
					line_num = line_num + 1
				end
				findings[#findings + 1] = {
					severity = SEV.CRITICAL,
					category = "error-handling",
					file = filepath,
					line = line_num,
					message = pat.label,
					snippet = vim.trim(lines[line_num] or ""):sub(1, 80),
				}
				search_pos = e + 1
			end
		end
	end
	return findings
end

--- Check for test coverage: does this source file have a corresponding test file?
function M.check_test_coverage(filepath)
	local constants = require("dwight.codebase_audit.constants")
	local SEV = constants.SEV

	local cwd = vim.fn.getcwd()
	local base = filepath:match("([^/]+)$") or filepath
	local dir = filepath:match("^(.+)/") or ""
	local name, ext = base:match("^(.+)(%.[^.]+)$")
	if not name then
		return nil
	end

	-- Common test file patterns
	local test_patterns = {
		dir .. "/" .. name .. "_test" .. ext, -- Go: foo_test.go
		dir .. "/" .. name .. ".test" .. ext, -- JS: foo.test.ts
		dir .. "/" .. name .. ".spec" .. ext, -- JS: foo.spec.ts
		dir .. "/__tests__/" .. name .. ext, -- JS: __tests__/foo.ts
		dir .. "/test_" .. name .. ext, -- Python: test_foo.py
		"tests/" .. name .. "_test" .. ext, -- tests/foo_test.go
		"test/" .. name .. "_test" .. ext, -- test/foo_test.go
		"spec/" .. name .. "_spec" .. ext, -- Ruby: spec/foo_spec.rb
	}

	for _, test_path in ipairs(test_patterns) do
		local full = cwd .. "/" .. test_path
		local f = io.open(full, "r")
		if f then
			f:close()
			return nil
		end -- test file exists, no finding
	end

	return {
		severity = SEV.INFO,
		category = "test-coverage",
		file = filepath,
		line = 1,
		message = "no test file found",
		snippet = "expected: " .. name .. "_test" .. ext .. " or " .. name .. ".test" .. ext,
	}
end

--- Find code duplication within a set of files.
--- Returns findings for blocks of MIN_DUPLICATION_LEN+ identical consecutive lines.
--- Skips structural noise (imports, pragmas, error checks, assertions).
--- Deduplicates: reports each unique block once with all locations.
function M.check_duplication(files_with_lines)
	local constants = require("dwight.codebase_audit.constants")
	local SEV = constants.SEV
	local DUPLICATION_SKIP_PATTERNS = constants.DUPLICATION_SKIP_PATTERNS
	local MIN_DUPLICATION_LEN = constants.MIN_DUPLICATION_LEN

	local findings = {}

	-- Check if a line is structural noise that shouldn't count for duplication
	local function is_skip_line(line)
		local trimmed = vim.trim(line)
		if #trimmed <= 10 then
			return true
		end
		if trimmed:match("^[%s{}%(%)%[%];,]$") then
			return true
		end
		for _, pat in ipairs(DUPLICATION_SKIP_PATTERNS) do
			if trimmed:match(pat) then
				return true
			end
		end
		return false
	end

	-- Build normalized content per file: only meaningful lines, with original line numbers
	-- Each entry: { orig_line = N, content = "trimmed line" }
	local file_meaningful = {}
	for filepath, lines in pairs(files_with_lines) do
		local meaningful = {}
		for i, line in ipairs(lines) do
			if not is_skip_line(line) then
				meaningful[#meaningful + 1] = { orig_line = i, content = vim.trim(line) }
			end
		end
		file_meaningful[filepath] = meaningful
	end

	-- Build a hash of each meaningful line -> locations
	local line_index = {}
	for filepath, meaningful in pairs(file_meaningful) do
		for idx, entry in ipairs(meaningful) do
			local hash = entry.content
			if not line_index[hash] then
				line_index[hash] = {}
			end
			line_index[hash][#line_index[hash] + 1] = {
				file = filepath,
				orig_line = entry.orig_line,
				meaningful_idx = idx,
			}
		end
	end

	-- Find consecutive matching blocks using meaningful-line indices.
	-- Track unique blocks by their content fingerprint to avoid reporting the same block N^2 times.
	local reported_blocks = {} -- fingerprint -> { locations = { {file, line}, ... }, length = N }

	for _, locs in pairs(line_index) do
		if #locs < 2 then
			goto continue
		end

		for a = 1, #locs do
			for b = a + 1, #locs do
				local la, lb = locs[a], locs[b]
				-- Skip same-file matches that are close together (overlapping)
				if la.file == lb.file and math.abs(la.meaningful_idx - lb.meaningful_idx) < MIN_DUPLICATION_LEN then
					goto next_pair
				end

				-- Count consecutive meaningful-line matches
				local ma = file_meaningful[la.file]
				local mb = file_meaningful[lb.file]
				local count = 0
				while
					la.meaningful_idx + count <= #ma
					and lb.meaningful_idx + count <= #mb
					and ma[la.meaningful_idx + count].content == mb[lb.meaningful_idx + count].content
				do
					count = count + 1
				end

				if count >= MIN_DUPLICATION_LEN then
					-- Build a content fingerprint from the first few lines
					local fp_parts = {}
					for k = 0, math.min(3, count - 1) do
						fp_parts[#fp_parts + 1] = ma[la.meaningful_idx + k].content:sub(1, 40)
					end
					local fingerprint = table.concat(fp_parts, "|")

					if not reported_blocks[fingerprint] then
						reported_blocks[fingerprint] = {
							locations = {},
							length = count,
							snippet = ma[la.meaningful_idx].content:sub(1, 60),
						}
					end
					-- Add both locations (deduplicated by file:line)
					local block = reported_blocks[fingerprint]
					local function add_loc(file, line)
						for _, existing in ipairs(block.locations) do
							if existing.file == file and existing.line == line then
								return
							end
						end
						block.locations[#block.locations + 1] = { file = file, line = line }
					end
					add_loc(la.file, ma[la.meaningful_idx].orig_line)
					add_loc(lb.file, mb[lb.meaningful_idx].orig_line)
				end

				::next_pair::
			end
		end

		::continue::
	end

	-- Convert deduplicated blocks to findings (one per unique block)
	for _, block in pairs(reported_blocks) do
		if #block.locations >= 2 then
			-- Report on the first location, mention all others
			local primary = block.locations[1]
			local others = {}
			for i = 2, #block.locations do
				others[#others + 1] = string.format("%s:%d", block.locations[i].file, block.locations[i].line)
			end

			findings[#findings + 1] = {
				severity = SEV.WARN,
				category = "duplication",
				file = primary.file,
				line = primary.line,
				message = string.format(
					"%d duplicated lines across %d locations (also at %s)",
					block.length,
					#block.locations,
					table.concat(others, ", ")
				),
				snippet = block.snippet .. " …",
			}
		end
	end

	return findings
end

return M
