-- dwight/skills.lua
-- Project-scoped skill management with logged AI generation.

local M = {}

local _flatten = require("dwight.util").flatten_lines

local uv = vim.loop or vim.uv

-- UTF-8 sanitization (shared module)
local sanitize_utf8 = require("dwight.utf8").sanitize

local function skills_dir()
	return require("dwight.project").skills_dir()
end

--------------------------------------------------------------------
-- List / Resolve
--------------------------------------------------------------------

function M.list()
	local dir = skills_dir()
	local skills = {}
	if vim.fn.isdirectory(dir) ~= 1 then
		return skills
	end
	local handle = uv.fs_scandir(dir)
	if not handle then
		return skills
	end
	while true do
		local name, ftype = uv.fs_scandir_next(handle)
		if not name then
			break
		end
		if ftype == "file" and name:match("%.md$") then
			skills[#skills + 1] = { name = name:gsub("%.md$", ""), path = dir .. "/" .. name }
		end
	end
	table.sort(skills, function(a, b)
		return a.name < b.name
	end)
	return skills
end

function M.names()
	local r = {}
	for _, s in ipairs(M.list()) do
		r[#r + 1] = s.name
	end
	return r
end

function M.resolve(name)
	local path = skills_dir() .. "/" .. name .. ".md"
	if vim.fn.filereadable(path) == 1 then
		return path
	end
	return nil
end

function M.read(name)
	local path = M.resolve(name)
	if not path then
		return nil
	end
	local f = io.open(path, "r")
	if not f then
		return nil
	end
	local content = f:read("*a")
	f:close()
	return content
end

function M.resolve_many(names)
	local paths = {}
	for _, name in ipairs(names) do
		local path = M.resolve(name)
		if path then
			paths[#paths + 1] = path
		else
			vim.notify("[dwight] Skill '@" .. name .. "' not found.", vim.log.levels.WARN)
		end
	end
	return paths
end

--------------------------------------------------------------------
-- Picker
--------------------------------------------------------------------

function M.pick()
	local skills = M.list()
	if #skills == 0 then
		vim.notify("[dwight] No skills. Use :DwightGenSkill or :DwightDocs.", vim.log.levels.INFO)
		return
	end
	local has_telescope = pcall(require, "telescope")
	if has_telescope then
		M._pick_telescope(skills)
	else
		M._pick_native(skills)
	end
end

function M._pick_native(skills)
	local items = {}
	for _, s in ipairs(skills) do
		items[#items + 1] = "@" .. s.name
	end
	require("dwight.select").pick(items, { prompt = "Skills:" }, function(choice)
		if choice then
			vim.cmd("edit " .. vim.fn.fnameescape(skills_dir() .. "/" .. choice:sub(2) .. ".md"))
		end
	end)
end

function M._pick_telescope(skills)
	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")
	local previewers = require("telescope.previewers")

	pickers
		.new({}, {
			prompt_title = "🔧 Skills",
			finder = finders.new_table({
				results = skills,
				entry_maker = function(skill)
					return { value = skill, display = "@" .. skill.name, ordinal = skill.name, path = skill.path }
				end,
			}),
			sorter = conf.generic_sorter({}),
			previewer = previewers.new_buffer_previewer({
				define_preview = function(self, entry)
					local ok, lines = pcall(function()
						local f = io.open(entry.value.path, "r")
						if not f then
							return {}
						end
						local c = f:read("*a")
						f:close()
						return vim.split(c, "\n")
					end)
					if ok and lines then
						vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, _flatten(lines))
						vim.bo[self.state.bufnr].filetype = "markdown"
					end
				end,
			}),
			attach_mappings = function(prompt_bufnr)
				actions.select_default:replace(function()
					local entry = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					if entry then
						vim.cmd("edit " .. vim.fn.fnameescape(entry.value.path))
					end
				end)
				return true
			end,
		})
		:find()
end

--------------------------------------------------------------------
-- Generate (AI, logged)
--------------------------------------------------------------------

function M.generate()
	local cfg = require("dwight").config
	local project = require("dwight.project")
	local log = require("dwight.log")

	if not project.is_initialized() then
		vim.notify("[dwight] Run :DwightInit first.", vim.log.levels.WARN)
		return
	end

	vim.ui.input({ prompt = "Skill name (e.g., 'react-hooks'): " }, function(name)
		if not name or name == "" then
			return
		end
		name = name:gsub("[^%w%-_]", "-"):lower()

		vim.ui.input({ prompt = "What should this skill cover? " }, function(desc)
			if not desc or desc == "" then
				return
			end

			vim.ui.input({ prompt = "Specific rules? (optional, Enter to skip): " }, function(patterns)
				patterns = patterns or ""
				local output_path = project.skills_dir() .. "/" .. name .. ".md"

				local prompt = string.format(
					[[
Generate a coding skill guide called "%s".
Description: %s
%s

Practical markdown with:
- Brief overview (2-3 sentences)
- Numbered guidelines (specific, actionable)
- Code pattern examples (good patterns)
- Anti-patterns to avoid (with explanation)
- Style rules

Under 150 lines. Focus on what an AI assistant needs to produce correct code.
Reply with ONLY markdown inside a fenced code block.
]],
					name,
					desc,
					patterns ~= "" and ("Additional: " .. patterns) or ""
				)

				vim.notify("[dwight] Generating skill '@" .. name .. "'…", vim.log.levels.INFO)

				local job_id = log._next_id()
				log.start(job_id, "gen-skill:" .. name, vim.api.nvim_get_current_buf(), 0, 0, prompt)

				M._run_llm(prompt, function(raw, code)
					if code ~= 0 or vim.trim(raw) == "" then
						log.finish(job_id, "error", raw, nil, "Generation failed")
						M._write_template(output_path, name, desc, patterns)
						return
					end

					local blocks = {}
					for block in raw:gmatch("```%w*\n(.-)\n```") do
						blocks[#blocks + 1] = block
					end
					local content
					if #blocks > 0 then
						content = blocks[1]
						for i = 2, #blocks do
							if #blocks[i] > #content then
								content = blocks[i]
							end
						end
					else
						content = raw:gsub("^[^\n]*[Hh]ere.-\n", "")
					end

					local out = io.open(output_path, "w")
					if out then
						out:write(content)
						out:close()
						log.finish(job_id, "success", raw, content, nil)
						vim.notify("✅ [dwight] Skill '@" .. name .. "' created!", vim.log.levels.INFO)
						vim.cmd("edit " .. vim.fn.fnameescape(output_path))
					else
						log.finish(job_id, "error", raw, nil, "Failed to write file")
					end
				end)
			end)
		end)
	end)
end

--- Shared helper: run LLM (api or opencode) and return output.
function M._run_llm(prompt, callback)
	local cfg = require("dwight").config

	if cfg.backend == "claude_code" then
		M._run_claude_code(prompt, callback)
	elseif cfg.backend == "api" then
		M._run_api(prompt, callback)
	else
		M._run_opencode_cli(prompt, callback)
	end
end

function M._run_api(prompt, callback)
	local cfg = require("dwight").config
	local providers = require("dwight.providers")

	local resolved = providers.resolve_model(nil)
	local provider = resolved.provider
	local model_id = resolved.model_id

	if not provider then
		vim.notify("[dwight] No provider configured.", vim.log.levels.ERROR)
		callback("", 1)
		return
	end

	local api_key = providers.get_api_key(provider)
	if not api_key then
		vim.notify(string.format("[dwight] No API key. Set %s.", provider.api_key_env or "?"), vim.log.levels.ERROR)
		callback("", 1)
		return
	end

	local format = provider.format or "openai"
	local max_tokens = cfg.max_tokens or 4096

	-- Track the model being used
	pcall(function()
		require("dwight.tracker").set_model(model_id)
	end)

	-- Sanitize prompt: ensure valid UTF-8 (the API requires it).
	-- sanitize_utf8 handles: surrogates, overlong encodings, truncated
	-- sequences, lone continuation bytes, codepoints above U+10FFFF, nulls.
	local clean_prompt = sanitize_utf8(prompt)

	-- Build payload JSON
	local ok_enc, payload = pcall(function()
		if format == "anthropic" then
			return vim.json.encode({
				model = model_id,
				max_tokens = max_tokens,
				messages = { { role = "user", content = clean_prompt } },
			})
		elseif format == "gemini" then
			return vim.json.encode({ contents = { { parts = { { text = clean_prompt } } } } })
		else
			return vim.json.encode({
				model = model_id,
				max_tokens = max_tokens,
				messages = { { role = "user", content = clean_prompt } },
			})
		end
	end)

	if not ok_enc or not payload then
		local err_msg = "JSON encoding failed: " .. tostring(payload)
		vim.notify("[dwight] " .. err_msg:sub(1, 200), vim.log.levels.ERROR)
		callback("", 1)
		return
	end

	-- Safety net: sanitize the final JSON payload too.
	-- vim.json.encode might emit \uDXXX escape sequences for surrogates;
	-- replace those with the replacement character.
	payload = payload:gsub("\\u[Dd][89ABCDEFabcdef]%x%x", "\\uFFFD")

	-- Verify payload starts with '{'
	if payload:byte(1) ~= 123 then
		payload = payload:gsub("^[^{]*", "")
		if payload == "" or payload:byte(1) ~= 123 then
			vim.notify("[dwight] JSON payload is empty or corrupt", vim.log.levels.ERROR)
			callback("", 1)
			return
		end
	end

	-- Build URL
	local endpoint = provider.endpoint or "/v1/messages"
	if format == "gemini" then
		endpoint = endpoint:gsub("{model}", model_id)
	end
	local url = (provider.base_url or "") .. endpoint

	-- Build curl args — payload will be piped via stdin (@-)
	local curl_args = {
		"-sS",
		"--max-time",
		"120",
		"-X",
		"POST",
		url,
		"-H",
		"Content-Type: application/json; charset=utf-8",
	}
	if provider.auth_header then
		local prefix = provider.auth_prefix or ""
		table.insert(curl_args, "-H")
		table.insert(curl_args, provider.auth_header .. ": " .. prefix .. api_key)
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
	-- Read JSON from stdin — avoids all temp file encoding issues
	table.insert(curl_args, "-d")
	table.insert(curl_args, "@-")

	local stdout_chunks = {}
	local stdout = uv.new_pipe(false)
	local stderr = uv.new_pipe(false)
	local stdin_pipe = uv.new_pipe(false)

	local handle
	handle = uv.spawn("curl", {
		args = curl_args,
		stdio = { stdin_pipe, stdout, stderr },
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
			local raw_json = table.concat(stdout_chunks, "")
			if code ~= 0 then
				vim.notify(
					string.format("[dwight] curl failed (exit %d). Response: %s", code, raw_json:sub(1, 200)),
					vim.log.levels.WARN
				)
				callback("", code)
				return
			end

			local ok, resp = pcall(vim.json.decode, raw_json)
			if not ok then
				vim.notify("[dwight] API returned invalid JSON: " .. raw_json:sub(1, 200), vim.log.levels.ERROR)
				callback("", 1)
				return
			end
			if resp.error then
				local msg = type(resp.error) == "table" and (resp.error.message or vim.inspect(resp.error))
					or tostring(resp.error)

				-- If it's a UTF-8/JSON error, dump diagnostic info
				if msg:lower():match("utf") or msg:lower():match("not valid json") then
					local byte_str = {}
					for i = 1, math.min(40, #payload) do
						byte_str[#byte_str + 1] = string.format("%02x", payload:byte(i))
					end
					vim.notify(
						string.format(
							"[dwight] API error: %s\n  Payload size: %d bytes (sent via stdin)\n  First 40 bytes (hex): %s",
							msg:sub(1, 200),
							#payload,
							table.concat(byte_str, " ")
						),
						vim.log.levels.ERROR
					)
				else
					vim.notify("[dwight] API error: " .. msg:sub(1, 200), vim.log.levels.ERROR)
				end
				callback("", 1)
				return
			end

			-- Extract text based on format
			local parts = {}
			if format == "anthropic" then
				if resp.content then
					for _, block in ipairs(resp.content) do
						if block.type == "text" then
							parts[#parts + 1] = block.text
						end
					end
				end
			elseif format == "gemini" then
				if resp.candidates then
					for _, cand in ipairs(resp.candidates) do
						if cand.content and cand.content.parts then
							for _, part in ipairs(cand.content.parts) do
								if part.text then
									parts[#parts + 1] = part.text
								end
							end
						end
					end
				end
			else -- openai
				if resp.choices then
					for _, choice in ipairs(resp.choices) do
						if choice.message and choice.message.content then
							parts[#parts + 1] = choice.message.content
						end
					end
				end
			end
			callback(table.concat(parts, "\n"), 0)
		end)
	end)

	if not handle then
		if stdin_pipe then
			stdin_pipe:close()
		end
		callback("", 1)
		return
	end

	-- Write JSON payload to curl's stdin, then close to signal EOF.
	-- This is the correct libuv pattern: write → shutdown (EOF) → close.
	stdin_pipe:write(payload, function(write_err)
		if write_err then
			vim.notify("[dwight] stdin write error: " .. tostring(write_err), vim.log.levels.WARN)
			stdin_pipe:close()
			return
		end
		stdin_pipe:shutdown(function()
			stdin_pipe:close()
		end)
	end)

	stdout:read_start(function(err, data)
		if not err and data then
			stdout_chunks[#stdout_chunks + 1] = data
		end
	end)
	stderr:read_start(function() end)
end

--- Run a prompt via Claude Code CLI (`claude`).
--- Uses the user's Pro/Max subscription. No API key needed.
--- Claude Code must be installed and authenticated (`npm i -g @anthropic-ai/claude-code && claude`).
function M._run_claude_code(prompt, callback)
	local cfg = require("dwight").config
	local claude_bin = cfg.claude_code_bin or "claude"

	-- -p = print mode: single prompt → single response → exit
	-- Do NOT add --max-turns — it conflicts with -p and causes "Reached max turns" errors
	local args = {
		"-p",
		prompt,
		"--output-format",
		"text",
	}

	-- If a model is configured, pass it
	local model = cfg.claude_code_model
	if model then
		table.insert(args, "--model")
		table.insert(args, model)
	end

	-- Set max output tokens via environment variable (not a CLI flag)
	-- Build full env by inheriting current process env and adding our var
	local max_tokens = cfg.max_tokens or 16384
	local spawn_env = nil -- nil = inherit parent env (default)
	pcall(function()
		local current_env = vim.fn.environ()
		local env_list = {}
		for k, v in pairs(current_env) do
			env_list[#env_list + 1] = k .. "=" .. v
		end
		env_list[#env_list + 1] = "CLAUDE_CODE_MAX_OUTPUT_TOKENS=" .. tostring(max_tokens)
		spawn_env = env_list
	end)

	local stdout_chunks = {}
	local stderr_chunks = {}
	local stdout = uv.new_pipe(false)
	local stderr = uv.new_pipe(false)

	-- Track model
	pcall(function()
		require("dwight.tracker").set_model(model or "claude-code")
	end)

	local handle
	local spawn_opts = {
		args = args,
		stdio = { nil, stdout, stderr },
		cwd = vim.fn.getcwd(),
	}
	if spawn_env then
		spawn_opts.env = spawn_env
	end

	handle = uv.spawn(claude_bin, spawn_opts, function(code)
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
			local output = table.concat(stdout_chunks, "")
			local err_output = table.concat(stderr_chunks, "")

			if code ~= 0 then
				if err_output:match("not found") or err_output:match("command not found") then
					vim.notify(
						"[dwight] Claude Code not found. Install: npm i -g @anthropic-ai/claude-code",
						vim.log.levels.ERROR
					)
				elseif err_output:match("auth") or err_output:match("login") then
					vim.notify(
						"[dwight] Claude Code not authenticated. Run 'claude' in terminal to log in.",
						vim.log.levels.ERROR
					)
				else
					vim.notify("[dwight] Claude Code error: " .. err_output:sub(1, 200), vim.log.levels.ERROR)
				end
				callback("", code)
				return
			end

			callback(output, 0)
		end)
	end)

	if not handle then
		vim.notify(
			"[dwight] Failed to spawn claude. Is it installed? npm i -g @anthropic-ai/claude-code",
			vim.log.levels.ERROR
		)
		callback("", 1)
		return
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

function M._run_opencode_cli(prompt, callback)
	local cfg = require("dwight").config

	local tmpfile = vim.fn.tempname() .. "_dwight_prompt.md"
	local f = io.open(tmpfile, "w")
	if not f then
		callback("", 1)
		return
	end
	f:write(prompt)
	f:close()

	local wrapper = vim.fn.tempname() .. "_dwight_run.sh"
	local wf = io.open(wrapper, "w")
	if not wf then
		os.remove(tmpfile)
		callback("", 1)
		return
	end
	wf:write("#!/bin/sh\n")
	wf:write(string.format('%s run "$(cat %s)"\n', cfg.opencode_bin, tmpfile))
	wf:close()
	os.execute("chmod +x " .. vim.fn.shellescape(wrapper))

	local stdout_chunks = {}
	local stdout = uv.new_pipe(false)
	local stderr = uv.new_pipe(false)

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
		pcall(os.remove, tmpfile)
		pcall(os.remove, wrapper)
		vim.schedule(function()
			callback(table.concat(stdout_chunks, ""), code)
		end)
	end)

	if not handle then
		pcall(os.remove, tmpfile)
		pcall(os.remove, wrapper)
		callback("", 1)
		return
	end

	stdout:read_start(function(err, data)
		if not err and data then
			stdout_chunks[#stdout_chunks + 1] = data
		end
	end)
	stderr:read_start(function() end)
end

function M._write_template(path, name, desc, patterns)
	local title = name:gsub("-", " "):gsub("(%a)([%w_']*)", function(a, b)
		return a:upper() .. b
	end)
	local f = io.open(path, "w")
	if f then
		f:write(
			string.format(
				"# %s\n\n## Overview\n%s\n\n## Guidelines\n1. \n\n## Patterns\n```\n```\n\n## Anti-Patterns\n```\n```\n%s\n",
				title,
				desc,
				patterns ~= "" and ("\n## Notes\n" .. patterns) or ""
			)
		)
		f:close()
		vim.notify("[dwight] Template '@" .. name .. "' created.", vim.log.levels.INFO)
		vim.cmd("edit " .. vim.fn.fnameescape(path))
	end
end

return M
