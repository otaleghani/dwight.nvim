-- dwight/modes.lua
-- Built-in operation modes with filetype-aware filtering.
-- context = "code" (only in code files), "prose" (only in markdown/text), "both"

local M = {}

--------------------------------------------------------------------
-- Scope constraints
--------------------------------------------------------------------

local SCOPE = [=[

SCOPE (mandatory):
- Modify ONLY the given code. Your output replaces these exact lines.
- Do NOT add new imports, requires, or includes.
- Do NOT add new functions, classes, types, or modules.
- Do NOT add helper functions or "completeness" code.
- Do NOT restructure, move things around, or rename exports.
- If you need something that doesn't exist, leave a TODO comment.
]=]

local TEST_SCOPE = [=[

SCOPE (mandatory):
- Output ONLY test code. No implementation changes.
- Use the testing framework/conventions visible in the project context.
- Test the functions in the selected code — don't test unrelated code.
- If you need imports for the test framework, include only those.
- Match existing test file style if project context shows test examples.
]=]

local STUB_SCOPE = [=[

SCOPE (mandatory):
- Output ONLY function/method stubs with empty bodies or a single TODO comment.
- Do NOT implement any logic. Every function body should be empty or contain only: TODO
- Include full type annotations on parameters and return types.
- If the language supports it, use the idiomatic stub pattern (e.g., `pass` in Python, `todo!()` in Rust, `return nil` in Go).
- You MAY add type definitions, interfaces, or structs that the signatures reference.
- You MAY add the minimal imports needed for the types used in signatures.
- Do NOT add tests, examples, or usage code.

CRITICAL — NEVER output an empty file:
- Every file MUST contain a valid package/module declaration and at least one real stub.
- A file with only a package declaration and no functions is NOT acceptable.
- If you are creating a new file, include the required language boilerplate (package in Go, module in Python, etc.) plus the requested stubs.
]=]

local PROSE_SCOPE = [=[

SCOPE (mandatory):
- You are editing a MARKDOWN document. Output only markdown.
- Your output replaces the selected text exactly.
- Preserve the overall structure and heading hierarchy.
- Keep any existing content that the user didn't ask to change.
- Do NOT wrap output in code fences.
]=]

