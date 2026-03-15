-- dwight/agent/init.lua
-- Re-exports the exact same public API as the original agent.lua module.
-- Shared helpers (_agent_dir, _gather_project_context) live here.

local M = {}

--------------------------------------------------------------------
-- Shared helpers (used by multiple sub-modules)
--------------------------------------------------------------------

function M._agent_dir()
	local ok, project = pcall(require, "dwight.project")
	if ok and project.is_initialized() then
		return project.dir() .. "/agent"
	end
	return vim.fn.stdpath("data") .. "/dwight/agent"
end

function M._gather_project_context()
	local parts = {}

	-- Deep project manifest (go.mod, package.json, Cargo.toml, pyproject.toml)
	pcall(function()
		local context = require("dwight.context")
		local manifest = context.build_xml()
		if manifest then
			-- Trim long dependency lists -- agent only needs project name + lang + main deps
			if #manifest > 1500 then
				manifest = manifest:sub(1, 1500) .. "\n... (deps truncated)"
			end
			parts[#parts + 1] = manifest
		end
	end)

	-- JIT pragmas (@project, @stack, @constraint, @convention, @feature)
	pcall(function()
		local features = require("dwight.features")
		local xml = features.build_project_context()
		if xml and xml ~= "" then
			parts[#parts + 1] = xml
		end

		local names = features.names()
		if #names > 0 then
			parts[#parts + 1] = "Features: " .. table.concat(names, ", ")
		end
	end)

	-- File tree (brief -- just enough for the agent to know the structure)
	pcall(function()
		local bootstrap = require("dwight.bootstrap")
		local scan = bootstrap.scan()
		if scan.tree and #scan.tree > 0 then
			local tree = table.concat(scan.tree, "\n")
			-- Agent plans only need ~40 lines of tree (not 2000 chars)
			local lines = {}
			for line in tree:gmatch("[^\n]+") do
				lines[#lines + 1] = line
				if #lines >= 40 then
					break
				end
			end
			if #lines >= 40 then
				lines[#lines + 1] = "... (truncated)"
			end
			parts[#parts + 1] = "<project_tree>\n" .. table.concat(lines, "\n") .. "\n</project_tree>"
		end
		-- Entry snippets: max 4, max 500 chars each (agent needs patterns, not full code)
		if scan.entry_snippets then
			local count = 0
			for _, s in ipairs(scan.entry_snippets) do
				if count >= 4 then
					break
				end
				local content = s.content
				if #content > 500 then
					content = content:sub(1, 500) .. "\n// ... (truncated)"
				end
				parts[#parts + 1] = string.format('<file path="%s">\n%s\n</file>', s.path, content)
				count = count + 1
			end
		end
	end)

	-- Skills, libs, and pragma instructions via integration module
	pcall(function()
		local integration = require("dwight.integration")
		local full_ctx = integration.build_full_context()
		if full_ctx then
			parts[#parts + 1] = full_ctx
		end
	end)

	-- Codebase digest: pre-extracted file signatures (the big speedup)
	pcall(function()
		local digest = require("dwight.digest")
		local digest_text = digest.format_for_prompt()
		if digest_text then
			parts[#parts + 1] = digest_text
		end
	end)
	if #parts == 0 then
		return "(no project context detected)"
	end
	return table.concat(parts, "\n\n")
end

--------------------------------------------------------------------
-- Re-exports: lessons
--------------------------------------------------------------------

function M._extract_lessons(...)
	return require("dwight.agent.lessons")._extract_lessons(...)
end

function M._load_lessons(...)
	return require("dwight.agent.lessons")._load_lessons(...)
end

function M._save_lessons(...)
	return require("dwight.agent.lessons")._save_lessons(...)
end

function M._find_relevant_lessons(...)
	return require("dwight.agent.lessons")._find_relevant_lessons(...)
end

function M._append_lessons(...)
	return require("dwight.agent.lessons")._append_lessons(...)
end

function M._evict_lessons(...)
	return require("dwight.agent.lessons")._evict_lessons(...)
end

function M._consolidate_lessons(...)
	return require("dwight.agent.lessons")._consolidate_lessons(...)
end

function M._lesson_stats(...)
	return require("dwight.agent.lessons")._lesson_stats(...)
end

--------------------------------------------------------------------
-- Re-exports: plan
--------------------------------------------------------------------

function M._generate_plan(...)
	return require("dwight.agent.plan")._generate_plan(...)
end

function M._show_plan_buffer(...)
	return require("dwight.agent.plan")._show_plan_buffer(...)
end

function M._plan_to_context(...)
	return require("dwight.agent.plan")._plan_to_context(...)
end

--------------------------------------------------------------------
-- Re-exports: run
--------------------------------------------------------------------

function M.run(...)
	return require("dwight.agent.run").run(...)
end

function M._run_agentic(...)
	return require("dwight.agent.run")._run_agentic(...)
end

--------------------------------------------------------------------
-- Re-exports: diff
--------------------------------------------------------------------

function M._show_post_diff(...)
	return require("dwight.agent.diff")._show_post_diff(...)
end

function M.diff_review(...)
	return require("dwight.agent.diff").diff_review(...)
end

-- _last_pre_head is a mutable field on the diff module; expose it as a property
-- so callers who read M._last_pre_head get the current value.
setmetatable(M, {
	__index = function(_, k)
		if k == "_last_pre_head" then
			return require("dwight.agent.diff")._last_pre_head
		end
	end,
	__newindex = function(_, k, v)
		if k == "_last_pre_head" then
			require("dwight.agent.diff")._last_pre_head = v
		else
			rawset(M, k, v)
		end
	end,
})

--------------------------------------------------------------------
-- Re-exports: sessions
--------------------------------------------------------------------

function M._save_session(...)
	return require("dwight.agent.sessions")._save_session(...)
end

function M.list_sessions(...)
	return require("dwight.agent.sessions").list_sessions(...)
end

function M.show_log(...)
	return require("dwight.agent.sessions").show_log(...)
end

function M._show_log_telescope(...)
	return require("dwight.agent.sessions")._show_log_telescope(...)
end

function M._show_log_fallback(...)
	return require("dwight.agent.sessions")._show_log_fallback(...)
end

return M
