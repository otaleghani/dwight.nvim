-- dwight/ui/prompt.lua
-- Floating prompt window: scratch buffer with static help, keymaps, submit logic.

local M = {}

local api = vim.api

M.EDITABLE_LINES = 6

--- Build a context-enriched request string for agent/auto dispatch.
--- Agent backends accept a plain string, so we append resolved context
--- (features, files, symbols) to the user's clean text.
local function build_agent_request(clean_text, parsed, resolved_features, resolved_files, resolved_symbols)
	local parts = { clean_text }

	-- $feature: append feature file lists
	if #resolved_features > 0 then
		local feat_lines = { "\n\nRelevant feature files:" }
		for _, feat in ipairs(resolved_features) do
			if feat.content then
				feat_lines[#feat_lines + 1] = feat.content
			end
		end
		parts[#parts + 1] = table.concat(feat_lines, "\n")
	end

	-- +file: append attached file contents
	if #resolved_files > 0 then
		local file_lines = { "\n\nAttached files:" }
		for _, f in ipairs(resolved_files) do
			file_lines[#file_lines + 1] = "--- " .. f.name .. " ---\n" .. f.content
		end
		parts[#parts + 1] = table.concat(file_lines, "\n")
	end

	-- #sym: append referenced symbol locations
	if #resolved_symbols > 0 then
		local sym_lines = { "\n\nReferenced symbols:" }
		for _, sym in ipairs(resolved_symbols) do
			local loc = sym.filepath
					and sym.line
					and string.format("%s:%d", vim.fn.fnamemodify(sym.filepath, ":."), sym.line)
				or "unknown"
			sym_lines[#sym_lines + 1] = "- " .. sym.name .. " (" .. loc .. ")"
		end
		parts[#parts + 1] = table.concat(sym_lines, "\n")
	end

	return table.concat(parts)
end

function M.open_prompt(selection, opts)
	opts = opts or {}
	local dispatch = opts.dispatch or "invoke"

	local ui = require("dwight.ui")
	local cfg = require("dwight").config
	if selection then
		ui._source_bufnr = selection.bufnr
	end

	local width = math.floor(vim.o.columns * 0.65)
	width = math.max(width, 60)
	local height = M.EDITABLE_LINES

	local row = math.floor((vim.o.lines - height) / 2)
	local col = math.floor((vim.o.columns - width) / 2)

	local buf = api.nvim_create_buf(false, true)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].filetype = "dwight_prompt"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].omnifunc = "v:lua.require'dwight.ui'.omnifunc"

	local file_info
	if selection then
		file_info = string.format(
			"%d lines · %s",
			selection.end_line - selection.start_line + 1,
			vim.fn.fnamemodify(selection.filepath or "", ":t")
		)
	else
		file_info = dispatch
	end

	local model_display = "default"
	pcall(function()
		local backend = cfg.backend or "api"
		if backend == "claude_code" then
			model_display = "claude_code/" .. (cfg.claude_code_model or cfg.model or "sonnet")
		elseif backend == "codex" then
			model_display = "codex/" .. (cfg.codex_model or "codex")
		elseif backend == "gemini" then
			model_display = "gemini/" .. (cfg.gemini_model or "gemini")
		elseif backend == "opencode" then
			model_display = "opencode/" .. (cfg.model or "default")
		else
			local resolved = require("dwight.providers").resolve_model(nil)
			local alias = resolved.model_id or ""
			local short = alias:match("([^/]+)$") or alias
			if #short > 20 then
				short = short:sub(1, 17) .. "…"
			end
			model_display = resolved.provider_name .. "/" .. short
		end
	end)

	local content = {}
	for _ = 1, M.EDITABLE_LINES do
		content[#content + 1] = ""
	end
	api.nvim_buf_set_lines(buf, 0, -1, false, content)

	local win = api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = row,
		col = col,
		style = "minimal",
		border = cfg.border,
		title = dispatch == "invoke" and " dwight " or (" dwight:" .. dispatch .. " "),
		title_pos = "center",
		footer = {
			{ " " .. file_info, "DwightFile" },
			{ " · ", "FloatBorder" },
			{ model_display, "DwightModel" },
			{ " · ", "FloatBorder" },
			{ ":H help ", "Comment" },
		},
		footer_pos = "center",
	})

	vim.wo[win].winhl = "Normal:Normal,FloatBorder:DwightBorder,FloatTitle:DwightTitle"
	vim.wo[win].cursorline = false
	vim.wo[win].wrap = true
	vim.wo[win].linebreak = true

	-- Help popup
	local help_win = nil
	local help_buf = nil

	local function toggle_help()
		if help_win and api.nvim_win_is_valid(help_win) then
			api.nvim_win_close(help_win, true)
			help_win = nil
			help_buf = nil
			return
		end

		local help_width = width
		local help_row = row + height + 2
		local help_col = col

		help_buf = api.nvim_create_buf(false, true)
		vim.bo[help_buf].buftype = "nofile"
		vim.bo[help_buf].bufhidden = "wipe"
		local help_lines = {
			" Tokens",
			"  /mode    fix test stub ...",
			"  @skill   pick a skill",
			"  $feat    project feature",
			"  #sym     code symbol",
			"  %lib     library docs",
			"  &mcp     mcp resource",
			"  +file    attach file",
			"  ~audit   peer review",
			"  ^N       think depth",
			"  !model   override model",
			"",
			" Keys",
			"  <CR> submit   <Tab> complete",
			"  <Esc> normal   q close   :H help",
		}
		api.nvim_buf_set_lines(help_buf, 0, -1, false, help_lines)

		help_win = api.nvim_open_win(help_buf, false, {
			relative = "editor",
			width = help_width,
			height = #help_lines,
			row = help_row,
			col = help_col,
			style = "minimal",
			border = "rounded",
			title = " help ",
			title_pos = "center",
		})

		vim.wo[help_win].winhl = "Normal:Normal,FloatBorder:DwightBorder"
		local hl_ns = api.nvim_create_namespace("dwight_help_popup_hl")
		-- Base: all lines as Comment
		for i = 0, #help_lines - 1 do
			api.nvim_buf_add_highlight(help_buf, hl_ns, "Comment", i, 0, -1)
		end
		-- Section titles
		api.nvim_buf_add_highlight(help_buf, hl_ns, "DwightTitle", 0, 0, -1)
		api.nvim_buf_add_highlight(help_buf, hl_ns, "DwightTitle", 12, 0, -1)
		-- Token sigils: find and highlight each token keyword
		local token_hls = {
			{ "/mode", "DwightMode" },
			{ "@skill", "DwightSkill" },
			{ "$feat", "DwightFeature" },
			{ "#sym", "DwightSymbol" },
			{ "%lib", "DwightLib" },
			{ "&mcp", "DwightMcp" },
			{ "+file", "DwightFile" },
			{ "~audit", "DwightAudit" },
			{ "^N", "DwightThink" },
			{ "!model", "DwightModel" },
		}
		for i, line in ipairs(help_lines) do
			for _, th in ipairs(token_hls) do
				local s, e = line:find(th[1], 1, true)
				if s then
					api.nvim_buf_add_highlight(help_buf, hl_ns, th[2], i - 1, s - 1, e)
				end
			end
		end
	end

	-- completeopt
	local saved_completeopt = vim.o.completeopt
	vim.opt.completeopt = "menuone,noinsert,noselect"
	api.nvim_create_autocmd("BufWipeout", {
		buffer = buf,
		once = true,
		callback = function()
			vim.opt.completeopt = saved_completeopt
			if help_win and api.nvim_win_is_valid(help_win) then
				api.nvim_win_close(help_win, true)
				help_win = nil
			end
		end,
	})

	api.nvim_win_set_cursor(win, { 1, 0 })
	vim.cmd("startinsert")

	-- Live highlighting
	local highlight = require("dwight.ui.highlight")
	highlight.highlight_prompt_buf(buf, M.EDITABLE_LINES)
	api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
		buffer = buf,
		callback = function()
			highlight.highlight_prompt_buf(buf, M.EDITABLE_LINES)
		end,
	})

	-- Trigger omnifunc on token chars
	local completion = require("dwight.ui.completion")
	api.nvim_create_autocmd("InsertCharPre", {
		buffer = buf,
		callback = function()
			local char = vim.v.char
			if
				char == "@"
				or char == "/"
				or char == "#"
				or char == "!"
				or char == "$"
				or char == "^"
				or char == "%"
				or char == "&"
			then
				vim.schedule(function()
					if api.nvim_buf_is_valid(buf) and vim.fn.pumvisible() == 0 then
						vim.fn.feedkeys(api.nvim_replace_termcodes("<C-x><C-o>", true, false, true), "n")
					end
				end)
			end
		end,
	})

	-- Re-trigger as user types
	api.nvim_create_autocmd("TextChangedI", {
		buffer = buf,
		callback = function()
			if vim.fn.pumvisible() == 1 then
				return
			end
			local trigger = completion.find_token_at_cursor()
			if trigger then
				vim.schedule(function()
					if api.nvim_buf_is_valid(buf) then
						vim.fn.feedkeys(api.nvim_replace_termcodes("<C-x><C-o>", true, false, true), "n")
					end
				end)
			end
		end,
	})

	-- Tab / S-Tab
	vim.keymap.set("i", "<Tab>", function()
		if vim.fn.pumvisible() == 1 then
			return api.nvim_replace_termcodes("<C-n>", true, false, true)
		else
			return api.nvim_replace_termcodes("<C-x><C-o>", true, false, true)
		end
	end, { buffer = buf, expr = true })

	vim.keymap.set("i", "<S-Tab>", function()
		if vim.fn.pumvisible() == 1 then
			return api.nvim_replace_termcodes("<C-p>", true, false, true)
		end
		return ""
	end, { buffer = buf, expr = true })

	-- Enter: accept completion or submit
	vim.keymap.set("i", "<CR>", function()
		if vim.fn.pumvisible() == 1 then
			return api.nvim_replace_termcodes("<C-y>", true, false, true)
		end

		vim.schedule(function()
			local tokens = require("dwight.ui.tokens")
			local input_lines = api.nvim_buf_get_lines(buf, 0, M.EDITABLE_LINES, false)
			local raw_text = vim.trim(table.concat(input_lines, " "))

			if api.nvim_win_is_valid(win) then
				api.nvim_win_close(win, true)
			end

			if raw_text == "" then
				vim.notify("[dwight] Empty prompt.", vim.log.levels.INFO)
				return
			end

			local parsed = tokens.parse_tokens(raw_text)
			local skill_paths = require("dwight.skills").resolve_many(parsed.skills)
			local resolved_symbols = require("dwight.symbols").resolve_many(parsed.symbols)
			local resolved_features = require("dwight.features").resolve_many(parsed.features)
			local resolved_libs = require("dwight.libs").resolve_many(parsed.libs)
			local resolved_mcp = require("dwight.mcp").resolve_many(parsed.mcp_refs)

			-- Resolve +file tokens -> treesitter minimaps or full files
			local resolved_files = {}
			for _, fpath in ipairs(parsed.files or {}) do
				pcall(function()
					local ts = require("dwight.treesitter")
					local cwd = vim.fn.getcwd() .. "/"
					local full = fpath:match("^/") and fpath or (cwd .. fpath)
					if vim.fn.isdirectory(full) == 1 then
						local file_content = ts.minimap_dir(full)
						if file_content then
							resolved_files[#resolved_files + 1] = { name = fpath, content = file_content }
						end
					else
						local file_content = ts.minimap(full)
						if file_content then
							resolved_files[#resolved_files + 1] = { name = fpath, content = file_content }
						end
					end
				end)
			end

			vim.schedule(function()
				if dispatch == "agent" or dispatch == "auto" then
					local request = build_agent_request(
						parsed.clean_text,
						parsed,
						resolved_features,
						resolved_files,
						resolved_symbols
					)
					if dispatch == "agent" then
						require("dwight.agent").run(request, opts.agent_opts or {})
					else
						require("dwight.auto").auto(request)
					end
				elseif parsed.mode then
					local mode = require("dwight.modes").get(parsed.mode)
					if mode then
						-- Apply +run modifier: inject last build/test output
						if parsed.modifiers and parsed.modifiers.run then
							mode = vim.tbl_extend("force", mode, { inject_run_output = true })
						end
						local ctx = require("dwight.lsp").gather_context(selection)
						local prompt_text = require("dwight.prompt").build(
							mode,
							selection,
							ctx,
							parsed.clean_text,
							skill_paths,
							resolved_symbols,
							resolved_features,
							parsed.think_depth,
							resolved_libs,
							resolved_mcp,
							resolved_files
						)
						require("dwight.inline").run(
							prompt_text,
							selection,
							cfg,
							parsed.mode,
							parsed.model_override,
							parsed.think_depth,
							{
								audit_model = parsed.audit_model,
								is_lint = mode.is_lint,
								is_macro = mode.is_macro,
								is_docs = mode.is_docs,
								is_prose = mode.context == "prose",
								is_plan = mode.is_plan,
								is_multi = mode.is_multi,
							}
						)
					else
						vim.notify("[dwight] Unknown mode: /" .. parsed.mode, vim.log.levels.ERROR)
					end
				else
					local prompt_text = require("dwight.prompt").build_freeform(
						parsed.clean_text,
						selection,
						skill_paths,
						resolved_symbols,
						resolved_features,
						parsed.think_depth,
						resolved_libs,
						resolved_mcp,
						resolved_files
					)
					require("dwight.inline").run(
						prompt_text,
						selection,
						cfg,
						"custom",
						parsed.model_override,
						parsed.think_depth,
						{ audit_model = parsed.audit_model }
					)
				end
			end)
		end)

		return ""
	end, { buffer = buf, expr = true })

	-- Esc: normal mode
	vim.keymap.set("i", "<Esc>", function()
		if vim.fn.pumvisible() == 1 then
			return api.nvim_replace_termcodes("<C-e>", true, false, true)
		end
		vim.cmd("stopinsert")
		return ""
	end, { buffer = buf, expr = true })

	-- q: close
	vim.keymap.set("n", "q", function()
		if api.nvim_win_is_valid(win) then
			api.nvim_win_close(win, true)
		end
	end, { buffer = buf, noremap = true, silent = true })

	-- i to re-enter insert
	vim.keymap.set("n", "i", function()
		local cursor = api.nvim_win_get_cursor(win)
		if cursor[1] > M.EDITABLE_LINES then
			api.nvim_win_set_cursor(win, { M.EDITABLE_LINES, 0 })
		end
		vim.cmd("startinsert")
	end, { buffer = buf, noremap = true })

	-- :H -- toggle help popup
	api.nvim_buf_create_user_command(buf, "H", function()
		toggle_help()
	end, { desc = "Toggle dwight help" })
end

return M
