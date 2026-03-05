-- dwight/templates.lua
-- Reusable prompt templates. Saved in .dwight/templates/.
-- :DwightTemplate picks and pre-fills the prompt. :DwightSaveTemplate saves current.

local M = {}

local uv = vim.loop or vim.uv

local function templates_dir()
	return require("dwight.project").dir() .. "/templates"
end

--------------------------------------------------------------------
-- Built-in templates
--------------------------------------------------------------------

M.builtins = {
	["add-error-handling"] = {
		name = "Add Error Handling",
		icon = "🛡️",
		prompt = "/refactor wrap all fallible operations in proper error handling with typed errors",
	},
	["to-async"] = {
		name = "Convert to Async",
		icon = "⚡",
		prompt = "/refactor convert callbacks to async/await, preserve behavior",
	},
	["add-types"] = {
		name = "Add Types",
		icon = "📐",
		prompt = "/refactor add full type annotations to all parameters and return types",
	},
	["extract-function"] = {
		name = "Extract Function",
		icon = "✂️",
		prompt = "/refactor extract the selected logic into a well-named helper function",
	},
	["add-logging"] = {
		name = "Add Logging",
		icon = "📋",
		prompt = "/refactor add structured logging at entry/exit/error points",
	},
	["dependency-injection"] = {
		name = "Dependency Injection",
		icon = "💉",
		prompt = "/refactor ^2 refactor to use dependency injection, extract interfaces",
	},
	["guard-clauses"] = {
		name = "Guard Clauses",
		icon = "🚧",
		prompt = "/refactor convert nested conditionals to early-return guard clauses",
	},
}

--------------------------------------------------------------------
-- List / Read
--------------------------------------------------------------------

function M.list()
	local all = {}

	-- Builtins
	for key, tmpl in pairs(M.builtins) do
		all[#all + 1] = { key = key, name = tmpl.name, icon = tmpl.icon, prompt = tmpl.prompt, builtin = true }
	end

	-- User templates
	local dir = templates_dir()
	if vim.fn.isdirectory(dir) == 1 then
		local handle = uv.fs_scandir(dir)
		if handle then
			while true do
				local name, ftype = uv.fs_scandir_next(handle)
				if not name then
					break
				end
				if (ftype == "file" or ftype == "link") and name:match("%.txt$") then
					local key = name:gsub("%.txt$", "")
					local f = io.open(dir .. "/" .. name, "r")
					if f then
						local content = f:read("*a")
						f:close()
						all[#all + 1] =
							{ key = key, name = key, icon = "📝", prompt = vim.trim(content), builtin = false }
					end
				end
			end
		end
	end

	table.sort(all, function(a, b)
		return a.key < b.key
	end)
	return all
end

--------------------------------------------------------------------
-- Save template
--------------------------------------------------------------------

function M.save(prompt_text)
	local project = require("dwight.project")
	if not project.is_initialized() then
		vim.notify("[dwight] Run :DwightInit first.", vim.log.levels.WARN)
		return
	end

	vim.ui.input({ prompt = "Template name: " }, function(name)
		if not name or name == "" then
			return
		end
		name = name:lower():gsub("[^%w_%-]", "-")

		vim.fn.mkdir(templates_dir(), "p")
		local path = templates_dir() .. "/" .. name .. ".txt"
		local f = io.open(path, "w")
		if f then
			f:write(prompt_text or "")
			f:close()
			vim.notify("[dwight] Template '" .. name .. "' saved.", vim.log.levels.INFO)
		end
	end)
end

--------------------------------------------------------------------
-- Pick template → return prompt text
--------------------------------------------------------------------

function M.pick(callback)
	local templates = M.list()
	if #templates == 0 then
		vim.notify("[dwight] No templates available.", vim.log.levels.INFO)
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
				prompt_title = "📋 Dwight Templates",
				finder = finders.new_table({
					results = templates,
					entry_maker = function(t)
						return { value = t, display = t.icon .. " " .. t.name, ordinal = t.key .. " " .. t.name }
					end,
				}),
				sorter = conf.generic_sorter({}),
				previewer = previewers.new_buffer_previewer({
					define_preview = function(self, entry)
						local t = entry.value
						local lines = {
							t.icon .. " " .. t.name,
							string.rep("─", 40),
							"",
							"Prompt:",
							"",
						}
						for _, line in ipairs(vim.split(t.prompt, "\n", { plain = true })) do
							lines[#lines + 1] = "  " .. line
						end
						if t.builtin then
							lines[#lines + 1] = ""
							lines[#lines + 1] = "(built-in template)"
						else
							lines[#lines + 1] = ""
							lines[#lines + 1] = "(user template — .dwight/templates/" .. t.key .. ".txt)"
						end
						vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
						vim.bo[self.state.bufnr].filetype = "markdown"
					end,
				}),
				attach_mappings = function(pb)
					actions.select_default:replace(function()
						local sel = action_state.get_selected_entry()
						actions.close(pb)
						if sel and callback then
							callback(sel.value.prompt)
						end
					end)
					return true
				end,
			})
			:find()
	else
		local items = {}
		for i, t in ipairs(templates) do
			items[i] = i .. ". " .. t.icon .. " " .. t.name
		end
		vim.ui.input({ prompt = table.concat(items, " | ") .. " > " }, function(c)
			if not c then
				return
			end
			local idx = tonumber(c)
			if idx and templates[idx] and callback then
				callback(templates[idx].prompt)
			end
		end)
	end
end

return M
