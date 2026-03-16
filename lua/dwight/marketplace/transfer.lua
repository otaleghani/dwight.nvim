-- dwight/marketplace/transfer.lua
-- Export / import skill bundles (with kit support).

local M = {}

--- Export current skills (and kits) as a shareable JSON bundle.
--- Returns the output path.
function M.export_skills()
	local project = require("dwight.project")
	if not project.is_initialized() then
		vim.notify("[dwight] Run :DwightInit first.", vim.log.levels.WARN)
		return nil
	end

	local skills = require("dwight.skills").list()
	if #skills == 0 then
		vim.notify("[dwight] No skills to export.", vim.log.levels.INFO)
		return nil
	end

	-- Check for installed kits
	local kits_mod = require("dwight.marketplace.kits")
	local installed_kits = kits_mod.installed()
	local has_kits = #installed_kits > 0

	local bundle = {
		format = has_kits and "dwight-kit-v1" or "dwight-skills-v1",
		exported_at = os.date("%Y-%m-%dT%H:%M:%S"),
		project = vim.fn.getcwd():match("([^/]+)$") or "unknown",
		skills = {},
	}

	for _, skill in ipairs(skills) do
		local f = io.open(skill.path, "r")
		if f then
			local content = f:read("*a")
			f:close()
			bundle.skills[#bundle.skills + 1] = {
				name = skill.name,
				content = content,
			}
		end
	end

	-- Include kit metadata if present
	if has_kits then
		bundle.kits = installed_kits
	end

	local path = project.dir() .. "/skills-bundle.json"
	local ok, json = pcall(vim.json.encode, bundle)
	if ok then
		local f = io.open(path, "w")
		if f then
			f:write(json .. "\n")
			f:close()
			local msg = string.format("[dwight] Exported %d skills", #bundle.skills)
			if has_kits then
				msg = msg .. string.format(" + %d kit(s)", #installed_kits)
			end
			msg = msg .. " to " .. path
			vim.notify(msg, vim.log.levels.INFO)
			return path
		end
	end

	vim.notify("[dwight] Export failed.", vim.log.levels.ERROR)
	return nil
end

--- Import skills (and kits) from a JSON bundle file.
function M.import_skills(path)
	local project = require("dwight.project")
	if not project.is_initialized() then
		vim.notify("[dwight] Run :DwightInit first.", vim.log.levels.WARN)
		return
	end

	local f = io.open(path, "r")
	if not f then
		vim.notify("[dwight] File not found: " .. path, vim.log.levels.ERROR)
		return
	end
	local raw = f:read("*a")
	f:close()

	local ok, bundle = pcall(vim.json.decode, raw)
	if not ok or type(bundle) ~= "table" then
		vim.notify("[dwight] Invalid bundle format.", vim.log.levels.ERROR)
		return
	end

	-- Accept both legacy and new format
	if bundle.format ~= "dwight-skills-v1" and bundle.format ~= "dwight-kit-v1" then
		vim.notify("[dwight] Unknown bundle format: " .. tostring(bundle.format), vim.log.levels.ERROR)
		return
	end

	local skills_dir = project.skills_dir()
	vim.fn.mkdir(skills_dir, "p")
	local imported = {}
	local skipped = {}

	for _, skill in ipairs(bundle.skills or {}) do
		local dest = skills_dir .. "/" .. skill.name .. ".md"
		if vim.fn.filereadable(dest) == 1 then
			skipped[#skipped + 1] = skill.name
		else
			local out = io.open(dest, "w")
			if out then
				out:write(skill.content)
				out:close()
				imported[#imported + 1] = skill.name
			end
		end
	end

	local msg = string.format("[dwight] Imported %d skills", #imported)
	if #imported > 0 then
		msg = msg .. ": " .. table.concat(
			vim.tbl_map(function(n)
				return "@" .. n
			end, imported),
			", "
		)
	end
	if #skipped > 0 then
		msg = msg .. string.format("\n  Skipped %d (already exist): %s", #skipped, table.concat(skipped, ", "))
	end

	-- Import kit metadata
	local kit_imported = 0
	if bundle.format == "dwight-kit-v1" and bundle.kits then
		local kits_mod = require("dwight.marketplace.kits")
		local state = kits_mod.load()
		local existing = {}
		for _, k in ipairs(state.installed) do
			existing[k.name] = true
		end
		for _, kit in ipairs(bundle.kits) do
			if not existing[kit.name] then
				state.installed[#state.installed + 1] = kit
				kit_imported = kit_imported + 1
			end
		end
		if kit_imported > 0 then
			kits_mod.save(state)
			msg = msg .. string.format("\n  Imported %d kit(s)", kit_imported)
		end
	end

	vim.notify(msg, vim.log.levels.INFO)
end

return M
