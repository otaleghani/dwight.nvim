-- dwight/devdocs.lua
-- Generates developer documentation in .dwight/dev/ from live feature context.
-- Uses features + treesitter + LLM. Architecture.md lives here — for devs, not LLMs.
-- :DwightDevDocs generates or updates the full dev doc set.

local M = {}

local api = vim.api

local function devdocs_dir()
	return require("dwight.project").dir() .. "/dev"
end

--------------------------------------------------------------------
-- Document types
--------------------------------------------------------------------

local DOC_TYPES = {
	{
		file = "architecture.md",
		title = "Architecture",
		prompt = [[
Generate a technical architecture document for developers joining this project.

%s

Include:
## Architecture Overview
What the system does and how it's structured (2-3 paragraphs).

## System Diagram
ASCII art showing how components/features connect.

## Feature Map
Brief description of each feature and its role.

## Data Flow
How data moves through the system.

## Technical Decisions
Key architectural choices and their rationale.

Be concise and technical. Under 100 lines.
Respond with ONLY the markdown wrapped in ~~~markdown ... ~~~.
]],
	},
	{
		file = "api-reference.md",
		title = "API Reference",
		prompt = [[
Generate an API reference from the feature signatures below.

%s

Group by feature. For each exported function/method/class, include:
- Signature with types
- One-line description
- Parameters and return type

Be extremely concise. This is a quick-lookup reference.
Respond with ONLY the markdown wrapped in ~~~markdown ... ~~~.
]],
	},
	{
		file = "getting-started.md",
		title = "Getting Started",
		prompt = [[
Generate a "Getting Started" guide for a developer joining this project.

%s

Include:
## Prerequisites
What tools/versions are needed.

## Setup
Step-by-step setup instructions.

## Project Structure
Key directories and what they contain.

## Development Workflow
How to run, test, and debug.

## Key Concepts
Important patterns or abstractions a new dev should understand.

Keep it practical and actionable. Under 80 lines.
Respond with ONLY the markdown wrapped in ~~~markdown ... ~~~.
]],
	},
}

--------------------------------------------------------------------
-- Build context for doc generation
--------------------------------------------------------------------

