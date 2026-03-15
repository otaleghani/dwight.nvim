-- dwight/inline/jobs.lua
-- Job ID tracking, overlap detection, and adjustment of concurrent jobs.

local M = {}

local function get_dwight()
	return require("dwight")
end

function M.new_job_id()
	return require("dwight.log")._next_id()
end

function M.has_overlap(bufnr, start_line, end_line)
	for _, job in pairs(get_dwight()._active_jobs) do
		if job.bufnr == bufnr and start_line <= job.end_line and end_line >= job.start_line then
			return true
		end
	end
	return false
end

function M.adjust_other_jobs(exclude_id, bufnr, start_line, old_end, new_count)
	local delta = new_count - (old_end - start_line + 1)
	if delta == 0 then
		return
	end
	local ui = require("dwight.ui")
	for id, job in pairs(get_dwight()._active_jobs) do
		if id ~= exclude_id and job.bufnr == bufnr and job.start_line > old_end then
			job.start_line = job.start_line + delta
			job.end_line = job.end_line + delta
			ui.update_indicator_range(id, job.start_line, job.end_line)
		end
	end
end

return M
