-- dwight/github/init.lua
-- Re-exports the exact public API of the original github.lua module.
-- Shared mutable state: _active_issue, _active_branch.

local M = {}

-- Shared mutable state (set by workflow.lua, read by others)
M._active_issue = nil
M._active_branch = nil

--------------------------------------------------------------------
-- cli.lua
--------------------------------------------------------------------

-- NOTE: run_gh, run_gh_sync, run_git_sync, parse_issue_ref, repo_flag
-- were local in the original module and not part of the public API.
-- They are available via require("dwight.github.cli") for sub-modules.

--------------------------------------------------------------------
-- preflight.lua
--------------------------------------------------------------------

function M.check(...)
	return require("dwight.github.preflight").check(...)
end

function M.is_github_repo(...)
	return require("dwight.github.preflight").is_github_repo(...)
end

function M.current_repo(...)
	return require("dwight.github.preflight").current_repo(...)
end

--------------------------------------------------------------------
-- issues.lua
--------------------------------------------------------------------

function M.list_issues(...)
	return require("dwight.github.issues").list_issues(...)
end

function M.get_issue(...)
	return require("dwight.github.issues").get_issue(...)
end

function M.list_templates(...)
	return require("dwight.github.issues").list_templates(...)
end

function M.create_issue(...)
	return require("dwight.github.issues").create_issue(...)
end

--------------------------------------------------------------------
-- context.lua
--------------------------------------------------------------------

function M.build_issue_context(...)
	return require("dwight.github.context").build_issue_context(...)
end

function M._extract_file_refs(...)
	return require("dwight.github.context")._extract_file_refs(...)
end

function M._detect_features(...)
	return require("dwight.github.context")._detect_features(...)
end

--------------------------------------------------------------------
-- branch.lua
--------------------------------------------------------------------

function M.create_branch(...)
	return require("dwight.github.branch").create_branch(...)
end

function M.create_pr(...)
	return require("dwight.github.branch").create_pr(...)
end

function M.comment(...)
	return require("dwight.github.branch").comment(...)
end

--------------------------------------------------------------------
-- workflow.lua
--------------------------------------------------------------------

function M.solve_agent(...)
	return require("dwight.github.workflow").solve_agent(...)
end

function M.solve_auto(...)
	return require("dwight.github.workflow").solve_auto(...)
end

function M.analyze(...)
	return require("dwight.github.workflow").analyze(...)
end

function M._offer_pr(...)
	return require("dwight.github.workflow")._offer_pr(...)
end

function M.maybe_offer_pr(...)
	return require("dwight.github.workflow").maybe_offer_pr(...)
end

function M.solve_by_number(...)
	return require("dwight.github.workflow").solve_by_number(...)
end

--------------------------------------------------------------------
-- picker.lua
--------------------------------------------------------------------

function M.pick(...)
	return require("dwight.github.picker").pick(...)
end

function M._action_picker(...)
	return require("dwight.github.picker")._action_picker(...)
end

function M._open_issue_buffer(...)
	return require("dwight.github.picker")._open_issue_buffer(...)
end

function M._pick_fallback(...)
	return require("dwight.github.picker")._pick_fallback(...)
end

--------------------------------------------------------------------
-- pr.lua
--------------------------------------------------------------------

function M.list_prs(...)
	return require("dwight.github.pr").list_prs(...)
end

function M.get_pr_diff(...)
	return require("dwight.github.pr").get_pr_diff(...)
end

function M.get_pr(...)
	return require("dwight.github.pr").get_pr(...)
end

function M.review_pr(...)
	return require("dwight.github.pr").review_pr(...)
end

function M._show_pr_review(...)
	return require("dwight.github.pr")._show_pr_review(...)
end

function M.pick_pr(...)
	return require("dwight.github.pr").pick_pr(...)
end

--------------------------------------------------------------------
-- ci.lua
--------------------------------------------------------------------

function M.ci_status(...)
	return require("dwight.github.ci").ci_status(...)
end

function M.ci_logs(...)
	return require("dwight.github.ci").ci_logs(...)
end

function M.ci_rerun(...)
	return require("dwight.github.ci").ci_rerun(...)
end

function M.ci_show(...)
	return require("dwight.github.ci").ci_show(...)
end

function M.ci_fix(...)
	return require("dwight.github.ci").ci_fix(...)
end

function M._show_ci_after_pr(...)
	return require("dwight.github.ci")._show_ci_after_pr(...)
end

return M
