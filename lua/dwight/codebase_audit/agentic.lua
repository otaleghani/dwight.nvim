-- dwight/codebase_audit/agentic.lua
-- Phase 2: Agentic deep review (reads files, runs tests, verifies).

local M = {}

--- Build the agentic audit prompt.
--- Gives the agent static analysis findings + file list and instructs it
--- to read files, run tests, verify findings, and produce structured output.
function M.build_audit_prompt(feature_name, feature_files, static_result)
	local lang = require("dwight.languages")
	local detected = lang.detect()
	local test_cmd = lang.test_cmd(detected) or "run tests"
	local coverage = lang.coverage_cmd(detected)

	-- Format static findings as context
	local finding_lines = {}
	for _, f in ipairs(static_result.findings) do
		finding_lines[#finding_lines + 1] =
			string.format("- %s [%s] %s:%d — %s", f.severity.icon, f.category, f.file, f.line, f.message)
	end

	-- Format file list
	local file_list = {}
	for _, fi in ipairs(feature_files) do
		file_list[#file_list + 1] = "  " .. fi.path
	end

	local parts = {}

	parts[#parts + 1] = string.format(
		[[
You are a senior engineer performing a deep code audit of the "$%s" feature.

## Files in this feature
%s

## Static Analysis Results (%d findings)
%s

## Your Task

Perform a thorough audit by doing the following IN ORDER:

### Step 1: Read ALL source files
Read every file listed above. Understand the architecture, data flow, and dependencies.

### Step 2: Run tests and coverage
Run the test suite: `%s`
]],
		feature_name,
		table.concat(file_list, "\n"),
		#static_result.findings,
		#finding_lines > 0 and table.concat(finding_lines, "\n") or "(none)",
		test_cmd
	)

	if coverage then
		parts[#parts + 1] = string.format("Run coverage: `%s`\n", coverage.cmd)
	end

	parts[#parts + 1] = [[
### Step 3: Verify static analysis findings
For each finding above, read the actual code and determine:
- Is this a true positive? Explain WHY the code is problematic.
- Is this a false positive? Mark it as such with a reason.

### Step 4: Find NEW issues the static analysis missed
Look for:
- Logic errors and edge cases
- Race conditions or concurrency issues
- Missing input validation
- API contract violations
- Resource leaks (unclosed files, connections)
- Security vulnerabilities
- Dead code or unreachable branches
- Missing error handling that static analysis couldn't detect
- Inconsistencies with the rest of the codebase

### Step 5: Write structured output
Write your findings to `.dwight/artifacts/audit-result.json` in this EXACT format:
```json
{
  "verified": [
    {"file": "path/to/file.go", "line": 42, "severity": "CRITICAL|WARN|INFO", "category": "category", "message": "description", "fix": "suggested fix"}
  ],
  "false_positives": [
    {"file": "path/to/file.go", "line": 42, "reason": "why this is not an issue"}
  ],
  "new_findings": [
    {"file": "path/to/file.go", "line": 42, "severity": "CRITICAL|WARN|INFO", "category": "category", "message": "description", "fix": "suggested fix"}
  ],
  "test_results": {
    "passed": true,
    "output_summary": "brief summary of test output",
    "coverage_pct": 85.2
  },
  "summary": "2-3 sentence overall assessment"
}
```

IMPORTANT:
- `mkdir -p .dwight/artifacts` before writing
- Use EXACT field names. "fix" should be a specific, actionable suggestion with the code change needed.
- The "line" field must be the actual line number in the current file, not the line from static analysis.
- Do NOT create any other files. Do NOT modify source code. This is READ-ONLY audit.
]]

	return table.concat(parts, "\n")
end

--- Parse the agent's structured audit output from .dwight/artifacts/audit-result.json
--- Returns { verified, false_positives, new_findings, test_results, summary } or nil
function M.parse_agent_audit_result()
	local project = require("dwight.project")
	if not project.is_initialized() then
		return nil
	end

	local path = project.dir() .. "/artifacts/audit-result.json"
	local file = io.open(path, "r")
	if not file then
		return nil
	end
	local raw = file:read("*a")
	file:close()

	-- Clean up — remove the file after reading
	os.remove(path)

	local ok, data = pcall(vim.json.decode, raw)
	if not ok or type(data) ~= "table" then
		return nil
	end
	return data
end

--- Merge agentic results into static analysis result.
--- Removes false positives, updates verified findings with fixes, adds new findings.
function M.merge_agent_results(static_result, agent_data)
	local constants = require("dwight.codebase_audit.constants")
	local SEV = constants.SEV

	if not agent_data then
		return static_result
	end

	-- Index false positives by file:line for fast lookup
	local fp_set = {}
	for _, fp in ipairs(agent_data.false_positives or {}) do
		local key = (fp.file or "") .. ":" .. (fp.line or 0)
		fp_set[key] = fp.reason or "agent verified as false positive"
	end

	-- Index verified findings by file:line for fix suggestions
	local verified_map = {}
	for _, v in ipairs(agent_data.verified or {}) do
		local key = (v.file or "") .. ":" .. (v.line or 0)
		verified_map[key] = v
	end

	-- Filter false positives from static findings, enrich verified ones
	local filtered = {}
	for _, f in ipairs(static_result.findings) do
		local key = f.file .. ":" .. f.line
		if fp_set[key] then
		-- Skip false positive (but count it)
		else
			-- Check if agent verified and has a fix suggestion
			local v = verified_map[key]
			if v then
				f.agent_verified = true
				if v.fix and v.fix ~= "" then
					f.fix = v.fix
				end
				-- Agent may have re-categorized severity
				if v.severity and SEV[v.severity] then
					f.severity = SEV[v.severity]
				end
			end
			filtered[#filtered + 1] = f
		end
	end

	-- Add new findings from the agent
	for _, nf in ipairs(agent_data.new_findings or {}) do
		filtered[#filtered + 1] = {
			severity = SEV[nf.severity] or SEV.WARN,
			category = nf.category or "agent-finding",
			file = nf.file or "",
			line = tonumber(nf.line) or 0,
			message = nf.message or "",
			fix = nf.fix,
			snippet = "",
			agent_verified = true,
		}
	end

	-- Re-sort
	table.sort(filtered, function(a, b)
		if a.severity.sort ~= b.severity.sort then
			return a.severity.sort < b.severity.sort
		end
		if a.file ~= b.file then
			return a.file < b.file
		end
		return a.line < b.line
	end)

	-- Update stats
	static_result.findings = filtered
	static_result.agent_review = {
		verified = #(agent_data.verified or {}),
		false_positives = #(agent_data.false_positives or {}),
		new_findings = #(agent_data.new_findings or {}),
		test_results = agent_data.test_results,
		summary = agent_data.summary,
	}

	return static_result
end

--- Run agentic deep audit on a feature.
--- callback(result) called when done.
function M._agentic_review(feature_name, feature_files, static_result, callback)
	local agentic = require("dwight.agentic")
	local status_mod = require("dwight.agent_status")

	status_mod.open()
	status_mod.start_session("🔍 Deep audit: $" .. feature_name)
	status_mod.append("🔍 Agentic deep audit: $" .. feature_name)
	status_mod.append(
		string.format("   %d files, %d static findings to verify", #feature_files, #static_result.findings)
	)
	status_mod.append("🤖 Starting agent session...")

	local task = M.build_audit_prompt(feature_name, feature_files, static_result)

	local tool_counts = { read = 0, write = 0, run = 0 }

	agentic.run({
		task = task,

		on_status = function(text)
			status_mod.stop_spin()
			status_mod.append(text)
		end,

		on_tool = function(desc)
			local tt = desc:match("^📖") and "read"
				or desc:match("^📝") and "write"
				or desc:match("^🔧 run") and "run"
				or desc:match("^🔍") and "search"
				or "other"
			tool_counts[tt] = (tool_counts[tt] or 0) + 1

			local should_persist = tt == "write"
				or tt == "run"
				or tt == "search"
				or (tt == "read" and (tool_counts.read == 1 or tool_counts.read % 3 == 0))
			if should_persist then
				status_mod.stop_spin()
				status_mod.append(desc)
			end
			status_mod.spin(desc)
		end,

		on_complete = function(success, _data)
			status_mod.stop_spin()

			if not success then
				status_mod.append("❌ Agentic audit failed")
				callback(static_result)
				return
			end

			-- Parse structured output
			local agent_data = M.parse_agent_audit_result()
			if not agent_data then
				status_mod.append("⚠️  Agent did not produce structured output — showing static results only")
				callback(static_result)
				return
			end

			-- Merge agent results
			local merged = M.merge_agent_results(static_result, agent_data)

			local review = merged.agent_review or {}
			status_mod.append("")
			status_mod.append("✅ Deep audit complete:")
			status_mod.append(
				string.format(
					"   Verified: %d  │  False positives: %d  │  New: %d",
					review.verified or 0,
					review.false_positives or 0,
					review.new_findings or 0
				)
			)

			if review.test_results then
				local tr = review.test_results
				local status_icon = tr.passed and "✅" or "❌"
				local cov_str = tr.coverage_pct and string.format(" │ Coverage: %.1f%%", tr.coverage_pct) or ""
				status_mod.append(string.format("   Tests: %s%s", status_icon, cov_str))
			end

			if review.summary then
				status_mod.append("   " .. (review.summary or ""):sub(1, 200))
			end

			callback(merged)
		end,
	})
end

return M
