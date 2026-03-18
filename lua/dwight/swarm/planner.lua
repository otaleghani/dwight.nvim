-- dwight/swarm/planner.lua
-- DAG-based goal decomposition: the LLM declares per-task dependencies,
-- and we compute the wave schedule automatically via topological sort.

local M = {}

local api = vim.api

--------------------------------------------------------------------
-- Plan prompt (DAG-aware)
--------------------------------------------------------------------

M.PLAN_PROMPT = [=[
You are Dwight, an autonomous coding agent. The developer wants a complex feature built.
Your job is to DECOMPOSE it into a DAG of sub-tasks with explicit dependencies.

The developer wants: %s

Project context:
%s

DECOMPOSITION RULES:
1. Each task declares its DEPENDENCIES — which other tasks must complete first.
2. Tasks with no mutual dependencies can run IN PARALLEL (each in its own git worktree).
3. Tasks that share the same dependencies run in the same wave and MUST NOT edit the same files.
4. Each task should be small enough for a single DwightAgent session (5-6 steps max).
5. Order matters: foundational work first (types, interfaces), then implementation, then wiring.
6. Each task description must list its EXACT file scope: which files it creates/edits.
7. MAXIMUM 12 tasks total, MAXIMUM dependency depth of 3 (longest chain of deps).
8. If you can't identify parallelism, create a linear chain of tasks.

FILE SCOPE — CRITICAL:
9. Every <task> MUST include a <files> element listing all files it will create or edit.
   Tasks that can run in parallel MUST NOT share files.

TDD ORDERING:
10. Within each task, follow test-first order: write tests FIRST, then implement.

PRAGMA PROPAGATION:
11. If the project uses @feature:name pragmas, new files must include the pragma.

%s

RESPOND IN THIS EXACT FORMAT:

<plan>
<task id="t1" title="Short title">
<deps></deps>
<files>path/to/file1.go, path/to/file2.go</files>
Concrete description of what to build. Include:
- Exact file paths to create/edit
- Function signatures and types
- What tests to write
</task>
<task id="t2" title="Short title">
<deps>t1</deps>
<files>path/to/other.go, path/to/other_test.go</files>
Another task that depends on t1 completing first.
</task>
<task id="t3" title="Short title">
<deps>t1</deps>
<files>path/to/another.go</files>
This task also depends on t1 but can run IN PARALLEL with t2 (different files).
</task>
<task id="t4" title="Short title">
<deps>t2, t3</deps>
<files>path/to/wiring.go</files>
This task depends on both t2 and t3 completing.
</task>
</plan>

IMPORTANT:
- The <files> element is REQUIRED for every task.
- The <deps> element is REQUIRED (empty for root tasks with no dependencies).
- Task IDs must be simple identifiers like t1, t2, t3, etc.
- Tasks at the same dependency level MUST have non-overlapping <files>.
- Each task description must be self-contained: detailed enough for an agent to execute
  without seeing the decomposition context.

CRITICAL OUTPUT FORMAT RULES:
- Your response MUST contain <plan>...</plan> with at least 1 <task> block inside.
- Do NOT write a prose summary instead of the plan/task blocks.
- Start your <plan> block as early as possible in the response.
]=]

--------------------------------------------------------------------
-- Parser: extract DAG nodes from LLM output
--------------------------------------------------------------------

