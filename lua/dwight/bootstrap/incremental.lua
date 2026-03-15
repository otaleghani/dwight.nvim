-- dwight/bootstrap/incremental.lua
-- Incremental bootstrap: only tag untagged files.

local M = {}

local api = vim.api

local INCREMENTAL_PROMPT = [=[
You are adding dwight pragma comments to UNTAGGED files in a project that already has partial coverage.

## Existing features in the project
%s

## Files that ALREADY have pragmas (DO NOT touch these)
%s

## Files that NEED pragmas (YOUR TARGETS)
%s

## Entry file previews (for context)
%s

Suggest pragma comments ONLY for the untagged files listed above.
For each file, output in this EXACT format:

<changes>
<file path="src/utils/helper.go" action="edit" lines="1-1">
// Shared utility functions for string and error handling. @feature:utils
(original line 1 content here)
</file>
</changes>

RULES:
- ONLY tag files from the "NEED pragmas" list. Do NOT touch already-tagged files.
- Assign each file to an EXISTING feature if it fits, or create a NEW feature if needed.
- Use the same comment style and naming conventions as existing pragmas.
- If a file doesn't clearly belong to any feature, use a general one like @feature:core or @feature:utils.
- Descriptions should be ONE concise sentence.
- Do NOT add @project/@stack/@constraint/@convention -- those already exist.
]=]

M.INCREMENTAL_PROMPT = INCREMENTAL_PROMPT

