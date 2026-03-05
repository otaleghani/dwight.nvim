-- tests/test_agentic.lua
-- Tests for agentic.lua helpers: language detection, commands, backend registry.

vim.opt.rtp:prepend(vim.fn.getcwd())

local agentic = require("dwight.agentic")
local T = _T

io.write("── agentic.get_test_command ──\n")

T.test("go test command", function()
	T.eq("go test ./... -count=1", agentic.get_test_command("go"))
end)

T.test("node test command", function()
	T.eq("npm test", agentic.get_test_command("node"))
end)

T.test("rust test command", function()
	T.eq("cargo test", agentic.get_test_command("rust"))
end)

T.test("python test command", function()
	T.eq("python -m pytest", agentic.get_test_command("python"))
end)

T.test("unknown language returns nil", function()
	T.is_nil(agentic.get_test_command("cobol"))
end)

io.write("── agentic.get_build_command ──\n")

T.test("go build command", function()
	T.eq("go build ./...", agentic.get_build_command("go"))
end)

T.test("node build command", function()
	T.eq("npx tsc --noEmit", agentic.get_build_command("node"))
end)

T.test("rust build command", function()
	T.eq("cargo check", agentic.get_build_command("rust"))
end)

T.test("python build command", function()
	T.eq("python -m py_compile", agentic.get_build_command("python"))
end)

io.write("── agentic.available_backends ──\n")

T.test("lists all backends", function()
	local backends = agentic.available_backends()
	T.assert(#backends >= 3, "should have at least 3 backends")

	-- Check expected backends exist
	local set = {}
	for _, b in ipairs(backends) do
		set[b] = true
	end
	T.ok(set.claude_code, "should include claude_code")
	T.ok(set.codex, "should include codex")
	T.ok(set.gemini, "should include gemini")
end)

T.test("backends are sorted", function()
	local backends = agentic.available_backends()
	for i = 2, #backends do
		T.assert(
			backends[i] >= backends[i - 1],
			"backends should be sorted: " .. backends[i - 1] .. " <= " .. backends[i]
		)
	end
end)

io.write("── agentic.detect_language ──\n")

T.test("detect_language returns a string", function()
	local lang = agentic.detect_language()
	T.assert(type(lang) == "string", "should return a string")
end)

io.write("── agentic.abort (no-op when idle) ──\n")

T.test("abort when nothing running", function()
	-- Should not error when no active process
	agentic.abort()
	T.is_nil(agentic._active_handle)
	T.is_nil(agentic._active_pid)
	T.is_nil(agentic._active_backend)
end)

io.write("── agentic.run (validation) ──\n")

T.test("run requires on_complete", function()
	local ok, err = pcall(agentic.run, { task = "test" })
	T.eq(false, ok, "should error without on_complete")
	T.match("on_complete", tostring(err))
end)

io.write("── agentic.get_lint_command ──\n")

T.test("go lint returns a command or nil", function()
	local cmd, bin = agentic.get_lint_command("go")
	-- Either golangci-lint or go vet (go is always in PATH in a Go project)
	if cmd then
		T.assert(type(cmd) == "string", "should be a string")
		T.assert(type(bin) == "string", "bin should be a string")
		T.assert(cmd:match("lint") or cmd:match("vet"), "should be a lint or vet command")
	end
	-- nil is also valid (no linter installed)
end)

T.test("unknown language returns nil", function()
	local cmd, bin = agentic.get_lint_command("cobol")
	T.is_nil(cmd, "unknown language should return nil")
	T.is_nil(bin)
end)

io.write("── agentic.get_vet_command ──\n")

T.test("go vet command", function()
	T.eq("go vet ./...", agentic.get_vet_command("go"))
end)

T.test("node vet is tsc", function()
	T.eq("npx tsc --noEmit", agentic.get_vet_command("node"))
end)

T.test("rust vet is cargo check", function()
	T.eq("cargo check", agentic.get_vet_command("rust"))
end)

T.test("python vet returns nil", function()
	T.is_nil(agentic.get_vet_command("python"))
end)

io.write("── agentic.get_coverage_command ──\n")

T.test("go coverage returns command and parser", function()
	local cov = agentic.get_coverage_command("go")
	if cov then
		T.assert(type(cov.cmd) == "string", "should have cmd")
		T.match("coverprofile", cov.cmd, "should use coverprofile flag")
		T.assert(type(cov.parse_total) == "function", "should have parse_total function")
	end
end)

T.test("unknown language returns nil", function()
	T.is_nil(agentic.get_coverage_command("cobol"))
end)

io.write("── agentic.get_smoke_command ──\n")

T.test("smoke command returns table or nil", function()
	local smoke = agentic.get_smoke_command("go")
	if smoke then
		T.assert(type(smoke.build) == "string", "should have build command")
	end
	-- nil is valid (no main package)
end)

T.test("unknown language returns nil", function()
	T.is_nil(agentic.get_smoke_command("cobol"))
end)
