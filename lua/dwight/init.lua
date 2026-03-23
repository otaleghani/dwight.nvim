-- dwight.nvim
-- A developer-centered AI coding assistant for Neovim.

local M = {}

M._version = "2.0.1"

local function require_mod(name)
	return require("dwight." .. name)
end

M.defaults = {
	-- Backend: which CLI agent runs agentic tasks.
	-- "claude_code" = Anthropic Claude Code (default)
	-- "codex"       = OpenAI Codex CLI
	-- "gemini"      = Google Gemini CLI
	-- "opencode"    = OpenCode CLI
	backend = "claude_code",

	-- Provider settings (for skills.lua single-shot API calls)
	provider = nil, -- nil = auto (anthropic if key set)
	model = nil, -- nil = provider default. Or: "sonnet", "openai:gpt-4o"
	api_key = nil, -- override for active provider
	max_tokens = 4096,

	-- Model diversity: use different models for test writing vs implementation.
	test_model = nil, -- e.g., "sonnet" or "openai:gpt-4o"
	implement_model = nil, -- e.g., "opus" — used for /code, /fix modes

	-- Claude Code CLI settings (backend = "claude_code")
	-- Uses your authenticated Claude Code session. No API key needed.
	claude_code_bin = "claude",
	claude_code_model = nil, -- nil = claude's default. Or: "sonnet", "opus", "haiku"

	-- Codex CLI settings (backend = "codex")
	codex_bin = "codex",
	codex_model = nil, -- nil = codex default

	-- Gemini CLI settings (backend = "gemini")
	gemini_bin = "gemini",
	gemini_model = nil, -- nil = gemini default

	-- OpenCode CLI settings (backend = "opencode")
	opencode_bin = "opencode",
	opencode_flags = {},

	-- Shared settings
	default_skills = {},
	lsp_context_lines = 80,
	include_diagnostics = true,
	include_type_info = true,
	include_references = true,
	max_references = 10,
	indicator_style = "both",
	indicator_sign = "⟳",
	indicator_hl = "DwightProcessing",
	border = "rounded",
	comment_styles = nil,
	timeout = 120000, -- ms. Agent auto-scales 2x for files >200 lines.

	-- Git-aware context: auto-include diffs and blame
	git_context = true,

	-- Agent settings
	parallel_steps = true, -- enable parallel step execution for independent steps

	-- Agentic loop tuning (for DwightAgent / DwightAuto execution)
	agentic_opts = {
		max_output_tokens = 64000, -- per-response output token budget (Claude Code)
		cli_timeout = 600, -- seconds before killing a CLI agent session (10 min)
		reflection = false, -- agent self-reflection/retry gate
	},

	-- Swarm: parallel multi-agent execution (DwightSwarm)
	swarm_opts = {
		max_parallel = 3, -- max agents per wave (caps worktree count)
		on_partial_failure = "continue", -- "continue" = merge successes, mark failures for retry
		cleanup_worktrees = true, -- remove worktrees after each wave merge
	},

	-- Cost limits: budget caps to prevent runaway spending.
	-- Costs are estimates (~20% variance). Set to nil to disable.
	cost_limits = {
		per_session = nil, -- max dollars per DwightAuto/DwightSwarm session. e.g., 5.00
		per_day = nil, -- max dollars per calendar day (spans Neovim restarts). e.g., 20.00
		warn_threshold = 0.8, -- warn at this fraction of limit (0.0-1.0)
	},

	-- MCP servers (list of { name, command, args, env, cwd })
	mcp_servers = {},

	-- Language registry overrides.
	-- Add or override language definitions for detection, test/build/lint commands,
	-- syntax checks, and agent hints. See :h dwight-languages for schema.
	-- Example:
	--   languages = {
	--     java = { detect = {"pom.xml"}, test_cmd = "mvn test -q", build_cmd = "mvn compile -q" },
	--   }
	languages = {},

	-- Custom modes: register project-specific modes at setup time.
	-- Each key is the mode name, value is a mode table (must have `task`).
	-- Example:
	--   modes = {
	--     deploy = { task = "Generate deployment script for ...", context = "code" },
	--   }
	modes = {},
}

