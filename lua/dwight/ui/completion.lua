-- dwight/ui/completion.lua
-- Omnifunc completion for token sigils in the prompt buffer.

local M = {}

local api = vim.api

function M.find_token_at_cursor()
	local line = api.nvim_get_current_line()
	local col = api.nvim_win_get_cursor(0)[2]
	local start = col
	while start > 0 do
		local c = line:sub(start, start)
		if
			c == "@"
			or c == "/"
			or c == "#"
			or c == "!"
			or c == "$"
			or c == "^"
			or c == "%"
			or c == "&"
			or c == "+"
			or c == "~"
		then
			return c, line:sub(start + 1, col), start
		end
		if not c:match("[%w_%-%.@/#!$%%&%^:/+~]") then
			break
		end
		start = start - 1
	end
	return nil, "", col
end

function M.omnifunc(findstart, base)
	local ui = require("dwight.ui")

	if findstart == 1 then
		local trigger, _, start_pos = M.find_token_at_cursor()
		if trigger then
			return start_pos - 1
		end
		return -3
	end

	local items = {}
	local trigger = base:sub(1, 1)
	local typed = base:sub(2):lower()

	if trigger == "@" then
		for _, name in ipairs(require("dwight.skills").names()) do
			if typed == "" or name:lower():find(typed, 1, true) then
				items[#items + 1] = { word = "@" .. name, menu = "[skill]", icase = 1 }
			end
		end
	elseif trigger == "/" then
		local modes = require("dwight.modes")
		-- Filter modes by the source buffer's filetype
		local source_ft = nil
		if ui._source_bufnr and api.nvim_buf_is_valid(ui._source_bufnr) then
			source_ft = vim.bo[ui._source_bufnr].filetype
		end
		for _, name in ipairs(modes.list_for_filetype(source_ft)) do
			if typed == "" or name:lower():find(typed, 1, true) then
				local m = modes.get(name)
				items[#items + 1] = { word = "/" .. name, menu = m.icon .. " " .. m.name, icase = 1 }
			end
		end
	elseif trigger == "#" then
		if #typed >= 1 then
			local ok, syms = pcall(function()
				return require("dwight.symbols").search(typed, 20, ui._source_bufnr)
			end)
			if ok and syms then
				for _, s in ipairs(syms) do
					local file = vim.fn.fnamemodify(s.filepath, ":t")
					items[#items + 1] = {
						word = "#" .. s.name,
						menu = string.format("[%s] %s:%d", s.kind, file, s.line),
						icase = 1,
					}
				end
			end
		end
	elseif trigger == "!" then
		-- Unified modifier: !type: or legacy !model
		if typed:match("^%w+:") then
			-- User typed !type:value -- complete the value
			local mtype, mval = typed:match("^(%w+):(.*)$")
			mtype = (mtype or ""):lower()
			mval = (mval or ""):lower()
			if mtype == "mode" then
				for _, name in ipairs(require("dwight.modes").list()) do
					if mval == "" or name:lower():find(mval, 1, true) then
						items[#items + 1] = { word = "!mode:" .. name, menu = "[mode]", icase = 1 }
					end
				end
			elseif mtype == "skill" then
				for _, name in ipairs(require("dwight.skills").names()) do
					if mval == "" or name:lower():find(mval, 1, true) then
						items[#items + 1] = { word = "!skill:" .. name, menu = "[skill]", icase = 1 }
					end
				end
			elseif mtype == "model" then
				pcall(function()
					for _, name in ipairs(require("dwight.providers").all_model_names()) do
						if mval == "" or name:lower():find(mval, 1, true) then
							items[#items + 1] = { word = "!model:" .. name, menu = "[model]", icase = 1 }
						end
					end
				end)
			elseif mtype == "feature" then
				pcall(function()
					for _, name in ipairs(require("dwight.features").names()) do
						if mval == "" or name:lower():find(mval, 1, true) then
							items[#items + 1] = { word = "!feature:" .. name, menu = "[feature]", icase = 1 }
						end
					end
				end)
			elseif mtype == "lib" then
				pcall(function()
					for _, name in ipairs(require("dwight.libs").names()) do
						if mval == "" or name:lower():find(mval, 1, true) then
							items[#items + 1] = { word = "!lib:" .. name, menu = "[lib]", icase = 1 }
						end
					end
				end)
			elseif mtype == "file" then
				pcall(function()
					for _, f in ipairs(require("dwight.treesitter").project_files(mval)) do
						items[#items + 1] = { word = "!file:" .. f, menu = "[file]", icase = 1 }
					end
				end)
			elseif mtype == "symbol" then
				pcall(function()
					local syms = require("dwight.symbols").search(mval, 20, ui._source_bufnr)
					for _, s in ipairs(syms or {}) do
						items[#items + 1] = { word = "!symbol:" .. s.name, menu = "[" .. s.kind .. "]", icase = 1 }
					end
				end)
			end
		else
			-- User typed ! -- show type picker first, then legacy model names
			local modifier_types = {
				{ word = "!mode:", menu = "🎯 pick mode" },
				{ word = "!model:", menu = "🤖 pick model" },
				{ word = "!skill:", menu = "📘 pick skill" },
				{ word = "!symbol:", menu = "🔗 pick symbol" },
				{ word = "!feature:", menu = "📋 pick feature" },
				{ word = "!lib:", menu = "📚 pick library" },
				{ word = "!file:", menu = "📁 pick file" },
				{ word = "!depth:", menu = "🧠 think depth" },
				{ word = "!audit:", menu = "👁️ peer review model" },
			}
			for _, mt in ipairs(modifier_types) do
				if typed == "" or mt.word:sub(2):lower():find(typed, 1, true) then
					items[#items + 1] = { word = mt.word, menu = mt.menu, icase = 1 }
				end
			end
			-- Also show legacy model names
			pcall(function()
				for _, name in ipairs(require("dwight.providers").all_model_names()) do
					if typed ~= "" and name:lower():find(typed, 1, true) then
						items[#items + 1] = { word = "!" .. name, menu = "[model]", icase = 1 }
					end
				end
			end)
		end
	elseif trigger == "$" then
		local ok, names = pcall(function()
			return require("dwight.features").names()
		end)
		if ok and names then
			for _, name in ipairs(names) do
				if typed == "" or name:lower():find(typed, 1, true) then
					items[#items + 1] = { word = "$" .. name, menu = "[feature]", icase = 1 }
				end
			end
		end
	elseif trigger == "^" then
		items = {
			{ word = "^2", menu = "🧠 chain-of-thought", icase = 1 },
			{ word = "^3", menu = "🧠🧠 analyze → code (2 passes)", icase = 1 },
			{ word = "^4", menu = "🧠🧠🧠 analyze → plan → code (3 passes)", icase = 1 },
		}
	elseif trigger == "%" then
		local ok, names = pcall(function()
			return require("dwight.libs").names()
		end)
		if ok and names then
			for _, name in ipairs(names) do
				if typed == "" or name:lower():find(typed, 1, true) then
					items[#items + 1] = { word = "%" .. name, menu = "[lib]", icase = 1 }
				end
			end
		end
	elseif trigger == "&" then
		local ok, names = pcall(function()
			return require("dwight.mcp").server_names()
		end)
		if ok and names then
			for _, name in ipairs(names) do
				if typed == "" or name:lower():find(typed, 1, true) then
					items[#items + 1] = { word = "&" .. name .. ":", menu = "[mcp]", icase = 1 }
				end
			end
		end
	elseif trigger == "+" then
		-- File/folder completion
		pcall(function()
			local ts = require("dwight.treesitter")
			for _, f in ipairs(ts.project_files(typed)) do
				if typed == "" or f:lower():find(typed, 1, true) then
					items[#items + 1] = { word = "+" .. f, menu = "[file]", icase = 1 }
				end
				if #items >= 30 then
					break
				end -- limit for performance
			end
		end)
	elseif trigger == "~" then
		-- ~audit completion
		items[#items + 1] = { word = "~audit", menu = "👁️ peer review (default model)", icase = 1 }
		pcall(function()
			for _, name in ipairs(require("dwight.providers").all_model_names()) do
				if typed == "" or ("audit:" .. name):lower():find(typed, 1, true) then
					items[#items + 1] = { word = "~audit:" .. name, menu = "👁️ review with " .. name, icase = 1 }
				end
			end
		end)
	end

	return items
end

return M
