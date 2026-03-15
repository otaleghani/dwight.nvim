-- dwight/agent/plan.lua
-- Plan generation and display for DwightAgent.

local M = {}

local api = vim.api
local _flatten = require("dwight.util").flatten_lines

--------------------------------------------------------------------
-- Plan generation prompt
--------------------------------------------------------------------

local PLAN_PROMPT = [=[
You are a senior engineer. Given the task below and the project context, produce a brief execution plan.

## Task
%s

## Project Context
%s

## Instructions
Respond ONLY with a JSON object (no markdown, no backticks):
{
  "summary": "1-sentence summary of what needs to happen",
  "complexity": "simple|medium|complex",
  "steps": [
    {"action": "read|write|edit|test|run", "target": "file or command", "description": "what and why"}
  ],
  "risks": ["potential risk or gotcha"],
  "estimated_files": 3,
  "recommend_auto": false
}

Keep it concise: 3-8 steps max. "recommend_auto" should be true ONLY if the task clearly needs multiple independent sub-tasks.
]=]

--- Generate an execution plan for a request.
--- callback(plan_table_or_nil, raw_text)
function M._generate_plan(request, callback)
	local gather_project_context = require("dwight.agent")._gather_project_context
	local context = gather_project_context()

	-- Inject feature context
	pcall(function()
		local integration = require("dwight.integration")
		local feature_ctx = integration.build_feature_context(request)
		if feature_ctx then
			context = context .. "\n\n" .. feature_ctx
		end
	end)

	local prompt = string.format(PLAN_PROMPT, request:sub(1, 3000), context:sub(1, 8000))

	require("dwight.skills")._run_llm(prompt, function(raw, code)
		if code ~= 0 or not raw or vim.trim(raw) == "" then
			callback(nil, raw)
			return
		end

		-- Parse JSON (strip markdown fences if present)
		local cleaned = raw:gsub("```json%s*", ""):gsub("```%s*", ""):match("(%{.+%})")
		if not cleaned then
			callback(nil, raw)
			return
		end

		local ok, plan = pcall(vim.json.decode, cleaned)
		if ok and type(plan) == "table" then
			plan._raw_context = context -- carry context forward to agent
			callback(plan, raw)
		else
			callback(nil, raw)
		end
	end)
end

--- Show plan in an editable markdown buffer (similar to DwightAuto decomposition).
--- User can freely edit the plan before starting. On <CR>, the buffer content
--- is re-read and passed as plan context to the agent.
--- on_action("run"|"auto"|"cancel", plan, edited_request)
function M._show_plan_buffer(request, plan, on_action)
	local safe_request = request:sub(1, 80):gsub("\n", " ")

	local lines = {
		"<!-- ═══════════════════════════════════════════════════════ -->",
		string.format("<!-- DwightAgent Plan: %s -->", safe_request),
		string.format("<!-- Complexity: %s | Est. files: %d -->", plan.complexity or "?", plan.estimated_files or 0),
		"<!-- -->",
		"<!-- <CR> execute with DwightAgent | A switch to DwightAuto | q cancel -->",
		"<!-- Edit the plan freely before starting -->",
		"<!-- ═══════════════════════════════════════════════════════ -->",
		"",
	}

	-- Summary
	if plan.summary then
		lines[#lines + 1] = "## Summary"
		lines[#lines + 1] = ""
		lines[#lines + 1] = plan.summary
		lines[#lines + 1] = ""
	end

	-- Steps
	if plan.steps and #plan.steps > 0 then
		lines[#lines + 1] = "## Steps"
		lines[#lines + 1] = ""
		for i, step in ipairs(plan.steps) do
			local target = step.target and step.target ~= "" and (" `" .. step.target .. "`") or ""
			lines[#lines + 1] = string.format("%d. [%s]%s %s", i, step.action or "?", target, step.description or "")
		end
		lines[#lines + 1] = ""
	end

	-- Risks
	if plan.risks and #plan.risks > 0 then
		lines[#lines + 1] = "## Risks"
		lines[#lines + 1] = ""
		for _, r in ipairs(plan.risks) do
			lines[#lines + 1] = "- " .. r
		end
		lines[#lines + 1] = ""
	end

	-- Recommend Auto?
	if plan.recommend_auto then
		lines[#lines + 1] = "> This task looks complex -- DwightAuto (multi-task) may work better. Press A to switch."
		lines[#lines + 1] = ""
	end

	local buf = api.nvim_create_buf(true, false)
	api.nvim_buf_set_lines(buf, 0, -1, false, _flatten(lines))
	vim.bo[buf].filetype = "markdown"
	vim.bo[buf].bufhidden = "wipe"
	pcall(function()
		api.nvim_buf_set_name(buf, "dwight://agent-plan")
	end)

	vim.cmd("tab split")
	api.nvim_win_set_buf(0, buf)

	-- <CR>: Re-read buffer content and execute
	vim.keymap.set("n", "<CR>", function()
		local buf_lines = api.nvim_buf_get_lines(buf, 0, -1, false)
		local text = table.concat(buf_lines, "\n")

		-- Strip HTML comments, keep the rest as plan context
		local plan_text = text:gsub("<!%-%-.-%-%->\n?", "")
		plan_text = vim.trim(plan_text)

		pcall(api.nvim_buf_delete, buf, { force = true })

		-- Build a plan table from the edited text so _plan_to_context works,
		-- but also carry the raw edited text as fallback
		local edited_plan = vim.tbl_deep_extend("force", {}, plan)
		edited_plan._edited_text = plan_text

		on_action("run", edited_plan, request)
	end, { buffer = buf, desc = "Execute with DwightAgent" })

	-- A: Switch to Auto
	vim.keymap.set("n", "A", function()
		pcall(api.nvim_buf_delete, buf, { force = true })
		on_action("auto", plan, request)
	end, { buffer = buf, desc = "Switch to DwightAuto" })

	-- q: Cancel
	vim.keymap.set("n", "q", function()
		pcall(api.nvim_buf_delete, buf, { force = true })
		vim.notify("[dwight] Plan cancelled.", vim.log.levels.INFO)
		on_action("cancel", plan, request)
	end, { buffer = buf, desc = "Cancel" })
end

--- Convert a plan table to context string for the agent prompt.
--- If the user edited the plan buffer, _edited_text contains their version.
function M._plan_to_context(plan)
	if not plan then
		return ""
	end

	-- User edited the plan: use their text directly
	if plan._edited_text and vim.trim(plan._edited_text) ~= "" then
		return "\n## Execution Plan (pre-approved by user)\n"
			.. plan._edited_text
			.. "\n\nFollow this plan but adapt if you discover something unexpected."
	end

	local parts = { "\n## Execution Plan (pre-approved by user)" }
	if plan.summary then
		parts[#parts + 1] = "Summary: " .. plan.summary
	end
	if plan.steps and #plan.steps > 0 then
		parts[#parts + 1] = "Steps:"
		for i, step in ipairs(plan.steps) do
			local target = step.target and (" -> " .. step.target) or ""
			parts[#parts + 1] = string.format("  %d. [%s] %s%s", i, step.action or "?", step.description or "", target)
		end
	end
	if plan.risks and #plan.risks > 0 then
		parts[#parts + 1] = "Known risks:"
		for _, r in ipairs(plan.risks) do
			parts[#parts + 1] = "  - " .. r
		end
	end
	parts[#parts + 1] = "Follow this plan but adapt if you discover something unexpected."
	return table.concat(parts, "\n")
end

return M
