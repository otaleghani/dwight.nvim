-- dwight/pubdocs/generate.lua
-- Single-page generation, multi-page generation, and browse.

local M = {}

local api = vim.api
local _flatten = require("dwight.util").flatten_lines

--------------------------------------------------------------------
-- Generate a single page
--------------------------------------------------------------------

function M.generate_page(page, callback)
	local adapters_mod = require("dwight.pubdocs.adapters")
	local helpers = require("dwight.pubdocs.helpers")
	local prompts = require("dwight.pubdocs.prompts")
	local plan_mod = require("dwight.pubdocs.plan")

	local adapter, fw = adapters_mod.get_adapter()
	local plan = plan_mod.build_plan()
	local docs_structure = helpers.build_docs_structure(plan, adapter, page)
	local project_ctx = helpers.build_project_context()
	local existing = helpers.read_existing_page(adapter, page.path)

	local position = nil
	for i, p in ipairs(plan) do
		if p.path == page.path then
			position = i
			break
		end
	end

	local prompt_fn = prompts.PAGE_PROMPTS[page.page_type] or prompts.PAGE_PROMPTS.generic
	local prompt = prompt_fn(page, adapter, docs_structure, project_ctx, existing)

	local log_ok, log = pcall(require, "dwight.log")
	local job_id
	if log_ok then
		job_id = log._next_id()
		log.start(
			job_id,
			"docs:" .. page.path,
			api.nvim_get_current_buf(),
			0,
			0,
			string.format("Framework: %s\n\n%s", fw, prompt:sub(1, 4000))
		)
	end

	require("dwight.skills")._run_llm(prompt, function(raw, code)
		if code ~= 0 or vim.trim(raw or "") == "" then
			if job_id then
				log.finish(job_id, "error", raw or "", nil, "Generation failed")
			end
			callback(nil, "Generation failed for " .. page.path)
			return
		end

		-- Strip fences if the LLM wrapped it
		local content = raw:gsub("^```%w*%s*\n", ""):gsub("\n```%s*$", "")
		content = content:gsub("^~~~%w*%s*\n", ""):gsub("\n~~~%s*$", "")

		-- Strip frontmatter if the LLM included it (we generate our own)
		content = content:gsub("^%-%-%-.-%-%-%-\n*", "")
		content = vim.trim(content)

		-- Prepend framework-specific frontmatter
		local frontmatter = adapter.frontmatter(page, position)
		content = frontmatter .. "\n\n" .. content

		if not content:match("\n$") then
			content = content .. "\n"
		end

		if job_id then
			log.finish(job_id, "success", raw, content:sub(1, 500), nil)
		end
		callback(content, nil)
	end)
end

--------------------------------------------------------------------
-- :DwightDocs [page|all] -- generate documentation
--------------------------------------------------------------------

