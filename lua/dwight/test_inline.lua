-- dwight/test_inline.lua
-- Tests for the inline editing core path: parse, buffer, multifile, prompt, no-change detection.

vim.opt.rtp:prepend(vim.fn.getcwd())

local T = _T

--------------------------------------------------------------------
-- parse.extract_code_block
--------------------------------------------------------------------

local parse = require("dwight.inline.parse")

T.test("extract_code_block: single block", function()
	local raw = "Some text\n```lua\nlocal x = 1\n```\nMore text"
	local result = parse.extract_code_block(raw)
	T.eq("local x = 1", result)
end)

T.test("extract_code_block: largest of many", function()
	local raw = "```lua\nsmall\n```\n\n```lua\nthis is\na bigger\nblock\n```"
	local result = parse.extract_code_block(raw)
	T.eq("this is\na bigger\nblock", result)
end)

T.test("extract_code_block: no fence returns nil", function()
	local raw = "just some plain text\nno fences here"
	T.is_nil(parse.extract_code_block(raw))
end)

T.test("extract_code_block: with language tag", function()
	local raw = "```typescript\nconst x: number = 42\n```"
	local result = parse.extract_code_block(raw)
	T.eq("const x: number = 42", result)
end)

--------------------------------------------------------------------
-- parse.looks_like_monologue
--------------------------------------------------------------------

T.test("looks_like_monologue: code returns false", function()
	local code = "local x = 1\nlocal y = 2\nreturn x + y"
	T.eq(false, parse.looks_like_monologue(code))
end)

T.test("looks_like_monologue: explanation returns true", function()
	local text =
		"I'll update the code.\nHere is the solution.\nLet me explain.\nFirst, we need to.\nBased on the requirements."
	T.eq(true, parse.looks_like_monologue(text))
end)

T.test("looks_like_monologue: empty returns true", function()
	T.eq(true, parse.looks_like_monologue(""))
end)

T.test("looks_like_monologue: mixed below threshold returns false", function()
	-- 1 signal line out of 5 = 0.2 < 0.4 threshold
	local text = "I'll fix this.\nlocal a = 1\nlocal b = 2\nlocal c = 3\nreturn a + b + c"
	T.eq(false, parse.looks_like_monologue(text))
end)

--------------------------------------------------------------------
-- parse.parse_output
--------------------------------------------------------------------

T.test("parse_output: fenced code block", function()
	local raw = "Here's the code:\n```lua\nlocal x = 1\nreturn x\n```"
	local original = "local old = true\nreturn old"
	local result = parse.parse_output(raw, original, "lua")
	T.ok(result)
	T.match("local x = 1", result)
end)

T.test("parse_output: no-fence fallback", function()
	local raw = "local x = 1\nreturn x"
	local original = "local old = true\nreturn old"
	local result = parse.parse_output(raw, original, "lua")
	T.ok(result)
	T.match("local x = 1", result)
end)

T.test("parse_output: empty input returns nil", function()
	T.is_nil(parse.parse_output("", "local x = 1", "lua"))
	T.is_nil(parse.parse_output(nil, "local x = 1", "lua"))
end)

T.test("parse_output: monologue rejection", function()
	local raw =
		"I'll update the code.\nHere is the solution.\nLet me explain.\nFirst, we need to.\nBased on the requirements."
	local original = "local x = 1\nlocal y = 2\nreturn x + y"
	T.is_nil(parse.parse_output(raw, original, "lua"))
end)

T.test("parse_output: sanity-check tiny output", function()
	-- 10-line original, 1-line output = 0.1 < 0.15 threshold
	local original = "line1\nline2\nline3\nline4\nline5\nline6\nline7\nline8\nline9\nline10"
	local raw = "```lua\nx\n```"
	T.is_nil(parse.parse_output(raw, original, "lua"))
end)

T.test("parse_output: small original bypasses sanity check", function()
	-- 3-line original (<=5), even 1-line output passes
	local original = "a\nb\nc"
	local raw = "```lua\nresult\n```"
	local result = parse.parse_output(raw, original, "lua")
	T.ok(result)
	T.eq("result", result)
end)

--------------------------------------------------------------------
-- buffer._replace_selection_atomic
--------------------------------------------------------------------

local buffer = require("dwight.inline.buffer")

T.test("buffer: basic replace", function()
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "line1", "line2", "line3" })
	buffer._replace_selection_atomic(buf, 2, 2, "replaced")
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	T.eq("line1", lines[1])
	T.eq("replaced", lines[2])
	T.eq("line3", lines[3])
	T.len(3, lines)
	vim.api.nvim_buf_delete(buf, { force = true })
end)

T.test("buffer: fewer-lines replace", function()
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a", "b", "c", "d" })
	buffer._replace_selection_atomic(buf, 2, 3, "merged")
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	T.eq("a", lines[1])
	T.eq("merged", lines[2])
	T.eq("d", lines[3])
	T.len(3, lines)
	vim.api.nvim_buf_delete(buf, { force = true })
end)

