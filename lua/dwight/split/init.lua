-- dwight/split/init.lua
-- Split a large feature into smaller sub-features.
-- When a feature grows too big (too many files, too many symbols), the LLM
-- struggles to work with it. This module analyzes a feature and proposes a
-- logical split into 2-4 sub-features, then rewrites the @feature pragmas.
--
-- :DwightSplitFeature [name]   — analyze + propose + confirm + apply
-- :DwightSplitPreview [name]   — analyze + propose (preview only, no changes)

local M = {}

local api = vim.api
local _flatten = require("dwight.util").flatten_lines

--------------------------------------------------------------------
-- Re-exports from sub-modules
--------------------------------------------------------------------

--- Check if a feature should be split.
--- Returns true + reason if it's too big, false + nil if it's fine.
function M.should_split(name)
	local analysis_mod = require("dwight.split.analysis")
	return analysis_mod.should_split(name)
end

--- Generate a split proposal via LLM.
--- callback(proposal, err) where proposal = { sub_features = { { name, description, files } } }
function M._propose_split(name, callback)
	local proposal_mod = require("dwight.split.proposal")
	return proposal_mod._propose_split(name, callback)
end

--- Parse the LLM's <split> response.
function M._parse_proposal(raw, parent_name)
	local proposal_mod = require("dwight.split.proposal")
	return proposal_mod._parse_proposal(raw, parent_name)
end

--- Apply a split proposal: replace @feature:parent with @feature:sub in each file.
--- Returns the number of files modified.
function M._apply_split(proposal)
	local apply_mod = require("dwight.split.apply")
	return apply_mod._apply_split(proposal)
end

--- Run agentic split: reads code, identifies boundaries, applies changes.
function M.split_agentic(name)
	local agentic_mod = require("dwight.split.agentic")
	return agentic_mod.split_agentic(name)
end

--------------------------------------------------------------------
-- Orchestrators: split, preview, audit, audit_interactive
--------------------------------------------------------------------

