-- dwight/github/ci.lua
-- CI/CD integration: status, logs, auto-fix, rerun.

local M = {}

--- Fetch CI/check status for the current branch (or a specific PR).
--- callback(checks, err) where checks = { overall, items = { { name, status, conclusion, url, run_id }, ... } }
function M.ci_status(opts, callback)
	local cli = require("dwight.github.cli")
	opts = opts or {}
	local args = cli.repo_flag(opts.repo)

	if opts.pr_number then
		-- Get checks for a specific PR
		vim.list_extend(args, {
			"pr",
			"checks",
			tostring(opts.pr_number),
			"--json",
			"name,state,conclusion,detailsUrl",
		})
	else
		-- Get checks for current branch
		local branch = cli.run_git_sync({ "rev-parse", "--abbrev-ref", "HEAD" }, 1000)
		if not branch then
			callback(nil, "Not on a branch")
			return
		end
		branch = vim.trim(branch)

		-- Use `gh run list` for the current branch
		vim.list_extend(args, {
			"run",
			"list",
			"--branch",
			branch,
			"--limit",
			"10",
			"--json",
			"databaseId,name,status,conclusion,headBranch,event,createdAt,url",
		})
	end

	cli.run_gh(args, function(out, code)
		if code ~= 0 then
			callback(nil, "Failed to fetch CI status: " .. (out or ""):sub(1, 200))
			return
		end

		local ok, data = pcall(vim.json.decode, out)
		if not ok or type(data) ~= "table" then
			callback(nil, "Failed to parse CI status")
			return
		end

		-- Normalize the data (pr checks vs run list have different shapes)
		local items = {}
		local overall = "success" -- default until proven otherwise

		for _, entry in ipairs(data) do
			local status = entry.status or entry.state or "unknown"
			local conclusion = entry.conclusion or ""
			local name = entry.name or "unknown"

			-- Normalize status
			local normalized
			if status == "completed" then
				normalized = conclusion == "success" and "success"
					or conclusion == "failure" and "failure"
					or conclusion == "cancelled" and "cancelled"
					or conclusion == "skipped" and "skipped"
					or "unknown"
			elseif
				status == "in_progress"
				or status == "queued"
				or status == "waiting"
				or status == "pending"
				or status == "requested"
			then
				normalized = "running"
			else
				normalized = status:lower()
			end

			-- Track overall status
			if normalized == "failure" then
				overall = "failure"
			elseif normalized == "running" and overall ~= "failure" then
				overall = "running"
			end

			items[#items + 1] = {
				name = name,
				status = normalized,
				conclusion = conclusion,
				url = entry.url or entry.detailsUrl or "",
				run_id = entry.databaseId,
				event = entry.event,
				created_at = entry.createdAt,
			}
		end

		callback({
			overall = #items > 0 and overall or "none",
			items = items,
			branch = cli.run_git_sync({ "rev-parse", "--abbrev-ref", "HEAD" }, 1000),
		}, nil)
	end)
end

