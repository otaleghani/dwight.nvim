-- dwight/treesitter.lua
-- Treesitter integration: minimaps (compressed signatures), smart selection,
-- and structure extraction. Requires nvim-treesitter.
-- +file.ts in prompts sends the file's minimap. Smart select finds enclosing node.

local M = {}

local api = vim.api

--------------------------------------------------------------------
-- Treesitter availability
--------------------------------------------------------------------

local function has_treesitter()
	local ok = pcall(require, "nvim-treesitter.parsers")
	return ok
end

local function get_parser(bufnr, lang)
	local ok, parser = pcall(vim.treesitter.get_parser, bufnr, lang)
	if ok and parser then
		return parser
	end
	return nil
end

--------------------------------------------------------------------
-- Language-specific node types for structure extraction
--------------------------------------------------------------------

local STRUCTURE_NODES = {
	-- Functions
	function_declaration = true,
	function_definition = true,
	method_definition = true,
	method_declaration = true,
	arrow_function = true,
	function_item = true, -- Rust
	func_literal = true,
	function_statement = true,
	-- Classes / types
	class_declaration = true,
	class_definition = true,
	struct_item = true,
	enum_item = true,
	trait_item = true,
	impl_item = true, -- Rust
	interface_declaration = true,
	type_alias_declaration = true,
	-- Exports
	export_statement = true,
	lexical_declaration = true,
}

-- Nodes that are "public API" (exported, pub, etc.)
local EXPORT_INDICATORS = {
	export_statement = true,
	visibility_modifier = true,
}

--------------------------------------------------------------------
-- Smart Selection: find enclosing scope at cursor
--------------------------------------------------------------------

--- Get the enclosing function/class/block at cursor position.
--- Returns { bufnr, start_line, end_line, text, lines, filetype, filepath } or nil.
function M.smart_select(bufnr)
	bufnr = bufnr or api.nvim_get_current_buf()
	local cursor = api.nvim_win_get_cursor(0)
	local row = cursor[1] - 1 -- 0-indexed

	local parser = get_parser(bufnr)
	if not parser then
		return M._fallback_select(bufnr, cursor[1])
	end

	local tree = parser:parse()[1]
	if not tree then
		return M._fallback_select(bufnr, cursor[1])
	end

	local root = tree:root()
	local best_node = nil
	local best_size = math.huge

	-- Walk ancestors from the smallest node at cursor to find the best scope
	local node = root:named_descendant_for_range(row, 0, row, 0)
	while node do
		local ntype = node:type()
		if STRUCTURE_NODES[ntype] then
			local sr, _, er, _ = node:range()
			local size = er - sr
			if size < best_size and size >= 1 then
				best_node = node
				best_size = size
			end
		end
		node = node:parent()
	end

	if not best_node then
		return M._fallback_select(bufnr, cursor[1])
	end

	local sr, _, er, _ = best_node:range()
	local start_line = sr + 1 -- 1-indexed
	local end_line = er + 1

	local lines = api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
	return {
		bufnr = bufnr,
		start_line = start_line,
		end_line = end_line,
		text = table.concat(lines, "\n"),
		lines = lines,
		filetype = vim.bo[bufnr].filetype,
		filepath = api.nvim_buf_get_name(bufnr),
	}
end

--- Fallback when treesitter is unavailable: select current paragraph/block.
function M._fallback_select(bufnr, cursor_line)
	local total = api.nvim_buf_line_count(bufnr)
	local start_line = cursor_line
	local end_line = cursor_line

	-- Expand up to nearest blank line
	while start_line > 1 do
		local line = api.nvim_buf_get_lines(bufnr, start_line - 2, start_line - 1, false)[1]
		if vim.trim(line) == "" then
			break
		end
		start_line = start_line - 1
	end
	-- Expand down to nearest blank line
	while end_line < total do
		local line = api.nvim_buf_get_lines(bufnr, end_line, end_line + 1, false)[1]
		if vim.trim(line) == "" then
			break
		end
		end_line = end_line + 1
	end

	local lines = api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
	return {
		bufnr = bufnr,
		start_line = start_line,
		end_line = end_line,
		text = table.concat(lines, "\n"),
		lines = lines,
		filetype = vim.bo[bufnr].filetype,
		filepath = api.nvim_buf_get_name(bufnr),
	}
end

--------------------------------------------------------------------
-- Minimap: extract structure from a file (signatures + docstrings)
--------------------------------------------------------------------

--- Build a compressed minimap of a file: only declarations, signatures, docstrings.
--- Returns a string suitable for prompt injection.
function M.minimap(filepath)
	if not filepath or filepath == "" then
		return nil
	end

	-- Try treesitter first
	local content = M._minimap_treesitter(filepath)
	if content then
		return content
	end

	-- Fallback: regex-based extraction
	return M._minimap_regex(filepath)
end

