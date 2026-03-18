-- dwight/reflection.lua
-- Agent self-reflection / retry loop.
-- When enabled (cfg.agentic_opts.reflection = true), a successful agent run
-- is reviewed by an LLM. If the verdict is RETRY and retries remain, the
-- task is re-spawned with feedback context. Fails open: any LLM error or
-- unparseable response passes the original result through.

local M = {}

M.MAX_RETRIES = 1
M.OUTPUT_TAIL_CHARS = 3000

--------------------------------------------------------------------
-- Prompt Builder
--------------------------------------------------------------------

--- Build the reflection prompt sent to the reviewer LLM.
--- @param task string       Original task description
--- @param summary string    Agent's self-reported summary (truncated)
--- @param output_tail string Tail of agent stdout
--- @return string
function M._build_prompt(task, summary, output_tail)
	task = (task or "")
	summary = (summary or ""):sub(1, 500)
	output_tail = (output_tail or ""):sub(-M.OUTPUT_TAIL_CHARS)
	local n = #output_tail

	return string.format(
		[[You are reviewing the output of an autonomous coding agent.
Your job: determine if the agent meaningfully addressed the task.

## Original Task
%s

## Agent's Self-Reported Summary
%s

## Agent Output (last %d characters)
%s

## Instructions
Evaluate whether the agent made a genuine attempt to complete the task.
PASS if: the agent wrote code, ran tests, and reported on the outcome.
RETRY if: the agent clearly failed to attempt the task, produced no meaningful
output, or explicitly reported it could not complete the work.

When in doubt, PASS. Do not retry for minor quality issues — only for
clear non-attempts or failures.

Respond with EXACTLY one line:
VERDICT: PASS
or
VERDICT: RETRY <one sentence explaining what was missed>]],
		task,
		summary,
		n,
		output_tail
	)
end

--------------------------------------------------------------------
-- Verdict Parser
--------------------------------------------------------------------

--- Parse the LLM's raw response into a structured verdict.
--- @param raw string  Raw LLM output
--- @return table { verdict = "PASS"|"RETRY", reason = string|nil }
function M._parse_verdict(raw)
	if not raw or raw == "" then
		return { verdict = "PASS" }
	end

	-- Primary: look for "VERDICT: PASS" or "VERDICT: RETRY <reason>"
	local retry_reason = raw:match("VERDICT:%s*RETRY%s+(.-)\n") or raw:match("VERDICT:%s*RETRY%s+(.+)$")
	if retry_reason then
		return { verdict = "RETRY", reason = vim.trim(retry_reason) }
	end

	if raw:match("VERDICT:%s*PASS") then
		return { verdict = "PASS" }
	end

	-- Fallback: look for bare RETRY/PASS anywhere
	if raw:match("RETRY") then
		local reason = raw:match("RETRY%s+(.-)\n") or raw:match("RETRY%s+(.+)$")
		return { verdict = "RETRY", reason = reason and vim.trim(reason) or nil }
	end

	if raw:match("PASS") then
		return { verdict = "PASS" }
	end

	-- Default: fail open
	return { verdict = "PASS" }
end

--------------------------------------------------------------------
-- Wrap on_complete with Reflection
--------------------------------------------------------------------

--- Wrap a caller's on_complete to inject a reflection step.
--- Returns a new on_complete function that, on success, asks an LLM to
--- review the output and optionally retries the task.
---
--- @param original_opts table     The opts passed to agentic.run()
--- @param backend_name string     Backend key (e.g. "claude_code")
--- @param spawn_fn function       function(enhanced_opts) to re-spawn the backend
--- @param caller_on_complete function  The original on_complete(success, data)
--- @return function               Wrapped on_complete(success, data)
function M.wrap(original_opts, backend_name, spawn_fn, caller_on_complete)
	local retry_count = 0

	local function wrapped_on_complete(success, data)
		-- Failures pass through immediately — reflection is only for successful runs
		if not success then
			caller_on_complete(false, data)
			return
		end

		-- Check config at call time (supports hot-reload)
		local cfg = require("dwight").config
		local ac = cfg.agentic_opts or {}
		if not ac.reflection then
			caller_on_complete(true, data)
			return
		end

		-- Build reflection prompt
		local task = original_opts.task or ""
		local summary = (data.summary or ""):sub(1, 500)
		local output_tail = (data.output or ""):sub(-M.OUTPUT_TAIL_CHARS)
		local prompt = M._build_prompt(task, summary, output_tail)

		-- Ask the LLM to review
		local skills = require("dwight.skills")
		skills._run_llm(prompt, function(raw, code)
			-- LLM error → fail open
			if code ~= 0 or not raw or raw == "" then
				data.reflection_verdict = "LLM_ERROR"
				caller_on_complete(true, data)
				return
			end

			local verdict = M._parse_verdict(raw)

			if verdict.verdict == "PASS" then
				data.reflection_verdict = "PASS"
				caller_on_complete(true, data)
				return
			end

			-- RETRY
			if retry_count < M.MAX_RETRIES then
				retry_count = retry_count + 1

				-- Build enhanced task with retry context
				local enhanced_task = string.format(
					[[## Retry Context (attempt %d)
A previous attempt was reviewed and found insufficient.
Reviewer feedback: %s
Previous agent summary: %s
Focus on addressing the gap identified above.

%s]],
					retry_count + 1,
					verdict.reason or "unspecified",
					summary,
					task
				)

				-- Re-spawn with enhanced opts
				local enhanced_opts = {}
				for k, v in pairs(original_opts) do
					enhanced_opts[k] = v
				end
				enhanced_opts.task = enhanced_task
				enhanced_opts.on_complete = wrapped_on_complete

				spawn_fn(enhanced_opts)
			else
				-- Retries exhausted — pass through with metadata
				data.reflection_verdict = "RETRY_EXHAUSTED"
				data.reflection_reason = verdict.reason
				caller_on_complete(true, data)
			end
		end)
	end

	return wrapped_on_complete
end

return M
