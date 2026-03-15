-- dwight/auto/decompose.lua
-- Task decomposition prompt and parsing

local M = {}

local api = vim.api

M.DECOMPOSE_PROMPT = [=[
You are Dwight, an autonomous coding agent. The developer wants a complex feature built.
Your job is to DECOMPOSE it into small, sequential sub-tasks that can each be executed
independently by a DwightAgent session (max 5-6 steps each).

The developer wants: %s

Project context:
%s

DECOMPOSITION RULES:
1. Each sub-task MUST be independently verifiable (tests pass after each sub-task).
2. Sub-tasks execute SEQUENTIALLY — each one can depend on files from previous ones.
3. Each sub-task should be small enough for a single DwightAgent plan (5-6 steps max).
4. Order matters: foundational work first (types, interfaces), then implementation, then wiring.
5. Include what each sub-task should produce (files, interfaces, tests).
6. MAXIMUM 8 sub-tasks. If the feature needs more, you're decomposing too finely.
7. Each sub-task description must be CONCRETE: include file paths, function names, types.
8. Do NOT include sub-tasks for "review" or "cleanup" — each sub-task should produce clean code.

USE THE EXPLORED CODE:
If <explored_code> is included above, you MUST base your decisions on the ACTUAL code:
- Use the EXACT interface names, method signatures, and type definitions from the code.
- Match the EXISTING testing patterns (test framework, assertion style, mock patterns).
- Reference the ACTUAL file structure and import paths from the project.
- Do NOT invent function signatures that don't match the existing interfaces.
- If the code shows a particular pattern (e.g., dependency injection, middleware chain),
  your sub-tasks should follow that same pattern.

CRITICAL — TDD ORDERING WITHIN EACH TASK:
9. Each sub-task MUST follow test-first order: write tests FIRST (verify-fail), then implement.
   NEVER put "implement handlers" before "write tests". The agent is more reliable when
   tests exist before implementation — it gives the on-fail handler something to target.

CRITICAL — FILE GROWTH AWARENESS:
10. If multiple sub-tasks edit the SAME file (e.g., server.go, server_test.go), be aware that
    each edit makes the file larger and harder for the agent to handle. When a file has been
    edited by 2+ prior tasks:
    - The sub-task description MUST list all existing functions/types in that file so the agent
      knows what to preserve.
    - Keep each edit step to 1-2 new functions maximum.
    - If adding 4+ functions to an already-edited file, split into two sub-tasks.
11. When a test file has been edited by prior tasks and needs NEW mock behavior (e.g., changing
    a stateless mock to stateful), this is a STRUCTURAL change. It should be its own step with
    a read action first, not combined with adding test functions.

CRITICAL — HANDLER + ROUTE WIRING IN SAME STEP:
12. When a sub-task implements HTTP handler functions, it MUST ALSO register the routes/endpoints
    for those handlers IN THE SAME SUB-TASK. NEVER split "implement handlers" and "register
    routes" into separate sub-tasks — the tests call the server's ServeHTTP/mux which returns
    404 for unregistered routes, so the verify step will fail if routes aren't registered.
    If handlers go in handlers.go and routes are registered in server.go, BOTH files must be
    edited in the same sub-task.

CRITICAL — TEMPLATE LOADING MUST USE EMBED:
13. When adding HTML template rendering to a Go web server, ALWAYS use `//go:embed templates/*.html`
    with `embed.FS` and `template.ParseFS`. NEVER use `template.Must(template.ParseGlob(...))` in
    a constructor — it panics during tests because the working directory differs. The sub-task
    description MUST specify embed.FS, not ParseGlob. Example: "Use `//go:embed templates/*.html`
    with `template.ParseFS` to load templates."

CRITICAL — FEATURE PRAGMA PROPAGATION:
14. This project tracks feature boundaries using `@feature:name` pragma comments on line 1 of
    source files. If the <project> context above lists features, ANY sub-task that creates new
    files belonging to an existing feature MUST include an instruction to add the pragma.
    Example: if splitting `auth.lua` (@feature:auth) into `auth/login.lua` and `auth/signup.lua`,
    the sub-task description must say: "Add `-- @feature:auth` on line 1 of each new file."
    Without this, the feature system loses track of the new files.

RESPOND IN THIS EXACT FORMAT (one sub-task per <task> block):

<tasks>
<task order="1" title="Short title">
Concrete description of what to build. Include:
- Exact file paths to create/edit
- Function signatures and types
- What tests to write
- What the verify command should be
</task>
<task order="2" title="Short title" depends_on="1">
...
</task>
</tasks>

IMPORTANT:
- The depends_on attribute is informational only — all tasks run sequentially.
- Each task description becomes the "request" for a DwightAgent session.
- Make descriptions detailed enough that the agent can execute correctly WITHOUT
  seeing the decomposition context. Each task description must be self-contained.
- If a task edits files created by a previous task, mention the file paths explicitly.

CRITICAL OUTPUT FORMAT RULES:
- Your response MUST contain <tasks>...</tasks> with at least 2 <task> blocks inside.
- Do NOT write a prose summary, overview, or architecture description instead of tasks.
- Do NOT explain the plan — just produce the <task> blocks.
- If you want to think through the design first, do so BRIEFLY, then ALWAYS follow with
  the <tasks> XML block containing the actual decomposition.
- Start your <tasks> block as early as possible in the response.
]=]

