-- dwight/inline.lua (formerly opencode.lua)
-- Inline code generation engine: prompt → parse → apply to buffer.
-- Multi-provider API backend for interactive editing.
-- Think depth: ^1 normal, ^2 CoT prefix (in prompt.lua), ^3+ multi-pass here.

local M = {}

local api = vim.api
local uv = vim.loop or vim.uv

local function get_config()
	return require("dwight").config
end
local function get_dwight()
	return require("dwight")
end

--------------------------------------------------------------------
-- Output Parsing (STRICT — fenced code blocks only)
--------------------------------------------------------------------

local function extract_code_block(raw)
	local blocks = {}
	for block in raw:gmatch("```[%w_]*%s*\n(.-)\n%s*```") do
		blocks[#blocks + 1] = block
	end
	if #blocks == 0 then
		for block in raw:gmatch("```[%w_]*%s*\n(.-)```") do
			blocks[#blocks + 1] = block
		end
	end
	if #blocks == 0 then
		return nil
	end
	local best = blocks[1]
	for i = 2, #blocks do
		if #blocks[i] > #best then
			best = blocks[i]
		end
	end
	return best
end

local function looks_like_monologue(text)
	local lines = vim.split(text, "\n", { plain = true })
	if #lines == 0 then
		return true
	end
	local signals, total = 0, 0
	for _, line in ipairs(lines) do
		local t = vim.trim(line)
		if t ~= "" then
			total = total + 1
			if
				t:match("^I['']ll ")
				or t:match("^I['']m ")
				or t:match("^I will ")
				or t:match("^Let me ")
				or t:match("^Now let")
				or t:match("^Here is")
				or t:match("^Here's")
				or t:match("^This code")
				or t:match("^The code")
				or t:match("^I need to")
				or t:match("^First,")
				or t:match("^Note:")
				or t:match("^Looking at")
				or t:match("^Based on")
				or t:match("^To implement")
				or t:match("^The changes")
				or t:match("^Key changes")
				or t:match("^Summary")
				or t:match("^I've ")
				or t:match("^I have ")
				or t:match("^Now,")
				or t:match("^%d+%.%s+[A-Z]")
			then
				signals = signals + 1
			end
		end
	end
	if total == 0 then
		return true
	end
	return (signals / total) > 0.4
end

local function parse_output(raw, original_text, _language)
	if not raw or raw == "" then
		return nil
	end

	-- Primary: extract from fenced code block
	local code = extract_code_block(raw)

	-- Fallback: if no fence found, check if the raw output IS code (not a monologue).
	-- This catches LLMs that return code without fences, common with short outputs.
	if not code then
		local trimmed = vim.trim(raw)
		if not looks_like_monologue(trimmed) and trimmed ~= "" then
			-- Strip any leading "Here is..." single line and trailing explanation
			local stripped = trimmed:gsub("^[^\n]-[Hh]ere.-:\n", ""):gsub("\n[^\n]-[Hh]ope.-$", "")
			stripped = vim.trim(stripped)
			if not looks_like_monologue(stripped) and stripped ~= "" then
				code = stripped
			end
		end
	end

	if not code then
		return nil
	end
	if looks_like_monologue(code) then
		return nil
	end
	code = code:gsub("^\n+", ""):gsub("\n+$", "")

	-- Sanity check: if original was substantial but result is tiny, probably a bad parse
	local orig_lines = #vim.split(original_text, "\n", { plain = true })
	local new_lines = #vim.split(code, "\n", { plain = true })
	if orig_lines > 5 and new_lines < orig_lines * 0.15 then
		return nil
	end

	return code
end

--------------------------------------------------------------------
-- Multi-file output: ```lang:path blocks
--------------------------------------------------------------------

--- Pre-apply syntax check: validate code compiles before writing to disk.
--- Returns (ok, error_msg). Only checks languages with fast checkers.
--- This prevents broken code from reaching disk during agent execution.
function M._pre_apply_syntax_check(code, filetype, filepath)
	if not code or code == "" then
		return true, nil
	end
	return require("dwight.languages").syntax_check(code, filetype, filepath)
end

--- Parse multi-file output: fenced blocks tagged with filepath.
--- Format: ```typescript:src/auth.ts\n...\n```
--- Returns nil if no multi-file blocks found, otherwise { {path, code, lang}, ... }
local function parse_multi_file_output(raw)
	return require("dwight.multifile").parse(raw)
end

--- Apply multi-file changes with quickfix + diff preview.
function M.apply_multi_file(files, job_id)
	local multifile = require("dwight.multifile")
	local cfg = get_config()

	-- Build gate: pre-apply syntax check for multi-file changes (agent mode).
	-- Check each file's content before applying any changes. If any check fails,
	-- reject ALL changes to keep the codebase consistent.
	if not cfg.diff_preview and cfg.pre_apply_check ~= false then
		for _, change in ipairs(files) do
			if change.content and change.path and change.action ~= "delete" then
				-- Only check full-file creates/edits (not line-range edits — those are partial)
				if not change.start_line then
					local full_path = change.path:match("^/") and change.path or (vim.fn.getcwd() .. "/" .. change.path)
					local ok, err = M._pre_apply_syntax_check(change.content, nil, full_path)
					if not ok then
						vim.notify(
							string.format(
								"[dwight] ⚠️ Job #%d: pre-apply check failed for %s, rejecting multi-file output.",
								job_id or 0,
								change.path
							),
							vim.log.levels.WARN
						)
						local log = require("dwight.log")
						log.finish(
							job_id,
							"pre_check_fail",
							"",
							nil,
							"Multi-file pre-check failed for " .. change.path .. ": " .. (err or "")
						)
						return -1 -- signal pre-check failure to caller
					end
				end
			end
		end
	end

	if cfg.diff_preview then
		multifile.preview(files, function() -- on_accept
			local count = multifile.apply_all(files)
			vim.notify(
				string.format("[dwight] ✅ Job #%d: %d files changed.", job_id or 0, count),
				vim.log.levels.INFO
			)
		end, function() -- on_reject
			vim.notify("[dwight] ❌ Multi-file changes rejected.", vim.log.levels.INFO)
		end)
		return 0 -- applied async
	else
		local count = multifile.apply_all(files)
		return count
	end
end

--------------------------------------------------------------------
-- Job ID / Overlap / Adjust
--------------------------------------------------------------------

local function new_job_id()
	return require("dwight.log")._next_id()
end

local function has_overlap(bufnr, start_line, end_line)
	for _, job in pairs(get_dwight()._active_jobs) do
		if job.bufnr == bufnr and start_line <= job.end_line and end_line >= job.start_line then
			return true
		end
	end
	return false
end

local function adjust_other_jobs(exclude_id, bufnr, start_line, old_end, new_count)
	local delta = new_count - (old_end - start_line + 1)
	if delta == 0 then
		return
	end
	local ui = require("dwight.ui")
	for id, job in pairs(get_dwight()._active_jobs) do
		if id ~= exclude_id and job.bufnr == bufnr and job.start_line > old_end then
			job.start_line = job.start_line + delta
			job.end_line = job.end_line + delta
			ui.update_indicator_range(id, job.start_line, job.end_line)
		end
	end
end

--------------------------------------------------------------------
-- Shared response handler
--------------------------------------------------------------------

local function handle_response(job_id, raw_output, err_output, exit_code, selection, mode_name, prompt_text)
	local ui = require("dwight.ui")
	local dwight = get_dwight()
	local log = require("dwight.log")

	local bufnr = selection.bufnr
	local job = dwight._active_jobs[job_id]
	local cur_start = job and job.start_line or selection.start_line
	local cur_end = job and job.end_line or selection.end_line

	ui.clear_indicators(job_id)
	dwight._active_jobs[job_id] = nil

	if exit_code ~= 0 then
		log.finish(job_id, "error", raw_output, nil, string.format("Exit %d: %s", exit_code, err_output))
		vim.notify("[dwight] Job #" .. job_id .. " failed: " .. err_output, vim.log.levels.ERROR)
		return
	end

	if raw_output == "" then
		log.finish(job_id, "error", "", nil, "Empty output")
		vim.notify("[dwight] Job #" .. job_id .. ": empty output.", vim.log.levels.WARN)
		return
	end

	-- Lint mode: parse diagnostics instead of replacing code
	if job and job.is_lint then
		local handled = pcall(function()
			local lint = require("dwight.lint")
			if lint.handle_lint_response(raw_output, selection) then
				log.finish(job_id, "success", raw_output, "[lint diagnostics]", nil)
				pcall(function()
					require("dwight.tracker").record(mode_name or "lint", #prompt_text, #raw_output)
				end)
				return true
			end
		end)
		if handled then
			return
		end
	end

	-- Macro mode: show commands in preview + store in register
	if job and job.is_macro then
		local handled = pcall(function()
			local macro = require("dwight.macro")
			if macro.handle_macro_response(raw_output, selection) then
				log.finish(job_id, "success", raw_output, "[macro commands]", nil)
				pcall(function()
					require("dwight.tracker").record(mode_name or "macro", #prompt_text, #raw_output)
				end)
				return true
			end
		end)
		if handled then
			return
		end
	end

	-- Docs mode: save output as markdown file instead of replacing code
	if job and job.is_docs then
		pcall(function()
			-- Extract markdown from fences
			local content = raw_output:match("```%w*%s*\n(.-)```")
				or raw_output:match("~~~%w*%s*\n(.-)~~~")
				or raw_output
			content = vim.trim(content)
			if content ~= "" then
				-- Save to docs/ with a name based on the file being documented
				local source_name = vim.fn.fnamemodify(selection.filepath or "", ":t:r") or "doc"
				local docs_dir = vim.fn.getcwd() .. "/docs"
				vim.fn.mkdir(docs_dir, "p")
				local path = docs_dir .. "/" .. source_name .. ".md"
				local f = io.open(path, "w")
				if f then
					f:write(content)
					f:close()
					log.finish(job_id, "success", raw_output, "[docs: " .. path .. "]", nil)
					vim.notify(
						"[dwight] 📄 Documentation saved to docs/" .. source_name .. ".md",
						vim.log.levels.INFO
					)
					vim.cmd("edit " .. vim.fn.fnameescape(path))
				end
			end
		end)
		pcall(function()
			require("dwight.tracker").record(mode_name or "docs", #prompt_text, #raw_output)
		end)
		return
	end

	-- Prose modes (brainstorm, refine, plan): raw markdown replaces selection
	if job and (job.is_prose or job.is_plan) then
		-- Strip fences if the LLM wrapped it anyway
		local content = raw_output:gsub("^```%w*%s*\n", ""):gsub("\n```%s*$", "")
		content = content:gsub("^~~~%w*%s*\n", ""):gsub("\n~~~%s*$", "")
		content = vim.trim(content)

		if content == "" then
			log.finish(job_id, "error", raw_output, nil, "Empty output")
			vim.notify("[dwight] Job #" .. job_id .. ": empty output.", vim.log.levels.WARN)
			return
		end

		local new_lines = vim.split(content, "\n", { plain = true })

		if get_config().diff_preview then
			require("dwight.diff").show(bufnr, cur_start, cur_end, content, function()
				M._replace_selection_atomic(bufnr, cur_start, cur_end, content)
				adjust_other_jobs(job_id, bufnr, cur_start, cur_end, #new_lines)
				log.finish(job_id, "success", raw_output, content, nil)
				pcall(function()
					require("dwight.tracker").record(mode_name or "prose", #prompt_text, #raw_output)
				end)
				vim.notify("[dwight] ✅ Job #" .. job_id .. " accepted.", vim.log.levels.INFO)
			end, function(reason)
				log.finish(job_id, "rejected", raw_output, content, reason or "rejected")
				vim.notify("[dwight] ❌ Job #" .. job_id .. " rejected.", vim.log.levels.INFO)
			end)
		else
			M._replace_selection_atomic(bufnr, cur_start, cur_end, content)
			adjust_other_jobs(job_id, bufnr, cur_start, cur_end, #new_lines)
			log.finish(job_id, "success", raw_output, content, nil)
			pcall(function()
				require("dwight.tracker").record(mode_name or "prose", #prompt_text, #raw_output)
			end)
			vim.notify(
				string.format("[dwight] ✅ Job #%d: %s applied.", job_id, mode_name or "prose"),
				vim.log.levels.INFO
			)
		end
		return
	end

	-- Check for multi-file output first
	local multi_files = parse_multi_file_output(raw_output)
	if multi_files then
		local result = M.apply_multi_file(multi_files, job_id)
		-- result == -1 means pre-apply check failed (already logged as pre_check_fail)
		if result ~= -1 then
			log.finish(job_id, "success", raw_output, "[multi-file: " .. #multi_files .. " changes]", nil)
			pcall(function()
				require("dwight.tracker").record(mode_name or "custom", #prompt_text, #raw_output)
			end)
		end
		return
	end

	local parsed_code = parse_output(raw_output, selection.text, selection.filetype)
	if not parsed_code then
		log.finish(job_id, "parse_fail", raw_output, nil, "No valid code block / monologue")
		vim.notify("[dwight] Job #" .. job_id .. ": no valid code block. Check :DwightLog.", vim.log.levels.WARN)
		return
	end

	if vim.trim(selection.text):gsub("%s+", " ") == vim.trim(parsed_code):gsub("%s+", " ") then
		log.finish(job_id, "no_change", raw_output, parsed_code, nil)
		vim.notify("[dwight] Job #" .. job_id .. ": no changes.", vim.log.levels.INFO)
		return
	end

	local new_lines = vim.split(parsed_code, "\n", { plain = true })

	-- Peer review (~audit): pass through second model before applying
	if job and job.audit_model then
		vim.notify(string.format("[dwight] Job #%d: running peer review…", job_id), vim.log.levels.INFO)
		local audit_model_name = job.audit_model
		if audit_model_name == true then
			audit_model_name = nil
		end -- use alternate model

		pcall(function()
			require("dwight.review").review(
				selection.text,
				parsed_code,
				selection.filetype or "code",
				prompt_text,
				audit_model_name,
				function(reviewed_code, err)
					if err then
						vim.notify("[dwight] Audit failed: " .. err .. ". Applying unreviewed.", vim.log.levels.WARN)
					elseif reviewed_code then
						parsed_code = reviewed_code
						new_lines = vim.split(parsed_code, "\n", { plain = true })
						vim.notify("[dwight] Job #" .. job_id .. ": peer review comments added.", vim.log.levels.INFO)
					end
					-- Continue with normal apply flow
					M._apply_parsed(
						job_id,
						bufnr,
						cur_start,
						cur_end,
						parsed_code,
						new_lines,
						raw_output,
						selection,
						mode_name,
						prompt_text
					)
				end
			)
		end)
		return -- _apply_parsed will be called from the audit callback
	end

	-- Normal apply flow
	M._apply_parsed(
		job_id,
		bufnr,
		cur_start,
		cur_end,
		parsed_code,
		new_lines,
		raw_output,
		selection,
		mode_name,
		prompt_text
	)
end

--- Apply parsed code to buffer (extracted for audit callback reuse).
function M._apply_parsed(
	job_id,
	bufnr,
	cur_start,
	cur_end,
	parsed_code,
	new_lines,
	raw_output,
	selection,
	mode_name,
	prompt_text
)
	local log = require("dwight.log")
	local cfg = get_config()

	-- Build gate: pre-apply syntax check (when diff_preview is disabled = agent mode).
	-- Validates code compiles BEFORE writing to disk. If check fails, the file stays
	-- clean and the retry loop works against uncorrupted code.
	if not cfg.diff_preview and cfg.pre_apply_check ~= false then
		local filepath = selection.filepath or api.nvim_buf_get_name(bufnr)
		local filetype = selection.filetype or vim.bo[bufnr].filetype or ""

		-- Reconstruct the full file with the replacement applied.
		-- Checking just the snippet would fail (e.g. a Go statement is not a valid file).
		local full_code = parsed_code
		if cur_start and cur_end and api.nvim_buf_is_valid(bufnr) then
			local buf_lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
			local before = {}
			for i = 1, cur_start - 1 do
				before[#before + 1] = buf_lines[i]
			end
			local after = {}
			for i = cur_end + 1, #buf_lines do
				after[#after + 1] = buf_lines[i]
			end
			full_code = table.concat(before, "\n")
				.. (cur_start > 1 and "\n" or "")
				.. parsed_code
				.. (#after > 0 and "\n" or "")
				.. table.concat(after, "\n")
		end

		local check_ok, check_err = M._pre_apply_syntax_check(full_code, filetype, filepath)
		if not check_ok then
			log.finish(
				job_id,
				"pre_check_fail",
				raw_output,
				parsed_code,
				"Pre-apply check failed: " .. (check_err or "unknown")
			)
			vim.notify(
				string.format("[dwight] ⚠️ Job #%d: pre-apply check failed, rejecting output.", job_id),
				vim.log.levels.WARN
			)
			return
		end
	end

	-- Diff preview: if enabled, show before applying
	local cfg = get_config()
	if cfg.diff_preview then
		require("dwight.diff").show(bufnr, cur_start, cur_end, parsed_code, function() -- on_accept
			M._replace_selection_atomic(bufnr, cur_start, cur_end, parsed_code)
			adjust_other_jobs(job_id, bufnr, cur_start, cur_end, #new_lines)
			log.finish(job_id, "success", raw_output, parsed_code, nil)
			pcall(function()
				require("dwight.tracker").record(mode_name or "custom", #prompt_text, #raw_output)
			end)
			vim.notify("[dwight] ✅ Job #" .. job_id .. " accepted.", vim.log.levels.INFO)
		end, function(reason) -- on_reject
			log.finish(job_id, "rejected", raw_output, parsed_code, reason or "rejected")
			vim.notify("[dwight] ❌ Job #" .. job_id .. " rejected.", vim.log.levels.INFO)
		end)
		return
	end

	-- Direct apply (no diff preview)
	M._replace_selection_atomic(bufnr, cur_start, cur_end, parsed_code)
	adjust_other_jobs(job_id, bufnr, cur_start, cur_end, #new_lines)

	log.finish(job_id, "success", raw_output, parsed_code, nil)
	pcall(function()
		require("dwight.tracker").record(mode_name or "custom", #prompt_text, #raw_output)
	end)

	local remaining = 0
	for _, j in pairs(get_dwight()._active_jobs) do
		if j.bufnr == bufnr then
			remaining = remaining + 1
		end
	end
	local msg = string.format("[dwight] ✅ Job #%d done (lines %d-%d).", job_id, cur_start, cur_end)
	if remaining > 0 then
		msg = msg .. string.format(" %d job(s) still running.", remaining)
	end
	vim.notify(msg, vim.log.levels.INFO)
end

--------------------------------------------------------------------
-- Payload builders / Response extractors
--------------------------------------------------------------------

local function build_payload(format, prompt_text, model_id, max_tokens, stream)
	if format == "anthropic" then
		local body =
			{ model = model_id, max_tokens = max_tokens, messages = { { role = "user", content = prompt_text } } }
		if stream then
			body.stream = true
		end
		return vim.json.encode(body)
	elseif format == "gemini" then
		return vim.json.encode({ contents = { { parts = { { text = prompt_text } } } } })
	else
		local body =
			{ model = model_id, max_tokens = max_tokens, messages = { { role = "user", content = prompt_text } } }
		if stream then
			body.stream = true
		end
		return vim.json.encode(body)
	end
end

--------------------------------------------------------------------
-- SSE (Server-Sent Events) parser for streaming
--------------------------------------------------------------------

local function parse_sse_chunk(format, line)
	if not line or line == "" or line:match("^:") then
		return nil
	end
	local data = line:match("^data: (.+)$")
	if not data then
		return nil
	end
	if data == "[DONE]" then
		return nil
	end

	local ok, event = pcall(vim.json.decode, data)
	if not ok then
		return nil
	end

	if format == "anthropic" then
		if event.type == "content_block_delta" and event.delta and event.delta.text then
			return event.delta.text
		end
	else
		-- OpenAI-compatible
		if event.choices and event.choices[1] then
			local delta = event.choices[1].delta
			if delta and delta.content then
				return delta.content
			end
		end
	end
	return nil
end

local function extract_text(format, resp)
	local parts = {}
	if format == "anthropic" then
		if resp.content then
			for _, b in ipairs(resp.content) do
				if b.type == "text" then
					parts[#parts + 1] = b.text
				end
			end
		end
		if resp.usage then
			parts[#parts + 1] = string.format(
				"\n\n<!-- tokens: %d in, %d out -->",
				resp.usage.input_tokens or 0,
				resp.usage.output_tokens or 0
			)
		end
	elseif format == "gemini" then
		if resp.candidates then
			for _, c in ipairs(resp.candidates) do
				if c.content and c.content.parts then
					for _, p in ipairs(c.content.parts) do
						if p.text then
							parts[#parts + 1] = p.text
						end
					end
				end
			end
		end
	else
		if resp.choices then
			for _, c in ipairs(resp.choices) do
				if c.message and c.message.content then
					parts[#parts + 1] = c.message.content
				end
			end
		end
		if resp.usage then
			parts[#parts + 1] = string.format(
				"\n\n<!-- tokens: %d in, %d out -->",
				resp.usage.prompt_tokens or 0,
				resp.usage.completion_tokens or 0
			)
		end
	end
	return table.concat(parts, "\n")
end

--------------------------------------------------------------------
-- Single API call (used by run_api and multi-pass)
--------------------------------------------------------------------

local function api_call(prompt_text, model_override, cfg, callback, opts)
	opts = opts or {}
	local providers = require("dwight.providers")
	local resolved = providers.resolve_model(model_override)
	local provider = resolved.provider
	local model_id = resolved.model_id

	if not provider then
		callback(nil, "No provider configured")
		return
	end

	local api_key = providers.get_api_key(provider)
	if not api_key then
		callback(nil, "No API key for " .. resolved.provider_name)
		return
	end

	local format = provider.format or "openai"
	local max_tokens = cfg.max_tokens or 4096
	local streaming = cfg.streaming and format ~= "gemini" -- Gemini doesn't use SSE
	local payload = build_payload(format, prompt_text, model_id, max_tokens, streaming)

	-- Track the model being used
	pcall(function()
		require("dwight.tracker").set_model(model_id)
	end)

	local payload_file = vim.fn.tempname() .. "_dwight_payload.json"
	local f = io.open(payload_file, "w")
	if not f then
		callback(nil, "Failed to write payload")
		return
	end
	f:write(payload)
	f:close()

	-- Build URL
	local endpoint = provider.endpoint or "/v1/messages"
	if format == "gemini" then
		endpoint = endpoint:gsub("{model}", model_id)
	end
	local url = (provider.base_url or "") .. endpoint

	-- curl args
	local curl_args = {
		"-sS",
		"--max-time",
		tostring(math.floor(cfg.timeout / 1000)),
		"-X",
		"POST",
		url,
		"-H",
		"Content-Type: application/json",
	}
	if streaming then
		table.insert(curl_args, "--no-buffer")
	end
	if provider.auth_header then
		table.insert(curl_args, "-H")
		table.insert(curl_args, provider.auth_header .. ": " .. (provider.auth_prefix or "") .. api_key)
	end
	if provider.auth_query then
		curl_args[6] = url .. "?key=" .. api_key
	end
	if provider.headers then
		for k, v in pairs(provider.headers) do
			table.insert(curl_args, "-H")
			table.insert(curl_args, k .. ": " .. v)
		end
	end
	table.insert(curl_args, "-d")
	table.insert(curl_args, "@" .. payload_file)

	local stdout_chunks = {}
	local stderr_chunks = {}
	local stream_text = {} -- accumulated text from SSE events
	local stream_chars = 0 -- progress counter
	local stdout = uv.new_pipe(false)
	local stderr = uv.new_pipe(false)

	local handle
	handle = uv.spawn("curl", {
		args = curl_args,
		stdio = { nil, stdout, stderr },
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
		pcall(os.remove, payload_file)

		vim.schedule(function()
			local err_output = table.concat(stderr_chunks, "")

			if code ~= 0 then
				callback(nil, "curl failed: " .. err_output)
				return
			end

			if streaming and #stream_text > 0 then
				-- Already parsed via SSE — return accumulated text
				callback(table.concat(stream_text, ""), nil)
				return
			end

			-- Non-streaming: parse full JSON response
			local raw_json = table.concat(stdout_chunks, "")
			local ok, resp = pcall(vim.json.decode, raw_json)
			if not ok then
				callback(nil, "Invalid JSON")
				return
			end
			if resp.error then
				local msg = type(resp.error) == "table" and (resp.error.message or vim.inspect(resp.error))
					or tostring(resp.error)
				callback(nil, msg)
				return
			end

			callback(extract_text(format, resp), nil)
		end)
	end)

	if not handle then
		pcall(os.remove, payload_file)
		callback(nil, "Failed to spawn curl")
		return
	end

	if streaming then
		-- Parse SSE events as they arrive, show progress
		local sse_buffer = ""
		stdout:read_start(function(err, data)
			if err or not data then
				return
			end
			stdout_chunks[#stdout_chunks + 1] = data
			sse_buffer = sse_buffer .. data

			-- Process complete SSE lines
			while true do
				local nl = sse_buffer:find("\n")
				if not nl then
					break
				end
				local line = sse_buffer:sub(1, nl - 1):gsub("\r$", "")
				sse_buffer = sse_buffer:sub(nl + 1)

				local text = parse_sse_chunk(format, line)
				if text then
					stream_text[#stream_text + 1] = text
					stream_chars = stream_chars + #text
					-- Show progress (throttled to every ~200 chars)
					if stream_chars % 200 < #text and opts.on_progress then
						vim.schedule(function()
							opts.on_progress(stream_chars)
						end)
					end
				end
			end
		end)
	else
		stdout:read_start(function(err, data)
			if not err and data then
				stdout_chunks[#stdout_chunks + 1] = data
			end
		end)
	end
	stderr:read_start(function(err, data)
		if not err and data then
			stderr_chunks[#stderr_chunks + 1] = data
		end
	end)

	return handle -- for cancellation
end

--------------------------------------------------------------------
-- Backend: API (single or multi-pass)
--------------------------------------------------------------------

local function run_api(prompt_text, selection, cfg, mode_name, job_id, model_override, think_depth)
	local dwight = get_dwight()
	local ui = require("dwight.ui")
	local log = require("dwight.log")
	local prompt_mod = require("dwight.prompt")

	think_depth = think_depth or 1

	-- ^1 or ^2: single request (^2 has CoT prefix baked into prompt by prompt.lua)
	if think_depth <= 2 then
		local handle = api_call(prompt_text, model_override, cfg, function(text, err)
			if err then
				handle_response(job_id, "", err, 1, selection, mode_name, prompt_text)
			else
				handle_response(job_id, text, "", 0, selection, mode_name, prompt_text)
			end
		end, {
			on_progress = function(chars)
				-- Update indicator with streaming progress
				pcall(function()
					local job = dwight._active_jobs[job_id]
					if job then
						ui.update_indicator_label(job_id, string.format("⚡ %d chars", chars))
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
	local depth_label = think_depth == 3 and "^3 (analyze → code)" or "^4 (analyze → plan → code)"
	vim.notify(string.format("[dwight] Job #%d: %s — pass 1 (analysis)…", job_id, depth_label), vim.log.levels.INFO)

	api_call(analysis_prompt, model_override, cfg, function(analysis, err1)
		if err1 then
			handle_response(job_id, "", "Analysis pass failed: " .. err1, 1, selection, mode_name, prompt_text)
			return
		end

		log.append_note(job_id, "Pass 1 (analysis):\n" .. (analysis or ""))

		local function do_final_pass(context_text)
			-- Final pass: code generation with analysis/plan context
			local final_prompt = prompt_mod.build_with_analysis(prompt_text, context_text)

			vim.notify(string.format("[dwight] Job #%d: final pass (code)…", job_id), vim.log.levels.INFO)

			local handle = api_call(final_prompt, model_override, cfg, function(text, err)
				if err then
					handle_response(job_id, "", "Code pass failed: " .. err, 1, selection, mode_name, prompt_text)
				else
					handle_response(job_id, text, "", 0, selection, mode_name, prompt_text)
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

			vim.notify(string.format("[dwight] Job #%d: pass 2 (planning)…", job_id), vim.log.levels.INFO)

			api_call(plan_prompt, model_override, cfg, function(plan, err2)
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

local function run_opencode(prompt_text, selection, cfg, mode_name, job_id)
	local dwight = get_dwight()
	local ui = require("dwight.ui")
	local log = require("dwight.log")

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
			handle_response(
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
			handle_response(
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

	local bufnr = selection.bufnr
	local start_line = selection.start_line
	local end_line = selection.end_line

	if has_overlap(bufnr, start_line, end_line) then
		vim.notify("[dwight] This selection overlaps with a running job.", vim.log.levels.WARN)
		return
	end

	local job_id = new_job_id()
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

--------------------------------------------------------------------
-- Atomic Buffer Replacement
--------------------------------------------------------------------

function M._replace_selection_atomic(bufnr, start_line, end_line, new_text)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	local new_lines = vim.split(new_text, "\n", { plain = true })

	-- Ensure buffer is modifiable
	local was_modifiable = vim.bo[bufnr].modifiable
	if not was_modifiable then
		vim.bo[bufnr].modifiable = true
	end

	local eventignore = vim.o.eventignore
	vim.o.eventignore = "all"

	local current_line_count = vim.api.nvim_buf_line_count(bufnr)
	if end_line > current_line_count then
		end_line = current_line_count
	end

	if vim.api.nvim_get_current_buf() == bufnr then
		pcall(vim.cmd, "undojoin")
	end
	vim.api.nvim_buf_set_lines(bufnr, start_line - 1, end_line, false, new_lines)
	vim.o.eventignore = eventignore

	-- Restore modifiable state if we changed it
	if not was_modifiable then
		vim.bo[bufnr].modifiable = was_modifiable
	end

	local ns = vim.api.nvim_create_namespace("dwight_replace_" .. start_line .. "_" .. os.time())
	local new_end = start_line - 1 + #new_lines
	for i = start_line - 1, math.min(new_end - 1, vim.api.nvim_buf_line_count(bufnr) - 1) do
		pcall(vim.api.nvim_buf_add_highlight, bufnr, ns, "DwightReplace", i, 0, -1)
	end
	vim.defer_fn(function()
		if vim.api.nvim_buf_is_valid(bufnr) then
			vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
		end
	end, 3000)
end

return M
