-- dwight/inline/backends.lua
-- Backend dispatchers: API (single/multi-pass), Codex, Gemini, OpenCode, Claude Code.
-- Contains the public M.run entry point which dispatches to the right backend.

local M = {}

local uv = vim.loop or vim.uv

local function get_config()
	return require("dwight").config
end

local function get_dwight()
	return require("dwight")
end

--------------------------------------------------------------------
-- Backend: API (single or multi-pass)
--------------------------------------------------------------------

local function run_api(prompt_text, selection, cfg, mode_name, job_id, model_override, think_depth)
	local dwight = get_dwight()
	local ui = require("dwight.ui")
	local log = require("dwight.log")
	local prompt_mod = require("dwight.prompt")
	local api_mod = require("dwight.inline.api")
	local response = require("dwight.inline.response")

	think_depth = think_depth or 1

	-- ^1 or ^2: single request (^2 has CoT prefix baked into prompt by prompt.lua)
	if think_depth <= 2 then
		local handle = api_mod.api_call(prompt_text, model_override, cfg, function(text, err)
			if err then
				response.handle_response(job_id, "", err, 1, selection, mode_name, prompt_text)
			else
				response.handle_response(job_id, text, "", 0, selection, mode_name, prompt_text)
			end
		end, {
			on_progress = function(chars)
				-- Update indicator with streaming progress
				pcall(function()
					local job = dwight._active_jobs[job_id]
					if job then
						ui.update_indicator_label(job_id, string.format("streaming %d chars", chars))
					end
				end)
			end,
		})
		local djob = dwight._active_jobs[job_id]
		if djob and handle then
			djob.handle = handle
		end
		return
	end

	-- ^3+: Multi-pass reasoning
	-- Pass 1: Analysis
	local analysis_prompt = prompt_mod.build_analysis(prompt_text, 1)
	local depth_label = think_depth == 3 and "^3 (analyze -> code)" or "^4 (analyze -> plan -> code)"
	vim.notify(string.format("[dwight] Job #%d: %s -- pass 1 (analysis)...", job_id, depth_label), vim.log.levels.INFO)

	api_mod.api_call(analysis_prompt, model_override, cfg, function(analysis, err1)
		if err1 then
			response.handle_response(job_id, "", "Analysis pass failed: " .. err1, 1, selection, mode_name, prompt_text)
			return
		end

		log.append_note(job_id, "Pass 1 (analysis):\n" .. (analysis or ""))

		local function do_final_pass(context_text)
			-- Final pass: code generation with analysis/plan context
			local final_prompt = prompt_mod.build_with_analysis(prompt_text, context_text)

			vim.notify(string.format("[dwight] Job #%d: final pass (code)...", job_id), vim.log.levels.INFO)

			local handle = api_mod.api_call(final_prompt, model_override, cfg, function(text, err)
				if err then
					response.handle_response(
						job_id,
						"",
						"Code pass failed: " .. err,
						1,
						selection,
						mode_name,
						prompt_text
					)
				else
					response.handle_response(job_id, text, "", 0, selection, mode_name, prompt_text)
				end
			end)
			local djob = dwight._active_jobs[job_id]
			if djob and handle then
				djob.handle = handle
			end
		end

		if think_depth >= 4 then
			-- ^4: Pass 2 (plan), then pass 3 (code)
			local plan_prompt = prompt_mod.build_analysis(prompt_text, 2)
				.. "\n\nAnalysis from previous pass:\n"
				.. (analysis or "")

			vim.notify(string.format("[dwight] Job #%d: pass 2 (planning)...", job_id), vim.log.levels.INFO)

			api_mod.api_call(plan_prompt, model_override, cfg, function(plan, err2)
				if err2 then
					-- Fall back to using just analysis
					do_final_pass(analysis or "")
					return
				end
				log.append_note(job_id, "Pass 2 (plan):\n" .. (plan or ""))
				do_final_pass((analysis or "") .. "\n\nImplementation plan:\n" .. (plan or ""))
			end)
		else
			-- ^3: Pass 2 (code with analysis)
			do_final_pass(analysis or "")
		end
	end)
end

--------------------------------------------------------------------
-- Backend: opencode CLI
--------------------------------------------------------------------

