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
-- Language-aware test failure parsing
--------------------------------------------------------------------

--- Extract failed test names from test output using language-aware patterns.
--- @param output string Raw test output
--- @param lang string|nil Detected language (nil = try all patterns)
--- @return table List of failed test names
function M.parse_test_failures(output, lang)
	local failures = {}
	local seen = {}

	-- Pattern sets per language
	local patterns = {
		go = { "%-%-%-% FAIL:%s+(%S+)" },
		python = { "FAILED%s+(%S+)", "FAIL:%s+(%S+)", "ERROR%s+(%S+)" },
		javascript = {
			"[✕×]%s+(.+)$", -- Jest/Vitest failure markers
			"FAIL%s+(%S+)", -- Jest FAIL prefix
		},
		rust = { "test%s+(%S+)%s+%.%.%.%s+FAILED" },
	}

	-- Determine which pattern sets to use
	local sets_to_try = {}
	if lang and patterns[lang] then
		sets_to_try[#sets_to_try + 1] = patterns[lang]
	else
		-- Try all patterns
		for _, pats in pairs(patterns) do
			sets_to_try[#sets_to_try + 1] = pats
		end
	end

	for _, pats in ipairs(sets_to_try) do
		for _, pat in ipairs(pats) do
			for test_name in output:gmatch(pat) do
				local trimmed = vim.trim(test_name)
				if trimmed ~= "" and not seen[trimmed] then
					seen[trimmed] = true
					failures[#failures + 1] = trimmed
				end
			end
		end
	end

	return failures
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

	run_gate_cmd(lint_cmd, 60000, function(code, output)
		if code == 0 then
			status.append_hl("  ● Lint passed", "DwightOK")
			callback(true, output)
		else
			local issue_count = 0
			for _ in output:gmatch("\n") do
				issue_count = issue_count + 1
			end
			status.append_hl(
				string.format("  ✗ Lint failed (%s, ~%d issue(s))", lint_bin or "linter", issue_count),
				"DwightFail"
			)
			-- Fold the lint output
			local log_lines = {}
			for line in output:gmatch("[^\n]+") do
				log_lines[#log_lines + 1] = line
				if #log_lines >= 8 then
					log_lines[#log_lines + 1] = "..."
					break
				end
			end
			if #log_lines > 0 then
				status.append_fold("    ▸ Lint output", log_lines)
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

	run_gate_cmd(test_cmd, 120000, function(code, output)
		if code == 0 then
			status.append_hl("  ● Tests passed", "DwightOK")
			callback(true, output)
		else
			-- Detect language for appropriate failure pattern matching
			local lang = nil
			pcall(function()
				lang = agentic.detect_language()
			end)

			local all_failures = M.parse_test_failures(output, lang)
			local new_failures = {}
			for _, test_name in ipairs(all_failures) do
				if not (baseline_failures and baseline_failures[test_name]) then
					new_failures[#new_failures + 1] = test_name
				end
			end

			if #new_failures == 0 and #all_failures > 0 then
				status.append_hl(
					string.format("  ● Tests passed (%d pre-existing failure(s) ignored)", #all_failures),
					"DwightWarn"
				)
				callback(true, output)
			else
				status.append_hl("  ✗ Tests failed (exit " .. code .. ")", "DwightFail")
				if #new_failures > 0 then
					for _, name in ipairs(new_failures) do
						status.append_hl("    └ " .. name, "DwightFail")
					end
				end
				-- Fold the test output
				local log_lines = {}
				for line in output:gmatch("[^\n]+") do
					log_lines[#log_lines + 1] = line
					if #log_lines >= 10 then
						log_lines[#log_lines + 1] = "..."
						break
					end
				end
				if #log_lines > 0 then
					status.append_fold("    ▸ Test output", log_lines)
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

	run_gate_cmd(cov_info.cmd, 180000, function(code, output)
		local new_coverage = cov_info.parse_total(output)
		if not new_coverage then
			status.append_hl("  ● Coverage skipped (couldn't parse)", "DwightWarn")
			callback(true, output)
			return
		end

		local delta = new_coverage - baseline_coverage
		if delta >= -1.0 then
			status.append_hl(string.format("  ● Coverage: %.1f%% (%+.1f%%)", new_coverage, delta), "DwightOK")
			callback(true, output)
		else
			status.append_hl(
				string.format(
					"  ✗ Coverage dropped: %.1f%% → %.1f%% (%.1f%%)",
					baseline_coverage,
					new_coverage,
					-delta
				),
				"DwightFail"
			)
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

	-- Step 1: Build
	run_gate_cmd(smoke.build, 60000, function(build_code, build_output)
		if build_code ~= 0 then
			status.append_hl("  ✗ Smoke failed: build error", "DwightFail")
			local log_lines = {}
			for line in build_output:gmatch("[^\n]+") do
				log_lines[#log_lines + 1] = line
				if #log_lines >= 8 then
					log_lines[#log_lines + 1] = "..."
					break
				end
			end
			if #log_lines > 0 then
				status.append_fold("    ▸ Build output", log_lines)
			end
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
			run_gate_cmd(smoke.run, 15000, function(run_code, run_output)
				if smoke.cleanup then
					pcall(function()
						vim.fn.system(smoke.cleanup)
					end)
				end

				local panicked = run_output:match("panic:")
					or run_output:match("SIGSEGV")
					or run_output:match("fatal error:")
					or run_output:match("Traceback %(most recent")
					or run_output:match("Error: Cannot find module")
				if panicked then
					status.append_hl("  ✗ Smoke failed: app crashed on startup", "DwightFail")
					local log_lines = {}
					for line in run_output:gmatch("[^\n]+") do
						log_lines[#log_lines + 1] = line
						if #log_lines >= 10 then
							log_lines[#log_lines + 1] = "..."
							break
						end
					end
					if #log_lines > 0 then
						status.append_fold("    ▸ Crash output", log_lines)
					end
					callback(false, run_output)
				else
					status.append_hl("  ● Smoke passed (builds and starts)", "DwightOK")
					callback(true, run_output)
				end
			end)
		else
			if smoke.cleanup then
				pcall(function()
					vim.fn.system(smoke.cleanup)
				end)
			end
			status.append_hl("  ● Smoke passed (builds)", "DwightOK")
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
	-- Open a fold for gate details
	status.append("  ▸ Verification ▸{{{")

	-- Define the pipeline as a list of gates.
	-- Each entry: { name, fn, args_after_status_and_callback }
	local pipeline = {
		{ name = "lint", fn = M.lint, args = {} },
		{ name = "tests", fn = M.tests, args = { baseline_failures } },
		{ name = "coverage", fn = M.coverage, args = { baseline_coverage } },
		{ name = "smoke", fn = M.smoke, args = {} },
	}

	local function run_next(idx)
		if idx > #pipeline then
			-- All gates passed
			status.append("  ▸}}}")
			status.append_hl("  ● Verification passed", "DwightOK")
			callback(true, "")
			return
		end

		local gate = pipeline[idx]
		gate.fn(status, function(ok, output)
			if not ok then
				status.append("  ▸}}}")
				status.append_hl("  ✗ Verification failed", "DwightFail")
				callback(false, output)
				return
			end
			run_next(idx + 1)
		end, unpack(gate.args))
	end

	run_next(1)
end

return M
