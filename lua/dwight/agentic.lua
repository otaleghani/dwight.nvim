-- dwight/agentic.lua
-- CLI agent dispatcher: delegates coding tasks to external agent CLIs
-- (Claude Code, Codex, Gemini CLI) that handle the agentic loop internally.
--
-- Each backend is a thin spawn config + output parser. The hard work
-- (git checkpoints, verification gates, decomposition, session logging)
-- lives in auto.lua — that code is backend-agnostic.

local M = {}
local uv = vim.loop or vim.uv
local api = vim.api

--------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------

-- Active process tracking (for abort/cleanup)
M._active_handle = nil -- uv_process_t handle of running agent session
M._active_pid = nil -- PID for process group kill
M._active_backend = nil -- "claude_code", "codex", "gemini"

--------------------------------------------------------------------
-- Process Management
--------------------------------------------------------------------

--- Abort the currently running agent session.
--- Sends SIGTERM, then escalates to SIGKILL after 2s.
--- Also kills the entire process group to catch child processes.
function M.abort()
	if M._active_handle and not M._active_handle:is_closing() then
		pcall(function()
			M._active_handle:kill("sigterm")
		end)
		local kill_timer = uv.new_timer()
		local h = M._active_handle
		local pid = M._active_pid
		kill_timer:start(2000, 0, function()
			kill_timer:close()
			if h and not h:is_closing() then
				pcall(function()
					h:kill("sigkill")
				end)
			end
			-- Kill process group (catches child processes like `go build`, `npm test`, etc.)
			if pid then
				pcall(function()
					uv.kill(-pid, "sigkill")
				end)
				pcall(function()
					uv.kill(pid, "sigkill")
				end)
			end
		end)
	end
	M._active_handle = nil
	M._active_pid = nil
	M._active_backend = nil
end

--------------------------------------------------------------------
-- Language Detection & System Prompts
--------------------------------------------------------------------

--- Language detection and hints are delegated to dwight.languages registry.
local function detect_language()
	local ok, lang = pcall(function()
		return require("dwight.languages").detect()
	end)
	return (ok and lang) or "unknown"
end

--------------------------------------------------------------------
-- Structured Replay Log
-- Writes a JSON-lines log to .dwight/agentic-logs/ for debugging.
--------------------------------------------------------------------

local session_log_file = nil

local function open_session_log(task_name)
	pcall(function()
		local project = require("dwight.project")
		if not project.is_initialized() then
			return
		end
		local log_dir = project.dir() .. "/agentic-logs"
		vim.fn.mkdir(log_dir, "p")
		local safe_name = (task_name or "task"):sub(1, 30):gsub("[^%w_%-]", "-"):gsub("%-+", "-")
		local path = log_dir .. "/" .. os.date("%Y%m%d-%H%M%S") .. "-" .. safe_name .. ".jsonl"
		session_log_file = io.open(path, "w")
	end)
end

local function log_event(event)
	if not session_log_file then
		return
	end
	pcall(function()
		event.timestamp = os.time()
		session_log_file:write(vim.json.encode(event) .. "\n")
		session_log_file:flush()
	end)
end

local function close_session_log()
	if session_log_file then
		pcall(function()
			session_log_file:close()
		end)
		session_log_file = nil
	end
end

local function log_turn(iteration, role, content_summary)
	pcall(function()
		local log = require("dwight.log")
		local job_id = log._next_id()
		local label = string.format("agentic-turn-%d-%s", iteration, role)
		log.start(job_id, label, api.nvim_get_current_buf(), 0, 0, content_summary:sub(1, 2000))
		log.finish(job_id, "success", content_summary:sub(1, 2000), nil, nil)
	end)
end

--------------------------------------------------------------------
-- Task Prompt Builder (shared across backends)
--------------------------------------------------------------------

