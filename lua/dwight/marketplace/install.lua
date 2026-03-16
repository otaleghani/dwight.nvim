-- dwight/marketplace/install.lua
-- Install skill packs and kits.

local M = {}

--- Check if a pack has kit fields (MCP servers, agent instructions, or URLs).
local function is_kit(pack)
	return pack.mcp_servers or pack.agent_instructions or pack.urls
end

--- Install a skill pack: writes each skill .md to .dwight/skills/.
--- If the pack has kit fields, also saves to kits.json and starts MCP servers.
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

	-- Handle kit fields: MCP servers, agent instructions
	if is_kit(pack) then
		local kits = require("dwight.marketplace.kits")
		local state = kits.load()

		-- Remove existing kit record if re-installing
		local new_installed = {}
		for _, k in ipairs(state.installed) do
			if k.name ~= pack_name then
				new_installed[#new_installed + 1] = k
			end
		end

		local record = {
			name = pack_name,
			installed_at = os.date("%Y-%m-%dT%H:%M:%S"),
			active = true,
		}

		if pack.mcp_servers then
			record.mcp_servers = pack.mcp_servers
		end

		if pack.agent_instructions then
			record.agent_instructions = pack.agent_instructions
		end

		new_installed[#new_installed + 1] = record
		state.installed = new_installed
		kits.save(state)

		-- Check env vars for MCP servers
		if pack.mcp_servers then
			local missing = {}
			for _, srv in ipairs(pack.mcp_servers) do
				for _, var in ipairs(srv.env or {}) do
					if vim.fn.getenv(var) == vim.NIL then
						missing[#missing + 1] = var
					end
				end
			end
			if #missing > 0 then
				vim.notify("[dwight] MCP requires: " .. table.concat(missing, ", "), vim.log.levels.WARN)
			end
		end

		-- Start MCP servers
		if pack.mcp_servers then
			pcall(function()
				local mcp = require("dwight.mcp")
				for _, srv in ipairs(pack.mcp_servers) do
					mcp.start_server(srv.name, srv)
				end
			end)
		end

		-- Fetch URL-based skills asynchronously
		if pack.urls then
			pcall(function()
				local skill_fetch = require("dwight.skill_fetch")
				for _, url_entry in ipairs(pack.urls) do
					skill_fetch._generate_skill(url_entry.name, nil, nil, url_entry.url)
				end
			end)
		end
	end

	if #installed > 0 then
		local label = is_kit(pack) and "kit" or "pack"
		vim.notify(
			string.format(
				"[dwight] Installed %s '%s': %s",
				label,
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

--- Uninstall a pack: remove skill files and kit record.
function M.uninstall_pack(pack_name)
	local project = require("dwight.project")
	local packs = require("dwight.marketplace.packs")
	if not project.is_initialized() then
		vim.notify("[dwight] Run :DwightInit first.", vim.log.levels.WARN)
		return
	end

	-- Find the pack definition for skill names
	local pack
	for _, p in ipairs(packs.PACKS) do
		if p.name == pack_name then
			pack = p
			break
		end
	end

	-- Remove skill files
	if pack then
		local skills_dir = project.skills_dir()
		for _, skill in ipairs(pack.skills) do
			local path = skills_dir .. "/" .. skill.name .. ".md"
			if vim.fn.filereadable(path) == 1 then
				os.remove(path)
			end
		end
	end

	-- Remove kit record + stop MCP servers
	if pack and is_kit(pack) then
		require("dwight.marketplace.kits").uninstall(pack_name)
	end

	vim.notify(string.format("[dwight] Uninstalled pack '%s'.", pack_name), vim.log.levels.INFO)
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
		local status = new_count == 0 and "● " or "○ "
		local kit_marker = is_kit(pack) and "[K] " or ""
		local mcp_info = ""
		if pack.mcp_servers then
			mcp_info = string.format(" | %d MCP", #pack.mcp_servers)
		end
		items[#items + 1] = string.format(
			"%s%s%s — %s (%d new%s)",
			status,
			kit_marker,
			pack.display,
			pack.description,
			new_count,
			mcp_info
		)
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
