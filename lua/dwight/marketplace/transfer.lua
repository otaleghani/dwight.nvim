-- dwight/marketplace/transfer.lua
-- Export / import skill bundles.

local M = {}

--- Export current skills as a shareable JSON bundle.
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

	local bundle = {
		format = "dwight-skills-v1",
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

	local path = project.dir() .. "/skills-bundle.json"
	local ok, json = pcall(vim.json.encode, bundle)
	if ok then
		local f = io.open(path, "w")
		if f then
			f:write(json .. "\n")
			f:close()
			vim.notify(
				string.format("[dwight] ✅ Exported %d skills to %s", #bundle.skills, path),
				vim.log.levels.INFO
			)
			return path
		end
	end

	vim.notify("[dwight] Export failed.", vim.log.levels.ERROR)
	return nil
end

--- Import skills from a JSON bundle file.
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
	if not ok or type(bundle) ~= "table" or bundle.format ~= "dwight-skills-v1" then
		vim.notify("[dwight] Invalid skill bundle format.", vim.log.levels.ERROR)
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

	local msg = string.format("[dwight] ✅ Imported %d skills", #imported)
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
	vim.notify(msg, vim.log.levels.INFO)
end

return M
