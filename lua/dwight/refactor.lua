-- dwight/refactor.lua
-- DwightRefactor: refactor a feature based on a prompt.
-- Reads the feature files + their importers, plans the refactoring,
-- and executes it via DwightAuto's agentic pipeline.

local M = {}

local api = vim.api

--------------------------------------------------------------------
-- Find importers: files that import/require any of the feature's files
--------------------------------------------------------------------

--- Scan the project tree for files that import any of the given paths.
--- Returns { { path = "...", imports = { "feature_file_1", ... } }, ... }
function M._find_importers(feature_files, tree_lines)
	local cwd = vim.fn.getcwd()

	-- Build a set of feature file basenames and package paths for matching
	local feature_basenames = {}
	local feature_packages = {}
	for _, f in ipairs(feature_files) do
		local path = f.path or f
		-- basename without extension: "handlers.go" → "handlers"
		local base = path:match("([^/]+)%.[^.]+$") or path:match("[^/]+$") or ""
		feature_basenames[base] = path
		-- package-style paths: "internal/auth/handlers.go" → "internal/auth"
		local pkg = path:match("^(.+)/[^/]+$")
		if pkg then
			feature_packages[pkg] = true
		end
		-- Also match the full relative path
		feature_basenames[path] = path
	end

	-- Skip these extensions when scanning
	local skip_ext = {
		[".png"] = true,
		[".jpg"] = true,
		[".svg"] = true,
		[".ico"] = true,
		[".woff"] = true,
		[".lock"] = true,
		[".sum"] = true,
		[".mod"] = true,
		[".min.js"] = true,
		[".min.css"] = true,
		[".map"] = true,
	}

	-- Feature file set (don't report feature files as their own importers)
	local feature_set = {}
	for _, f in ipairs(feature_files) do
		feature_set[f.path or f] = true
	end

	local importers = {}
	local seen = {}

	for _, rel_path in ipairs(tree_lines or {}) do
		if rel_path:match("/$") then
			goto continue
		end -- skip dirs
		if feature_set[rel_path] then
			goto continue
		end -- skip feature's own files

		local ext = rel_path:match("%.[^.]+$") or ""
		if skip_ext[ext] then
			goto continue
		end

		-- Only scan source files
		local is_source = ext:match("%.go$")
			or ext:match("%.py$")
			or ext:match("%.js$")
			or ext:match("%.ts$")
			or ext:match("%.tsx$")
			or ext:match("%.jsx$")
			or ext:match("%.lua$")
			or ext:match("%.rs$")
			or ext:match("%.rb$")
			or ext:match("%.java$")
		if not is_source then
			goto continue
		end

		local full = cwd .. "/" .. rel_path
		local f = io.open(full, "r")
		if not f then
			goto continue
		end
		local content = f:read("*a")
		f:close()
		if not content then
			goto continue
		end

		-- Check each line for import/require statements referencing feature files
		local matched_imports = {}
		for line in content:gmatch("[^\n]+") do
			-- Match import paths against feature basenames/packages
			local import_path = line:match("[\"']([^\"']+)[\"']")
				or line:match("from%s+[\"']([^\"']+)[\"']")
				or line:match("require%s*%(?%s*[\"']([^\"']+)[\"']")
			if import_path then
				-- Check if this import references any feature file
				for base, feat_path in pairs(feature_basenames) do
					if import_path:find(base, 1, true) then
						matched_imports[feat_path] = true
					end
				end
				-- Check package-level imports (Go, Python)
				for pkg in pairs(feature_packages) do
					if import_path:find(pkg, 1, true) then
						matched_imports[pkg] = true
					end
				end
			end
		end

		local imports_list = {}
		for imp in pairs(matched_imports) do
			imports_list[#imports_list + 1] = imp
		end

		if #imports_list > 0 and not seen[rel_path] then
			seen[rel_path] = true
			importers[#importers + 1] = { path = rel_path, imports = imports_list }
		end
		::continue::
	end

	return importers
end

--------------------------------------------------------------------
-- Build refactoring context
--------------------------------------------------------------------

--- Build comprehensive context for the refactoring LLM.
--- Includes feature files (full source), signatures, and importer code.
function M._build_context(feature, importers)
	local parts = {}
	local cwd = vim.fn.getcwd()
	local ts_ok, ts = pcall(require, "dwight.treesitter")
	local total_chars = 0
	local MAX_CHARS = 25000

	-- Feature files: full source (they're the refactoring target)
	parts[#parts + 1] = "<feature_files>"
	for _, file_info in ipairs(feature.files) do
		local filepath = file_info.path
		local full = filepath:sub(1, 1) == "/" and filepath or (cwd .. "/" .. filepath)
		local f = io.open(full, "r")
		if f then
			local content = f:read("*a")
			f:close()
			if content and content ~= "" then
				if #content > 5000 then
					content = content:sub(1, 5000) .. "\n... (truncated)"
				end
				total_chars = total_chars + #content
				local sigs = ""
				if ts_ok then
					sigs = ts.minimap(full) or ""
				end
				parts[#parts + 1] = string.format(
					'<file path="%s">\n<signatures>\n%s\n</signatures>\n<source>\n%s\n</source>\n</file>',
					filepath,
					sigs,
					content
				)
			end
		end
	end
	parts[#parts + 1] = "</feature_files>"

	-- Importer files: signatures + relevant import sections
	if #importers > 0 then
		parts[#parts + 1] = "\n<importers>"
		parts[#parts + 1] = "Files that import this feature (must be updated if public API changes):"
		for _, imp in ipairs(importers) do
			if total_chars >= MAX_CHARS then
				break
			end

			local full = imp.path:sub(1, 1) == "/" and imp.path or (cwd .. "/" .. imp.path)
			local sigs = ""
			if ts_ok then
				sigs = ts.minimap(full) or ""
			end

			-- Read just the import section + usages (first 2000 chars)
			local f = io.open(full, "r")
			local content = ""
			if f then
				content = f:read("*a")
				f:close()
				if #content > 2000 then
					content = content:sub(1, 2000) .. "\n... (truncated)"
				end
				total_chars = total_chars + #content
			end

			parts[#parts + 1] = string.format(
				'<importer path="%s" imports="%s">\n<signatures>\n%s\n</signatures>\n<source>\n%s\n</source>\n</importer>',
				imp.path,
				table.concat(imp.imports, ", "),
				sigs,
				content
			)
		end
		parts[#parts + 1] = "</importers>"
	end

	return table.concat(parts, "\n")
end

--------------------------------------------------------------------
-- Refactoring prompt
--------------------------------------------------------------------

local REFACTOR_PROMPT = [=[
You are Dwight, an autonomous coding agent. The developer wants to REFACTOR an existing feature.

Feature: $%s
%s

Refactoring request: %s

%s

REFACTORING RULES:
1. Preserve ALL existing behavior unless the prompt explicitly asks for behavioral changes.
2. If the feature has importers (files that use it), you MUST update them too.
3. Keep the same public API unless the prompt specifically asks to change it.
4. If splitting files, move code — don't duplicate it.
5. Each sub-task must leave tests passing (no broken intermediate states).
6. Run tests after each sub-task to verify nothing broke.
7. FEATURE PRAGMA PROPAGATION: The original file has `@feature:%s` on line 1. When you
   create ANY new file for this feature, you MUST add the same pragma as the first line.
   Use the file's comment style (e.g., `-- @feature:%s` for Lua, `// @feature:%s` for Go/JS).
   This is how the project tracks which files belong to which feature — without it, new files
   become invisible to the tooling.

DECOMPOSITION RULES:
1. Each sub-task MUST be independently verifiable (tests pass after each).
2. Sub-tasks execute SEQUENTIALLY — each one can depend on files from previous ones.
3. Each sub-task should be small enough for a single DwightAgent session (5-6 steps max).
4. Order: structural changes first, then update importers, then cleanup.
5. Include what each sub-task should produce (files created/modified/deleted).
6. MAXIMUM 8 sub-tasks.
7. Each sub-task description must be CONCRETE: include file paths, function names, types.

RESPOND IN THIS EXACT FORMAT:

<tasks>
<task order="1" title="Short title">
Concrete description of what to refactor. Include:
- Exact file paths to create/edit/delete
- Function signatures and types to move/rename
- What tests to update/create
- What the verify command should be
</task>
<task order="2" title="Short title" depends_on="1">
...
</task>
</tasks>
]=]

--- Start a refactoring session.
--- feature_name: string — name of the feature to refactor.
--- prompt: string — what to refactor (e.g., "Split into smaller files").
function M.refactor(feature_name, prompt)
	if not feature_name or feature_name == "" then
		-- Pick from available features
		local features = require("dwight.features")
		local names = features.names()
		if #names == 0 then
			vim.notify("[dwight] No features found. Run :DwightBootstrap first.", vim.log.levels.WARN)
			return
		end
		require("dwight.select").pick(names, { prompt = "Refactor which feature?" }, function(name)
			if not name then
				return
			end
			vim.ui.input({ prompt = "Refactoring prompt: " }, function(input)
				if input and vim.trim(input) ~= "" then
					M.refactor(name, input)
				end
			end)
		end)
		return
	end

	if not prompt or vim.trim(prompt) == "" then
		vim.ui.input({ prompt = "Refactoring prompt for $" .. feature_name .. ": " }, function(input)
			if input and vim.trim(input) ~= "" then
				M.refactor(feature_name, input)
			end
		end)
		return
	end

	local features = require("dwight.features")
	local feature = features.build_feature(feature_name)
	if not feature then
		vim.notify("[dwight] Feature '" .. feature_name .. "' not found.", vim.log.levels.ERROR)
		return
	end

	vim.notify(
		string.format("[dwight] 🔄 Preparing refactoring for $%s (%d files)…", feature_name, #feature.files),
		vim.log.levels.INFO
	)

	-- Get project tree for importer scanning
	local tree_lines = {}
	pcall(function()
		local bootstrap = require("dwight.bootstrap")
		local scan = bootstrap.scan()
		if scan.tree then
			tree_lines = scan.tree
		end
	end)

	-- Find importers
	local importers = M._find_importers(feature.files, tree_lines)
	local importer_note = ""
	if #importers > 0 then
		local imp_names = {}
		for _, imp in ipairs(importers) do
			imp_names[#imp_names + 1] = imp.path
		end
		importer_note = string.format(
			"\n⚠️ Found %d file(s) that import this feature: %s\nThese must be updated if the public API changes.\n",
			#importers,
			table.concat(imp_names, ", ")
		)
		vim.notify(
			string.format("[dwight] 📦 Found %d importer(s) of $%s", #importers, feature_name),
			vim.log.levels.INFO
		)
	end

	-- Build context
	local context = M._build_context(feature, importers)
	local desc = feature.description and string.format("Description: %s", feature.description) or ""

	-- Build the full decomposition prompt
	local full_prompt =
		string.format(REFACTOR_PROMPT, feature_name, desc, prompt, context, feature_name, feature_name, feature_name)

	-- Log to DwightLog
	local log = require("dwight.log")
	local job_id = log._next_id()
	log.start(
		job_id,
		"refactor:plan",
		api.nvim_get_current_buf(),
		0,
		0,
		string.format(
			"DwightRefactor: $%s — %s\n%s\n\n%s",
			feature_name,
			prompt,
			importer_note,
			full_prompt:sub(1, 4000)
		)
	)

	-- Use DwightAuto's decomposition + execution pipeline
	local auto = require("dwight.auto")

	-- Wrap the refactoring as a DwightAuto request with pre-built context
	local auto_request = string.format("Refactor feature $%s: %s%s", feature_name, prompt, importer_note)

	-- Inject the refactoring context into DwightAuto's decomposition
	-- by using the _decompose callback directly
	vim.notify(
		string.format("[dwight] 🔄 Decomposing refactoring plan for $%s…", feature_name),
		vim.log.levels.INFO
	)

	require("dwight.skills")._run_llm(full_prompt, function(raw, code)
		if code ~= 0 or not raw or vim.trim(raw) == "" then
			log.finish(job_id, "error", raw or "", nil, "Refactoring plan generation failed")
			vim.notify("[dwight] Refactoring plan generation failed.", vim.log.levels.ERROR)
			return
		end

		local tasks = auto._parse_tasks(raw)
		if #tasks == 0 then
			log.finish(job_id, "parse_fail", raw, nil, "No tasks parsed from refactoring plan")
			vim.notify("[dwight] Failed to parse refactoring plan. Check :DwightLog.", vim.log.levels.ERROR)
			return
		end

		local task_summary = {}
		for _, t in ipairs(tasks) do
			task_summary[#task_summary + 1] = string.format("%d. %s", t.order, t.title)
		end
		log.finish(
			job_id,
			"success",
			raw,
			string.format("%d tasks:\n%s", #tasks, table.concat(task_summary, "\n")),
			nil
		)

		-- Show decomposition preview and let user review before executing
		auto._show_decomposition(auto_request, tasks, function(approved_tasks)
			if not approved_tasks then
				vim.notify("[dwight] Refactoring cancelled.", vim.log.levels.INFO)
				return
			end

			vim.notify(
				string.format("[dwight] 🔄 Starting refactoring: %d tasks", #approved_tasks),
				vim.log.levels.INFO
			)

			-- Execute via DwightAuto's standard execution pipeline
			auto._start_execution(auto_request, approved_tasks, 1)
		end)
	end)
end

return M
