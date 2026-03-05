-- dwight/health.lua
-- Health check: verifies prerequisites and reports status.
-- :DwightHealth runs all checks and prints a diagnostic report.

local M = {}

local _flatten = require("dwight.util").flatten_lines

--------------------------------------------------------------------
-- Individual checks
--------------------------------------------------------------------

--- Check if a binary is in PATH and optionally verify it runs.
--- Returns { ok, name, detail }
local function check_binary(name, bin, verify_args)
	local path = vim.fn.exepath(bin)
	if path == "" then
		return { ok = false, name = name, detail = bin .. " not found in PATH" }
	end

	if verify_args then
		local cmd = bin .. " " .. verify_args .. " 2>&1"
		local output = vim.fn.system(cmd)
		local code = vim.v.shell_error
		if code ~= 0 then
			return { ok = false, name = name, detail = path .. " found but failed: " .. (output or ""):sub(1, 100) }
		end
		return { ok = true, name = name, detail = path .. " ✓" }
	end

	return { ok = true, name = name, detail = path }
end

--- Check git repo status.
local function check_git()
	local output = vim.fn.system("git rev-parse --is-inside-work-tree 2>&1")
	local code = vim.v.shell_error
	if code ~= 0 then
		return {
			ok = false,
			name = "Git repository",
			detail = "Not inside a git repo. DwightAuto checkpoints require git.",
		}
	end

	-- Check for dirty working tree
	local status_out = vim.fn.system("git status --porcelain 2>/dev/null")
	local dirty = status_out and vim.trim(status_out) ~= ""
	local detail = "Clean repo"
	if dirty then
		local count = 0
		for _ in status_out:gmatch("\n") do
			count = count + 1
		end
		count = count + 1 -- last line may not end with \n
		detail = count .. " uncommitted change(s) — consider committing before :DwightAuto"
	end
	return { ok = true, name = "Git repository", detail = detail, warn = dirty }
end

--- Check Dwight project initialization.
local function check_project()
	local ok, project = pcall(require, "dwight.project")
	if not ok then
		return { ok = false, name = "Dwight project", detail = "Failed to load dwight.project module" }
	end
	if not project.is_initialized() then
		return { ok = false, name = "Dwight project", detail = "Not initialized. Run :DwightInit" }
	end
	return { ok = true, name = "Dwight project", detail = project.dir() }
end

