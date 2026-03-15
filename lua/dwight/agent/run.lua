-- dwight/agent/run.lua
-- Main entry point for DwightAgent: orchestrates plan -> execute -> diff -> lessons.

local M = {}

--------------------------------------------------------------------
-- Complexity heuristic
--------------------------------------------------------------------

--- Heuristic: is the request complex enough to benefit from planning?
local function request_is_complex(request)
	local word_count = 0
	for _ in request:gmatch("%S+") do
		word_count = word_count + 1
	end

	-- Multiple files mentioned
	local file_refs = 0
	for _ in request:gmatch("[%w_%-/]+%.[%w]+") do
		file_refs = file_refs + 1
	end

	-- Multiple action verbs
	local actions = 0
	for _, verb in ipairs({
		"add",
		"create",
		"fix",
		"refactor",
		"update",
		"implement",
		"remove",
		"delete",
		"move",
		"rename",
		"change",
		"modify",
		"write",
		"build",
	}) do
		if request:lower():find(verb, 1, true) then
			actions = actions + 1
		end
	end

	return word_count > 40 or file_refs > 2 or actions > 2
end

--------------------------------------------------------------------
-- Main entry point
--------------------------------------------------------------------

function M.run(request, opts)
	opts = opts or {}

	if not request or vim.trim(request) == "" then
		require("dwight.ui").open_prompt(nil, {
			dispatch = "agent",
			agent_opts = opts,
		})
		return
	end

	local plan_mod = require("dwight.agent.plan")

	-- If caller explicitly set plan mode, respect it
	local plan_mode = opts.plan

	-- Auto-detect: suggest plan for complex requests (unless opts.plan == false)
	if plan_mode == nil and request_is_complex(request) then
		plan_mode = true
	end

	-- Skip planning: jump straight in
	if plan_mode == false or opts._skip_plan then
		M._run_agentic(request, opts)
		return
	end

	-- Plan mode: generate plan first, then show preview
	if plan_mode then
		vim.notify("[dwight] Generating execution plan…", vim.log.levels.INFO)

		plan_mod._generate_plan(request, function(plan, _raw)
			if not plan then
				-- Plan generation failed — fall back to direct execution
				vim.notify("[dwight] Plan generation failed — launching agent directly.", vim.log.levels.WARN)
				M._run_agentic(request, opts)
				return
			end

			plan_mod._show_plan_buffer(request, plan, function(action, plan_data, final_request)
				if action == "run" then
					-- Feed plan as additional context to the agent
					local plan_context = plan_mod._plan_to_context(plan_data)
					opts._plan_context = plan_context
					M._run_agentic(final_request, opts)
				elseif action == "auto" then
					require("dwight.auto").auto(final_request)
				end
				-- "cancel" -> do nothing
			end)
		end)
		return
	end

	-- Default: offer mode choice for ambiguous complexity
	M._run_agentic(request, opts)
end

--------------------------------------------------------------------
-- Agentic mode: tool-use loop (optional plan context injected by M.run)
--------------------------------------------------------------------