local MULTI_FILE_RULES = [=[

OUTPUT FORMAT (multi-file):
You may need to create or edit MULTIPLE files. Use this EXACT format:

<changes>
<file path="relative/path/to/file.ts" action="create">
...file content...
</file>
<file path="relative/path/to/existing.ts" action="edit" lines="15-30">
...replacement for those lines...
</file>
<file path="path/to/remove.ts" action="delete" />
</changes>

Actions: create (new file), edit (modify existing), delete (remove file).
The "lines" attribute is optional for edit — omit it to replace the entire file.
Paths are relative to project root.

When creating new files:
- Include a @feature:name pragma comment near the top (e.g. // @feature:auth) if one was requested in the instructions.
- NEVER create an empty file. Every file must have real, compilable content.
]=]

--------------------------------------------------------------------
-- Mode registry
--------------------------------------------------------------------

M.registry = {
	-- CODE MODES (only in code files)
	document = {
		name = "Document",
		icon = "📝",
		context = "code",
		description = "Add documentation comments (jsdoc, godoc, docstring, etc.)",
		task = [=[
Add documentation to the code below using the language's idiomatic doc style:
- JavaScript/TypeScript: JSDoc (/** ... */)
- Python: docstrings (""" ... """)
- Go: godoc (// FuncName ...)
- Rust: /// doc comments
- Lua: --- EmmyLua annotations

For each function, method, class, and module:
- Add a doc-comment above it with: brief description, @param types, @returns type.
- Add short inline comments for non-obvious logic only.
- Keep original code exactly as-is — only add comments.
- Comments explain WHY, not WHAT.
]=] .. SCOPE,
	},

	refactor = {
		name = "Refactor",
		icon = "🔧",
		context = "code",
		description = "Improve structure and readability",
		task = [=[
Refactor the code below for better structure, readability, and maintainability:
- Improve naming, reduce nesting, simplify conditionals.
- Preserve external behavior — same inputs and outputs.
- Don't add features or change the public API.
- Respect existing code style.
- You may extract local helpers WITHIN the selected code only.
]=] .. SCOPE,
	},

	optimize = {
		name = "Optimize",
		icon = "⚡",
		context = "code",
		description = "Performance optimization",
		task = [=[
Optimize the code below for better performance:
- Fix performance bottlenecks. Prefer algorithmic improvements.
- Preserve correctness — identical results required.
- If no meaningful optimization exists, return unchanged.
]=] .. SCOPE,
	},

	fix = {
		name = "Fix",
		icon = "🐛",
		context = "code",
		description = "Fix bugs",
		task = [=[
Fix the code below:
- Identify and fix bugs, errors, and broken logic.
- If build/test output is provided, fix the specific failures.
- Preserve the original intent and API.
- Add brief comments explaining what was wrong and how it's fixed.
]=] .. SCOPE,
	},

	security = {
		name = "Security",
		icon = "🔒",
		context = "code",
		description = "Security audit and hardening",
		task = [=[
Audit and fix security vulnerabilities in the code below:
- Input validation: sanitize, validate types/ranges, prevent injection.
- Authentication/authorization: check access, validate tokens.
- Data handling: encrypt secrets, prevent leaks, safe serialization.
- Fix issues inline. Add // SECURITY comments for decisions.
]=] .. SCOPE,
	},

	test = {
		name = "Test",
		icon = "🧪",
		context = "code",
		description = "Generate tests",
		task = [=[
Write tests for the code below.
- Use the project's test framework if visible in context, otherwise use the standard one.
- Cover: happy path, edge cases, error cases (as relevant to the request).
- Keep tests focused — one assertion per logical behavior.
- If the code has dependencies, mock/stub them appropriately.
]=] .. TEST_SCOPE,
	},

	stub = {
		name = "Stub",
		icon = "🦴",
		context = "code",
		description = "Generate function signatures and type stubs",
		is_multi = true, -- stubs may span multiple files
		task = [=[
Generate function stubs for the code below based on the user's instructions.

CRITICAL: Only create stubs for what the user SPECIFICALLY asked for.
- If the user says "create login and logout", create ONLY login and logout stubs.
- If the user gives NO specific instructions, create all stubs that make sense.

For each stub:
- Write ONLY function/method signatures with empty bodies (or a single TODO/pass/todo!()).
- Include FULL type annotations: parameter types, return types, generics.
- Add a brief doc-comment above each function explaining its purpose.
- If feature specs are in the context, match the signatures described there.
- Use the language's idiomatic patterns.

If multiple files are needed, use the multi-file output format.
]=] .. STUB_SCOPE .. MULTI_FILE_RULES,
	},

	code = {
		name = "Code",
		icon = "💻",
		context = "code",
		description = "Implement stubs and TODOs",
		is_multi = true, -- code generation may span multiple files
		task = [=[
Implement the code below. If it's a stub, signature, TODO, or incomplete — write the full working code.
- Follow existing signatures and types exactly.
- Match code style and conventions from the surrounding context.
- Handle edge cases and errors properly.
- Add brief comments for non-obvious logic.

If the implementation requires changes in multiple files, use the multi-file output format.
]=] .. SCOPE .. MULTI_FILE_RULES,
	},

	lint = {
		name = "Lint",
		icon = "🔍",
		context = "code",
		description = "AI-powered linting with diagnostics",
		is_lint = true,
		task = [=[
Lint the code below. Find bugs, issues, and improvements.

For EVERY issue found, output a comment line in this EXACT format:
  // [SEVERITY:LN] Description

Where:
- SEVERITY is one of: ERROR, WARN, STYLE, INFO
- N is the LINE NUMBER in the original code (relative to the selection)
- Description explains the issue concisely

Check for:
- Null/nil safety, unchecked errors, type mismatches
- Logic bugs, off-by-one, race conditions
- Performance issues (N+1, unnecessary allocations, O(n²))
- Security issues (injection, hardcoded secrets)
- Missing error handling, edge cases

Output ONLY the comment lines. No code, no preamble, no fences.
If no issues found, output: // [INFO:L1] No issues found.
]=],
	},

	macro = {
		name = "Macro",
		icon = "🎹",
		context = "code",
		description = "Generate Neovim commands/macros",
		is_macro = true,
		task = [=[
Generate Neovim commands or macros based on the user's instructions.

Output executable commands, one per line:
- :substitute commands, :global commands
- Normal mode key sequences
- Lua one-liners via :lua
- Combinations of the above

Add a brief comment (starting with ") above each command.
Output ONLY comments and commands. No fences, no preamble.
]=],
	},

	-- PROSE MODES (only in markdown/text files)
	brainstorm = {
		name = "Brainstorm",
		icon = "🧠",
		context = "prose",
		description = "Brainstorm ideas and approaches",
		task = [=[
Analyze the selected text and brainstorm ideas, approaches, and improvements.

Structure your response as markdown:
- Use ### headers for each idea/approach
- Be specific and actionable
- Consider trade-offs, alternatives, and risks
- If feature specs are in the context, reference them
- Suggest concrete next steps

Output markdown that replaces the selection.
]=] .. PROSE_SCOPE,
	},

	plan = {
		name = "Plan",
		icon = "📋",
		context = "prose",
		description = "Create a structured implementation plan",
		is_plan = true,
		task = [=[
Create a concrete, executable implementation plan based on the selected text.

OUTPUT FORMAT — this plan will be parsed by dwight, so follow EXACTLY:

# Plan: [Title]

## Context
Brief summary of what's being built and why (2-3 sentences).

## Decisions Needed
List gray areas the developer must resolve before execution:
- ⚠️ **Decision**: Options and trade-offs

## Steps

### 1. [Step title]
Brief developer-facing description of what this step does and why.
<!-- @dwight:action create path/to/new/file.ts -->
<!-- @dwight:prompt /stub $feature Create ... -->

### 2. [Step title]
Description.
<!-- @dwight:action edit path/to/existing/file.ts -->
<!-- @dwight:prompt /code $feature Implement ... -->

### 3. [Step title]
Description.
<!-- @dwight:action run npm test -->

Available actions: create, edit, delete, move (src → dest), run (shell command).
Prompts use dwight syntax: /mode +modifier $feature instructions.
Modifiers: +run (inject last test/build output).

RULES:
- Be STINGY: flag every ambiguity as a ⚠️ Decision Needed.
- Each step should be small enough for one dwight prompt.
- Order steps by dependency (what must happen first).
- Include a final "verify" step (run tests, build, etc).
- Reference features with $name if they exist in context.
]=] .. PROSE_SCOPE,
	},

	refine = {
		name = "Refine",
		icon = "✨",
		context = "prose",
		description = "Refine and improve selected text",
		task = [=[
Refine and improve the selected markdown text:
- Make it clearer, more specific, more actionable.
- Fix grammar and awkward phrasing.
- Preserve the author's intent and voice.
- Don't add filler or change the meaning.
- If there are vague parts, make them concrete.
]=] .. PROSE_SCOPE,
	},

	-- BOTH CONTEXTS
	explain = {
		name = "Explain",
		icon = "💡",
		context = "both",
		description = "Add explanatory comments/notes",
		task = [=[
Add detailed explanatory comments to the content below:
- Explain logic, patterns, and design decisions.
- Do NOT modify any code — only add comments.
- Reference design patterns and language idioms where relevant.
]=] .. SCOPE,
	},

	-- AGENT-SPECIFIC MODES (intentional roles for agent retries and step execution)

	implement = {
		name = "Implement",
		icon = "🔨",
		context = "code",
		description = "Make tests pass — sees tests, writes source",
		is_multi = true,
		role = "implement",
		task = [=[
Your SOLE job is to make the failing tests pass. You are given the test file(s) as context.

1. Read the test assertions carefully to understand the EXACT expected behavior.
2. Implement the MINIMUM code needed to make all tests pass.
3. Match function signatures, types, and return values EXACTLY as the tests expect.
4. Handle edge cases that tests check for.
5. Do NOT modify any test files. Only write/edit source files.
6. If a test imports a symbol, that symbol MUST exist in your implementation.

If the implementation requires changes in multiple files, use the multi-file output format.
]=] .. SCOPE .. MULTI_FILE_RULES,
	},

	fix_build = {
		name = "Fix Build",
		icon = "🔧",
		context = "code",
		description = "Fix compilation errors only — minimal changes",
		role = "fix_build",
		task = [=[
Fix the BUILD/COMPILATION errors shown in the error output. Make ONLY the minimum changes
needed to make the code compile. Do NOT:
- Change any logic or behavior
- Add new features or tests
- Refactor or reorganize code
- Fix test failures (only compilation errors)

Common build errors to fix:
- Missing imports/requires
- Type mismatches
- Undefined variables/functions
- Syntax errors
- Wrong number of arguments
]=] .. SCOPE,
	},

	fix_test = {
		name = "Fix Test",
		icon = "🧪",
		context = "code",
		description = "Fix specific test failures — sees failing test + error",
		is_multi = true,
		role = "fix_test",
		task = [=[
A specific test is FAILING. Fix the IMPLEMENTATION code (not the test) to make it pass.

The error output shows which test failed and why. Focus on:
1. Read the failing test name and assertion to understand what's expected.
2. Read the error message to understand what actually happened.
3. Fix the implementation to produce the expected result.
4. Do NOT modify test files unless the test itself has a bug (very rare).
5. Make the minimum change needed — don't refactor unrelated code.

If the fix requires changes in multiple files, use the multi-file output format.
]=] .. SCOPE .. MULTI_FILE_RULES,
	},

	fix_smoke = {
		name = "Fix Smoke",
		icon = "🔥",
		context = "code",
		description = "Fix runtime failures — unit tests pass but app crashes",
		is_multi = true,
		role = "fix_smoke",
		task = [=[
Unit tests PASS but the application FAILS at runtime. This is a WIRING problem.

The smoke test output shows the runtime error. Focus on:
1. Missing initialization: migrations not called, setup functions skipped
2. Missing wiring: dependencies not connected in main/init
3. Interface not satisfied: concrete type never created in production code path
4. Import missing in production: package used in tests but not imported in main
5. Configuration gap: function needs parameter never passed in real call chain
6. Entry point issues: main() doesn't call the right functions

Fix the PRODUCTION code path (main.go, init.py, index.ts, etc.), NOT the tests.
You MUST trace from the entry point to find where the wiring is broken.

If the fix requires changes in multiple files, use the multi-file output format.
]=] .. SCOPE .. MULTI_FILE_RULES,
	},

	wire = {
		name = "Wire",
		icon = "🔌",
		context = "code",
		description = "Connect components — wire dependencies in main/init",
		is_multi = true,
		role = "wire",
		task = [=[
Wire components together. You are given multiple source files that define types, interfaces,
and functions. Your job is to connect them in the application's entry point.

For each component:
1. Verify it is imported in the entry point
2. Verify it is initialized (constructors called, migrations run)
3. Verify it is connected to its dependencies (injected, passed as parameter)
4. Verify the initialization ORDER is correct (dependencies before dependents)

Common wiring patterns:
- Go: AutoMigrate in Open(), handler registration in main()
- Python: app.register_blueprint(), db.init_app()
- JS/TS: middleware registration, route mounting, service injection
- Rust: .configure(), .service(), .wrap()

Fix ONLY the wiring/initialization code. Do NOT change business logic.
]=] .. SCOPE .. MULTI_FILE_RULES,
	},

	docs = {
		name = "Docs",
		icon = "📄",
		context = "both",
		description = "Generate documentation (comments in code, markdown in prose)",
		is_docs = true,
		-- Task is set dynamically based on filetype in M.get()
		task = "",
	},
}

--------------------------------------------------------------------
-- Docs mode: dynamic task based on filetype
--------------------------------------------------------------------

local DOCS_CODE_TASK = [=[
Add comprehensive documentation comments to the code below using the language's
idiomatic documentation system:

- JavaScript/TypeScript: JSDoc with @param, @returns, @throws, @example
- Python: Google-style docstrings with Args, Returns, Raises, Examples
- Go: godoc format (// FunctionName does ...)
- Rust: /// with # Examples, # Panics, # Errors
- Java/Kotlin: Javadoc with @param, @return, @throws
- Lua: EmmyLua @param, @return, @class

Document every exported/public function, class, method, and type.
Include parameter types, return types, brief description, and one example.
Do NOT modify any code — only add documentation comments.
]=] .. SCOPE

local DOCS_PROSE_TASK = [=[
Generate user-facing documentation based on the selected text.

If this looks like developer/technical content, generate DEVELOPER documentation:
- Technical, precise, reference-style
- Include types, signatures, edge cases

If this looks like feature descriptions or high-level content, generate USER documentation:
- Clear, friendly, example-driven
- Focus on what the user can DO, not how it works

Output clean Markdown. Use headers, code blocks, and callout blocks.
]=] .. PROSE_SCOPE

--------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------

function M.get(name)
	if name == "fix_bugs" then
		name = "fix"
	end

	-- Agent mode aliases with hyphens
	local aliases = {
		["fix-build"] = "fix_build",
		["fix-test"] = "fix_test",
		["fix-smoke"] = "fix_smoke",
	}
	if aliases[name] then
		name = aliases[name]
	end

	-- Backwards compat: /tdd → /code with inject_run_output
	if name == "tdd" then
		local code = M.registry["code"]
		if code then
			return vim.tbl_extend("force", code, {
				name = "Code (+run)",
				icon = "🔴",
				inject_run_output = true,
			})
		end
	end

	local mode = M.registry[name]
	if not mode then
		return nil
	end

	-- Dynamic task for docs mode
	if name == "docs" and mode.task == "" then
		local ft = vim.bo.filetype
		if ft == "markdown" or ft == "text" or ft == "help" then
			return vim.tbl_extend("force", mode, { task = DOCS_PROSE_TASK })
		else
			return vim.tbl_extend("force", mode, { task = DOCS_CODE_TASK, is_docs = false })
		end
	end

	return mode
end

--- List all mode names.
function M.list()
	local names = {}
	for k in pairs(M.registry) do
		names[#names + 1] = k
	end
	table.sort(names)
	return names
end

--- List mode names filtered by filetype context.
function M.list_for_filetype(filetype)
	filetype = filetype or vim.bo.filetype
	local is_prose = filetype == "markdown" or filetype == "text" or filetype == "help" or filetype == "dwight_prompt"
	local names = {}
	for k, v in pairs(M.registry) do
		local ctx = v.context or "both"
		if ctx == "both" or (is_prose and ctx == "prose") or (not is_prose and ctx == "code") then
			names[#names + 1] = k
		end
	end
	table.sort(names)
	return names
end

function M.register(name, mode)
	assert(mode.task, "Mode must have a 'task' field")
	mode.name = mode.name or name
	mode.icon = mode.icon or "🔹"
	mode.description = mode.description or ""
	mode.context = mode.context or "both"
	M.registry[name] = mode
end

--- Resolve which model to use for a given mode name.
--- Returns model_override (string or nil). nil = use default model.
function M.resolve_model(mode_name)
	local cfg = require("dwight").config

	-- Only apply diversity if both models are configured
	if not cfg.test_model and not cfg.implement_model then
		return nil
	end

	-- Test-writing modes → test_model
	local test_modes = { test = true, stub = true }
	if test_modes[mode_name] and cfg.test_model then
		return cfg.test_model
	end

	-- Implementation/fix modes → implement_model
	local impl_modes = {
		code = true,
		implement = true,
		fix = true,
		fix_build = true,
		fix_test = true,
		fix_smoke = true,
		wire = true,
	}
	if impl_modes[mode_name] and cfg.implement_model then
		return cfg.implement_model
	end

	return nil
end

return M
