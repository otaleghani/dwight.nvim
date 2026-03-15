-- dwight/agent/diff.lua
-- Post-session diff review and quickfix population.

local M = {}

local _flatten = require("dwight.util").flatten_lines

--------------------------------------------------------------------
-- Post-session diff review
--------------------------------------------------------------------

--- Show git diff summary after an agent session completes.
--- Appends a summary to the status buffer and populates quickfix with changed files.
function M._show_post_diff(status_mod, pre_head)
	if not pre_head then
		return
	end

	-- Determine diff range: committed changes or working tree
	local diff_ref = pre_head .. "..HEAD"
	local stat = vim.fn.system("git diff --stat " .. diff_ref .. " 2>/dev/null")
	local using_worktree = false
	if vim.v.shell_error ~= 0 or not stat or vim.trim(stat) == "" then
		diff_ref = "HEAD"
		stat = vim.fn.system("git diff --stat HEAD 2>/dev/null")
		using_worktree = true
	end

	-- Check for new untracked files early (git diff misses these)
	local untracked = vim.fn.system("git ls-files --others --exclude-standard 2>/dev/null")
	local untracked_files = {}
	if untracked and vim.trim(untracked) ~= "" then
		for fname in untracked:gmatch("[^\n]+") do
			fname = vim.trim(fname)
			if fname ~= "" and not fname:match("^%.dwight/") and not fname:match("%.db$") then
				untracked_files[#untracked_files + 1] = fname
			end
		end
	end

	local has_stat = stat and vim.trim(stat) ~= ""
	local has_new = #untracked_files > 0

	-- Nothing changed at all
	if not has_stat and not has_new then
		return
	end

	if using_worktree then
		status_mod.append("")
		status_mod.append("Uncommitted changes:")
	else
		status_mod.append("")
		status_mod.append("Changes since session start:")
	end

	-- Show compact diff stat (tracked changes)
	if has_stat then
		local line_count = 0
		for line in stat:gmatch("[^\n]+") do
			if line_count < 15 then
				status_mod.append("  " .. line)
			end
			line_count = line_count + 1
		end
		if line_count > 15 then
			status_mod.append(string.format("  ... and %d more files", line_count - 15))
		end
	end

	-- Show new untracked files
	if has_new then
		for i, fname in ipairs(untracked_files) do
			if i <= 10 then
				status_mod.append("  " .. fname .. " (new)")
			end
		end
		if #untracked_files > 10 then
			status_mod.append(string.format("  ... and %d more new files", #untracked_files - 10))
		end
	end

	-- Store for :DwightDiffReview
	M._last_pre_head = pre_head

	-- Build quickfix list from changed files with first-changed-line
	local qf_items = {}
	local cwd = vim.fn.getcwd()
	local numstat = vim.fn.system("git diff --numstat " .. diff_ref .. " 2>/dev/null")
	local name_lines = vim.fn.system("git diff --name-only " .. diff_ref .. " 2>/dev/null")

	if name_lines and vim.trim(name_lines) ~= "" then
		for fname in name_lines:gmatch("[^\n]+") do
			fname = vim.trim(fname)
			if fname ~= "" then
				-- Get first changed line number from unified diff
				local lnum = 1
				local file_diff =
					vim.fn.system("git diff " .. diff_ref .. " -- " .. vim.fn.shellescape(fname) .. " 2>/dev/null")
				if file_diff then
					-- Parse first @@ hunk: @@ -old,count +new,count @@
					local new_start = file_diff:match("@@ %-%d+[,%d]* %+(%d+)")
					if new_start then
						lnum = tonumber(new_start) or 1
					end
				end

				-- Count insertions/deletions from numstat
				local ins, del = nil, nil
				if numstat then
					local pattern = "(%d+)%s+(%d+)%s+" .. fname:gsub("[%(%)%.%%%+%-%*%?%[%^%$]", "%%%1")
					ins, del = numstat:match(pattern)
				end
				local stat_text = ""
				if ins and del then
					stat_text = string.format(" (+%s -%s)", ins, del)
				end

				qf_items[#qf_items + 1] = {
					filename = cwd .. "/" .. fname,
					lnum = lnum,
					col = 1,
					text = fname .. stat_text,
				}
			end
		end
	end

	-- Add untracked (new) files to quickfix -- these are created by the agent
	for _, fname in ipairs(untracked_files) do
		qf_items[#qf_items + 1] = {
			filename = cwd .. "/" .. fname,
			lnum = 1,
			col = 1,
			text = fname .. " (new)",
		}
	end

	if #qf_items > 0 then
		vim.fn.setqflist(qf_items, "r")
		vim.fn.setqflist({}, "a", { title = "Dwight: " .. #qf_items .. " file(s) changed" })

		status_mod.append("")
		status_mod.append(string.format("Quickfix: %d file(s) — :copen to review", #qf_items))
		status_mod.append(":DwightDiffReview — full unified diff in a tab")

		-- Auto-open quickfix (non-blocking)
		vim.defer_fn(function()
			vim.cmd("botright copen")
		end, 300)
	end
end

--- Open a full diff buffer showing all changes from the last agent session.
function M.diff_review()
	local pre_head = M._last_pre_head

	-- Try committed changes first, then working tree
	local diff
	if pre_head then
		diff = vim.fn.system("git diff " .. pre_head .. "..HEAD 2>/dev/null")
		if vim.v.shell_error ~= 0 or vim.trim(diff or "") == "" then
			diff = nil
		end
	end
	if not diff then
		diff = vim.fn.system("git diff HEAD 2>/dev/null")
		if vim.v.shell_error ~= 0 or vim.trim(diff or "") == "" then
			vim.notify("[dwight] No changes to review.", vim.log.levels.INFO)
			return
		end
	end

	local buf = vim.api.nvim_create_buf(false, true)
	local lines = vim.split(diff, "\n", { plain = true })
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, _flatten(lines))
	vim.bo[buf].filetype = "diff"
	vim.bo[buf].modifiable = false
	vim.bo[buf].bufhidden = "wipe"
	pcall(function()
		vim.api.nvim_buf_set_name(buf, "dwight://diff-review")
	end)

	vim.cmd("tab split")
	vim.api.nvim_win_set_buf(0, buf)
	vim.wo[0].number = true
	vim.wo[0].wrap = false
	vim.wo[0].foldenable = true
	vim.wo[0].foldmethod = "diff"

	-- Keymap: q to close
	vim.keymap.set("n", "q", function()
		pcall(vim.api.nvim_buf_delete, buf, { force = true })
	end, { buffer = buf, desc = "Close diff review" })

	vim.notify("[dwight] Diff review open. q to close.", vim.log.levels.INFO)
end

return M
