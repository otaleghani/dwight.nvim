-- dwight/github/picker.lua
-- Telescope/fallback pickers for issues: display, preview, keybindings.

local M = {}

--------------------------------------------------------------------
-- Label colors: map GitHub hex colors to Neovim highlights
--------------------------------------------------------------------

local _label_hl_cache = {}

--- Create a highlight group for a GitHub label color.
--- Returns the highlight group name.
local function label_hl(hex_color)
	local api = vim.api

	if not hex_color or hex_color == "" then
		return nil
	end
	hex_color = hex_color:gsub("^#", "")
	if #hex_color ~= 6 then
		return nil
	end

	local hl_name = "DwightLabel_" .. hex_color
	if _label_hl_cache[hl_name] then
		return hl_name
	end

	-- Parse RGB to determine if we need light or dark foreground
	local r = tonumber(hex_color:sub(1, 2), 16) or 128
	local g = tonumber(hex_color:sub(3, 4), 16) or 128
	local b = tonumber(hex_color:sub(5, 6), 16) or 128
	local luminance = (0.299 * r + 0.587 * g + 0.114 * b) / 255
	local fg = luminance > 0.5 and "#1a1b26" or "#c0caf5"

	api.nvim_set_hl(0, hl_name, { fg = fg, bg = "#" .. hex_color, bold = true })
	_label_hl_cache[hl_name] = true
	return hl_name
end

--------------------------------------------------------------------
-- Display / preview formatters
--------------------------------------------------------------------

