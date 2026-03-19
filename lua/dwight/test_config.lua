-- tests/test_config.lua
-- Tests for config.lua (validation, migration, unknown keys) and errors.lua.

vim.opt.rtp:prepend(vim.fn.getcwd())

local config = require("dwight.config")
local errors = require("dwight.errors")
local T = _T

--------------------------------------------------------------------
-- errors.try
--------------------------------------------------------------------

io.write("── errors.try ──\n")

T.test("try: success returns result", function()
	local result = errors.try("test", function()
		return 42
	end)
	T.eq(42, result)
end)

T.test("try: failure returns nil, no propagation", function()
	local result = errors.try("test", function()
		error("boom")
	end)
	T.is_nil(result)
end)

T.test("try: success with nil return", function()
	local result = errors.try("test", function()
		return nil
	end)
	T.is_nil(result)
end)

--------------------------------------------------------------------
-- config.validate
--------------------------------------------------------------------

io.write("── config.validate ──\n")

T.test("validate: valid config produces 0 messages", function()
	local cfg = {
		backend = "claude_code",
		timeout = 120000,
		agentic_opts = {
			cli_timeout = 600,
			max_output_tokens = 64000,
			reflection = false,
		},
		swarm_opts = {
			on_partial_failure = "continue",
			max_parallel = 3,
		},
	}
	local msgs = config.validate(cfg)
	T.len(0, msgs, "valid config should produce 0 messages")
end)

T.test("validate: invalid backend produces ERROR", function()
	local msgs = config.validate({ backend = "nonexistent" })
	T.ok(#msgs > 0, "should have messages")
	T.eq("ERROR", msgs[1].level)
	T.match("Unknown backend", msgs[1].msg)
end)

T.test("validate: bad timeout produces WARN", function()
	local msgs = config.validate({ timeout = -1 })
	T.ok(#msgs > 0, "should have messages")
	T.eq("WARN", msgs[1].level)
	T.match("timeout", msgs[1].msg)
end)

T.test("validate: string timeout produces WARN", function()
	local msgs = config.validate({ timeout = "fast" })
	T.ok(#msgs > 0)
	T.eq("WARN", msgs[1].level)
end)

T.test("validate: bad on_partial_failure produces WARN", function()
	local msgs = config.validate({ swarm_opts = { on_partial_failure = "ignore" } })
	T.ok(#msgs > 0)
	T.eq("WARN", msgs[1].level)
	T.match("on_partial_failure", msgs[1].msg)
end)

T.test("validate: non-boolean reflection produces WARN", function()
	local msgs = config.validate({ agentic_opts = { reflection = "yes" } })
	T.ok(#msgs > 0)
	T.eq("WARN", msgs[1].level)
	T.match("reflection", msgs[1].msg)
end)

T.test("validate: bad max_parallel produces WARN", function()
	local msgs = config.validate({ swarm_opts = { max_parallel = 0 } })
	T.ok(#msgs > 0)
	T.eq("WARN", msgs[1].level)
	T.match("max_parallel", msgs[1].msg)
end)

T.test("validate: bad cli_timeout produces WARN", function()
	local msgs = config.validate({ agentic_opts = { cli_timeout = -5 } })
	T.ok(#msgs > 0)
	T.eq("WARN", msgs[1].level)
	T.match("cli_timeout", msgs[1].msg)
end)

T.test("validate: nil agentic_opts is fine", function()
	local msgs = config.validate({ agentic_opts = nil })
	T.len(0, msgs)
end)

--------------------------------------------------------------------
-- config.migrate_deprecated
--------------------------------------------------------------------

io.write("── config.migrate_deprecated ──\n")

T.test("migrate: claude_code_timeout -> cli_timeout", function()
	local cfg = { agentic_opts = { claude_code_timeout = 300 } }
	local msgs = config.migrate_deprecated(cfg)
	T.eq(300, cfg.agentic_opts.cli_timeout, "should migrate value")
	T.ok(#msgs > 0, "should produce a warning")
	T.match("deprecated", msgs[1].msg)
end)

T.test("migrate: both set, cli_timeout wins", function()
	local cfg = { agentic_opts = { cli_timeout = 500, claude_code_timeout = 300 } }
	local msgs = config.migrate_deprecated(cfg)
	T.eq(500, cfg.agentic_opts.cli_timeout, "cli_timeout should be unchanged")
	T.ok(#msgs > 0)
	T.match("precedence", msgs[1].msg)
end)

T.test("migrate: nil agentic_opts is safe", function()
	local cfg = {}
	local msgs = config.migrate_deprecated(cfg)
	T.len(0, msgs)
end)

T.test("migrate: no deprecated keys is clean", function()
	local cfg = { agentic_opts = { cli_timeout = 600 } }
	local msgs = config.migrate_deprecated(cfg)
	T.len(0, msgs)
end)

--------------------------------------------------------------------
-- config.find_unknown_keys
--------------------------------------------------------------------

io.write("── config.find_unknown_keys ──\n")

T.test("unknown keys: clean opts produce 0 messages", function()
	local opts = { backend = "claude_code", timeout = 120000 }
	local msgs = config.find_unknown_keys(opts)
	T.len(0, msgs)
end)

T.test("unknown keys: unknown top-level key detected", function()
	local opts = { backendd = "claude_code" }
	local msgs = config.find_unknown_keys(opts)
	T.ok(#msgs > 0)
	T.match("backendd", msgs[1].msg)
	T.match("typo", msgs[1].msg)
end)

T.test("unknown keys: unknown nested agentic_opts key", function()
	local opts = { agentic_opts = { cli_timeoutt = 600 } }
	local msgs = config.find_unknown_keys(opts)
	T.ok(#msgs > 0)
	T.match("cli_timeoutt", msgs[1].msg)
end)

T.test("unknown keys: unknown nested swarm_opts key", function()
	local opts = { swarm_opts = { max_parallell = 3 } }
	local msgs = config.find_unknown_keys(opts)
	T.ok(#msgs > 0)
	T.match("max_parallell", msgs[1].msg)
end)

T.test("unknown keys: nil opts is safe", function()
	local msgs = config.find_unknown_keys(nil)
	T.len(0, msgs)
end)

T.test("unknown keys: extensible tables (languages, modes) not flagged", function()
	local opts = { languages = { java = {} }, modes = { deploy = {} } }
	local msgs = config.find_unknown_keys(opts)
	T.len(0, msgs)
end)

--------------------------------------------------------------------
-- config.check_backend_binary
--------------------------------------------------------------------

io.write("── config.check_backend_binary ──\n")

T.test("check_backend_binary: existing binary produces no warning", function()
	-- "ls" should exist on any system
	local msgs = config.check_backend_binary({ backend = "claude_code", claude_code_bin = "ls" })
	T.len(0, msgs)
end)

T.test("check_backend_binary: missing binary produces warning", function()
	local msgs = config.check_backend_binary({
		backend = "claude_code",
		claude_code_bin = "nonexistent_binary_12345",
	})
	T.ok(#msgs > 0)
	T.match("not found", msgs[1].msg)
end)
