-- tests/test_scratchpad.lua
-- Tests for cross-agent scratchpad (report_note / read_notes MCP tools).

local T = _T

local tmpfile = vim.fn.tempname() .. "_scratchpad.jsonl"

-- Configure env before loading the module
vim.fn.setenv("DWIGHT_SCRATCHPAD_FILE", tmpfile)
vim.fn.setenv("DWIGHT_TASK_ID", "swarm-w1-t1")
package.loaded["dwight.mcp_server"] = nil
package.loaded["dwight.mcp_json"] = nil

vim.opt.rtp:prepend(vim.fn.getcwd())
local mcp = require("dwight.mcp_server")

--- Helper: reset scratchpad file
local function reset()
	os.remove(tmpfile)
end

io.write("── report_note ──\n")

T.test("report_note writes entry with correct fields", function()
	reset()
	local result = mcp._handle_report_note({ key = "interface_change", value = "Renamed AuthHandler to AuthService" })

	-- Check return text
	T.match("interface_change", result.content[1].text)

	-- Read back the file
	local f = io.open(tmpfile, "r")
	T.ok(f, "scratchpad file should exist")
	local line = f:read("*l")
	f:close()

	local entry = vim.json.decode(line)
	T.eq("swarm-w1-t1", entry.agent_id)
	T.eq("interface_change", entry.key)
	T.eq("Renamed AuthHandler to AuthService", entry.value)
	T.ok(entry.ts, "should have a timestamp")
	T.assert(type(entry.ts) == "number", "ts should be a number")
end)

T.test("report_note appends multiple entries", function()
	reset()
	mcp._handle_report_note({ key = "naming", value = "Use camelCase" })
	mcp._handle_report_note({ key = "bug_found", value = "Off-by-one in loop" })

	local count = 0
	local f = io.open(tmpfile, "r")
	for _ in f:lines() do
		count = count + 1
	end
	f:close()
	T.eq(2, count, "should have 2 lines")
end)

io.write("── read_notes ──\n")

T.test("read_notes returns all notes when no key filter", function()
	reset()
	mcp._handle_report_note({ key = "naming", value = "Use camelCase" })
	mcp._handle_report_note({ key = "bug_found", value = "Off-by-one" })

	local result = mcp._handle_read_notes({})
	local text = result.content[1].text
	T.match("naming", text)
	T.match("bug_found", text)
	T.match("Use camelCase", text)
	T.match("Off%-by%-one", text)
end)

T.test("read_notes filters by key", function()
	reset()
	mcp._handle_report_note({ key = "naming", value = "Use camelCase" })
	mcp._handle_report_note({ key = "bug_found", value = "Off-by-one" })
	mcp._handle_report_note({ key = "naming", value = "Prefix interfaces with I" })

	local result = mcp._handle_read_notes({ key = "naming" })
	local text = result.content[1].text
	T.match("Use camelCase", text)
	T.match("Prefix interfaces with I", text)
	-- Should NOT contain bug_found entries
	T.assert(not text:match("Off%-by%-one"), "should not contain bug_found notes")
end)

T.test("read_notes returns friendly message when file missing", function()
	reset()
	local result = mcp._handle_read_notes({})
	T.eq("No notes yet.", result.content[1].text)
end)

T.test("read_notes returns message when key not found", function()
	reset()
	mcp._handle_report_note({ key = "naming", value = "Use camelCase" })

	local result = mcp._handle_read_notes({ key = "nonexistent" })
	T.match("No notes found for key: nonexistent", result.content[1].text)
end)

T.test("read_notes ignores malformed lines", function()
	reset()
	-- Write mixed valid/invalid content
	local f = io.open(tmpfile, "w")
	f:write("not valid json\n")
	f:write(vim.json.encode({ agent_id = "t1", key = "good", value = "valid note", ts = 1000 }) .. "\n")
	f:write("{}\n") -- valid JSON but no key
	f:write(vim.json.encode({ agent_id = "t2", key = "also_good", value = "another note", ts = 2000 }) .. "\n")
	f:close()

	local result = mcp._handle_read_notes({})
	local text = result.content[1].text
	T.match("good", text)
	T.match("also_good", text)
	-- Count lines in output — should be exactly 2
	local line_count = 0
	for _ in text:gmatch("[^\n]+") do
		line_count = line_count + 1
	end
	T.eq(2, line_count, "should only have 2 valid note lines")
end)

-- Cleanup
reset()
