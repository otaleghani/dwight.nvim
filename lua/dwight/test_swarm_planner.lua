-- tests/test_swarm_planner.lua
-- Tests for swarm DAG planner: parse, validate, to_waves.

vim.opt.rtp:prepend(vim.fn.getcwd())

local planner = require("dwight.swarm.planner")
local T = _T

--------------------------------------------------------------------
-- _parse_plan
--------------------------------------------------------------------

io.write("── planner._parse_plan ──\n")

T.test("parse basic plan with 2 tasks", function()
	local raw = [[
<plan>
<task id="t1" title="Create auth module">
<deps></deps>
<files>src/auth.go, src/auth_test.go</files>
Implement the authentication module with login and logout.
</task>
<task id="t2" title="Wire routes">
<deps>t1</deps>
<files>src/server.go</files>
Register auth routes in the server.
</task>
</plan>
	]]
	local plan = planner._parse_plan(raw)
	T.ok(plan, "should return a plan")
	T.len(2, plan.nodes, "should have 2 nodes")
	T.eq("t1", plan.nodes[1].id)
	T.eq("Create auth module", plan.nodes[1].goal)
	T.len(0, plan.nodes[1].deps, "t1 has no deps")
	T.len(2, plan.nodes[1].files, "t1 has 2 files")
	T.eq("src/auth.go", plan.nodes[1].files[1])
	T.eq("t2", plan.nodes[2].id)
	T.len(1, plan.nodes[2].deps, "t2 has 1 dep")
	T.eq("t1", plan.nodes[2].deps[1])
	T.eq("pending", plan.nodes[1].status)
	T.eq("pending", plan.nodes[2].status)
end)

T.test("parse plan with code fences", function()
	local raw = [[```xml
<plan>
<task id="t1" title="Setup">
<deps></deps>
<files>pkg/setup.go</files>
Initialize the project.
</task>
</plan>
```]]
	local plan = planner._parse_plan(raw)
	T.ok(plan, "should strip code fences")
	T.len(1, plan.nodes)
	T.eq("Setup", plan.nodes[1].goal)
end)

T.test("empty input returns nil", function()
	T.is_nil(planner._parse_plan(""))
end)

T.test("malformed input returns nil", function()
	T.is_nil(planner._parse_plan("just some random text"))
end)

T.test("missing <deps> treated as no deps", function()
	local raw = [[
<plan>
<task id="t1" title="Solo task">
<files>a.go</files>
Do the thing.
</task>
</plan>
	]]
	local plan = planner._parse_plan(raw)
	T.ok(plan)
	T.len(0, plan.nodes[1].deps)
end)

--------------------------------------------------------------------
-- _validate_plan
--------------------------------------------------------------------

io.write("── planner._validate_plan ──\n")

T.test("valid diamond DAG passes", function()
	local plan = {
		nodes = {
			{ id = "t1", goal = "Base", deps = {}, files = { "a.go" }, status = "pending" },
			{ id = "t2", goal = "Left", deps = { "t1" }, files = { "b.go" }, status = "pending" },
			{ id = "t3", goal = "Right", deps = { "t1" }, files = { "c.go" }, status = "pending" },
			{ id = "t4", goal = "Join", deps = { "t2", "t3" }, files = { "d.go" }, status = "pending" },
		},
	}
	local ok, errs = planner._validate_plan(plan)
	T.ok(ok, "diamond should be valid: " .. (errs and errs[1] or ""))
end)

T.test("cycle detected: t1→t2, t2→t1", function()
	local plan = {
		nodes = {
			{ id = "t1", goal = "A", deps = { "t2" }, files = { "a.go" }, status = "pending" },
			{ id = "t2", goal = "B", deps = { "t1" }, files = { "b.go" }, status = "pending" },
		},
	}
	local ok, errs = planner._validate_plan(plan)
	T.ok(not ok, "should detect cycle")
	local found = false
	for _, e in ipairs(errs) do
		if e:match("cycle") then
			found = true
		end
	end
	T.ok(found, "error should mention cycle")
end)