M.config = {}
M._active_jobs = {}
M._last_inline = nil

--------------------------------------------------------------------
-- Setup
--------------------------------------------------------------------

function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", {}, M.defaults, opts or {})

	-- Validate config early (migrates deprecated keys, flags typos/invalid values)
	require_mod("config").check_all(M.config, opts)

	local hl = vim.api.nvim_set_hl
	hl(0, "DwightProcessing", { fg = "#e0af68", bold = true, italic = true, default = true })
	hl(0, "DwightSkill", { fg = "#7dcfff", bold = true, underline = true, default = true })
	hl(0, "DwightSkillInvalid", { fg = "#f7768e", bold = true, strikethrough = true, default = true })
	hl(0, "DwightMode", { fg = "#e0af68", bold = true, default = true })
	hl(0, "DwightSymbol", { fg = "#bb9af7", bold = true, underline = true, default = true })
	hl(0, "DwightModel", { fg = "#73daca", bold = true, italic = true, default = true })
	hl(0, "DwightFeature", { fg = "#ff9e64", bold = true, underline = true, default = true })
	hl(0, "DwightThink", { fg = "#f7768e", bold = true, default = true })
	hl(0, "DwightLib", { fg = "#9ece6a", bold = true, underline = true, default = true })
	hl(0, "DwightMcp", { fg = "#73daca", bold = true, italic = true, underline = true, default = true })
	hl(0, "DwightFile", { fg = "#c0caf5", bold = true, underline = true, default = true })
	hl(0, "DwightAudit", { fg = "#f7768e", bold = true, italic = true, default = true })
	hl(0, "DwightHeal", { fg = "#9ece6a", bold = true, italic = true, default = true })
	hl(0, "DwightAuto", { fg = "#e0af68", bold = true, italic = true, default = true })
	hl(0, "DwightGithub", { fg = "#7aa2f7", bold = true, italic = true, default = true })
	hl(0, "DwightReplace", { fg = "#9ece6a", italic = true, default = true })
	hl(0, "DwightBorder", { fg = "#7aa2f7", default = true })
	hl(0, "DwightTitle", { fg = "#bb9af7", bold = true, default = true })
	hl(0, "DwightHelpHint", { fg = "#89b4fa", italic = true, default = true })

	vim.fn.sign_define("DwightProcessing", {
		text = M.config.indicator_sign,
		texthl = "DwightProcessing",
	})

	-- Load provider config
	require_mod("providers").load()

	-- Reset language registry so user config merges take effect
	local errors = require_mod("errors")
	errors.try("languages.reset", function()
		require_mod("languages").reset()
	end)

	-- Register custom modes from config
	if M.config.modes then
		local modes_mod = require_mod("modes")
		for name, mode in pairs(M.config.modes) do
			modes_mod.register(name, mode)
		end
	end

	-- Sync tracker model with backend config
	errors.try("tracker.set_model", function()
		local model_map = {
			claude_code = M.config.claude_code_model or M.config.model or "sonnet",
			codex = M.config.codex_model or "codex",
			gemini = M.config.gemini_model or "gemini",
		}
		local model = model_map[M.config.backend]
		if model then
			require_mod("tracker").set_model(model)
		end
	end)

	M._register_commands()

	-- Initialize persistent session log (.dwight/session.log)
	errors.try("session_log.init", function()
		require_mod("session_log").init()
	end)

	-- Start MCP servers
	if #M.config.mcp_servers > 0 then
		require_mod("mcp").setup(M.config)
	end

	-- Start kit MCP servers
	errors.try("kit_mcp_servers", function()
		if require_mod("project").is_initialized() then
			local kit_servers = require("dwight.marketplace.kits").active_mcp_servers()
			if #kit_servers > 0 then
				local mcp = require_mod("mcp")
				for _, srv in ipairs(kit_servers) do
					mcp.start_server(srv.name, srv)
				end
			end
		end
	end)

	-- Cleanup MCP on exit
	if #M.config.mcp_servers > 0 then
		vim.api.nvim_create_autocmd("VimLeavePre", {
			callback = function()
				errors.try("mcp.stop_all", function()
					require_mod("mcp").stop_all()
				end)
			end,
		})
	end

	-- Cleanup progress watcher on exit
	vim.api.nvim_create_autocmd("VimLeavePre", {
		callback = function()
			errors.try("progress.stop", function()
				require_mod("progress").stop()
			end)
		end,
	})

	-- Cleanup all agent processes, inline jobs, and swarm worktrees on exit
	vim.api.nvim_create_autocmd("VimLeavePre", {
		callback = function()
			errors.try("agentic.abort_all", function()
				require_mod("agentic").abort_all()
			end)
			errors.try("inline_jobs.cleanup", function()
				for id, job in pairs(M._active_jobs) do
					M._kill_job(id, job)
				end
			end)
			errors.try("worktree.cleanup_all", function()
				require_mod("swarm.worktree").cleanup_all()
			end)
		end,
	})
