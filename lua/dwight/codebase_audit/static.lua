-- dwight/codebase_audit/static.lua
-- Phase 1: Full static analysis orchestration for a feature.

local M = {}

--- Run all static checks on a set of files.
--- Returns { findings = {...}, stats = {...} }
function M._static_analysis(feature_files)
	local constants = require("dwight.codebase_audit.constants")
	local checks = require("dwight.codebase_audit.checks")
	local SEV = constants.SEV

	local all_findings = {}
	local stats = {
		files = 0,
		functions = 0,
		long_functions = 0,
		deep_functions = 0,
		many_params = 0,
		secrets = 0,
		error_issues = 0,
		no_tests = 0,
		duplication = 0,
	}

	local files_with_lines = {}

	for _, file_info in ipairs(feature_files) do
		local filepath = file_info.path
		local lines = checks.read_lines(filepath)
		if lines then
			stats.files = stats.files + 1
			files_with_lines[filepath] = lines
			local lang = constants.detect_lang(filepath)

			-- 1. Function analysis (treesitter)
			local funcs = checks.analyze_functions_ts(filepath)
			for _, fn in ipairs(funcs) do
				stats.functions = stats.functions + 1

				if fn.line_count > constants.MAX_FUNCTION_LINES then
					stats.long_functions = stats.long_functions + 1
					all_findings[#all_findings + 1] = {
						severity = SEV.WARN,
						category = "complexity",
						file = filepath,
						line = fn.start_line,
						message = string.format(
							"function '%s' is %d lines (max %d)",
							fn.name,
							fn.line_count,
							constants.MAX_FUNCTION_LINES
						),
						snippet = fn.name,
					}
				end

				if fn.max_nesting > constants.MAX_NESTING_DEPTH then
					stats.deep_functions = stats.deep_functions + 1
					all_findings[#all_findings + 1] = {
						severity = SEV.WARN,
						category = "complexity",
						file = filepath,
						line = fn.start_line,
						message = string.format(
							"function '%s' has nesting depth %d (max %d)",
							fn.name,
							fn.max_nesting,
							constants.MAX_NESTING_DEPTH
						),
						snippet = fn.name,
					}
				end

				if fn.param_count > constants.MAX_PARAMS then
					stats.many_params = stats.many_params + 1
					all_findings[#all_findings + 1] = {
						severity = SEV.INFO,
						category = "clean-code",
						file = filepath,
						line = fn.start_line,
						message = string.format(
							"function '%s' has %d parameters (max %d)",
							fn.name,
							fn.param_count,
							constants.MAX_PARAMS
						),
						snippet = fn.name,
					}
				end
			end

			-- 2. Hardcoded secrets
			local secrets = checks.check_secrets(filepath, lines)
			stats.secrets = stats.secrets + #secrets
			for _, s in ipairs(secrets) do
				all_findings[#all_findings + 1] = s
			end

			-- 3. Swallowed errors
			local errors = checks.check_errors(filepath, lines, lang)
			stats.error_issues = stats.error_issues + #errors
			for _, e in ipairs(errors) do
				all_findings[#all_findings + 1] = e
			end

			-- 4. Test coverage
			-- Skip test files themselves
			if
				not filepath:match("_test%.")
				and not filepath:match("%.test%.")
				and not filepath:match("%.spec%.")
				and not filepath:match("test_")
				and not filepath:match("__tests__/")
			then
				local missing = checks.check_test_coverage(filepath)
				if missing then
					stats.no_tests = stats.no_tests + 1
					all_findings[#all_findings + 1] = missing
				end
			end
		end
	end

	-- 5. Cross-file duplication
	local dupes = checks.check_duplication(files_with_lines)
	stats.duplication = #dupes
	for _, d in ipairs(dupes) do
		all_findings[#all_findings + 1] = d
	end

	-- Sort by severity then file then line
	table.sort(all_findings, function(a, b)
		if a.severity.sort ~= b.severity.sort then
			return a.severity.sort < b.severity.sort
		end
		if a.file ~= b.file then
			return a.file < b.file
		end
		return a.line < b.line
	end)

	return { findings = all_findings, stats = stats }
end

return M
