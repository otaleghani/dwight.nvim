-- dwight/github/branch.lua
-- Branch creation, PR creation, and issue commenting.

local M = {}

--- Create a feature branch for an issue.
--- Returns branch name.
function M.create_branch(issue)
	local cli = require("dwight.github.cli")

	local slug = (issue.title or "issue")
		:sub(1, 40)
		:lower()
		:gsub("[^%w%s%-]", "")
		:gsub("%s+", "-")
		:gsub("%-+", "-")
		:gsub("^%-+", "")
		:gsub("%-+$", "")

	local branch = string.format("fix/%d-%s", issue.number, slug)

	-- Stash if dirty
	local status = cli.run_git_sync({ "status", "--porcelain" }, 2000)
	local was_dirty = status and vim.trim(status) ~= ""
	if was_dirty then
		cli.run_git_sync({ "stash", "push", "-m", "dwight: stash before issue #" .. issue.number }, 3000)
	end

	-- Create and checkout branch
	local out = cli.run_git_sync({ "checkout", "-b", branch }, 3000)
	if not out and not cli.run_git_sync({ "rev-parse", "--verify", branch }, 1000) then
		-- Branch might already exist, try switching
		cli.run_git_sync({ "checkout", branch }, 3000)
	end

	if was_dirty then
		cli.run_git_sync({ "stash", "pop" }, 3000)
	end

	return branch
end

--- Open a pull request for the current branch.
--- opts.issue -- issue number (adds "Closes #N")
--- opts.title -- PR title (default: "Fix #N: title")
--- opts.body -- PR body (default: auto-generated)
--- opts.draft -- true for draft PR
function M.create_pr(opts, callback)
	local cli = require("dwight.github.cli")
	opts = opts or {}
	local args = cli.repo_flag(opts.repo)
	vim.list_extend(args, { "pr", "create" })

	if opts.title then
		args[#args + 1] = "--title"
		args[#args + 1] = opts.title
	end

	local body = opts.body or ""
	if opts.issue then
		if body ~= "" then
			body = body .. "\n\n"
		end
		body = body .. "Closes #" .. opts.issue
	end
	if body ~= "" then
		args[#args + 1] = "--body"
		args[#args + 1] = body
	end

	if opts.draft then
		args[#args + 1] = "--draft"
	end

	-- Push first
	local branch = cli.run_git_sync({ "rev-parse", "--abbrev-ref", "HEAD" }, 1000)
	if branch then
		branch = vim.trim(branch)
		cli.run_git_sync({ "push", "-u", "origin", branch }, 15000)
	end

	cli.run_gh(args, function(out, code)
		if code ~= 0 then
			callback(nil, "PR creation failed: " .. (out or ""):sub(1, 200))
		else
			callback(vim.trim(out), nil)
		end
	end)
end

--- Post a comment on an issue.
function M.comment(number, body, callback, opts)
	local cli = require("dwight.github.cli")
	opts = opts or {}
	local args = cli.repo_flag(opts.repo)
	vim.list_extend(args, { "issue", "comment", tostring(number), "--body", body })
	cli.run_gh(args, function(out, code)
		if callback then
			callback(code == 0, out)
		end
	end)
end

return M
