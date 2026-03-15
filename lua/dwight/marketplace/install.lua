-- dwight/marketplace/install.lua
-- Install skill packs.

local M = {}

--- Install a skill pack: writes each skill .md to .dwight/skills/.
--- Returns list of installed skill names.
function M.install_pack(pack_name)
	local project = require("dwight.project")
	local packs = require("dwight.marketplace.packs")
	if not project.is_initialized() then
		vim.notify("[dwight] Run :DwightInit first.", vim.log.levels.WARN)
		return {}
	end

	-- Find the pack
	local pack
	for _, p in ipairs(packs.PACKS) do
		if p.name == pack_name then
			pack = p
			break
		end
	end
	if not pack then
		vim.notify("[dwight] Pack not found: " .. pack_name, vim.log.levels.ERROR)
		return {}
	end

	local skills_dir = project.skills_dir()
	vim.fn.mkdir(skills_dir, "p")
	local installed = {}

	for _, skill in ipairs(pack.skills) do
		local path = skills_dir .. "/" .. skill.name .. ".md"
		if vim.fn.filereadable(path) == 1 then
			-- Don't overwrite existing
			vim.notify("[dwight] Skill '@" .. skill.name .. "' already exists, skipping.", vim.log.levels.INFO)
		else
			local f = io.open(path, "w")
			if f then
				f:write(skill.content)
				f:close()
				installed[#installed + 1] = skill.name
			end
		end
	end

	if #installed > 0 then
		vim.notify(
			string.format(
				"[dwight] ✅ Installed pack '%s': %s",
				pack.display,
				table.concat(
					vim.tbl_map(function(n)
						return "@" .. n
					end, installed),
					", "
				)
			),
			vim.log.levels.INFO
		)
	end

	return installed
end

--- Interactive pack installer.
function M.install_interactive()
	local packs = require("dwight.marketplace.packs")
	local matching = require("dwight.marketplace.matching")
	local items = {}
	local already = matching.installed_skills()
	local already_set = {}
	for _, n in ipairs(already) do
		already_set[n] = true
	end

	for _, pack in ipairs(packs.PACKS) do
		local new_count = 0
		for _, s in ipairs(pack.skills) do
			if not already_set[s.name] then
				new_count = new_count + 1
			end
		end
		local status = new_count == 0 and "✅ " or "📦 "
		items[#items + 1] = string.format("%s%s — %s (%d new)", status, pack.display, pack.description, new_count)
	end

	require("dwight.select").pick(items, {
		prompt = "Install which skill pack?",
	}, function(_, idx)
		if idx then
			M.install_pack(packs.PACKS[idx].name)
		end
	end)
end

return M
