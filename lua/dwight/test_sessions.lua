-- tests/test_sessions.lua
-- Tests for unified sessions browser and cross-mode context bridge.

vim.opt.rtp:prepend(vim.fn.getcwd())

local T = _T

io.write("── sessions.list_all ──\n")

-- Mock project module for tests
local _orig_project = package.loaded["dwight.project"]

local function setup_mock_project(tmpdir)
	package.loaded["dwight.project"] = {
		is_initialized = function()
			return true
		end,
		dir = function()
			return tmpdir
		end,
	}
end

local function teardown_mock_project()
	if _orig_project then
		package.loaded["dwight.project"] = _orig_project
	else
		package.loaded["dwight.project"] = nil
	end
end

T.test("sessions.list_all parses agent format", function()
	local tmpdir = vim.fn.tempname()
	vim.fn.mkdir(tmpdir .. "/agent", "p")

	-- Write a mock agent session log
	local f = io.open(tmpdir .. "/agent/20260320-143200_test-session.md", "w")
	f:write(table.concat({
		"# Agent Session",
		"",
		"**Request:** implement auth flow",
		"**Time:** 2026-03-20 14:32:00 (45s)",
		"**Outcome:** ✅ SUCCESS",
		"**Cost:** ~$0.1200",
		"",
	}, "\n"))
	f:close()

	setup_mock_project(tmpdir)
	local sessions = require("dwight.sessions")
	-- Clear module cache for fresh load
	package.loaded["dwight.sessions"] = nil
	sessions = require("dwight.sessions")

	local all = sessions.list_all()

	T.ok(#all >= 1, "should find at least 1 session")
	local s = all[1]
	T.eq("agent", s.mode)
	T.eq("implement auth flow", s.request)
	T.ok(s.success, "should be success")
	T.eq(45, s.duration)
	T.ok(s.cost > 0.1, "cost should be parsed")

	teardown_mock_project()
	vim.fn.delete(tmpdir, "rf")
end)

T.test("sessions.list_all parses auto format", function()
	local tmpdir = vim.fn.tempname()
	vim.fn.mkdir(tmpdir .. "/auto-logs", "p")

	local f = io.open(tmpdir .. "/auto-logs/20260320-131000-failed.md", "w")
	f:write(table.concat({
		"# DwightAuto Session",
		"",
		"**Request:** refactor database",
		"**Result:** FAILED",
		"**Duration:** 192s",
		"**Cost:** ~$0.45",
		"",
	}, "\n"))
	f:close()

	setup_mock_project(tmpdir)
	package.loaded["dwight.sessions"] = nil
	local sessions = require("dwight.sessions")

	local all = sessions.list_all()
	T.ok(#all >= 1, "should find at least 1 session")
	local s = all[1]
	T.eq("auto", s.mode)
	T.eq("refactor database", s.request)
	T.ok(not s.success, "should be failed")
	T.eq(192, s.duration)

	teardown_mock_project()
	vim.fn.delete(tmpdir, "rf")
end)

T.test("sessions.list_all parses swarm format", function()
	local tmpdir = vim.fn.tempname()
	vim.fn.mkdir(tmpdir .. "/swarm-logs", "p")

	local f = io.open(tmpdir .. "/swarm-logs/20260320-120500-success.md", "w")
	f:write(table.concat({
		"# DwightSwarm Session",
		"",
		"**Request:** parallel test suite",
		"**Result:** SUCCESS",
		"**Duration:** 90s",
		"**Cost:** ~$0.30",
		"",
	}, "\n"))
	f:close()

	setup_mock_project(tmpdir)
	package.loaded["dwight.sessions"] = nil
	local sessions = require("dwight.sessions")

	local all = sessions.list_all()
	T.ok(#all >= 1, "should find at least 1 session")
	local s = all[1]
	T.eq("swarm", s.mode)
	T.eq("parallel test suite", s.request)
	T.ok(s.success, "should be success")
	T.eq(90, s.duration)

	teardown_mock_project()
	vim.fn.delete(tmpdir, "rf")
end)

T.test("sessions.list_all sorts by timestamp descending", function()
	local tmpdir = vim.fn.tempname()
	vim.fn.mkdir(tmpdir .. "/agent", "p")
	vim.fn.mkdir(tmpdir .. "/auto-logs", "p")

	local f1 = io.open(tmpdir .. "/agent/20260320-100000_old.md", "w")
	f1:write("# Agent Session\n\n**Request:** old task\n**Outcome:** ✅ SUCCESS\n")
	f1:close()

	local f2 = io.open(tmpdir .. "/auto-logs/20260320-150000-success.md", "w")
	f2:write("# DwightAuto Session\n\n**Request:** new task\n**Result:** SUCCESS\n**Duration:** 10s\n")
	f2:close()

	setup_mock_project(tmpdir)
	package.loaded["dwight.sessions"] = nil
	local sessions = require("dwight.sessions")

	local all = sessions.list_all()
	T.ok(#all >= 2, "should find 2 sessions")
	T.eq("new task", all[1].request, "newest should be first")
	T.eq("old task", all[2].request, "oldest should be last")

	teardown_mock_project()
	vim.fn.delete(tmpdir, "rf")
end)

io.write("── integration.write_last_session / read_last_session_context ──\n")

T.test("write_last_session round-trips through read_last_session_context", function()
	local tmpdir = vim.fn.tempname()
	vim.fn.mkdir(tmpdir, "p")

	setup_mock_project(tmpdir)
	package.loaded["dwight.integration"] = nil
	local integration = require("dwight.integration")

	integration.write_last_session({
		mode = "agent",
		request = "test round-trip",
		success = true,
		duration = 42,
		cost = 0.15,
		changed_features = { "auth", "users" },
		summary = "Did the thing",
	})

	local ctx = integration.read_last_session_context()
	T.ok(ctx ~= nil, "should return context")
	T.ok(ctx:match("agent"), "should contain mode")
	T.ok(ctx:match("test round%-trip"), "should contain request")
	T.ok(ctx:match("completed"), "should say completed")
	T.ok(ctx:match("auth"), "should contain changed features")

	teardown_mock_project()
	vim.fn.delete(tmpdir, "rf")
end)

T.test("read_last_session_context returns nil for stale data", function()
	local tmpdir = vim.fn.tempname()
	vim.fn.mkdir(tmpdir, "p")

	setup_mock_project(tmpdir)
	package.loaded["dwight.integration"] = nil
	local integration = require("dwight.integration")

	-- Write session with a very old timestamp
	local path = tmpdir .. "/last_session.json"
	local f = io.open(path, "w")
	f:write(vim.json.encode({
		mode = "auto",
		request = "old session",
		success = true,
		timestamp = os.time() - 10000, -- ~2.7 hours ago
		duration = 30,
	}))
	f:close()

	local ctx = integration.read_last_session_context()
	T.is_nil(ctx, "should return nil for stale session")

	teardown_mock_project()
	vim.fn.delete(tmpdir, "rf")
end)

T.test("read_last_session_context returns nil when no file exists", function()
	local tmpdir = vim.fn.tempname()
	vim.fn.mkdir(tmpdir, "p")

	setup_mock_project(tmpdir)
	package.loaded["dwight.integration"] = nil
	local integration = require("dwight.integration")

	local ctx = integration.read_last_session_context()
	T.is_nil(ctx, "should return nil when no file")

	teardown_mock_project()
	vim.fn.delete(tmpdir, "rf")
end)
