-- dwight/whiteboard.lua
-- The Whiteboard: a persistent scratch buffer for braindumping.
-- Select text and use dwight modes on it normally.
-- :DwightWhiteboard opens it.
-- :DwightWhiteboardSave [name] saves content to .dwight/brainstorm/.
--   Without selection: saves entire whiteboard.
--   With visual selection: saves just the selection.
--   With argument: uses that as filename. Without: auto-generates from content.

local M = {}

local api = vim.api

--------------------------------------------------------------------
-- Paths
--------------------------------------------------------------------

local function brainstorm_dir()
	return require("dwight.project").dir() .. "/brainstorm"
end

local function wb_path()
	return require("dwight.project").dir() .. "/whiteboard.md"
end

--------------------------------------------------------------------
-- Open / focus the whiteboard
--------------------------------------------------------------------

function M.open()
	local project = require("dwight.project")
	if not project.is_initialized() then
		vim.notify("[dwight] Run :DwightInit first.", vim.log.levels.WARN)
		return
	end

	local path = wb_path()

	-- Focus if already open
	for _, win in ipairs(api.nvim_list_wins()) do
		local buf = api.nvim_win_get_buf(win)
		if api.nvim_buf_get_name(buf) == vim.fn.fnamemodify(path, ":p") then
			api.nvim_set_current_win(win)
			return
		end
	end

	-- Create file if it doesn't exist
	if vim.fn.filereadable(path) ~= 1 then
		vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
		local f = io.open(path, "w")
		if f then
			f:write(table.concat({
				"# Whiteboard",
				"",
				"Brain dump ideas here. Select text and fire it off:",
				"",
				"  <leader>da  → DwightAgent (execute immediately)",
				"  <leader>dp  → DwightAgent (plan first)",
				"  <leader>dA  → DwightAuto  (decompose into tasks)",
				"",
				"---",
				"",
				"",
			}, "\n"))
			f:close()
		end
	end

	vim.cmd("vsplit " .. vim.fn.fnameescape(path))
	vim.cmd("vertical resize 70")
	local buf = api.nvim_get_current_buf()
	vim.bo[buf].filetype = "markdown"
	local lines = api.nvim_buf_line_count(0)
	api.nvim_win_set_cursor(0, { lines, 0 })

	-- Set up whiteboard-specific keymaps
	M._setup_keymaps(buf)
end

--------------------------------------------------------------------
-- Fire selection as prompt → DwightAgent / DwightAuto
--------------------------------------------------------------------

--- Grab visual selection text from a buffer.
local function get_visual_text()
	vim.cmd('noautocmd normal! "vy')
	local bufnr = api.nvim_get_current_buf()
	local start_pos = api.nvim_buf_get_mark(bufnr, "<")
	local end_pos = api.nvim_buf_get_mark(bufnr, ">")
	if start_pos[1] == 0 and end_pos[1] == 0 then
		return nil
	end

	local lines = api.nvim_buf_get_lines(bufnr, start_pos[1] - 1, end_pos[1], false)
	if not lines or #lines == 0 then
		return nil
	end
	return vim.trim(table.concat(lines, "\n"))
end

--- Fire the visual selection as a prompt for the given target.
--- @param target "agent"|"auto"
--- @param opts table|nil  extra opts for agent.run()
function M.fire(target, opts)
	local text = get_visual_text()
	if not text or text == "" then
		vim.notify("[dwight] No text selected. Select your brainstorm text first.", vim.log.levels.WARN)
		return
	end

	-- Strip markdown headings/horizontal rules — keep the substance
	local cleaned = text:gsub("^#+%s+[^\n]*\n?", ""):gsub("\n%-%-%-\n?", "\n")
	cleaned = vim.trim(cleaned)
	if cleaned == "" then
		cleaned = text
	end

	local preview = cleaned:sub(1, 60):gsub("\n", " ")
	if #cleaned > 60 then
		preview = preview .. "…"
	end

	if target == "agent" then
		opts = opts or {}
		vim.notify(string.format("[dwight] 🚀 Firing agent: %s", preview), vim.log.levels.INFO)
		require("dwight.agent").run(cleaned, opts)
	elseif target == "auto" then
		vim.notify(string.format("[dwight] 🤖 Firing auto: %s", preview), vim.log.levels.INFO)
		require("dwight.auto").auto(cleaned)
	else
		vim.notify("[dwight] Unknown target: " .. tostring(target), vim.log.levels.ERROR)
	end
