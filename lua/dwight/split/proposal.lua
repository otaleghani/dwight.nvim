-- dwight/split/proposal.lua
-- LLM-based split proposal generation and XML parsing.

local M = {}

M.SPLIT_PROMPT = [=[
You are analyzing a code feature that has grown too large for an AI coding agent to work with
effectively. Your job is to propose how to SPLIT it into 2-4 smaller, cohesive sub-features.

## Feature: $%s
%s

## Files in this feature:
%s

## Rules
1. Each sub-feature should be COHESIVE: files that work together stay together.
2. Sub-feature names should be kebab-case: parent-subname (e.g., auth-handlers, auth-store).
3. Keep the parent name as prefix for discoverability (auth → auth-handlers, auth-middleware).
4. Every file must be assigned to exactly ONE sub-feature.
5. Aim for 2-4 sub-features. Fewer is better — only split if there's a clear logical boundary.
6. Each sub-feature should have a one-sentence description.
7. Consider these natural boundaries:
   - Data/storage layer vs business logic vs API/handler layer
   - Core types/interfaces vs implementations
   - Main functionality vs middleware/helpers
   - Tests should follow their source files (same sub-feature).

## SINGLE-FILE FEATURES
If this feature has only ONE file, you CANNOT split it using the XML format below (each file can only
go to one sub-feature). In this case, respond with ONLY this XML:

<split>
<cannot_split reason="Single file feature. Use :DwightSplitFeature --agentic to refactor the file into multiple files first." />
</split>

Do NOT explain why. Do NOT analyze the file contents. Just output the XML above.

## MULTI-FILE FEATURES
Respond in this EXACT format and NOTHING ELSE before or after — no explanation, no analysis, no preamble.
Output ONLY the <split> XML block. Any text outside the XML will cause a parse error:

<split>
<sub_feature name="PARENT-SUBNAME" description="One sentence describing this sub-feature.">
  <file path="relative/path/to/file.go" />
  <file path="relative/path/to/file_test.go" />
</sub_feature>
<sub_feature name="PARENT-SUBNAME2" description="One sentence describing this sub-feature.">
  <file path="relative/path/to/other.go" />
</sub_feature>
</split>
]=]

--- Generate a split proposal via LLM.
--- callback(proposal, err) where proposal = { sub_features = { { name, description, files } } }
function M._propose_split(name, callback)
	local analysis_mod = require("dwight.split.analysis")
	local analysis = analysis_mod.analyze_feature(name)
	if not analysis then
		callback(nil, "Feature '" .. name .. "' not found")
		return
	end

	-- Single-file features cannot be split by pragma reassignment
	if analysis.file_count <= 1 then
		callback(
			nil,
			string.format(
				"$%s has only %d file — cannot split by file assignment.\n"
					.. "Use :DwightSplitFeature %s --agentic to refactor the file into multiple files first.",
				name,
				analysis.file_count,
				name
			)
		)
		return
	end

	-- Build file context for the LLM
	local file_parts = {}
	for _, file in ipairs(analysis.files) do
		local entry = string.format("### %s (%d lines, %d symbols)", file.path, file.lines, file.symbols)
		if file.signatures and file.signatures ~= "" then
			entry = entry .. "\nSignatures:\n" .. file.signatures
		end
		if #file.dependencies > 0 then
			local deps = {}
			for _, d in ipairs(file.dependencies) do
				deps[#deps + 1] = "  " .. d
			end
			entry = entry .. "\nImports:\n" .. table.concat(deps, "\n")
		end
		file_parts[#file_parts + 1] = entry
	end

	local desc = analysis.description
			and string.format(
				"Description: %s\n%d files, %d lines, %d symbols",
				analysis.description,
				analysis.file_count,
				analysis.total_lines,
				analysis.symbol_count
			)
		or string.format(
			"%d files, %d lines, %d symbols",
			analysis.file_count,
			analysis.total_lines,
			analysis.symbol_count
		)

	local prompt = string.format(M.SPLIT_PROMPT, name, desc, table.concat(file_parts, "\n\n"))

	local log = require("dwight.log")
	local job_id = log._next_id()
	log.start(
		job_id,
		"split:propose",
		vim.api.nvim_get_current_buf(),
		0,
		0,
		"DwightSplit for $" .. name .. "\n\n" .. prompt:sub(1, 4000)
	)

	require("dwight.skills")._run_llm(prompt, function(raw, code)
		if code ~= 0 or not raw or vim.trim(raw) == "" then
			log.finish(job_id, "error", raw or "", nil, "LLM proposal failed")
			callback(nil, "LLM proposal failed (exit " .. tostring(code) .. ")")
			return
		end

		-- Parse the <split> XML
		local proposal, parse_reason = M._parse_proposal(raw, name)
		if not proposal then
			local reason = parse_reason or "Failed to parse split proposal"
			log.finish(job_id, "parse_fail", raw, nil, reason)
			if parse_reason then
				-- cannot_split or other structured reason
				callback(nil, reason)
			else
				callback(nil, "Failed to parse split proposal. Raw:\n" .. (raw or ""):sub(1, 500))
			end
			return
		end

		-- Validate: every original file must be assigned
		local assigned = {}
		for _, sf in ipairs(proposal.sub_features) do
			for _, fp in ipairs(sf.files) do
				assigned[fp] = sf.name
			end
		end

		local missing = {}
		for _, file in ipairs(analysis.files) do
			if not assigned[file.path] then
				missing[#missing + 1] = file.path
			end
		end

		if #missing > 0 then
			log.finish(job_id, "error", raw, nil, "Proposal missing files: " .. table.concat(missing, ", "))
			callback(nil, "Proposal missing files: " .. table.concat(missing, ", "))
			return
		end

		log.finish(
			job_id,
			"success",
			raw,
			string.format("Split $%s into %d sub-features", name, #proposal.sub_features),
			nil
		)
		proposal.analysis = analysis
		callback(proposal, nil)
	end)
end

--- Parse the LLM's <split> response.
function M._parse_proposal(raw, parent_name)
	if not raw or not raw:find("<split>") then
		return nil
	end

	-- Check for <cannot_split> response
	if raw:find("<cannot_split") then
		local reason = raw:match('<cannot_split%s+reason="([^"]*)"') or "Feature cannot be split"
		return nil, reason
	end

	-- Find ALL <split>...</split> blocks (LLM may output multiple attempts)
	local best_result = nil
	for split_block in raw:gmatch("<split>(.-)</split>") do
		local sub_features = {}
		for attrs, body in split_block:gmatch("<sub_feature%s+(.-)>(.-)</sub_feature>") do
			local sf_name = attrs:match('name="([^"]+)"')
			local desc = attrs:match('description="([^"]*)"')

			if sf_name then
				local files = {}
				for file_path in body:gmatch('<file%s+path="([^"]+)"') do
					files[#files + 1] = vim.trim(file_path)
				end

				sub_features[#sub_features + 1] = {
					name = sf_name,
					description = desc or "",
					files = files,
				}
			end
		end

		-- Keep the block with the most sub-features (>=2)
		if #sub_features >= 2 then
			if not best_result or #sub_features > #best_result then
				best_result = sub_features
			end
		end
	end

	if not best_result then
		return nil
	end

	return {
		parent = parent_name,
		sub_features = best_result,
	}
end

return M
