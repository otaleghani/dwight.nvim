-- dwight/github/cli.lua
-- gh/git CLI wrappers and argument helpers.

local M = {}

local uv = vim.loop or vim.uv

--- Run a gh command asynchronously.
--- callback(output_string, exit_code)
function M.run_gh(args, callback)
	local chunks = {}
	local stderr_chunks = {}
	local stdout = uv.new_pipe(false)
	local stderr = uv.new_pipe(false)

	local handle
	handle = uv.spawn("gh", {
		args = args,
		stdio = { nil, stdout, stderr },
		cwd = vim.fn.getcwd(),
	}, function(code)
		if stdout then
			stdout:close()
		end
		if stderr then
			stderr:close()
		end
		if handle then
			handle:close()
		end
		vim.schedule(function()
			local out = table.concat(chunks, "")
			local err_out = table.concat(stderr_chunks, "")
			if code ~= 0 and out == "" then
				out = err_out
			end
			callback(out, code)
		end)
	end)

	if not handle then
		vim.schedule(function()
			callback("", -1)
		end)
		return
	end

	stdout:read_start(function(err, data)
		if not err and data then
			chunks[#chunks + 1] = data
		end
	end)
	stderr:read_start(function(err, data)
		if not err and data then
			stderr_chunks[#stderr_chunks + 1] = data
		end
	end)
end

--- Run gh synchronously (with timeout).
function M.run_gh_sync(args, timeout_ms)
	local result, code_out, done = nil, nil, false
	M.run_gh(args, function(out, code)
		result = out
		code_out = code
		done = true
	end)
	vim.wait(timeout_ms or 10000, function()
		return done
	end, 50)
	return result, code_out
end

--- Run a git command synchronously.
function M.run_git_sync(args, timeout_ms)
	local chunks = {}
	local stdout = uv.new_pipe(false)
	local result, done = nil, false

	local handle
	handle = uv.spawn("git", {
		args = args,
		stdio = { nil, stdout, nil },
		cwd = vim.fn.getcwd(),
	}, function(code)
		if stdout then
			stdout:close()
		end
		if handle then
			handle:close()
		end
		vim.schedule(function()
			result = code == 0 and table.concat(chunks, "") or nil
			done = true
		end)
	end)
	if not handle then
		return nil
	end
	stdout:read_start(function(err, data)
		if not err and data then
			chunks[#chunks + 1] = data
		end
	end)
	vim.wait(timeout_ms or 5000, function()
		return done
	end, 50)
	return result
end

--- Parse cross-repo reference: "owner/repo#42" -> { repo = "owner/repo", number = 42 }
--- Also handles: "42", "#42", "--repo owner/repo 42"
function M.parse_issue_ref(raw)
	if not raw or raw == "" then
		return {}
	end
	-- owner/repo#42
	local repo, num = raw:match("^([%w%-%.]+/[%w%-%.]+)#(%d+)$")
	if repo and num then
		return { repo = repo, number = tonumber(num) }
	end
	-- Just a number
	num = raw:match("^#?(%d+)$")
	if num then
		return { number = tonumber(num) }
	end
	return {}
end

--- Build repo flag args for gh CLI.
--- Returns a table of args to prepend, e.g. {"-R", "owner/repo"} or {}.
function M.repo_flag(repo)
	if not repo or repo == "" then
		return {}
	end
	return { "-R", repo }
end

return M