local function build_doc_context()
	local features = require("dwight.features")
	local parts = {}

	-- Project context
	local proj_xml = features.build_project_context()
	if proj_xml then
		parts[#parts + 1] = "Project context (from pragmas):\n" .. proj_xml
	end

	-- Fallback to project.md
	pcall(function()
		local scope = require("dwight.project").read_scope()
		if scope and not proj_xml then
			parts[#parts + 1] = "Project scope:\n" .. scope
		end
	end)

	-- All features with full XML
	local names = features.names()
	if #names > 0 then
		parts[#parts + 1] = "\nFeatures (" .. #names .. "):"
		for _, name in ipairs(names) do
			local xml = features.read(name)
			if xml then
				parts[#parts + 1] = xml
			end
		end
	end

	-- Config file hints
	pcall(function()
		local hints = require("dwight.project")._scan_project_hints()
		if hints and hints ~= "(no config files detected)" then
			parts[#parts + 1] = "\nConfig files: " .. hints
		end
	end)

	return table.concat(parts, "\n\n")
end

--------------------------------------------------------------------
-- Generate a single doc
--------------------------------------------------------------------

local function generate_doc(doc_type, context, callback)
	local prompt = string.format(doc_type.prompt, context)
	require("dwight.skills")._run_llm(prompt, function(raw, code)
		if code ~= 0 or vim.trim(raw or "") == "" then
			callback(nil, "Generation failed for " .. doc_type.title)
			return
		end
		local content = raw:match("~~~%w*%s*\n(.-)~~~") or raw:match("```%w*%s*\n(.-)```") or raw
		if not content:match("^#") then
			content = "# " .. doc_type.title .. "\n\n" .. content
		end
		callback(content, nil)
	end)
end

--------------------------------------------------------------------
-- :DwightDevDocs — generate full doc set
--------------------------------------------------------------------

function M.generate(doc_name)
	local project = require("dwight.project")
	if not project.is_initialized() then
		vim.notify("[dwight] Run :DwightInit first.", vim.log.levels.WARN)
		return
	end

	local features = require("dwight.features")
	local names = features.names()
	if #names == 0 then
		vim.notify("[dwight] No features found. Add @feature: pragmas to your code first.", vim.log.levels.WARN)
		return
	end

	vim.fn.mkdir(devdocs_dir(), "p")
	local context = build_doc_context()

	-- If a specific doc was requested, generate just that
	if doc_name then
		for _, dt in ipairs(DOC_TYPES) do
			if dt.file:match(doc_name) or dt.title:lower():match(doc_name:lower()) then
				vim.notify("[dwight] 📖 Generating " .. dt.title .. "…", vim.log.levels.INFO)
				local log = require("dwight.log")
				local job_id = log._next_id()
				log.start(job_id, "devdocs:" .. dt.file, api.nvim_get_current_buf(), 0, 0, "")

				generate_doc(dt, context, function(content, err)
					if err then
						log.finish(job_id, "error", "", nil, err)
						vim.notify("[dwight] " .. err, vim.log.levels.ERROR)
					else
						local path = devdocs_dir() .. "/" .. dt.file
						local f = io.open(path, "w")
						if f then
							f:write(content)
							f:close()
						end
						log.finish(job_id, "success", "", content, nil)
						vim.notify("[dwight] ✅ " .. dt.title .. " generated!", vim.log.levels.INFO)
						vim.cmd("edit " .. vim.fn.fnameescape(path))
					end
				end)
				return
			end
		end
		vim.notify("[dwight] Unknown doc type: " .. doc_name, vim.log.levels.WARN)
		return
	end

	-- Generate all docs
	vim.notify(
		string.format("[dwight] 📖 Generating %d developer docs from %d features…", #DOC_TYPES, #names),
		vim.log.levels.INFO
	)

	local pending = #DOC_TYPES
	local generated = 0
	for _, dt in ipairs(DOC_TYPES) do
		generate_doc(dt, context, function(content, err)
			pending = pending - 1
			if content then
				local path = devdocs_dir() .. "/" .. dt.file
				local f = io.open(path, "w")
				if f then
					f:write(content)
					f:close()
				end
				generated = generated + 1
			end
			if pending == 0 then
				vim.notify(
					string.format("[dwight] ✅ Generated %d/%d docs in .dwight/dev/", generated, #DOC_TYPES),
					vim.log.levels.INFO
				)
				if generated > 0 then
					vim.cmd("edit " .. vim.fn.fnameescape(devdocs_dir() .. "/architecture.md"))
				end
			end
		end)
	end
end

--------------------------------------------------------------------
-- Browse dev docs
--------------------------------------------------------------------

function M.browse()
	local dir = devdocs_dir()
	if vim.fn.isdirectory(dir) ~= 1 then
		vim.notify("[dwight] No dev docs. Run :DwightDevDocs to generate.", vim.log.levels.INFO)
		return
	end

	local files = {}
	local uv = vim.loop or vim.uv
	local handle = uv.fs_scandir(dir)
	if handle then
		while true do
			local name, ftype = uv.fs_scandir_next(handle)
			if not name then
				break
			end
			if ftype == "file" and name:match("%.md$") then
				files[#files + 1] = name
			end
		end
	end
	table.sort(files)

	if #files == 0 then
		vim.notify("[dwight] No dev docs found.", vim.log.levels.INFO)
		return
	end

	local has_tel, pickers = pcall(require, "telescope.pickers")
	if has_tel then
		local finders = require("telescope.finders")
		local conf = require("telescope.config").values
		local actions = require("telescope.actions")
		local action_state = require("telescope.actions.state")
		local previewers = require("telescope.previewers")

		pickers
			.new({}, {
				prompt_title = "📖 Dev Docs (.dwight/dev/)",
				finder = finders.new_table({ results = files }),
				sorter = conf.generic_sorter({}),
				previewer = previewers.new_buffer_previewer({
					define_preview = function(self, entry)
						conf.buffer_previewer_maker(dir .. "/" .. entry[1], self.state.bufnr, {})
					end,
				}),
				attach_mappings = function(pb)
					actions.select_default:replace(function()
						local sel = action_state.get_selected_entry()
						actions.close(pb)
						if sel then
							vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/" .. sel[1]))
						end
					end)
					return true
				end,
			})
			:find()
	else
		for i, name in ipairs(files) do
			vim.notify(string.format("  %d. %s", i, name))
		end
	end
end

--------------------------------------------------------------------
-- Agentic dev docs: reads source, cross-references, verifies
--------------------------------------------------------------------

--- Run agentic dev docs generation.
function M.generate_agentic(doc_name)
	local project = require("dwight.project")
	if not project.is_initialized() then
		vim.notify("[dwight] Run :DwightInit first.", vim.log.levels.WARN)
		return
	end

	local features = require("dwight.features")
	local names = features.names()
	if #names == 0 then
		vim.notify("[dwight] No features found. Add @feature: pragmas first.", vim.log.levels.WARN)
		return
	end

	vim.fn.mkdir(devdocs_dir(), "p")

	-- Build feature→files map for the agent
	local feature_files = {}
	for _, name in ipairs(names) do
		local feat = features.build_feature(name)
		if feat and feat.files then
			local file_list = {}
			for _, ff in ipairs(feat.files) do
				file_list[#file_list + 1] = ff.path or ff
			end
			feature_files[#feature_files + 1] = string.format("  $%s: %s", name, table.concat(file_list, ", "))
		end
	end

	-- Build doc list
	local target_docs = {}
	if doc_name then
		for _, dt in ipairs(DOC_TYPES) do
			if dt.file:match(doc_name) or dt.title:lower():match(doc_name:lower()) then
				target_docs[#target_docs + 1] = dt
				break
			end
		end
		if #target_docs == 0 then
			vim.notify("[dwight] Unknown doc type: " .. doc_name, vim.log.levels.WARN)
			return
		end
	else
		target_docs = DOC_TYPES
	end

	local doc_list = {}
	for _, dt in ipairs(target_docs) do
		doc_list[#doc_list + 1] = string.format("  %s — %s", dt.file, dt.title)
	end

	-- Check for existing docs
	local existing = {}
	for _, dt in ipairs(target_docs) do
		local path = devdocs_dir() .. "/" .. dt.file
		if vim.fn.filereadable(path) == 1 then
			existing[#existing + 1] = dt.file
		end
	end

	local prompt = string.format(
		[[
You are generating developer documentation for an internal engineering audience.

## Output Directory
%s/

## Documents to Generate
%s

## Features → Source Files
%s
%s

## Your Task — IN ORDER

### Step 1: Read ALL source files
For each feature, read the actual source code to understand:
- Public API: exported functions, methods, types, interfaces
- Internal architecture: how components connect
- Error handling and edge cases
- Dependencies between features

### Step 2: Read existing docs (if any)
%s

### Step 3: Write documentation
For each document, write it to %s/{filename}. Requirements:

**architecture.md**: Include real component relationships from the code. The system diagram
should reflect actual imports/calls between modules. Data flow should trace real function calls.

**api-reference.md**: Extract REAL signatures from source code. Every function listed must
actually exist. Include types, parameters, return values. Group by feature.

**getting-started.md**: Include actual setup commands that work. Project structure should
match real directory layout. Development workflow should use real commands from the project.

### Step 4: Cross-reference verification
After writing all docs, verify:
- All function names in api-reference.md exist in the source
- All file paths in getting-started.md are correct
- Links between docs use correct relative paths
- Code examples compile/run (verify by reading surrounding source)

Fix any inaccuracies you find.

## Important Rules
- Write from ACTUAL source code — no guesses, no placeholders
- Every function signature must match the real code
- Every file path must exist
- Be concise and technical — this is for engineers
- Do NOT modify any source code files
- Do NOT create extra files beyond the doc targets
]],
		devdocs_dir(),
		table.concat(doc_list, "\n"),
		table.concat(feature_files, "\n"),
		#names .. " feature(s): " .. table.concat(names, ", "),
		#existing > 0 and ("Read these existing docs for style: " .. table.concat(existing, ", "))
			or "No existing docs — establish a clear, concise technical style.",
		devdocs_dir()
	)

	vim.notify(
		string.format("[dwight] 🤖 Agentic dev docs: %d doc(s) from %d features…", #target_docs, #names),
		vim.log.levels.INFO
	)

	local agent = require("dwight.agent")
	agent.run(prompt, {
		plan = false,
		on_complete = function(success)
			vim.schedule(function()
				if success then
					local generated = 0
					for _, dt in ipairs(target_docs) do
						if vim.fn.filereadable(devdocs_dir() .. "/" .. dt.file) == 1 then
							generated = generated + 1
						end
					end
					vim.notify(
						string.format(
							"[dwight] 🤖 Dev docs complete! %d/%d docs in .dwight/dev/\n"
								.. "Run :DwightDevDocsBrowse to review.",
							generated,
							#target_docs
						),
						vim.log.levels.INFO
					)
					if vim.fn.filereadable(devdocs_dir() .. "/architecture.md") == 1 then
						vim.cmd("edit " .. vim.fn.fnameescape(devdocs_dir() .. "/architecture.md"))
					end
				else
					vim.notify("[dwight] 🤖 Dev docs had errors. Check :DwightAgentStatus.", vim.log.levels.WARN)
				end
			end)
		end,
	})
end

return M