--- Check API key for skills.lua (single-shot generation).
local function check_api_key()
	local cfg = require("dwight").config
	local provider = cfg.provider

	-- Check for explicit key first
	if cfg.api_key and cfg.api_key ~= "" then
		return { ok = true, name = "API key", detail = "Configured in dwight setup()" }
	end

	-- Check environment variables
	local env_keys = {
		{ env = "ANTHROPIC_API_KEY", provider = "anthropic" },
		{ env = "OPENAI_API_KEY", provider = "openai" },
		{ env = "GOOGLE_API_KEY", provider = "google" },
	}

	local found = {}
	for _, ek in ipairs(env_keys) do
		if os.getenv(ek.env) then
			found[#found + 1] = ek.env
		end
	end

	if #found > 0 then
		return { ok = true, name = "API key (for skills)", detail = table.concat(found, ", ") .. " set" }
	end

	return {
		ok = false,
		name = "API key (for skills)",
		detail = "No API key found. Skills (/code, /test, /explain) need an API key. "
			.. "Set ANTHROPIC_API_KEY or configure api_key in setup().",
		warn = true, -- warn not fatal: CLI backends work without it
	}
end

--- Check configured backend binary.
local function check_backend()
	local cfg = require("dwight").config
	local backend = cfg.backend or "claude_code"

	local bin_map = {
		claude_code = cfg.claude_code_bin or "claude",
		codex = cfg.codex_bin or "codex",
		gemini = cfg.gemini_bin or "gemini",
		opencode = cfg.opencode_bin or "opencode",
	}

	local bin = bin_map[backend]
	if not bin then
		return { ok = false, name = "Backend: " .. backend, detail = "Unknown backend" }
	end

	local result = check_binary("Backend: " .. backend, bin)
	if not result.ok then
		-- Add install hints
		local hints = {
			claude_code = "Install: npm i -g @anthropic-ai/claude-code",
			codex = "Install: npm i -g @openai/codex",
			gemini = "Install: npm i -g @google/gemini-cli",
			opencode = "Install: go install github.com/opencode-ai/opencode@latest",
		}
		result.detail = result.detail .. ". " .. (hints[backend] or "")
	end
	return result
end

--- Check Claude Code authentication (only if backend is claude_code).
local function check_claude_auth()
	local cfg = require("dwight").config
	if (cfg.backend or "claude_code") ~= "claude_code" then
		return nil -- skip for other backends
	end

	local bin = cfg.claude_code_bin or "claude"
	if vim.fn.exepath(bin) == "" then
		return nil -- already reported by check_backend
	end

	-- Try a quick auth check
	local output = vim.fn.system(bin .. " --version 2>&1")
	local code = vim.v.shell_error
	if code ~= 0 then
		return { ok = false, name = "Claude Code auth", detail = "Failed to run. Try: claude login" }
	end

	-- Check for API key as alternative auth
	if os.getenv("ANTHROPIC_API_KEY") then
		return { ok = true, name = "Claude Code auth", detail = "ANTHROPIC_API_KEY set" }
	end

	return { ok = true, name = "Claude Code auth", detail = "Version: " .. vim.trim(output):sub(1, 50) }
end

--- Check test command availability.
local function check_tests()
	local ok, agentic = pcall(require, "dwight.agentic")
	if not ok then
		return { ok = false, name = "Test command", detail = "Failed to load agentic module" }
	end

	local lang = agentic.detect_language()
	local test_cmd = agentic.get_test_command(lang)
	if not test_cmd then
		return {
			ok = true,
			name = "Test command",
			detail = "Language: " .. lang .. " — no test command configured",
			warn = true,
		}
	end

	-- Check if the test binary exists
	local test_bin = test_cmd:match("^(%S+)")
	if test_bin and vim.fn.exepath(test_bin) == "" then
		return {
			ok = false,
			name = "Test command",
			detail = test_cmd .. " — " .. test_bin .. " not in PATH",
		}
	end

	return { ok = true, name = "Test command", detail = lang .. " → " .. test_cmd }
end

--- Check lessons status.
local function check_lessons()
	local ok, agent = pcall(require, "dwight.agent")
	if not ok then
		return nil
	end

	local lessons = agent._load_lessons()
	local count = #lessons
	if count == 0 then
		return { ok = true, name = "Lessons", detail = "None yet (will learn from agent sessions)" }
	end

	-- Check for staleness
	local now = os.time()
	local stale_count = 0
	local thirty_days = 30 * 24 * 3600
	for _, l in ipairs(lessons) do
		if l.timestamp and (now - l.timestamp) > thirty_days then
			stale_count = stale_count + 1
		end
	end

	local detail = count .. " lesson(s)"
	if stale_count > 0 then
		detail = detail .. string.format(" (%d stale — consider :DwightLessons consolidate)", stale_count)
	end
	return { ok = true, name = "Lessons", detail = detail, warn = stale_count > count / 2 }
end

--- Check auto session status.
local function check_auto_session()
	local ok, auto = pcall(require, "dwight.auto")
	if not ok then
		return nil
	end

	local state = auto._load_state()
	if not state then
		return { ok = true, name = "Auto session", detail = "No active session" }
	end

	local task_num = state.current_task or 1
	local total = #state.tasks
	if state.failed then
		return {
			ok = true,
			name = "Auto session",
			detail = string.format(
				"FAILED at task %d/%d: %s — use :DwightAutoRetry or :DwightAutoResume",
				task_num,
				total,
				(state.tasks[task_num] or {}).title or "?"
			),
			warn = true,
		}
	elseif state.paused then
		return {
			ok = true,
			name = "Auto session",
			detail = string.format("PAUSED at task %d/%d — use :DwightContinue", task_num, total),
			warn = true,
		}
	end
	return { ok = true, name = "Auto session", detail = string.format("In progress: task %d/%d", task_num, total) }
end

--------------------------------------------------------------------
-- Main health check
--------------------------------------------------------------------

--- Run all checks and return structured results.
--- Used by both :DwightHealth and :checkhealth dwight.
function M._run_checks()
	local checks = {}

	-- Core checks (always run)
	checks[#checks + 1] = check_project()
	checks[#checks + 1] = check_git()
	checks[#checks + 1] = check_backend()
	checks[#checks + 1] = check_claude_auth()
	checks[#checks + 1] = check_api_key()
	checks[#checks + 1] = check_tests()
	checks[#checks + 1] = check_lessons()
	checks[#checks + 1] = check_auto_session()

	-- Also check common tools
	checks[#checks + 1] = check_binary("Node.js", "node", "--version")
	checks[#checks + 1] = check_binary("npm", "npm", "--version")

	-- GitHub CLI (optional, for :DwightIssue)
	pcall(function()
		local gh_check = require("dwight.github").check()
		checks[#checks + 1] = {
			ok = gh_check.ok,
			name = "GitHub CLI (gh)",
			detail = gh_check.detail,
			warn = not gh_check.ok, -- warn, not error (it's optional)
		}
	end)

	-- Optional dependencies
	local telescope_ok = pcall(require, "telescope")
	checks[#checks + 1] = {
		ok = true,
		name = "Telescope",
		detail = telescope_ok and "Available (better pickers)" or "Not installed (using vim.ui.select fallback)",
		warn = not telescope_ok,
	}

	local ts_ok = pcall(require, "nvim-treesitter")
	checks[#checks + 1] = {
		ok = true,
		name = "Treesitter",
		detail = ts_ok and "Available (signature extraction)" or "Not installed (no minimap/signatures)",
		warn = not ts_ok,
	}

	-- Feature and skill counts
	pcall(function()
		local features = require("dwight.features")
		local names = features.names()
		local skills = require("dwight.skills")
		local skill_names = skills.names()
		checks[#checks + 1] = {
			ok = true,
			name = "Features",
			detail = #names > 0 and (#names .. " feature(s): " .. table.concat(names, ", "):sub(1, 80))
				or "None detected — run :DwightBootstrap",
			warn = #names == 0,
		}
		checks[#checks + 1] = {
			ok = true,
			name = "Skills",
			detail = #skill_names > 0 and (#skill_names .. " skill(s)")
				or "None installed — run :DwightInstallSkills or :DwightMarketplace",
			warn = #skill_names == 0,
		}
	end)

	-- Filter out nil checks (skipped)
	local results = {}
	for _, c in ipairs(checks) do
		if c then
			results[#results + 1] = c
		end
	end

	return results
end

--- Neovim :checkhealth integration.
--- Called by `:checkhealth dwight`.
function M.check()
	local health = vim.health or require("health")

	health.start("Dwight")

	local results = M._run_checks()
	for _, r in ipairs(results) do
		if not r.ok then
			health.error(r.name .. ": " .. r.detail)
		elseif r.warn then
			health.warn(r.name .. ": " .. r.detail)
		else
			health.ok(r.name .. ": " .. r.detail)
		end
	end

	-- Config summary
	local cfg = require("dwight").config
	health.info("Backend: " .. (cfg.backend or "claude_code"))
	health.info("Provider: " .. (cfg.provider or "auto"))
	health.info("Model: " .. (cfg.model or "default"))
	health.info("CLI timeout: " .. tostring((cfg.agentic_opts and cfg.agentic_opts.cli_timeout) or 600) .. "s")
end

--- Run health check and display results in a buffer (:DwightHealth).
function M.show()
	local results = M._run_checks()

	local lines = { "# 🏥 Dwight Health Check", "" }
	local errors = 0
	local warns = 0

	for _, r in ipairs(results) do
		local icon
		if not r.ok then
			icon = "❌"
			errors = errors + 1
		elseif r.warn then
			icon = "⚠️"
			warns = warns + 1
		else
			icon = "✅"
		end
		lines[#lines + 1] = string.format("%s **%s**: %s", icon, r.name, r.detail)
	end

	lines[#lines + 1] = ""
	if errors == 0 and warns == 0 then
		lines[#lines + 1] = "---"
		lines[#lines + 1] = "**All checks passed!** Dwight is ready to go. 🎉"
	elseif errors == 0 then
		lines[#lines + 1] = "---"
		lines[#lines + 1] =
			string.format("**%d warning(s)** — Dwight will work but some features may be limited.", warns)
	else
		lines[#lines + 1] = "---"
		lines[#lines + 1] = string.format(
			"**%d error(s), %d warning(s)** — fix errors above for Dwight to work properly.",
			errors,
			warns
		)
	end

	-- Config summary
	local cfg = require("dwight").config
	lines[#lines + 1] = ""
	lines[#lines + 1] = "## Configuration"
	lines[#lines + 1] = string.format("- Backend: `%s`", cfg.backend or "claude_code")
	lines[#lines + 1] = string.format("- Provider: `%s`", cfg.provider or "auto")
	lines[#lines + 1] = string.format("- Model: `%s`", cfg.model or "default")
	lines[#lines + 1] = string.format("- Agentic: `%s`", cfg.agentic and "yes" or "no (pipeline mode)")
	lines[#lines + 1] =
		string.format("- CLI timeout: `%ds`", (cfg.agentic_opts and cfg.agentic_opts.cli_timeout) or 600)

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, _flatten(lines))
	vim.bo[buf].filetype = "markdown"
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.api.nvim_set_current_buf(buf)
end

return M