end

--- Set up whiteboard-specific keymaps on a buffer.
function M._setup_keymaps(buf)
	local mopts = { buffer = buf, silent = true }

	-- Visual mode: fire selection as prompt
	vim.keymap.set("v", "<leader>da", function()
		M.fire("agent")
	end, vim.tbl_extend("force", mopts, { desc = "Dwight: fire selection → Agent" }))

	vim.keymap.set("v", "<leader>dp", function()
		M.fire("agent", { plan = true })
	end, vim.tbl_extend("force", mopts, { desc = "Dwight: fire selection → Agent (plan first)" }))

	vim.keymap.set("v", "<leader>dA", function()
		M.fire("auto")
	end, vim.tbl_extend("force", mopts, { desc = "Dwight: fire selection → Auto" }))

	-- Buffer-local command that works with visual range
	api.nvim_buf_create_user_command(buf, "DwightFire", function(o)
		local target = o.args ~= "" and o.args or "agent"
		M.fire(target)
	end, {
		range = true,
		nargs = "?",
		complete = function()
			return { "agent", "auto" }
		end,
		desc = "Fire visual selection as prompt (agent|auto)",
	})

	-- Show hint on first open
	if not M._keymaps_hinted then
		M._keymaps_hinted = true
		vim.defer_fn(function()
			vim.notify(
				"[dwight] Whiteboard: select text → <leader>da (Agent) | <leader>dA (Auto) | <leader>dp (Agent+plan)",
				vim.log.levels.INFO
			)
		end, 200)
	end
end

--------------------------------------------------------------------
-- Append AI response to whiteboard
--------------------------------------------------------------------

function M.append(text, label)
	local path = wb_path()
	local f = io.open(path, "a")
	if not f then
		return
	end
	label = label or "AI"
	f:write("\n\n### " .. label .. " (" .. os.date("%H:%M") .. ")\n\n" .. text .. "\n")
	f:close()

	-- Refresh any open whiteboard buffer
	for _, buf in ipairs(api.nvim_list_bufs()) do
		if api.nvim_buf_is_loaded(buf) and api.nvim_buf_get_name(buf) == vim.fn.fnamemodify(path, ":p") then
			api.nvim_buf_call(buf, function()
				pcall(vim.cmd, "edit!")
			end)
			local win = vim.fn.bufwinid(buf)
			if win ~= -1 then
				api.nvim_win_set_cursor(win, { api.nvim_buf_line_count(buf), 0 })
			end
		end
	end
end

--------------------------------------------------------------------
-- Save to .dwight/brainstorm/
-- Works from any buffer, not just the whiteboard.
-- Range mode: saves visual selection. Normal mode: saves entire buffer.
-- :DwightWhiteboardSave [name] — name is optional.
--------------------------------------------------------------------

