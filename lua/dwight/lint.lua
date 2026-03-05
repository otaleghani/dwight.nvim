-- dwight/lint.lua
-- LLM-powered linter: /lint sends code to AI, parses issues,
-- and injects them as vim.diagnostic entries in the gutter.
-- Issues can then be fixed with /fix or <leader>af.

local M = {}

local ns = vim.api.nvim_create_namespace("dwight_lint")

--------------------------------------------------------------------
-- Parse lint output: AI returns [WARN:L12] or [ERROR:L5] comments
--------------------------------------------------------------------

local SEVERITY_MAP = {
	error = vim.diagnostic.severity.ERROR,
	warn = vim.diagnostic.severity.WARN,
	style = vim.diagnostic.severity.HINT,
	info = vim.diagnostic.severity.INFO,
}

--- Parse AI lint output into diagnostics.
--- Expected format: // [WARN:L12] Message here
function M.parse_diagnostics(raw, start_line_offset)
	start_line_offset = (start_line_offset or 1) - 1
	local diagnostics = {}

	for line in raw:gmatch("[^\n]+") do
		-- Match: [SEVERITY:LN] message  or  [SEVERITY:L:N] message
		local sev, lnum, msg = line:match("%[(%w+):L(%d+)%]%s*(.+)")
		if sev and lnum and msg then
			sev = sev:lower()
			local severity = SEVERITY_MAP[sev] or vim.diagnostic.severity.WARN
			diagnostics[#diagnostics + 1] = {
				lnum = tonumber(lnum) - 1 + start_line_offset, -- 0-indexed
				col = 0,
				severity = severity,
				source = "dwight",
				message = vim.trim(msg),
			}
		end
	end

	return diagnostics
end

--------------------------------------------------------------------
-- Apply diagnostics to buffer
--------------------------------------------------------------------

function M.set_diagnostics(bufnr, diagnostics)
	vim.diagnostic.set(ns, bufnr, diagnostics, {
		virtual_text = { prefix = "🔍" },
		signs = true,
		underline = true,
	})
end

function M.clear_diagnostics(bufnr)
	vim.diagnostic.reset(ns, bufnr)
end

--------------------------------------------------------------------
-- Run lint (called by handle_response when mode is /lint)
--------------------------------------------------------------------

--- Process /lint response: instead of replacing code, inject diagnostics.
--- Returns true if handled (caller should skip normal code replacement).
function M.handle_lint_response(raw_output, selection)
	if not raw_output or raw_output == "" then
		return false
	end

	local diagnostics = M.parse_diagnostics(raw_output, selection.start_line)
	if #diagnostics == 0 then
		vim.notify("[dwight] 🔍 Lint: no issues found.", vim.log.levels.INFO)
		return true
	end

	M.set_diagnostics(selection.bufnr, diagnostics)

	local counts = { 0, 0, 0, 0 } -- ERROR, WARN, INFO, HINT
	for _, d in ipairs(diagnostics) do
		counts[d.severity] = (counts[d.severity] or 0) + 1
	end

	vim.notify(
		string.format(
			"[dwight] 🔍 Lint: %d issues (E:%d W:%d H:%d). Use ]d/[d to navigate, :DwightLintClear to dismiss.",
			#diagnostics,
			counts[1] or 0,
			counts[2] or 0,
			counts[4] or 0
		),
		vim.log.levels.INFO
	)

	return true
end

return M
