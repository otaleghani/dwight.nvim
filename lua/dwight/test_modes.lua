-- tests/test_modes.lua
-- Tests for modes registry, custom registration, aliases, and filetype filtering.

vim.opt.rtp:prepend(vim.fn.getcwd())

local T = _T

-- Clear cached module so we get a fresh registry
package.loaded["dwight.modes"] = nil
local modes = require("dwight.modes")

io.write("── modes: built-in modes ──\n")

T.test("built-in modes exist", function()
	T.ok(modes.get("refactor"), "refactor mode should exist")
	T.ok(modes.get("test"), "test mode should exist")
	T.ok(modes.get("fix"), "fix mode should exist")
	T.ok(modes.get("code"), "code mode should exist")
	T.ok(modes.get("document"), "document mode should exist")
end)

T.test("every mode has required fields", function()
	for name, mode in pairs(modes.registry) do
		T.ok(mode.task ~= nil, name .. " missing task")
		T.ok(mode.name, name .. " missing name")
		T.ok(mode.context, name .. " missing context")
	end
end)

io.write("── modes: aliases ──\n")

T.test("fix_bugs alias resolves to fix", function()
	local fix = modes.get("fix")
	local fix_bugs = modes.get("fix_bugs")
	T.ok(fix_bugs, "fix_bugs alias should resolve")
	T.eq(fix.task, fix_bugs.task, "fix_bugs should have same task as fix")
end)

io.write("── modes: tdd compat ──\n")

T.test("tdd returns code mode with inject_run_output", function()
	-- Mock vim.bo for docs mode (tdd uses code mode internally)
	local tdd = modes.get("tdd")
	T.ok(tdd, "tdd should return a mode")
	T.ok(tdd.inject_run_output, "tdd should have inject_run_output = true")
	T.eq("✗", tdd.icon, "tdd icon should be ✗")
end)

io.write("── modes: register custom ──\n")

T.test("register custom mode", function()
	modes.register("my_deploy", { task = "Generate deployment script" })
	local m = modes.get("my_deploy")
	T.ok(m, "custom mode should be retrievable")
	T.eq("Generate deployment script", m.task)
	T.eq("my_deploy", m.name)
	T.eq("◆", m.icon, "default icon should be ◆")
	T.eq("both", m.context, "default context should be both")
end)

T.test("register requires task", function()
	local ok = pcall(modes.register, "bad_mode", {})
	T.eq(false, ok, "register without task should error")
end)

T.test("list includes custom mode", function()
	local names = modes.list()
	local found = false
	for _, n in ipairs(names) do
		if n == "my_deploy" then
			found = true
			break
		end
	end
	T.ok(found, "list() should include custom mode my_deploy")
end)

io.write("── modes: filetype filtering ──\n")

T.test("code modes excluded for prose filetypes", function()
	local prose_modes = modes.list_for_filetype("markdown")
	local code_only = {}
	for _, n in ipairs(prose_modes) do
		local m = modes.registry[n]
		if m and m.context == "code" then
			code_only[#code_only + 1] = n
		end
	end
	T.eq(0, #code_only, "no code-only modes should appear for markdown")
end)

T.test("prose modes excluded for code filetypes", function()
	local code_modes = modes.list_for_filetype("lua")
	local prose_only = {}
	for _, n in ipairs(code_modes) do
		local m = modes.registry[n]
		if m and m.context == "prose" then
			prose_only[#prose_only + 1] = n
		end
	end
	T.eq(0, #prose_only, "no prose-only modes should appear for lua")
end)

T.test("both-context modes appear for all filetypes", function()
	local prose_modes = modes.list_for_filetype("markdown")
	local code_modes = modes.list_for_filetype("lua")
	local found_prose = false
	local found_code = false
	for _, n in ipairs(prose_modes) do
		if n == "explain" then
			found_prose = true
		end
	end
	for _, n in ipairs(code_modes) do
		if n == "explain" then
			found_code = true
		end
	end
	T.ok(found_prose, "explain should appear in prose modes")
	T.ok(found_code, "explain should appear in code modes")
end)

-- Cleanup: remove custom mode to not affect other tests
modes.registry["my_deploy"] = nil
