-- tests/test_reflection.lua
-- Tests for dwight.reflection: prompt building, verdict parsing, and wrap logic.

vim.opt.rtp:prepend(vim.fn.getcwd())

local reflection = require("dwight.reflection")
local T = _T

--------------------------------------------------------------------
-- _build_prompt
--------------------------------------------------------------------

io.write("── reflection._build_prompt ──\n")

T.test("includes task in prompt", function()
	local p = reflection._build_prompt("implement sorting", "done", "output here")
	T.match("implement sorting", p)
end)

T.test("includes summary in prompt", function()
	local p = reflection._build_prompt("task", "I refactored the module", "output")
	T.match("I refactored the module", p)
end)

T.test("includes output_tail in prompt", function()
	local p = reflection._build_prompt("task", "summary", "tests passed ok")
	T.match("tests passed ok", p)
end)

T.test("contains VERDICT instruction keywords", function()
	local p = reflection._build_prompt("task", "summary", "output")
	T.match("VERDICT", p)
	T.match("PASS", p)
	T.match("RETRY", p)
end)

T.test("handles empty inputs without error", function()
	local p = reflection._build_prompt("", "", "")
	T.assert(type(p) == "string")
	T.assert(#p > 0, "prompt should not be empty")
end)

T.test("handles nil inputs without error", function()
	local p = reflection._build_prompt(nil, nil, nil)
	T.assert(type(p) == "string")
	T.assert(#p > 0, "prompt should not be empty")
end)

--------------------------------------------------------------------
-- _parse_verdict
--------------------------------------------------------------------

io.write("── reflection._parse_verdict ──\n")

T.test("parses VERDICT: PASS", function()
	local v = reflection._parse_verdict("VERDICT: PASS")
	T.eq("PASS", v.verdict)
	T.is_nil(v.reason)
end)

T.test("parses VERDICT: RETRY with reason", function()
	local v = reflection._parse_verdict("VERDICT: RETRY tests not run")
	T.eq("RETRY", v.verdict)
	T.eq("tests not run", v.reason)
end)

T.test("parses multi-word reasons", function()
	local v = reflection._parse_verdict("VERDICT: RETRY the agent did not write any code or run tests")
	T.eq("RETRY", v.verdict)
	T.eq("the agent did not write any code or run tests", v.reason)
end)

T.test("ignores preamble text before verdict line", function()
	local raw = "Let me review the output.\nThe agent seems to have done well.\nVERDICT: PASS"
	local v = reflection._parse_verdict(raw)
	T.eq("PASS", v.verdict)
end)

T.test("ignores preamble before RETRY verdict", function()
	local raw = "Looking at the output...\nVERDICT: RETRY no code was written"
	local v = reflection._parse_verdict(raw)
	T.eq("RETRY", v.verdict)
	T.eq("no code was written", v.reason)
end)

T.test("defaults to PASS on empty input", function()
	local v = reflection._parse_verdict("")
	T.eq("PASS", v.verdict)
end)

T.test("defaults to PASS on nil input", function()
	local v = reflection._parse_verdict(nil)
	T.eq("PASS", v.verdict)
end)

T.test("defaults to PASS on garbage input", function()
	local v = reflection._parse_verdict("lorem ipsum dolor sit amet")
	T.eq("PASS", v.verdict)
end)

T.test("strips whitespace from reason", function()
	local v = reflection._parse_verdict("VERDICT: RETRY   tests were not executed   \n")
	T.eq("RETRY", v.verdict)
	T.eq("tests were not executed", v.reason)
end)

T.test("fallback: bare RETRY detected", function()
	local v = reflection._parse_verdict("I think we should RETRY because nothing happened")
	T.eq("RETRY", v.verdict)
end)

T.test("fallback: bare PASS detected", function()
	local v = reflection._parse_verdict("The agent did fine, I'd say PASS")
	T.eq("PASS", v.verdict)
end)

--------------------------------------------------------------------
-- wrap
--------------------------------------------------------------------

io.write("── reflection.wrap ──\n")

T.test("passes through immediately on success=false", function()
	local called_with = nil
	local original_on_complete = function(success, data)
		called_with = { success = success, data = data }
	end

	local wrapped = reflection.wrap({ task = "do something" }, "claude_code", function() end, original_on_complete)

	wrapped(false, { error = "spawn failed" })

	T.ok(called_with, "on_complete should have been called")
	T.eq(false, called_with.success)
	T.eq("spawn failed", called_with.data.error)
end)

T.test("passes through when reflection config is disabled", function()
	-- Ensure reflection is off in config
	local dwight = require("dwight")
	local saved = dwight.config.agentic_opts
	dwight.config.agentic_opts = { reflection = false }

	local called_with = nil
	local original_on_complete = function(success, data)
		called_with = { success = success, data = data }
	end

	local wrapped = reflection.wrap({ task = "do something" }, "claude_code", function() end, original_on_complete)

	wrapped(true, { summary = "done", output = "all good" })

	T.ok(called_with, "on_complete should have been called")
	T.eq(true, called_with.success)

	-- Restore
	dwight.config.agentic_opts = saved
end)
