-- dwight/bootstrap/generate.lua
-- Generate pragma suggestions via LLM (single-shot quick mode).

local M = {}

local api = vim.api

local BOOTSTRAP_PROMPT = [=[
You are analyzing a project to add dwight pragma comments for AI-assisted development.

Project structure:
%s

Entry/config files found: %s

Entry file previews:
%s

Suggest pragma comments to add to this project. For each suggestion, output in this EXACT format:

<changes>
<file path="src/index.ts" action="edit" lines="1-1">
// REST API for task management with real-time updates. @project
// TypeScript, Express, PostgreSQL, Redis. @stack
// Must handle 10k concurrent users. GDPR compliant. @constraint
// Use dependency injection. All errors typed. No any. @convention
(original line 1 content here)
</file>
<file path="src/auth/index.ts" action="edit" lines="1-1">
// JWT-based authentication and session management. @feature:auth
(original line 1 content here)
</file>
</changes>

RULES:
- Add @project, @stack, @constraint, @convention pragmas to the MAIN entry point only.
- Add @feature:name pragmas to EACH distinct module/feature directory.
- Feature names should be short, lowercase, kebab-case (e.g. auth, payments, user-mgmt).
- Each pragma comment goes ABOVE the first line of the file.
- For "edit" actions, set lines="1-1" and include the pragma comment(s) PLUS the original first line.
- Use the comment style appropriate for the language (// for JS/TS/Go, # for Python, -- for Lua, etc.)
- Only suggest pragmas for files that represent distinct features. Skip utils, helpers, configs.
- Be conservative: 1 @project, 1 @stack, 1-3 @constraint, 1-3 @convention, 3-10 @feature.
- Descriptions should be ONE concise sentence.
]=]

M.BOOTSTRAP_PROMPT = BOOTSTRAP_PROMPT

function M.generate(callback)
	local scan_mod = require("dwight.bootstrap.scan")
	local scan = scan_mod.scan()

	local tree_str = table.concat(scan.tree, "\n")
	if #tree_str > 3000 then
		tree_str = tree_str:sub(1, 3000) .. "\n... (truncated)"
	end

	local entries_str = table.concat(scan.entry_files, ", ")
	if entries_str == "" then
		entries_str = "(none detected)"
	end

	local snippets_parts = {}
	for _, s in ipairs(scan.entry_snippets) do
		snippets_parts[#snippets_parts + 1] = string.format("--- %s ---\n%s", s.path, s.content)
	end
	local snippets_str = table.concat(snippets_parts, "\n\n")
	if snippets_str == "" then
		snippets_str = "(no entry files found)"
	end

	local prompt = string.format(BOOTSTRAP_PROMPT, tree_str, entries_str, snippets_str)

	-- Log to DwightLog
	local log = require("dwight.log")
	local job_id = log._next_id()
	log.start(
		job_id,
		"bootstrap",
		api.nvim_get_current_buf(),
		0,
		0,
		"DwightBootstrap: " .. #scan.tree .. " files scanned\n\n" .. prompt:sub(1, 4000)
	)

	require("dwight.skills")._run_llm(prompt, function(raw, code)
		if code ~= 0 or vim.trim(raw or "") == "" then
			log.finish(job_id, "error", raw or "", nil, "LLM generation failed")
			callback(nil, "LLM generation failed")
			return
		end
		-- Parse multi-file changes
		local multifile = require("dwight.multifile")
		local changes = multifile.parse_xml(raw)
		if not changes then
			log.finish(job_id, "parse_fail", raw or "", nil, "Could not parse pragma suggestions")
			callback(nil, "Could not parse pragma suggestions. Raw:\n" .. (raw or ""):sub(1, 500))
			return
		end
		log.finish(job_id, "success", raw, string.format("%d file(s) to annotate with pragmas", #changes), nil)
		callback(changes, nil)
	end)
end

--- Legacy single-shot bootstrap (fast but shallow).
function M._run_bootstrap()
	vim.notify("[dwight] Quick bootstrap: scanning project...", vim.log.levels.INFO)

	M.generate(function(changes, err)
		if err then
			vim.notify("[dwight] Bootstrap failed: " .. err, vim.log.levels.ERROR)
			return
		end

		vim.notify(string.format("[dwight] Found %d files to annotate.", #changes), vim.log.levels.INFO)

		local multifile = require("dwight.multifile")
		local count = multifile.apply_all(changes)
		vim.notify(
			string.format(
				"[dwight] Bootstrap complete! Added pragmas to %d file(s). Run :DwightFeatures to verify.\n"
					.. "Use :DwightMultiUndo to revert all, or undo per-file with u.",
				count
			),
			vim.log.levels.INFO
		)
	end)
end

return M