--- Format an issue for the picker display.
--- Returns { text, highlights } where highlights is a list of { hl_group, col_start, col_end }.
function M.format_issue_display(issue)
	local parts = {}
	local highlights = {}

	-- Issue number
	local num_str = string.format("#%-5d ", issue.number)
	parts[#parts + 1] = num_str

	-- Title
	parts[#parts + 1] = issue.title or ""

	-- Assignees
	if issue.assignees and #issue.assignees > 0 then
		local names = {}
		for _, a in ipairs(issue.assignees) do
			names[#names + 1] = "@" .. (type(a) == "table" and a.login or tostring(a))
		end
		parts[#parts + 1] = " -> " .. table.concat(names, ",")
	end

	-- Milestone
	if issue.milestone and type(issue.milestone) == "table" and issue.milestone.title then
		parts[#parts + 1] = " " .. issue.milestone.title
	end

	-- Labels (with color tracking for highlights)
	local label_info = {}
	if issue.labels and #issue.labels > 0 then
		local label_strs = {}
		for _, l in ipairs(issue.labels) do
			local name = type(l) == "table" and l.name or tostring(l)
			local color = type(l) == "table" and l.color or nil
			label_strs[#label_strs + 1] = name
			label_info[#label_info + 1] = { name = name, color = color }
		end
		parts[#parts + 1] = " [" .. table.concat(label_strs, ", ") .. "]"
	end

	local text = table.concat(parts, "")

	-- Build highlight positions for labels
	if #label_info > 0 then
		local bracket_pos = text:find(" %[", 1, false)
		if bracket_pos then
			local pos = bracket_pos + 2 -- after " ["
			for _, li in ipairs(label_info) do
				local hl = label_hl(li.color)
				if hl then
					highlights[#highlights + 1] = { hl, pos, pos + #li.name }
				end
				pos = pos + #li.name + 2 -- ", "
			end
		end
	end

	return text, highlights
end

--- Format issue body for the preview window.
function M.format_issue_preview(issue)
	local lines = {
		"# #" .. issue.number .. ": " .. (issue.title or ""),
		"",
	}

	if issue.labels and #issue.labels > 0 then
		local names = {}
		for _, l in ipairs(issue.labels) do
			names[#names + 1] = type(l) == "table" and l.name or tostring(l)
		end
		lines[#lines + 1] = "**Labels:** " .. table.concat(names, ", ")
	end

	if issue.assignees and #issue.assignees > 0 then
		local names = {}
		for _, a in ipairs(issue.assignees) do
			names[#names + 1] = "@" .. (type(a) == "table" and a.login or tostring(a))
		end
		lines[#lines + 1] = "**Assignees:** " .. table.concat(names, ", ")
	end

	if issue.milestone and type(issue.milestone) == "table" and issue.milestone.title then
		lines[#lines + 1] = "**Milestone:** " .. issue.milestone.title
	end

	local author = issue.author
	if type(author) == "table" then
		author = author.login
	end
	if author then
		lines[#lines + 1] = "**Author:** " .. author
	end
	if issue.createdAt then
		lines[#lines + 1] = "**Created:** " .. issue.createdAt:sub(1, 10)
	end
	if issue.url then
		lines[#lines + 1] = "**URL:** " .. issue.url
	end

	lines[#lines + 1] = ""
	lines[#lines + 1] = "---"
	lines[#lines + 1] = ""

	if issue.body and issue.body ~= "" then
		for line in issue.body:gmatch("[^\n]*") do
			lines[#lines + 1] = line
		end
	else
		lines[#lines + 1] = "(no description)"
	end

	if issue.comments and #issue.comments > 0 then
		lines[#lines + 1] = ""
		lines[#lines + 1] = "---"
		lines[#lines + 1] = string.format("## Comments (%d)", #issue.comments)
		lines[#lines + 1] = ""

		local start_idx = math.max(1, #issue.comments - 4)
		for i = start_idx, #issue.comments do
			local c = issue.comments[i]
			local c_author = type(c.author) == "table" and c.author.login or (c.author or "?")
			lines[#lines + 1] = string.format("**@%s** (%s):", c_author, (c.createdAt or ""):sub(1, 10))
			for line in (c.body or ""):gmatch("[^\n]*") do
				lines[#lines + 1] = line
			end
			lines[#lines + 1] = ""
		end
	end

	lines[#lines + 1] = ""
	lines[#lines + 1] = "---"
	lines[#lines + 1] = "**s** solve (Agent) | **S** solve (Auto) | **a** analyze | **e** open in buffer"

	return lines
end

--------------------------------------------------------------------
-- Telescope picker
--------------------------------------------------------------------

--- Open the Telescope picker for GitHub issues.
function M.pick(opts)
	local api = vim.api
	local _flatten = require("dwight.util").flatten_lines
	local preflight = require("dwight.github.preflight")
	local issues_mod = require("dwight.github.issues")
	local workflow = require("dwight.github.workflow")

	opts = opts or {}

	-- Preflight
	local check = preflight.check()
	if not check.ok then
		vim.notify("[dwight] " .. check.detail, vim.log.levels.ERROR)
		return
	end

	if not opts.repo and not preflight.is_github_repo() then
		vim.notify("[dwight] Not a GitHub repository (origin doesn't point to github.com).", vim.log.levels.ERROR)
		return
	end

	local filter_parts = {}
	if opts.milestone then
		filter_parts[#filter_parts + 1] = opts.milestone
	end
	if opts.label then
		filter_parts[#filter_parts + 1] = opts.label
	end
	if opts.repo then
		filter_parts[#filter_parts + 1] = opts.repo
	end
	local filter_str = #filter_parts > 0 and (" " .. table.concat(filter_parts, " ")) or ""

	vim.notify("[dwight] Fetching issues..." .. filter_str, vim.log.levels.INFO)

	issues_mod.list_issues(opts, function(issues, err)
		if err then
			vim.notify("[dwight] " .. err, vim.log.levels.ERROR)
			return
		end

		if not issues or #issues == 0 then
			vim.notify("[dwight] No open issues found.", vim.log.levels.INFO)
			return
		end

		local has_tel, pickers = pcall(require, "telescope.pickers")
		if not has_tel then
			M._pick_fallback(issues)
			return
		end

		local finders = require("telescope.finders")
		local conf = require("telescope.config").values
		local actions = require("telescope.actions")
		local action_state = require("telescope.actions.state")
		local previewers = require("telescope.previewers")
		local entry_display = nil
		pcall(function()
			entry_display = require("telescope.pickers.entry_display")
		end)

		pickers
			.new({}, {
				prompt_title = string.format("GitHub Issues (%d open)%s", #issues, filter_str),
				finder = finders.new_table({
					results = issues,
					entry_maker = function(issue)
						local text = M.format_issue_display(issue)
						return {
							value = issue,
							display = text,
							ordinal = string.format(
								"%d %s %s",
								issue.number or 0,
								issue.title or "",
								issue.assignees
										and #issue.assignees > 0
										and (type(issue.assignees[1]) == "table" and issue.assignees[1].login or "")
									or ""
							),
						}
					end,
				}),
				sorter = conf.generic_sorter({}),
				previewer = previewers.new_buffer_previewer({
					title = "Issue Preview  s=solve(Agent) S=solve(Auto) a=analyze e=open",
					define_preview = function(self, entry)
						local lines = M.format_issue_preview(entry.value)
						api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, _flatten(lines))
						vim.bo[self.state.bufnr].filetype = "markdown"
					end,
				}),
				attach_mappings = function(prompt_bufnr, map_fn)
					-- Enter: action picker
					actions.select_default:replace(function()
						local entry = action_state.get_selected_entry()
						actions.close(prompt_bufnr)
						if entry then
							M._action_picker(entry.value)
						end
					end)

					-- s: solve with DwightAgent
					local function map_solve_agent()
						local entry = action_state.get_selected_entry()
						actions.close(prompt_bufnr)
						if entry then
							workflow.solve_agent(entry.value)
						end
					end
					map_fn("i", "<C-s>", map_solve_agent)
					map_fn("n", "s", map_solve_agent)

					-- S: solve with DwightAuto
					local function map_solve_auto()
						local entry = action_state.get_selected_entry()
						actions.close(prompt_bufnr)
						if entry then
							workflow.solve_auto(entry.value)
						end
					end
					map_fn("n", "S", map_solve_auto)

					-- a: analyze
					local function map_analyze()
						local entry = action_state.get_selected_entry()
						actions.close(prompt_bufnr)
						if entry then
							workflow.analyze(entry.value)
						end
					end
					map_fn("i", "<C-a>", map_analyze)
					map_fn("n", "a", map_analyze)

					-- e: open in buffer
					local function map_open()
						local entry = action_state.get_selected_entry()
						actions.close(prompt_bufnr)
						if entry then
							M._open_issue_buffer(entry.value)
						end
					end
					map_fn("i", "<C-e>", map_open)
					map_fn("n", "e", map_open)

					return true
				end,
			})
			:find()
	end)
end

--- Action picker after selecting an issue (when pressing Enter).
function M._action_picker(issue)
	local workflow = require("dwight.github.workflow")

	require("dwight.select").pick({
		"Solve with DwightAgent (single task)",
		"Solve with DwightAuto (multi-task)",
		"Analyze (read-only, optional comment)",
		"Open in buffer (manual work)",
	}, {
		prompt = string.format("Issue #%d: %s", issue.number, issue.title:sub(1, 50)),
	}, function(choice)
		if not choice then
			return
		end
		if choice:match("DwightAgent") then
			workflow.solve_agent(issue)
		elseif choice:match("DwightAuto") then
			workflow.solve_auto(issue)
		elseif choice:match("Analyze") then
			workflow.analyze(issue)
		elseif choice:match("Open in buffer") then
			M._open_issue_buffer(issue)
		end
	end)
end

--- Open an issue as a read-only buffer for context while working.
function M._open_issue_buffer(issue)
	local api = vim.api
	local _flatten = require("dwight.util").flatten_lines
	local workflow = require("dwight.github.workflow")

	local buf = api.nvim_create_buf(false, true)
	local lines = M.format_issue_preview(issue)
	api.nvim_buf_set_lines(buf, 0, -1, false, _flatten(lines))
	vim.bo[buf].filetype = "markdown"
	vim.bo[buf].modifiable = false
	vim.bo[buf].bufhidden = "wipe"
	api.nvim_buf_set_name(buf, string.format("dwight://issue/%d", issue.number))

	vim.cmd("botright vsplit")
	api.nvim_win_set_buf(0, buf)
	vim.wo[0].number = false
	vim.wo[0].relativenumber = false
	vim.wo[0].wrap = true
	vim.wo[0].winfixwidth = true
	api.nvim_win_set_width(0, 60)

	-- Keymaps in the issue buffer
	vim.keymap.set("n", "s", function()
		workflow.solve_agent(issue)
	end, { buffer = buf, desc = "Solve with DwightAgent" })

	vim.keymap.set("n", "S", function()
		workflow.solve_auto(issue)
	end, { buffer = buf, desc = "Solve with DwightAuto" })

	vim.keymap.set("n", "a", function()
		workflow.analyze(issue)
	end, { buffer = buf, desc = "Analyze issue" })

	vim.keymap.set("n", "q", function()
		if api.nvim_buf_is_valid(buf) then
			pcall(api.nvim_buf_delete, buf, { force = true })
		end
	end, { buffer = buf, desc = "Close issue buffer" })

	vim.notify(
		string.format("[dwight] Issue #%d open. s=solve(Agent) S=solve(Auto) a=analyze q=close", issue.number),
		vim.log.levels.INFO
	)
end

--- Fallback picker when Telescope is not available.
function M._pick_fallback(issues)
	local items = {}
	for _, issue in ipairs(issues) do
		local text = M.format_issue_display(issue)
		items[#items + 1] = text
	end

	require("dwight.select").pick(items, {
		prompt = "Select issue:",
	}, function(_, idx)
		if idx then
			M._action_picker(issues[idx])
		end
	end)
end

return M