--- Split a feature interactively: analyze -> propose -> preview -> confirm -> apply.
function M.split(name)
	local analysis_mod = require("dwight.split.analysis")
	local preview_mod = require("dwight.split.preview")

	if not name or name == "" then
		-- Pick from available features
		local features = require("dwight.features")
		local names = features.names()
		if #names == 0 then
			vim.notify("[dwight] No features found. Add // @feature:name pragmas first.", vim.log.levels.WARN)
			return
		end

		-- Build feature data for picker
		local picker_items = {}
		for _, n in ipairs(names) do
			local a = analysis_mod.analyze_feature(n)
			if a then
				local should, reason = analysis_mod.should_split(n)
				picker_items[#picker_items + 1] = {
					name = n,
					analysis = a,
					should_split = should,
					reason = reason,
				}
			end
		end

		-- Sort: features needing split first
		table.sort(picker_items, function(a, b)
			if a.should_split and not b.should_split then
				return true
			end
			if not a.should_split and b.should_split then
				return false
			end
			return a.analysis.total_lines > b.analysis.total_lines
		end)

		local has_tel, pickers = pcall(require, "telescope.pickers")
		if has_tel then
			local finders = require("telescope.finders")
			local conf = require("telescope.config").values
			local actions = require("telescope.actions")
			local action_state = require("telescope.actions.state")
			local previewers = require("telescope.previewers")

			pickers
				.new({}, {
					prompt_title = "🔀 Split Feature",
					finder = finders.new_table({
						results = picker_items,
						entry_maker = function(item)
							local marker = item.should_split and "⚠️ " or "  "
							local reason_str = item.reason and (" — " .. item.reason) or ""
							return {
								value = item,
								display = string.format(
									"%s$%s (%d files, %d lines)%s",
									marker,
									item.name,
									item.analysis.file_count,
									item.analysis.total_lines,
									reason_str
								),
								ordinal = item.name,
							}
						end,
					}),
					sorter = conf.generic_sorter({}),
					previewer = previewers.new_buffer_previewer({
						title = "Feature Details",
						define_preview = function(self, entry)
							local a = entry.value.analysis
							local lines = {
								"Feature: $" .. a.name,
								string.format(
									"Files: %d | Lines: %d | Symbols: %d",
									a.file_count,
									a.total_lines,
									a.symbol_count
								),
								a.description and ("Description: " .. a.description) or "",
								"",
								"── Files ──",
							}
							for _, f in ipairs(a.files) do
								lines[#lines + 1] =
									string.format("  %s (%d lines, %d symbols)", f.path, f.lines, f.symbols)
								if f.signatures and f.signatures ~= "" then
									for sig_line in f.signatures:gmatch("[^\n]+") do
										lines[#lines + 1] = "    " .. sig_line:sub(1, 90)
									end
								end
							end
							if entry.value.should_split then
								lines[#lines + 1] = ""
								lines[#lines + 1] = "⚠️  " .. entry.value.reason
							end
							if a.file_count <= 1 then
								lines[#lines + 1] = ""
								lines[#lines + 1] =
									"⚠️  Single-file feature: use --agentic mode to refactor into multiple files first."
							end
							api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, _flatten(lines))
						end,
					}),
					attach_mappings = function(pb)
						actions.select_default:replace(function()
							local entry = action_state.get_selected_entry()
							actions.close(pb)
							if entry then
								M.split(entry.value.name)
							end
						end)
						return true
					end,
				})
				:find()
		else
			-- Fallback: dwight.select
			local items = {}
			for _, item in ipairs(picker_items) do
				local marker = item.should_split and "⚠️ " or ""
				items[#items + 1] = string.format(
					"%s$%s (%d files, %d lines)",
					marker,
					item.name,
					item.analysis.file_count,
					item.analysis.total_lines
				)
			end
			require("dwight.select").pick(items, {
				prompt = "Split which feature?",
			}, function(_, idx)
				if idx then
					M.split(picker_items[idx].name)
				end
			end)
		end
		return
	end

	-- Validate the feature exists
	local analysis = analysis_mod.analyze_feature(name)
	if not analysis then
		vim.notify("[dwight] Feature '$" .. name .. "' not found.", vim.log.levels.WARN)
		return
	end

	vim.notify(
		string.format(
			"[dwight] Analyzing $%s (%d files, %d lines, %d symbols)...",
			name,
			analysis.file_count,
			analysis.total_lines,
			analysis.symbol_count
		),
		vim.log.levels.INFO
	)

	-- Single-file features can't be split by pragma reassignment — need file-level refactoring
	if analysis.file_count == 1 then
		local file = analysis.files[1]
		vim.notify(
			string.format(
				"[dwight] $%s has only 1 file (%s, %d lines).\n"
					.. "Pragma-based splitting requires multiple files.\n"
					.. "Use :DwightSplitFeature %s --agentic to refactor the file into multiple files first.",
				name,
				file.path,
				file.lines,
				name
			),
			vim.log.levels.WARN
		)
		return
	end

	-- Generate proposal
	M._propose_split(name, function(proposal, err)
		if err then
			vim.notify("[dwight] Split failed: " .. err, vim.log.levels.ERROR)
			return
		end

		-- Show preview with confirm/cancel
		preview_mod.show_proposal_buffer(
			proposal,
			-- On confirm
			function()
				local count = M._apply_split(proposal)
				vim.notify(
					string.format(
						"[dwight] ✅ Split $%s into %d sub-features (%d files modified).\n"
							.. "New features: %s\n"
							.. "Use :DwightFeatures to verify. Undo with git checkout or per-file undo.",
						name,
						#proposal.sub_features,
						count,
						table.concat(
							vim.tbl_map(function(sf)
								return "$" .. sf.name
							end, proposal.sub_features),
							", "
						)
					),
					vim.log.levels.INFO
				)
			end,
			-- On cancel
			function()
				vim.notify("[dwight] Split cancelled.", vim.log.levels.INFO)
			end
		)
	end)
end

--- Preview-only: show what a split would look like without applying.
function M.preview(name)
	local analysis_mod = require("dwight.split.analysis")
	local preview_mod = require("dwight.split.preview")

	if not name or name == "" then
		local features = require("dwight.features")
		local names = features.names()
		local picker_items = {}
		for _, n in ipairs(names) do
			local a = analysis_mod.analyze_feature(n)
			if a then
				local should, reason = analysis_mod.should_split(n)
				picker_items[#picker_items + 1] = { name = n, analysis = a, should_split = should, reason = reason }
			end
		end

		local has_tel, pickers = pcall(require, "telescope.pickers")
		if has_tel then
			local finders = require("telescope.finders")
			local conf = require("telescope.config").values
			local actions = require("telescope.actions")
			local action_state = require("telescope.actions.state")

			pickers
				.new({}, {
					prompt_title = "🔍 Preview Split",
					finder = finders.new_table({
						results = picker_items,
						entry_maker = function(item)
							local marker = item.should_split and "⚠️ " or "  "
							return {
								value = item,
								display = string.format(
									"%s$%s (%d files, %d lines)",
									marker,
									item.name,
									item.analysis.file_count,
									item.analysis.total_lines
								),
								ordinal = item.name,
							}
						end,
					}),
					sorter = conf.generic_sorter({}),
					attach_mappings = function(pb)
						actions.select_default:replace(function()
							local entry = action_state.get_selected_entry()
							actions.close(pb)
							if entry then
								M.preview(entry.value.name)
							end
						end)
						return true
					end,
				})
				:find()
		else
			local items = {}
			for _, item in ipairs(picker_items) do
				items[#items + 1] = string.format(
					"$%s (%d files, %d lines)",
					item.name,
					item.analysis.file_count,
					item.analysis.total_lines
				)
			end
			require("dwight.select").pick(items, {
				prompt = "Preview split for which feature?",
			}, function(_, idx)
				if idx then
					M.preview(picker_items[idx].name)
				end
			end)
		end
		return
	end

	vim.notify("[dwight] Generating split preview for $" .. name .. "...", vim.log.levels.INFO)

	-- Single-file features can't be split meaningfully
	local analysis = analysis_mod.analyze_feature(name)
	if analysis and analysis.file_count == 1 then
		vim.notify(
			string.format(
				"[dwight] $%s has only 1 file — pragma-based split not possible.\n"
					.. "Use :DwightSplitFeature %s --agentic to refactor into multiple files.",
				name,
				name
			),
			vim.log.levels.WARN
		)
		return
	end

	M._propose_split(name, function(proposal, err)
		if err then
			vim.notify("[dwight] Preview failed: " .. err, vim.log.levels.ERROR)
			return
		end

		-- Show in a buffer (no confirm action)
		preview_mod.show_proposal_buffer(proposal, nil, nil)
	end)
end

--- Check all features and report which ones might need splitting.
--- Returns list of { name, reason, analysis }
function M.audit()
	local analysis_mod = require("dwight.split.analysis")
	local features = require("dwight.features")
	local names = features.names()
	local results = {}

	for _, name in ipairs(names) do
		local should, reason = analysis_mod.should_split(name)
		if should then
			results[#results + 1] = {
				name = name,
				reason = reason,
				analysis = analysis_mod.analyze_feature(name),
			}
		end
	end

	return results
end

--- Interactive audit: show which features need splitting.
function M.audit_interactive()
	local results = M.audit()

	if #results == 0 then
		vim.notify("[dwight] All features are within size limits. No splits needed.", vim.log.levels.INFO)
		return
	end

	local parts = { "⚠️ Features that may benefit from splitting:\n" }
	for _, r in ipairs(results) do
		local a = r.analysis
		parts[#parts + 1] = string.format(
			"  $%s — %s (%d files, %d lines, %d symbols)",
			r.name,
			r.reason,
			a.file_count,
			a.total_lines,
			a.symbol_count
		)
	end
	parts[#parts + 1] = "\nRun :DwightSplitFeature <name> to split."

	vim.notify(table.concat(parts, "\n"), vim.log.levels.WARN)
end

return M
