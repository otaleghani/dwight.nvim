-- tests/test_swarm_parse.lua
-- Tests for swarm decompose wave parsing and preview buffer parsing.

vim.opt.rtp:prepend(vim.fn.getcwd())

local decompose = require("dwight.swarm.decompose")
local preview = require("dwight.swarm.preview")
local T = _T

io.write("── swarm._parse_waves (XML) ──\n")

T.test("parse basic wave XML", function()
	local raw = [[
<waves>
<wave number="1">
<task order="1" title="Create auth module">
<files>src/auth.go, src/auth_test.go</files>
Implement the authentication module with login and logout.
</task>
<task order="2" title="Create user module">
<files>src/user.go, src/user_test.go</files>
Implement the user management module.
</task>
</wave>
<wave number="2">
<task order="3" title="Wire routes">
<files>src/server.go</files>
Register auth and user routes in the server.
</task>
</wave>
</waves>
	]]
	local waves = decompose._parse_waves(raw)
	T.len(2, waves, "should parse 2 waves")
	T.eq(1, waves[1].wave)
	T.len(2, waves[1].tasks, "wave 1 should have 2 tasks")
	T.eq("Create auth module", waves[1].tasks[1].title)
	T.eq("Create user module", waves[1].tasks[2].title)
	T.len(2, waves[1].tasks[1].files, "task 1 should have 2 files")
	T.eq("src/auth.go", waves[1].tasks[1].files[1])
	T.eq(2, waves[2].wave)
	T.len(1, waves[2].tasks, "wave 2 should have 1 task")
	T.eq("Wire routes", waves[2].tasks[1].title)
end)

T.test("parse wave XML with code fences", function()
	local raw = [[```xml
<waves>
<wave number="1">
<task order="1" title="Setup">
<files>pkg/setup.go</files>
Initialize the project.
</task>
</wave>
</waves>
```]]
	local waves = decompose._parse_waves(raw)
	T.len(1, waves, "should strip code fences")
	T.eq("Setup", waves[1].tasks[1].title)
end)

T.test("parse waves with single quotes", function()
	local raw = [[
<waves>
<wave number='1'>
<task order='1' title='Quoted task'>
<files>a.go</files>
Body text.
</task>
</wave>
</waves>
	]]
	local waves = decompose._parse_waves(raw)
	T.len(1, waves)
	T.eq("Quoted task", waves[1].tasks[1].title)
end)

T.test("empty input produces no waves", function()
	T.len(0, decompose._parse_waves(""))
end)

T.test("random text produces no waves", function()
	T.len(0, decompose._parse_waves("just some random text with no structure"))
end)

T.test("waves sorted by number", function()
	local raw = [[
<waves>
<wave number="2">
<task order="2" title="Second wave">
<files>b.go</files>
Second.
</task>
</wave>
<wave number="1">
<task order="1" title="First wave">
<files>a.go</files>
First.
</task>
</wave>
</waves>
	]]
	local waves = decompose._parse_waves(raw)
	T.len(2, waves)
	T.eq(1, waves[1].wave)
	T.eq(2, waves[2].wave)
end)

T.test("tasks within wave sorted by order", function()
	local raw = [[
<waves>
<wave number="1">
<task order="3" title="Third">
<files>c.go</files>
C
</task>
<task order="1" title="First">
<files>a.go</files>
A
</task>
<task order="2" title="Second">
<files>b.go</files>
B
</task>
</wave>
</waves>
	]]
	local waves = decompose._parse_waves(raw)
	T.eq("First", waves[1].tasks[1].title)
	T.eq("Second", waves[1].tasks[2].title)
	T.eq("Third", waves[1].tasks[3].title)
end)

io.write("── swarm._parse_waves (flat fallback) ──\n")

T.test("fallback: flat <task> blocks become single wave", function()
	local raw = [[
<task order="1" title="First task">Do first thing.</task>
<task order="2" title="Second task">Do second thing.</task>
	]]
	local waves = decompose._parse_waves(raw)
	T.len(1, waves, "should create single wave from flat tasks")
	T.eq(1, waves[1].wave)
	T.len(2, waves[1].tasks)
end)

io.write("── swarm._validate_wave ──\n")

T.test("no conflicts when files don't overlap", function()
	local wave = {
		tasks = {
			{ title = "A", files = { "a.go", "a_test.go" } },
			{ title = "B", files = { "b.go", "b_test.go" } },
		},
	}
	local conflicts = decompose._validate_wave(wave)
	T.len(0, conflicts, "should have no conflicts")
end)

T.test("detect file conflicts", function()
	local wave = {
		tasks = {
			{ title = "A", files = { "shared.go", "a.go" } },
			{ title = "B", files = { "shared.go", "b.go" } },
		},
	}
	local conflicts = decompose._validate_wave(wave)
	T.ok(#conflicts > 0, "should detect conflict on shared.go")
	T.match("shared.go", conflicts[1])
end)

io.write("── swarm preview._parse_buffer_waves ──\n")

T.test("parse buffer waves", function()
	local text = [[
<!-- header -->

# Wave 1  (2 parallel tasks)

## Task 1: Auth module
**Files:** src/auth.go, src/auth_test.go

Implement authentication.

---

## Task 2: User module
**Files:** src/user.go

Implement users.

---

# Wave 2  (1 parallel tasks)

## Task 3: Wire routes

Register all routes.

---
	]]
	local waves = preview._parse_buffer_waves(text)
	T.len(2, waves, "should parse 2 waves")
	T.eq(1, waves[1].wave)
	T.len(2, waves[1].tasks, "wave 1 has 2 tasks")
	T.eq("Auth module", waves[1].tasks[1].title)
	T.eq(1, waves[1].tasks[1].order)
	T.len(2, waves[1].tasks[1].files, "task 1 has 2 files")
	T.eq("src/auth.go", waves[1].tasks[1].files[1])
	T.eq("User module", waves[1].tasks[2].title)
	T.eq(2, waves[2].wave)
	T.len(1, waves[2].tasks)
	T.eq("Wire routes", waves[2].tasks[1].title)
end)

T.test("parse buffer with no files line", function()
	local text = [[
# Wave 1  (1 parallel tasks)

## Task 1: Simple task

Just do it.
	]]
	local waves = preview._parse_buffer_waves(text)
	T.len(1, waves)
	T.len(0, waves[1].tasks[1].files, "files should be empty")
	T.match("Just do it", waves[1].tasks[1].description)
end)

T.test("empty buffer produces no waves", function()
	T.len(0, preview._parse_buffer_waves(""))
end)
