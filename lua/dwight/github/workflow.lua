-- dwight/github/workflow.lua
-- Solve/analyze workflows: agent, auto, analyze, PR offering, solve_by_number.

local M = {}

--- Build the request string for DwightAgent (single task).
local function build_agent_request(issue)
	local context = require("dwight.github.context")
	return string.format(
		"Solve GitHub issue #%d: %s\n\n"
			.. "Fix the issue described below. After fixing, ensure all existing tests pass "
			.. "and add new tests if appropriate.\n\n%s",
		issue.number,
		issue.title,
		context.build_issue_context(issue)
	)
end

--- Build the request string for DwightAuto (multi-task decomposition).
local function build_auto_request(issue)
	local context = require("dwight.github.context")
	return string.format(
		"Solve GitHub issue #%d: %s\n\n"
			.. "This may require multiple changes across several files. "
			.. "Fix the issue, add tests, and ensure everything compiles and passes.\n\n%s",
		issue.number,
		issue.title,
		context.build_issue_context(issue)
	)
end

--- Solve an issue via DwightAgent (single-shot agentic loop).
--- Creates branch, runs agent, offers PR on completion.
function M.solve_agent(issue)
	local gh = require("dwight.github")
	local branch_mod = require("dwight.github.branch")

	local branch = branch_mod.create_branch(issue)
	vim.notify(string.format("[dwight] Branch: %s", branch), vim.log.levels.INFO)

	-- Store issue metadata for post-completion PR flow
	gh._active_issue = issue
	gh._active_branch = branch

	-- Run agent
	local request = build_agent_request(issue)
	require("dwight.agent").run(request, {
		on_complete = function(success)
			vim.schedule(function()
				M._offer_pr(issue, success)
			end)
		end,
	})
end

--- Solve an issue via DwightAuto (multi-task decomposition).
--- Creates branch, runs auto, offers PR on completion.
function M.solve_auto(issue)
	local gh = require("dwight.github")
	local branch_mod = require("dwight.github.branch")

	local branch = branch_mod.create_branch(issue)
	vim.notify(string.format("[dwight] Branch: %s", branch), vim.log.levels.INFO)

	gh._active_issue = issue
	gh._active_branch = branch

	local request = build_auto_request(issue)
	require("dwight.auto").auto(request)
end

--- Analyze an issue without changing code.
--- Posts analysis as a comment on the issue.
function M.analyze(issue)
	local api = vim.api
	local _flatten = require("dwight.util").flatten_lines
	local context = require("dwight.github.context")
	local branch_mod = require("dwight.github.branch")

	local request = string.format(
		"Analyze GitHub issue #%d: %s\n\n"
			.. "DO NOT make any changes. Instead, analyze the codebase and describe:\n"
			.. "1. What's causing the issue (root cause)\n"
			.. "2. Which files need to change\n"
			.. "3. A proposed approach (step by step)\n"
			.. "4. Potential risks or side effects\n\n"
			.. "Output your analysis as markdown.\n\n%s",
		issue.number,
		issue.title,
		context.build_issue_context(issue)
	)

	vim.notify(string.format("[dwight] Analyzing issue #%d...", issue.number), vim.log.levels.INFO)

	require("dwight.skills")._run_llm(request, function(raw, code)
		if code ~= 0 or vim.trim(raw or "") == "" then
			vim.notify("[dwight] Analysis failed.", vim.log.levels.ERROR)
			return
		end

		-- Show analysis in a buffer
		local buf = api.nvim_create_buf(false, true)
		local lines = vim.split(raw, "\n", { plain = true })
		api.nvim_buf_set_lines(buf, 0, -1, false, _flatten(lines))
		vim.bo[buf].filetype = "markdown"
		vim.bo[buf].bufhidden = "wipe"
		api.nvim_buf_set_name(buf, string.format("dwight://issue/%d/analysis", issue.number))
		vim.cmd("botright split")
		api.nvim_win_set_buf(0, buf)

		-- Keymap: p to post as comment
		vim.keymap.set("n", "p", function()
			vim.ui.select({ "Post as comment", "Cancel" }, {
				prompt = "Post this analysis to issue #" .. issue.number .. "?",
			}, function(choice)
				if choice == "Post as comment" then
					local analysis = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
					local comment = "## Dwight Analysis\n\n" .. analysis
					branch_mod.comment(issue.number, comment, function(ok)
						if ok then
							vim.notify(
								string.format("[dwight] Analysis posted to #%d", issue.number),
								vim.log.levels.INFO
							)
						else
							vim.notify("[dwight] Failed to post comment.", vim.log.levels.ERROR)
						end
					end)
				end
			end)
		end, { buffer = buf, desc = "Post analysis as issue comment" })

		vim.notify(
			string.format("[dwight] Analysis ready for #%d. Press p to post as comment.", issue.number),
			vim.log.levels.INFO
		)
	end)
