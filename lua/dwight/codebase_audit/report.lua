-- dwight/codebase_audit/report.lua
-- Report generation and display for audit results.

local M = {}

--- Build report lines for display buffer.
function M._build_report_lines(feature_name, result)
	local U = require("dwight.util")
	local findings = result.findings
	local stats = result.stats
	local lines = {}

	-- Header
	lines[#lines + 1] = U.tui_header("DwightAudit: $" .. feature_name)
	lines[#lines + 1] = ""

	-- Stats
	lines[#lines + 1] =
		string.format("  Files: %d  |  Functions: %d  |  Findings: %d", stats.files, stats.functions, #findings)
	lines[#lines + 1] = string.format(
		"  ✗ Critical: %d  |  ○ Warnings: %d  |  · Info: %d",
		stats.secrets + stats.error_issues,
		stats.long_functions + stats.deep_functions + stats.duplication,
		stats.many_params + stats.no_tests
	)

	-- Agent review stats (if available)
	local review = result.agent_review
	if review then
		lines[#lines + 1] = ""
		lines[#lines + 1] = U.tui_header("Agent Deep Review")
		lines[#lines + 1] = string.format(
			"  Verified: %d  |  False positives removed: %d  |  New findings: %d",
			review.verified or 0,
			review.false_positives or 0,
			review.new_findings or 0
		)

		if review.test_results then
			local tr = review.test_results
			local status_icon = tr.passed and "●" or "✗"
			local cov_str = tr.coverage_pct and string.format("  |  Coverage: %.1f%%", tr.coverage_pct) or ""
			lines[#lines + 1] =
				string.format("  Tests: %s %s%s", status_icon, (tr.output_summary or ""):sub(1, 60), cov_str)
		end

		if review.summary then
			lines[#lines + 1] = ""
			lines[#lines + 1] = "  " .. (review.summary or "")
		end
	end

	lines[#lines + 1] = ""

	if #findings == 0 then
		lines[#lines + 1] = "  ● No issues found. This feature looks clean."
		lines[#lines + 1] = ""
		return lines
	end

	-- Keybindings (shown before findings for discoverability)
	lines[#lines + 1] = U.tui_header("Keybindings")
	lines[#lines + 1] = "  <CR>  Jump to file:line  |  h  Heal finding  |  H  Heal feature"
	lines[#lines + 1] = "  i     Ignore finding     |  a  Agentic review  |  q  Close"
	lines[#lines + 1] = ""

	lines[#lines + 1] = U.tui_header("Findings (sorted by severity)")
	lines[#lines + 1] = ""

	-- Finding lines — grouped by severity then file
	local current_sev = ""
	local current_file = ""
	for i, f in ipairs(findings) do
		-- Severity heading
		if f.severity.label ~= current_sev then
			-- Close previous file fold
			if current_file ~= "" then
				lines[#lines + 1] = "  ▸}}}"
				current_file = ""
			end
			current_sev = f.severity.label
			lines[#lines + 1] = ""
			lines[#lines + 1] = U.tui_header(f.severity.icon .. " " .. current_sev)
		end

		-- File grouping within severity
		if f.file ~= current_file then
			-- Close previous fold
			if current_file ~= "" then
				lines[#lines + 1] = "  ▸}}}"
			end
			current_file = f.file
			lines[#lines + 1] = string.format("  %s ▸{{{", current_file)
		end

		local verified = f.agent_verified and " ✓agent" or (f.llm_reviewed and " ✓" or "")
		lines[#lines + 1] =
			string.format("    %s [%s] L%d: %s%s", f.severity.icon, f.category, f.line, f.message, verified)

		if f.snippet and f.snippet ~= "" then
			lines[#lines + 1] = string.format("        | %s", f.snippet)
		end

		-- Show fix suggestion if agent provided one
		if f.fix and f.fix ~= "" then
			-- Wrap fix text to ~70 chars
			local fix_text = f.fix:gsub("\n", " "):sub(1, 200)
			lines[#lines + 1] = string.format("        Fix: %s", fix_text)
		end

		-- Marker for keybinding lookup
		lines[#lines + 1] = string.format("      [%d] <CR>=goto  h=heal  i=ignore", i)
	end

	-- Close last fold
	if current_file ~= "" then
		lines[#lines + 1] = "  ▸}}}"
	end

	return lines
end

--- Find which finding index a buffer line corresponds to.
function M.finding_at_cursor(buf_lines, cursor_line)
	-- Walk backwards from cursor to find the nearest [N] marker
	for i = cursor_line, math.max(1, cursor_line - 5), -1 do
		local line = buf_lines[i] or ""
		local idx = line:match("%[(%d+)%]%s*<CR>")
		if idx then
			return tonumber(idx)
		end
	end
	return nil
end

--- Show the audit report in a floating buffer with keybindings.
function M._show_report(feature_name, result)
	local api = vim.api
	local U = require("dwight.util")

	local report_lines = M._build_report_lines(feature_name, result)

	local buf = api.nvim_create_buf(false, true)
	api.nvim_buf_set_lines(buf, 0, -1, false, U.flatten_lines(report_lines))
	vim.bo[buf].modifiable = false
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].filetype = "dwight_audit"

	U.apply_tui_syntax(buf)

	-- Open as a split (not float — report can be long)
	vim.cmd("botright split")
	local win = api.nvim_get_current_win()
	api.nvim_win_set_buf(win, buf)
	api.nvim_win_set_height(win, math.min(#report_lines + 2, math.floor(vim.o.lines * 0.5)))

	U.setup_tui_win(win, { foldlevel = 1 })

	-- Store state for keybindings
	vim.b[buf] = vim.b[buf] or {}
	api.nvim_buf_set_var(buf, "dwight_audit_feature", feature_name)
	api.nvim_buf_set_var(buf, "dwight_audit_result", result)

	-- Keybindings
	local function get_finding()
		local cursor = api.nvim_win_get_cursor(win)
		local idx = M.finding_at_cursor(report_lines, cursor[1])
		if not idx or not result.findings[idx] then
			vim.notify("[dwight] No finding at cursor", vim.log.levels.WARN)
			return nil
		end
		return result.findings[idx], idx
	end

	--- Close audit window safely (handles last-window case).
	--- If this is the last window, replace buffer instead of closing.
	local function safe_close()
		local wins = api.nvim_tabpage_list_wins(0)
		if #wins <= 1 then
			-- Can't close the last window — switch to an empty buffer
			vim.cmd("enew")
		else
			api.nvim_win_close(win, true)
		end
	end

	-- <CR> Jump to file:line (opens in previous window, keeps audit open)
	vim.keymap.set("n", "<CR>", function()
		local f = get_finding()
		if not f then
			return
		end
		-- Switch to previous window and open file there
		vim.cmd("wincmd p")
		vim.cmd("edit " .. vim.fn.fnameescape(f.file))
		pcall(api.nvim_win_set_cursor, 0, { f.line, 0 })
		vim.cmd("normal! zz")
	end, { buffer = buf, desc = "Jump to finding" })

	-- h: Heal single finding
	vim.keymap.set("n", "h", function()
		local f = get_finding()
		if not f then
			return
		end
		safe_close()
		require("dwight.codebase_heal").heal_finding(feature_name, f)
	end, { buffer = buf, desc = "Heal this finding" })

	-- H: Heal entire feature
	vim.keymap.set("n", "H", function()
		safe_close()
		require("dwight.codebase_heal").heal(feature_name, { findings = result.findings })
	end, { buffer = buf, desc = "Heal entire feature" })

	-- i: Ignore finding
	vim.keymap.set("n", "i", function()
		local f, idx = get_finding()
		if not f then
			return
		end
		table.remove(result.findings, idx)
		-- Refresh report
		local new_lines = M._build_report_lines(feature_name, result)
		vim.bo[buf].modifiable = true
		api.nvim_buf_set_lines(buf, 0, -1, false, U.flatten_lines(new_lines))
		vim.bo[buf].modifiable = false
		report_lines = new_lines
		vim.notify(string.format("[dwight] Ignored: %s", f.message), vim.log.levels.INFO)
	end, { buffer = buf, desc = "Ignore finding" })

	-- a: Agentic deep review
	vim.keymap.set("n", "a", function()
		local feat = feature_name
		safe_close()
		require("dwight.codebase_audit").audit(feat, { agentic = true })
	end, { buffer = buf, desc = "Agentic deep review" })

	-- q: Close
	vim.keymap.set("n", "q", function()
		safe_close()
	end, { buffer = buf, desc = "Close" })

	-- Populate quickfix with findings
	if #result.findings > 0 then
		local qf_items = {}
		local cwd = vim.fn.getcwd()
		for _, f in ipairs(result.findings) do
			local fix_text = ""
			if f.fix then
				fix_text = " Fix: " .. f.fix:gsub("\n", " "):sub(1, 100)
			end
			qf_items[#qf_items + 1] = {
				filename = f.file:match("^/") and f.file or (cwd .. "/" .. f.file),
				lnum = f.line,
				col = 1,
				type = f.severity.sort == 1 and "E" or (f.severity.sort == 2 and "W" or "I"),
				text = string.format("[%s] %s%s", f.category, f.message, fix_text),
			}
		end
		vim.fn.setqflist(qf_items, "r")
		vim.fn.setqflist({}, "a", {
			title = string.format("DwightAudit: $%s — %d finding(s)", feature_name, #qf_items),
		})
	end

	return buf
end

return M
