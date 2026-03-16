-- dwight/marketplace/browse.lua
-- Interactive marketplace browser UI.

local M = {}

local api = vim.api

--- Check if a pack has kit fields.
local function is_kit(pack)
	return pack.mcp_servers or pack.agent_instructions or pack.urls
end

--- Build env status string for a pack's MCP servers.
--- Returns e.g. "env: TWENTY_FIRST_API_KEY ✗" or nil.
local function env_status(pack)
	if not pack.mcp_servers then
		return nil
	end
	local parts = {}
	for _, srv in ipairs(pack.mcp_servers) do
		for _, var in ipairs(srv.env or {}) do
			local set = vim.fn.getenv(var) ~= vim.NIL
			parts[#parts + 1] = var .. (set and " ●" or " ✗")
		end
	end
	if #parts == 0 then
		return nil
	end
	return "env: " .. table.concat(parts, ", ")
end

--- Main marketplace browser.
function M.browse()
	local U = require("dwight.util")
	local detect = require("dwight.marketplace.detect")
	local matching = require("dwight.marketplace.matching")
	local packs = require("dwight.marketplace.packs")
	local install = require("dwight.marketplace.install")
	local transfer = require("dwight.marketplace.transfer")
	local suggest = require("dwight.marketplace.suggest")
	local kits_mod = require("dwight.marketplace.kits")

	local detected = detect.detect_project_type()
	local already = matching.installed_skills()
	local already_set = {}
	for _, n in ipairs(already) do
		already_set[n] = true
	end

	local installed_kits = kits_mod.installed()
	local kit_count = #installed_kits
	local active_kit_count = 0
	for _, k in ipairs(installed_kits) do
		if k.active then
			active_kit_count = active_kit_count + 1
		end
	end

	local W = 68
	local lines = {}

	-- Header
	lines[#lines + 1] = U.tui_header("Dwight Skill Marketplace", W)
	lines[#lines + 1] = ""
	lines[#lines + 1] =
		string.format("  Detected: %s", #detected.langs > 0 and table.concat(detected.langs, ", ") or "(unknown)")
	local kit_str = kit_count > 0 and string.format(" | %d kit (%d active)", kit_count, active_kit_count) or ""
	lines[#lines + 1] = string.format("  Installed: %d skills%s", #already, kit_str)
	lines[#lines + 1] = ""

	-- Helper: pack status glyph
	local function pack_glyph(pack)
		local total = #pack.skills
		local count = 0
		for _, s in ipairs(pack.skills) do
			if already_set[s.name] then
				count = count + 1
			end
		end
		if count == total then
			return "●", count
		elseif count > 0 then
			return "◐", count
		else
			return "○", count
		end
	end

	-- Recommended
	local matches = matching.suggest_packs()
	if #matches > 0 then
		lines[#lines + 1] = U.tui_header("Recommended", W)
		lines[#lines + 1] = ""
		for _, m in ipairs(matches) do
			local pack = m.pack
			local glyph, inst = pack_glyph(pack)
			local kit_tag = is_kit(pack) and " [K]" or ""
			local mcp_info = ""
			if pack.mcp_servers then
				mcp_info = string.format("  %d MCP", #pack.mcp_servers)
			end
			lines[#lines + 1] = string.format(
				"  %s %-24s %d skills%s  (%d installed)  [%s]%s",
				glyph,
				pack.display,
				#pack.skills,
				mcp_info,
				inst,
				table.concat(pack.project_types, ", "),
				kit_tag
			)
			local ev = env_status(pack)
			if ev then
				lines[#lines + 1] = "      " .. ev
			end
		end
		lines[#lines + 1] = ""
	end

	-- All packs
	lines[#lines + 1] = U.tui_header("All Packs", W)
	lines[#lines + 1] = ""
	for _, pack in ipairs(packs.PACKS) do
		local glyph, inst = pack_glyph(pack)
		local kit_tag = is_kit(pack) and " [K]" or ""
		local mcp_info = ""
		if pack.mcp_servers then
			mcp_info = string.format("  %d MCP", #pack.mcp_servers)
		end
		lines[#lines + 1] = string.format(
			"  %s  %-24s %d skills%s  (%d installed)  [%s]%s",
			glyph,
			pack.display,
			#pack.skills,
			mcp_info,
			inst,
			table.concat(pack.project_types, ", "),
			kit_tag
		)
		-- Foldable detail section
		local detail = {}
		detail[#detail + 1] = "  ▸ Pack Details ▸{{{"
		detail[#detail + 1] = "    Skills:"
		for _, s in ipairs(pack.skills) do
			if already_set[s.name] then
				detail[#detail + 1] = "      ● @" .. s.name .. " (installed)"
			else
				detail[#detail + 1] = "      ○ @" .. s.name
			end
		end
		if pack.mcp_servers then
			detail[#detail + 1] = "    MCP Servers:"
			for _, srv in ipairs(pack.mcp_servers) do
				local cmd = srv.command
				if srv.args then
					cmd = cmd .. " " .. table.concat(srv.args, " ")
				end
				detail[#detail + 1] = string.format("      %s -- %s", srv.name, cmd)
				for _, var in ipairs(srv.env or {}) do
					local set = vim.fn.getenv(var) ~= vim.NIL
					detail[#detail + 1] = string.format("        env: %s %s", var, set and "●" or "✗ not set")
				end
			end
		end
		if pack.agent_instructions then
			local preview = pack.agent_instructions:sub(1, 80):gsub("\n", " ")
			if #pack.agent_instructions > 80 then
				preview = preview .. "..."
			end
			detail[#detail + 1] = "    Instructions: " .. preview
		end
		detail[#detail + 1] = "  ▸}}}"
		for _, d in ipairs(detail) do
			lines[#lines + 1] = d
		end
	end
	lines[#lines + 1] = ""

	-- Actions
	lines[#lines + 1] = U.tui_header("Actions", W)
	lines[#lines + 1] = "  i  Install a pack        e  Export skills        m  Import skills"
	lines[#lines + 1] = "  s  Suggest for project   g  Generate custom      u  Uninstall pack"
	lines[#lines + 1] = "  t  Toggle kit            q  Close"

	local buf = api.nvim_create_buf(false, true)
	U.buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].filetype = "dwight_marketplace"

	vim.cmd("botright split")
	local win = api.nvim_get_current_win()
	api.nvim_win_set_buf(win, buf)
	api.nvim_win_set_height(win, math.min(#lines + 2, math.floor(vim.o.lines * 0.6)))

	-- Use shared TUI highlighting + marketplace-specific additions
	U.apply_tui_syntax(buf)
	pcall(function()
		api.nvim_buf_call(buf, function()
			vim.cmd([[
        syntax match DwightWarn /◐/
        syntax match DwightMktSkill /@[a-z][a-z0-9_-]*/
        syntax match DwightMktKit /\[K\]/
      ]])
		end)
	end)
	local hl = api.nvim_set_hl
	hl(0, "DwightMktSkill", { fg = "#7dcfff", default = true })
	hl(0, "DwightMktKit", { fg = "#e0af68", bold = true, default = true })

	U.setup_tui_win(win, { foldlevel = 0 })

	local function close()
		pcall(api.nvim_win_close, win, true)
	end

	vim.keymap.set("n", "q", close, { buffer = buf })
	vim.keymap.set("n", "<Esc>", close, { buffer = buf })

	vim.keymap.set("n", "i", function()
		close()
		install.install_interactive()
	end, { buffer = buf, desc = "Install pack" })

	vim.keymap.set("n", "e", function()
		close()
		transfer.export_skills()
	end, { buffer = buf, desc = "Export skills" })

	vim.keymap.set("n", "m", function()
		close()
		vim.ui.input({ prompt = "Path to skill bundle JSON: ", completion = "file" }, function(path)
			if path and path ~= "" then
				transfer.import_skills(path)
			end
		end)
	end, { buffer = buf, desc = "Import skills" })

	vim.keymap.set("n", "s", function()
		close()
		suggest.auto_suggest()
	end, { buffer = buf, desc = "Suggest for project" })

	vim.keymap.set("n", "g", function()
		close()
		require("dwight.skills").generate()
	end, { buffer = buf, desc = "Generate custom skill" })

	vim.keymap.set("n", "u", function()
		close()
		local pack_list = packs.PACKS
		local items = {}
		local pack_names = {}
		for _, pack in ipairs(pack_list) do
			local has_skills = false
			for _, s in ipairs(pack.skills) do
				if already_set[s.name] then
					has_skills = true
					break
				end
			end
			local has_kit = false
			for _, k in ipairs(installed_kits) do
				if k.name == pack.name then
					has_kit = true
					break
				end
			end
			if has_skills or has_kit then
				local kit_tag = is_kit(pack) and " [K]" or ""
				items[#items + 1] = string.format("%s%s — %s", pack.display, kit_tag, pack.description)
				pack_names[#pack_names + 1] = pack.name
			end
		end
		if #items == 0 then
			vim.notify("[dwight] No packs installed to uninstall.", vim.log.levels.INFO)
			return
		end
		require("dwight.select").pick(items, {
			prompt = "Uninstall which pack?",
		}, function(_, idx)
			if idx then
				install.uninstall_pack(pack_names[idx])
			end
		end)
	end, { buffer = buf, desc = "Uninstall pack" })

	vim.keymap.set("n", "t", function()
		close()
		local items = {}
		local kit_names = {}
		for _, k in ipairs(installed_kits) do
			local state = k.active and "active" or "inactive"
			items[#items + 1] = string.format("%s (%s)", k.name, state)
			kit_names[#kit_names + 1] = k.name
		end
		if #items == 0 then
			vim.notify("[dwight] No kits installed to toggle.", vim.log.levels.INFO)
			return
		end
		require("dwight.select").pick(items, {
			prompt = "Toggle which kit?",
		}, function(_, idx)
			if idx then
				kits_mod.toggle(kit_names[idx])
			end
		end)
	end, { buffer = buf, desc = "Toggle kit active/inactive" })
end

return M
