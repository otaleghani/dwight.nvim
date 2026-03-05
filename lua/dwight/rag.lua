-- dwight/rag.lua
-- Retrieval-augmented generation using ripgrep.
-- When the user's prompt references symbols not in the selection,
-- rg searches the codebase and injects surrounding context.

local M = {}

local uv = vim.loop or vim.uv

--------------------------------------------------------------------
-- Ripgrep search
--------------------------------------------------------------------

local function rg_search(pattern, max_results, callback)
	max_results = max_results or 10
	local chunks = {}
	local stdout = uv.new_pipe(false)
	local handle
	handle = uv.spawn("rg", {
		args = {
			"--no-heading",
			"--line-number",
			"--column",
			"-m",
			tostring(max_results),
			"--type-add",
			"code:*.{ts,tsx,js,jsx,py,go,rs,lua,rb,java,kt,c,cpp,h,cs,swift}",
			"-t",
			"code",
			"--glob",
			"!node_modules",
			"--glob",
			"!.git",
			"--glob",
			"!dist",
			"--glob",
			"!build",
			"--glob",
			"!vendor",
			"--glob",
			"!__pycache__",
			pattern,
		},
		stdio = { nil, stdout, nil },
		cwd = vim.fn.getcwd(),
	}, function(code)
		if stdout then
			stdout:close()
		end
		if handle then
			handle:close()
		end
		vim.schedule(function()
			callback(code == 0 and table.concat(chunks, "") or nil)
		end)
	end)
	if not handle then
		callback(nil)
		return
	end
	stdout:read_start(function(err, data)
		if not err and data then
			chunks[#chunks + 1] = data
		end
	end)
end

local function rg_search_sync(pattern, max_results, timeout_ms)
	local result, done = nil, false
	rg_search(pattern, max_results, function(out)
		result = out
		done = true
	end)
	vim.wait(timeout_ms or 5000, function()
		return done
	end, 50)
	return result
end

--------------------------------------------------------------------
-- Context extraction: get surrounding lines for each match
--------------------------------------------------------------------

local function read_lines(filepath, center_line, context_lines)
	context_lines = context_lines or 5
	local f = io.open(filepath, "r")
	if not f then
		return nil
	end
	local lines = {}
	local i = 0
	for line in f:lines() do
		i = i + 1
		lines[i] = line
	end
	f:close()

	local start = math.max(1, center_line - context_lines)
	local stop = math.min(#lines, center_line + context_lines)
	local result = {}
	for j = start, stop do
		result[#result + 1] = lines[j]
	end
	return table.concat(result, "\n"), start, stop
end

--------------------------------------------------------------------
-- Extract symbols from user prompt text
--------------------------------------------------------------------

local function extract_potential_symbols(text)
	local symbols = {}
	local seen = {}
	-- CamelCase words, snake_case with capitals, or words with dots
	for word in text:gmatch("[A-Z][%w_]+") do
		if not seen[word] and #word >= 3 then
			seen[word] = true
			symbols[#symbols + 1] = word
		end
	end
	for word in text:gmatch("[%w_]+%.[%w_]+") do
		if not seen[word] then
			seen[word] = true
			symbols[#symbols + 1] = word
		end
	end
	return symbols
end

--------------------------------------------------------------------
-- Public API: gather RAG context for a prompt
--------------------------------------------------------------------

--- Search codebase for symbols mentioned in the prompt.
--- Returns context string or nil.
function M.gather_context(prompt_text, selection, max_symbols, max_results_per)
	max_symbols = max_symbols or 5
	max_results_per = max_results_per or 3

	-- Check if rg is available
	if vim.fn.executable("rg") ~= 1 then
		return nil
	end

	local symbols = extract_potential_symbols(prompt_text)
	if #symbols == 0 then
		return nil
	end

	-- Filter out symbols that are already in the selection
	local sel_text = selection and selection.text or ""
	local relevant = {}
	for _, sym in ipairs(symbols) do
		if not sel_text:find(sym, 1, true) then
			relevant[#relevant + 1] = sym
		end
	end
	if #relevant == 0 then
		return nil
	end

	-- Limit number of symbols to search
	if #relevant > max_symbols then
		relevant = vim.list_slice(relevant, 1, max_symbols)
	end

	local parts = {}
	local current_file = selection and selection.filepath or ""
	local seen_files = {}

	for _, sym in ipairs(relevant) do
		local output = rg_search_sync(sym, max_results_per, 3000)
		if output then
			for line in output:gmatch("[^\n]+") do
				local file, lnum = line:match("^(.-):(%-?%d+):")
				if file and lnum then
					lnum = tonumber(lnum)
					local abs_file = vim.fn.getcwd() .. "/" .. file
					-- Skip the current file (already in context)
					if abs_file ~= current_file then
						local key = file .. ":" .. lnum
						if not seen_files[key] then
							seen_files[key] = true
							local context, start_l, end_l = read_lines(abs_file, lnum, 4)
							if context then
								parts[#parts + 1] =
									string.format("--- %s (lines %d-%d) ---\n%s", file, start_l, end_l, context)
							end
						end
					end
				end
			end
		end
	end

	if #parts == 0 then
		return nil
	end
	return "Related code from the project:\n" .. table.concat(parts, "\n\n")
end

return M
