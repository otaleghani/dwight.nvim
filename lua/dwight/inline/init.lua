-- dwight/inline/init.lua
-- Re-exports the exact same public API as the original inline.lua module.

local M = {}

-- Re-export: public entry point (dispatches to the right backend)
function M.run(...)
	return require("dwight.inline.backends").run(...)
end

-- Re-export: apply multi-file changes with quickfix + diff preview
function M.apply_multi_file(...)
	return require("dwight.inline.response").apply_multi_file(...)
end

-- Re-export: apply parsed code to buffer (used by audit callback)
function M._apply_parsed(...)
	return require("dwight.inline.response")._apply_parsed(...)
end

-- Re-export: atomic buffer replacement
function M._replace_selection_atomic(...)
	return require("dwight.inline.buffer")._replace_selection_atomic(...)
end

-- Re-export: pre-apply syntax check
function M._pre_apply_syntax_check(...)
	return require("dwight.inline.parse")._pre_apply_syntax_check(...)
end

return M
