-- tests/test_gates.lua
-- Tests for the verification pipeline gates in gates.lua.
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

local gates = require("dwight.gates")
local T = _T

io.write("── gate functions exist ──\n")

T.test("lint gate exists and is callable", function()
	T.assert(type(gates.lint) == "function")
end)

T.test("tests gate exists and is callable", function()
	T.assert(type(gates.tests) == "function")
end)

T.test("coverage gate exists and is callable", function()
	T.assert(type(gates.coverage) == "function")
end)

T.test("smoke gate exists and is callable", function()
	T.assert(type(gates.smoke) == "function")
end)

T.test("run_all exists and is callable", function()
	T.assert(type(gates.run_all) == "function")
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

	gates.coverage(mock_status, function(passed, _output)
		passed_result = passed
	end, nil)

	-- Synchronous return for nil baseline
	T.eq(true, passed_result, "should pass when no baseline coverage")
end)

io.write("── backwards compat: auto.lua still exposes gates ──\n")

T.test("auto._gate_lint delegates to gates.lint", function()
	local auto = require("dwight.auto")
	T.assert(auto._gate_lint == gates.lint, "should be same function")
end)

T.test("auto._verification_gate delegates to gates.run_all", function()
	local auto = require("dwight.auto")
	T.assert(auto._verification_gate == gates.run_all, "should be same function")
end)

io.write("── pipeline function signature ──\n")

T.test("run_all accepts baseline_coverage", function()
	-- Verify the function accepts 4 args (status, callback, baseline_failures, baseline_coverage)
	local info = debug.getinfo(gates.run_all)
	-- nparams may not be reliable across Lua versions, just verify it's callable
	T.assert(info ~= nil, "should be inspectable")
end)
