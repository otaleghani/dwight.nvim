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

	-- Pre-work: optional git checkpoint
	local cfg = require("dwight").config
	local pre_checkpoint_sha = nil
	pcall(function()
		local status_out = vim.fn.system("git status --porcelain 2>/dev/null")
		if status_out and vim.trim(status_out) ~= "" then
			local count = 0
			for _ in status_out:gmatch("[^\n]+") do
				count = count + 1
			end
			if cfg.agent_checkpoint ~= false then
				vim.fn.system("git add -A 2>/dev/null")
				vim.fn.system('git commit -m "dwight: pre-agent checkpoint" --no-verify 2>/dev/null')
				if vim.v.shell_error == 0 then
					pre_checkpoint_sha = vim.trim(vim.fn.system("git rev-parse HEAD 2>/dev/null"))
					status_mod.append(string.format("Pre-agent checkpoint (%d files)", count))
				end
			else
				status_mod.append(string.format("WARN: %d uncommitted change(s) in working tree", count))
				status_mod.append("   Tip: commit or stash first, or use :DwightGit stash")
			end
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

	-- Inject recent session context (cross-mode bridge)
	pcall(function()
		local integration = require("dwight.integration")
		local last_ctx = integration.read_last_session_context()
		if last_ctx then
			context = context .. "\n\n" .. last_ctx
		end
	end)

	-- Inject pre-approved plan if available
	if opts._plan_context then
		context = context .. "\n" .. opts._plan_context
	end

	local started = os.time()
	local session_id = os.date("%Y%m%d-%H%M%S")
	local safe_name = request:sub(1, 30):gsub("[^%w_%-]", "-"):gsub("%-+", "-")

	-- Track tool activity for compact display
	local tool_counts = { reads = 0, writes = 0, edits = 0, cmds = 0, searches = 0, other = 0 }
	local tool_log = {} -- detailed tool descriptions for foldable section

	local function classify_tool(desc)
		if desc:match("^Read ") then
			return "reads"
		elseif desc:match("^Write ") then
			return "writes"
		elseif desc:match("^Edit ") then
			return "edits"
		elseif desc:match("^%$ ") or desc:match("^Tool: Bash") then
			return "cmds"
		elseif desc:match("^Search ") or desc:match("^List ") then
			return "searches"
		else
			return "other"
		end
	end

	local function fmt_tools()
		local parts = {}
		if tool_counts.reads > 0 then
			parts[#parts + 1] = tool_counts.reads .. "r"
		end
		if tool_counts.writes > 0 then
			parts[#parts + 1] = tool_counts.writes .. "w"
		end
		if tool_counts.edits > 0 then
			parts[#parts + 1] = tool_counts.edits .. "e"
		end
		if tool_counts.cmds > 0 then
			parts[#parts + 1] = tool_counts.cmds .. "cmd"
		end
		if tool_counts.searches > 0 then
			parts[#parts + 1] = tool_counts.searches .. "s"
		end
		if tool_counts.other > 0 then
			parts[#parts + 1] = tool_counts.other .. "?"
		end
		if #parts == 0 then
			return ""
		end
		return " [" .. table.concat(parts, " ") .. "]"
	end

	-- Snapshot git HEAD before execution for post-session diff
	local pre_head = nil
	pcall(function()
		local out = vim.fn.system("git rev-parse HEAD 2>/dev/null")
		if vim.v.shell_error == 0 then
			pre_head = vim.trim(out)
		end
	end)

	status_mod.phase("Execution")

	agentic.run({
		task = request,
		context = context,

		on_status = function(text)
			-- Only surface structured events (test/build results) in the buffer
			if text:match("Tests? FAILED") or text:match("Build failed") then
				status_mod.stop_spin()
				if #text > 60 then
					status_mod.error_block(text:sub(1, 56), text:sub(1, 1000))
				else
					status_mod.append_hl("  " .. text:sub(1, 200), "DwightFail")
				end
				status_mod.spin("working..." .. fmt_tools() .. "  " .. (os.time() - started) .. "s")
			elseif text:match("Tests? passed") or text:match("Build OK") then
				status_mod.stop_spin()
				status_mod.append_hl("  " .. text:sub(1, 200), "DwightOK")
				status_mod.spin("working..." .. fmt_tools() .. "  " .. (os.time() - started) .. "s")
			end
			-- Always log to session_log
			pcall(function()
				if #text > 5 then
					require("dwight.session_log").append(text:sub(1, 500))
				end
			end)
		end,

		on_tool = function(desc)
			-- Increment counter and update spinner in-place
			local key = classify_tool(desc)
			tool_counts[key] = tool_counts[key] + 1
			tool_log[#tool_log + 1] = desc:sub(1, 120)
			local action = desc:sub(1, 25)
			status_mod.spin("working..." .. fmt_tools() .. "  " .. (os.time() - started) .. "s  " .. action)
			-- Log detail to session_log
			pcall(function()
				require("dwight.session_log").append("  " .. desc)
			end)
		end,

		on_complete = function(success, data)
			local duration = os.time() - started
			status_mod.stop_spin()

			status_mod.phase("Results")

			-- Foldable detail section with all tool calls (grouped by type)
			status_mod.tool_fold(tool_log, tool_counts)

			status_mod.end_session(success, duration)

			-- Post-session diff review: show what changed
			status_mod.phase("Diff")
			diff_mod._show_post_diff(status_mod, pre_head)

			-- Post-agent: git checkpoint
			if cfg.agent_checkpoint ~= false then
				pcall(function()
					local status_out = vim.fn.system("git status --porcelain 2>/dev/null")
					if status_out and vim.trim(status_out) ~= "" then
						vim.fn.system("git add -A 2>/dev/null")
						local msg = require("dwight.integration").smart_commit_message(1, 1, request:sub(1, 60))
						vim.fn.system(
							string.format("git commit -m %s --no-verify 2>/dev/null", vim.fn.shellescape(msg))
						)
						if vim.v.shell_error == 0 then
							status_mod.append("Post-agent checkpoint committed")
						end
					end
				end)
			end

			-- Post-agent: optional verification gates
			status_mod.phase("Verification")
			if cfg.agent_gates ~= false and success then
				pcall(function()
					local gates = require("dwight.gates")
					gates.run_all(status_mod, function(gate_passed, gate_output)
						if gate_passed then
							status_mod.append_hl("  Verification gates passed", "DwightOK")
						else
							status_mod.append_hl("  Verification gates FAILED", "DwightFail")
							status_mod.append_hl("  Run :DwightAgent /fix or review manually", "DwightDim")
						end
					end)
				end)
			end

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

			-- Write last session summary (cross-mode context bridge)
			pcall(function()
				local integration = require("dwight.integration")
				integration.write_last_session({
					mode = "agent",
					request = request,
					success = success,
					duration = duration,
					cost = status_mod.session_cost and status_mod.session_cost() or 0,
				})
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
