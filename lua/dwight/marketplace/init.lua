-- dwight/marketplace/init.lua
-- Skill marketplace: project templates, community skill registry, auto-suggest.

local M = {}

local detect = require("dwight.marketplace.detect")
local packs = require("dwight.marketplace.packs")
local matching = require("dwight.marketplace.matching")
local install = require("dwight.marketplace.install")
local transfer = require("dwight.marketplace.transfer")
local suggest = require("dwight.marketplace.suggest")
local browse = require("dwight.marketplace.browse")

-- Re-export detect
M.DETECTORS = detect.DETECTORS
M.detect_project_type = detect.detect_project_type

-- Re-export packs
M.PACKS = packs.PACKS

-- Re-export matching
M.suggest_packs = matching.suggest_packs

-- Re-export install
M.install_pack = install.install_pack
M.install_interactive = install.install_interactive
M.uninstall_pack = install.uninstall_pack

-- Re-export transfer
M.export_skills = transfer.export_skills
M.import_skills = transfer.import_skills

-- Re-export suggest
M.auto_suggest = suggest.auto_suggest

-- Re-export browse
M.browse = browse.browse

function M.run(target)
	if target == "install" then
		M.install_interactive()
	elseif target == "suggest" then
		M.auto_suggest()
	elseif target == "export" then
		M.export_skills()
	elseif target == "import" then
		vim.ui.input({ prompt = "Path to skill bundle JSON: ", completion = "file" }, function(path)
			if path and path ~= "" then
				M.import_skills(path)
			end
		end)
	elseif target == "detect" then
		local detected = M.detect_project_type()
		vim.notify(
			string.format(
				"[dwight] Detected: %s\n  Types: %s\n  Langs: %s",
				detected.primary,
				table.concat(detected.types, ", "),
				table.concat(detected.langs, ", ")
			),
			vim.log.levels.INFO
		)
	elseif target == "kits" then
		M.kit_status()
	elseif target == "toggle" then
		M.kit_toggle_interactive()
	elseif target == "uninstall" then
		M.uninstall_interactive()
	else
		M.browse()
	end
end

--- Show installed kit status.
function M.kit_status()
	local kits = require("dwight.marketplace.kits")
	local installed = kits.installed()
	if #installed == 0 then
		vim.notify("[dwight] No kits installed. Use :DwightMarketplace install to add one.", vim.log.levels.INFO)
		return
	end

	local mcp = require("dwight.mcp")
	local running = {}
	for _, name in ipairs(mcp.server_names()) do
		running[name] = true
	end

	local lines = { "Installed Kits:" }
	for _, kit in ipairs(installed) do
		local state = kit.active and "active" or "inactive"
		lines[#lines + 1] = string.format("  %s %s (%s)", kit.active and "●" or "○", kit.name, state)
		if kit.mcp_servers then
			for _, srv in ipairs(kit.mcp_servers) do
				local srv_state = running[srv.name] and "running" or "stopped"
				local env_parts = {}
				for _, var in ipairs(srv.env or {}) do
					local set = vim.fn.getenv(var) ~= vim.NIL
					env_parts[#env_parts + 1] = var .. (set and " ●" or " ✗")
				end
				local env_str = #env_parts > 0 and ("  env: " .. table.concat(env_parts, ", ")) or ""
				lines[#lines + 1] = string.format("    MCP: %s (%s)%s", srv.name, srv_state, env_str)
			end
		end
		if kit.agent_instructions then
			lines[#lines + 1] = string.format("    Agent instructions (%d chars)", #kit.agent_instructions)
		end
	end
	vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

--- Interactive kit toggle.
function M.kit_toggle_interactive()
	local kits = require("dwight.marketplace.kits")
	local installed = kits.installed()
	if #installed == 0 then
		vim.notify("[dwight] No kits installed.", vim.log.levels.INFO)
		return
	end
	local items = {}
	local names = {}
	for _, k in ipairs(installed) do
		local state = k.active and "active" or "inactive"
		items[#items + 1] = string.format("%s (%s)", k.name, state)
		names[#names + 1] = k.name
	end
	require("dwight.select").pick(items, { prompt = "Toggle which kit?" }, function(_, idx)
		if idx then
			kits.toggle(names[idx])
		end
	end)
end

--- Interactive uninstall.
function M.uninstall_interactive()
	local kits = require("dwight.marketplace.kits")
	local matching_mod = require("dwight.marketplace.matching")
	local already = matching_mod.installed_skills()
	local already_set = {}
	for _, n in ipairs(already) do
		already_set[n] = true
	end
	local installed_kits = kits.installed()
	local kit_set = {}
	for _, k in ipairs(installed_kits) do
		kit_set[k.name] = true
	end

	local items = {}
	local pack_names = {}
	for _, pack in ipairs(packs.PACKS) do
		local has_skills = false
		for _, s in ipairs(pack.skills) do
			if already_set[s.name] then
				has_skills = true
				break
			end
		end
		if has_skills or kit_set[pack.name] then
			items[#items + 1] = string.format("%s — %s", pack.display, pack.description)
			pack_names[#pack_names + 1] = pack.name
		end
	end
	if #items == 0 then
		vim.notify("[dwight] No packs installed to uninstall.", vim.log.levels.INFO)
		return
	end
	require("dwight.select").pick(items, { prompt = "Uninstall which pack?" }, function(_, idx)
		if idx then
			install.uninstall_pack(pack_names[idx])
		end
	end)
end

return M
