-- dwight/prompt.lua
-- Builds the full prompt. Features context + think depth chain-of-thought.
-- ^1 = normal, ^2 = CoT prefix, ^3+ = multi-pass analysis (handled by opencode.lua).

local M = {}

local function get_config()
	return require("dwight").config
end

local function read_file(path)
	local f = io.open(path, "r")
	if not f then
		return nil
	end
	local content = f:read("*a")
	f:close()
	return content
end

local function comment_style(filetype)
	local overrides = get_config().comment_styles
	if overrides and overrides[filetype] then
		if type(overrides[filetype]) == "string" then
			return { line = overrides[filetype] }
		end
		return overrides[filetype]
	end

	local styles = {
		javascript = { line = "// " },
		typescript = { line = "// " },
		typescriptreact = { line = "// " },
		javascriptreact = { line = "// " },
		go = { line = "// " },
		rust = { line = "// " },
		c = { line = "// " },
		cpp = { line = "// " },
		java = { line = "// " },
		kotlin = { line = "// " },
		swift = { line = "// " },
		scala = { line = "// " },
		dart = { line = "// " },
		php = { line = "// " },
		zig = { line = "// " },
		v = { line = "// " },
		odin = { line = "// " },
		proto = { line = "// " },
		groovy = { line = "// " },
		scss = { line = "// " },
		sass = { line = "// " },
		python = { line = "# " },
		ruby = { line = "# " },
		sh = { line = "# " },
		bash = { line = "# " },
		zsh = { line = "# " },
		fish = { line = "# " },
		yaml = { line = "# " },
		toml = { line = "# " },
		elixir = { line = "# " },
		perl = { line = "# " },
		r = { line = "# " },
		julia = { line = "# " },
		dockerfile = { line = "# " },
		make = { line = "# " },
		cmake = { line = "# " },
		conf = { line = "# " },
		terraform = { line = "# " },
		hcl = { line = "# " },
		nix = { line = "# " },
		powershell = { line = "# " },
		ps1 = { line = "# " },
		lua = { line = "-- " },
		haskell = { line = "-- " },
		sql = { line = "-- " },
		ada = { line = "-- " },
		vhdl = { line = "-- " },
		vim = { line = '" ' },
		html = { line = "<!-- " },
		xml = { line = "<!-- " },
		svg = { line = "<!-- " },
		vue = { line = "// " },
		svelte = { line = "// " },
		css = { line = "/* " },
		ocaml = { line = "(* " },
		fsharp = { line = "// " },
		clojure = { line = ";; " },
		lisp = { line = ";; " },
		scheme = { line = ";; " },
		asm = { line = "; " },
		nasm = { line = "; " },
		ini = { line = "; " },
		erlang = { line = "% " },
		latex = { line = "% " },
		tex = { line = "% " },
		matlab = { line = "% " },
	}
	return styles[filetype] or { line = "// " }
end

--------------------------------------------------------------------
-- Think Depth: Chain-of-Thought prefix
--------------------------------------------------------------------

-- ^2: Adds analysis preamble (zero extra API calls)
local COT_PREFIX = [[
Before writing code, think step by step:
1. What exactly does this code do? What are its inputs and outputs?
2. What edge cases, error conditions, or tricky parts exist?
3. What patterns or idioms would best apply here?
4. What could go wrong with a naive approach?
Then implement your solution in a single fenced code block.

]]

-- ^3+: This prompt is used for the ANALYSIS pass (pass 1).
-- The response is then fed into a second pass that produces code.
M.ANALYSIS_PROMPT = [[
Analyze this code carefully. Do NOT write code yet. Instead:
1. Describe what the code does and its role in the system.
2. Identify every edge case, bug, or limitation.
3. List the specific changes needed to fulfill the task.
4. For each change, explain WHY and describe the approach.
5. Note any risks, tradeoffs, or dependencies.

Be specific and reference line numbers. This analysis will be used to guide implementation.

]]

