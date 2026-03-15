-- dwight/ui/init.lua
-- Re-exports the exact same public API as the original flat ui.lua module.

local M = {}

--------------------------------------------------------------------
-- Shared mutable state
--------------------------------------------------------------------

M._source_bufnr = nil

--------------------------------------------------------------------
-- Re-exports
--------------------------------------------------------------------

function M.get_visual_selection()
	return require("dwight.ui.selection").get_visual_selection()
end

function M.show_indicators(job_id, bufnr, start_line, end_line)
	return require("dwight.ui.indicators").show_indicators(job_id, bufnr, start_line, end_line)
end

function M.clear_indicators(job_id)
	return require("dwight.ui.indicators").clear_indicators(job_id)
end

function M.update_indicator_range(job_id, new_start, new_end)
	return require("dwight.ui.indicators").update_indicator_range(job_id, new_start, new_end)
end

function M.update_indicator_label(job_id, label)
	return require("dwight.ui.indicators").update_indicator_label(job_id, label)
end

function M.parse_tokens(text)
	return require("dwight.ui.tokens").parse_tokens(text)
end

function M.omnifunc(findstart, base)
	return require("dwight.ui.completion").omnifunc(findstart, base)
end

function M.open_prompt(selection, opts)
	return require("dwight.ui.prompt").open_prompt(selection, opts)
end

--------------------------------------------------------------------
-- Constants re-exported for backward compat
--------------------------------------------------------------------

M.EDITABLE_LINES = require("dwight.ui.prompt").EDITABLE_LINES

return M