end

function M._register_commands()
	require_mod("commands").register()
end

--------------------------------------------------------------------
-- Core API
--------------------------------------------------------------------

--- Smart invoke: works in both visual and normal mode.
--- In visual mode: uses the selection. In normal mode: uses treesitter
--- to find the enclosing function/class/block at cursor.
--- Get selection using visual marks (range) or treesitter smart_select.
--- Guaranteed to return a selection — falls back to paragraph at cursor.
--- @param opts table|nil  { range = number }  (from command handler)
function M._get_selection(opts)
	opts = opts or {}
	local ui = require_mod("ui")

	-- 1. Visual mode: check if we were called with a range (from :'<,'>DwightInvoke
	--    or a visual-mode keymap). vim.fn.mode() is always "n" here because
	--    entering command mode exits visual, so we use the range flag instead.
	local vim_mode = vim.fn.mode()
	local is_visual = vim_mode == "v" or vim_mode == "V" or vim_mode == "\22"

	if is_visual or (opts.range and opts.range > 0) then
		local selection = ui.get_visual_selection()
		if selection then
			return selection
		end
		-- Visual marks invalid — fall through to smart select
	end

	-- 2. Treesitter smart select (includes paragraph fallback)
	local ts_ok, ts = pcall(require, "dwight.treesitter")
	if ts_ok then
		local selection = ts.smart_select()
		if selection then
			return selection
		end
	end

	-- 3. Final fallback: select current line range as paragraph
	local bufnr = vim.api.nvim_get_current_buf()
	local cursor = vim.api.nvim_win_get_cursor(0)
	local total = vim.api.nvim_buf_line_count(bufnr)
	local start_line = cursor[1]
	local end_line = cursor[1]

	while start_line > 1 do
		local line = vim.api.nvim_buf_get_lines(bufnr, start_line - 2, start_line - 1, false)[1]
		if vim.trim(line) == "" then
			break
		end
		start_line = start_line - 1
	end
	while end_line < total do
		local line = vim.api.nvim_buf_get_lines(bufnr, end_line, end_line + 1, false)[1]
		if vim.trim(line) == "" then
			break
		end
		end_line = end_line + 1
	end

	local lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
	return {
		bufnr = bufnr,
		start_line = start_line,
		end_line = end_line,
		text = table.concat(lines, "\n"),
		lines = lines,
		filetype = vim.bo[bufnr].filetype,
		filepath = vim.api.nvim_buf_get_name(bufnr),
	}
end

function M.invoke(opts)
	local selection = M._get_selection(opts)

	if not selection or vim.trim(selection.text or "") == "" then
		vim.notify(
			"[dwight] No code at cursor. Place cursor inside a function or select code first.",
			vim.log.levels.WARN
		)
		return
	end

	require_mod("ui").open_prompt(selection, nil)
end

