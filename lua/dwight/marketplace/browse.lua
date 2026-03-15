-- dwight/marketplace/browse.lua
-- Interactive marketplace browser UI.

local M = {}

local api = vim.api
local _flatten = require("dwight.util").flatten_lines

--- Main marketplace browser.
function M.browse()
	local detect = require("dwight.marketplace.detect")
	local matching = require("dwight.marketplace.matching")
	local packs = require("dwight.marketplace.packs")
	local install = require("dwight.marketplace.install")
	local transfer = require("dwight.marketplace.transfer")
	local suggest = require("dwight.marketplace.suggest")

	local detected = detect.detect_project_type()
	local already = matching.installed_skills()
	local already_set = {}
	for _, n in ipairs(already) do
		already_set[n] = true
	end

	local lines = {
		"╔══════════════════════════════════════════════════════════════╗",
		"║                  Dwight Skill Marketplace                    ║",
		"╚══════════════════════════════════════════════════════════════╝",
		"",
		string.format("  Detected: %s", #detected.langs > 0 and table.concat(detected.langs, ", ") or "(unknown)"),
		string.format("  Installed: %d skills", #already),
		"",
	}

	-- Recommended first
	local matches = matching.suggest_packs()
	if #matches > 0 then
		lines[#lines + 1] =
			"── 💡 Recommended for Your Project ────────────────────────────────"
		for _, m in ipairs(matches) do
			local pack = m.pack
			local skill_status = {}
			local all_installed = true
			for _, s in ipairs(pack.skills) do
				if already_set[s.name] then
					skill_status[#skill_status + 1] = "  ✅ @" .. s.name .. " (installed)"
				else
					skill_status[#skill_status + 1] = "  📥 @" .. s.name
					all_installed = false
				end
			end
			local marker = all_installed and "✅" or "📦"
			lines[#lines + 1] = string.format("  %s %s — %s", marker, pack.display, pack.description)
			for _, ss in ipairs(skill_status) do
				lines[#lines + 1] = "    " .. ss
			end
			lines[#lines + 1] = ""
		end
	end

	-- All packs
	lines[#lines + 1] =
		"── 📚 All Skill Packs ─────────────────────────────────────────────"
	for _, pack in ipairs(packs.PACKS) do
		local skill_count = #pack.skills
		local installed_count = 0
		for _, s in ipairs(pack.skills) do
			if already_set[s.name] then
				installed_count = installed_count + 1
			end
		end
		local status = installed_count == skill_count and "✅" or installed_count > 0 and "🔶" or "📦"
		lines[#lines + 1] = string.format(
			"  %s %-25s %d skills  (%d installed)  [%s]",
			status,
			pack.display,
			skill_count,
			installed_count,
			table.concat(pack.project_types, ", ")
		)
	end
	lines[#lines + 1] = ""

	-- Actions
	lines[#lines + 1] =
		"── Actions ─────────────────────────────────────────────────────────"
	lines[#lines + 1] = "  i — Install a pack     e — Export skills     m — Import skills"
	lines[#lines + 1] = "  s — Suggest for project g — Generate custom   q — Close"

	local buf = api.nvim_create_buf(false, true)
	api.nvim_buf_set_lines(buf, 0, -1, false, _flatten(lines))
	vim.bo[buf].modifiable = false
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].filetype = "dwight_marketplace"

	vim.cmd("botright split")
	local win = api.nvim_get_current_win()
	api.nvim_win_set_buf(win, buf)
	api.nvim_win_set_height(win, math.min(#lines + 2, math.floor(vim.o.lines * 0.6)))

	-- Highlights
	pcall(function()
		api.nvim_buf_call(buf, function()
			vim.cmd([[
        syntax match DwightMktHeader /^[╔╚║].*$/
        syntax match DwightMktSection /^──.*──$/
        syntax match DwightMktInstalled /✅/
        syntax match DwightMktAvailable /📦/
        syntax match DwightMktPartial /🔶/
        syntax match DwightMktSkill /@[a-z][a-z0-9_-]*/
      ]])
		end)
	end)

	local hl = api.nvim_set_hl
	hl(0, "DwightMktHeader", { fg = "#bb9af7", bold = true, default = true })
	hl(0, "DwightMktSection", { fg = "#7aa2f7", bold = true, default = true })
	hl(0, "DwightMktInstalled", { fg = "#9ece6a", default = true })
	hl(0, "DwightMktSkill", { fg = "#7dcfff", default = true })

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
end

return M