T.test("depth 4 chain exceeds limit", function()
	local plan = {
		nodes = {
			{ id = "t1", goal = "A", deps = {}, files = { "a.go" }, status = "pending" },
			{ id = "t2", goal = "B", deps = { "t1" }, files = { "b.go" }, status = "pending" },
			{ id = "t3", goal = "C", deps = { "t2" }, files = { "c.go" }, status = "pending" },
			{ id = "t4", goal = "D", deps = { "t3" }, files = { "d.go" }, status = "pending" },
			{ id = "t5", goal = "E", deps = { "t4" }, files = { "e.go" }, status = "pending" },
		},
	}
	local ok, errs = planner._validate_plan(plan)
	T.ok(not ok, "should reject depth 4")
	local found = false
	for _, e in ipairs(errs) do
		if e:match("depth") then
			found = true
		end
	end
	T.ok(found, "error should mention depth")
end)

T.test("depth 3 chain is OK", function()
	local plan = {
		nodes = {
			{ id = "t1", goal = "A", deps = {}, files = { "a.go" }, status = "pending" },
			{ id = "t2", goal = "B", deps = { "t1" }, files = { "b.go" }, status = "pending" },
			{ id = "t3", goal = "C", deps = { "t2" }, files = { "c.go" }, status = "pending" },
			{ id = "t4", goal = "D", deps = { "t3" }, files = { "d.go" }, status = "pending" },
		},
	}
	local ok, errs = planner._validate_plan(plan)
	T.ok(ok, "depth 3 should be valid: " .. (errs and errs[1] or ""))
end)

T.test("dangling dep detected", function()
	local plan = {
		nodes = {
			{ id = "t1", goal = "A", deps = {}, files = { "a.go" }, status = "pending" },
			{ id = "t2", goal = "B", deps = { "t99" }, files = { "b.go" }, status = "pending" },
		},
	}
	local ok, errs = planner._validate_plan(plan)
	T.ok(not ok, "should detect dangling dep")
	local found = false
	for _, e in ipairs(errs) do
		if e:match("dangling") or e:match("t99") then
			found = true
		end
	end
	T.ok(found, "error should mention dangling dep")
end)

T.test("file conflict at same level detected", function()
	local plan = {
		nodes = {
			{ id = "t1", goal = "A", deps = {}, files = { "shared.go", "a.go" }, status = "pending" },
			{ id = "t2", goal = "B", deps = {}, files = { "shared.go", "b.go" }, status = "pending" },
		},
	}
	local ok, errs = planner._validate_plan(plan)
	T.ok(not ok, "should detect file conflict")
	local found = false
	for _, e in ipairs(errs) do
		if e:match("shared%.go") then
			found = true
		end
	end
	T.ok(found, "error should mention shared.go")
end)

T.test("file overlap across levels is OK", function()
	local plan = {
		nodes = {
			{ id = "t1", goal = "A", deps = {}, files = { "shared.go" }, status = "pending" },
			{ id = "t2", goal = "B", deps = { "t1" }, files = { "shared.go" }, status = "pending" },
		},
	}
	local ok, errs = planner._validate_plan(plan)
	T.ok(ok, "file overlap across levels should be OK: " .. (errs and errs[1] or ""))
end)

--------------------------------------------------------------------
-- _to_waves
--------------------------------------------------------------------

io.write("── planner._to_waves ──\n")

T.test("linear chain produces N waves of 1 task", function()
	local plan = {
		nodes = {
			{ id = "t1", goal = "First", deps = {}, files = { "a.go" }, status = "pending" },
			{ id = "t2", goal = "Second", deps = { "t1" }, files = { "b.go" }, status = "pending" },
			{ id = "t3", goal = "Third", deps = { "t2" }, files = { "c.go" }, status = "pending" },
		},
	}
	local waves = planner._to_waves(plan)
	T.len(3, waves, "should produce 3 waves")
	T.len(1, waves[1].tasks, "wave 1 has 1 task")
	T.len(1, waves[2].tasks, "wave 2 has 1 task")
	T.len(1, waves[3].tasks, "wave 3 has 1 task")
	T.eq("First", waves[1].tasks[1].title)
	T.eq("Second", waves[2].tasks[1].title)
	T.eq("Third", waves[3].tasks[1].title)
end)

