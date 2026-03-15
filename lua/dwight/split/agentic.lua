-- dwight/split/agentic.lua
-- Agentic split: reads code, identifies boundaries, applies split via agent.

local M = {}

--- Build the agentic split prompt.
function M.build_agentic_split_prompt(name, analysis)
	-- Build file list with paths
	local file_list = {}
	for _, f in ipairs(analysis.files) do
		file_list[#file_list + 1] = string.format("  %s (%d lines, %d symbols)", f.path, f.lines, f.symbols)
	end

	return string.format(
		[=[
You are splitting a large code feature into smaller, cohesive sub-features.

## Feature: $%s
%s
Files: %d | Lines: %d | Symbols: %d

### Files
%s

## Your Task — IN ORDER

### Step 1: Read ALL source files
Read every file in this feature completely. Understand:
- What each file does (its responsibility)
- Import/dependency relationships between files
- Shared types, interfaces, constants used across files
- Call patterns: which files call functions in which other files
- Test files and which source files they test

### Step 2: Identify natural split boundaries
Look for these patterns to find cohesive groups:
- **Layer boundaries**: data/storage vs business logic vs handlers/routes
- **Domain boundaries**: files dealing with the same domain concept
- **Dependency clusters**: files that import each other heavily should stay together
- **Type ownership**: files defining types and files consuming them
- **Test co-location**: test files must stay with their source files

### Step 3: Propose the split
Decide on 2-4 sub-features. Each should be:
- **Cohesive**: files within a sub-feature are tightly coupled
- **Loosely coupled**: minimal dependencies between sub-features
- **Named clearly**: use prefix "%s-" (e.g., %s-handlers, %s-store, %s-types)
- **Balanced**: avoid one huge group and several tiny ones

### Step 4: Apply the split
For EACH file, edit the pragma comment at the top:
- Replace `@feature:%s` with `@feature:{new-sub-feature-name}`
- Add or update the description to reflect the sub-feature's purpose
- Keep the same comment syntax (// for Go/JS, # for Python, -- for Lua)
- Do NOT change any actual code — only modify the pragma comment line

Example: Change `// JWT auth handlers. @feature:%s` to `// JWT auth request handlers. @feature:%s-handlers`

### Step 5: Verify integrity
After applying all changes:
1. List all sub-features you created with their file counts
2. Verify every original file got assigned (no orphans)
3. Verify no file has the old `@feature:%s` pragma anymore
4. Read 2-3 modified files to confirm the pragmas are correct

Write a summary to stdout showing:
- Sub-features created (name, description, file count)
- Files per sub-feature
- Any issues found during verification

## Rules
- Every file MUST be assigned to exactly ONE sub-feature
- Sub-feature names: lowercase, kebab-case, prefixed with "%s-"
- Do NOT create more than 4 sub-features
- Do NOT modify any actual code — only pragma comment lines
- Test files go with their corresponding source files
- If a file is genuinely shared infrastructure, put it in a "-core" or "-types" sub-feature
]=],
		name,
		analysis.description or "(no description)",
		analysis.file_count,
		analysis.total_lines,
		analysis.symbol_count,
		table.concat(file_list, "\n"),
		name,
		name,
		name,
		name,
		name,
		name,
		name .. "-handlers",
		name,
		name
	)
end

--- Run agentic split: reads code, identifies boundaries, applies changes.
function M.split_agentic(name)
	if not name or name == "" then
		-- Pick from features that need splitting
		local features = require("dwight.features")
		local names = features.names()
		if #names == 0 then
			vim.notify("[dwight] No features found.", vim.log.levels.WARN)
			return
		end

		local analysis_mod = require("dwight.split.analysis")
		local items = {}
		for _, n in ipairs(names) do
			local a = analysis_mod.analyze_feature(n)
			if a then
				local should, reason = analysis_mod.should_split(n)
				local marker = should and " ⚠️ " .. reason or ""
				items[#items + 1] = string.format("$%s (%d files, %d lines)%s", n, a.file_count, a.total_lines, marker)
			end
		end

		require("dwight.select").pick(items, {
			prompt = "Agentic split which feature?",
		}, function(choice)
			if choice then
				local name_match = choice:match("^%$([%w_%-]+)")
				if name_match then
					M.split_agentic(name_match)
				end
			end
		end)
		return
	end

	local analysis_mod = require("dwight.split.analysis")
	local analysis = analysis_mod.analyze_feature(name)
	if not analysis then
		vim.notify("[dwight] Feature '$" .. name .. "' not found.", vim.log.levels.WARN)
		return
	end

	vim.notify(
		string.format(
			"[dwight] 🤖 Agentic split: $%s (%d files, %d lines, %d symbols)",
			name,
			analysis.file_count,
			analysis.total_lines,
			analysis.symbol_count
		),
		vim.log.levels.INFO
	)

	local prompt = M.build_agentic_split_prompt(name, analysis)

	local before_features = require("dwight.features").names()

	local agent = require("dwight.agent")
	agent.run(prompt, {
		on_complete = function(success)
			vim.schedule(function()
				if success then
					-- Rebuild feature index and show results
					local features = require("dwight.features")

					-- Force re-scan by clearing any cache
					pcall(function()
						features._clear_cache()
					end)

					local after_features = features.names()

					-- Find new sub-features (those starting with name-)
					local new_subs = {}
					local before_set = {}
					for _, n in ipairs(before_features) do
						before_set[n] = true
					end
					for _, n in ipairs(after_features) do
						if not before_set[n] and n:match("^" .. vim.pesc(name) .. "%-") then
							new_subs[#new_subs + 1] = n
						end
					end

					-- Check if old feature still exists
					local old_exists = false
					for _, n in ipairs(after_features) do
						if n == name then
							old_exists = true
							break
						end
					end

					if #new_subs > 0 then
						-- Build summary
						local sub_info = {}
						for _, sn in ipairs(new_subs) do
							local feat = features.build_feature(sn)
							local fc = feat and feat.files and #feat.files or 0
							sub_info[#sub_info + 1] = string.format("  $%s (%d files)", sn, fc)
						end

						local msg = string.format(
							"[dwight] 🤖 Split complete! $%s → %d sub-features:\n%s",
							name,
							#new_subs,
							table.concat(sub_info, "\n")
						)

						if old_exists then
							msg = msg
								.. string.format(
									"\n\n  ⚠️  $%s still has files — agent may not have split everything.\n"
										.. "  Run :DwightSplitFeature %s --agentic to finish.",
									name,
									name
								)
						end

						msg = msg .. "\n\nRun :DwightFeatures to explore. Undo with git checkout."
						vim.notify(msg, vim.log.levels.INFO)
					else
						vim.notify(
							"[dwight] 🤖 Agentic split completed but no new sub-features detected.\n"
								.. "Check :DwightAgentStatus for details. The agent may have encountered issues.",
							vim.log.levels.WARN
						)
					end
				else
					vim.notify(
						"[dwight] 🤖 Agentic split had errors. Check :DwightAgentStatus for details.",
						vim.log.levels.WARN
					)
				end
			end)
		end,
	})
end

return M