-- ^4: Additional planning pass prompt (pass 2 of 3)
M.PLAN_PROMPT = [[
Based on the analysis above, create a detailed implementation plan:
1. List each change in order of execution.
2. For each change: exact location, what to add/modify/remove, and why.
3. Identify any changes that depend on other changes.
4. Note what should NOT be changed.

Be precise enough that a developer could follow this plan line by line.

]]

--------------------------------------------------------------------
-- Build Prompt
--------------------------------------------------------------------

function M.build(
	mode,
	selection,
	ctx,
	extra_instructions,
	skill_paths,
	resolved_symbols,
	resolved_features,
	think_depth,
	resolved_libs,
	resolved_mcp,
	resolved_files
)
	local lsp = require("dwight.lsp")
	local project = require("dwight.project")
	local runner = require("dwight.runner")
	local budget = require("dwight.budget")
	local cfg = get_config()
	local parts = {}
	local cs = comment_style(selection.filetype or ctx.language)

	think_depth = think_depth or 1

	-- ^2: Chain-of-thought prefix (added to the single request)
	if think_depth == 2 then
		parts[#parts + 1] = COT_PREFIX
	end

	-- Task (wrapped in XML)
	parts[#parts + 1] = string.format('<task mode="%s">\n%s\n</task>', mode.name or "custom", mode.task)

	-- User instructions
	if extra_instructions and extra_instructions ~= "" then
		parts[#parts + 1] = "\n<instructions>" .. extra_instructions .. "</instructions>"
	end

	-- Code (placed early so it's never trimmed)
	local code_section = string.format(
		'\n<code language="%s" file="%s" lines="%d-%d">\n%s\n</code>',
		ctx.language,
		vim.fn.fnamemodify(selection.filepath or "", ":."),
		selection.start_line,
		selection.end_line,
		selection.text
	)

	-- Build optional context sections with priorities (trimmed by budget)
	local optional = {}
	local P = budget.PRIORITY

	-- JIT project context (from @project, @constraint, @stack, @convention pragmas)
	pcall(function()
		local features = require("dwight.features")
		local proj_xml = features.build_project_context()
		if proj_xml then
			optional[#optional + 1] = budget.section(P.ARCHITECTURE + 5, "project", "\n" .. proj_xml)
		end
	end)

	-- Project manifest (from go.mod, package.json, Cargo.toml, pyproject.toml)
	pcall(function()
		local context = require("dwight.context")
		local manifest_xml = context.build_xml()
		if manifest_xml then
			optional[#optional + 1] = budget.section(P.ARCHITECTURE + 3, "manifest", "\n" .. manifest_xml)
		end
	end)

	-- Features (from $feature tokens — live XML from @feature: pragmas)
	resolved_features = resolved_features or {}
	if #resolved_features > 0 then
		local feat_parts = { "\n<features>" }
		for _, feat in ipairs(resolved_features) do
			feat_parts[#feat_parts + 1] = feat.content
		end
		feat_parts[#feat_parts + 1] = "</features>"
		optional[#optional + 1] = budget.section(P.FEATURES, "features", table.concat(feat_parts, "\n"))
	end

	-- Auto feature index (compact one-liners, only when user didn't $reference)
	pcall(function()
		local features = require("dwight.features")
		local all_names = features.names()
		if #all_names > 0 and #resolved_features == 0 then
			local index = features.build_index()
			if index then
				optional[#optional + 1] = budget.section(
					P.ARCHITECTURE - 5,
					"feature_index",
					"\n<feature_index>\n" .. index .. "\n</feature_index>"
				)
			end
		end
	end)

	-- Library refs (from %lib tokens — XML format)
	resolved_libs = resolved_libs or {}
	if #resolved_libs > 0 then
		local lib_parts = { "\n<libraries>" }
		for _, lib in ipairs(resolved_libs) do
			-- Content is already XML for new libs, plain text for legacy .md
			lib_parts[#lib_parts + 1] = lib.content
		end
		lib_parts[#lib_parts + 1] = "</libraries>"
		optional[#optional + 1] = budget.section(P.LIBS, "libs", table.concat(lib_parts, "\n"))
	end

	-- MCP resources (from &server:resource tokens)
	resolved_mcp = resolved_mcp or {}
	if #resolved_mcp > 0 then
		local mcp_parts = { "\n<mcp_resources>" }
		for _, res in ipairs(resolved_mcp) do
			mcp_parts[#mcp_parts + 1] = string.format('<resource name="%s">\n%s\n</resource>', res.name, res.content)
		end
		mcp_parts[#mcp_parts + 1] = "</mcp_resources>"
		optional[#optional + 1] = budget.section(P.MCP_RESOURCES, "mcp", table.concat(mcp_parts, "\n"))
	end

	-- File context (from +file tokens — treesitter minimaps or full files)
	resolved_files = resolved_files or {}
	if #resolved_files > 0 then
		local file_parts = { "\n<referenced_files>" }
		for _, f in ipairs(resolved_files) do
			file_parts[#file_parts + 1] = string.format('<file path="%s">\n%s\n</file>', f.name, f.content)
		end
		file_parts[#file_parts + 1] = "</referenced_files>"
		optional[#optional + 1] = budget.section(P.FEATURES + 5, "files", table.concat(file_parts, "\n"))
	end

	-- RAG: search codebase for symbols mentioned in instructions
	-- Skip when mode provides its own file context (e.g., agent on-fail with related_files)
	if not mode.skip_rag then
		pcall(function()
			local rag = require("dwight.rag")
			local rag_ctx = rag.gather_context(extra_instructions or "", selection)
			if rag_ctx then
				optional[#optional + 1] =
					budget.section(P.SYMBOLS - 5, "rag", "\n<codebase_search>\n" .. rag_ctx .. "\n</codebase_search>")
			end
		end)
	end

	-- Skills
	local all_skill_paths = skill_paths or {}
	for _, name in ipairs(cfg.default_skills) do
		local path = require("dwight.skills").resolve(name)
		if path then
			local found = false
			for _, p in ipairs(all_skill_paths) do
				if p == path then
					found = true
					break
				end
			end
			if not found then
				all_skill_paths[#all_skill_paths + 1] = path
			end
		end
	end
	if #all_skill_paths > 0 then
		local skill_parts = { "\n<guidelines>" }
		for _, path in ipairs(all_skill_paths) do
			local content = read_file(path)
			if content then
				skill_parts[#skill_parts + 1] = content
			end
		end
		skill_parts[#skill_parts + 1] = "</guidelines>"
		optional[#optional + 1] = budget.section(P.SKILLS, "skills", table.concat(skill_parts, "\n"))
	end

	-- Symbols
	resolved_symbols = resolved_symbols or {}
	if #resolved_symbols > 0 then
		local sym_parts = { '\n<symbols hint="reuse these, do NOT redefine">' }
		for _, sym in ipairs(resolved_symbols) do
			sym_parts[#sym_parts + 1] = string.format(
				'  <symbol name="%s" kind="%s" file="%s" line="%d" />',
				sym.name,
				sym.kind,
				vim.fn.fnamemodify(sym.filepath, ":."),
				sym.line
			)
			if sym.text then
				sym_parts[#sym_parts + 1] = sym.text
			end
		end
		sym_parts[#sym_parts + 1] = "</symbols>"
		optional[#optional + 1] = budget.section(P.SYMBOLS, "symbols", table.concat(sym_parts, "\n"))
	end

	-- TDD / test context (injected when mode has inject_run_output)
	if mode.inject_run_output then
		pcall(function()
			local tdd = require("dwight.tdd")
			local tdd_ctx = tdd.get_tdd_context(selection)
			if tdd_ctx then
				optional[#optional + 1] =
					budget.section(P.TEST_CONTEXT, "tdd", "\n<test_context>\n" .. tdd_ctx .. "\n</test_context>")
			end
		end)
	end

	-- Build/test output (injected when mode has inject_run_output)
	local run_ctx = runner.last_run_context()
	if run_ctx and mode.inject_run_output then
		optional[#optional + 1] =
			budget.section(P.RUN_OUTPUT, "run_output", "\n<build_output>\n" .. run_ctx .. "\n</build_output>")
	end

	-- Git context (toggled with :DwightGitToggle, skipped during agent retries)
	if cfg.git_context ~= false and not mode.skip_git then
		pcall(function()
			local git_ctx = require("dwight.git").context_for_selection(selection)
			if git_ctx then
				optional[#optional + 1] =
					budget.section(P.GIT_CONTEXT, "git", "\n<git_context>\n" .. git_ctx .. "\n</git_context>")
			end
		end)
	end

	-- File structure: treesitter minimap (cheaper than full LSP context)
	pcall(function()
		local ts = require("dwight.treesitter")
		local filepath = selection.filepath or vim.api.nvim_buf_get_name(selection.bufnr)
		if filepath and filepath ~= "" then
			local minimap = ts.minimap(filepath)
			if minimap and minimap ~= "" then
				optional[#optional + 1] = budget.section(
					P.LSP_DIAGNOSTICS,
					"file_structure",
					string.format(
						'\n<file_structure path="%s">\n%s\n</file_structure>',
						vim.fn.fnamemodify(filepath, ":."),
						minimap
					)
				)
			end
		end
	end)

	-- Diagnostics only (from vim.diagnostic, not full LSP hover/types)
	if ctx.diagnostics and #ctx.diagnostics > 0 then
		local diag_parts = { "\n<diagnostics>" }
		for _, d in ipairs(ctx.diagnostics) do
			diag_parts[#diag_parts + 1] = string.format(
				'  <diagnostic line="%s" severity="%s">%s</diagnostic>',
				d.line or "?",
				d.severity or "HINT",
				d.message or ""
			)
		end
		diag_parts[#diag_parts + 1] = "</diagnostics>"
		optional[#optional + 1] = budget.section(P.LSP_DIAGNOSTICS + 2, "diagnostics", table.concat(diag_parts, "\n"))
	end

	-- Apply budget to optional sections
	-- Reserve tokens for: task + instructions + code + output rules (~fixed cost)
	local fixed_cost = 0
	for _, p in ipairs(parts) do
		fixed_cost = fixed_cost + math.ceil(#p / 4)
	end
	fixed_cost = fixed_cost + math.ceil(#code_section / 4) + 200 -- 200 for rules
	local remaining = budget.get_budget() - fixed_cost
	local trimmed = budget.apply(optional, remaining)

	-- Assemble: fixed parts → budget-managed context → code → rules
	for _, section in ipairs(trimmed) do
		parts[#parts + 1] = section.text
	end

	parts[#parts + 1] = code_section

	-- Output rules (context-aware)
	local scope_reminder = ""
	if think_depth >= 3 then
		scope_reminder = string.format(
			"\n6. IMPORTANT: Output ONLY the code for lines %d-%d. Do NOT include the entire file.",
			selection.start_line,
			selection.end_line
		)
	end

	-- Check if mode supports multi-file or is prose
	local is_multi = mode.is_multi or false
	local is_prose = mode.context == "prose"

	if is_prose then
		parts[#parts + 1] = [=[

<rules>
1. Reply with ONLY markdown. No code fences wrapping the output.
2. Your output replaces the selected text exactly.
3. Preserve heading hierarchy and existing structure.
4. Use [[Wikilinks]] for internal cross-references when writing docs.
</rules>]=]
	elseif is_multi then
		parts[#parts + 1] = string.format(
			[[

<rules>
1. If changes span MULTIPLE files, reply with a <changes>...</changes> XML block.
   Inside: <file path="..." action="create|edit|delete" lines="N-M">...content...</file>
2. If changes affect ONLY the current selection, reply with a fenced code block (```%s ... ```).
3. Only modify what's needed. No unnecessary changes.
4. Comment prefix: %s
5. If unchanged, return original code in a code block.%s
</rules>]],
			ctx.language,
			cs.line,
			scope_reminder
		)
	else
		parts[#parts + 1] = string.format(
			[[

<rules>
1. Reply with ONLY a fenced code block (```%s ... ```). Nothing else.
2. Only modify the given code. No new imports, functions, or helpers unless asked.
3. Output is a drop-in replacement for lines %d-%d only.
4. Comment prefix: %s
5. If unchanged, return original code in a code block.%s
</rules>]],
			ctx.language,
			selection.start_line,
			selection.end_line,
			cs.line,
			scope_reminder
		)
	end

	return table.concat(parts, "\n")
end

function M.build_freeform(
	user_text,
	selection,
	skill_paths,
	resolved_symbols,
	resolved_features,
	think_depth,
	resolved_libs,
	resolved_mcp,
	resolved_files
)
	local lsp = require("dwight.lsp")
	local ctx = lsp.gather_context(selection)

	local custom_mode = {
		name = "Custom",
		task = "Do exactly what is asked, nothing more:\n" .. user_text,
	}

	return M.build(
		custom_mode,
		selection,
		ctx,
		nil,
		skill_paths,
		resolved_symbols,
		resolved_features,
		think_depth,
		resolved_libs,
		resolved_mcp,
		resolved_files
	)
end

--- Build a follow-up prompt that refines a previous inline edit.
--- @param follow_up_text string  The user's refinement instruction
--- @param prev table  The _last_inline state (prompt_text, raw_response, etc.)
--- @param current_code string  The current code at the edit range
function M.build_follow_up(follow_up_text, prev, current_code)
	local parts = {}

	parts[#parts + 1] = "<previous_exchange>"
	parts[#parts + 1] = "<request>"
	parts[#parts + 1] = prev.prompt_text
	parts[#parts + 1] = "</request>"
	parts[#parts + 1] = "<response>"
	parts[#parts + 1] = prev.raw_response
	parts[#parts + 1] = "</response>"
	parts[#parts + 1] = "</previous_exchange>"

	parts[#parts + 1] = ""
	parts[#parts + 1] = "<current_code>"
	parts[#parts + 1] = current_code
	parts[#parts + 1] = "</current_code>"

	parts[#parts + 1] = ""
	parts[#parts + 1] = "<follow_up>"
	parts[#parts + 1] = follow_up_text
	parts[#parts + 1] = "</follow_up>"

	parts[#parts + 1] = ""
	parts[#parts + 1] = [[<rules>
1. Reply with ONLY a fenced code block. Nothing else.
2. Output is a drop-in replacement for the current code shown above.
3. Apply the follow-up instruction to refine the previous result.
4. Do not add explanations, comments about changes, or anything outside the code fence.
</rules>]]

	return table.concat(parts, "\n")
end

--- Build an analysis-only prompt for ^3+ multi-pass.
--- Returns the prompt with ANALYSIS_PROMPT prepended and no code-output rules.
function M.build_analysis(base_prompt, pass_number)
	local prefix
	if pass_number == 1 then
		prefix = M.ANALYSIS_PROMPT
	else
		prefix = M.PLAN_PROMPT
	end

	-- Strip the output rules from base_prompt (everything after "Rules:")
	local stripped = base_prompt:gsub("\nRules:\n.*$", "")

	return prefix .. stripped .. "\n\nRespond with analysis only. Do NOT write code yet."
end

--- Build a final code prompt that includes prior analysis.
function M.build_with_analysis(base_prompt, analysis_text)
	-- Insert analysis before the code section
	local code_marker = base_prompt:find("\n```")
	if not code_marker then
		return base_prompt .. "\n\nPrior analysis:\n" .. analysis_text
	end

	local before = base_prompt:sub(1, code_marker - 1)
	local after = base_prompt:sub(code_marker)

	return before .. "\n\nPrior analysis (use this to guide your implementation):\n" .. analysis_text .. after
end

return M