local function run_codex(prompt_text, selection, cfg, mode_name, job_id)
	local dwight = get_dwight()
	local ui = require("dwight.ui")
	local log = require("dwight.log")
	local response = require("dwight.inline.response")

	local codex_bin = cfg.codex_bin or "codex"

	local args = {
		"exec",
		"--full-auto",
		prompt_text,
	}

	local model = cfg.codex_model
	if model then
		table.insert(args, "--model")
		table.insert(args, model)
	end

	-- Track model
	pcall(function()
		require("dwight.tracker").set_model(model or "codex")
	end)

	local stdout_chunks, stderr_chunks = {}, {}
	local stdout, stderr = uv.new_pipe(false), uv.new_pipe(false)

	local handle
	handle = uv.spawn(codex_bin, {
		args = args,
		stdio = { nil, stdout, stderr },
		cwd = vim.fn.getcwd(),
	}, function(code)
		if stdout then
			stdout:close()
		end
		if stderr then
			stderr:close()
		end
		if handle then
			handle:close()
		end
		vim.schedule(function()
			response.handle_response(
				job_id,
				table.concat(stdout_chunks, ""),
				table.concat(stderr_chunks, ""),
				code,
				selection,
				mode_name,
				prompt_text
			)
		end)
	end)

	if not handle then
		log.finish(job_id, "error", "", nil, "Failed to spawn codex. Install: npm i -g @openai/codex")
		ui.clear_indicators(job_id)
		dwight._active_jobs[job_id] = nil
		return
	end

	local djob = dwight._active_jobs[job_id]
	if djob then
		djob.handle = handle
	end

	stdout:read_start(function(err, data)
		if not err and data then
			stdout_chunks[#stdout_chunks + 1] = data
		end
	end)
	stderr:read_start(function(err, data)
		if not err and data then
			stderr_chunks[#stderr_chunks + 1] = data
		end
	end)
end

local function run_gemini(prompt_text, selection, cfg, mode_name, job_id)
	local dwight = get_dwight()
	local ui = require("dwight.ui")
	local log = require("dwight.log")
	local response = require("dwight.inline.response")

	local gemini_bin = cfg.gemini_bin or "gemini"

	local args = {
		"--sandbox",
		"false",
		prompt_text,
	}

	local model = cfg.gemini_model
	if model then
		table.insert(args, "--model")
		table.insert(args, model)
	end

	-- Track model
	pcall(function()
		require("dwight.tracker").set_model(model or "gemini")
	end)

	local stdout_chunks, stderr_chunks = {}, {}
	local stdout, stderr = uv.new_pipe(false), uv.new_pipe(false)

	local handle
	handle = uv.spawn(gemini_bin, {
		args = args,
		stdio = { nil, stdout, stderr },
		cwd = vim.fn.getcwd(),
	}, function(code)
		if stdout then
			stdout:close()
		end
		if stderr then
			stderr:close()
		end
		if handle then
			handle:close()
		end
		vim.schedule(function()
			response.handle_response(
				job_id,
				table.concat(stdout_chunks, ""),
				table.concat(stderr_chunks, ""),
				code,
				selection,
				mode_name,
				prompt_text
			)
		end)
	end)

	if not handle then
		log.finish(job_id, "error", "", nil, "Failed to spawn gemini. Install: npm i -g @google/gemini-cli")
		ui.clear_indicators(job_id)
		dwight._active_jobs[job_id] = nil
		return
	end

	local djob = dwight._active_jobs[job_id]
	if djob then
		djob.handle = handle
	end

	stdout:read_start(function(err, data)
		if not err and data then
			stdout_chunks[#stdout_chunks + 1] = data
		end
	end)
	stderr:read_start(function(err, data)
		if not err and data then
			stderr_chunks[#stderr_chunks + 1] = data
		end
	end)
end

local function run_opencode(prompt_text, selection, cfg, mode_name, job_id)
	local dwight = get_dwight()
	local ui = require("dwight.ui")
	local log = require("dwight.log")
	local response = require("dwight.inline.response")

	local prompt_file = vim.fn.tempname() .. "_dwight_prompt.md"
	local f = io.open(prompt_file, "w")
	if not f then
		log.finish(job_id, "error", "", nil, "Failed to write prompt")
		ui.clear_indicators(job_id)
		dwight._active_jobs[job_id] = nil
		return
	end
	f:write(prompt_text)
	f:close()

	local extra_flags = {}
	if cfg.model then
		extra_flags[#extra_flags + 1] = "--model"
		extra_flags[#extra_flags + 1] = cfg.model
	end
	for _, flag in ipairs(cfg.opencode_flags or {}) do
		extra_flags[#extra_flags + 1] = flag
	end

	local wrapper = vim.fn.tempname() .. "_dwight_run.sh"
	local wf = io.open(wrapper, "w")
	if not wf then
		os.remove(prompt_file)
		log.finish(job_id, "error", "", nil, "Failed to write wrapper")
		ui.clear_indicators(job_id)
		dwight._active_jobs[job_id] = nil
		return
	end
	wf:write("#!/bin/sh\n")
	wf:write(string.format("%s run", cfg.opencode_bin))
	for _, flag in ipairs(extra_flags) do
		wf:write(string.format(" %s", vim.fn.shellescape(flag)))
	end
	wf:write(string.format(' "$(cat %s)"\n', prompt_file))
	wf:close()
	os.execute("chmod +x " .. vim.fn.shellescape(wrapper))

	local stdout_chunks, stderr_chunks = {}, {}
	local stdout, stderr = uv.new_pipe(false), uv.new_pipe(false)

	local handle
	handle = uv.spawn("sh", {
		args = { wrapper },
		stdio = { nil, stdout, stderr },
		cwd = vim.fn.getcwd(),
	}, function(code)
		if stdout then
			stdout:close()
		end
		if stderr then
			stderr:close()
		end
		if handle then
			handle:close()
		end
		pcall(os.remove, prompt_file)
		pcall(os.remove, wrapper)
		vim.schedule(function()
			response.handle_response(
				job_id,
				table.concat(stdout_chunks, ""),
				table.concat(stderr_chunks, ""),
				code,
				selection,
				mode_name,
				prompt_text
			)
		end)
	end)

	if not handle then
		pcall(os.remove, prompt_file)
		pcall(os.remove, wrapper)
		log.finish(job_id, "error", "", nil, "Failed to spawn opencode")
		ui.clear_indicators(job_id)
		dwight._active_jobs[job_id] = nil
		return
	end

	local djob = dwight._active_jobs[job_id]
	if djob then
		djob.handle = handle
	end

	stdout:read_start(function(err, data)
		if not err and data then
			stdout_chunks[#stdout_chunks + 1] = data
		end
	end)
	stderr:read_start(function(err, data)
		if not err and data then
			stderr_chunks[#stderr_chunks + 1] = data
		end
	end)
end

local function run_claude_code(prompt_text, selection, cfg, mode_name, job_id, model_override)
	local dwight = get_dwight()
	local ui = require("dwight.ui")
	local log = require("dwight.log")
	local response = require("dwight.inline.response")

	local claude_bin = cfg.claude_code_bin or "claude"

	-- Write prompt to temp file
	local prompt_file = vim.fn.tempname() .. "_dwight_cc_prompt.md"
	local f = io.open(prompt_file, "w")
	if not f then
		log.finish(job_id, "error", "", nil, "Failed to write prompt")
		ui.clear_indicators(job_id)
		dwight._active_jobs[job_id] = nil
		return
	end
	f:write(prompt_text)
	f:close()

	-- Build claude args
	local args = {
		"-p",
		prompt_text,
		"--output-format",
		"text",
	}

	-- Model priority: explicit override (from model diversity) > config > claude default
	local model = model_override or cfg.claude_code_model
	if model then
		table.insert(args, "--model")
		table.insert(args, model)
	end

	-- Track model
	pcall(function()
		require("dwight.tracker").set_model(model or "claude-code")
	end)

	local stdout_chunks, stderr_chunks = {}, {}
	local stdout, stderr = uv.new_pipe(false), uv.new_pipe(false)

	local handle
	handle = uv.spawn(claude_bin, {
		args = args,
		stdio = { nil, stdout, stderr },
		cwd = vim.fn.getcwd(),
	}, function(code)
		if stdout then
			stdout:close()
		end
		if stderr then
			stderr:close()
		end
		if handle then
			handle:close()
		end
		pcall(os.remove, prompt_file)
		vim.schedule(function()
			response.handle_response(
				job_id,
				table.concat(stdout_chunks, ""),
				table.concat(stderr_chunks, ""),
				code,
				selection,
				mode_name,
				prompt_text
			)
		end)
	end)

	if not handle then
		pcall(os.remove, prompt_file)
		log.finish(job_id, "error", "", nil, "Failed to spawn claude. Install: npm i -g @anthropic-ai/claude-code")
		ui.clear_indicators(job_id)
		dwight._active_jobs[job_id] = nil
		return
	end

	local djob = dwight._active_jobs[job_id]
	if djob then
		djob.handle = handle
	end

	stdout:read_start(function(err, data)
		if not err and data then
			stdout_chunks[#stdout_chunks + 1] = data
		end
	end)
	stderr:read_start(function(err, data)
		if not err and data then
			stderr_chunks[#stderr_chunks + 1] = data
		end
	end)
end

--------------------------------------------------------------------
-- Public API: run
--------------------------------------------------------------------

function M.run(prompt_text, selection, cfg, mode_name, model_override, think_depth, opts)
	opts = opts or {}
	local ui = require("dwight.ui")
	local dwight = get_dwight()
	local log = require("dwight.log")
	local jobs = require("dwight.inline.jobs")

	local bufnr = selection.bufnr
	local start_line = selection.start_line
	local end_line = selection.end_line

	if jobs.has_overlap(bufnr, start_line, end_line) then
		vim.notify("[dwight] This selection overlaps with a running job.", vim.log.levels.WARN)
		return
	end

	local job_id = jobs.new_job_id()
	log.start(job_id, mode_name or "custom", bufnr, start_line, end_line, prompt_text)
	ui.show_indicators(job_id, bufnr, start_line, end_line)

	dwight._active_jobs[job_id] = {
		handle = nil,
		bufnr = bufnr,
		start_line = start_line,
		end_line = end_line,
		mode = mode_name or "custom",
		started = os.time(),
		is_lint = opts.is_lint or false,
		is_macro = opts.is_macro or false,
		is_docs = opts.is_docs or false,
		is_prose = opts.is_prose or false,
		is_plan = opts.is_plan or false,
		is_multi = opts.is_multi or false,
		audit_model = opts.audit_model or nil,
	}

	local backend = cfg.backend or "api"

	-- Store for dot-repeat
	pcall(function()
		require("dwight").store_last_op(prompt_text, mode_name, model_override, think_depth, opts)
	end)

	if backend == "api" then
		run_api(prompt_text, selection, cfg, mode_name, job_id, model_override, think_depth)
	elseif backend == "claude_code" then
		run_claude_code(prompt_text, selection, cfg, mode_name, job_id, model_override)
	elseif backend == "codex" then
		run_codex(prompt_text, selection, cfg, mode_name, job_id)
	elseif backend == "gemini" then
		run_gemini(prompt_text, selection, cfg, mode_name, job_id)
	else
		run_opencode(prompt_text, selection, cfg, mode_name, job_id)
	end

	-- Timeout
	local timer = uv.new_timer()
	local timeout_ms = cfg.timeout * (think_depth or 1) -- scale timeout with depth
	timer:start(timeout_ms, 0, function()
		timer:close()
		local job = dwight._active_jobs[job_id]
		if job then
			if job.handle and not job.handle:is_closing() then
				job.handle:kill("sigterm")
			end
			vim.schedule(function()
				ui.clear_indicators(job_id)
				dwight._active_jobs[job_id] = nil
				log.finish(job_id, "timeout", "", nil, "Timed out")
				vim.notify("[dwight] Job #" .. job_id .. " timed out.", vim.log.levels.ERROR)
			end)
		end
	end)

	-- Parallel job notification
	local active_count = 0
	for _ in pairs(dwight._active_jobs) do
		active_count = active_count + 1
	end
	if active_count > 1 then
		vim.notify(string.format("[dwight] Job #%d started (%d parallel).", job_id, active_count), vim.log.levels.INFO)
	end

	return job_id
end

return M