end

--- Offer to create a PR after solving an issue.
function M._offer_pr(issue, success)
	local cli = require("dwight.github.cli")
	local branch_mod = require("dwight.github.branch")
	local ci = require("dwight.github.ci")

	if not issue then
		return
	end

	local status_msg = success and "Issue solved!" or "Completed with errors."
	require("dwight.select").pick({
		"Push & open PR",
		"Push & open draft PR",
		"Just push (no PR)",
		"Skip (don't push)",
	}, {
		prompt = string.format("%s Create PR for #%d?", status_msg, issue.number),
	}, function(choice)
		if not choice or choice == "Skip (don't push)" then
			return
		end

		if choice == "Just push (no PR)" then
			local branch = cli.run_git_sync({ "rev-parse", "--abbrev-ref", "HEAD" }, 1000)
			if branch then
				cli.run_git_sync({ "push", "-u", "origin", vim.trim(branch) }, 15000)
				vim.notify("[dwight] Pushed to origin.", vim.log.levels.INFO)
			end
			return
		end

		local draft = choice:match("draft") ~= nil

		-- Build PR title and body
		local pr_title = string.format("Fix #%d: %s", issue.number, issue.title:sub(1, 60))

		-- Try to get a smart summary from the commit log
		local log = cli.run_git_sync({
			"log",
			"main..HEAD",
			"--oneline",
			"--no-decorate",
		}, 2000) or cli.run_git_sync({
			"log",
			"master..HEAD",
			"--oneline",
			"--no-decorate",
		}, 2000) or ""

		local pr_body = "## Summary\n\n"
		if vim.trim(log) ~= "" then
			pr_body = pr_body .. "Changes:\n"
			for line in log:gmatch("[^\n]+") do
				pr_body = pr_body .. "- " .. line .. "\n"
			end
			pr_body = pr_body .. "\n"
		end

		branch_mod.create_pr({
			issue = issue.number,
			title = pr_title,
			body = pr_body,
			draft = draft,
		}, function(url, err)
			if err then
				vim.notify("[dwight] " .. err, vim.log.levels.ERROR)
			else
				vim.notify(string.format("[dwight] PR created: %s", url or ""), vim.log.levels.INFO)
				-- Check CI status after a delay
				ci._show_ci_after_pr(url)
			end
		end)
	end)
end

--- Check if there's an active issue and offer PR.
--- Called by integration.post_session or manually.
function M.maybe_offer_pr()
	local gh = require("dwight.github")
	if gh._active_issue then
		M._offer_pr(gh._active_issue, true)
		gh._active_issue = nil
		gh._active_branch = nil
	end
end

--- Fetch and solve a specific issue by number.
--- opts.repo -- "owner/repo" for cross-repo
function M.solve_by_number(number, mode, opts)
	local preflight = require("dwight.github.preflight")
	local issues = require("dwight.github.issues")

	mode = mode or "pick"
	opts = opts or {}

	local check = preflight.check()
	if not check.ok then
		vim.notify("[dwight] " .. check.detail, vim.log.levels.ERROR)
		return
	end

	local repo_str = opts.repo and (" in " .. opts.repo) or ""
	vim.notify(string.format("[dwight] Fetching issue #%d%s...", number, repo_str), vim.log.levels.INFO)

	issues.get_issue(number, function(issue, err)
		if err then
			vim.notify("[dwight] " .. err, vim.log.levels.ERROR)
			return
		end

		if mode == "agent" then
			M.solve_agent(issue)
		elseif mode == "auto" then
			M.solve_auto(issue)
		elseif mode == "analyze" then
			M.analyze(issue)
		else
			local picker = require("dwight.github.picker")
			picker._action_picker(issue)
		end
	end, { repo = opts.repo })
end

return M
