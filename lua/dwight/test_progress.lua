-- tests/test_progress.lua
-- Tests for progress.lua: Lua binary detection, plugin dir resolution, poll dispatching.

vim.opt.rtp:prepend(vim.fn.getcwd())

local progress = require("dwight.progress")
local T = _T

io.write("── progress.detect_lua_binary ──\n")

T.test("detect_lua_binary returns string or nil", function()
	local result = progress.detect_lua_binary()
	T.assert(result == nil or type(result) == "string", "expected string or nil, got " .. type(result))
end)

io.write("── progress._resolve_plugin_dir ──\n")

T.test("_resolve_plugin_dir finds plugin root", function()
	local dir = progress._resolve_plugin_dir()
	T.assert(type(dir) == "string", "expected string")
	-- The resolved dir should contain lua/dwight/progress.lua
	local test_path = dir .. "/lua/dwight/progress.lua"
	T.eq(1, vim.fn.filereadable(test_path), "plugin dir does not contain progress.lua: " .. dir)
end)

io.write("── progress._poll dispatch ──\n")

T.test("_poll dispatches events to registered callbacks", function()
	-- Set up a temp file
	local tmpfile = vim.fn.tempname() .. ".jsonl"
	progress._file_path = tmpfile
	progress._file_offset = 0

	-- Write test events
	local f = io.open(tmpfile, "w")
	f:write(vim.json.encode({ task_id = "t1", phase = "coding", message = "writing code" }) .. "\n")
	f:write(vim.json.encode({ task_id = "t2", phase = "testing", message = "running tests" }) .. "\n")
	f:close()

	-- Register callbacks
	local t1_events = {}
	local t2_events = {}
	progress.register("t1", function(ev)
		t1_events[#t1_events + 1] = ev
	end)
	progress.register("t2", function(ev)
		t2_events[#t2_events + 1] = ev
	end)

	-- Poll
	progress._poll()

	T.eq(1, #t1_events, "expected 1 event for t1")
	T.eq("coding", t1_events[1].phase)
	T.eq("writing code", t1_events[1].message)

	T.eq(1, #t2_events, "expected 1 event for t2")
	T.eq("testing", t2_events[1].phase)

	-- Cleanup
	progress.unregister("t1")
	progress.unregister("t2")
	progress._file_path = nil
	progress._file_offset = 0
	os.remove(tmpfile)
end)

T.test("_poll tracks offset — no re-read on second poll", function()
	local tmpfile = vim.fn.tempname() .. ".jsonl"
	progress._file_path = tmpfile
	progress._file_offset = 0

	local f = io.open(tmpfile, "w")
	f:write(vim.json.encode({ task_id = "t1", phase = "coding", message = "first" }) .. "\n")
	f:close()

	local events = {}
	progress.register("t1", function(ev)
		events[#events + 1] = ev
	end)

	progress._poll()
	T.eq(1, #events, "first poll")

	-- Poll again without new data
	progress._poll()
	T.eq(1, #events, "second poll should not re-dispatch")

	-- Append new data
	f = io.open(tmpfile, "a")
	f:write(vim.json.encode({ task_id = "t1", phase = "testing", message = "second" }) .. "\n")
	f:close()

	progress._poll()
	T.eq(2, #events, "third poll should get new event")
	T.eq("testing", events[2].phase)

	-- Cleanup
	progress.unregister("t1")
	progress._file_path = nil
	progress._file_offset = 0
	os.remove(tmpfile)
end)

T.test("_poll ignores malformed lines", function()
	local tmpfile = vim.fn.tempname() .. ".jsonl"
	progress._file_path = tmpfile
	progress._file_offset = 0

	local f = io.open(tmpfile, "w")
	f:write("not valid json\n")
	f:write(vim.json.encode({ task_id = "t1", phase = "done", message = "ok" }) .. "\n")
	f:write("{}\n") -- valid JSON but no task_id
	f:close()

	local events = {}
	progress.register("t1", function(ev)
		events[#events + 1] = ev
	end)

	progress._poll()
	T.eq(1, #events, "should only dispatch valid events with task_id")
	T.eq("done", events[1].phase)

	-- Cleanup
	progress.unregister("t1")
	progress._file_path = nil
	progress._file_offset = 0
	os.remove(tmpfile)
end)

io.write("── progress.has_registrations ──\n")

T.test("has_registrations tracks state", function()
	T.assert(not progress.has_registrations(), "should start empty")
	progress.register("test", function() end)
	T.assert(progress.has_registrations(), "should have registration")
	progress.unregister("test")
	T.assert(not progress.has_registrations(), "should be empty after unregister")
end)
