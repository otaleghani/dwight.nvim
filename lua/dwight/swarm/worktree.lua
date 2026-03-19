-- dwight/swarm/worktree.lua
-- Git worktree operations for parallel agent isolation.
-- Each swarm task runs in its own worktree so agents don't conflict.

local M = {}

local uv = vim.loop or vim.uv

--------------------------------------------------------------------
-- Git sync helper (reuses auto/git pattern, adds cwd param)
--------------------------------------------------------------------

--- Run a git command synchronously. Returns (output, exit_code).
--- @param args table Git subcommand + args
--- @param timeout_ms number|nil Timeout in ms (default 5000)
--- @param cwd string|nil Working directory (default vim.fn.getcwd())
function M.git_sync(args, timeout_ms, cwd)
	local result, code_out, done = nil, nil, false
	local chunks = {}
	local stdout = uv.new_pipe(false)
	local handle
	handle = uv.spawn("git", {
		args = args,
		stdio = { nil, stdout, nil },
		cwd = cwd or vim.fn.getcwd(),
	}, function(code)
		if stdout then
			stdout:close()
		end
		if handle then
			handle:close()
		end
		vim.schedule(function()
			result = table.concat(chunks, "")
			code_out = code
			done = true
		end)
	end)
	if not handle then
		return nil, -1
	end
	stdout:read_start(function(e, d)
		if not e and d then
			chunks[#chunks + 1] = d
		end
	end)
	vim.wait(timeout_ms or 5000, function()
		return done
	end, 50)
	-- Kill the process if it's still running after timeout
	if not done and handle and not handle:is_closing() then
		pcall(function()
			handle:kill("sigkill")
		end)
	end
	return result, code_out or -1
end

--------------------------------------------------------------------
-- Stale merge state detection
--------------------------------------------------------------------

--- Check for and abort any dangling merge state left by a crash.
--- Should be called at the start of each wave to ensure clean git state.
--- @return boolean aborted True if a stale merge was detected and aborted
function M.check_merge_state()
	local git_dir = vim.fn.finddir(".git", vim.fn.getcwd())
	if git_dir == "" then
		return false
	end
	local merge_head = git_dir .. "/MERGE_HEAD"
	if vim.fn.filereadable(merge_head) == 1 then
		M.git_sync({ "merge", "--abort" }, 5000)
		return true
	end
	return false
end

--------------------------------------------------------------------
-- Worktree base directory
--------------------------------------------------------------------

--- Get the base directory for swarm worktrees.
--- Returns the path (creates it if needed).
function M.base_dir()
	local project = require("dwight.project")
	local base
	if project.is_initialized() then
		base = project.dir() .. "/worktrees"
	else
		base = vim.fn.getcwd() .. "/.dwight/worktrees"
	end
	vim.fn.mkdir(base, "p")
	return base
end

--------------------------------------------------------------------
-- Create worktree
--------------------------------------------------------------------

--- Create a git worktree for a swarm task.
--- @param wave_num number Wave index (1-based)
--- @param task_idx number Task index within the wave (1-based)
--- @return string|nil path Path to the created worktree, or nil on failure
--- @return string|nil error Error message on failure
function M.create(wave_num, task_idx)
	local base = M.base_dir()
	local branch = string.format("dwight-swarm/wave-%d-task-%d", wave_num, task_idx)
	local wt_path = string.format("%s/wave-%d-task-%d", base, wave_num, task_idx)

	-- Remove stale worktree at this path if it exists
	M.remove(wt_path)

	-- Create worktree with a new branch
	local out, code = M.git_sync({ "worktree", "add", wt_path, "-b", branch }, 10000)
	if code ~= 0 then
		-- Branch might already exist — try without -b
		local out2, code2 = M.git_sync({ "worktree", "add", wt_path, branch }, 10000)
		if code2 ~= 0 then
			return nil, string.format("git worktree add failed: %s", (out2 or out or ""):sub(1, 200))
		end
	end

	return wt_path, nil
end

--------------------------------------------------------------------
-- Remove worktree
--------------------------------------------------------------------

--- Remove a worktree and its branch.
--- Retries once after 500ms if the first attempt fails (locked files, NFS, etc.).
--- @param wt_path string Worktree path
function M.remove(wt_path)
	-- Prune stale worktree references first
	M.git_sync({ "worktree", "prune" }, 5000)

	-- Remove worktree (--force to handle uncommitted changes)
	local _, code = M.git_sync({ "worktree", "remove", wt_path, "--force" }, 10000)
	if code ~= 0 then
		-- Retry once after a brief pause (handles locked files, NFS delays)
		vim.wait(500, function()
			return false
		end, 500)
		M.git_sync({ "worktree", "remove", wt_path, "--force" }, 10000)
	end

	-- Extract branch name from path and delete it
	local branch = wt_path:match("(dwight%-swarm/.*)$")
	if not branch then
		-- Try extracting from the directory name
		local wave, task = wt_path:match("wave%-(%d+)%-task%-(%d+)$")
		if wave and task then
			branch = string.format("dwight-swarm/wave-%s-task-%s", wave, task)
		end
	end
	if branch then
		M.git_sync({ "branch", "-D", branch }, 5000)
	end
end

--------------------------------------------------------------------
-- Cleanup stale swarm worktrees (pre-wave safety)
--------------------------------------------------------------------

--- Prune and remove any stale dwight-swarm worktrees.
--- Called at the top of _execute_wave to ensure a clean slate.
function M.cleanup_stale()
	M.git_sync({ "worktree", "prune" }, 5000)

	local raw, code = M.git_sync({ "worktree", "list", "--porcelain" }, 5000)
	if code ~= 0 or not raw then
		return
	end

	for path in raw:gmatch("worktree ([^\n]+)") do
		if path:match("dwight%-swarm/") or path:match("dwight%-swarm[/\\]") then
			M.remove(path)
		end
	end
end

--------------------------------------------------------------------
-- Cleanup all swarm worktrees
--------------------------------------------------------------------

--- Remove all worktrees under the swarm base directory.
function M.cleanup_all()
	local base = M.base_dir()

	-- List all worktrees
	local raw, code = M.git_sync({ "worktree", "list", "--porcelain" }, 5000)
	if code ~= 0 or not raw then
		return
	end

	-- Parse worktree paths that are under our base dir
	for path in raw:gmatch("worktree ([^\n]+)") do
		if path:find(base, 1, true) then
			M.remove(path)
		end
	end

	-- Final prune
	M.git_sync({ "worktree", "prune" }, 5000)

	-- Remove empty base dir
	pcall(function()
		vim.fn.delete(base, "rf")
	end)
end

--------------------------------------------------------------------
-- List active worktrees
--------------------------------------------------------------------

--- List all swarm worktrees.
--- @return table List of { path, branch } tables
function M.list()
	local base = M.base_dir()
	local result = {}

	local raw, code = M.git_sync({ "worktree", "list", "--porcelain" }, 5000)
	if code ~= 0 or not raw then
		return result
	end

	local current_path = nil
	for line in raw:gmatch("[^\n]+") do
		local p = line:match("^worktree (.+)")
		if p then
			current_path = p
		end
		local b = line:match("^branch (.+)")
		if b and current_path and current_path:find(base, 1, true) then
			result[#result + 1] = { path = current_path, branch = b }
			current_path = nil
		end
	end

	return result
end

--------------------------------------------------------------------
-- Commit changes in a worktree
--------------------------------------------------------------------

--- Stage and commit all changes in a worktree.
--- @param wt_path string Worktree path
--- @param message string Commit message
--- @return boolean success
function M.commit(wt_path, message)
	-- Check for changes
	local diff_out, _ = M.git_sync({ "status", "--porcelain" }, 3000, wt_path)
	if not diff_out or vim.trim(diff_out) == "" then
		return true -- nothing to commit, not an error
	end

	-- Stage all
	local _, add_code = M.git_sync({ "add", "-A" }, 5000, wt_path)
	if add_code ~= 0 then
		return false
	end

	-- Commit
	local _, commit_code = M.git_sync({ "commit", "-m", message, "--no-verify" }, 10000, wt_path)
	return commit_code == 0
end

--------------------------------------------------------------------
-- Pre-merge overlap detection
--------------------------------------------------------------------

--- Get the list of files actually changed in a worktree.
--- After commit, working tree matches HEAD so we must diff against
--- the base SHA (the commit the worktree branched from).
--- @param wt_path string Worktree path
--- @param base_ref string|nil Base ref to diff against (e.g. SHA before worktree was created)
--- @return table List of changed file paths
function M.changed_files(wt_path, base_ref)
	local files = {}

	if base_ref then
		-- Diff committed changes: base..HEAD (works after commit)
		local diff_out, code = M.git_sync({ "diff", "--name-only", base_ref .. "..HEAD" }, 5000, wt_path)
		if code == 0 and diff_out then
			for f in diff_out:gmatch("[^\n]+") do
				local trimmed = vim.trim(f)
				if trimmed ~= "" then
					files[#files + 1] = trimmed
				end
			end
		end
	else
		-- Fallback: uncommitted changes (staged + unstaged vs HEAD)
		local diff_out, code = M.git_sync({ "diff", "--name-only", "HEAD" }, 5000, wt_path)
		if code == 0 and diff_out then
			for f in diff_out:gmatch("[^\n]+") do
				local trimmed = vim.trim(f)
				if trimmed ~= "" then
					files[#files + 1] = trimmed
				end
			end
		end
	end

	-- Untracked new files (not yet committed)
	local ls_out, ls_code = M.git_sync({ "ls-files", "--others", "--exclude-standard" }, 5000, wt_path)
	if ls_code == 0 and ls_out then
		for f in ls_out:gmatch("[^\n]+") do
			local trimmed = vim.trim(f)
			if trimmed ~= "" then
				files[#files + 1] = trimmed
			end
		end
	end

	-- Deduplicate
	local seen = {}
	local unique = {}
	for _, f in ipairs(files) do
		if not seen[f] then
			seen[f] = true
			unique[#unique + 1] = f
		end
	end
	return unique
end

--- Detect files touched by multiple tasks in a wave.
--- @param tasks table List of { task_idx, wt_path }
--- @param base_ref string|nil Base SHA to diff against (pre-worktree creation)
--- @return table overlaps List of { file, task_indices } for files touched by 2+ tasks
--- @return table file_map task_idx -> { files }
function M.detect_overlaps(tasks, base_ref)
	local file_to_tasks = {} -- file -> { task_idx, ... }
	local file_map = {} -- task_idx -> { files }

	for _, t in ipairs(tasks) do
		local files = M.changed_files(t.wt_path, base_ref)
		file_map[t.task_idx] = files
		for _, f in ipairs(files) do
			if not file_to_tasks[f] then
				file_to_tasks[f] = {}
			end
			file_to_tasks[f][#file_to_tasks[f] + 1] = t.task_idx
		end
	end

	local overlaps = {}
	for file, task_indices in pairs(file_to_tasks) do
		if #task_indices > 1 then
			overlaps[#overlaps + 1] = { file = file, task_indices = task_indices }
		end
	end
	-- Sort by filename for deterministic output
	table.sort(overlaps, function(a, b)
		return a.file < b.file
	end)

	return overlaps, file_map
end

--- Order tasks for merge: fewest overlaps first.
--- Tasks with unique-only files merge first; heavily overlapping tasks merge last.
--- @param tasks table List of batch entries with task_idx
--- @param overlaps table From detect_overlaps
--- @return table Reordered tasks
function M.order_for_merge(tasks, overlaps)
	-- Count overlap involvement per task_idx
	local overlap_count = {}
	for _, o in ipairs(overlaps) do
		for _, idx in ipairs(o.task_indices) do
			overlap_count[idx] = (overlap_count[idx] or 0) + 1
		end
	end

	-- Copy and sort
	local sorted = {}
	for _, t in ipairs(tasks) do
		sorted[#sorted + 1] = t
	end
	table.sort(sorted, function(a, b)
		return (overlap_count[a.task_idx] or 0) < (overlap_count[b.task_idx] or 0)
	end)

	return sorted
end

--------------------------------------------------------------------
-- Conflict file helpers (for auto-resolution)
--------------------------------------------------------------------

--- Read conflict files from a failed merge (UU/AA entries in git status).
--- Must be called while the merge is still in-progress (before --abort).
--- @return table List of { path = string, content = string }
function M._read_conflict_files()
	local status_out, code = M.git_sync({ "status", "--porcelain" }, 3000)
	if code ~= 0 or not status_out then
		return {}
	end

	local files = {}
	for line in status_out:gmatch("[^\n]+") do
		local xy, path = line:match("^(..) (.+)")
		if xy and (xy == "UU" or xy == "AA") then
			-- Read the file with conflict markers
			local full_path = vim.fn.getcwd() .. "/" .. path
			local f = io.open(full_path, "r")
			if f then
				local content = f:read("*a")
				f:close()
				files[#files + 1] = { path = path, content = content }
			end
		end
	end
	return files
end

--- Build a prompt for the LLM to resolve merge conflicts.
--- @param conflict_files table From _read_conflict_files
--- @param wave_num number
--- @param task_idx number
--- @return string prompt
function M._build_resolution_prompt(conflict_files, wave_num, task_idx)
	local parts = {
		"You are resolving merge conflicts from a parallel swarm task.",
		string.format(
			"Wave %d, task %d produced changes that conflict with previously merged work.",
			wave_num,
			task_idx
		),
		"",
		"For each conflicted file below, produce a resolved version that preserves the intent of BOTH sides.",
		"Remove all conflict markers (<<<<<<< ======= >>>>>>>).",
		"Output ONLY the resolved files in the exact format shown.",
		"",
	}

	for _, cf in ipairs(conflict_files) do
		parts[#parts + 1] = string.format('<conflicted path="%s">', cf.path)
		parts[#parts + 1] = cf.content
		parts[#parts + 1] = "</conflicted>"
		parts[#parts + 1] = ""
	end

	parts[#parts + 1] = "Respond with resolved files, one per block:"
	parts[#parts + 1] = '<resolved path="filename">...resolved content...</resolved>'
	parts[#parts + 1] = ""
	parts[#parts + 1] = "CRITICAL: Do NOT include any conflict markers in your output."

	return table.concat(parts, "\n")
end

--- Parse resolved file blocks from LLM output.
--- @param raw string LLM response
--- @return table|nil List of { path, content }, or nil if markers remain
function M._parse_resolutions(raw)
	local results = {}
	for path, content in raw:gmatch('<resolved%s+path="([^"]+)">(.-)</resolved>') do
		-- Validate no conflict markers remain
		if content:match("^<<<<<<< ") or content:match("\n<<<<<<< ") then
			return nil
		end
		if content:match("^=======$") or content:match("\n=======$") then
			return nil
		end
		if content:match("^>>>>>>> ") or content:match("\n>>>>>>> ") then
			return nil
		end
		-- Strip leading/trailing whitespace from content
		content = content:match("^\n?(.-)%s*$") or content
		results[#results + 1] = { path = path, content = content }
	end
	if #results == 0 then
		return nil
	end
	return results
end

--- Attempt LLM-based conflict resolution.
--- @param conflict_files table From _read_conflict_files
--- @param wave_num number
--- @param task_idx number
--- @param callback function(success, info)
function M._try_llm_resolve(conflict_files, wave_num, task_idx, callback)
	local prompt = M._build_resolution_prompt(conflict_files, wave_num, task_idx)
	local agentic = require("dwight.agentic")

	agentic.run({
		task = prompt,
		context = "",
		on_status = function() end,
		on_tool = function() end,
		on_complete = function(success, data)
			if not success then
				callback(false, { error = "LLM resolution call failed" })
				return
			end

			local raw = data and data.summary or ""
			local resolutions = M._parse_resolutions(raw)
			if not resolutions then
				callback(false, { error = "LLM output contained conflict markers or was unparseable" })
				return
			end

			-- Write resolved files
			for _, r in ipairs(resolutions) do
				local full_path = vim.fn.getcwd() .. "/" .. r.path
				local f = io.open(full_path, "w")
				if f then
					f:write(r.content)
					f:close()
				else
					callback(false, { error = "Could not write resolved file: " .. r.path })
					return
				end
			end

			-- Stage resolved files and complete merge
			for _, r in ipairs(resolutions) do
				M.git_sync({ "add", r.path }, 3000)
			end
			local _, commit_code = M.git_sync({ "commit", "--no-edit", "--no-verify" }, 10000)
			if commit_code ~= 0 then
				callback(false, { error = "git commit after resolution failed" })
				return
			end

			callback(true, {
				resolved_files = vim.tbl_map(function(r)
					return r.path
				end, resolutions),
			})
		end,
	})
end

--------------------------------------------------------------------
-- Merge worktree branch back into current branch
--------------------------------------------------------------------

--- Merge a worktree's branch into the current branch (sync, backward-compat).
--- @param wt_path string Worktree path (used to derive branch name)
--- @param wave_num number Wave index
--- @param task_idx number Task index within wave
--- @return boolean success
--- @return string|nil error Error message on failure
function M.merge(wt_path, wave_num, task_idx)
	local branch = string.format("dwight-swarm/wave-%d-task-%d", wave_num, task_idx)

	local out, code = M.git_sync(
		{ "merge", "--no-ff", "-m", string.format("merge: swarm wave %d task %d", wave_num, task_idx), branch },
		30000
	)

	if code ~= 0 then
		local status_out, _ = M.git_sync({ "status", "--porcelain" }, 3000)
		local has_conflict = status_out and (status_out:match("^UU") or status_out:match("\nUU"))

		if has_conflict then
			M.git_sync({ "merge", "--abort" }, 5000)
			return false, "merge conflict"
		end

		return false, string.format("merge failed: %s", (out or ""):sub(1, 200))
	end

	return true, nil
end

--- Async merge with optional LLM auto-resolution.
--- @param wt_path string Worktree path
--- @param wave_num number
--- @param task_idx number
--- @param opts table { auto_resolve = bool }
--- @param callback function(success, error_msg, conflict_files)
function M.merge_async(wt_path, wave_num, task_idx, opts, callback)
	local branch = string.format("dwight-swarm/wave-%d-task-%d", wave_num, task_idx)
	local called_back = false

	-- Safety net timeout for the entire merge → resolve → commit chain.
	-- Default 120s, configurable via merge_timeout in swarm_opts.
	local merge_timeout_ms = (opts.merge_timeout or 120) * 1000
	local merge_timer = uv.new_timer()
	merge_timer:start(merge_timeout_ms, 0, function()
		merge_timer:close()
		if called_back then
			return
		end
		called_back = true
		-- Abort any in-progress resolution agent
		pcall(function()
			require("dwight.agentic").abort()
		end)
		-- Abort the merge itself
		M.git_sync({ "merge", "--abort" }, 5000)
		vim.schedule(function()
			callback(false, "merge operation timed out", nil)
		end)
	end)

	local function safe_callback(ok, err, cfiles)
		if called_back then
			return
		end
		called_back = true
		if merge_timer and not merge_timer:is_closing() then
			merge_timer:close()
		end
		callback(ok, err, cfiles)
	end

	local out, code = M.git_sync(
		{ "merge", "--no-ff", "-m", string.format("merge: swarm wave %d task %d", wave_num, task_idx), branch },
		30000
	)

	if code == 0 then
		safe_callback(true, nil, nil)
		return
	end

	-- Check for conflict
	local status_out, _ = M.git_sync({ "status", "--porcelain" }, 3000)
	local has_conflict = status_out and (status_out:match("^UU") or status_out:match("\nUU"))

	if not has_conflict then
		safe_callback(false, string.format("merge failed: %s", (out or ""):sub(1, 200)), nil)
		return
	end

	-- Read conflict files before any abort
	local conflict_files = M._read_conflict_files()

	if opts.auto_resolve then
		-- Attempt LLM resolution (merge stays in-progress)
		M._try_llm_resolve(conflict_files, wave_num, task_idx, function(resolved, info)
			if resolved then
				safe_callback(true, nil, nil)
			else
				-- Resolution failed — abort merge
				M.git_sync({ "merge", "--abort" }, 5000)
				safe_callback(false, info and info.error or "LLM resolution failed", conflict_files)
			end
		end)
	else
		-- No auto-resolve — abort and report
		M.git_sync({ "merge", "--abort" }, 5000)
		safe_callback(false, "merge conflict", conflict_files)
	end
end

--------------------------------------------------------------------
-- Conflict diagnostics
--------------------------------------------------------------------

--- Build display lines for a merge conflict diagnostic.
--- @param conflict_files table From _read_conflict_files: { { path, content }, ... }
--- @param file_map table task_idx -> { files } from detect_overlaps
--- @param successes table List of batch entries with task_idx and title
--- @return table List of display lines
function M.build_conflict_diagnostic(conflict_files, file_map, successes)
	local lines = {}

	-- Build reverse map: file -> task titles
	local file_to_titles = {}
	for _, s in ipairs(successes) do
		local files = file_map[s.task_idx] or {}
		for _, f in ipairs(files) do
			if not file_to_titles[f] then
				file_to_titles[f] = {}
			end
			file_to_titles[f][#file_to_titles[f] + 1] = s.title or ("task " .. s.task_idx)
		end
	end

	lines[#lines + 1] = string.format("%d conflicted file(s):", #conflict_files)

	for _, cf in ipairs(conflict_files) do
		lines[#lines + 1] = ""
		local owners = file_to_titles[cf.path]
		if owners and #owners > 0 then
			lines[#lines + 1] = string.format("  %s  (modified by: %s)", cf.path, table.concat(owners, ", "))
		else
			lines[#lines + 1] = string.format("  %s", cf.path)
		end

		-- Show first conflict snippet (up to 6 lines around first marker)
		local snippet_lines = {}
		local in_snippet = false
		local snippet_count = 0
		for line in cf.content:gmatch("[^\n]*") do
			if not in_snippet and line:match("^<<<<<<< ") then
				in_snippet = true
			end
			if in_snippet then
				snippet_lines[#snippet_lines + 1] = "    " .. line
				snippet_count = snippet_count + 1
				if snippet_count >= 6 then
					snippet_lines[#snippet_lines + 1] = "    ..."
					break
				end
				if line:match("^>>>>>>> ") then
					break
				end
			end
		end
		if #snippet_lines > 0 then
			for _, sl in ipairs(snippet_lines) do
				lines[#lines + 1] = sl
			end
		end
	end

	return lines
end

--------------------------------------------------------------------
-- Record base SHA for rollback
--------------------------------------------------------------------

--- Get the current HEAD SHA.
--- @return string|nil sha
function M.head_sha()
	local out, code = M.git_sync({ "rev-parse", "HEAD" }, 2000)
	if code == 0 and out then
		return vim.trim(out)
	end
	return nil
end

--- Rollback to a specific SHA (hard reset).
--- @param sha string Target SHA
--- @return boolean success
function M.rollback(sha)
	local _, code = M.git_sync({ "reset", "--hard", sha }, 5000)
	if code ~= 0 then
		return false
	end
	M.git_sync({ "clean", "-fd" }, 5000)
	return true
end

return M
