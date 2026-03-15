-- dwight/github/preflight.lua
-- Preflight checks: gh CLI availability, authentication, repo detection.

local M = {}

--- Check if gh CLI is available and authenticated.
--- Returns { ok, detail }
function M.check()
	local cli = require("dwight.github.cli")

	local path = vim.fn.exepath("gh")
	if path == "" then
		return { ok = false, detail = "gh CLI not found. Install from https://cli.github.com" }
	end

	local out, code = cli.run_gh_sync({ "auth", "status" }, 5000)
	if code ~= 0 then
		return { ok = false, detail = "gh not authenticated. Run: gh auth login" }
	end

	return { ok = true, detail = "gh authenticated (" .. path .. ")" }
end

--- Check if we're in a GitHub repo (has remote pointing to github.com).
function M.is_github_repo()
	local cli = require("dwight.github.cli")
	local out = cli.run_git_sync({ "remote", "get-url", "origin" }, 2000)
	return out and out:match("github") ~= nil
end

--- Detect the current repo's owner/name from git remote.
function M.current_repo()
	local cli = require("dwight.github.cli")
	local out = cli.run_git_sync({ "remote", "get-url", "origin" }, 2000)
	if not out then
		return nil
	end
	-- git@github.com:owner/repo.git or https://github.com/owner/repo.git
	local owner, name = out:match("github%.com[:/]([%w%-%.]+)/([%w%-%.]+)")
	if owner and name then
		return owner .. "/" .. name:gsub("%.git%s*$", "")
	end
	return nil
end

return M
