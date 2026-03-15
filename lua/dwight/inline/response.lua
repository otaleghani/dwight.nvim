-- dwight/inline/response.lua
-- Handling LLM responses: dispatching to lint/macro/docs/prose modes,
-- applying parsed code to buffers, and peer review integration.

local M = {}

local api = vim.api

local function get_config()
	return require("dwight").config
end

local function get_dwight()
	return require("dwight")
end

--- Apply multi-file changes with quickfix + diff preview.
function M.apply_multi_file(files, job_id)
	local multifile = require("dwight.multifile")
	local parse = require("dwight.inline.parse")
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
					local ok, err = parse._pre_apply_syntax_check(change.content, nil, full_path)
					if not ok then
						vim.notify(
							string.format(
								"[dwight] Job #%d: pre-apply check failed for %s, rejecting multi-file output.",
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
			vim.notify(string.format("[dwight] Job #%d: %d files changed.", job_id or 0, count), vim.log.levels.INFO)
		end, function() -- on_reject
			vim.notify("[dwight] Multi-file changes rejected.", vim.log.levels.INFO)
		end)
		return 0 -- applied async
	else
		local count = multifile.apply_all(files)
		return count
	end
end

function M.handle_response(job_id, raw_output, err_output, exit_code, selection, mode_name, prompt_text)
	local ui = require("dwight.ui")
	local dwight = get_dwight()
	local log = require("dwight.log")
	local parse = require("dwight.inline.parse")
	local jobs = require("dwight.inline.jobs")
	local buffer = require("dwight.inline.buffer")

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
					vim.notify("[dwight] Documentation saved to docs/" .. source_name .. ".md", vim.log.levels.INFO)
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
				buffer._replace_selection_atomic(bufnr, cur_start, cur_end, content)
				jobs.adjust_other_jobs(job_id, bufnr, cur_start, cur_end, #new_lines)
				log.finish(job_id, "success", raw_output, content, nil)
				pcall(function()
					require("dwight.tracker").record(mode_name or "prose", #prompt_text, #raw_output)
				end)
				vim.notify("[dwight] Job #" .. job_id .. " accepted.", vim.log.levels.INFO)
			end, function(reason)
				log.finish(job_id, "rejected", raw_output, content, reason or "rejected")
				vim.notify("[dwight] Job #" .. job_id .. " rejected.", vim.log.levels.INFO)
			end)
		else
			buffer._replace_selection_atomic(bufnr, cur_start, cur_end, content)
			jobs.adjust_other_jobs(job_id, bufnr, cur_start, cur_end, #new_lines)
			log.finish(job_id, "success", raw_output, content, nil)
			pcall(function()
				require("dwight.tracker").record(mode_name or "prose", #prompt_text, #raw_output)
			end)
			vim.notify(
				string.format("[dwight] Job #%d: %s applied.", job_id, mode_name or "prose"),
				vim.log.levels.INFO
			)
		end
		return
	end

	-- Check for multi-file output first
	local multi_files = parse.parse_multi_file_output(raw_output)
	if multi_files then
		local inline = require("dwight.inline")
		local result = inline.apply_multi_file(multi_files, job_id)
		-- result == -1 means pre-apply check failed (already logged as pre_check_fail)
		if result ~= -1 then
			log.finish(job_id, "success", raw_output, "[multi-file: " .. #multi_files .. " changes]", nil)
			pcall(function()
				require("dwight.tracker").record(mode_name or "custom", #prompt_text, #raw_output)
			end)
		end
		return
	end

	local parsed_code = parse.parse_output(raw_output, selection.text, selection.filetype)
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
		vim.notify(string.format("[dwight] Job #%d: running peer review...", job_id), vim.log.levels.INFO)
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
	local parse = require("dwight.inline.parse")
	local jobs = require("dwight.inline.jobs")
	local buffer = require("dwight.inline.buffer")
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

		local check_ok, check_err = parse._pre_apply_syntax_check(full_code, filetype, filepath)
		if not check_ok then
			log.finish(
				job_id,
				"pre_check_fail",
				raw_output,
				parsed_code,
				"Pre-apply check failed: " .. (check_err or "unknown")
			)
			vim.notify(
				string.format("[dwight] Job #%d: pre-apply check failed, rejecting output.", job_id),
				vim.log.levels.WARN
			)
			return
		end
	end

	-- Diff preview: if enabled, show before applying
	local cfg = get_config()
	if cfg.diff_preview then
		require("dwight.diff").show(bufnr, cur_start, cur_end, parsed_code, function() -- on_accept
			buffer._replace_selection_atomic(bufnr, cur_start, cur_end, parsed_code)
			jobs.adjust_other_jobs(job_id, bufnr, cur_start, cur_end, #new_lines)
			log.finish(job_id, "success", raw_output, parsed_code, nil)
			pcall(function()
				require("dwight.tracker").record(mode_name or "custom", #prompt_text, #raw_output)
			end)
			vim.notify("[dwight] Job #" .. job_id .. " accepted.", vim.log.levels.INFO)
		end, function(reason) -- on_reject
			log.finish(job_id, "rejected", raw_output, parsed_code, reason or "rejected")
			vim.notify("[dwight] Job #" .. job_id .. " rejected.", vim.log.levels.INFO)
		end)
		return
	end

	-- Direct apply (no diff preview)
	buffer._replace_selection_atomic(bufnr, cur_start, cur_end, parsed_code)
	jobs.adjust_other_jobs(job_id, bufnr, cur_start, cur_end, #new_lines)

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
	local msg = string.format("[dwight] Job #%d done (lines %d-%d).", job_id, cur_start, cur_end)
	if remaining > 0 then
		msg = msg .. string.format(" %d job(s) still running.", remaining)
	end
	vim.notify(msg, vim.log.levels.INFO)
end

return M
