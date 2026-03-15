-- dwight/split/preview.lua
-- Format and display split proposals in a preview buffer.

local M = {}

local api = vim.api
local _flatten = require("dwight.util").flatten_lines

--- Format a proposal as readable text.
function M.format_proposal(proposal)
	local parts = {}
	local a = proposal.analysis

	parts[#parts + 1] = string.format(
		"═══════════════════════════════════════════════"
	)
	parts[#parts + 1] = string.format("  DwightSplitFeature: $%s", proposal.parent)
	parts[#parts + 1] = string.format(
		"═══════════════════════════════════════════════"
	)
	parts[#parts + 1] = ""

	if a then
		parts[#parts + 1] =
			string.format("Current: %d files, %d lines, %d symbols", a.file_count, a.total_lines, a.symbol_count)
		if a.description then
			parts[#parts + 1] = string.format("Description: %s", a.description)
		end
	end

	parts[#parts + 1] = ""
	parts[#parts + 1] = string.format("Proposed split into %d sub-features:", #proposal.sub_features)
	parts[#parts + 1] = ""

	for i, sf in ipairs(proposal.sub_features) do
		parts[#parts + 1] = string.format("  %d. $%s", i, sf.name)
		parts[#parts + 1] = string.format("     %s", sf.description)
		parts[#parts + 1] = string.format("     Files (%d):", #sf.files)
		for _, fp in ipairs(sf.files) do
			-- Find line count from analysis
			local lines = "?"
			if a then
				for _, af in ipairs(a.files) do
					if af.path == fp then
						lines = tostring(af.lines)
						break
					end
				end
			end
			parts[#parts + 1] = string.format("       - %s (%s lines)", fp, lines)
		end
		parts[#parts + 1] = ""
	end

	parts[#parts + 1] =
		"───────────────────────────────────────────────"
	parts[#parts + 1] = "  Press 'y' to apply, 'n' to cancel, 'q' to close"
	parts[#parts + 1] =
		"───────────────────────────────────────────────"

	return table.concat(parts, "\n")
end

--- Show proposal in a preview buffer with confirm/cancel keybinds.
function M.show_proposal_buffer(proposal, on_confirm, on_cancel)
	local text = M.format_proposal(proposal)
	local lines = vim.split(text, "\n", { plain = true })

	local buf = api.nvim_create_buf(false, true)
	api.nvim_buf_set_name(buf, "dwight://split-preview/" .. proposal.parent)
	api.nvim_buf_set_lines(buf, 0, -1, false, _flatten(lines))
	vim.bo[buf].filetype = "markdown"
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].modifiable = false
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false

	-- Open in a split
	vim.cmd("botright split")
	api.nvim_win_set_buf(0, buf)
	vim.cmd("resize " .. math.min(#lines + 2, 30))

	-- Keymaps
	local function close()
		local win = api.nvim_get_current_win()
		pcall(api.nvim_win_close, win, true)
	end

	vim.keymap.set("n", "y", function()
		close()
		if on_confirm then
			on_confirm()
		end
	end, { buffer = buf, desc = "Apply split" })

	vim.keymap.set("n", "n", function()
		close()
		if on_cancel then
			on_cancel()
		end
	end, { buffer = buf, desc = "Cancel split" })

	vim.keymap.set("n", "q", close, { buffer = buf, desc = "Close preview" })
end

return M
