-- dwight/commands.lua
-- All :Dwight* user commands. Extracted from init.lua for readability.

local M = {}

local function require_mod(name)
	return require("dwight." .. name)
end

local function get_dwight()
	return require("dwight")
end

function M.register()
	local dwight = get_dwight()
	local _flatten = require("dwight.util").flatten_lines
	local cmd = vim.api.nvim_create_user_command

	cmd("DwightInvoke", function(o)
		dwight.invoke({ range = o.range })
	end, { range = true, desc = "Invoke with prompt" })

	cmd("DwightMode", function(o)
		dwight.invoke_mode(o.args, { range = o.range })
	end, {
		nargs = 1,
		range = true,
		complete = function()
			return require_mod("modes").list()
		end,
		desc = "Invoke a mode",
	})

	cmd("DwightCancel", function(o)
		if o.args == "all" then
			dwight.cancel_all()
		else
			dwight.cancel()
		end
	end, {
		nargs = "?",
		complete = function()
			return { "all" }
		end,
		desc = "Cancel job(s)",
	})

	-- Follow-up: refine last inline edit
	cmd("DwightFollowUp", function()
		dwight.follow_up()
	end, { desc = "Refine the last inline edit" })

	-- Dot-repeat: replay last operation on new selection
	cmd("DwightRepeat", function(o)
		dwight.dot_repeat({ range = o.range })
	end, { range = true, desc = "Repeat last dwight operation on current selection" })

	cmd("DwightInit", function()
		require_mod("project").init()
	end, { desc = "Initialize project" })

	-- Bootstrap: scan project + suggest pragmas via LLM
	cmd("DwightBootstrap", function(o)
		local args = vim.trim(o.args or "")
		local opts = {}
		if args:match("%-%-quick") then
			opts.mode = "quick"
		elseif args:match("%-%-agentic") then
			opts.mode = "agentic"
		end
		if args:match("%-%-force") then
			opts.force = true
		end
		if args:match("%-%-incremental") then
			opts.incremental = true
		end
		require_mod("bootstrap").bootstrap(opts)
	end, {
		nargs = "?",
		desc = "Bootstrap project with pragma comments (--quick, --agentic, --force, --incremental)",
	})

	cmd("DwightCoverage", function()
		require_mod("bootstrap").show_coverage()
	end, { desc = "Show pragma coverage: tagged vs untagged source files" })

	-- Multi-file undo
	cmd("DwightMultiUndo", function()
		require_mod("multifile").undo_all()
	end, { desc = "Undo last multi-file change set" })

	-- Interactive undo: pick from recent commits
	cmd("DwightUndo", function()
		require_mod("auto.git").undo_interactive()
	end, { desc = "Undo dwight checkpoint commits interactively" })

	-- Agent: autonomous TDD loop
	cmd("DwightAgent", function(o)
		local args = o.args or ""
		local opts = {}

		-- Parse flags
		if args:match("%-%-plan") then
			opts.plan = true
			args = args:gsub("%-%-plan%s*", "")
		elseif args:match("%-%-jump") then
			opts.plan = false
			args = args:gsub("%-%-jump%s*", "")
		end

		local request = vim.trim(args)

		-- Range provided: use visual selection as the request
		if request == "" and o.range and o.range > 0 then
			local sel = dwight._get_selection({ range = o.range })
			if sel and sel.text and vim.trim(sel.text) ~= "" then
				request = sel.text
			end
		end

		require_mod("agent").run(request ~= "" and request or nil, opts)
	end, {
		nargs = "?",
		range = true,
		desc = "Autonomous agent (--plan = preview plan first, --jump = skip planning)",
	})

	cmd("DwightAgentLog", function()
		require_mod("agent").show_log()
	end, { desc = "Browse agent session logs (Telescope)" })
	cmd("DwightSkills", function()
		require_mod("skills").pick()
	end, { desc = "Browse skills" })

	cmd("DwightModes", function()
		require_mod("modes").pick()
	end, { desc = "Browse available modes" })
	cmd("DwightGenSkill", function()
		require_mod("skills").generate()
	end, { desc = "Generate skill" })
	cmd("DwightInstallSkills", function()
		require_mod("project").install_builtins()
	end, { desc = "Install built-in skills" })

	cmd("DwightMarketplace", function(o)
		local target = o.args ~= "" and o.args or nil
		require_mod("marketplace").run(target)
	end, {
		nargs = "?",
		complete = function()
			return { "install", "suggest", "export", "import", "detect", "kits", "toggle", "uninstall" }
		end,
		desc = "Skill marketplace: browse packs, kits, auto-suggest, import/export",
	})

	cmd("DwightKitStatus", function()
		require_mod("marketplace").kit_status()
	end, { desc = "List installed kits with active/inactive state and MCP server status" })

	cmd("DwightKitToggle", function(o)
		local name = vim.trim(o.args or "")
		if name == "" then
			require_mod("marketplace").kit_toggle_interactive()
		else
			require("dwight.marketplace.kits").toggle(name)
		end
	end, {
		nargs = "?",
		complete = function()
			local ok, kits = pcall(require, "dwight.marketplace.kits")
			if not ok then
				return {}
			end
			return vim.tbl_map(function(k)
				return k.name
			end, kits.installed())
		end,
		desc = "Enable/disable a kit (with completion from installed kit names)",
	})
	cmd("DwightDocsFromURL", function()
		require_mod("skill_fetch").generate_from_url()
	end, { desc = "Generate skill from docs URL" })
	cmd("DwightLog", function()
		require_mod("log").show()
	end, { desc = "Job log" })
	cmd("DwightSessionLog", function()
		require_mod("agent_status").view_session_log()
	end, { desc = "View persistent session log (survives buffer close)" })

	cmd("DwightReplay", function(o)
		local target = o.args ~= "" and o.args or nil
		require_mod("replay").pick(target)
	end, {
		nargs = "?",
		complete = function()
			local ok, replay = pcall(require_mod, "replay")
			if not ok then
				return { "latest" }
			end
			local sessions = replay.list_sessions()
			local items = { "latest" }
			for _, s in ipairs(sessions) do
				items[#items + 1] = s.filename
			end
			return items
		end,
		desc = "Step through a past agent session (latest, or pick from list)",
	})
	cmd("DwightRun", function(o)
		require_mod("runner").run_interactive(o.args)
	end, { nargs = "?", desc = "Run build/test command" })
	cmd("DwightRunOutput", function()
		require_mod("runner").show_output()
	end, { desc = "Show last run output" })
	cmd("DwightUsage", function()
		require_mod("tracker").show()
	end, { desc = "Usage stats" })

	cmd("DwightStats", function(o)
		local target = o.args ~= "" and o.args or nil
		require_mod("stats").show(target)
	end, {
		nargs = "?",
		complete = function()
			return { "features", "export", "csv", "json" }
		end,
		desc = "Telemetry dashboard: usage trends, per-feature stats, success rates, export",
	})

	-- Codebase rehabilitation: audit + heal
	cmd("DwightAudit", function(o)
		local opts = {}
		local args = vim.trim(o.args or "")
		local feature_name = nil

		-- Parse flags: --deep for agentic review, or feature name
		for word in args:gmatch("%S+") do
			if word == "--deep" or word == "--agentic" then
				opts.agentic = true
			else
				feature_name = word
			end
		end

		require_mod("codebase_audit").audit(feature_name, opts)
	end, {
		nargs = "?",
		complete = function()
			return require_mod("features").names()
		end,
		desc = "Audit a feature: static analysis + optional LLM review",
	})

	cmd("DwightHeal", function(o)
		local args = vim.trim(o.args or "")
		local feature_name = args ~= "" and args or nil
		require_mod("codebase_heal").heal(feature_name)
	end, {
		nargs = "?",
		complete = function()
			return require_mod("features").names()
		end,
		desc = "Rehabilitate a feature: char tests + improvement plan + execution",
	})

	-- Autonomous mode: decompose + sequential agent execution
	cmd("DwightAuto", function(o)
		local request = o.args ~= "" and o.args or nil

		-- Range provided: use visual selection as the request
		if not request and o.range and o.range > 0 then
			local sel = dwight._get_selection({ range = o.range })
			if sel and sel.text and vim.trim(sel.text) ~= "" then
				request = sel.text
			end
		end

		require_mod("auto").auto(request)
	end, {
		nargs = "?",
		range = true,
		desc = "Autonomous mode: decompose complex request into sequential agent runs",
	})

	cmd("DwightAutoResume", function(o)
		local opts = {}
		if o.args ~= "" then
			opts.override_prompt = o.args
		end
		require_mod("auto").resume(opts)
	end, {
		nargs = "?",
		desc = "Resume from failed/paused task (optional: override task prompt)",
	})

	cmd("DwightAutoReview", function()
		require_mod("auto").resume({ review = true })
	end, { desc = "Resume with decomposition review" })

	cmd("DwightPause", function()
		require_mod("auto").pause()
	end, { desc = "Pause DwightAuto after the current task completes" })

	cmd("DwightContinue", function(o)
		local prompt = o.args ~= "" and o.args or nil
		require_mod("auto").continue(prompt)
	end, {
		nargs = "?",
		desc = "Continue from paused state (optional: override next task prompt)",
	})

	cmd("DwightAutoSkip", function()
		require_mod("auto").skip()
	end, { desc = "Skip the failed/next task and continue" })

	cmd("DwightAutoRetry", function()
		require_mod("auto").retry()
	end, { desc = "Retry failed task with error context from previous attempt" })

	cmd("DwightAutoCancel", function()
		require_mod("auto").cancel()
	end, { desc = "Cancel active autonomous session" })

	cmd("DwightAutoStatus", function()
		require_mod("auto").status()
	end, { desc = "Show autonomous session status" })

	-- Swarm: parallel multi-agent execution
	cmd("DwightSwarm", function(o)
		local request = o.args ~= "" and o.args or nil

		if not request and o.range and o.range > 0 then
			local sel = dwight._get_selection({ range = o.range })
			if sel and sel.text and vim.trim(sel.text) ~= "" then
				request = sel.text
			end
		end

		require_mod("swarm").swarm(request)
	end, {
		nargs = "?",
		range = true,
		desc = "Parallel swarm: decompose into waves of parallel agent tasks",
	})

	cmd("DwightSwarmResume", function()
		require_mod("swarm").resume()
	end, { desc = "Resume from failed/paused swarm wave" })

	cmd("DwightSwarmCancel", function()
		require_mod("swarm").cancel()
	end, { desc = "Cancel active swarm session and cleanup worktrees" })

	cmd("DwightSwarmStatus", function()
		require_mod("swarm").status()
	end, { desc = "Show swarm session status" })

	cmd("DwightSwarmPause", function()
		require_mod("swarm").pause()
	end, { desc = "Pause swarm after the current wave completes" })

	cmd("DwightSquash", function()
		require_mod("integration").squash()
	end, { desc = "Squash dwight checkpoint commits into one with smart message" })

	-- GitHub integration
	cmd("DwightIssue", function(o)
		local args = vim.trim(o.args or "")
		local gh = require_mod("github")

		-- Parse cross-repo reference: owner/repo#42
		local ref = args:match("([%w%-%.]+/[%w%-%.]+#%d+)")
		if ref then
			local parsed = gh._parse_ref and gh._parse_ref(ref) or {}
			-- Fallback: parse inline
			local repo_part, num_part = ref:match("^([%w%-%.]+/[%w%-%.]+)#(%d+)$")
			if repo_part and num_part then
				local mode = "pick"
				if args:match("%-%-agent") then
					mode = "agent"
				elseif args:match("%-%-auto") then
					mode = "auto"
				elseif args:match("%-%-analyze") then
					mode = "analyze"
				end
				gh.solve_by_number(tonumber(num_part), mode, { repo = repo_part })
				return
			end
		end

		-- :DwightIssue 42 -> fetch and action-pick that issue
		local number = tonumber(args:match("^(%d+)"))
		if number then
			local mode = "pick"
			if args:match("%-%-agent") then
				mode = "agent"
			elseif args:match("%-%-auto") then
				mode = "auto"
			elseif args:match("%-%-analyze") then
				mode = "analyze"
			end
			local repo = args:match("%-%-repo%s+(%S+)")
			gh.solve_by_number(number, mode, { repo = repo })
			return
		end

		-- :DwightIssue --label bug --milestone v2.0 --repo owner/repo
		local label = args:match("%-%-label%s+(%S+)")
		local assignee = args:match("%-%-assignee%s+(%S+)")
		local milestone = args:match("%-%-milestone%s+(%S+)")
		local repo = args:match("%-%-repo%s+(%S+)")
		gh.pick({ label = label, assignee = assignee, milestone = milestone, repo = repo })
	end, {
		nargs = "?",
		desc = "GitHub issues: pick, solve, analyze (issue number, owner/repo#N, --label/--assignee/--milestone/--repo)",
	})

	cmd("DwightPR", function()
		require_mod("github").maybe_offer_pr()
	end, { desc = "Create PR for current branch (if solving a GitHub issue)" })

	cmd("DwightPRReview", function(o)
		local args = vim.trim(o.args or "")
		local gh = require_mod("github")
		local number = tonumber(args:match("^(%d+)"))
		local repo = args:match("%-%-repo%s+(%S+)")

		if number then
			gh.review_pr(number, { repo = repo })
		else
			gh.pick_pr({ repo = repo })
		end
	end, {
		nargs = "?",
		desc = "Review a PR with AI analysis (optional: PR number or --repo)",
	})

	cmd("DwightNewIssue", function(o)
		local args = vim.trim(o.args or "")
		local gh = require_mod("github")
		local opts = {}
		opts.repo = args:match("%-%-repo%s+(%S+)")
		opts.milestone = args:match("%-%-milestone%s+(%S+)")
		opts.labels = args:match("%-%-label%s+(%S+)")

		-- If there's a remaining non-flag argument, use as title
		local title = args:gsub("%-%-[%w]+%s+%S+", ""):match("^%s*(.+)%s*$")
		if title and title ~= "" then
			opts.title = title
		end

		gh.create_issue(opts)
	end, {
		nargs = "?",
		desc = "Create a new GitHub issue (uses repo templates if available)",
	})

	cmd("DwightCI", function(o)
		local args = vim.trim(o.args or "")
		local gh = require_mod("github")
		local opts = {}
		opts.repo = args:match("%-%-repo%s+(%S+)")

		if args:match("%-%-fix") then
			-- Extract run ID if provided
			local run_id = args:match("%-%-fix%s+(%d+)")
			if run_id then
				gh.ci_fix(tonumber(run_id), opts)
			else
				-- Find first failed run and fix it
				gh.ci_status(opts, function(checks, err)
					if err then
						vim.notify("[dwight] " .. err, vim.log.levels.ERROR)
						return
					end
					for _, item in ipairs(checks and checks.items or {}) do
						if item.status == "failure" and item.run_id then
							gh.ci_fix(item.run_id, opts)
							return
						end
					end
					vim.notify("[dwight] No failed CI runs found.", vim.log.levels.INFO)
				end)
			end
		elseif args:match("%-%-rerun") then
			gh.ci_status(opts, function(checks, err)
				if err then
					vim.notify("[dwight] " .. err, vim.log.levels.ERROR)
					return
				end
				for _, item in ipairs(checks and checks.items or {}) do
					if item.status == "failure" and item.run_id then
						gh.ci_rerun(item.run_id, opts, function(ok, msg)
							vim.notify("[dwight] " .. msg, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
						end)
					end
				end
			end)
		else
			gh.ci_show(opts)
		end
	end, {
		nargs = "?",
		complete = function()
			return { "--fix", "--rerun", "--repo" }
		end,
		desc = "CI/CD status, logs, and auto-fix (--fix, --rerun)",
	})

	cmd("DwightGit", function(o)
		require_mod("gitops").pick(o.args ~= "" and o.args or nil)
	end, {
		nargs = "?",
		complete = function()
			return { "status", "commit", "stash", "pop", "push", "pull", "cleanup", "conflicts", "resolve" }
		end,
		desc = "Git workflow: status, commit, stash, push, pull, cleanup, conflicts, resolve",
	})

	-- Provider commands
	cmd("DwightSwitch", function(o)
		require_mod("providers").switch(o.args)
	end, {
		nargs = 1,
		complete = function(arglead)
			return require_mod("providers").available_models_for_backend(arglead)
		end,
		desc = "Switch model (filtered by current backend)",
	})

	cmd("DwightAddProvider", function()
		require_mod("providers").add_provider_wizard()
	end, { desc = "Add a new API provider" })

	cmd("DwightProviders", function()
		require_mod("providers").show_current()
	end, { desc = "Show current provider/model" })

	cmd("DwightAuthMax", function()
		require_mod("providers").auth_max()
	end, { desc = "Authenticate with Anthropic Pro/Max subscription (OAuth)" })

	cmd("DwightAgentStatus", function()
		require_mod("agent_status").toggle()
	end, { desc = "Toggle agent status buffer" })

	cmd("DwightDiffReview", function()
		require_mod("agent").diff_review()
	end, { desc = "Open full diff of recent agent changes in a split" })

	cmd("DwightLessons", function(o)
		local agent = require_mod("agent")
		if o.args == "clear" then
			agent._save_lessons({})
			vim.notify("[dwight] All lessons cleared.", vim.log.levels.INFO)
		elseif o.args == "consolidate" then
			vim.notify("[dwight] Consolidating similar lessons...", vim.log.levels.INFO)
			agent._consolidate_lessons(function(stats)
				if stats.error then
					vim.notify("[dwight] Consolidation failed: " .. stats.error, vim.log.levels.ERROR)
				elseif stats.merged_groups == 0 then
					vim.notify("[dwight] No similar lessons to merge.", vim.log.levels.INFO)
				else
					vim.notify(
						string.format(
							"[dwight] Consolidated: %d -> %d lessons (%d groups merged, %d removed)",
							stats.before,
							stats.after,
							stats.merged_groups,
							stats.removed or 0
						),
						vim.log.levels.INFO
					)
				end
			end)
		elseif o.args == "stats" then
			local stats = agent._lesson_stats()
			if stats.total == 0 then
				vim.notify("[dwight] No lessons yet.", vim.log.levels.INFO)
			else
				vim.notify(
					string.format(
						"[dwight] Lesson stats:\n  Total: %d\n  Stale (>30d): %d\n  Never used: %d\n"
							.. "  Avg uses: %.1f\n  Avg reinforcement: %.1f",
						stats.total,
						stats.stale,
						stats.never_used,
						stats.avg_uses,
						stats.avg_reinforced
					),
					vim.log.levels.INFO
				)
			end
		else
			local lessons = agent._load_lessons()
			if #lessons == 0 then
				vim.notify("[dwight] No lessons stored yet. Run some agent sessions first.", vim.log.levels.INFO)
				return
			end
			local lines = { "# Dwight Lessons (" .. #lessons .. " total)", "" }
			for i, l in ipairs(lessons) do
				local meta_parts = {}
				if (l.reinforced or 1) > 1 then
					meta_parts[#meta_parts + 1] = "x" .. l.reinforced
				end
				if (l.use_count or 0) > 0 then
					meta_parts[#meta_parts + 1] = l.use_count .. " uses"
				end
				if l.timestamp then
					local age = os.time() - l.timestamp
					if age > 30 * 86400 then
						meta_parts[#meta_parts + 1] = "stale"
					end
				end
				local meta = #meta_parts > 0 and " (" .. table.concat(meta_parts, ", ") .. ")" or ""

				lines[#lines + 1] =
					string.format("%d. **%s** -- %s%s", i, table.concat(l.keywords or {}, " "), l.text or "?", meta)
				if l.request then
					lines[#lines + 1] = string.format("   _From: %s_", l.request:sub(1, 60))
				end
			end
			lines[#lines + 1] = ""
			lines[#lines + 1] = "---"
			lines[#lines + 1] =
				"_Commands: `:DwightLessons consolidate` | `:DwightLessons stats` | `:DwightLessons clear`_"

			local buf = vim.api.nvim_create_buf(false, true)
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, _flatten(lines))
			vim.bo[buf].filetype = "markdown"
			vim.bo[buf].buftype = "nofile"
			vim.bo[buf].bufhidden = "wipe"
			vim.api.nvim_set_current_buf(buf)
		end
	end, {
		nargs = "?",
		complete = function()
			return { "clear", "consolidate", "stats" }
		end,
		desc = "View, consolidate, stats, or clear session lessons",
	})

	cmd("DwightBackend", function(o)
		local cfg = dwight.config
		if o.args == "" then
			local model = require_mod("tracker").get_model()
			vim.notify(
				string.format("[dwight] Backend: %s | Model: %s", cfg.backend or "claude_code", model),
				vim.log.levels.INFO
			)
		else
			local valid = { claude_code = true, codex = true, gemini = true, opencode = true }
			if valid[o.args] then
				cfg.backend = o.args
				-- Sync tracker with backend-appropriate model
				local model_map = {
					claude_code = cfg.claude_code_model or "sonnet",
					codex = cfg.codex_model or "codex",
					gemini = cfg.gemini_model or "gemini",
					opencode = "opencode",
				}
				pcall(function()
					require_mod("tracker").set_model(model_map[o.args] or o.args)
				end)
				vim.notify(string.format("[dwight] Switched backend to: %s", o.args), vim.log.levels.INFO)
			else
				vim.notify("[dwight] Valid backends: claude_code, codex, gemini, opencode", vim.log.levels.WARN)
			end
		end
	end, {
		nargs = "?",
		complete = function()
			return { "claude_code", "codex", "gemini", "opencode" }
		end,
		desc = "Get/set backend (claude_code, codex, gemini, opencode)",
	})

	-- Feature commands (code-driven: reads @feature: pragmas from source)
	cmd("DwightFeatures", function()
		require_mod("features").pick()
	end, { desc = "Browse live features (from @feature: pragmas)" })

	cmd("DwightFeaturePreview", function(o)
		local name = o.args and o.args ~= "" and o.args or nil
		if name then
			require_mod("features").show_virtual(name)
		else
			require_mod("features").pick()
		end
	end, {
		nargs = "?",
		complete = function()
			return require_mod("features").names()
		end,
		desc = "Preview feature context (what the AI sees)",
	})

	-- Feature splitting: break large features into smaller sub-features
	cmd("DwightSplitFeature", function(o)
		local args = vim.trim(o.args or "")
		if args:match("%-%-agentic") then
			local name = args:gsub("%-%-agentic%s*", ""):match("^%s*(.-)%s*$")
			require_mod("split").split_agentic(name ~= "" and name or nil)
		else
			local name = args ~= "" and args or nil
			require_mod("split").split(name)
		end
	end, {
		nargs = "?",
		complete = function()
			return require_mod("features").names()
		end,
		desc = "Split a large feature into sub-features (--agentic reads code for boundaries)",
	})

	cmd("DwightSplitPreview", function(o)
		local name = o.args and o.args ~= "" and o.args or nil
		require_mod("split").preview(name)
	end, {
		nargs = "?",
		complete = function()
			return require_mod("features").names()
		end,
		desc = "Preview a feature split without applying",
	})

	cmd("DwightSplitAudit", function()
		require_mod("split").audit_interactive()
	end, { desc = "Check which features might need splitting" })

	-- Multi-repo workspace commands
	cmd("DwightWorkspace", function()
		require_mod("workspace").status()
	end, { desc = "Show multi-repo workspace status" })

	cmd("DwightWorkspaceAdd", function(o)
		require_mod("workspace").add_interactive(o.args ~= "" and o.args or nil)
	end, {
		nargs = "?",
		complete = "dir",
		desc = "Add a repo to the workspace",
	})

	cmd("DwightWorkspaceRemove", function(o)
		require_mod("workspace").remove_interactive(o.args ~= "" and o.args or nil)
	end, {
		nargs = "?",
		complete = function()
			local ok, ws = pcall(require_mod, "workspace")
			if not ok then
				return {}
			end
			return vim.tbl_map(function(r)
				return r.name
			end, ws.repos())
		end,
		desc = "Remove a repo from the workspace",
	})

	cmd("DwightWorkspaceIssues", function(o)
		local args = vim.trim(o.args or "")
		local opts = {}
		opts.label = args:match("%-%-label%s+(%S+)")
		opts.assignee = args:match("%-%-assignee%s+(%S+)")
		opts.milestone = args:match("%-%-milestone%s+(%S+)")
		require_mod("workspace").show_issues(opts)
	end, {
		nargs = "?",
		desc = "Unified issue view across all workspace repos (--label/--assignee/--milestone)",
	})

	cmd("DwightWorkspaceFeatures", function()
		require_mod("workspace").show_features()
	end, { desc = "Cross-repo feature map" })

	cmd("DwightWorkspaceInit", function()
		require_mod("workspace").init_monorepo()
	end, { desc = "Initialize workspace from monorepo (scan sub-directories)" })

	cmd("DwightProjectContext", function()
		require_mod("features").show_project_context()
	end, { desc = "Preview JIT project context (what the AI sees)" })

	-- Documentation commands
	cmd("DwightDevDocs", function(o)
		local args = vim.trim(o.args or "")
		if args:match("%-%-agentic") then
			local doc_name = args:gsub("%-%-agentic%s*", ""):match("^%s*(.-)%s*$")
			require_mod("devdocs").generate_agentic(doc_name ~= "" and doc_name or nil)
		else
			require_mod("devdocs").generate(args ~= "" and args or nil)
		end
	end, {
		nargs = "?",
		complete = function()
			return { "architecture", "api-reference", "getting-started", "--agentic" }
		end,
		desc = "Generate developer docs (--agentic reads source code for accuracy)",
	})

	cmd("DwightDevDocsBrowse", function()
		require_mod("devdocs").browse()
	end, { desc = "Browse developer docs" })

	cmd("DwightDocs", function(o)
		local args = vim.trim(o.args or "")
		if args:match("%-%-update") then
			local target = args:gsub("%-%-update%s*", ""):match("%S+")
			require_mod("pubdocs").update_docs({ target = target })
		elseif args:match("%-%-seo") then
			local target = args:gsub("%-%-seo%s*", ""):match("%S+")
			require_mod("pubdocs").seo_optimize({ target = target })
		elseif args:match("%-%-agentic") then
			require_mod("pubdocs").generate_agentic()
		else
			require_mod("pubdocs").generate({ target = args ~= "" and args or nil })
		end
	end, {
		nargs = "*",
		complete = function(_, cmdline)
			local ok, pubdocs = pcall(require_mod, "pubdocs")
			if not ok then
				return { "all", "--agentic", "--update", "--seo" }
			end

			-- If --seo or --update already typed, complete with page names
			if cmdline:match("%-%-seo%s") or cmdline:match("%-%-update%s") then
				local adapter = pubdocs.get_adapter()
				local existing = pubdocs.scan_existing_docs(adapter)
				local items = {}
				for _, p in ipairs(existing) do
					items[#items + 1] = p.path:gsub("%.md$", "")
				end
				return items
			end

			local plan = pubdocs.build_plan()
			local items = { "all", "--agentic", "--update", "--seo" }
			for _, page in ipairs(plan) do
				items[#items + 1] = page.path:gsub("%.md$", "")
				if page.feature_name then
					items[#items + 1] = page.feature_name
				end
			end
			return items
		end,
		desc = "Generate/update docs (--agentic | --update | --seo [page])",
	})

	cmd("DwightDocsBrowse", function()
		require_mod("pubdocs").browse()
	end, { desc = "Browse public docs" })

	-- Library reference commands
	cmd("DwightAddLib", function()
		require_mod("libs").add_lib()
	end, { desc = "Add a library API reference" })

	cmd("DwightLibs", function()
		require_mod("libs").pick()
	end, { desc = "Browse library references" })

	-- TDD commands
	cmd("DwightTDD", function(o)
		require_mod("tdd").start(o.args ~= "" and o.args or nil)
	end, { nargs = "?", desc = "Start TDD session: describe a feature, agent writes tests + code" })

	cmd("DwightTDDStop", function()
		require_mod("tdd").stop()
	end, { desc = "Stop TDD session" })

	-- Template commands
	cmd("DwightTemplate", function()
		require_mod("templates").pick(function(prompt)
			-- Pre-fill prompt would need UI integration -- just notify for now
			vim.fn.setreg("+", prompt)
			vim.notify("[dwight] Template copied to clipboard. Paste in prompt.", vim.log.levels.INFO)
		end)
	end, { desc = "Pick a prompt template" })

	cmd("DwightSaveTemplate", function(o)
		require_mod("templates").save(o.args ~= "" and o.args or nil)
	end, { nargs = "?", desc = "Save a prompt template" })

	-- MCP commands
	cmd("DwightMCP", function()
		require_mod("mcp").status()
	end, { desc = "Show MCP server status" })

	-- Git context toggle
	cmd("DwightGitToggle", function()
		dwight.config.git_context = not dwight.config.git_context
		vim.notify("[dwight] Git context: " .. (dwight.config.git_context and "ON" or "OFF"), vim.log.levels.INFO)
	end, { desc = "Toggle git diff/blame in prompts" })

	-- Whiteboard (replaces chat)
	cmd("DwightWhiteboard", function()
		require_mod("whiteboard").open()
	end, { desc = "Open whiteboard scratch buffer" })

	cmd("DwightWhiteboardSave", function(o)
		require_mod("whiteboard").save({
			name = o.args ~= "" and o.args or nil,
			range = o.range,
		})
	end, {
		nargs = "?",
		range = true,
		desc = "Save to ~/.dwight/brainstorm/ (visual=selection, normal=whole buffer)",
	})

	cmd("DwightBrainstorms", function()
		require_mod("whiteboard").browse()
	end, { desc = "Browse saved brainstorms" })

	-- Codebase digest
	cmd("DwightDigest", function(o)
		local args = o.args or ""
		local digest = require_mod("digest")
		if args:match("%-%-status") then
			digest.status()
		elseif args:match("%-%-clear") then
			digest.clear()
		elseif args:match("%-%-force") then
			digest.build({ force = true })
		else
			digest.build()
		end
	end, {
		nargs = "?",
		complete = function()
			return { "--status", "--clear", "--force" }
		end,
		desc = "Build codebase digest (--status, --clear, --force)",
	})

	-- Commits with motive
	cmd("DwightCommit", function()
		require_mod("commit").generate()
	end, { desc = "Generate commit message from staged changes + AI context" })

	-- Lint diagnostics
	cmd("DwightLintClear", function()
		require_mod("lint").clear_diagnostics(vim.api.nvim_get_current_buf())
		vim.notify("[dwight] Lint diagnostics cleared.", vim.log.levels.INFO)
	end, { desc = "Clear dwight lint diagnostics" })

	-- Test run history
	cmd("DwightTestRuns", function()
		require_mod("tdd").browse_runs()
	end, { desc = "Browse test run history" })

	-- Treesitter minimap
	cmd("DwightMinimap", function(o)
		local path = o.args and o.args ~= "" and o.args or vim.api.nvim_buf_get_name(0)
		local ts = require_mod("treesitter")
		local content
		if vim.fn.isdirectory(path) == 1 then
			content = ts.minimap_dir(path)
		else
			content = ts.minimap(path)
		end
		if content then
			local buf = vim.api.nvim_create_buf(false, true)
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(content, "\n"))
			vim.bo[buf].filetype = "lua"
			vim.bo[buf].buftype = "nofile"
			vim.bo[buf].bufhidden = "wipe"
			vim.cmd("split")
			vim.api.nvim_win_set_buf(0, buf)
		else
			vim.notify("[dwight] No structure found.", vim.log.levels.INFO)
		end
	end, { nargs = "?", complete = "file", desc = "Show treesitter minimap of file/dir" })

	cmd("DwightStatus", function()
		dwight.status()
	end, { desc = "Full status" })

	cmd("DwightHealth", function()
		require_mod("health").show()
	end, { desc = "Run health check: verify all prerequisites and report status" })

	cmd("DwightRefactor", function(o)
		local args = vim.trim(o.args or "")
		-- Parse: "feature_name prompt..." or just show picker
		local feature_name, prompt
		if args ~= "" then
			feature_name = args:match("^(%S+)")
			prompt = args:match("^%S+%s+(.+)$")
		end
		require_mod("refactor").refactor(feature_name, prompt)
	end, {
		nargs = "*",
		complete = function()
			local ok, features = pcall(require, "dwight.features")
			if ok then
				return features.names()
			end
			return {}
		end,
		desc = "Refactor a feature based on a prompt (agentic workflow)",
	})
end

return M