--- Fetch logs for a failed CI run.
--- callback(logs, err)
function M.ci_logs(run_id, opts, callback)
	local cli = require("dwight.github.cli")
	opts = opts or {}
	local args = cli.repo_flag(opts.repo)
	vim.list_extend(args, { "run", "view", tostring(run_id), "--log-failed" })

	cli.run_gh(args, function(out, code)
		if code ~= 0 then
			-- Try full log if --log-failed not available
			local args2 = cli.repo_flag(opts.repo)
			vim.list_extend(args2, { "run", "view", tostring(run_id), "--log" })
			cli.run_gh(args2, function(out2, code2)
				if code2 ~= 0 then
					callback(nil, "Failed to fetch CI logs")
				else
					-- Truncate to last 200 lines (full logs can be huge)
					local lines = vim.split(out2 or "", "\n", { plain = true })
					if #lines > 200 then
						local truncated = {}
						for i = #lines - 199, #lines do
							truncated[#truncated + 1] = lines[i]
						end
						callback(table.concat(truncated, "\n"), nil)
					else
						callback(out2 or "", nil)
					end
				end
			end)
		else
			callback(out or "", nil)
		end
	end)
end

--- Re-run a failed CI workflow.
--- callback(success, msg)
function M.ci_rerun(run_id, opts, callback)
	local cli = require("dwight.github.cli")
	opts = opts or {}
	local args = cli.repo_flag(opts.repo)
	vim.list_extend(args, { "run", "rerun", tostring(run_id), "--failed" })

	cli.run_gh(args, function(out, code)
		if code ~= 0 then
			callback(false, "Re-run failed: " .. (out or ""):sub(1, 200))
		else
			callback(true, "Re-run triggered for run #" .. tostring(run_id))
		end
	end)
end

--- Show CI status in an interactive buffer.
function M.ci_show(opts)
	local api = vim.api
	local cli = require("dwight.github.cli")
	local preflight = require("dwight.github.preflight")
	opts = opts or {}

	local check = preflight.check()
	if not check.ok then
		vim.notify("[dwight] " .. check.detail, vim.log.levels.ERROR)
		return
	end

	vim.notify("[dwight] Fetching CI status...", vim.log.levels.INFO)

	M.ci_status(opts, function(checks, err)
		if err then
			vim.notify("[dwight] " .. err, vim.log.levels.ERROR)
			return
		end

		if not checks or #checks.items == 0 then
			vim.notify("[dwight] No CI runs found for this branch.", vim.log.levels.INFO)
			return
		end

		local branch = checks.branch and vim.trim(checks.branch) or "(unknown)"

		-- Status labels
		local status_labels = {
			success = "[OK]",
			failure = "[FAIL]",
			running = "[RUN]",
			cancelled = "[STOP]",
			skipped = "[SKIP]",
			none = "[--]",
			unknown = "[??]",
		}

		local overall_label = status_labels[checks.overall] or "[??]"

		local lines = {
			"===================================================",
			string.format("  %s CI Status: %s -- %s", overall_label, branch, checks.overall:upper()),
			"===================================================",
			"",
		}

		-- Find failed runs for action picking
		local failed_runs = {}

		for _, item in ipairs(checks.items) do
			local label = status_labels[item.status] or "[??]"
			local created = item.created_at and item.created_at:sub(1, 16):gsub("T", " ") or ""
			lines[#lines + 1] = string.format("  %s %-35s %s", label, item.name:sub(1, 35), created)

			if item.status == "failure" and item.run_id then
				failed_runs[#failed_runs + 1] = item
				lines[#lines + 1] =
					string.format("     Run #%d -- %s", item.run_id, item.url ~= "" and item.url or "(no URL)")
			end
		end

		lines[#lines + 1] = ""
		lines[#lines + 1] = "---------------------------------------------------"

		if #failed_runs > 0 then
			lines[#lines + 1] = "  Keybindings:"
			lines[#lines + 1] = "    l -- View logs for first failed run"
			lines[#lines + 1] = "    f -- Auto-fix: read logs -> fix -> push"
			lines[#lines + 1] = "    r -- Re-run failed workflows"
			lines[#lines + 1] = "    o -- Open in browser"
			lines[#lines + 1] = "    R -- Refresh"
			lines[#lines + 1] = "    q -- Close"
		else
			lines[#lines + 1] = "    o -- Open in browser"
			lines[#lines + 1] = "    R -- Refresh"
			lines[#lines + 1] = "    q -- Close"
		end

		local buf = api.nvim_create_buf(false, true)
		api.nvim_buf_set_name(buf, "dwight://ci-status/" .. branch)
		api.nvim_buf_set_lines(buf, 0, -1, false, require("dwight.util").flatten_lines(lines))
		vim.bo[buf].filetype = "markdown"
		vim.bo[buf].buftype = "nofile"
		vim.bo[buf].modifiable = false
		vim.bo[buf].bufhidden = "wipe"

		vim.cmd("botright split")
		local win = api.nvim_get_current_win()
		api.nvim_win_set_buf(win, buf)
		vim.cmd("resize " .. math.min(#lines + 2, 30))

		-- Keybindings
		local function close()
			pcall(api.nvim_win_close, win, true)
		end

		vim.keymap.set("n", "q", close, { buffer = buf })

		vim.keymap.set("n", "R", function()
			close()
			M.ci_show(opts)
		end, { buffer = buf, desc = "Refresh CI status" })

		vim.keymap.set("n", "o", function()
			if #checks.items > 0 and checks.items[1].url ~= "" then
				vim.fn.system({ "open", checks.items[1].url })
				vim.notify("[dwight] Opened in browser.", vim.log.levels.INFO)
			end
		end, { buffer = buf, desc = "Open in browser" })

		if #failed_runs > 0 then
			local first_failed = failed_runs[1]

			vim.keymap.set("n", "l", function()
				close()
				vim.notify("[dwight] Fetching CI logs for " .. first_failed.name .. "...", vim.log.levels.INFO)
				M.ci_logs(first_failed.run_id, opts, function(logs, log_err)
					if log_err then
						vim.notify("[dwight] " .. log_err, vim.log.levels.ERROR)
						return
					end

					-- Show logs in a buffer
					local log_buf = api.nvim_create_buf(false, true)
					api.nvim_buf_set_name(log_buf, "dwight://ci-logs/" .. first_failed.run_id)
					api.nvim_buf_set_lines(
						log_buf,
						0,
						-1,
						false,
						vim.split(logs or "(no logs)", "\n", { plain = true })
					)
					vim.bo[log_buf].buftype = "nofile"
					vim.bo[log_buf].modifiable = false
					vim.bo[log_buf].bufhidden = "wipe"

					vim.cmd("botright split")
					local log_win = api.nvim_get_current_win()
					api.nvim_win_set_buf(log_win, log_buf)

					vim.keymap.set("n", "q", function()
						pcall(api.nvim_win_close, log_win, true)
					end, { buffer = log_buf })

					vim.keymap.set("n", "f", function()
						pcall(api.nvim_win_close, log_win, true)
						M.ci_fix(first_failed.run_id, opts)
					end, { buffer = log_buf, desc = "Auto-fix from these logs" })
				end)
			end, { buffer = buf, desc = "View CI logs" })

			vim.keymap.set("n", "f", function()
				close()
				M.ci_fix(first_failed.run_id, opts)
			end, { buffer = buf, desc = "Auto-fix CI failure" })

			vim.keymap.set("n", "r", function()
				close()
				vim.notify("[dwight] Re-running failed workflows...", vim.log.levels.INFO)
				for _, fr in ipairs(failed_runs) do
					M.ci_rerun(fr.run_id, opts, function(ok, msg)
						vim.notify("[dwight] " .. msg, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
					end)
				end
			end, { buffer = buf, desc = "Re-run failed workflows" })
		end
	end)
end

--- Auto-fix a CI failure: fetch logs, agent fixes code, push.
function M.ci_fix(run_id, opts)
	local cli = require("dwight.github.cli")
	opts = opts or {}

	vim.notify("[dwight] Fetching CI logs for auto-fix...", vim.log.levels.INFO)

	M.ci_logs(run_id, opts, function(logs, err)
		if err then
			vim.notify("[dwight] " .. err, vim.log.levels.ERROR)
			return
		end

		-- Truncate logs if too long
		if #logs > 40000 then
			logs = "... (truncated -- showing last 40K chars)\n" .. logs:sub(-40000)
		end

		local branch = cli.run_git_sync({ "rev-parse", "--abbrev-ref", "HEAD" }, 1000)
		branch = branch and vim.trim(branch) or "current"

		local prompt = string.format(
			[=[
You are fixing a CI/CD failure. The CI pipeline failed on branch '%s'.

## Failed CI Logs

```
%s
```

## Your Task -- IN ORDER

### Step 1: Analyze the failure
Read the CI logs carefully and identify:
- Which step(s) failed
- The root cause (test failure, lint error, build error, type error, etc.)
- Which file(s) need to be fixed

### Step 2: Read the relevant source files
Read the files mentioned in the error logs to understand the context.

### Step 3: Fix the issue(s)
Apply the minimal fix needed to resolve the CI failure. Common fixes:
- Fix failing test assertions
- Fix lint errors (formatting, unused vars, etc.)
- Fix type errors or missing imports
- Fix build configuration issues
- Update dependency versions if needed

### Step 4: Verify the fix
If there's a way to run the failing check locally (test command, lint command), run it
to verify your fix works before pushing.

### Step 5: Commit and push
After fixing, commit with a descriptive message like:
  "fix: resolve CI failure -- [brief description of what was wrong]"

Then push to the remote.

## Rules
- Make the MINIMUM changes needed to fix CI -- don't refactor unrelated code
- If the fix requires changing tests, make sure the tests still test the right behavior
- If you can't determine the cause from the logs, say so
- Do NOT modify CI config files unless the failure is clearly a config issue
]=],
			branch,
			logs
		)

		vim.notify("[dwight] Starting CI auto-fix agent...", vim.log.levels.INFO)

		local agent = require("dwight.agent")
		agent.run(prompt, {
			plan = false, -- prompt IS the plan
			on_complete = function(success)
				vim.schedule(function()
					if success then
						vim.notify(
							"[dwight] CI fix applied and pushed!\n" .. "Run :DwightCI to check if the new run passes.",
							vim.log.levels.INFO
						)
					else
						vim.notify(
							"[dwight] CI fix had errors. Check :DwightAgentStatus for details.",
							vim.log.levels.WARN
						)
					end
				end)
			end,
		})
	end)
end

--- Show CI status inline after PR creation (called from _offer_pr flow).
function M._show_ci_after_pr(pr_url, opts)
	local cli = require("dwight.github.cli")
	opts = opts or {}

	-- Extract PR number from URL
	local pr_number = pr_url and pr_url:match("/pull/(%d+)")
	if not pr_number then
		return
	end

	-- Wait a bit for CI to start, then poll
	vim.defer_fn(function()
		vim.notify("[dwight] Checking CI status for PR #" .. pr_number .. "...", vim.log.levels.INFO)

		M.ci_status({ pr_number = tonumber(pr_number), repo = opts.repo }, function(checks, err)
			if err then
				return
			end
			if not checks or #checks.items == 0 then
				vim.notify(
					"[dwight] No CI checks found yet for PR #" .. pr_number .. ". They may still be starting.",
					vim.log.levels.INFO
				)
				return
			end

			local status_labels = {
				success = "[OK]",
				failure = "[FAIL]",
				running = "[RUN]",
				cancelled = "[STOP]",
				skipped = "[SKIP]",
				none = "[--]",
			}
			local overall_label = status_labels[checks.overall] or "[??]"

			local parts = {
				string.format("[dwight] %s CI for PR #%s: %s", overall_label, pr_number, checks.overall:upper()),
			}

			for _, item in ipairs(checks.items) do
				local label = status_labels[item.status] or "[??]"
				parts[#parts + 1] = string.format("  %s %s", label, item.name)
			end

			if checks.overall == "failure" then
				parts[#parts + 1] = ""
				parts[#parts + 1] = "Run :DwightCI to see details or press 'f' to auto-fix."
			end

			vim.notify(table.concat(parts, "\n"), vim.log.levels.INFO)
		end)
	end, 5000) -- 5s delay for CI to register
end

return M
