-- dwight/bootstrap/agentic.lua
-- Agentic bootstrap: uses DwightAgent to read code and tag files.

local M = {}

local AGENTIC_BOOTSTRAP_PROMPT = [=[
You are bootstrapping a project with dwight pragma comments for AI-assisted development.

## What are dwight pragmas?

Pragma comments are special inline comments that help the AI understand the codebase structure.
They are placed at the TOP of source files (line 1 or 2), using the file's native comment syntax.

Available pragma types:

1. **@project** -- ONE file only (main entry point). Describes what the project does.
   Example: `// Todo app with REST API and WebSocket notifications. @project`

2. **@stack** -- ONE file only (same as @project). Lists the tech stack.
   Example: `// Go 1.22, GORM, SQLite, JWT, Cobra CLI. @stack`

3. **@constraint** -- ONE file only (same as @project). Project constraints.
   Example: `// GDPR compliant. No global state. 100%% test coverage on core. @constraint`

4. **@convention** -- ONE file only (same as @project). Coding conventions.
   Example: `// Use dependency injection. Error wrapping with %%w. Table-driven tests. @convention`

5. **@feature:name** -- MANY files. Groups files into logical features.
   Example: `// JWT authentication and session management. @feature:auth`
   - Name: lowercase, kebab-case (auth, user-mgmt, billing, api-routes)
   - Description: ONE sentence explaining what this feature does
   - Every source file that belongs to a feature should have this pragma

## Your task

1. **Read the directory tree** to understand project structure
2. **Read key files** -- entry points, package definitions, main modules -- to understand architecture
3. **Identify features** -- logical groupings of files (auth, database, routing, UI, etc.)
4. **Add pragmas to ALL relevant source files:**
   - @project + @stack + @constraint + @convention on the main entry point
   - @feature:name on EVERY file that belongs to a feature
5. **Verify coverage** by listing what you tagged

## Rules

- Use the file's comment syntax (// for Go/JS/TS, # for Python, -- for Lua, etc.)
- Add pragma as the FIRST line of the file (prepend before existing content)
- If the file already has a pragma, skip it
- Be THOROUGH: tag 80%%+ of source files. Skip only utilities, generated code, and configs.
- Feature names: 3-15 features for a medium project. Group related files together.
- Descriptions: ONE concise sentence per pragma.
- Do NOT modify any actual code -- only add comment lines at the top.
- Skip: test files, vendor/, node_modules/, .git/, binary files, config files (json/yaml/toml)
- After tagging, list all features you created with file counts.

## Pragma format by language

Go:     `// Description. @feature:name`
JS/TS:  `// Description. @feature:name`
Python: `# Description. @feature:name`
Lua:    `-- Description. @feature:name`
Ruby:   `# Description. @feature:name`
Rust:   `// Description. @feature:name`
C/C++:  `// Description. @feature:name`
Java:   `// Description. @feature:name`
Shell:  `# Description. @feature:name`

Start by reading the project structure, then read key files to understand the architecture.
Then systematically add pragmas file by file.
]=]

M.AGENTIC_BOOTSTRAP_PROMPT = AGENTIC_BOOTSTRAP_PROMPT

function M._run_bootstrap_agentic()
	local scan_mod = require("dwight.bootstrap.scan")
	local scan = scan_mod.scan()

	vim.notify("[dwight] Agentic bootstrap: scanning project...", vim.log.levels.INFO)

	local tree_str = table.concat(scan.tree, "\n")
	if #tree_str > 6000 then
		tree_str = tree_str:sub(1, 6000) .. "\n... (truncated)"
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

	local file_count = 0
	for _, entry in ipairs(scan.tree) do
		if not entry:match("/$") then
			file_count = file_count + 1
		end
	end

	local prompt = AGENTIC_BOOTSTRAP_PROMPT
		.. string.format(
			[=[

## Project scan (pre-computed -- do NOT waste time running ls or find)

Total files: %d
Entry/config files: %s

Directory tree:
```
%s
```

Entry file previews:
```
%s
```

Now proceed: read key source files to understand the architecture, then add pragmas.
Target: tag at least %d files (80%% of %d source files).
]=],
			file_count,
			entries_str,
			tree_str,
			snippets_str,
			math.floor(file_count * 0.8),
			file_count
		)

	vim.notify(
		string.format("[dwight] Agentic bootstrap: %d files found, starting agent...", file_count),
		vim.log.levels.INFO
	)

	local agent = require("dwight.agent")
	agent.run(prompt, {
		plan = false, -- skip planning, the prompt IS the plan
		on_complete = function(success)
			vim.schedule(function()
				if success then
					-- Rebuild feature index
					pcall(function()
						local features = require("dwight.features")
						local names = features.names()
						local total_tagged = 0
						for _, name in ipairs(names) do
							local feature = features.build_feature(name)
							if feature and feature.files then
								total_tagged = total_tagged + #feature.files
							end
						end
						vim.notify(
							string.format(
								"[dwight] Bootstrap complete!\n"
									.. "  Features: %d (%s)\n"
									.. "  Tagged: %d/%d files (%.0f%%)\n"
									.. "Run :DwightFeatures to explore.",
								#names,
								table.concat(names, ", "),
								total_tagged,
								file_count,
								file_count > 0 and (total_tagged / file_count * 100) or 0
							),
							vim.log.levels.INFO
						)
					end)
				else
					vim.notify(
						"[dwight] Bootstrap had errors. Check :DwightAgentStatus for details.",
						vim.log.levels.WARN
					)
				end
			end)
		end,
	})
end

return M
