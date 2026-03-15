-- dwight/ui/highlight.lua
-- Prompt buffer syntax highlighting for token sigils.

local M = {}

local api = vim.api
local ns_hl = api.nvim_create_namespace("dwight_prompt_hl")

function M.highlight_prompt_buf(buf, editable_end)
	if not api.nvim_buf_is_valid(buf) then
		return
	end
	api.nvim_buf_clear_namespace(buf, ns_hl, 0, -1)

	local lines = api.nvim_buf_get_lines(buf, 0, editable_end, false)
	local skill_names = require("dwight.skills").names()
	local skill_set = {}
	for _, n in ipairs(skill_names) do
		skill_set[n] = true
	end
	local mode_names = require("dwight.modes").list()
	local mode_set = {}
	for _, n in ipairs(mode_names) do
		mode_set[n] = true
	end
	local feat_set = {}
	pcall(function()
		for _, n in ipairs(require("dwight.features").names()) do
			feat_set[n] = true
		end
	end)
	local lib_set = {}
	pcall(function()
		for _, n in ipairs(require("dwight.libs").names()) do
			lib_set[n] = true
		end
	end)

	for i, line in ipairs(lines) do
		local row = i - 1
		-- @skills
		local pos = 1
		while true do
			local s, e, name = line:find("@([%w_%-%.]+)", pos)
			if not s then
				break
			end
			local hl = skill_set[name] and "DwightSkill" or "DwightSkillInvalid"
			api.nvim_buf_add_highlight(buf, ns_hl, hl, row, s - 1, e)
			pos = e + 1
		end
		-- /modes
		pos = 1
		while true do
			local s, e, name = line:find("/(%w[%w_]*)", pos)
			if not s then
				break
			end
			if mode_set[name] or name == "tdd" then
				api.nvim_buf_add_highlight(buf, ns_hl, "DwightMode", row, s - 1, e)
			end
			pos = e + 1
		end
		-- +modifiers (+run)
		pos = 1
		while true do
			local s, e, name = line:find("%+(%w+)", pos)
			if not s then
				break
			end
			if name == "run" then
				api.nvim_buf_add_highlight(buf, ns_hl, "DwightMode", row, s - 1, e)
			end
			pos = e + 1
		end
		-- #symbols
		pos = 1
		while true do
			local s, e = line:find("#[%w_%-%.]+", pos)
			if not s then
				break
			end
			api.nvim_buf_add_highlight(buf, ns_hl, "DwightSymbol", row, s - 1, e)
			pos = e + 1
		end
		-- !model
		pos = 1
		while true do
			local s, e = line:find("![%w_%-%./:]+", pos)
			if not s then
				break
			end
			api.nvim_buf_add_highlight(buf, ns_hl, "DwightModel", row, s - 1, e)
			pos = e + 1
		end
		-- $features
		pos = 1
		while true do
			local s, e, name = line:find("%$([%w_%-%.]+)", pos)
			if not s then
				break
			end
			local hl = feat_set[name] and "DwightFeature" or "DwightSkillInvalid"
			api.nvim_buf_add_highlight(buf, ns_hl, hl, row, s - 1, e)
			pos = e + 1
		end
		-- %libs
		pos = 1
		while true do
			local s, e, name = line:find("%%([%w_%-%.]+)", pos)
			if not s then
				break
			end
			local hl = lib_set[name] and "DwightLib" or "DwightSkillInvalid"
			api.nvim_buf_add_highlight(buf, ns_hl, hl, row, s - 1, e)
			pos = e + 1
		end
		-- &mcp resources
		pos = 1
		while true do
			local s, e = line:find("&[%w_%-%./:]+", pos)
			if not s then
				break
			end
			api.nvim_buf_add_highlight(buf, ns_hl, "DwightMcp", row, s - 1, e)
			pos = e + 1
		end
		-- ^N think depth
		pos = 1
		while true do
			local s, e = line:find("%^%d+", pos)
			if not s then
				break
			end
			api.nvim_buf_add_highlight(buf, ns_hl, "DwightThink", row, s - 1, e)
			pos = e + 1
		end
		-- +files
		pos = 1
		while true do
			local s, e = line:find("%+[%w_%-%./ ]+", pos)
			if not s then
				break
			end
			api.nvim_buf_add_highlight(buf, ns_hl, "DwightFile", row, s - 1, e)
			pos = e + 1
		end
		-- ~audit
		pos = 1
		while true do
			local s, e = line:find("~audit[:%w_%-%./:]*", pos)
			if not s then
				break
			end
			api.nvim_buf_add_highlight(buf, ns_hl, "DwightAudit", row, s - 1, e)
			pos = e + 1
		end
	end
end

return M
