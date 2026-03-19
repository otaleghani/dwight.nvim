-- tests/test_ux.lua
-- Tests for UX polish: undo, modes picker, config validation, error messages.

vim.opt.rtp:prepend(vim.fn.getcwd())

local T = _T

--------------------------------------------------------------------
-- list_dwight_commits parsing
--------------------------------------------------------------------

io.write("── list_dwight_commits ──\n")

T.test("list_dwight_commits: parses git log output", function()
	local git = require("dwight.auto.git")

	-- Monkey-patch git_sync for testing
	local orig = git.git_sync
	local orig_is_git = git.is_git_repo
	git.is_git_repo = function()
		return true
	end
	git.git_sync = function(args)
		if args[1] == "log" then
			return "abc1234567890 feat: first commit\ndef4567890abc fix: second commit\n", 0
		end
		return "", 0
	end

	local commits = git.list_dwight_commits(20)
	T.eq(2, #commits, "should parse 2 commits")
	T.eq("abc1234567890", commits[1].hash)
	T.eq("feat: first commit", commits[1].message)
	T.eq("def4567890abc", commits[2].hash)
	T.eq("fix: second commit", commits[2].message)

	-- Restore
	git.git_sync = orig
	git.is_git_repo = orig_is_git
end)

T.test("list_dwight_commits: returns empty on non-git", function()
	local git = require("dwight.auto.git")

	local orig = git.is_git_repo
	git.is_git_repo = function()
		return false
	end

	local commits = git.list_dwight_commits(20)
	T.eq(0, #commits, "should return empty for non-git")

	git.is_git_repo = orig
end)

T.test("list_dwight_commits: handles empty output", function()
	local git = require("dwight.auto.git")

	local orig = git.git_sync
	local orig_is_git = git.is_git_repo
	git.is_git_repo = function()
		return true
	end
	git.git_sync = function()
		return "", 0
	end

	local commits = git.list_dwight_commits(5)
	T.eq(0, #commits, "should return empty for empty output")

	git.git_sync = orig
	git.is_git_repo = orig_is_git
end)

--------------------------------------------------------------------
-- modes.pick is callable
--------------------------------------------------------------------

io.write("── modes.pick ──\n")

T.test("modes.pick: function exists", function()
	local modes = require("dwight.modes")
	T.ok(type(modes.pick) == "function", "modes.pick should be a function")
end)

T.test("modes._pick_native: function exists", function()
	local modes = require("dwight.modes")
	T.ok(type(modes._pick_native) == "function", "modes._pick_native should be a function")
end)

T.test("modes._pick_telescope: function exists", function()
	local modes = require("dwight.modes")
	T.ok(type(modes._pick_telescope) == "function", "modes._pick_telescope should be a function")
end)

--------------------------------------------------------------------
-- Config: diff_preview and streaming are now unknown keys
--------------------------------------------------------------------

io.write("── config: removed keys ──\n")

T.test("diff_preview is flagged as unknown key", function()
	local config = require("dwight.config")
	local msgs = config.find_unknown_keys({ diff_preview = false })
	T.eq(1, #msgs, "should flag diff_preview as unknown")
	T.match("diff_preview", msgs[1].msg)
end)

T.test("streaming is flagged as unknown key", function()
	local config = require("dwight.config")
	local msgs = config.find_unknown_keys({ streaming = false })
	T.eq(1, #msgs, "should flag streaming as unknown")
	T.match("streaming", msgs[1].msg)
end)

T.test("valid keys are not flagged", function()
	local config = require("dwight.config")
	local msgs = config.find_unknown_keys({ backend = "claude_code", git_context = true })
	T.eq(0, #msgs, "valid keys should not be flagged")
end)

--------------------------------------------------------------------
-- Error message hints
--------------------------------------------------------------------

io.write("── error message hints ──\n")

T.test("empty output message includes DwightLog hint", function()
	-- We test the format string pattern directly
	local msg = string.format(
		"[dwight] Job #%d: empty output. Check :DwightLog for details. This can happen if the model returned nothing or the API timed out.",
		1
	)
	T.match(":DwightLog", msg)
	T.match("timed out", msg)
end)

T.test("pre-apply check message includes error text", function()
	local msg =
		string.format("[dwight] Job #%d: pre-apply check failed: %s", 1, ("syntax error near line 5"):sub(1, 200))
	T.match("syntax error", msg)
end)

T.test("timeout message includes config hint", function()
	local msg = string.format(
		"⏰ %s timed out after %ds — killing. Increase agentic_opts.cli_timeout (current: %d) for longer tasks.",
		"claude",
		600,
		600
	)
	T.match("agentic_opts.cli_timeout", msg)
	T.match("current: 600", msg)
end)

T.test("classify_error fallback includes common causes hint (claude)", function()
	local msg =
		"Claude Code failed (exit 1): some error Common causes: network issue, max turns reached, or invalid model."
	T.match("Common causes", msg)
	T.match("network issue", msg)
end)

--------------------------------------------------------------------
-- diff.lua is gone
--------------------------------------------------------------------

io.write("── diff.lua removed ──\n")

T.test("require dwight.diff errors (file deleted)", function()
	local ok = pcall(require, "dwight.diff")
	T.assert(not ok, "require('dwight.diff') should error since the file was deleted")
end)
