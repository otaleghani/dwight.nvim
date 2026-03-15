-- dwight/inline/parse.lua
-- Parsing LLM output into structured data: fenced code blocks, monologue detection,
-- multi-file output, and pre-apply syntax checking.

local M = {}

function M.extract_code_block(raw)
	local blocks = {}
	for block in raw:gmatch("```[%w_]*%s*\n(.-)\n%s*```") do
		blocks[#blocks + 1] = block
	end
	if #blocks == 0 then
		for block in raw:gmatch("```[%w_]*%s*\n(.-)```") do
			blocks[#blocks + 1] = block
		end
	end
	if #blocks == 0 then
		return nil
	end
	local best = blocks[1]
	for i = 2, #blocks do
		if #blocks[i] > #best then
			best = blocks[i]
		end
	end
	return best
end

function M.looks_like_monologue(text)
	local lines = vim.split(text, "\n", { plain = true })
	if #lines == 0 then
		return true
	end
	local signals, total = 0, 0
	for _, line in ipairs(lines) do
		local t = vim.trim(line)
		if t ~= "" then
			total = total + 1
			if
				t:match("^I['']ll ")
				or t:match("^I['']m ")
				or t:match("^I will ")
				or t:match("^Let me ")
				or t:match("^Now let")
				or t:match("^Here is")
				or t:match("^Here's")
				or t:match("^This code")
				or t:match("^The code")
				or t:match("^I need to")
				or t:match("^First,")
				or t:match("^Note:")
				or t:match("^Looking at")
				or t:match("^Based on")
				or t:match("^To implement")
				or t:match("^The changes")
				or t:match("^Key changes")
				or t:match("^Summary")
				or t:match("^I've ")
				or t:match("^I have ")
				or t:match("^Now,")
				or t:match("^%d+%.%s+[A-Z]")
			then
				signals = signals + 1
			end
		end
	end
	if total == 0 then
		return true
	end
	return (signals / total) > 0.4
end

function M.parse_output(raw, original_text, _language)
	if not raw or raw == "" then
		return nil
	end

	-- Primary: extract from fenced code block
	local code = M.extract_code_block(raw)

	-- Fallback: if no fence found, check if the raw output IS code (not a monologue).
	-- This catches LLMs that return code without fences, common with short outputs.
	if not code then
		local trimmed = vim.trim(raw)
		if not M.looks_like_monologue(trimmed) and trimmed ~= "" then
			-- Strip any leading "Here is..." single line and trailing explanation
			local stripped = trimmed:gsub("^[^\n]-[Hh]ere.-:\n", ""):gsub("\n[^\n]-[Hh]ope.-$", "")
			stripped = vim.trim(stripped)
			if not M.looks_like_monologue(stripped) and stripped ~= "" then
				code = stripped
			end
		end
	end

	if not code then
		return nil
	end
	if M.looks_like_monologue(code) then
		return nil
	end
	code = code:gsub("^\n+", ""):gsub("\n+$", "")

	-- Sanity check: if original was substantial but result is tiny, probably a bad parse
	local orig_lines = #vim.split(original_text, "\n", { plain = true })
	local new_lines = #vim.split(code, "\n", { plain = true })
	if orig_lines > 5 and new_lines < orig_lines * 0.15 then
		return nil
	end

	return code
end

--- Parse multi-file output: fenced blocks tagged with filepath.
--- Format: ```typescript:src/auth.ts\n...\n```
--- Returns nil if no multi-file blocks found, otherwise { {path, code, lang}, ... }
function M.parse_multi_file_output(raw)
	return require("dwight.multifile").parse(raw)
end

--- Pre-apply syntax check: validate code compiles before writing to disk.
--- Returns (ok, error_msg). Only checks languages with fast checkers.
--- This prevents broken code from reaching disk during agent execution.
function M._pre_apply_syntax_check(code, filetype, filepath)
	if not code or code == "" then
		return true, nil
	end
	return require("dwight.languages").syntax_check(code, filetype, filepath)
end

return M
