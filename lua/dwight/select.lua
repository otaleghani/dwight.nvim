-- dwight/select.lua
-- Telescope-based selection that works cleanly with noice.nvim.
-- Drop-in replacement for vim.ui.select in Dwight modules.

local M = {}

--- Telescope-powered select. Uses Telescope for 3+ items, vim.ui.select for 2.
--- @param items string[] — display items
--- @param opts table — { prompt: string }
--- @param on_choice function(choice: string|nil, idx: number|nil)
function M.pick(items, opts, on_choice)
	opts = opts or {}
	if not items or #items == 0 then
		on_choice(nil, nil)
		return
	end

	-- For 2 items, a simple confirm-style prompt works better
	if #items == 2 then
		vim.ui.select(items, opts, on_choice)
		return
	end

	-- Use Telescope
	local ok, pickers = pcall(require, "telescope.pickers")
	if not ok then
		-- Fallback if Telescope unavailable
		vim.ui.select(items, opts, on_choice)
		return
	end

	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")

	pickers
		.new({}, {
			prompt_title = opts.prompt or "Select",
			finder = finders.new_table({
				results = items,
			}),
			sorter = conf.generic_sorter({}),
			attach_mappings = function(prompt_bufnr, map)
				actions.select_default:replace(function()
					local selection = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					if selection then
						on_choice(selection.value, selection.index)
					else
						on_choice(nil, nil)
					end
				end)

				-- q to cancel
				map("n", "q", function()
					actions.close(prompt_bufnr)
					on_choice(nil, nil)
				end)

				return true
			end,
		})
		:find()
end

return M