T.test("diamond produces 3 waves", function()
	local plan = {
		nodes = {
			{ id = "t1", goal = "Base", deps = {}, files = { "a.go" }, status = "pending" },
			{ id = "t2", goal = "Left", deps = { "t1" }, files = { "b.go" }, status = "pending" },
			{ id = "t3", goal = "Right", deps = { "t1" }, files = { "c.go" }, status = "pending" },
			{ id = "t4", goal = "Join", deps = { "t2", "t3" }, files = { "d.go" }, status = "pending" },
		},
	}
	local waves = planner._to_waves(plan)
	T.len(3, waves, "should produce 3 waves")
	T.len(1, waves[1].tasks, "wave 1: [t1]")
	T.eq("Base", waves[1].tasks[1].title)
	T.len(2, waves[2].tasks, "wave 2: [t2, t3]")
	T.len(1, waves[3].tasks, "wave 3: [t4]")
	T.eq("Join", waves[3].tasks[1].title)
end)

T.test("all independent produces 1 wave", function()
	local plan = {
		nodes = {
			{ id = "t1", goal = "A", deps = {}, files = { "a.go" }, status = "pending" },
			{ id = "t2", goal = "B", deps = {}, files = { "b.go" }, status = "pending" },
			{ id = "t3", goal = "C", deps = {}, files = { "c.go" }, status = "pending" },
		},
	}
	local waves = planner._to_waves(plan)
	T.len(1, waves, "should produce 1 wave")
	T.len(3, waves[1].tasks, "all 3 tasks in wave 1")
end)

T.test("node_id preserved on tasks", function()
	local plan = {
		nodes = {
			{ id = "t1", goal = "A", deps = {}, files = { "a.go" }, status = "pending" },
			{ id = "t2", goal = "B", deps = { "t1" }, files = { "b.go" }, status = "pending" },
		},
	}
	local waves = planner._to_waves(plan)
	T.eq("t1", waves[1].tasks[1].node_id)
	T.eq("t2", waves[2].tasks[1].node_id)
end)

T.test("tasks within wave sorted alphabetically by id", function()
	local plan = {
		nodes = {
			{ id = "t3", goal = "C", deps = {}, files = { "c.go" }, status = "pending" },
			{ id = "t1", goal = "A", deps = {}, files = { "a.go" }, status = "pending" },
			{ id = "t2", goal = "B", deps = {}, files = { "b.go" }, status = "pending" },
		},
	}
	local waves = planner._to_waves(plan)
	T.eq("t1", waves[1].tasks[1].node_id)
	T.eq("t2", waves[1].tasks[2].node_id)
	T.eq("t3", waves[1].tasks[3].node_id)
end)

--------------------------------------------------------------------
-- preview._parse_buffer_waves with DAG headers
--------------------------------------------------------------------

io.write("── preview._parse_buffer_waves (DAG) ──\n")

local preview = require("dwight.swarm.preview")

T.test("parse buffer with node_id headers and deps", function()
	local text = [[
<!-- header -->

# Wave 1  (1 parallel tasks)

## Task t1: Base module
**Files:** src/base.go
**Deps:** (none)

Implement the base module.

---

# Wave 2  (2 parallel tasks)

## Task t2: Left branch
**Files:** src/left.go
**Deps:** t1

Left implementation.

---

## Task t3: Right branch
**Files:** src/right.go
**Deps:** t1

Right implementation.

---
	]]
	local waves = preview._parse_buffer_waves(text)
	T.len(2, waves, "should parse 2 waves")

	-- Wave 1
	T.eq(1, waves[1].wave)
	T.len(1, waves[1].tasks)
	T.eq("t1", waves[1].tasks[1].node_id)
	T.eq("Base module", waves[1].tasks[1].title)
	T.len(1, waves[1].tasks[1].files)
	T.eq("src/base.go", waves[1].tasks[1].files[1])
	T.len(0, waves[1].tasks[1].deps, "t1 has no deps")

	-- Wave 2
	T.eq(2, waves[2].wave)
	T.len(2, waves[2].tasks)
	T.eq("t2", waves[2].tasks[1].node_id)
	T.len(1, waves[2].tasks[1].deps)
	T.eq("t1", waves[2].tasks[1].deps[1])
	T.eq("t3", waves[2].tasks[2].node_id)
end)

T.test("parse buffer with numeric task IDs (backwards compat)", function()
	local text = [[
# Wave 1  (1 parallel tasks)

## Task 1: Simple task
**Files:** a.go

Just do it.
	]]
	local waves = preview._parse_buffer_waves(text)
	T.len(1, waves)
	T.eq(1, waves[1].tasks[1].order)
	T.is_nil(waves[1].tasks[1].node_id, "numeric tasks should not have node_id")
end)
