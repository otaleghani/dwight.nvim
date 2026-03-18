-- dwight/swarm/state.lua
-- Swarm state persistence: save/load/resume for multi-wave parallel execution.
-- State file: .dwight/swarm/current.json

local M = {}

--------------------------------------------------------------------
-- Directory helpers
--------------------------------------------------------------------

function M.swarm_dir()
	local project = require("dwight.project")
	if project.is_initialized() then
		return project.dir() .. "/swarm"
	end
	return vim.fn.stdpath("data") .. "/dwight/swarm"
end

--------------------------------------------------------------------
-- Save / Load / Clear
--------------------------------------------------------------------

--- Save swarm state for resume.
--- @param state table { request, waves, current_wave, base_sha, wave_results, ... }
function M.save(state)
	local dir = M.swarm_dir()
	vim.fn.mkdir(dir, "p")
	local path = dir .. "/current.json"
	local f = io.open(path, "w")
	if f then
		f:write(vim.json.encode(state))
		f:close()
	end
end

--- Load swarm state.
--- @return table|nil state
function M.load()
	local path = M.swarm_dir() .. "/current.json"
	local f = io.open(path, "r")
	if not f then
		return nil
	end
	local raw = f:read("*a")
	f:close()
	local ok, data = pcall(vim.json.decode, raw)
	if not ok then
		return nil
	end
	return data
end

--- Clear swarm state.
function M.clear()
	pcall(os.remove, M.swarm_dir() .. "/current.json")
end

--------------------------------------------------------------------
-- Session log (markdown summary)
--------------------------------------------------------------------

--- Write a session summary log to .dwight/swarm-logs/
function M.write_log(opts)
	pcall(function()
		local project = require("dwight.project")
		if not project.is_initialized() then
			return
		end

		local log_dir = project.dir() .. "/swarm-logs"
		vim.fn.mkdir(log_dir, "p")

		local timestamp = os.date("%Y%m%d-%H%M%S")
		local success = opts.success and "success" or "failed"
		local path = string.format("%s/%s-%s.md", log_dir, timestamp, success)

		local lines = {}
		lines[#lines + 1] = string.format("# DwightSwarm Session — %s", os.date("%Y-%m-%d %H:%M:%S"))
		lines[#lines + 1] = ""
		lines[#lines + 1] = string.format("**Request:** %s", opts.request or "?")
		lines[#lines + 1] = string.format("**Result:** %s", opts.success and "SUCCESS" or "FAILED")
		lines[#lines + 1] = string.format("**Duration:** %ds", opts.duration or 0)
		lines[#lines + 1] = string.format("**Waves:** %d", opts.total_waves or 0)
		if opts.cost and opts.cost > 0 then
			lines[#lines + 1] = string.format("**Cost:** ~$%.2f", opts.cost)
		end
		lines[#lines + 1] = ""

		-- Per-wave details
		if opts.wave_results then
			for i, wr in ipairs(opts.wave_results) do
				lines[#lines + 1] = string.format("## Wave %d (%ds)", i, wr.duration or 0)
				lines[#lines + 1] = ""

				for _, tr in ipairs(wr.task_results or {}) do
					local icon = tr.success and "+" or "x"
					lines[#lines + 1] = string.format(
						"- %s **%s** (%ds) %s",
						icon,
						tr.title or "?",
						tr.duration or 0,
						tr.success and "" or ("— " .. (tr.error or "failed"):sub(1, 100))
					)
				end
				lines[#lines + 1] = ""
			end
		end

		-- Failed wave info
		if opts.failed_wave then
			lines[#lines + 1] = "## Failure Details"
			lines[#lines + 1] = ""
			lines[#lines + 1] = string.format("Failed at wave %d", opts.failed_wave)
			if opts.failed_error then
				lines[#lines + 1] = "Error: " .. opts.failed_error:sub(1, 500)
			end
			lines[#lines + 1] = ""
		end

		local f = io.open(path, "w")
		if f then
			f:write(table.concat(lines, "\n"))
			f:close()
		end
	end)
end

return M
