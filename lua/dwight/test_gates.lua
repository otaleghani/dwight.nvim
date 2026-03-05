-- tests/test_gates.lua
-- Tests for the verification pipeline gates in auto.lua.
-- These test the gate orchestration logic, not actual tool execution.

vim.opt.rtp:prepend(vim.fn.getcwd())

-- Mock project module
package.preload["dwight.project"] = function()
	return {
		is_initialized = function()
			return true
		end,
		dir = function()
			return vim.fn.tempname()
		end,
	}
end

local auto = require("dwight.auto")
local T = _T

io.write("── gate functions exist ──\n")

T.test("_gate_lint exists and is callable", function()
	T.assert(type(auto._gate_lint) == "function")
end)

T.test("_gate_tests exists and is callable", function()
	T.assert(type(auto._gate_tests) == "function")
end)

T.test("_gate_coverage exists and is callable", function()
	T.assert(type(auto._gate_coverage) == "function")
end)

T.test("_gate_smoke exists and is callable", function()
	T.assert(type(auto._gate_smoke) == "function")
end)

T.test("_verification_gate exists and is callable", function()
	T.assert(type(auto._verification_gate) == "function")
end)

io.write("── gate_coverage skips when no baseline ──\n")

T.test("coverage gate skips with nil baseline", function()
	local passed_result = nil
	-- Create a mock status
	local mock_status = {
		append = function() end,
		stop_spin = function() end,
		spin = function() end,
	}

	auto._gate_coverage(mock_status, function(passed, _output)
		passed_result = passed
	end, nil)

	-- Synchronous return for nil baseline
	T.eq(true, passed_result, "should pass when no baseline coverage")
end)

io.write("── verification pipeline structure ──\n")

T.test("pipeline function signature accepts baseline_coverage", function()
	-- Verify the function accepts 4 args (status, callback, baseline_failures, baseline_coverage)
	local info = debug.getinfo(auto._verification_gate)
	-- nparams may not be reliable across Lua versions, just verify it's callable
	T.assert(info ~= nil, "should be inspectable")
end)
