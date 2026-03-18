-- dwight/swarm/decompose.lua
-- Wave-aware decomposition: splits a complex request into parallel waves.
-- Each wave contains tasks that can run simultaneously (no file conflicts).

local M = {}

local api = vim.api

--------------------------------------------------------------------
-- Decomposition prompt (wave-aware)
--------------------------------------------------------------------

M.DECOMPOSE_PROMPT = [=[
You are Dwight, an autonomous coding agent. The developer wants a complex feature built.
Your job is to DECOMPOSE it into WAVES of sub-tasks. Tasks within a wave run IN PARALLEL
(each in its own git worktree), so they MUST NOT edit the same files.

The developer wants: %s

Project context:
%s

DECOMPOSITION RULES:
1. Group tasks into WAVES. Tasks in the same wave run in parallel — they MUST touch
   completely different files. No two tasks in the same wave may create or edit the same file.
2. Waves execute SEQUENTIALLY — wave 2 starts after wave 1's tasks are merged.
3. Each task should be small enough for a single DwightAgent session (5-6 steps max).
4. Order matters: foundational work first (types, interfaces), then implementation, then wiring.
5. Each task description must list its EXACT file scope: which files it creates/edits.
6. MAXIMUM 4 waves, MAXIMUM 4 tasks per wave, MAXIMUM 12 tasks total.
7. If tasks naturally depend on each other, put them in different waves.
8. If you can't identify parallelism, use 1 task per wave (degrades to sequential).

FILE SCOPE — CRITICAL:
9. Every <task> MUST include a <files> element listing all files it will create or edit.
   This is used to validate that parallel tasks don't conflict. Example:
   <files>src/auth/login.go, src/auth/login_test.go</files>

TDD ORDERING:
10. Within each task, follow test-first order: write tests FIRST, then implement.

PRAGMA PROPAGATION:
11. If the project uses @feature:name pragmas, new files must include the pragma.

%s

RESPOND IN THIS EXACT FORMAT:

<waves>
<wave number="1">
<task order="1" title="Short title">
<files>path/to/file1.go, path/to/file2.go</files>
Concrete description of what to build. Include:
- Exact file paths to create/edit
- Function signatures and types
- What tests to write
</task>
<task order="2" title="Short title">
<files>path/to/other.go, path/to/other_test.go</files>
Another task that can run IN PARALLEL with task 1 (different files).
</task>
</wave>
<wave number="2">
<task order="3" title="Short title">
<files>path/to/file1.go, path/to/wiring.go</files>
This task may depend on wave 1's output — it can edit files from wave 1.
</task>
</wave>
</waves>

IMPORTANT:
- The <files> element is REQUIRED for every task. Without it, parallel safety cannot be verified.
- Tasks in the same wave MUST have non-overlapping <files>.
- Each task description must be self-contained: detailed enough for an agent to execute
  without seeing the decomposition context.

CRITICAL OUTPUT FORMAT RULES:
- Your response MUST contain <waves>...</waves> with at least 1 <wave> block inside.
- Do NOT write a prose summary instead of the wave/task blocks.
- Start your <waves> block as early as possible in the response.
]=]

--------------------------------------------------------------------
-- Go-specific rules (reused from auto/decompose.lua)
--------------------------------------------------------------------

M._GO_RULES = [[
CRITICAL — HANDLER + ROUTE WIRING IN SAME STEP:
12. When a task implements HTTP handlers, it MUST ALSO register routes in the same task.
    NEVER split "implement handlers" and "register routes" into separate tasks.

CRITICAL — TEMPLATE LOADING MUST USE EMBED:
13. When adding HTML template rendering to Go, ALWAYS use `//go:embed` with `embed.FS`
    and `template.ParseFS`. NEVER use `template.ParseGlob` — it panics during tests.
]]

--------------------------------------------------------------------
-- Parser: extract waves + tasks from LLM output
--------------------------------------------------------------------