--- Parse a DAG plan from LLM output.
--- Returns SwarmPlan { nodes = SwarmNode[], root_goal = "" } or nil
function M._parse_plan(raw)
	if not raw or vim.trim(raw) == "" then
		return nil
	end

	local cleaned = raw:gsub("```xml%s*\n?", ""):gsub("```%s*\n?", "")

	local plan_body = cleaned:match("<plan>(.-)</plan>")
	if not plan_body then
		return nil
	end

	local nodes = {}
	for task_attrs, task_body in plan_body:gmatch("<task%s+(.-)>(.-)</task>") do
		local id = task_attrs:match('id="([^"]*)"') or task_attrs:match("id='([^']*)'")
		local title = task_attrs:match('title="([^"]*)"') or task_attrs:match("title='([^']*)'")

		if id and title then
			local deps_str = task_body:match("<deps>(.-)</deps>") or ""
			local files_str = task_body:match("<files>(.-)</files>") or ""

			-- Remove <deps> and <files> from description
			local description = task_body:gsub("<deps>.-</deps>%s*", ""):gsub("<files>.-</files>%s*", "")

			local deps = {}
			for d in deps_str:gmatch("[^,%s]+") do
				deps[#deps + 1] = vim.trim(d)
			end

			local files = {}
			for f in files_str:gmatch("[^,%s]+") do
				files[#files + 1] = vim.trim(f)
			end

			nodes[#nodes + 1] = {
				id = vim.trim(id),
				goal = vim.trim(title),
				description = vim.trim(description),
				deps = deps,
				files = files,
				status = "pending",
			}
		end
	end

	if #nodes == 0 then
		return nil
	end

	return { nodes = nodes, root_goal = "" }
end

--------------------------------------------------------------------
-- Validation
--------------------------------------------------------------------

--- Validate a SwarmPlan.
--- Returns (ok, errors_list)
function M._validate_plan(plan)
	local errors = {}

	-- Build id→node index
	local by_id = {}
	for _, node in ipairs(plan.nodes) do
		by_id[node.id] = node
	end

	-- Dangling deps
	for _, node in ipairs(plan.nodes) do
		for _, dep in ipairs(node.deps) do
			if not by_id[dep] then
				errors[#errors + 1] = string.format("dangling dep: %s depends on unknown '%s'", node.id, dep)
			end
		end
	end

	-- Cycle detection (DFS coloring: white=0, gray=1, black=2)
	local color = {}
	for _, node in ipairs(plan.nodes) do
		color[node.id] = 0
	end

	local function dfs(id)
		if color[id] == 1 then
			return true -- cycle
		end
		if color[id] == 2 then
			return false
		end
		color[id] = 1
		local node = by_id[id]
		if node then
			for _, dep in ipairs(node.deps) do
				if by_id[dep] and dfs(dep) then
					return true
				end
			end
		end
		color[id] = 2
		return false
	end

	for _, node in ipairs(plan.nodes) do
		if color[node.id] == 0 then
			if dfs(node.id) then
				errors[#errors + 1] = "cycle detected in dependency graph"
				break
			end
		end
	end

	-- Depth limit (longest path via memoized recursion)
	-- Skip if cycles were detected (longest_path would infinite-recurse)
	local has_cycle = false
	for _, e in ipairs(errors) do
		if e:match("cycle") then
			has_cycle = true
			break
		end
	end

	if not has_cycle then
		local depth_memo = {}
		local function longest_path(id)
			if depth_memo[id] then
				return depth_memo[id]
			end
			local node = by_id[id]
			if not node or #node.deps == 0 then
				depth_memo[id] = 0
				return 0
			end
			local max_dep = 0
			for _, dep in ipairs(node.deps) do
				if by_id[dep] then
					local d = longest_path(dep)
					if d > max_dep then
						max_dep = d
					end
				end
			end
			depth_memo[id] = max_dep + 1
			return max_dep + 1
		end

		local max_depth = 0
		for _, node in ipairs(plan.nodes) do
			local d = longest_path(node.id)
			if d > max_depth then
				max_depth = d
			end
		end
		if max_depth > 3 then
			errors[#errors + 1] = string.format("depth %d exceeds maximum of 3", max_depth)
		end

		-- File conflicts at same level
		-- Compute levels via topo-sort (Kahn's)
		local in_deg = {}
		local adj = {} -- id → list of dependents
		for _, node in ipairs(plan.nodes) do
			in_deg[node.id] = 0
			adj[node.id] = {}
		end
		for _, node in ipairs(plan.nodes) do
			for _, dep in ipairs(node.deps) do
				if by_id[dep] then
					in_deg[node.id] = in_deg[node.id] + 1
					adj[dep][#adj[dep] + 1] = node.id
				end
			end
		end

		local level = {}
		local queue = {}
		for _, node in ipairs(plan.nodes) do
			if in_deg[node.id] == 0 then
				queue[#queue + 1] = node.id
				level[node.id] = 1
			end
		end

		local qi = 1
		while qi <= #queue do
			local cur = queue[qi]
			qi = qi + 1
			for _, next_id in ipairs(adj[cur] or {}) do
				in_deg[next_id] = in_deg[next_id] - 1
				local new_level = level[cur] + 1
				if not level[next_id] or new_level > level[next_id] then
					level[next_id] = new_level
				end
				if in_deg[next_id] == 0 then
					queue[#queue + 1] = next_id
				end
			end
		end

		-- Group by level, check file overlaps within each level
		local by_level = {}
		for _, node in ipairs(plan.nodes) do
			local lv = level[node.id] or 1
			if not by_level[lv] then
				by_level[lv] = {}
			end
			by_level[lv][#by_level[lv] + 1] = node
		end

		for lv, level_nodes in pairs(by_level) do
			local file_owners = {}
			for _, node in ipairs(level_nodes) do
				for _, f in ipairs(node.files) do
					if file_owners[f] then
						errors[#errors + 1] = string.format(
							"file conflict at level %d: '%s' claimed by both '%s' and '%s'",
							lv,
							f,
							file_owners[f],
							node.id
						)
					else
						file_owners[f] = node.id
					end
				end
			end
		end
	end -- if not has_cycle

	return #errors == 0, errors
end

--------------------------------------------------------------------
-- Topological sort → wave schedule
--------------------------------------------------------------------

--- Convert a SwarmPlan into the waves format used by the execution engine.
--- Returns { { wave = N, tasks = { ... } }, ... }
function M._to_waves(plan)
	local by_id = {}
	for _, node in ipairs(plan.nodes) do
		by_id[node.id] = node
	end

	-- Kahn's algorithm
	local in_deg = {}
	local adj = {}
	for _, node in ipairs(plan.nodes) do
		in_deg[node.id] = 0
		adj[node.id] = {}
	end
	for _, node in ipairs(plan.nodes) do
		for _, dep in ipairs(node.deps) do
			if by_id[dep] then
				in_deg[node.id] = in_deg[node.id] + 1
				adj[dep][#adj[dep] + 1] = node.id
			end
		end
	end

	local waves = {}
	local remaining = {}
	for _, node in ipairs(plan.nodes) do
		remaining[node.id] = true
	end

	local wave_num = 0
	while true do
		-- Collect nodes with in_degree == 0
		local ready = {}
		for _, node in ipairs(plan.nodes) do
			if remaining[node.id] and in_deg[node.id] == 0 then
				ready[#ready + 1] = node
			end
		end

		if #ready == 0 then
			break
		end

		-- Sort alphabetically by id for determinism
		table.sort(ready, function(a, b)
			return a.id < b.id
		end)

		wave_num = wave_num + 1
		local tasks = {}
		for i, node in ipairs(ready) do
			tasks[#tasks + 1] = {
				order = i,
				title = node.goal,
				description = node.description,
				files = node.files,
				node_id = node.id,
				deps = node.deps,
			}
			remaining[node.id] = nil
			-- Decrement in-degree of dependents
			for _, next_id in ipairs(adj[node.id] or {}) do
				in_deg[next_id] = in_deg[next_id] - 1
			end
		end

		waves[#waves + 1] = { wave = wave_num, tasks = tasks }
	end

	return waves
end

--------------------------------------------------------------------
-- Entry point: plan a request
--------------------------------------------------------------------

--- Plan a complex request into a DAG, then convert to waves.
--- callback(waves, err, plan)
function M._plan(request, callback)
	local decompose = require("dwight.swarm.decompose")
	local context, go_rules = decompose._gather_context(request)

	local prompt = string.format(M.PLAN_PROMPT, request, context, go_rules)

	-- Log
	local log = require("dwight.log")
	local job_id = log._next_id()
	log.start(
		job_id,
		"swarm:plan",
		api.nvim_get_current_buf(),
		0,
		0,
		"DwightSwarm DAG planning: " .. request:sub(1, 200)
	)

	require("dwight.skills")._run_llm(prompt, function(raw, code)
		if code ~= 0 or not raw or vim.trim(raw) == "" then
			local err_msg = "Swarm planning failed (exit " .. tostring(code) .. ")"
			log.finish(job_id, "error", raw or "", nil, err_msg)
			callback(nil, err_msg, nil)
			return
		end

		-- Save raw output
		pcall(function()
			local project = require("dwight.project")
			if project.is_initialized() then
				local path = project.dir() .. "/swarm-plan-last.txt"
				local lf = io.open(path, "w")
				if lf then
					lf:write("-- DwightSwarm DAG plan\n-- " .. os.date() .. "\n\n")
					lf:write(raw)
					lf:close()
				end
			end
		end)

		local plan = M._parse_plan(raw)
		if not plan then
			-- Retry once with correction prompt
			local retry_prompt = string.format(
				"Your previous response did NOT contain the required <plan>/<task> XML blocks. "
					.. "Rewrite in the REQUIRED format. Your response MUST contain:\n\n"
					.. "<plan>\n"
					.. '<task id="t1" title="...">\n<deps></deps>\n<files>...</files>\n...\n</task>\n'
					.. "</plan>\n\n"
					.. "Produce ONLY the <plan> XML block.\n"
					.. "The original request was: %s",
				request:sub(1, 200)
			)

			require("dwight.skills")._run_llm(retry_prompt, function(retry_raw, retry_code)
				if retry_code ~= 0 or not retry_raw then
					log.finish(job_id, "parse_fail", raw, nil, "No plan parsed, retry failed")
					callback(nil, "No plan parsed from planning output", nil)
					return
				end

				local retry_plan = M._parse_plan(retry_raw)
				if not retry_plan then
					log.finish(job_id, "parse_fail", retry_raw, nil, "No plan parsed after retry")
					callback(nil, "No plan parsed even after retry", nil)
					return
				end

				retry_plan.root_goal = request
				local ok, errs = M._validate_plan(retry_plan)
				if not ok then
					log.finish(job_id, "validation_fail", retry_raw, nil, table.concat(errs, "; "))
					callback(nil, "Plan validation failed: " .. table.concat(errs, "; "), nil)
					return
				end

				local waves = M._to_waves(retry_plan)
				log.finish(job_id, "success", retry_raw, string.format("%d waves", #waves), nil)
				callback(waves, nil, retry_plan)
			end)
			return
		end

		plan.root_goal = request
		local ok, errs = M._validate_plan(plan)
		if not ok then
			log.finish(job_id, "validation_fail", raw, nil, table.concat(errs, "; "))
			callback(nil, "Plan validation failed: " .. table.concat(errs, "; "), nil)
			return
		end

		local waves = M._to_waves(plan)
		log.finish(job_id, "success", raw, string.format("%d waves", #waves), nil)

		callback(waves, nil, plan)
	end)
end

return M