--- Build the full prompt sent to any CLI agent.
local function build_task_prompt(opts)
	local parts = {}

	parts[#parts + 1] = [[You are an autonomous coding agent running in non-interactive mode.
You MUST immediately execute the task below — read files, write files, run commands.
Do NOT ask for permission or confirmation. Do NOT say "Would you like me to proceed?"
Do NOT just describe what you would do. Actually DO it right now.
]]

	parts[#parts + 1] = "## Task\n" .. (opts.task or "No task specified")

	if opts.context and opts.context ~= "" then
		parts[#parts + 1] = "\n## Project Context\n" .. opts.context:sub(1, 30000)
	end

	if opts.prev_tasks and opts.prev_tasks ~= "" then
		parts[#parts + 1] = "\n## Previous Sub-Tasks (already completed)\n" .. opts.prev_tasks:sub(1, 10000)
	end

	-- Inject language-specific patterns
	local lang = detect_language()
	local lang_hint = require("dwight.languages").hint(lang) or ""
	if lang_hint ~= "" then
		parts[#parts + 1] = "\n" .. lang_hint
	end

	local test_cmd = M.get_test_command(lang) or "go test ./..."
	local build_cmd = M.get_build_command(lang) or "go build ./..."

	parts[#parts + 1] = string.format(
		[[

## Instructions
- IMMEDIATELY start reading files and writing code. No planning preamble.
- Read existing code before writing to understand patterns and conventions
- Write clean, idiomatic code that fits the project style
- After making changes, run the FULL project test suite: `%s`
  (not just tests for your new package — run ALL project tests)
- Run build to verify compilation: `%s`
- If tests fail, check if they are PRE-EXISTING failures (tests that were already broken
  before your changes). Only fix test failures that YOUR changes caused.
- When done, provide a brief summary of what you accomplished
- Focus ONLY on the specified task — do not implement unrelated features

## File hygiene — IMPORTANT
- Do NOT create summary, checklist, report, or documentation files in the project root.
- If you want to write notes, summaries, test results, or checklists, put them in:
  `.dwight/artifacts/` (create the directory if needed with `mkdir -p .dwight/artifacts`)
  Example: `.dwight/artifacts/REFACTORING_SUMMARY.md`, `.dwight/artifacts/TEST_RESULTS.md`
- Only create files in the actual source tree that are part of the implementation.
- Temporary test scripts should be cleaned up after use.
]],
		test_cmd,
		build_cmd
	)

	return table.concat(parts, "\n")
end

--------------------------------------------------------------------
-- Backend Registry
--------------------------------------------------------------------
-- Each backend defines:
--   build_args(prompt, cfg) → bin, args_table, env_table|nil
--   new_parser(on_status, on_tool, log_ev) → { on_chunk(data), get_result() }
--   classify_error(stderr, exit_code) → string
--   install_hint → string

local BACKENDS = {}

-- ─────────────────────────────────────────────────────────────────
-- Claude Code (Anthropic)
-- CLI: claude -p "prompt" --output-format stream-json --dangerously-skip-permissions
-- Auth: claude login (browser OAuth) or ANTHROPIC_API_KEY
-- ─────────────────────────────────────────────────────────────────

BACKENDS.claude_code = {
	build_args = function(prompt, cfg)
		local bin = cfg.claude_code_bin or "claude"
		local model = cfg.claude_code_model
		local ac = cfg.agentic_opts or {}

		local args = {
			"-p",
			prompt,
			"--output-format",
			"stream-json",
			"--verbose",
			"--dangerously-skip-permissions",
		}
		if model then
			args[#args + 1] = "--model"
			args[#args + 1] = model
		end

		-- Environment: inherit current + set max output tokens
		local env = nil
		pcall(function()
			local current_env = vim.fn.environ()
			local env_list = {}
			for k, v in pairs(current_env) do
				env_list[#env_list + 1] = k .. "=" .. v
			end
			local max_tokens = ac.max_output_tokens or 64000
			env_list[#env_list + 1] = "CLAUDE_CODE_MAX_OUTPUT_TOKENS=" .. tostring(max_tokens)
			env = env_list
		end)

		return bin, args, env
	end,

	--- Stream-json NDJSON parser: extracts inner thoughts, tool use, and final result.
	new_parser = function(on_status, on_tool, log_ev)
		local buf = ""
		local final_result = nil
		local last_command = nil

		--- Route a tool invocation to on_tool with proper formatting.
		local function emit_tool(ti)
			-- Claude Code sends {type: "tool_use", name: "Bash", input: {...}}
			-- Prefer .name (actual tool) over .type (often just "tool_use")
			local tt = ti.name or (ti.type ~= "tool_use" and ti.type) or "?"
			local det = ""
			if tt == "bash" or tt == "run_command" or tt == "Bash" then
				det = ti.command or (ti.input and ti.input.command) or ""
				on_tool("$ " .. det:sub(1, 120))
				last_command = det
			elseif tt == "read" or tt == "read_file" or tt == "Read" then
				det = ti.path or (ti.input and (ti.input.file_path or ti.input.path)) or ""
				on_tool("Read " .. det:sub(1, 120))
			elseif tt == "write" or tt == "write_file" or tt == "Write" then
				det = ti.path or (ti.input and (ti.input.file_path or ti.input.path)) or ""
				on_tool("Write " .. det:sub(1, 120))
			elseif tt == "edit" or tt == "str_replace" or tt == "Edit" or tt == "MultiEdit" then
				det = ti.path or (ti.input and (ti.input.file_path or ti.input.path)) or ""
				on_tool("Edit " .. det:sub(1, 120))
			elseif tt == "list" or tt == "list_dir" or tt == "ListDir" then
				det = ti.path or (ti.input and (ti.input.path or ti.input.dir_path)) or ""
				on_tool("List " .. det:sub(1, 120))
			elseif tt == "search" or tt == "grep" or tt == "Grep" or tt == "Glob" then
				det = ti.pattern or (ti.input and (ti.input.pattern or ti.input.query)) or ""
				on_tool("Search " .. det:sub(1, 120))
			elseif tt == "task_complete" or tt == "TodoComplete" then
				on_tool("Task complete")
				local s = ti.input and ti.input.summary
				if s and s ~= "" then
					final_result = final_result or s
				end
			else
				-- Unknown tool — show whatever we have
				local label = tt
				if ti.input then
					-- Try to extract something useful from input
					local p = ti.input.file_path or ti.input.path or ti.input.command or ""
					if p ~= "" then
						label = tt .. ": " .. p:sub(1, 60)
					end
				end
				on_tool("Tool: " .. tostring(label):sub(1, 120))
			end
			log_ev({ turn = -1, type = "cc_tool", tool = tt, detail = (det or ""):sub(1, 200) })
		end

		local function process_line(line)
			local jok, event = pcall(vim.json.decode, line)
			if not jok or type(event) ~= "table" then
				return
			end

			vim.schedule(function()
				pcall(function()
					local etype = event.type or ""

					if etype == "assistant" then
						local msg = event.message
						local content = msg and msg.content or event.content
						if type(content) == "table" then
							for _, block in ipairs(content) do
								if type(block) == "table" then
									if block.type == "text" and block.text and block.text ~= "" then
										on_status(block.text:sub(1, 500))
										log_ev({ turn = -1, type = "cc-thought", text = block.text:sub(1, 500) })
									elseif block.type == "tool_use" then
										-- Tool use blocks nested inside assistant messages
										emit_tool(block)
									end
								end
							end
						elseif type(content) == "string" and content ~= "" then
							on_status(content:sub(1, 500))
						end
						local usage = (msg and msg.usage) or event.usage
						if usage then
							log_ev({
								turn = -1,
								type = "cc_usage",
								input_tokens = usage.input_tokens,
								output_tokens = usage.output_tokens,
							})
						end
					elseif etype == "content_block_delta" then
						local delta = event.delta
						if delta and delta.type == "text_delta" and delta.text and delta.text ~= "" then
							on_status(delta.text:sub(1, 500))
						end

					-- Claude Code emits tool calls as content_block_start events
					elseif etype == "content_block_start" then
						local cb = event.content_block
						if cb and cb.type == "tool_use" then
							emit_tool(cb)
						end
					elseif etype == "tool_use" then
						emit_tool(event.tool or event)
					elseif etype == "tool_result" then
						-- Parse tool results for test/build outcomes
						local content = event.content or event.output or ""
						if type(content) == "table" then
							local ps = {}
							for _, b in ipairs(content) do
								if type(b) == "table" and b.text then
									ps[#ps + 1] = b.text
								elseif type(b) == "string" then
									ps[#ps + 1] = b
								end
							end
							content = table.concat(ps, "\n")
						end

						if type(content) == "string" and content ~= "" then
							-- Detect test results
							local is_test = last_command
								and (
									last_command:match("test")
									or last_command:match("pytest")
									or last_command:match("jest")
									or last_command:match("vitest")
								)
							local is_build = last_command
								and (
									last_command:match("build")
									or last_command:match("compile")
									or last_command:match("tsc")
									or last_command:match("cargo check")
								)

							if is_test then
								-- Go: "ok" / "FAIL" lines
								local pass = content:match("ok%s") or content:match("PASS")
								local fail = content:match("FAIL") or content:match("FAILED")
								if fail then
									on_status("Tests FAILED")
								elseif pass then
									on_status("Tests passed")
								end
							elseif is_build then
								local fail = content:match("FAIL")
									or content:match("error")
									or content:match("Error")
									or event.is_error
								if fail then
									on_status("Build failed")
								else
									on_status("Build OK")
								end
							end

							last_command = nil
							log_ev({
								turn = -1,
								type = "cc_tool_result",
								summary = content:sub(1, 200),
								is_error = event.is_error or false,
							})
						end
					elseif etype == "result" then
						local rt = event.result or event.text or event.content or ""
						if type(rt) == "table" then
							local ps = {}
							for _, b in ipairs(rt) do
								if type(b) == "table" and b.text then
									ps[#ps + 1] = b.text
								elseif type(b) == "string" then
									ps[#ps + 1] = b
								end
							end
							rt = table.concat(ps, "\n")
						end
						if type(rt) == "string" and rt ~= "" then
							final_result = rt
						end
						if event.cost then
							log_ev({
								turn = -1,
								type = "cc_final_cost",
								input_tokens = event.cost.input_tokens,
								output_tokens = event.cost.output_tokens,
								duration_ms = event.duration_ms,
							})
						end
					elseif etype == "error" then
						local emsg = event.error or event.message or "unknown error"
						if type(emsg) == "table" then
							emsg = emsg.message or vim.inspect(emsg)
						end
						on_status("Error: " .. tostring(emsg):sub(1, 200))
					end
				end)
			end)
		end

		return {
			on_chunk = function(data)
				buf = buf .. data
				while true do
					local nl = buf:find("\n")
					if not nl then
						break
					end
					local line = buf:sub(1, nl - 1)
					buf = buf:sub(nl + 1)
					if line ~= "" then
						process_line(line)
					end
				end
			end,
			get_result = function()
				return final_result
			end,
		}
	end,

	classify_error = function(err_output, code)
		if err_output:match("not found") or err_output:match("command not found") then
			return "Claude Code CLI not found. Install: npm i -g @anthropic-ai/claude-code"
		elseif err_output:match("auth") or err_output:match("login") then
			return "Claude Code not authenticated. Run 'claude' in terminal to log in."
		end
		return "Claude Code failed (exit " .. code .. "): " .. err_output:sub(1, 300)
	end,

	install_hint = "npm i -g @anthropic-ai/claude-code",
}

-- ─────────────────────────────────────────────────────────────────
-- Codex (OpenAI)
-- CLI: codex -q --full-auto "prompt"
-- Auth: OPENAI_API_KEY environment variable
-- ─────────────────────────────────────────────────────────────────

BACKENDS.codex = {
	build_args = function(prompt, cfg)
		local bin = cfg.codex_bin or "codex"
		local model = cfg.codex_model

		local args = {
			"-q",
			"--full-auto",
			prompt,
		}
		if model then
			args[#args + 1] = "--model"
			args[#args + 1] = model
		end

		return bin, args, nil
	end,

	--- Codex outputs plain text. Parse heuristically for progress.
	new_parser = function(on_status, on_tool, log_ev)
		local buf = ""
		local all_output = {}

		return {
			on_chunk = function(data)
				all_output[#all_output + 1] = data
				buf = buf .. data
				while true do
					local nl = buf:find("\n")
					if not nl then
						break
					end
					local line = buf:sub(1, nl - 1)
					buf = buf:sub(nl + 1)
					if line ~= "" then
						vim.schedule(function()
							if line:match("^%$ ") or line:match("^> ") then
								on_tool("$ " .. line:sub(1, 120))
							elseif line:match("[Rr]eading") or line:match("[Ww]riting") or line:match("[Ee]diting") then
								on_tool(line:sub(1, 120))
							elseif line:match("[Rr]unning") or line:match("[Ee]xecuting") then
								on_tool("$ " .. line:sub(1, 120))
							elseif #line > 10 then
								on_status(line:sub(1, 500))
							end
						end)
						log_ev({ turn = -1, type = "codex_output", line = line:sub(1, 500) })
					end
				end
			end,
			get_result = function()
				local output = table.concat(all_output, "")
				local last_para = output:match("\n\n([^\n]+)%s*$")
				if last_para and #last_para > 20 then
					return last_para
				end
				return output:sub(-500)
			end,
		}
	end,

	classify_error = function(err_output, code)
		if err_output:match("not found") or err_output:match("command not found") then
			return "Codex CLI not found. Install: npm i -g @openai/codex"
		elseif err_output:match("OPENAI_API_KEY") or err_output:match("auth") then
			return "Codex not authenticated. Set OPENAI_API_KEY environment variable."
		end
		return "Codex failed (exit " .. code .. "): " .. err_output:sub(1, 300)
	end,

	install_hint = "npm i -g @openai/codex",
}

-- ─────────────────────────────────────────────────────────────────
-- Gemini CLI (Google)
-- CLI: gemini "prompt"
-- Auth: GEMINI_API_KEY or gcloud auth
-- ─────────────────────────────────────────────────────────────────

BACKENDS.gemini = {
	build_args = function(prompt, cfg)
		local bin = cfg.gemini_bin or "gemini"
		local model = cfg.gemini_model

		local args = {
			"--sandbox",
			"false",
			prompt,
		}
		if model then
			args[#args + 1] = "--model"
			args[#args + 1] = model
		end

		return bin, args, nil
	end,

	--- Gemini CLI outputs plain text. Parse heuristically.
	new_parser = function(on_status, on_tool, log_ev)
		local buf = ""
		local all_output = {}

		return {
			on_chunk = function(data)
				all_output[#all_output + 1] = data
				buf = buf .. data
				while true do
					local nl = buf:find("\n")
					if not nl then
						break
					end
					local line = buf:sub(1, nl - 1)
					buf = buf:sub(nl + 1)
					if line ~= "" then
						vim.schedule(function()
							if line:match("^%$ ") or line:match("^> ") then
								on_tool("$ " .. line:sub(1, 120))
							elseif line:match("[Rr]ead") or line:match("[Ww]rit") or line:match("[Ee]dit") then
								on_tool(line:sub(1, 120))
							elseif line:match("[Rr]un") or line:match("[Ee]xecut") then
								on_tool("$ " .. line:sub(1, 120))
							elseif #line > 10 then
								on_status(line:sub(1, 500))
							end
						end)
						log_ev({ turn = -1, type = "gemini_output", line = line:sub(1, 500) })
					end
				end
			end,
			get_result = function()
				local output = table.concat(all_output, "")
				local last_para = output:match("\n\n([^\n]+)%s*$")
				if last_para and #last_para > 20 then
					return last_para
				end
				return output:sub(-500)
			end,
		}
	end,

	classify_error = function(err_output, code)
		if err_output:match("not found") or err_output:match("command not found") then
			return "Gemini CLI not found. Install: npm i -g @anthropic-ai/gemini-cli"
		elseif err_output:match("auth") or err_output:match("GEMINI_API_KEY") then
			return "Gemini CLI not authenticated. Set GEMINI_API_KEY or run 'gcloud auth login'."
		end
		return "Gemini CLI failed (exit " .. code .. "): " .. err_output:sub(1, 300)
	end,

	install_hint = "npm i -g @google/gemini-cli",
}

--------------------------------------------------------------------
-- Shared CLI Spawn Engine
--------------------------------------------------------------------

--- Spawn a CLI agent backend and manage its lifecycle.
--- @param backend_name string  Key into BACKENDS table
--- @param opts table           { task, context, prev_tasks, cwd, on_status, on_tool, on_complete }
local function spawn_backend(backend_name, opts)
	local backend = BACKENDS[backend_name]
	local cfg = require("dwight").config
	local cwd = opts.cwd or vim.fn.getcwd()
	local started = os.time()
	local on_status = opts.on_status
	local on_tool = opts.on_tool
	local on_complete = opts.on_complete

	-- Build prompt
	local prompt = build_task_prompt(opts)

	-- Log session to DwightLog
	local session_job_id
	pcall(function()
		local dlog = require("dwight.log")
		session_job_id = dlog._next_id()
		dlog.start(
			session_job_id,
			"agentic:" .. backend_name,
			api.nvim_get_current_buf(),
			0,
			0,
			string.format(
				"═══ %s Session ═══\nBackend: %s\nTask: %s",
				backend_name,
				backend_name,
				(opts.task or "?"):sub(1, 300)
			)
		)
		dlog.set_metadata(session_job_id, { backend = backend_name })
	end)

	-- Open structured replay log
	open_session_log(opts.task)
	log_event({ turn = 0, type = "start", task = (opts.task or ""):sub(1, 500), backend = backend_name })

	-- Track model
	pcall(function()
		require("dwight.tracker").set_model(backend_name)
	end)

	on_status(string.format("🤖 Starting %s session...", backend_name))

	-- Build args from backend
	local bin, args, env = backend.build_args(prompt, cfg)

	-- Set up pipes
	local stdout_chunks = {}
	local stderr_chunks = {}
	local stderr_lines = {}
	local stdout_pipe = uv.new_pipe(false)
	local stderr_pipe = uv.new_pipe(false)

	-- Timeout (declared before spawn so exit callback can cancel it)
	local timeout_timer = nil
	local ac = cfg.agentic_opts or {}
	local timeout_secs = ac.cli_timeout or ac.claude_code_timeout or 600

	-- Create stdout parser from backend (before spawn, referenced in exit callback)
	local parser = backend.new_parser(on_status, on_tool, log_event)

	-- Spawn
	local spawn_opts = {
		args = args,
		stdio = { nil, stdout_pipe, stderr_pipe },
		cwd = cwd,
	}
	if env then
		spawn_opts.env = env
	end

	local handle
	handle = uv.spawn(bin, spawn_opts, function(code)
		M._active_handle = nil
		M._active_pid = nil
		M._active_backend = nil
		if timeout_timer and not timeout_timer:is_closing() then
			timeout_timer:close()
		end
		timeout_timer = nil
		if stdout_pipe then
			stdout_pipe:close()
		end
		if stderr_pipe then
			stderr_pipe:close()
		end
		if handle then
			handle:close()
		end

		vim.schedule(function()
			local output = table.concat(stdout_chunks, "")
			local err_output = table.concat(stderr_chunks, "")
			local duration = os.time() - started

			log_event({ turn = -1, type = "finish", exit_code = code, duration = duration, output_len = #output })
			close_session_log()

			-- Failure
			if code ~= 0 then
				local error_msg = backend.classify_error(err_output, code)
				on_status("❌ " .. error_msg)
				pcall(function()
					if session_job_id then
						require("dwight.log").finish(session_job_id, "error", nil, nil, error_msg)
					end
				end)
				on_complete(false, {
					error = error_msg,
					summary = error_msg,
					journal = stderr_lines,
					duration = duration,
				})
				return
			end

			-- Success: extract summary from parser
			local summary = parser.get_result() or ""
			if summary == "" then
				summary = output:sub(-500)
				local last_para = output:match("\n\n([^\n]+)%s*$")
				if last_para and #last_para > 20 then
					summary = last_para
				end
			end

			on_status(string.format("✅ %s completed in %ds", backend_name, duration))
			pcall(function()
				if session_job_id then
					require("dwight.log").finish(session_job_id, "success", summary:sub(1, 500), nil, nil)
				end
			end)
			on_complete(true, {
				summary = summary:sub(1, 500),
				journal = stderr_lines,
				duration = duration,
				output = output,
			})
		end)
	end)

	if not handle then
		local err = string.format("Failed to spawn '%s'. Is it installed? %s", bin, backend.install_hint or "")
		on_status("❌ " .. err)
		pcall(function()
			if session_job_id then
				require("dwight.log").finish(session_job_id, "error", nil, nil, err)
			end
		end)
		close_session_log()
		on_complete(false, { error = err, journal = {} })
		return
	end

	-- Track for abort/cleanup
	M._active_handle = handle
	M._active_pid = handle:get_pid()
	M._active_backend = backend_name

	-- Start timeout
	timeout_timer = uv.new_timer()
	timeout_timer:start(timeout_secs * 1000, 0, function()
		timeout_timer:close()
		if handle and not handle:is_closing() then
			vim.schedule(function()
				on_status(string.format("⏰ %s timed out after %ds — killing", backend_name, timeout_secs))
			end)
			pcall(function()
				handle:kill("sigkill")
			end)
			local pid = M._active_pid
			if pid then
				pcall(function()
					uv.kill(-pid, "sigkill")
				end)
			end
		end
	end)

	-- Read stdout through parser
	stdout_pipe:read_start(function(err, data)
		if not err and data then
			stdout_chunks[#stdout_chunks + 1] = data
			parser.on_chunk(data)
		end
	end)

	-- Read stderr (fallback progress for backends without structured stdout)
	local stderr_buf = ""
	stderr_pipe:read_start(function(err, data)
		if not err and data then
			stderr_chunks[#stderr_chunks + 1] = data
			stderr_buf = stderr_buf .. data

			while true do
				local nl = stderr_buf:find("\n")
				if not nl then
					break
				end
				local line = stderr_buf:sub(1, nl - 1)
				stderr_buf = stderr_buf:sub(nl + 1)

				if line ~= "" then
					stderr_lines[#stderr_lines + 1] = line
					vim.schedule(function()
						if line:match("[Rr]ead") or line:match("[Ww]rit") or line:match("[Ee]dit") then
							on_tool(line:sub(1, 120))
						elseif line:match("[Rr]un") or line:match("[Ee]xecut") then
							on_tool("$ " .. line:sub(1, 120))
						elseif line:match("[Ss]earch") or line:match("[Ll]ist") then
							on_tool("Search " .. line:sub(1, 120))
						elseif #line > 5 then
							on_status(line:sub(1, 200))
						end
					end)
				end
			end
		end
	end)
end

--------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------

--- Run a task via the configured CLI agent backend.
--- @param opts table {
---   task: string,           -- What to implement
---   context: string|nil,    -- Project context (manifest, tree, etc.)
---   prev_tasks: string|nil, -- Summary of completed sub-tasks
---   cwd: string|nil,        -- Working directory
---   on_status: function,    -- Called with status text
---   on_tool: function,      -- Called with tool-use description
---   on_complete: function,  -- Called with (success: bool, data: table)
--- }
function M.run(opts)
	local on_status = opts.on_status or function() end
	local on_tool = opts.on_tool or function() end
	local on_complete = opts.on_complete

	if not on_complete then
		error("agentic.run() requires on_complete callback")
	end

	-- Resolve backend
	local cfg = require("dwight").config
	local backend_name = cfg.backend or "claude_code"

	-- Validate backend
	if not BACKENDS[backend_name] then
		if backend_name == "api" then
			-- Legacy: api backend was removed, fall back gracefully
			on_status("⚠️ The 'api' agentic backend has been removed. Using 'claude_code' instead.")
			on_status("   Update your config: backend = 'claude_code'")
			backend_name = "claude_code"
		else
			on_status("❌ Unknown backend: " .. tostring(backend_name))
			on_complete(false, { error = "Unknown backend: " .. backend_name })
			return
		end
	end

	spawn_backend(backend_name, {
		task = opts.task,
		context = opts.context,
		prev_tasks = opts.prev_tasks,
		cwd = opts.cwd or vim.fn.getcwd(),
		on_status = on_status,
		on_tool = on_tool,
		on_complete = on_complete,
	})
end

--------------------------------------------------------------------
-- Utilities (public) — delegated to dwight.languages registry
--------------------------------------------------------------------

--- Expose language detection for other modules.
M.detect_language = detect_language

--- Get the appropriate test command for the detected language.
function M.get_test_command(lang)
	return require("dwight.languages").test_cmd(lang or detect_language())
end

--- Get the appropriate build/compile check command.
function M.get_build_command(lang)
	return require("dwight.languages").build_cmd(lang or detect_language())
end

--- Get the lint command for the project.
--- Returns (command, binary) or (nil, nil) if no linter is available.
function M.get_lint_command(lang)
	return require("dwight.languages").lint_cmd(lang or detect_language())
end

--- Get the static analysis / vet command.
function M.get_vet_command(lang)
	return require("dwight.languages").vet_cmd(lang or detect_language())
end

--- Get the test-with-coverage command.
--- Returns { cmd, parse_total } or nil.
function M.get_coverage_command(lang)
	return require("dwight.languages").coverage_cmd(lang or detect_language())
end

--- Get the smoke test command.
--- Returns { build, run, cleanup? } or nil.
function M.get_smoke_command(lang)
	return require("dwight.languages").smoke_cmd(lang or detect_language())
end

--- List registered backend names.
function M.available_backends()
	local names = {}
	for k in pairs(BACKENDS) do
		names[#names + 1] = k
	end
	table.sort(names)
	return names
end

return M