--- Parse decomposition XML into task list.
--- Returns { { order, title, description, depends_on }, ... }
--- Robust: handles attribute reordering, extra whitespace, markdown fences, fallback formats.
function M._parse_tasks(raw)
	local tasks = {}

	-- Strip markdown code fences if the LLM wrapped the output
	local cleaned = raw:gsub("```xml%s*\n?", ""):gsub("```%s*\n?", "")

	-- Strategy 1: Parse <task ...>...</task> blocks with flexible attribute extraction
	for attrs, body in cleaned:gmatch("<task%s+(.-)>(.-)</task>") do
		-- Extract attributes in any order
		local order_str = attrs:match('order="(%d+)"') or attrs:match("order='(%d+)'")
		local title = attrs:match('title="([^"]*)"') or attrs:match("title='([^']*)'")
		local depends = attrs:match('depends_on="([^"]*)"') or attrs:match("depends_on='([^']*)'")

		-- Title might span to a newline if attributes are on separate lines
		if not title then
			title = attrs:match('title="([^"]+)') -- unclosed quote (newline before close)
		end

		if title then
			tasks[#tasks + 1] = {
				order = tonumber(order_str) or #tasks + 1,
				title = vim.trim(title),
				description = vim.trim(body),
				depends_on = depends,
			}
		end
	end

	-- Strategy 2: Fallback — markdown headings like:
	--   ## Task 1: Title       ## Step 1: Title
	--   ### Task 1: Title      ### Step 1 - Title
	--   ### Sub-task 1: Title
	-- Handles any heading level (##, ###, ####), any keyword (Task/Step/Sub-task).
	-- NOTE: Lua patterns use + * - ? only. NO {2,} quantifier!
	--   ###* matches "##" + optional extra "#"s = 2+ hashes.
	if #tasks == 0 then
		local current_title, current_order, current_body

		-- More specific patterns tried in order
		-- ###* matches "##" + optional extra "#"s = any heading level 2+
		-- [:%.%-%s] as separator handles : - . and whitespace
		local heading_patterns = {
			"^###*%s*[Ss]tep%s+(%d+)%s*[:%.%-]+%s*(.+)",
			"^###*%s*[Tt]ask%s+(%d+)%s*[:%.%-]+%s*(.+)",
			"^###*%s*[Ss]ub%-?[Tt]ask%s+(%d+)%s*[:%.%-]+%s*(.+)",
			"^###*%s*(%d+)%s*[:%.%-]+%s*(.+)", -- ### 1: Title (number only)
		}

		local function try_heading(line)
			for _, pat in ipairs(heading_patterns) do
				local num, t = line:match(pat)
				if num then
					return tonumber(num), t
				end
			end
			return nil, nil
		end

		for line in (cleaned .. "\n"):gmatch("([^\n]*)\n") do
			local num, t = try_heading(line)
			if num then
				-- Save previous task
				if current_title and current_body then
					tasks[#tasks + 1] = {
						order = current_order,
						title = vim.trim(current_title),
						description = vim.trim(current_body),
					}
				end
				current_order = num
				current_title = t
				current_body = ""
			elseif current_title then
				current_body = (current_body or "") .. line .. "\n"
			end
		end
		-- Don't forget the last task!
		if current_title and current_body then
			tasks[#tasks + 1] = {
				order = current_order,
				title = vim.trim(current_title),
				description = vim.trim(current_body),
			}
		end
	end

	-- Strategy 3: Fallback — numbered list: 1. **Title**: description
	if #tasks == 0 then
		for num, title, desc in cleaned:gmatch("(%d+)%.%s+%*%*([^*]+)%*%*:?%s*([^\n]+)") do
			tasks[#tasks + 1] = {
				order = tonumber(num) or #tasks + 1,
				title = vim.trim(title),
				description = vim.trim(desc),
			}
		end
	end

	-- Sort by order
	table.sort(tasks, function(a, b)
		return a.order < b.order
	end)
	return tasks
end

--- Decompose a complex request into sub-tasks.
--- Uses exploration-informed approach: reads key project files before decomposing
--- so the LLM makes decisions grounded in actual code, not just file names.
--- callback(tasks, err)
function M._decompose(request, callback)
	-- Phase 1: Gather project context (tree, manifest, pragmas)
	local context_parts = {}
	local project_info = nil

	pcall(function()
		local ctx = require("dwight.context")
		project_info = ctx.scan()
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
		local names = features.names()
		if #names > 0 then
			context_parts[#context_parts + 1] = "Features: " .. table.concat(names, ", ")
		end
	end)

	local tree_lines = {}
	pcall(function()
		local bootstrap = require("dwight.bootstrap")
		local scan = bootstrap.scan()
		if scan.tree and #scan.tree > 0 then
			for _, line in ipairs(scan.tree) do
				tree_lines[#tree_lines + 1] = line
				if #tree_lines >= 60 then
					break
				end
			end
			context_parts[#context_parts + 1] = "<project_tree>\n"
				.. table.concat(tree_lines, "\n")
				.. "\n</project_tree>"
		end
	end)

	-- Inject skills + libs + pragma instructions via integration module
	pcall(function()
		local integration = require("dwight.integration")
		local full_ctx = integration.build_full_context()
		if full_ctx then
			context_parts[#context_parts + 1] = full_ctx
		end

		-- Feature-scoped context: if the request references specific features,
		-- inject their full signatures so decomposition is grounded in actual code
		local feature_ctx = integration.build_feature_context(request)
		if feature_ctx then
			context_parts[#context_parts + 1] = feature_ctx
		end
	end)

	-- Phase 2: Exploration — auto-read key files relevant to the request.
	-- This is what makes decomposition much better: the LLM sees actual code.
	local exploration_parts = {}
	local cwd = vim.fn.getcwd()
	local total_exploration_chars = 0
	local MAX_EXPLORATION_CHARS = 20000 -- Cap to avoid prompt bloat

	--- Read a file if it exists and we have budget, return content or nil.
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
		-- Cap individual files
		if #content > 4000 then
			content = content:sub(1, 4000) .. "\n... (truncated)"
		end
		total_exploration_chars = total_exploration_chars + #content
		return content
	end

	-- Strategy: read files that are most likely relevant to the request.
	-- Priority tiers (higher = read first):
	--   1. Interface/type definition files (the contracts)
	--   2. Files whose names match request keywords
	--   3. Main entry point, server/router wiring
	--   4. Existing test files (testing patterns)
	--   5. Config/README for project conventions

	local explore_patterns = {
		-- Tier 1: Interfaces and types (highest priority)
		{ pattern = "interface", desc = "interface definitions", priority = 10 },
		{ pattern = "types", desc = "type definitions", priority = 10 },
		{ pattern = "models", desc = "data models", priority = 9 },
		{ pattern = "schema", desc = "schema definitions", priority = 9 },
		-- Tier 2: Server/app wiring
		{ pattern = "server", desc = "server/app setup", priority = 7 },
		{ pattern = "router", desc = "routing", priority = 7 },
		{ pattern = "routes", desc = "routes", priority = 7 },
		{ pattern = "app", desc = "app setup", priority = 6 },
		{ pattern = "main", desc = "entry point", priority = 6 },
		-- Tier 3: Test files (learn testing patterns)
		{ pattern = "_test", desc = "test patterns", priority = 5 },
		{ pattern = "test_", desc = "test patterns", priority = 5 },
		{ pattern = ".spec", desc = "test patterns", priority = 5 },
		-- Tier 4: Config (project conventions)
		{ pattern = "config", desc = "configuration", priority = 3 },
		{ pattern = "readme", desc = "project documentation", priority = 2 },
	}

	-- Also look for files mentioned in or relevant to the request
	local request_lower = request:lower()
	local request_keywords = {}
	for word in request_lower:gmatch("%w+") do
		if #word > 3 then
			request_keywords[word] = true
		end
	end

	-- Scan tree for matching files, score by priority
	local scored_files = {}
	local files_seen = {}
	for _, line in ipairs(tree_lines) do
		if not line:match("/$") then -- skip directories
			local basename = line:match("[^/]+$") or line
			local base_lower = basename:lower()
			local best_priority = 0
			local best_reason = ""

			-- Check against explore patterns
			for _, ep in ipairs(explore_patterns) do
				if base_lower:match(ep.pattern) and ep.priority > best_priority then
					best_priority = ep.priority
					best_reason = ep.desc
				end
			end

			-- Check against request keywords (high priority — directly relevant)
			for kw in pairs(request_keywords) do
				if base_lower:match(kw) then
					best_priority = math.max(best_priority, 8) -- between interfaces and server
					best_reason = "matches request keyword '" .. kw .. "'"
				end
			end

			-- Content-based scoring: peek at first 200 bytes to check relevance
			if best_priority == 0 and not files_seen[line] then
				pcall(function()
					local peek_f = io.open(cwd .. "/" .. line, "r")
					if peek_f then
						local peek = peek_f:read(500)
						peek_f:close()
						if peek then
							local peek_lower = peek:lower()
							local keyword_hits = 0
							for kw in pairs(request_keywords) do
								if peek_lower:find(kw, 1, true) then
									keyword_hits = keyword_hits + 1
								end
							end
							if keyword_hits >= 2 then
								best_priority = 4 + keyword_hits -- scale with relevance
								best_reason = string.format("content matches %d request keywords", keyword_hits)
							end
						end
					end
				end)
			end

			if best_priority > 0 and not files_seen[line] then
				files_seen[line] = true
				scored_files[#scored_files + 1] = {
					path = line,
					reason = best_reason,
					priority = best_priority,
				}
			end
		end
	end

	-- Sort by priority (highest first) so we read the most important files within budget
	table.sort(scored_files, function(a, b)
		return a.priority > b.priority
	end)

	-- Limit test files to 2 max (we want patterns, not all tests)
	local test_count = 0
	local files_to_read = {}
	for _, entry in ipairs(scored_files) do
		if entry.reason == "test patterns" then
			test_count = test_count + 1
			if test_count > 2 then
				goto continue
			end
		end
		files_to_read[#files_to_read + 1] = entry
		::continue::
	end

	-- Read the files (most important first, cap at budget)
	for _, entry in ipairs(files_to_read) do
		local content = explore_file(entry.path)
		if content then
			exploration_parts[#exploration_parts + 1] = string.format(
				'<explored_file path="%s" reason="%s">\n%s\n</explored_file>',
				entry.path,
				entry.reason,
				content
			)
		end
	end

	if #exploration_parts > 0 then
		context_parts[#context_parts + 1] = "\n<explored_code>\n"
			.. "The following files were auto-read to help you understand the codebase. "
			.. "Use this code to make SPECIFIC, GROUNDED decisions about file paths, "
			.. "function signatures, interface contracts, and testing patterns.\n\n"
			.. table.concat(exploration_parts, "\n\n")
			.. "\n</explored_code>"
	end

	-- Phase 3: Build prompt and call LLM
	local context = #context_parts > 0 and table.concat(context_parts, "\n\n") or "(no context)"
	local prompt = string.format(M.DECOMPOSE_PROMPT, request, context)

	-- Log the decomposition call to DwightLog
	local log = require("dwight.log")
	local job_id = log._next_id()
	log.start(
		job_id,
		"auto:decompose",
		api.nvim_get_current_buf(),
		0,
		0,
		"DwightAuto decomposition: " .. request:sub(1, 200) .. "\n\n" .. prompt:sub(1, 4000)
	)
	-- Set metadata for DwightLog display
	pcall(function()
		local cfg = require("dwight").config
		local backend = cfg.backend or "api"
		local model = "?"
		if backend == "claude_code" then
			model = cfg.claude_code_model or "claude-code"
		else
			local providers = require("dwight.providers")
			local resolved = providers.resolve_model(nil)
			model = resolved.model_id or "?"
		end
		log.set_metadata(job_id, {
			model = model,
			backend = backend,
		})
	end)

	require("dwight.skills")._run_llm(prompt, function(raw, code)
		if code ~= 0 or not raw or vim.trim(raw) == "" then
			local detail = ""
			if not raw or vim.trim(raw or "") == "" then
				detail = " (empty response)"
			end
			local err_msg = "Decomposition LLM failed (exit " .. tostring(code) .. ")" .. detail
			log.finish(job_id, "error", raw or "", nil, err_msg)
			callback(nil, err_msg)
			return
		end

		-- Log raw output for debugging (write to .dwight/ if possible)
		pcall(function()
			local project = require("dwight.project")
			if project.is_initialized() then
				local log_path = project.dir() .. "/decompose-last.txt"
				local lf = io.open(log_path, "w")
				if lf then
					lf:write("-- DwightAuto decomposition output\n")
					lf:write("-- Request: " .. request:sub(1, 200) .. "\n")
					lf:write("-- Timestamp: " .. os.date() .. "\n\n")
					lf:write(raw)
					lf:close()
				end
			end
		end)

		local tasks = M._parse_tasks(raw)
		if #tasks == 0 then
			-- RETRY: The LLM may have returned a summary instead of structured tasks.
			-- Re-prompt once with a correction.
			log.append_note(job_id, "0 tasks parsed from first attempt, retrying with correction prompt")

			local retry_prompt = string.format(
				"Your previous response did NOT contain the required <task> XML blocks. "
					.. "You gave a prose summary instead. Here is what you wrote:\n\n"
					.. "---\n%s\n---\n\n"
					.. "Now rewrite this as the REQUIRED format. Your response MUST contain:\n\n"
					.. "<tasks>\n"
					.. '<task order="1" title="Short title">\nConcrete description...\n</task>\n'
					.. '<task order="2" title="Short title">\nConcrete description...\n</task>\n'
					.. "</tasks>\n\n"
					.. "Produce ONLY the <tasks> XML block. No preamble, no summary, no explanation.\n"
					.. "The original request was: %s",
				raw:sub(1, 3000),
				request:sub(1, 200)
			)

			require("dwight.skills")._run_llm(retry_prompt, function(retry_raw, retry_code)
				if retry_code ~= 0 or not retry_raw or vim.trim(retry_raw) == "" then
					local preview = raw:sub(1, 500):gsub("\n", " "):gsub("%s+", " ")
					local err_msg = "No tasks found in decomposition output (retry also failed). "
						.. "Check .dwight/decompose-last.txt for full LLM response. "
						.. "Preview: "
						.. preview
					log.finish(job_id, "parse_fail", raw, nil, err_msg)
					callback(nil, err_msg)
					return
				end

				-- Save retry output too
				pcall(function()
					local project = require("dwight.project")
					if project.is_initialized() then
						local log_path = project.dir() .. "/decompose-retry.txt"
						local lf = io.open(log_path, "w")
						if lf then
							lf:write("-- DwightAuto decomposition RETRY output\n")
							lf:write("-- Timestamp: " .. os.date() .. "\n\n")
							lf:write(retry_raw)
							lf:close()
						end
					end
				end)

				local retry_tasks = M._parse_tasks(retry_raw)
				if #retry_tasks == 0 then
					local preview = retry_raw:sub(1, 500):gsub("\n", " "):gsub("%s+", " ")
					local err_msg = "No tasks found even after retry. "
						.. "Check .dwight/decompose-retry.txt. "
						.. "Preview: "
						.. preview
					log.finish(job_id, "parse_fail", retry_raw, nil, err_msg)
					callback(nil, err_msg)
					return
				end

				-- Retry succeeded
				local task_summary = {}
				for _, t in ipairs(retry_tasks) do
					task_summary[#task_summary + 1] = string.format("%d. %s", t.order, t.title)
				end
				log.finish(
					job_id,
					"success",
					retry_raw,
					string.format("%d tasks (after retry):\n%s", #retry_tasks, table.concat(task_summary, "\n")),
					nil
				)

				callback(retry_tasks, nil)
			end)
			return
		end

		-- Log success
		local task_summary = {}
		for _, t in ipairs(tasks) do
			task_summary[#task_summary + 1] = string.format("%d. %s", t.order, t.title)
		end
		log.finish(
			job_id,
			"success",
			raw,
			string.format("%d tasks:\n%s", #tasks, table.concat(task_summary, "\n")),
			nil
		)

		callback(tasks, nil)
	end)
end

return M
