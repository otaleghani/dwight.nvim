-- tests/test_mcp_json.lua
-- Tests for mcp_json.lua pure Lua JSON codec.

vim.opt.rtp:prepend(vim.fn.getcwd())

local json = require("dwight.mcp_json")
local T = _T

io.write("── mcp_json.encode ──\n")

T.test("encode string", function()
	T.eq('"hello"', json.encode("hello"))
end)

T.test("encode string with newlines (NDJSON safety)", function()
	local encoded = json.encode("line1\nline2")
	T.eq('"line1\\nline2"', encoded)
	-- Must not contain literal newline
	T.assert(not encoded:find("\n"), "encoded string contains literal newline")
end)

T.test("encode string with special chars", function()
	local encoded = json.encode('tab\there\r\n"quotes"\\back')
	T.assert(not encoded:find("\t"), "literal tab in output")
	T.assert(not encoded:find("\r"), "literal CR in output")
	T.assert(not encoded:find("\n"), "literal LF in output")
end)

T.test("encode number integer", function()
	T.eq("42", json.encode(42))
end)

T.test("encode number float", function()
	local encoded = json.encode(3.14)
	T.assert(encoded:match("^3%.14"), "expected 3.14, got " .. encoded)
end)

T.test("encode number negative", function()
	T.eq("-1", json.encode(-1))
end)

T.test("encode boolean true", function()
	T.eq("true", json.encode(true))
end)

T.test("encode boolean false", function()
	T.eq("false", json.encode(false))
end)

T.test("encode nil", function()
	T.eq("null", json.encode(nil))
end)

T.test("encode empty table as empty object", function()
	-- Empty table with no keys → treated as empty array []
	T.eq("[]", json.encode({}))
end)

T.test("encode array", function()
	T.eq("[1,2,3]", json.encode({ 1, 2, 3 }))
end)

T.test("encode array of strings", function()
	T.eq('["a","b"]', json.encode({ "a", "b" }))
end)

T.test("encode object", function()
	-- Single key object for deterministic output
	local encoded = json.encode({ name = "test" })
	T.eq('{"name":"test"}', encoded)
end)

T.test("encode nested object", function()
	local val = { data = { items = { 1, 2 } } }
	local encoded = json.encode(val)
	T.assert(encoded:find('"data"'), "missing data key")
	T.assert(encoded:find('"items"'), "missing items key")
	T.assert(encoded:find("%[1,2%]"), "missing array")
end)

T.test("encode NaN as null", function()
	T.eq("null", json.encode(0 / 0))
end)

T.test("encode Inf as null", function()
	T.eq("null", json.encode(1 / 0))
end)

io.write("── mcp_json.decode ──\n")

T.test("decode string", function()
	T.eq("hello", json.decode('"hello"'))
end)

T.test("decode string with escapes", function()
	T.eq("line1\nline2", json.decode('"line1\\nline2"'))
end)

T.test("decode number", function()
	T.eq(42, json.decode("42"))
end)

T.test("decode negative number", function()
	T.eq(-3.14, json.decode("-3.14"))
end)

T.test("decode true", function()
	T.eq(true, json.decode("true"))
end)

T.test("decode false", function()
	T.eq(false, json.decode("false"))
end)

T.test("decode null", function()
	T.is_nil(json.decode("null"))
end)

T.test("decode empty array", function()
	local val = json.decode("[]")
	T.eq(0, #val)
end)

T.test("decode array", function()
	local val = json.decode("[1, 2, 3]")
	T.eq(3, #val)
	T.eq(1, val[1])
	T.eq(3, val[3])
end)

T.test("decode empty object", function()
	local val = json.decode("{}")
	T.assert(type(val) == "table", "expected table")
	T.is_nil(next(val))
end)

T.test("decode object", function()
	local val = json.decode('{"name": "test", "count": 5}')
	T.eq("test", val.name)
	T.eq(5, val.count)
end)

T.test("decode nested", function()
	local val = json.decode('{"data": {"items": [1, 2]}}')
	T.eq(2, #val.data.items)
	T.eq(1, val.data.items[1])
end)

T.test("decode unicode escape", function()
	local val = json.decode('"\\u0041"') -- 'A'
	T.eq("A", val)
end)

T.test("decode with whitespace", function()
	local val = json.decode('  { "a" : 1 }  ')
	T.eq(1, val.a)
end)

io.write("── mcp_json round-trips ──\n")

T.test("round-trip object", function()
	local orig = { phase = "coding", percent = 45, message = "Writing handler" }
	local encoded = json.encode(orig)
	local decoded = json.decode(encoded)
	T.eq(orig.phase, decoded.phase)
	T.eq(orig.percent, decoded.percent)
	T.eq(orig.message, decoded.message)
end)

T.test("round-trip array of strings", function()
	local orig = { "auth.go", "main.go" }
	local encoded = json.encode(orig)
	local decoded = json.decode(encoded)
	T.eq(2, #decoded)
	T.eq("auth.go", decoded[1])
	T.eq("main.go", decoded[2])
end)

T.test("round-trip nested progress event", function()
	local orig = {
		task_id = "swarm-w1-t2",
		phase = "coding",
		percent = 45,
		message = "Writing auth handler",
		files_touched = { "auth.go" },
		tokens_used = 12500,
		timestamp = 1710000000,
	}
	local encoded = json.encode(orig)
	-- Verify NDJSON safety: no literal newlines
	T.assert(not encoded:find("\n"), "encoded event has literal newline")
	local decoded = json.decode(encoded)
	T.eq("swarm-w1-t2", decoded.task_id)
	T.eq("coding", decoded.phase)
	T.eq(45, decoded.percent)
	T.eq("auth.go", decoded.files_touched[1])
	T.eq(12500, decoded.tokens_used)
end)

T.test("round-trip booleans", function()
	local orig = { a = true, b = false }
	local decoded = json.decode(json.encode(orig))
	T.eq(true, decoded.a)
	T.eq(false, decoded.b)
end)

io.write("── mcp_json error cases ──\n")

T.test("decode empty string errors", function()
	local ok = pcall(json.decode, "")
	T.assert(not ok, "should error on empty string")
end)

T.test("decode invalid JSON errors", function()
	local ok = pcall(json.decode, "not json")
	T.assert(not ok, "should error on invalid JSON")
end)

T.test("decode trailing content errors", function()
	local ok = pcall(json.decode, '{"a":1} extra')
	T.assert(not ok, "should error on trailing content")
end)
