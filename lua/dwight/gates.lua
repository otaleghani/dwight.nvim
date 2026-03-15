-- dwight/gates.lua
-- Verification gates for DwightAuto: lint, tests, coverage, smoke.
-- Extracted from auto.lua for modularity and independent testing.

local M = {}

local uv = vim.loop or vim.uv

--------------------------------------------------------------------
-- Shell command runner with timeout
--------------------------------------------------------------------

local function run_gate_cmd(cmd, timeout_ms, callback)
	local stdout_chunks = {}
	local stderr_chunks = {}
	local stdout_pipe = uv.new_pipe(false)
	local stderr_pipe = uv.new_pipe(false)
	local done = false

	local handle
	handle = uv.spawn("sh", {
		args = { "-c", cmd },
		stdio = { nil, stdout_pipe, stderr_pipe },
		cwd = vim.fn.getcwd(),
	}, function(code)
		if done then
			return
		end
		done = true
		if stdout_pipe then
			pcall(function()
				stdout_pipe:close()
			end)
		end
		if stderr_pipe then
			pcall(function()
				stderr_pipe:close()
			end)
		end
		if handle then
			pcall(function()
				handle:close()
			end)
		end

		vim.schedule(function()
			local out = table.concat(stdout_chunks, "") .. table.concat(stderr_chunks, "")
			callback(code, out)
		end)
	end)

	if not handle then
		callback(-1, "failed to spawn: " .. cmd)
		return
	end

	-- Timeout
	local timer = uv.new_timer()
	timer:start(timeout_ms or 120000, 0, function()
		timer:close()
		if not done then
			done = true
			pcall(function()
				handle:kill("sigkill")
			end)
			vim.schedule(function()
				callback(-1, "timeout after " .. (timeout_ms / 1000) .. "s")
			end)
		end
	end)

	stdout_pipe:read_start(function(err, data)
		if not err and data then
			stdout_chunks[#stdout_chunks + 1] = data
		end
	end)
	stderr_pipe:read_start(function(err, data)
		if not err and data then
			stderr_chunks[#stderr_chunks + 1] = data
		end
	end)
end

--------------------------------------------------------------------
-- Individual gates
--------------------------------------------------------------------

--- Run the lint gate: project linter must pass (or be unavailable -> skip).
--- callback(passed, output)
function M.lint(status, callback)
	local agentic = require("dwight.agentic")
	local lint_cmd, lint_bin = agentic.get_lint_command()

	if not lint_cmd then
		callback(true, "") -- no linter -> skip
		return
	end

	status.append(string.format("  Lint: %s", lint_cmd))

	run_gate_cmd(lint_cmd, 60000, function(code, output)
		if code == 0 then
			status.append("  Lint gate passed")
			callback(true, output)
		else
			-- Count issues
			local issue_count = 0
			for _ in output:gmatch("\n") do
				issue_count = issue_count + 1
			end
			status.append(string.format("  FAILED Lint gate (%s, ~%d issue(s))", lint_bin or "linter", issue_count))
			local n = 0
			for line in output:gmatch("[^\n]+") do
				status.append("    " .. line)
				n = n + 1
				if n >= 8 then
					status.append("    ...")
					break
				end
			end
			callback(false, output)
		end
	end)
end

--- Run the unit test gate with baseline failure filtering.
--- callback(passed, output)
function M.tests(status, callback, baseline_failures)
	local agentic = require("dwight.agentic")
	local test_cmd = agentic.get_test_command()

	if not test_cmd then
		callback(true, "") -- no test command -> skip
		return
	end

	status.append(string.format("  Tests: %s", test_cmd))

	run_gate_cmd(test_cmd, 120000, function(code, output)
		if code == 0 then
			status.append("  Test gate passed")
			callback(true, output)
		else
			-- Check if all failures are pre-existing (baseline) failures
			local new_failures = {}
			local all_failures = {}
			for test_name in output:gmatch("%-%-%-% FAIL:%s+(%S+)") do
				all_failures[#all_failures + 1] = test_name
				if not (baseline_failures and baseline_failures[test_name]) then
					new_failures[#new_failures + 1] = test_name
				end
			end

			if #new_failures == 0 and #all_failures > 0 then
				status.append(
					string.format(
						"  WARN: Test gate: %d pre-existing failure(s), no NEW failures -- passing",
						#all_failures
					)
				)
				callback(true, output)
			else
				status.append("  FAILED Test gate (exit " .. code .. ")")
				if #new_failures > 0 then
					status.append(string.format("  %d NEW test failure(s):", #new_failures))
					for _, name in ipairs(new_failures) do
						status.append("    - " .. name)
					end
				end
				local n = 0
				for line in output:gmatch("[^\n]+") do
					status.append("    " .. line)
					n = n + 1
					if n >= 10 then
						status.append("    ...")
						break
					end
				end
				callback(false, output)
			end
		end
	end)
end

--- Run coverage delta check: coverage must not decrease.
--- baseline_coverage: number (percentage) captured before the run started.
--- callback(passed, output)
function M.coverage(status, callback, baseline_coverage)
	if not baseline_coverage then
		callback(true, "") -- no baseline -> skip
		return
	end

	local agentic = require("dwight.agentic")
	local cov_info = agentic.get_coverage_command()
	if not cov_info then
		callback(true, "") -- no coverage tool -> skip
		return
	end

	status.append(string.format("  Coverage: %s", cov_info.cmd))

	run_gate_cmd(cov_info.cmd, 180000, function(code, output)
		-- Coverage command may "fail" if tests fail, but we already tested above.
		-- Parse coverage regardless of exit code.
		local new_coverage = cov_info.parse_total(output)
		if not new_coverage then
			status.append("  WARN: Coverage gate: couldn't parse coverage -- skipping")
			callback(true, output)
			return
		end

		local delta = new_coverage - baseline_coverage
		if delta >= -1.0 then -- allow 1% tolerance for flaky coverage measurement
			status.append(
				string.format(
					"  Coverage gate passed: %.1f%% (baseline %.1f%%, delta %+.1f%%)",
					new_coverage,
					baseline_coverage,
					delta
				)
			)
			callback(true, output)
		else
			status.append(
				string.format(
					"  FAILED Coverage gate: %.1f%% -> %.1f%% (dropped %.1f%%)",
					baseline_coverage,
					new_coverage,
					-delta
				)
			)
			status.append("     Agent's changes reduced test coverage. New code may be untested.")
			callback(false, output)
		end
	end)
end

--- Run smoke test: build the app and verify it starts.
--- callback(passed, output)
function M.smoke(status, callback)
	local agentic = require("dwight.agentic")
	local smoke = agentic.get_smoke_command()

	if not smoke then
		callback(true, "") -- no entry point -> skip
		return
	end

	status.append(string.format("  Smoke: %s", smoke.build))

	-- Step 1: Build
	run_gate_cmd(smoke.build, 60000, function(build_code, build_output)
		if build_code ~= 0 then
			status.append("  FAILED Smoke gate: build failed")
			local n = 0
			for line in build_output:gmatch("[^\n]+") do
				status.append("    " .. line)
				n = n + 1
				if n >= 8 then
					status.append("    ...")
					break
				end
			end
			-- Cleanup
			if smoke.cleanup then
				pcall(function()
					vim.fn.system(smoke.cleanup)
				end)
			end
			callback(false, build_output)
			return
		end

		-- Step 2: Run (quick start check)
		if smoke.run then
			status.append(string.format("  Smoke: %s", smoke.run))
			run_gate_cmd(smoke.run, 15000, function(run_code, run_output)
				-- Cleanup
				if smoke.cleanup then
					pcall(function()
						vim.fn.system(smoke.cleanup)
					end)
				end

				-- run_code may be non-zero for --help (some CLIs exit 1 for --help)
				-- We mainly care that it didn't crash/panic
				local panicked = run_output:match("panic:")
					or run_output:match("SIGSEGV")
					or run_output:match("fatal error:")
					or run_output:match("Traceback %(most recent")
					or run_output:match("Error: Cannot find module")
				if panicked then
					status.append("  FAILED Smoke gate: app panicked/crashed on startup")
					local n = 0
					for line in run_output:gmatch("[^\n]+") do
						status.append("    " .. line)
						n = n + 1
						if n >= 10 then
							status.append("    ...")
							break
						end
					end
					callback(false, run_output)
				else
					status.append("  Smoke gate passed (app builds and starts)")
					callback(true, run_output)
				end
			end)
		else
			-- No run command, build passing is enough
			if smoke.cleanup then
				pcall(function()
					vim.fn.system(smoke.cleanup)
				end)
			end
			status.append("  Smoke gate passed (builds successfully)")
			callback(true, build_output)
		end
	end)
end

--------------------------------------------------------------------
-- Full pipeline
--------------------------------------------------------------------

--- Full verification pipeline: lint -> tests -> coverage -> smoke.
--- Runs gates sequentially, stops at first failure.
--- callback(passed: boolean, output: string)
function M.run_all(status, callback, baseline_failures, baseline_coverage)
	status.append("  Verification pipeline")

	-- Gate 1: Lint
	M.lint(status, function(lint_ok, lint_out)
		if not lint_ok then
			callback(false, lint_out)
			return
		end

		-- Gate 2: Unit tests
		M.tests(status, function(test_ok, test_out)
			if not test_ok then
				callback(false, test_out)
				return
			end

			-- Gate 3: Coverage delta
			M.coverage(status, function(cov_ok, cov_out)
				if not cov_ok then
					callback(false, cov_out)
					return
				end

				-- Gate 4: Smoke test
				M.smoke(status, function(smoke_ok, smoke_out)
					if smoke_ok then
						status.append("  All verification gates passed")
					end
					callback(smoke_ok, smoke_out)
				end)
			end, baseline_coverage)
		end, baseline_failures)
	end)
end

return M
