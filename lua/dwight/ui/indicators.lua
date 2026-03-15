-- dwight/ui/indicators.lua
-- Per-job processing indicators (spinners, signs, extmarks).

local M = {}

local api = vim.api

local _job_indicators = {}
local spinner_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

function M.show_indicators(job_id, bufnr, start_line, end_line)
	if not api.nvim_buf_is_valid(bufnr) then
		return
	end
	local cfg = require("dwight").config
	local ns = api.nvim_create_namespace("dwight_job_" .. job_id)
	local sign_group = "dwight_job_" .. job_id
	local style = cfg.indicator_style

	if style == "sign" or style == "both" then
		for lnum = start_line, end_line do
			pcall(vim.fn.sign_place, 0, sign_group, "DwightProcessing", bufnr, { lnum = lnum })
		end
	end

	local frame = 1
	local timer = (vim.loop or vim.uv).new_timer()
	_job_indicators[job_id] = {
		ns = ns,
		sign_group = sign_group,
		timer = timer,
		bufnr = bufnr,
		start_line = start_line,
		end_line = end_line,
	}

	timer:start(
		0,
		120,
		vim.schedule_wrap(function()
			if not api.nvim_buf_is_valid(bufnr) then
				M.clear_indicators(job_id)
				return
			end
			api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
			local ind = _job_indicators[job_id]
			if not ind then
				return
			end
			local icon = spinner_frames[frame]
			local label = ind.custom_label or string.format("#%d processing…", job_id)
			local text = string.format(" %s %s", icon, label)
			for _, lnum in ipairs({ ind.start_line, ind.end_line }) do
				pcall(api.nvim_buf_set_extmark, bufnr, ns, lnum - 1, 0, {
					virt_text = { { text, "DwightProcessing" } },
					virt_text_pos = "eol",
				})
			end
			frame = frame % #spinner_frames + 1
		end)
	)
end

function M.clear_indicators(job_id)
	local ind = _job_indicators[job_id]
	if not ind then
		return
	end
	pcall(function()
		ind.timer:stop()
		ind.timer:close()
	end)
	if api.nvim_buf_is_valid(ind.bufnr) then
		api.nvim_buf_clear_namespace(ind.bufnr, ind.ns, 0, -1)
	end
	pcall(vim.fn.sign_unplace, ind.sign_group, { buffer = ind.bufnr })
	_job_indicators[job_id] = nil
end

function M.update_indicator_range(job_id, new_start, new_end)
	local ind = _job_indicators[job_id]
	if ind then
		ind.start_line = new_start
		ind.end_line = new_end
	end
end

--- Update the text label shown in the spinning indicator (e.g. streaming progress).
function M.update_indicator_label(job_id, label)
	local ind = _job_indicators[job_id]
	if ind then
		ind.custom_label = label
	end
end

return M