function M.invoke_mode(mode_name, opts)
	local modes = require_mod("modes")
	local mode = modes.get(mode_name)
	if not mode then
		vim.notify("[dwight] Unknown mode: " .. tostring(mode_name), vim.log.levels.ERROR)
		return
	end

	local selection = M._get_selection(opts)

	if not selection or vim.trim(selection.text or "") == "" then
		vim.notify("[dwight] No code selected.", vim.log.levels.WARN)
		return
	end

	local ctx = require_mod("lsp").gather_context(selection)
	local prompt_text = require_mod("prompt").build(mode, selection, ctx)
	require_mod("inline").run(prompt_text, selection, M.config, mode_name)
end

--------------------------------------------------------------------
-- Follow-up: refine the last inline edit
--------------------------------------------------------------------

function M.follow_up()
	local prev = M._last_inline
	if not prev then
		vim.notify("[dwight] No previous inline edit to follow up on.", vim.log.levels.WARN)
		return
	end

	local bufnr = prev.bufnr
	if not vim.api.nvim_buf_is_valid(bufnr) then
		vim.notify("[dwight] Buffer from last edit is no longer valid.", vim.log.levels.WARN)
		return
	end

	local line_count = vim.api.nvim_buf_line_count(bufnr)
	local start_line = math.min(prev.new_start, line_count)
	local end_line = math.min(prev.new_end, line_count)

	local lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
	local current_code = table.concat(lines, "\n")

	local selection = {
		bufnr = bufnr,
		start_line = start_line,
		end_line = end_line,
		text = current_code,
		lines = lines,
		filetype = prev.selection.filetype,
		filepath = prev.selection.filepath,
	}

	require_mod("ui").open_prompt(selection, { follow_up = prev, current_code = current_code })
end

--------------------------------------------------------------------
-- Dot-repeat: replay last dwight operation on new selection
--------------------------------------------------------------------

M._last_operation = nil -- { prompt_text, mode_name, model_override, think_depth, opts }

--- Store the last operation for dot-repeat.
function M.store_last_op(prompt_text, mode_name, model_override, think_depth, opts)
	M._last_operation = {
		prompt_text = prompt_text,
		mode_name = mode_name,
		model_override = model_override,
		think_depth = think_depth,
		opts = opts,
	}
end

--- Replay the last operation on current selection/smart-select.
function M.dot_repeat(opts)
	if not M._last_operation then
		vim.notify("[dwight] No previous operation to repeat.", vim.log.levels.WARN)
		return
	end

	local selection = M._get_selection(opts)

	if not selection or vim.trim(selection.text or "") == "" then
		vim.notify("[dwight] No code selected for repeat.", vim.log.levels.WARN)
		return
	end

	local op = M._last_operation

	-- Rebuild prompt with new selection
	local mode_def = require_mod("modes").get(op.mode_name)
	if mode_def then
		local ctx = require_mod("lsp").gather_context(selection)
		local prompt_text = require_mod("prompt").build(mode_def, selection, ctx)
		require_mod("inline").run(
			prompt_text,
			selection,
			M.config,
			op.mode_name,
			op.model_override,
			op.think_depth,
			op.opts
		)
	else
		-- Freeform: replay original prompt
		require_mod("inline").run(
			op.prompt_text,
			selection,
			M.config,
			op.mode_name,
			op.model_override,
			op.think_depth,
			op.opts
		)
	end

	vim.notify(string.format("[dwight] 🔄 Repeating /%s", op.mode_name or "custom"), vim.log.levels.INFO)
end

--------------------------------------------------------------------
-- Cancel
--------------------------------------------------------------------