--- Treesitter-based minimap extraction.
function M._minimap_treesitter(filepath)
	-- Load file into a temporary buffer for parsing
	local f = io.open(filepath, "r")
	if not f then
		return nil
	end
	local source = f:read("*a")
	f:close()

	local ft = vim.filetype.match({ filename = filepath }) or ""
	local lang = vim.treesitter.language.get_lang(ft)
	if not lang then
		return nil
	end

	local ok, parser = pcall(vim.treesitter.get_string_parser, source, lang)
	if not ok or not parser then
		return nil
	end

	local tree = parser:parse()[1]
	if not tree then
		return nil
	end

	local root = tree:root()
	local lines = vim.split(source, "\n", { plain = true })
	local results = {}

	M._walk_for_minimap(root, lines, results, 0)

	if #results == 0 then
		return nil
	end

	local header = string.format("-- Minimap of %s (%d symbols)\n", vim.fn.fnamemodify(filepath, ":."), #results)
	return header .. table.concat(results, "\n")
end

function M._walk_for_minimap(node, lines, results, depth)
	for child in node:iter_children() do
		local ctype = child:type()
		if STRUCTURE_NODES[ctype] then
			local sr, _, er, _ = child:range()
			-- Get first line (signature) and any preceding comment
			local sig_line = lines[sr + 1] or ""

			-- Check for docstring above
			local doc = ""
			if sr > 0 then
				local prev = lines[sr] or ""
				if prev:match("^%s*[%-%-//%*#]") or prev:match('^%s*"""') or prev:match("^%s*'''") then
					doc = vim.trim(prev) .. "\n"
				end
			end

			-- For multi-line signatures, grab until opening brace/colon
			local sig = sig_line
			if not sig:match("[{:]%s*$") and not sig:match("%)%s*$") and sr + 1 <= er then
				-- Grab up to 3 more lines for the signature
				for i = sr + 2, math.min(sr + 4, er + 1) do
					if lines[i] then
						sig = sig .. "\n" .. lines[i]
						if lines[i]:match("[{:]%s*$") or lines[i]:match("%)") then
							break
						end
					end
				end
			end

			local indent = string.rep("  ", depth)
			if doc ~= "" then
				results[#results + 1] = indent .. doc
			end
			results[#results + 1] = indent .. vim.trim(sig)

			-- Recurse for nested declarations (methods inside classes)
			M._walk_for_minimap(child, lines, results, depth + 1)
		end
	end
end

--- Regex fallback for when treesitter isn't available for the language.
function M._minimap_regex(filepath)
	local f = io.open(filepath, "r")
	if not f then
		return nil
	end
	local source = f:read("*a")
	f:close()

	local sigs = {}
	local prev_line = ""

	for line in source:gmatch("[^\n]+") do
		local trimmed = vim.trim(line)
		-- Match common declaration patterns
		if
			trimmed:match("^%s*function ")
			or trimmed:match("^%s*local function ")
			or trimmed:match("^%s*def ")
			or trimmed:match("^%s*async def ")
			or trimmed:match("^%s*class ")
			or trimmed:match("^%s*export ")
			or trimmed:match("^%s*pub fn ")
			or trimmed:match("^%s*fn ")
			or trimmed:match("^%s*func ")
			or trimmed:match("^%s*type ")
			or trimmed:match("^%s*interface ")
			or trimmed:match("^%s*struct ")
			or trimmed:match("^%s*enum ")
			or trimmed:match("^%s*impl ")
			or trimmed:match("^%s*const .*= function")
			or trimmed:match("^%s*[%w_]+%s*:%s*function")
		then
			-- Include preceding comment
			if prev_line:match("^%s*[%-%-//%*#]") then
				sigs[#sigs + 1] = prev_line
			end
			sigs[#sigs + 1] = trimmed
		end
		prev_line = line
	end

	if #sigs == 0 then
		return nil
	end

	local header = string.format("-- Minimap of %s (%d symbols)\n", vim.fn.fnamemodify(filepath, ":."), #sigs)
	return header .. table.concat(sigs, "\n")
end

--------------------------------------------------------------------
-- Directory minimap: minimaps of all files in a directory
--------------------------------------------------------------------

function M.minimap_dir(dirpath)
	if vim.fn.isdirectory(dirpath) ~= 1 then
		return nil
	end

	local parts = {}
	local handle = (vim.loop or vim.uv).fs_scandir(dirpath)
	if not handle then
		return nil
	end

	while true do
		local name, ftype = (vim.loop or vim.uv).fs_scandir_next(handle)
		if not name then
			break
		end
		if ftype == "file" and not name:match("^%.") then
			local content = M.minimap(dirpath .. "/" .. name)
			if content then
				parts[#parts + 1] = content
			end
		end
	end

	if #parts == 0 then
		return nil
	end
	return table.concat(parts, "\n\n")
end

--------------------------------------------------------------------
-- File list for completion
--------------------------------------------------------------------

function M.project_files(prefix)
	prefix = prefix or ""
	local cwd = vim.fn.getcwd()
	local files = vim.fn.globpath(cwd, prefix .. "**/*", false, true)
	local results = {}
	for _, f in ipairs(files) do
		local rel = f:sub(#cwd + 2)
		-- Skip hidden, node_modules, .git, binary files
		if
			not rel:match("^%.")
			and not rel:match("/%.")
			and not rel:match("node_modules")
			and not rel:match("%.git/")
			and not rel:match("%.png$")
			and not rel:match("%.jpg$")
			and not rel:match("%.wasm$")
			and not rel:match("%.o$")
		then
			results[#results + 1] = rel
		end
	end
	table.sort(results)
	return results
end

return M
