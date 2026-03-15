-- dwight/split/analysis.lua
-- Feature complexity analysis: measure files, lines, symbols.

local M = {}

--- Analyze a feature's complexity.
--- Returns { name, file_count, total_lines, symbol_count, files = { ... } }
function M.analyze_feature(name)
	local features = require("dwight.features")
	local feature = features.build_feature(name)
	if not feature then
		return nil
	end

	local cwd = vim.fn.getcwd()
	local total_lines = 0
	local symbol_count = 0
	local file_details = {}
	local seen_paths = {}

	for _, file in ipairs(feature.files) do
		-- Deduplicate: same file can appear multiple times if it has multiple pragma lines
		-- Normalize path: trim whitespace, remove leading ./
		local norm_path = vim.trim(file.path):gsub("^%./", "")
		if seen_paths[norm_path] then
			goto continue
		end
		seen_paths[norm_path] = true

		local full_path = norm_path
		if not full_path:match("^/") then
			full_path = cwd .. "/" .. full_path
		end

		-- Count lines
		local f = io.open(full_path, "r")
		local lines = 0
		local content = ""
		if f then
			content = f:read("*a")
			f:close()
			lines = select(2, content:gsub("\n", "\n")) + 1
		end
		total_lines = total_lines + lines

		-- Count symbols from signatures
		local sigs = file.signatures or ""
		local sig_count = 0
		for _ in sigs:gmatch("[^\n]+") do
			sig_count = sig_count + 1
		end
		symbol_count = symbol_count + sig_count

		file_details[#file_details + 1] = {
			path = norm_path,
			full_path = full_path,
			lines = lines,
			symbols = sig_count,
			signatures = sigs,
			dependencies = file.dependencies or {},
			-- First 50 lines for LLM context (to understand what the file does)
			preview = content:sub(1, 2000),
		}
		::continue::
	end

	return {
		name = name,
		description = feature.description,
		file_count = #file_details,
		total_lines = total_lines,
		symbol_count = symbol_count,
		files = file_details,
	}
end

--- Check if a feature should be split.
--- Returns true + reason if it's too big, false + nil if it's fine.
function M.should_split(name)
	local analysis = M.analyze_feature(name)
	if not analysis then
		return false, nil
	end

	-- Thresholds (tuned from experience with agentic loop)
	if analysis.file_count >= 8 then
		return true, string.format("%d files (threshold: 8)", analysis.file_count)
	end
	if analysis.total_lines >= 1500 then
		return true, string.format("%d total lines (threshold: 1500)", analysis.total_lines)
	end
	if analysis.symbol_count >= 40 then
		return true, string.format("%d symbols (threshold: 40)", analysis.symbol_count)
	end

	return false, nil
end

return M