T.test("buffer: more-lines replace", function()
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a", "b", "c" })
	buffer._replace_selection_atomic(buf, 2, 2, "x\ny\nz")
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	T.eq("a", lines[1])
	T.eq("x", lines[2])
	T.eq("y", lines[3])
	T.eq("z", lines[4])
	T.eq("c", lines[5])
	T.len(5, lines)
	vim.api.nvim_buf_delete(buf, { force = true })
end)

T.test("buffer: invalid buffer is a no-op", function()
	-- Should not error
	buffer._replace_selection_atomic(999999, 1, 1, "nope")
end)

--------------------------------------------------------------------
-- multifile.parse_xml
--------------------------------------------------------------------

local multifile = require("dwight.multifile")

T.test("multifile.parse_xml: basic XML", function()
	local raw = [[
<changes>
<file path="src/foo.lua" action="edit">local x = 1</file>
</changes>
]]
	local result = multifile.parse_xml(raw)
	T.ok(result)
	T.len(1, result)
	T.eq("src/foo.lua", result[1].path)
	T.eq("edit", result[1].action)
	T.eq("local x = 1", result[1].content)
end)

T.test("multifile.parse_xml: line ranges", function()
	local raw = [[
<changes>
<file path="src/bar.lua" action="edit" lines="10-20">new code</file>
</changes>
]]
	local result = multifile.parse_xml(raw)
	T.ok(result)
	T.eq(10, result[1].start_line)
	T.eq(20, result[1].end_line)
end)

T.test("multifile.parse_xml: multiple files", function()
	local raw = [[
<changes>
<file path="a.lua" action="create">aaa</file>
<file path="b.lua" action="edit">bbb</file>
<file path="c.lua" action="delete"></file>
</changes>
]]
	local result = multifile.parse_xml(raw)
	T.ok(result)
	T.len(3, result)
	T.eq("create", result[1].action)
	T.eq("edit", result[2].action)
	T.eq("delete", result[3].action)
end)

T.test("multifile.parse_xml: no changes tag returns nil", function()
	T.is_nil(multifile.parse_xml("just some text"))
	T.is_nil(multifile.parse_xml(nil))
end)

--------------------------------------------------------------------
-- multifile.parse_fenced
--------------------------------------------------------------------

T.test("multifile.parse_fenced: 2+ files", function()
	local raw = "```lua:src/a.lua\nlocal a = 1\n```\n\n```lua:src/b.lua\nlocal b = 2\n```"
	local result = multifile.parse_fenced(raw)
	T.ok(result)
	T.len(2, result)
	T.eq("src/a.lua", result[1].path)
	T.eq("src/b.lua", result[2].path)
end)

T.test("multifile.parse_fenced: single file returns nil", function()
	local raw = "```lua:src/a.lua\nlocal a = 1\n```"
	T.is_nil(multifile.parse_fenced(raw))
end)

T.test("multifile.parse_fenced: no colon-path returns nil", function()
	local raw = "```lua\nlocal a = 1\n```\n```lua\nlocal b = 2\n```"
	T.is_nil(multifile.parse_fenced(raw))
end)

--------------------------------------------------------------------
-- prompt.build_follow_up
--------------------------------------------------------------------

local prompt = require("dwight.prompt")

T.test("build_follow_up: contains previous exchange", function()
	local prev = {
		prompt_text = "refactor this function",
		raw_response = "```lua\nlocal x = 1\n```",
	}
	local result = prompt.build_follow_up("make it faster", prev, "local x = 1")
	T.match("<previous_exchange>", result)
	T.match("refactor this function", result)
	T.match("</previous_exchange>", result)
end)

T.test("build_follow_up: contains current code", function()
	local prev = { prompt_text = "p", raw_response = "r" }
	local result = prompt.build_follow_up("fix it", prev, "local current = true")
	T.match("<current_code>", result)
	T.match("local current = true", result)
	T.match("</current_code>", result)
end)

T.test("build_follow_up: contains follow-up instruction", function()
	local prev = { prompt_text = "p", raw_response = "r" }
	local result = prompt.build_follow_up("add error handling", prev, "code")
	T.match("<follow_up>", result)
	T.match("add error handling", result)
	T.match("</follow_up>", result)
end)

T.test("build_follow_up: contains output rules", function()
	local prev = { prompt_text = "p", raw_response = "r" }
	local result = prompt.build_follow_up("fix", prev, "code")
	T.match("<rules>", result)
	T.match("fenced code block", result)
	T.match("drop%-in replacement", result)
end)

--------------------------------------------------------------------
-- no-change detection (logic from response.lua)
--------------------------------------------------------------------

T.test("no-change: whitespace-normalized match", function()
	local original = "  local x = 1  \n  return x  "
	local parsed = "local x = 1\nreturn x"
	local norm_orig = vim.trim(original):gsub("%s+", " ")
	local norm_parsed = vim.trim(parsed):gsub("%s+", " ")
	T.eq(norm_orig, norm_parsed, "should detect as no change")
end)

T.test("no-change: actual change detected", function()
	local original = "local x = 1\nreturn x"
	local parsed = "local x = 2\nreturn x"
	local norm_orig = vim.trim(original):gsub("%s+", " ")
	local norm_parsed = vim.trim(parsed):gsub("%s+", " ")
	T.assert(norm_orig ~= norm_parsed, "should detect as changed")
end)
