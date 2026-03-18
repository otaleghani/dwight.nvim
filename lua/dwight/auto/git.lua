-- dwight/auto/git.lua
-- Git checkpoints: safe rollback between tasks

local M = {}

local uv = vim.loop or vim.uv

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
	return result, code_out or -1
end

--- Check if the project is a git repo.
function M.is_git_repo()
	local _, code = M.git_sync({ "rev-parse", "--git-dir" }, 2000)
	return code == 0
end

--- Create a git checkpoint after a successful task.
--- Commits all changes with a descriptive message.
--- Returns true if checkpoint was created.
function M._git_checkpoint(task_num, total, title, status)
	if not M.is_git_repo() then
		return false
	end

	-- Check if there are any changes to commit
	local diff_output, _ = M.git_sync({ "status", "--porcelain" }, 3000)
	if not diff_output or vim.trim(diff_output) == "" then
		status.append_hl("  ○ No changes to checkpoint", "DwightDim")
		return true -- not an error, just nothing to commit
	end

	-- Stage all changes
	local _, add_code = M.git_sync({ "add", "-A" }, 5000)
	if add_code ~= 0 then
		status.append_hl("  ✗ Git add failed — skipping checkpoint", "DwightWarn")
		return false
	end

	-- Build a descriptive commit message using integration module (immediate, no LLM)
	local msg
	pcall(function()
		local integration = require("dwight.integration")
		msg = integration.smart_commit_message(task_num, total, title)
	end)
	if not msg or msg == "" then
		msg = string.format("feat: %s", title:sub(1, 65))
	end

	local _, commit_code = M.git_sync({ "commit", "-m", msg, "--no-verify" }, 10000)
	if commit_code ~= 0 then
		status.append_hl("  ✗ Git commit failed — skipping checkpoint", "DwightWarn")
		return false
	end

	-- Show just the first line in the status
	local first_line = msg:match("^([^\n]+)")
	status.append_hl(string.format("  ● Git: %s", first_line), "DwightDim")

	-- Background: upgrade commit message with LLM-generated one (fire-and-forget)
	-- Save the commit hash so we only amend THIS commit, not a later one
	local checkpoint_hash
	pcall(function()
		local h, _ = M.git_sync({ "rev-parse", "HEAD" }, 2000)
		if h then
			checkpoint_hash = vim.trim(h)
		end
	end)

	pcall(function()
		require("dwight.commit").generate_auto(title, task_num, total, function(ai_msg)
			if ai_msg and vim.trim(ai_msg) ~= "" then
				vim.schedule(function()
					pcall(function()
						-- Safety: only amend if HEAD is still our checkpoint commit
						local cur_head, _ = M.git_sync({ "rev-parse", "HEAD" }, 2000)
						if cur_head and checkpoint_hash and vim.trim(cur_head) == checkpoint_hash then
							local _, amend_code =
								M.git_sync({ "commit", "--amend", "-m", ai_msg, "--no-verify" }, 10000)
							if amend_code == 0 then
								local ai_first = ai_msg:match("^([^\n]+)")
								status.append_hl(string.format("  ● Git: %s", ai_first), "DwightDim")
							end
						end
					end)
				end)
			end
		end)
	end)

	return true
end

--- Rollback to the last git checkpoint.
--- Used when a task fails and we want to reset to a clean state.
function M._git_rollback(status)
	if not M.is_git_repo() then
		return false
	end

	-- Reset to last commit (which is the checkpoint)
	local _, code = M.git_sync({ "reset", "--hard", "HEAD" }, 5000)
	if code ~= 0 then
		status.append_hl("  ✗ Git rollback failed", "DwightWarn")
		return false
	end

	-- Clean untracked files too
	M.git_sync({ "clean", "-fd" }, 5000)

	status.append_hl("  ● Rolled back to last checkpoint", "DwightWarn")
	return true
end

return M