function M.save(opts)
	opts = opts or {}
	vim.fn.mkdir(brainstorm_dir(), "p")

	-- Get content: visual selection if range given, otherwise entire buffer
	local content = nil
	local has_range = opts.range and opts.range > 0

	if has_range then
		local sel = require("dwight.ui").get_visual_selection()
		if sel and vim.trim(sel.text) ~= "" then
			content = sel.text
		end
	end

	if not content then
		-- Save entire buffer content
		local lines = api.nvim_buf_get_lines(0, 0, -1, false)
		content = table.concat(lines, "\n")
		-- Strip the whiteboard header if saving from whiteboard
		content = content:gsub("^# Whiteboard%s*\n+Brain dump ideas here.-\n+%-%-%-\n*", "")
		content = vim.trim(content)
	end

	if content == "" then
		vim.notify("[dwight] Nothing to save.", vim.log.levels.WARN)
		return
	end

	-- Determine filename
	local filename = opts.name

	if not filename or filename == "" then
		-- Auto-generate: timestamp + first meaningful words
		local first = content:match("^[^\n]+") or ""
		first = first:gsub("^#+%s*", ""):gsub("[^%w%s_%-]", "")
		local slug = vim.trim(first):sub(1, 30):lower():gsub("%s+", "-"):gsub("%-+$", "")
		if slug == "" then
			slug = "note"
		end
		filename = os.date("%Y%m%d-%H%M") .. "-" .. slug .. ".md"
	else
		if not filename:match("%.%w+$") then
			filename = filename .. ".md"
		end
	end

	local dest = brainstorm_dir() .. "/" .. filename

	-- If file exists with same name, append
	if vim.fn.filereadable(dest) == 1 then
		local f = io.open(dest, "a")
		if f then
			f:write("\n\n---\n\n*" .. os.date("%Y-%m-%d %H:%M") .. "*\n\n" .. content)
			f:close()
			vim.notify("[dwight] ✅ Appended to .dwight/brainstorm/" .. filename, vim.log.levels.INFO)
		end
	else
		local f = io.open(dest, "w")
		if f then
			f:write("# " .. (content:match("^### (.-)$") or content:match("^[^\n]+") or "Note") .. "\n\n")
			f:write("*" .. os.date("%Y-%m-%d %H:%M") .. "*\n\n")
			f:write(content)
			f:close()
			vim.notify("[dwight] ✅ Saved to .dwight/brainstorm/" .. filename, vim.log.levels.INFO)
		end
	end
end

--------------------------------------------------------------------
-- Browse brainstorms
--------------------------------------------------------------------

function M.browse()
	local dir = brainstorm_dir()
	if vim.fn.isdirectory(dir) ~= 1 then
		vim.notify("[dwight] No brainstorms yet. Use :DwightWhiteboardSave.", vim.log.levels.INFO)
		return
	end

	local files = {}
	local uv = vim.loop or vim.uv
	local handle = uv.fs_scandir(dir)
	if handle then
		while true do
			local name, ftype = uv.fs_scandir_next(handle)
			if not name then
				break
			end
			if ftype == "file" then
				files[#files + 1] = name
			end
		end
	end
	table.sort(files, function(a, b)
		return a > b
	end) -- newest first

	if #files == 0 then
		vim.notify("[dwight] No brainstorms found.", vim.log.levels.INFO)
		return
	end

	local has_tel, pickers = pcall(require, "telescope.pickers")
	if has_tel then
		local finders = require("telescope.finders")
		local conf = require("telescope.config").values
		local actions = require("telescope.actions")
		local action_state = require("telescope.actions.state")
		local previewers = require("telescope.previewers")

		pickers
			.new({}, {
				prompt_title = "🧠 Brainstorms (.dwight/brainstorm/)",
				finder = finders.new_table({ results = files }),
				sorter = conf.generic_sorter({}),
				previewer = previewers.new_buffer_previewer({
					define_preview = function(self, entry)
						conf.buffer_previewer_maker(dir .. "/" .. entry[1], self.state.bufnr, {})
					end,
				}),
				attach_mappings = function(pb, map)
					actions.select_default:replace(function()
						local sel = action_state.get_selected_entry()
						actions.close(pb)
						if sel then
							vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/" .. sel[1]))
						end
					end)
					map("i", "<C-d>", function()
						local sel = action_state.get_selected_entry()
						if sel then
							os.remove(dir .. "/" .. sel[1])
							vim.notify("[dwight] Deleted " .. sel[1], vim.log.levels.INFO)
							actions.close(pb)
						end
					end)
					return true
				end,
			})
			:find()
	else
		for i, name in ipairs(files) do
			vim.notify(string.format("  %d. %s", i, name))
		end
	end
end

return M
