-- dwight/marketplace/kits.lua
-- Kit state management: load/save/query installed kits from .dwight/kits.json.

local M = {}

--------------------------------------------------------------------
-- Persistence
--------------------------------------------------------------------

--- Load kit state from .dwight/kits.json.
--- Returns the state table (or a fresh empty state).
function M.load()
	local project = require("dwight.project")
	local path = project.kits_file()
	local f = io.open(path, "r")
	if not f then
		return { format = "dwight-kits-v1", installed = {} }
	end
	local raw = f:read("*a")
	f:close()
	local ok, data = pcall(vim.json.decode, raw)
	if ok and type(data) == "table" and data.format == "dwight-kits-v1" then
		return data
	end
	return { format = "dwight-kits-v1", installed = {} }
end

--- Save kit state to .dwight/kits.json.
function M.save(state)
	local project = require("dwight.project")
	vim.fn.mkdir(project.dir(), "p")
	local path = project.kits_file()
	local ok, json = pcall(vim.json.encode, state)
	if ok then
		local f = io.open(path, "w")
		if f then
			f:write(json .. "\n")
			f:close()
		end
	end
end

--------------------------------------------------------------------
-- Queries
--------------------------------------------------------------------

--- Return list of installed kit records.
function M.installed()
	return M.load().installed or {}
end

--- Check if a kit is active.
function M.is_active(kit_name)
	for _, kit in ipairs(M.installed()) do
		if kit.name == kit_name and kit.active then
			return true
		end
	end
	return false
end

--- Return MCP server configs from all active kits.
function M.active_mcp_servers()
	local servers = {}
	for _, kit in ipairs(M.installed()) do
		if kit.active and kit.mcp_servers then
			for _, srv in ipairs(kit.mcp_servers) do
				servers[#servers + 1] = srv
			end
		end
	end
	return servers
end

--- Build XML string of agent instructions from active kits.
--- Capped at 4000 chars total.
function M.build_instructions_context()
	local kits = M.installed()
	local parts = {}
	local total = 0
	local MAX_CHARS = 4000

	for _, kit in ipairs(kits) do
		if kit.active and kit.agent_instructions and kit.agent_instructions ~= "" then
			if total >= MAX_CHARS then
				break
			end
			local instr = kit.agent_instructions
			if total + #instr > MAX_CHARS then
				instr = instr:sub(1, MAX_CHARS - total) .. "\n... (truncated)"
			end
			parts[#parts + 1] = string.format('  <kit name="%s">\n%s\n  </kit>', kit.name, instr)
			total = total + #instr
		end
	end

	if #parts == 0 then
		return nil
	end
	return '<kit_instructions hint="Instructions from active kits. Follow these when relevant.">\n'
		.. table.concat(parts, "\n")
		.. "\n</kit_instructions>"
end

--- Check env var status for a kit's MCP servers.
--- @param kit_name string
--- @return { var: string, set: boolean }[]
function M.check_env(kit_name)
	local packs = require("dwight.marketplace.packs")
	local pack
	for _, p in ipairs(packs.PACKS) do
		if p.name == kit_name then
			pack = p
			break
		end
	end
	if not pack or not pack.mcp_servers then
		return {}
	end
	local result = {}
	for _, srv in ipairs(pack.mcp_servers) do
		for _, var in ipairs(srv.env or {}) do
			result[#result + 1] = { var = var, set = vim.fn.getenv(var) ~= vim.NIL }
		end
	end
	return result
end

--------------------------------------------------------------------
-- Mutations
--------------------------------------------------------------------

--- Toggle active flag for a kit.
function M.toggle(kit_name)
	local state = M.load()
	local found = false
	for _, kit in ipairs(state.installed) do
		if kit.name == kit_name then
			kit.active = not kit.active
			found = true
			break
		end
	end
	if not found then
		vim.notify("[dwight] Kit not installed: " .. kit_name, vim.log.levels.WARN)
		return
	end
	M.save(state)

	local kit_active = M.is_active(kit_name)
	-- Start/stop MCP servers based on new active state
	pcall(function()
		local mcp = require("dwight.mcp")
		for _, kit in ipairs(state.installed) do
			if kit.name == kit_name and kit.mcp_servers then
				for _, srv in ipairs(kit.mcp_servers) do
					if kit_active then
						mcp.start_server(srv.name, srv)
					else
						mcp.stop_server(srv.name)
					end
				end
			end
		end
	end)

	vim.notify(
		string.format("[dwight] Kit '%s' %s.", kit_name, kit_active and "activated" or "deactivated"),
		vim.log.levels.INFO
	)
end

--- Uninstall a kit: remove from kits.json + stop MCP servers.
function M.uninstall(kit_name)
	local state = M.load()
	local removed
	local new_installed = {}
	for _, kit in ipairs(state.installed) do
		if kit.name == kit_name then
			removed = kit
		else
			new_installed[#new_installed + 1] = kit
		end
	end

	if not removed then
		vim.notify("[dwight] Kit not installed: " .. kit_name, vim.log.levels.WARN)
		return
	end

	-- Stop MCP servers
	if removed.mcp_servers then
		pcall(function()
			local mcp = require("dwight.mcp")
			for _, srv in ipairs(removed.mcp_servers) do
				mcp.stop_server(srv.name)
			end
		end)
	end

	state.installed = new_installed
	M.save(state)
	vim.notify(string.format("[dwight] Kit '%s' uninstalled.", kit_name), vim.log.levels.INFO)
end

return M
