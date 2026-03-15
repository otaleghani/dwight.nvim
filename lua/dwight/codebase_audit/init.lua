-- dwight/codebase_audit/init.lua
-- DwightAudit: deep codebase analysis per feature.
-- Phase 1: static analysis (treesitter + regex). Zero LLM calls.
-- Phase 2: targeted LLM review on flagged items only.
-- Output: ranked report buffer with actionable keybindings.
--
-- Re-exports the exact same public API as the original monolithic module.

local M = {}

--------------------------------------------------------------------
-- Re-exported functions (delegated to sub-modules)
--------------------------------------------------------------------

function M._static_analysis(feature_files)
	local static = require("dwight.codebase_audit.static")
	return static._static_analysis(feature_files)
end

function M._agentic_review(feature_name, feature_files, static_result, callback)
	local agentic_mod = require("dwight.codebase_audit.agentic")
	return agentic_mod._agentic_review(feature_name, feature_files, static_result, callback)
end

function M._build_report_lines(feature_name, result)
	local report = require("dwight.codebase_audit.report")
	return report._build_report_lines(feature_name, result)
end

function M._show_report(feature_name, result)
	local report = require("dwight.codebase_audit.report")
	return report._show_report(feature_name, result)
end

function M._save_audit(feature_name, result)
	local persistence = require("dwight.codebase_audit.persistence")
	return persistence._save_audit(feature_name, result)
end

function M._load_audit(feature_name)
	local persistence = require("dwight.codebase_audit.persistence")
	return persistence._load_audit(feature_name)
end

--------------------------------------------------------------------
-- Main entry: :DwightAudit [feature-name]
--------------------------------------------------------------------

--- Run audit on a feature. Options:
---   agentic = true   -> run Phase 2 agentic deep review after static analysis
function M.audit(feature_name, opts)
	opts = opts or {}
	local features = require("dwight.features")

	-- If no feature name, let user pick
	if not feature_name or feature_name == "" then
		local names = features.names()
		if #names == 0 then
			vim.notify(
				"[dwight] No features found. Tag your code with @feature:name pragmas first.",
				vim.log.levels.WARN
			)
			return
		end

		require("dwight.select").pick(names, { prompt = "Audit which feature?" }, function(choice)
			if choice then
				M.audit(choice, opts)
			end
		end)
		return
	end

	-- Build feature (gets file list)
	local feature = features.build_feature(feature_name)
	if not feature then
		vim.notify(string.format("[dwight] Feature '%s' not found.", feature_name), vim.log.levels.ERROR)
		return
	end

	vim.notify(
		string.format("[dwight] 🔍 Auditing $%s (%d files)…", feature_name, #feature.files),
		vim.log.levels.INFO
	)

	-- Phase 1: Static analysis (always runs — fast, free)
	local result = M._static_analysis(feature.files)

	vim.notify(
		string.format(
			"[dwight] 🔍 Static analysis: %d findings across %d files, %d functions.",
			#result.findings,
			result.stats.files,
			result.stats.functions
		),
		vim.log.levels.INFO
	)

	-- Phase 2: Agentic deep review (optional)
	if opts.agentic then
		vim.notify(
			string.format("[dwight] 🤖 Starting agentic deep review on $%s…", feature_name),
			vim.log.levels.INFO
		)

		M._agentic_review(feature_name, feature.files, result, function(merged_result)
			M._save_audit(feature_name, merged_result)
			M._show_report(feature_name, merged_result)
		end)
		return -- async path
	end

	-- Sync path (static only)
	M._save_audit(feature_name, result)
	M._show_report(feature_name, result)
end

return M
