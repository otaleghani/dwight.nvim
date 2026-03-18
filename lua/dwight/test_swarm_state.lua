-- tests/test_swarm_state.lua
-- Tests for swarm state save/load/clear.

vim.opt.rtp:prepend(vim.fn.getcwd())

-- Monkey-patch dwight.project to use a temp directory
local tmpdir = vim.fn.tempname()
vim.fn.mkdir(tmpdir, "p")
package.loaded["dwight.project"] = {
	is_initialized = function()
		return true
	end,
	dir = function()
		return tmpdir
	end,
}

local state = require("dwight.swarm.state")
local T = _T

io.write("── swarm.state ──\n")

T.test("save and load round-trip", function()
	local data = {
		request = "add authentication",
		waves = {
			{
				wave = 1,
				tasks = {
					{ order = 1, title = "Auth module", description = "build it", files = { "auth.go" } },
				},
			},
		},
		current_wave = 1,
		started = 1000000,
		wave_results = {},
	}
	state.save(data)
	local loaded = state.load()
	T.ok(loaded, "should load saved state")
	T.eq("add authentication", loaded.request)
	T.eq(1, loaded.current_wave)
	T.eq(1, #loaded.waves)
	T.eq("Auth module", loaded.waves[1].tasks[1].title)
end)

T.test("clear removes state", function()
	state.save({ request = "test" })
	T.ok(state.load(), "should exist before clear")
	state.clear()
	T.is_nil(state.load(), "should be nil after clear")
end)

T.test("load returns nil when no state", function()
	state.clear()
	T.is_nil(state.load())
end)

T.test("save with failed flag", function()
	state.save({
		request = "something",
		waves = {},
		current_wave = 2,
		failed = true,
		error = "merge conflict",
	})
	local loaded = state.load()
	T.ok(loaded.failed, "should have failed flag")
	T.eq("merge conflict", loaded.error)
	state.clear()
end)

T.test("save with paused flag", function()
	state.save({
		request = "something",
		waves = {},
		current_wave = 1,
		paused = true,
	})
	local loaded = state.load()
	T.ok(loaded.paused, "should have paused flag")
	state.clear()
end)

-- Cleanup temp dir
pcall(function()
	vim.fn.delete(tmpdir, "rf")
end)
