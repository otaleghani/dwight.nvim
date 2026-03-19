-- tests/test_swarm_worktree.lua
-- Tests for pure functions in swarm/worktree.lua.

vim.opt.rtp:prepend(vim.fn.getcwd())

local worktree = require("dwight.swarm.worktree")
local T = _T

--------------------------------------------------------------------
-- _parse_resolutions
--------------------------------------------------------------------

io.write("── worktree._parse_resolutions ──\n")

T.test("parse_resolutions: valid single file", function()
	local raw = [[
Some preamble text.
<resolved path="src/main.go">package main

func main() {}
</resolved>
	]]
	local results = worktree._parse_resolutions(raw)
	T.ok(results, "should return results")
	T.len(1, results)
	T.eq("src/main.go", results[1].path)
	T.match("package main", results[1].content)
end)

T.test("parse_resolutions: valid multi-file", function()
	local raw = [[
<resolved path="a.go">package a
</resolved>
<resolved path="b.go">package b
</resolved>
	]]
	local results = worktree._parse_resolutions(raw)
	T.ok(results)
	T.len(2, results)
	T.eq("a.go", results[1].path)
	T.eq("b.go", results[2].path)
end)

T.test("parse_resolutions: conflict markers -> nil", function()
	local raw = [[
<resolved path="a.go">
<<<<<<< HEAD
our stuff
=======
their stuff
>>>>>>> branch
</resolved>
	]]
	local results = worktree._parse_resolutions(raw)
	T.is_nil(results, "should reject output with conflict markers")
end)

T.test("parse_resolutions: empty input -> nil", function()
	local results = worktree._parse_resolutions("")
	T.is_nil(results)
end)

T.test("parse_resolutions: no resolved blocks -> nil", function()
	local results = worktree._parse_resolutions("just some text without XML blocks")
	T.is_nil(results)
end)

T.test("parse_resolutions: whitespace trimming", function()
	local raw = [[
<resolved path="x.go">
package x
</resolved>
	]]
	local results = worktree._parse_resolutions(raw)
	T.ok(results)
	T.eq("package x", results[1].content)
end)

--------------------------------------------------------------------
-- _build_resolution_prompt
--------------------------------------------------------------------

io.write("── worktree._build_resolution_prompt ──\n")

T.test("build_resolution_prompt: expected XML blocks", function()
	local conflict_files = {
		{ path = "a.go", content = "<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> branch" },
	}
	local prompt = worktree._build_resolution_prompt(conflict_files, 2, 3)
	T.match('path="a.go"', prompt)
	T.match("Wave 2", prompt)
	T.match("task 3", prompt)
	T.match("<conflicted", prompt)
	T.match("</conflicted>", prompt)
	T.match("<resolved", prompt)
end)

T.test("build_resolution_prompt: multi-file", function()
	local conflict_files = {
		{ path = "a.go", content = "conflict a" },
		{ path = "b.go", content = "conflict b" },
	}
	local prompt = worktree._build_resolution_prompt(conflict_files, 1, 1)
	T.match('path="a.go"', prompt)
	T.match('path="b.go"', prompt)
end)

--------------------------------------------------------------------
-- build_conflict_diagnostic
--------------------------------------------------------------------

io.write("── worktree.build_conflict_diagnostic ──\n")

T.test("build_conflict_diagnostic: single owner", function()
	local conflict_files = {
		{ path = "shared.go", content = "<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> branch" },
	}
	local file_map = { [1] = { "shared.go" }, [2] = { "shared.go" } }
	local successes = {
		{ task_idx = 1, title = "Task A" },
		{ task_idx = 2, title = "Task B" },
	}
	local lines = worktree.build_conflict_diagnostic(conflict_files, file_map, successes)
	T.ok(#lines > 0)
	-- Should contain the file path
	local joined = table.concat(lines, "\n")
	T.match("shared.go", joined)
	-- Should mention both task owners
	T.match("Task A", joined)
	T.match("Task B", joined)
end)

T.test("build_conflict_diagnostic: no owners (empty file_map)", function()
	local conflict_files = {
		{ path = "orphan.go", content = "no conflict markers here" },
	}
	local file_map = {}
	local successes = {}
	local lines = worktree.build_conflict_diagnostic(conflict_files, file_map, successes)
	T.ok(#lines > 0)
	local joined = table.concat(lines, "\n")
	T.match("orphan.go", joined)
end)

T.test("build_conflict_diagnostic: snippet truncation (6 line cap)", function()
	local long_conflict = "<<<<<<< HEAD\nline1\nline2\nline3\nline4\nline5\nline6\nline7\n=======\ntheirs\n>>>>>>> b"
	local conflict_files = {
		{ path = "big.go", content = long_conflict },
	}
	local file_map = {}
	local successes = {}
	local lines = worktree.build_conflict_diagnostic(conflict_files, file_map, successes)
	local joined = table.concat(lines, "\n")
	T.match("%.%.%.", joined, "should have truncation marker")
end)

--------------------------------------------------------------------
-- order_for_merge
--------------------------------------------------------------------

io.write("── worktree.order_for_merge ──\n")

T.test("order_for_merge: fewest-overlaps-first", function()
	local tasks = {
		{ task_idx = 1 },
		{ task_idx = 2 },
		{ task_idx = 3 },
	}
	local overlaps = {
		{ file = "shared.go", task_indices = { 2, 3 } },
		{ file = "other.go", task_indices = { 2, 3 } },
	}
	local sorted = worktree.order_for_merge(tasks, overlaps)
	-- Task 1 has 0 overlaps, should be first
	T.eq(1, sorted[1].task_idx)
	-- Tasks 2 and 3 each have 2 overlaps
	T.ok(sorted[2].task_idx == 2 or sorted[2].task_idx == 3)
end)

T.test("order_for_merge: empty inputs", function()
	local sorted = worktree.order_for_merge({}, {})
	T.len(0, sorted)
end)

T.test("order_for_merge: no overlaps preserves order", function()
	local tasks = { { task_idx = 1 }, { task_idx = 2 } }
	local sorted = worktree.order_for_merge(tasks, {})
	T.eq(1, sorted[1].task_idx)
	T.eq(2, sorted[2].task_idx)
end)