function M.generate(opts)
	local adapters_mod = require("dwight.pubdocs.adapters")
	local helpers = require("dwight.pubdocs.helpers")
	local plan_mod = require("dwight.pubdocs.plan")

	local project = require("dwight.project")
	if not project.is_initialized() then
		vim.notify("[dwight] Run :DwightInit first.", vim.log.levels.WARN)
		return
	end

	local plan = plan_mod.build_plan()
	if #plan == 0 then
		vim.notify("[dwight] No pages to generate. Add @feature: or @docs: pragmas.", vim.log.levels.WARN)
		return
	end

	local adapter, fw = adapters_mod.get_adapter()
	vim.notify(
		string.format("[dwight] 📄 Docs framework: %s → %s/", fw, adapter.docs_dir():match("[^/]+$")),
		vim.log.levels.INFO
	)

	opts = opts or {}

	-- :DwightDocs all -- show plan, then generate everything
	if opts.target == "all" then
		-- Show plan preview
		local plan_lines = {
			string.format("📄 DwightDocs — Generate %d pages [%s]", #plan, fw),
			"",
		}
		local existing_count = 0
		for _, p in ipairs(plan) do
			local exists = vim.fn.filereadable(adapter.docs_dir() .. "/" .. p.path) == 1
			if exists then
				existing_count = existing_count + 1
			end
			local icon = ({
				index = "📖",
				["getting-started"] = "🚀",
				feature = "⚙️",
				reference = "📋",
				guide = "📝",
				concept = "💡",
			})[p.page_type] or "📄"
			local marker = exists and " (overwrite)" or " (new)"
			plan_lines[#plan_lines + 1] = string.format("  %s %s — %s%s", icon, p.path, p.title, marker)
		end
		plan_lines[#plan_lines + 1] = ""
		plan_lines[#plan_lines + 1] = string.format("  Output: %s/", adapter.docs_dir())
		if existing_count > 0 then
			plan_lines[#plan_lines + 1] =
				string.format("  ⚠️  %d existing page(s) will be overwritten", existing_count)
		end

		require("dwight.select").pick({
			string.format("✅ Generate all %d pages", #plan),
			"❌ Cancel",
		}, {
			prompt = table.concat(plan_lines, "\n"),
		}, function(choice)
			if choice and choice:match("Generate") then
				M._generate_many(plan)
			end
		end)
		return
	end

	-- :DwightDocs {page} -- generate a specific page
	if opts.target and opts.target ~= "" then
		for _, page in ipairs(plan) do
			if
				page.path:match(opts.target)
				or page.page_type == opts.target
				or (page.feature_name and page.feature_name == opts.target)
			then
				vim.notify("[dwight] 📄 Generating " .. page.path .. "…", vim.log.levels.INFO)

				M.generate_page(page, function(content, err)
					if err then
						vim.notify("[dwight] " .. err, vim.log.levels.ERROR)
					else
						helpers.write_page(adapter, page, content)
						vim.notify("[dwight] ✅ " .. page.path .. " generated!", vim.log.levels.INFO)
						vim.cmd("edit " .. vim.fn.fnameescape(adapter.docs_dir() .. "/" .. page.path))
					end
				end)
				return
			end
		end
		vim.notify("[dwight] Page not found: " .. opts.target, vim.log.levels.WARN)
		return
	end

	-- :DwightDocs (no args) -- Telescope picker
	local has_tel, pickers = pcall(require, "telescope.pickers")
	if has_tel then
		local finders = require("telescope.finders")
		local conf = require("telescope.config").values
		local actions = require("telescope.actions")
		local action_state = require("telescope.actions.state")
		local previewers = require("telescope.previewers")

		local picker_items = { { path = "(all)", title = "Generate ALL pages", page_type = "all" } }
		for _, p in ipairs(plan) do
			picker_items[#picker_items + 1] = p
		end

		pickers
			.new({}, {
				prompt_title = string.format("📄 DwightDocs [%s] — select pages", fw),
				finder = finders.new_table({
					results = picker_items,
					entry_maker = function(page)
						local icon = ({
							index = "📖",
							["getting-started"] = "🚀",
							feature = "⚙️",
							reference = "📋",
							guide = "📝",
							concept = "💡",
							generic = "📄",
							all = "✨",
						})[page.page_type] or "📄"
						local exists = page.path ~= "(all)"
							and vim.fn.filereadable(adapter.docs_dir() .. "/" .. page.path) == 1
						local marker = exists and " ✓" or ""
						return {
							value = page,
							display = icon .. " " .. page.path .. marker .. " — " .. page.title,
							ordinal = page.path .. " " .. page.title,
						}
					end,
				}),
				sorter = conf.generic_sorter({}),
				previewer = previewers.new_buffer_previewer({
					define_preview = function(self, entry)
						local page = entry.value
						if page.page_type == "all" then
							local lines = { "Generate ALL documentation pages:", "", "Framework: " .. fw, "" }
							for _, p in ipairs(plan) do
								lines[#lines + 1] = "  " .. p.path .. " — " .. p.title
							end
							api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, _flatten(lines))
						else
							local existing = helpers.read_existing_page(adapter, page.path)
							if existing then
								api.nvim_buf_set_lines(
									self.state.bufnr,
									0,
									-1,
									false,
									vim.split(existing, "\n", { plain = true })
								)
								vim.bo[self.state.bufnr].filetype = "markdown"
							else
								api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, {
									"📄 " .. page.path .. " (will be generated)",
									"",
									"Framework: " .. fw,
									"Type: " .. page.page_type,
									"Title: " .. page.title,
									page.feature_name and ("Feature: $" .. page.feature_name) or "",
								})
							end
						end
					end,
				}),
				attach_mappings = function(pb, map)
					map("i", "<Tab>", actions.toggle_selection + actions.move_selection_worse)
					map("n", "<Tab>", actions.toggle_selection + actions.move_selection_worse)
					actions.select_default:replace(function()
						local picker = action_state.get_current_picker(pb)
						local selections = picker:get_multi_selection()
						actions.close(pb)

						local targets = {}
						if #selections > 0 then
							for _, sel in ipairs(selections) do
								targets[#targets + 1] = sel.value
							end
						else
							local sel = action_state.get_selected_entry()
							if sel then
								targets[#targets + 1] = sel.value
							end
						end

						if #targets == 1 and targets[1].page_type == "all" then
							M._generate_many(plan)
						elseif #targets > 0 then
							local filtered = {}
							for _, t in ipairs(targets) do
								if t.page_type ~= "all" then
									filtered[#filtered + 1] = t
								end
							end
							if #filtered > 0 then
								M._generate_many(filtered)
							end
						end
					end)
					return true
				end,
			})
			:find()
	else
		M._generate_many(plan)
	end
end

--------------------------------------------------------------------
-- Generate multiple pages + navigation metadata
--------------------------------------------------------------------

function M._generate_many(pages)
	local adapters_mod = require("dwight.pubdocs.adapters")
	local helpers = require("dwight.pubdocs.helpers")

	local adapter, fw = adapters_mod.get_adapter()
	vim.notify(string.format("[dwight] 📄 Generating %d page(s) [%s]…", #pages, fw), vim.log.levels.INFO)

	local pending = #pages
	local generated = 0
	local errors = {}

	for _, page in ipairs(pages) do
		M.generate_page(page, function(content, err)
			pending = pending - 1
			if content then
				if helpers.write_page(adapter, page, content) then
					generated = generated + 1
				end
			else
				errors[#errors + 1] = err or page.path
			end
			if pending == 0 then
				-- Generate navigation metadata after all pages are written
				local nav_files = adapter.write_nav(pages, adapter.docs_dir())

				local msg = string.format(
					"[dwight] ✅ Generated %d/%d docs in %s/",
					generated,
					#pages,
					adapter.docs_dir():match("[^/]+$")
				)
				if #nav_files > 0 then
					msg = msg .. string.format(" + %d nav file(s)", #nav_files)
				end
				if #errors > 0 then
					msg = msg .. string.format(" (%d failed)", #errors)
				end
				vim.notify(msg, vim.log.levels.INFO)

				-- Populate quickfix with generated/failed pages
				local qf_items = {}
				for _, page in ipairs(pages) do
					local full_path = adapter.docs_dir() .. "/" .. page.path
					local is_err = false
					for _, e in ipairs(errors) do
						if e:match(vim.pesc(page.path)) then
							is_err = true
							break
						end
					end
					if vim.fn.filereadable(full_path) == 1 or is_err then
						qf_items[#qf_items + 1] = {
							filename = full_path,
							lnum = 1,
							text = (is_err and "❌ " or "✅ ") .. page.title .. " [" .. page.page_type .. "]",
							type = is_err and "E" or "I",
						}
					end
				end
				if #qf_items > 0 then
					vim.fn.setqflist(qf_items, "r")
					vim.fn.setqflist({}, "a", { title = "Dwight Docs: " .. #qf_items .. " page(s)" })
					vim.defer_fn(function()
						vim.cmd("botright copen")
					end, 300)
				end

				-- Hint about nav snippets that need manual integration
				for _, nf in ipairs(nav_files) do
					if nf:match("_nav_snippet") then
						vim.notify(
							"[dwight] 📋 " .. nf .. " — paste into mkdocs.yml nav section",
							vim.log.levels.INFO
						)
					elseif nf:match("_sidebar_snippet") then
						vim.notify(
							"[dwight] 📋 " .. nf .. " — paste into .vitepress/config.ts sidebar",
							vim.log.levels.INFO
						)
					end
				end

				if generated > 0 and vim.fn.filereadable(adapter.docs_dir() .. "/index.md") == 1 then
					vim.cmd("edit " .. vim.fn.fnameescape(adapter.docs_dir() .. "/index.md"))
				end
			end
		end)
	end
end

--------------------------------------------------------------------
-- :DwightDocsBrowse -- browse existing docs
--------------------------------------------------------------------

function M.browse()
	local adapters_mod = require("dwight.pubdocs.adapters")

	local adapter = adapters_mod.get_adapter()
	local dir = adapter.docs_dir()

	if vim.fn.isdirectory(dir) ~= 1 then
		vim.notify("[dwight] No docs yet. Run :DwightDocs to generate.", vim.log.levels.INFO)
		return
	end

	local files = {}
	local uv = vim.loop or vim.uv

	local function scan(d, prefix)
		local handle = uv.fs_scandir(d)
		if not handle then
			return
		end
		while true do
			local name, ftype = uv.fs_scandir_next(handle)
			if not name then
				break
			end
			if name:match("^_") then
				goto continue
			end -- skip nav snippets / _category_.json
			local rel = prefix ~= "" and (prefix .. "/" .. name) or name
			if ftype == "directory" then
				scan(d .. "/" .. name, rel)
			elseif ftype == "file" and name:match("%.md$") then
				files[#files + 1] = rel
			end
			::continue::
		end
	end
	scan(dir, "")
	table.sort(files)

	if #files == 0 then
		vim.notify("[dwight] No docs found.", vim.log.levels.INFO)
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
				prompt_title = "📄 Docs (" .. dir:match("[^/]+$") .. "/)",
				finder = finders.new_table({ results = files }),
				sorter = conf.generic_sorter({}),
				previewer = previewers.new_buffer_previewer({
					define_preview = function(self, entry)
						conf.buffer_previewer_maker(dir .. "/" .. entry[1], self.state.bufnr, {})
					end,
				}),
				attach_mappings = function(pb)
					actions.select_default:replace(function()
						local sel = action_state.get_selected_entry()
						actions.close(pb)
						if sel then
							vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/" .. sel[1]))
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