--- Parse wave-grouped tasks from LLM output.
--- Returns { { wave = N, tasks = { { order, title, description, files }, ... } }, ... }
function M._parse_waves(raw)
	local waves = {}

	-- Strip markdown code fences
	local cleaned = raw:gsub("```xml%s*\n?", ""):gsub("```%s*\n?", "")

	-- Strategy 1: Parse <wave>...<task>...</task>...</wave> blocks
	for wave_attrs, wave_body in cleaned:gmatch("<wave%s+(.-)>(.-)</wave>") do
		local wave_num = tonumber(wave_attrs:match('number="(%d+)"') or wave_attrs:match("number='(%d+)'"))
			or #waves + 1

		local tasks = {}
		for task_attrs, task_body in wave_body:gmatch("<task%s+(.-)>(.-)</task>") do
			local order_str = task_attrs:match('order="(%d+)"') or task_attrs:match("order='(%d+)'")
			local title = task_attrs:match('title="([^"]*)"') or task_attrs:match("title='([^']*)'")

			-- Extract <files> element
			local files_str = task_body:match("<files>(.-)</files>") or ""
			-- Remove <files> from description
			local description = task_body:gsub("<files>.-</files>%s*", "")

			if title then
				local file_list = {}
				for f in files_str:gmatch("[^,%s]+") do
					file_list[#file_list + 1] = vim.trim(f)
				end

				tasks[#tasks + 1] = {
					order = tonumber(order_str) or #tasks + 1,
					title = vim.trim(title),
					description = vim.trim(description),
					files = file_list,
				}
			end
		end

		if #tasks > 0 then
			table.sort(tasks, function(a, b)
				return a.order < b.order
			end)
			waves[#waves + 1] = { wave = wave_num, tasks = tasks }
		end
	end

	-- Strategy 2: Fallback — try parsing as flat <task> blocks (no waves), treat as single wave
	if #waves == 0 then
		local flat_tasks = require("dwight.auto.decompose")._parse_tasks(raw)
		if #flat_tasks > 0 then
			-- Wrap in a single wave
			for i, t in ipairs(flat_tasks) do
				t.files = t.files or {}
			end
			waves[#waves + 1] = { wave = 1, tasks = flat_tasks }
		end
	end

	-- Sort waves by number
	table.sort(waves, function(a, b)
		return a.wave < b.wave
	end)

	return waves
end

--------------------------------------------------------------------
-- Validate file scope: no overlapping files within a wave
--------------------------------------------------------------------

--- Check that no two tasks in a wave share files.
--- Returns list of conflict descriptions (empty = valid).
function M._validate_wave(wave)
	local conflicts = {}
	local file_owners = {} -- file → task title

	for _, task in ipairs(wave.tasks) do
		for _, f in ipairs(task.files or {}) do
			if file_owners[f] then
				conflicts[#conflicts + 1] =
					string.format("File '%s' claimed by both '%s' and '%s'", f, file_owners[f], task.title)
			else
				file_owners[f] = task.title
			end
		end
	end

	return conflicts
end

--------------------------------------------------------------------
-- Context gathering (shared with planner.lua)
--------------------------------------------------------------------

--- Gather project context for decomposition prompts.
--- Returns context_string, go_rules_string
function M._gather_context(request)
	local context_parts = {}

	pcall(function()
		local ctx = require("dwight.context")
		local manifest = ctx.build_xml()
		if manifest then
			if #manifest > 1500 then
				manifest = manifest:sub(1, 1500) .. "\n..."
			end
			context_parts[#context_parts + 1] = manifest
		end
	end)

	pcall(function()
		local features = require("dwight.features")
		local xml = features.build_project_context()
		if xml and xml ~= "" then
			context_parts[#context_parts + 1] = xml
		end
	end)

	local tree_lines = {}
	pcall(function()
		local bootstrap = require("dwight.bootstrap")
		local scan = bootstrap.scan()
		if scan.tree and #scan.tree > 0 then
			for _, line in ipairs(scan.tree) do
				tree_lines[#tree_lines + 1] = line
				if #tree_lines >= 40 then
					break
				end
			end
			context_parts[#context_parts + 1] = "<project_tree>\n"
				.. table.concat(tree_lines, "\n")
				.. "\n</project_tree>"
		end
	end)

	pcall(function()
		local integration = require("dwight.integration")
		local full_ctx = integration.build_full_context()
		if full_ctx then
			context_parts[#context_parts + 1] = full_ctx
		end
		local feature_ctx = integration.build_feature_context(request)
		if feature_ctx then
			context_parts[#context_parts + 1] = feature_ctx
		end
	end)

	local exploration_parts = {}
	local cwd = vim.fn.getcwd()
	local total_exploration_chars = 0
	local MAX_EXPLORATION_CHARS = 12000

	local function explore_file(rel_path)
		if total_exploration_chars >= MAX_EXPLORATION_CHARS then
			return nil
		end
		local full = cwd .. "/" .. rel_path
		local f = io.open(full, "r")
		if not f then
			return nil
		end
		local content = f:read("*a")
		f:close()
		if not content or content == "" then
			return nil
		end
		if #content > 2500 then
			content = content:sub(1, 2500) .. "\n... (truncated)"
		end
		total_exploration_chars = total_exploration_chars + #content
		return content
	end

	local explore_patterns = {
		{ pattern = "interface", priority = 10 },
		{ pattern = "types", priority = 10 },
		{ pattern = "models", priority = 9 },
		{ pattern = "server", priority = 7 },
		{ pattern = "router", priority = 7 },
		{ pattern = "routes", priority = 7 },
		{ pattern = "_test", priority = 5 },
		{ pattern = "test_", priority = 5 },
	}

	local request_lower = request:lower()
	local request_keywords = {}
	for word in request_lower:gmatch("%w+") do
		if #word > 3 then
			request_keywords[word] = true
		end
	end

	local scored_files = {}
	local files_seen = {}
	for _, line in ipairs(tree_lines) do
		if not line:match("/$") then
			local basename = line:match("[^/]+$") or line
			local base_lower = basename:lower()
			local best_priority = 0

			for _, ep in ipairs(explore_patterns) do
				if base_lower:match(ep.pattern) and ep.priority > best_priority then
					best_priority = ep.priority
				end
			end

			for kw in pairs(request_keywords) do
				if base_lower:match(kw) then
					best_priority = math.max(best_priority, 8)
				end
			end

			if best_priority > 0 and not files_seen[line] then
				files_seen[line] = true
				scored_files[#scored_files + 1] = { path = line, priority = best_priority }
			end
		end
	end

	table.sort(scored_files, function(a, b)
		return a.priority > b.priority
	end)

	local test_count = 0
	for _, entry in ipairs(scored_files) do
		if entry.priority == 5 then
			test_count = test_count + 1
			if test_count > 2 then
				goto continue
			end
		end
		local content = explore_file(entry.path)
		if content then
			exploration_parts[#exploration_parts + 1] =
				string.format('<explored_file path="%s">\n%s\n</explored_file>', entry.path, content)
		end
		::continue::
	end

	if #exploration_parts > 0 then
		context_parts[#context_parts + 1] = "\n<explored_code>\n"
			.. table.concat(exploration_parts, "\n\n")
			.. "\n</explored_code>"
	end

	local context = #context_parts > 0 and table.concat(context_parts, "\n\n") or "(no context)"

	local go_rules = ""
	for _, line in ipairs(tree_lines) do
		if line:match("%.go$") or line:match("go%.mod$") then
			go_rules = M._GO_RULES
			break
		end
	end

	return context, go_rules
end

--------------------------------------------------------------------
-- Decompose a request into waves
--------------------------------------------------------------------

--- Decompose a complex request into parallel waves of sub-tasks.
--- callback(waves, err)
function M._decompose(request, callback)
	local context, go_rules = M._gather_context(request)

	local prompt = string.format(M.DECOMPOSE_PROMPT, request, context, go_rules)

	-- Log
	local log = require("dwight.log")
	local job_id = log._next_id()
	log.start(
		job_id,
		"swarm:decompose",
		api.nvim_get_current_buf(),
		0,
		0,
		"DwightSwarm decomposition: " .. request:sub(1, 200)
	)

	require("dwight.skills")._run_llm(prompt, function(raw, code)
		if code ~= 0 or not raw or vim.trim(raw) == "" then
			local err_msg = "Swarm decomposition failed (exit " .. tostring(code) .. ")"
			log.finish(job_id, "error", raw or "", nil, err_msg)
			callback(nil, err_msg)
			return
		end

		-- Save raw output
		pcall(function()
			local project = require("dwight.project")
			if project.is_initialized() then
				local path = project.dir() .. "/swarm-decompose-last.txt"
				local lf = io.open(path, "w")
				if lf then
					lf:write("-- DwightSwarm decomposition\n-- " .. os.date() .. "\n\n")
					lf:write(raw)
					lf:close()
				end
			end
		end)

		local waves = M._parse_waves(raw)
		if #waves == 0 then
			-- Retry once with correction prompt
			local retry_prompt = string.format(
				"Your previous response did NOT contain the required <waves>/<wave>/<task> XML blocks. "
					.. "Rewrite as the REQUIRED format. Your response MUST contain:\n\n"
					.. '<waves>\n<wave number="1">\n'
					.. '<task order="1" title="...">\n<files>...</files>\n...\n</task>\n'
					.. "</wave>\n</waves>\n\n"
					.. "Produce ONLY the <waves> XML block.\n"
					.. "The original request was: %s",
				request:sub(1, 200)
			)

			require("dwight.skills")._run_llm(retry_prompt, function(retry_raw, retry_code)
				if retry_code ~= 0 or not retry_raw then
					log.finish(job_id, "parse_fail", raw, nil, "No waves parsed, retry failed")
					callback(nil, "No waves parsed from decomposition output")
					return
				end

				local retry_waves = M._parse_waves(retry_raw)
				if #retry_waves == 0 then
					log.finish(job_id, "parse_fail", retry_raw, nil, "No waves parsed after retry")
					callback(nil, "No waves parsed even after retry")
					return
				end

				log.finish(job_id, "success", retry_raw, nil, nil)
				callback(retry_waves, nil)
			end)
			return
		end

		-- Validate file scopes
		for _, wave in ipairs(waves) do
			local conflicts = M._validate_wave(wave)
			if #conflicts > 0 then
				-- Auto-fix: split conflicting tasks into separate waves
				-- For now, just warn (the preview lets the user fix it)
				for _, c in ipairs(conflicts) do
					vim.schedule(function()
						vim.notify("[dwight] Swarm conflict in wave " .. wave.wave .. ": " .. c, vim.log.levels.WARN)
					end)
				end
			end
		end

		log.finish(job_id, "success", raw, string.format("%d waves", #waves), nil)

		callback(waves, nil)
	end)
end

return M
