-- dwight/github/pr.lua
-- Pull request API: list, get, diff, review, and PR picker.

local M = {}

M.PR_FIELDS =
	"number,title,body,state,author,baseRefName,headRefName,additions,deletions,changedFiles,files,url,labels,assignees,milestone,reviewDecision,reviews"

--- List open PRs.
function M.list_prs(opts, callback)
	local cli = require("dwight.github.cli")
	opts = opts or {}
	local args = cli.repo_flag(opts.repo)
	vim.list_extend(args, {
		"pr",
		"list",
		"--json",
		M.PR_FIELDS,
		"--limit",
		tostring(opts.limit or 20),
		"--state",
		opts.state or "open",
	})

	if opts.label then
		args[#args + 1] = "--label"
		args[#args + 1] = opts.label
	end
	if opts.assignee then
		args[#args + 1] = "--assignee"
		args[#args + 1] = opts.assignee
	end

	cli.run_gh(args, function(out, code)
		if code ~= 0 then
			callback(nil, "gh pr list failed: " .. (out or ""):sub(1, 200))
			return
		end
		local ok, data = pcall(vim.json.decode, out)
		if not ok then
			callback(nil, "Failed to parse PR list")
			return
		end
		callback(data, nil)
	end)
end

--- Get the diff for a PR.
function M.get_pr_diff(number, callback, opts)
	local cli = require("dwight.github.cli")
	opts = opts or {}
	local args = cli.repo_flag(opts.repo)
	vim.list_extend(args, { "pr", "diff", tostring(number) })
	cli.run_gh(args, function(out, code)
		callback(code == 0 and out or nil, code ~= 0 and out or nil)
	end)
end

--- Get full PR details.
function M.get_pr(number, callback, opts)
	local cli = require("dwight.github.cli")
	opts = opts or {}
	local args = cli.repo_flag(opts.repo)
	vim.list_extend(args, { "pr", "view", tostring(number), "--json", M.PR_FIELDS })
	cli.run_gh(args, function(out, code)
		if code ~= 0 then
			callback(nil, out)
			return
		end
		local ok, data = pcall(vim.json.decode, out)
		if not ok then
			callback(nil, "parse error")
			return
		end
		callback(data, nil)
	end)
end

--- Review a PR with AI analysis.
--- Shows diff, runs agentic analysis, displays findings.
function M.review_pr(number, opts)
	local cli = require("dwight.github.cli")
	local preflight = require("dwight.github.preflight")
	opts = opts or {}

	local check = preflight.check()
	if not check.ok then
		vim.notify("[dwight] " .. check.detail, vim.log.levels.ERROR)
		return
	end

	vim.notify(string.format("[dwight] Fetching PR #%d for review...", number), vim.log.levels.INFO)

	-- Fetch PR details and diff in parallel
	local pr_data, diff_data, done_count = nil, nil, 0
	local function check_done()
		done_count = done_count + 1
		if done_count < 2 then
			return
		end

		if not pr_data then
			vim.notify("[dwight] Failed to fetch PR details.", vim.log.levels.ERROR)
			return
		end

		-- Build review prompt
		local diff_text = diff_data or "(diff unavailable)"
		if #diff_text > 40000 then
			diff_text = diff_text:sub(1, 40000) .. "\n... (diff truncated)"
		end

		local prompt = string.format(
			[[
You are a senior engineer reviewing Pull Request #%d: "%s"

Branch: %s -> %s
Changes: +%d -%d across %d file(s)

## PR Description
%s

## Diff
```diff
%s
```

## Your Review Task

Analyze this PR thoroughly and write your review to `.dwight/artifacts/pr-review.json` in this format:
```json
{
  "summary": "2-3 sentence overall assessment",
  "verdict": "approve|request_changes|comment",
  "findings": [
    {
      "file": "path/to/file.go",
      "line": 42,
      "severity": "CRITICAL|WARN|SUGGESTION|PRAISE",
      "comment": "detailed review comment"
    }
  ],
  "suggestions": ["overall suggestion 1", "overall suggestion 2"]
}
```

Focus on:
- Logic errors, bugs, edge cases
- Security vulnerabilities
- Performance issues
- Code style consistency
- Missing tests or error handling
- Good patterns worth praising (severity=PRAISE)

IMPORTANT: `mkdir -p .dwight/artifacts` before writing. Do NOT modify any source files.
]],
			pr_data.number,
			pr_data.title or "",
			pr_data.headRefName or "?",
			pr_data.baseRefName or "?",
			pr_data.additions or 0,
			pr_data.deletions or 0,
			pr_data.changedFiles or 0,
			(pr_data.body or "(no description)"):sub(1, 5000),
			diff_text
		)

		-- Run agentic review
		local agentic = require("dwight.agentic")
		local status_mod = require("dwight.agent_status")

		status_mod.open()
		status_mod.start_session(string.format("PR Review: #%d", number))
		status_mod.append_hl(string.format("PR #%d: %s", number, (pr_data.title or ""):sub(1, 50)), "DwightHeader")
		status_mod.append_hl(
			string.format(
				"  +%d -%d across %d files",
				pr_data.additions or 0,
				pr_data.deletions or 0,
				pr_data.changedFiles or 0
			),
			"DwightDim"
		)

		local pr_tool_counts = { reads = 0, writes = 0, cmds = 0, searches = 0, other = 0 }
		local pr_tool_log = {}
		local pr_started = os.time()

		local function pr_fmt_tools()
			local parts = {}
			if pr_tool_counts.reads > 0 then
				parts[#parts + 1] = pr_tool_counts.reads .. "r"
			end
			if pr_tool_counts.searches > 0 then
				parts[#parts + 1] = pr_tool_counts.searches .. "s"
			end
			if #parts == 0 then
				return ""
			end
			return " [" .. table.concat(parts, " ") .. "]"
		end

		agentic.run({
			task = prompt,
			on_status = function(text)
				pcall(function()
					if #text > 5 then
						require("dwight.session_log").append(text:sub(1, 500))
					end
				end)
			end,
			on_tool = function(desc)
				local key = desc:match("^Read ") and "reads"
					or desc:match("^%$ ") and "cmds"
					or (desc:match("^Search ") or desc:match("^List ")) and "searches"
					or "other"
				pr_tool_counts[key] = pr_tool_counts[key] + 1
				pr_tool_log[#pr_tool_log + 1] = desc:sub(1, 120)
				status_mod.spin("Reviewing..." .. pr_fmt_tools() .. "  " .. (os.time() - pr_started) .. "s")
			end,
			on_complete = function(success)
				status_mod.stop_spin()

				if #pr_tool_log > 0 then
					local total_tools = 0
					for _, v in pairs(pr_tool_counts) do
						total_tools = total_tools + v
					end
					status_mod.append_fold(string.format("  ▸ Details (%d tool calls)", total_tools), pr_tool_log)
				end

				if not success then
					status_mod.append_hl("  ✗ PR review failed", "DwightFail")
					return
				end

				local project = require("dwight.project")
				local result_path = project.is_initialized() and (project.dir() .. "/artifacts/pr-review.json") or nil
				local review = nil
				if result_path then
					local f = io.open(result_path, "r")
					if f then
						local raw = f:read("*a")
						f:close()
						os.remove(result_path)
						local parse_ok, parsed = pcall(vim.json.decode, raw)
						if parse_ok then
							review = parsed
						end
					end
				end

				if not review then
					status_mod.append_hl("  ✗ No structured review produced", "DwightWarn")
					return
				end

				status_mod.append_hl("  ● Review complete", "DwightOK")
				M._show_pr_review(pr_data, review)
			end,
		})
	end

	M.get_pr(number, function(data, err)
		if err then
			vim.notify("[dwight] PR fetch error: " .. tostring(err), vim.log.levels.WARN)
		end
		pr_data = data
		check_done()
	end, opts)

	M.get_pr_diff(number, function(diff, err)
		diff_data = diff
		check_done()
	end, opts)
end

--- Display PR review results in a buffer with action keybindings.
function M._show_pr_review(pr, review)
	local api = vim.api
	local _flatten = require("dwight.util").flatten_lines
	local cli = require("dwight.github.cli")

	local lines = {
		"======================================================================",
		string.format("  PR Review: #%d -- %s", pr.number, (pr.title or ""):sub(1, 50)),
		"======================================================================",
		"",
	}

	-- Verdict
	local verdict_label = review.verdict == "approve" and "APPROVE"
		or review.verdict == "request_changes" and "REQUEST_CHANGES"
		or "COMMENT"
	lines[#lines + 1] = string.format("  Verdict: %s", verdict_label)
	lines[#lines + 1] = ""

	-- Summary
	if review.summary then
		lines[#lines + 1] = "  " .. review.summary
		lines[#lines + 1] = ""
	end

	-- Findings
	local sev_icons = { CRITICAL = "[CRIT]", WARN = "[WARN]", SUGGESTION = "[SUGG]", PRAISE = "[GOOD]" }
	if review.findings and #review.findings > 0 then
		lines[#lines + 1] = "  --- Findings ---"
		lines[#lines + 1] = ""
		local current_file = ""
		for _, f in ipairs(review.findings) do
			if f.file and f.file ~= current_file then
				current_file = f.file
				lines[#lines + 1] = string.format("  %s", current_file)
			end
			local icon = sev_icons[f.severity] or "[??]"
			lines[#lines + 1] = string.format("  %s L%d: %s", icon, f.line or 0, f.comment or "")
		end
		lines[#lines + 1] = ""
	end

	-- Suggestions
	if review.suggestions and #review.suggestions > 0 then
		lines[#lines + 1] = "  --- Suggestions ---"
		for _, s in ipairs(review.suggestions) do
			lines[#lines + 1] = "  * " .. s
		end
		lines[#lines + 1] = ""
	end

	lines[#lines + 1] = "  --- Actions ---"
	lines[#lines + 1] = "  p     Post review to GitHub"
	lines[#lines + 1] = "  q     Close"

	-- Display in split
	local buf = api.nvim_create_buf(false, true)
	api.nvim_buf_set_lines(buf, 0, -1, false, _flatten(lines))
	vim.bo[buf].modifiable = false
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].filetype = "dwight_review"

	vim.cmd("botright split")
	local win = api.nvim_get_current_win()
	api.nvim_win_set_buf(win, buf)
	api.nvim_win_set_height(win, math.min(#lines + 2, math.floor(vim.o.lines * 0.5)))

	local function safe_close()
		local wins = api.nvim_tabpage_list_wins(0)
		if #wins <= 1 then
			vim.cmd("enew")
		else
			api.nvim_win_close(win, true)
		end
	end

	-- p: Post review to GitHub
	vim.keymap.set("n", "p", function()
		-- Build review body
		local body_parts = { "## Dwight PR Review\n" }
		if review.summary then
			body_parts[#body_parts + 1] = review.summary .. "\n"
		end

		if review.findings and #review.findings > 0 then
			body_parts[#body_parts + 1] = "\n### Findings\n"
			for _, f in ipairs(review.findings) do
				local icon = sev_icons[f.severity] or "[??]"
				body_parts[#body_parts + 1] =
					string.format("- %s **%s:%d** -- %s", icon, f.file or "?", f.line or 0, f.comment or "")
			end
		end

		if review.suggestions and #review.suggestions > 0 then
			body_parts[#body_parts + 1] = "\n### Suggestions\n"
			for _, s in ipairs(review.suggestions) do
				body_parts[#body_parts + 1] = "- " .. s
			end
		end

		local review_body = table.concat(body_parts, "\n")
		local event = review.verdict == "approve" and "APPROVE"
			or review.verdict == "request_changes" and "REQUEST_CHANGES"
			or "COMMENT"

		cli.run_gh({
			"pr",
			"review",
			tostring(pr.number),
			"--" .. event:lower():gsub("_", "-"),
			"--body",
			review_body,
		}, function(out, code)
			if code == 0 then
				vim.notify(
					string.format("[dwight] Review posted to PR #%d (%s)", pr.number, event),
					vim.log.levels.INFO
				)
			else
				vim.notify("[dwight] Failed to post review: " .. (out or ""):sub(1, 200), vim.log.levels.ERROR)
			end
		end)
	end, { buffer = buf, desc = "Post review to GitHub" })

	-- q: Close
	vim.keymap.set("n", "q", safe_close, { buffer = buf, desc = "Close" })

	vim.notify(string.format("[dwight] PR #%d review ready. p=post q=close", pr.number), vim.log.levels.INFO)
end

--- Open Telescope picker for PRs to review.
function M.pick_pr(opts)
	local preflight = require("dwight.github.preflight")
	opts = opts or {}

	local check = preflight.check()
	if not check.ok then
		vim.notify("[dwight] " .. check.detail, vim.log.levels.ERROR)
		return
	end

	vim.notify("[dwight] Fetching PRs...", vim.log.levels.INFO)

	M.list_prs(opts, function(prs, err)
		if err then
			vim.notify("[dwight] " .. err, vim.log.levels.ERROR)
			return
		end
		if not prs or #prs == 0 then
			vim.notify("[dwight] No open PRs found.", vim.log.levels.INFO)
			return
		end

		local items = {}
		for _, pr in ipairs(prs) do
			local author = type(pr.author) == "table" and pr.author.login or (pr.author or "?")
			items[#items + 1] = string.format(
				"#%-5d %s -> %s  (+%d/-%d)  @%s  %s",
				pr.number,
				(pr.headRefName or "?"):sub(1, 20),
				(pr.baseRefName or "?"):sub(1, 10),
				pr.additions or 0,
				pr.deletions or 0,
				author,
				(pr.title or ""):sub(1, 40)
			)
		end

		require("dwight.select").pick(items, {
			prompt = "Select PR to review:",
		}, function(_, idx)
			if idx then
				M.review_pr(prs[idx].number, opts)
			end
		end)
	end)
end

return M