function M._run_agentic(request, opts)
	opts = opts or {}
	local agentic = require("dwight.agentic")
	local status_mod = require("dwight.agent_status")
	local gather_project_context = require("dwight.agent")._gather_project_context
	local lessons_mod = require("dwight.agent.lessons")
	local diff_mod = require("dwight.agent.diff")
	local sessions_mod = require("dwight.agent.sessions")

	status_mod.start_session(request)
	if opts._plan_context then
		status_mod.append("Running with pre-approved plan")
	else
		status_mod.append("Running in agentic mode (tool-use loop)")
	end

	-- Pre-work git safety: warn about dirty state
	pcall(function()
		local status_out = vim.fn.system("git status --porcelain 2>/dev/null")
		if status_out and vim.trim(status_out) ~= "" then
			local count = 0
			for _ in status_out:gmatch("[^\n]+") do
				count = count + 1
			end
			status_mod.append(string.format("WARN: %d uncommitted change(s) in working tree", count))
			status_mod.append("   Tip: commit or stash first, or use :DwightGit stash")
		end
	end)

	-- Build project context
	local context = gather_project_context()

	-- Inject lessons
	local lessons = lessons_mod._find_relevant_lessons(request)
	if #lessons > 0 then
		local parts = {}
		for _, l in ipairs(lessons) do
			parts[#parts + 1] = "- " .. l.text
		end
		context = context .. "\n\n## Lessons from Past Sessions\n" .. table.concat(parts, "\n")
	end

	-- Inject feature-scoped context if the request references specific features
	pcall(function()
		local integration = require("dwight.integration")
		local feature_ctx = integration.build_feature_context(request)
		if feature_ctx then
			context = context .. "\n\n" .. feature_ctx
		end
	end)

	-- Inject pre-approved plan if available
	if opts._plan_context then
		context = context .. "\n" .. opts._plan_context
	end

	local started = os.time()
	local session_id = os.date("%Y%m%d-%H%M%S")
	local safe_name = request:sub(1, 30):gsub("[^%w_%-]", "-"):gsub("%-+", "-")

	-- Track tool activity for richer status display
	local tool_counts = { read = 0, write = 0, edit = 0, run = 0 }
	local last_tool_type = nil

	-- Snapshot git HEAD before execution for post-session diff
	local pre_head = nil
	pcall(function()
		local out = vim.fn.system("git rev-parse HEAD 2>/dev/null")
		if vim.v.shell_error == 0 then
			pre_head = vim.trim(out)
		end
	end)

	agentic.run({
		task = request,
		context = context,

		on_status = function(text)
			if #text > 15 then
				status_mod.stop_spin()
				status_mod.append(text:sub(1, 500))
			end
		end,

		on_tool = function(desc)
			-- Categorize and count tool usage
			local tool_type = desc:match("^Read ") and "read"
				or desc:match("^Write ") and "write"
				or desc:match("^Edit ") and "edit"
				or desc:match("^%$ ") and "run"
				or desc:match("^Search ") and "search"
				or desc:match("^List ") and "list"
				or "other"

			if tool_counts[tool_type] then
				tool_counts[tool_type] = tool_counts[tool_type] + 1
			else
				tool_counts[tool_type] = 1
			end

			-- Persist every tool call as a permanent indented line
			status_mod.stop_spin()
			status_mod.append("  " .. desc)

			-- Spin with generic working message
			status_mod.spin("working...")
		end,

		on_complete = function(success, data)
			local duration = os.time() - started
			status_mod.stop_spin()

			-- Show tool usage summary before final status
			local tool_parts = {}
			if tool_counts.read > 0 then
				tool_parts[#tool_parts + 1] = tool_counts.read .. " reads"
			end
			if tool_counts.write > 0 then
				tool_parts[#tool_parts + 1] = tool_counts.write .. " writes"
			end
			if tool_counts.edit > 0 then
				tool_parts[#tool_parts + 1] = tool_counts.edit .. " edits"
			end
			if tool_counts.run > 0 then
				tool_parts[#tool_parts + 1] = tool_counts.run .. " commands"
			end
			if (tool_counts.search or 0) > 0 then
				tool_parts[#tool_parts + 1] = tool_counts.search .. " searches"
			end
			if #tool_parts > 0 then
				status_mod.append("Tool usage: " .. table.concat(tool_parts, ", "))
			end

			status_mod.end_session(success, duration)

			-- Post-session diff review: show what changed
			diff_mod._show_post_diff(status_mod, pre_head)

			-- Post-session integration (feature warnings, squash hint, PR hint)
			pcall(function()
				local integration = require("dwight.integration")
				integration.post_session(request, data.journal or {}, status_mod)
			end)

			-- Save session
			pcall(function()
				sessions_mod._save_session({
					id = session_id,
					name = safe_name,
					request = request,
					had_error = not success,
					duration = duration,
					timestamp = started,
					journal = data.journal,
					cost = status_mod.session_cost and status_mod.session_cost() or 0,
					agentic = true,
					summary = data.summary,
				})
			end)

			-- Extract lessons
			pcall(function()
				lessons_mod._extract_lessons(
					{
						request = request,
						had_error = not success,
						timestamp = os.time(),
					},
					data.journal or {},
					function(lessons_out)
						if lessons_out and #lessons_out > 0 then
							lessons_mod._append_lessons(lessons_out)
							status_mod.append(string.format("Learned %d lesson(s)", #lessons_out))
						end
					end
				)
			end)

			if success then
				vim.notify(string.format("[dwight] Agentic: done in %ds!", duration), vim.log.levels.INFO)
			else
				vim.notify("[dwight] Agentic: execution had errors.", vim.log.levels.WARN)
			end

			-- Fire external on_complete callback (used by github.lua for PR flow)
			if opts.on_complete then
				pcall(opts.on_complete, success)
			end
		end,
	})
end

return M