function M.cancel()
	local bufnr = vim.api.nvim_get_current_buf()
	local cursor_line = vim.api.nvim_win_get_cursor(0)[1]

	local buffer_jobs = {}
	for id, job in pairs(M._active_jobs) do
		if job.bufnr == bufnr then
			buffer_jobs[#buffer_jobs + 1] = { id = id, job = job }
		end
	end

	if #buffer_jobs == 0 then
		vim.notify("[dwight] No active jobs here.", vim.log.levels.INFO)
		return
	end

	local nearest = buffer_jobs[1]
	local nearest_dist = math.huge
	for _, bj in ipairs(buffer_jobs) do
		local dist = math.min(math.abs(cursor_line - bj.job.start_line), math.abs(cursor_line - bj.job.end_line))
		if cursor_line >= bj.job.start_line and cursor_line <= bj.job.end_line then
			dist = 0
		end
		if dist < nearest_dist then
			nearest_dist = dist
			nearest = bj
		end
	end

	M._kill_job(nearest.id, nearest.job)
	vim.notify("[dwight] Job #" .. nearest.id .. " cancelled.", vim.log.levels.INFO)
end

function M.cancel_all()
	if vim.tbl_isempty(M._active_jobs) then
		vim.notify("[dwight] No active jobs.", vim.log.levels.INFO)
		return
	end
	local count = 0
	for id, job in pairs(M._active_jobs) do
		M._kill_job(id, job)
		count = count + 1
	end
	vim.notify(string.format("[dwight] Cancelled %d job(s).", count), vim.log.levels.INFO)
end

function M._kill_job(id, job)
	if job.handle and not job.handle:is_closing() then
		job.handle:kill("sigterm")
	end
	require_mod("ui").clear_indicators(id)
	pcall(function()
		require_mod("log").finish(id, "cancelled", "", nil, "Cancelled")
	end)
	M._active_jobs[id] = nil
end

--------------------------------------------------------------------
-- Status
--------------------------------------------------------------------

function M.status()
	local tracker = require_mod("tracker")
	local project = require_mod("project")
	local runner = require_mod("runner")

	local backend = M.config.backend or "api"
	local model_line

	if backend == "claude_code" then
		local model = M.config.claude_code_model or M.config.model or "sonnet"
		model_line = string.format("Backend: claude_code | Model: %s ✅ (cli auth)", model)
	elseif backend == "codex" then
		local model = M.config.codex_model or "codex"
		model_line = string.format("Backend: codex | Model: %s (cli)", model)
	elseif backend == "gemini" then
		local model = M.config.gemini_model or "gemini"
		model_line = string.format("Backend: gemini | Model: %s (cli)", model)
	elseif backend == "opencode" then
		model_line = string.format("Backend: opencode | Model: %s", tracker.get_model())
	else
		local providers = require_mod("providers")
		local resolved = providers.resolve_model(nil)
		local key_status = providers.get_api_key(resolved.provider) and "✅" or "❌"
		model_line = string.format(
			"Backend: api | Provider: %s | Model: %s %s",
			resolved.provider_name,
			resolved.model_id,
			key_status
		)
	end

	local feature_count = 0
	pcall(function()
		feature_count = #require_mod("features").list()
	end)

	local lines = {
		model_line,
		"Project: " .. (project.is_initialized() and "✅ " .. project.dir() or "❌ :DwightInit"),
		"Skills: " .. #require_mod("skills").list() .. " | Features: " .. feature_count,
		"Session: " .. tracker._session.invocations .. " invocations",
		"Logged: " .. #require_mod("log")._entries .. " jobs",
	}

	if runner._last_run then
		local r = runner._last_run
		local icon = r.exit_code == 0 and "✅" or "❌"
		lines[#lines + 1] = string.format("Last run: %s '%s' (exit %d)", icon, r.cmd, r.exit_code)
	end

	local job_count = 0
	for id, job in pairs(M._active_jobs) do
		job_count = job_count + 1
		local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(job.bufnr), ":t")
		lines[#lines + 1] = string.format("  #%d: %s %d-%d (%s)", id, name, job.start_line, job.end_line, job.mode)
	end
	lines[#lines + 1] = job_count > 0 and (job_count .. " jobs running") or "No active jobs"

	vim.notify("[dwight]\n" .. table.concat(lines, "\n"), vim.log.levels.INFO)
end

return M