--- Quick incremental bootstrap (single-shot LLM).
function M._run_bootstrap_incremental()
	local coverage_mod = require("dwight.bootstrap.coverage")
	local cov = coverage_mod.coverage()
	if cov.untagged_files == 0 then
		vim.notify("[dwight] All files already tagged!", vim.log.levels.INFO)
		return
	end

	vim.notify(
		string.format("[dwight] Incremental bootstrap: %d untagged files to tag...", cov.untagged_files),
		vim.log.levels.INFO
	)

	-- Build context from existing coverage
	local features_str = #cov.features > 0 and table.concat(cov.features, ", ") or "(none)"
	local tagged_str = table.concat(cov.tagged, "\n")
	if #tagged_str > 2000 then
		tagged_str = tagged_str:sub(1, 2000) .. "\n... (truncated)"
	end
	local untagged_str = table.concat(cov.untagged, "\n")
	if #untagged_str > 3000 then
		untagged_str = untagged_str:sub(1, 3000) .. "\n... (truncated)"
	end

	-- Read first lines of a few untagged files for context
	local cwd = vim.fn.getcwd()
	local snippets = {}
	for i, rel in ipairs(cov.untagged) do
		if i > 10 then
			break
		end -- cap at 10 snippets
		local f = io.open(cwd .. "/" .. rel, "r")
		if f then
			local lines = {}
			for j = 1, 15 do
				local line = f:read("*l")
				if not line then
					break
				end
				lines[#lines + 1] = line
			end
			f:close()
			if #lines > 0 then
				snippets[#snippets + 1] = string.format("--- %s ---\n%s", rel, table.concat(lines, "\n"))
			end
		end
	end
	local snippets_str = #snippets > 0 and table.concat(snippets, "\n\n") or "(none)"

	local prompt = string.format(INCREMENTAL_PROMPT, features_str, tagged_str, untagged_str, snippets_str)

	local log = require("dwight.log")
	local job_id = log._next_id()
	log.start(
		job_id,
		"bootstrap-incremental",
		api.nvim_get_current_buf(),
		0,
		0,
		string.format("Incremental bootstrap: %d untagged files\n\n%s", cov.untagged_files, prompt:sub(1, 4000))
	)

	require("dwight.skills")._run_llm(prompt, function(raw, code)
		if code ~= 0 or vim.trim(raw or "") == "" then
			log.finish(job_id, "error", raw or "", nil, "LLM generation failed")
			vim.notify("[dwight] Incremental bootstrap failed.", vim.log.levels.ERROR)
			return
		end

		local multifile = require("dwight.multifile")
		local changes = multifile.parse_xml(raw)
		if not changes then
			log.finish(job_id, "parse_fail", raw or "", nil, "Could not parse suggestions")
			vim.notify("[dwight] Could not parse pragma suggestions.", vim.log.levels.ERROR)
			return
		end

		log.finish(job_id, "success", raw, string.format("%d file(s) to annotate", #changes), nil)

		local count = multifile.apply_all(changes)

		-- Show before/after coverage
		local after = coverage_mod.coverage()
		vim.notify(
			string.format(
				"[dwight] Incremental bootstrap complete!\n"
					.. "  Before: %d/%d files (%.0f%%)\n"
					.. "  After:  %d/%d files (%.0f%%)\n"
					.. "  Tagged: %d new file(s), %d feature(s)\n"
					.. "Use :DwightMultiUndo to revert, or :DwightBootstrap --incremental to tag more.",
				cov.tagged_files,
				cov.total_files,
				cov.coverage_pct,
				after.tagged_files,
				after.total_files,
				after.coverage_pct,
				count,
				#after.features
			),
			vim.log.levels.INFO
		)
	end)
end

--- Agentic incremental bootstrap.
function M._run_bootstrap_incremental_agentic()
	local coverage_mod = require("dwight.bootstrap.coverage")
	local cov = coverage_mod.coverage()
	if cov.untagged_files == 0 then
		vim.notify("[dwight] All files already tagged!", vim.log.levels.INFO)
		return
	end

	local before_tagged = cov.tagged_files
	local before_total = cov.total_files
	local before_pct = cov.coverage_pct

	vim.notify(
		string.format("[dwight] Incremental agentic bootstrap: %d untagged files to tag...", cov.untagged_files),
		vim.log.levels.INFO
	)

	-- Build the untagged file list for the agent
	local untagged_str = table.concat(cov.untagged, "\n")
	if #untagged_str > 8000 then
		untagged_str = untagged_str:sub(1, 8000) .. "\n... (truncated)"
	end

	local features_str = #cov.features > 0 and table.concat(cov.features, ", ") or "(none)"

	local agentic_mod = require("dwight.bootstrap.agentic")
	local prompt = agentic_mod.AGENTIC_BOOTSTRAP_PROMPT
		.. string.format(
			[=[

## INCREMENTAL MODE -- IMPORTANT

This project ALREADY has partial pragma coverage. Your job is to tag ONLY the untagged files.

Current coverage: %d/%d files (%.0f%%)
Existing features: %s

### Files that ALREADY have pragmas (DO NOT modify)
There are %d files that already have pragmas. Do NOT touch them.

### Files that NEED pragmas (YOUR TARGETS -- tag ALL of these)
```
%s
```

CRITICAL RULES for incremental mode:
- Do NOT touch files that already have pragmas -- you'll create duplicates.
- Assign files to EXISTING features when they fit.
- Create new features only when files don't fit any existing feature.
- Use the same comment style and naming conventions as existing pragmas.
- Do NOT re-add @project/@stack/@constraint/@convention -- they already exist.
- Only add @feature:name pragmas to the untagged files.
- Read a few already-tagged files first to understand the existing naming pattern.
- Target: tag ALL %d untagged files.

Start by reading 2-3 already-tagged files to see the existing pragma style, then systematically tag the untagged files.
]=],
			cov.tagged_files,
			cov.total_files,
			cov.coverage_pct,
			features_str,
			cov.tagged_files,
			untagged_str,
			cov.untagged_files
		)

	local agent = require("dwight.agent")
	agent.run(prompt, {
		plan = false, -- skip planning, the prompt IS the plan
		on_complete = function(success)
			vim.schedule(function()
				if success then
					local after = coverage_mod.coverage()
					local new_tagged = after.tagged_files - before_tagged
					vim.notify(
						string.format(
							"[dwight] Incremental bootstrap complete!\n"
								.. "  Before: %d/%d files (%.0f%%)\n"
								.. "  After:  %d/%d files (%.0f%%)\n"
								.. "  Tagged: +%d file(s), %d feature(s)\n"
								.. "  %s\n"
								.. "Run :DwightFeatures to explore, :DwightBootstrap --incremental to tag more.",
							before_tagged,
							before_total,
							before_pct,
							after.tagged_files,
							after.total_files,
							after.coverage_pct,
							new_tagged,
							#after.features,
							after.untagged_files == 0 and "Full coverage achieved!"
								or string.format("%d files still untagged", after.untagged_files)
						),
						vim.log.levels.INFO
					)
				else
					vim.notify(
						"[dwight] Incremental bootstrap had errors. Check :DwightAgentStatus.",
						vim.log.levels.WARN
					)
				end
			end)
		end,
	})
end

return M
