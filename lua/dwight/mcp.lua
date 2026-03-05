-- dwight/mcp.lua
-- MCP (Model Context Protocol) client.
-- Spawn servers via stdio, query resources for prompt context.
-- Config: setup({ mcp_servers = { { name="docs", command="npx", args={...} } } })

local M = {}

local uv = vim.loop or vim.uv

M._servers = {} -- name → { handle, stdin, stdout, pending, resources_cache }

--------------------------------------------------------------------
-- JSON-RPC helpers
--------------------------------------------------------------------

local _msg_id = 0
local function next_id()
	_msg_id = _msg_id + 1
	return _msg_id
end

local function encode_message(msg)
	local json = vim.fn.json_encode(msg)
	return string.format("Content-Length: %d\r\n\r\n%s", #json, json)
end

local function send_request(server, method, params, callback)
	if not server or not server.stdin then
		if callback then
			callback(nil, "Server not running")
		end
		return
	end
	local id = next_id()
	server.pending[id] = callback
	local msg = { jsonrpc = "2.0", id = id, method = method, params = params or {} }
	server.stdin:write(encode_message(msg))
end

--------------------------------------------------------------------
-- Server lifecycle
--------------------------------------------------------------------

function M.start_server(name, config)
	if M._servers[name] then
		return M._servers[name]
	end

	local stdin = uv.new_pipe(false)
	local stdout = uv.new_pipe(false)
	local stderr = uv.new_pipe(false)

	local server = {
		name = name,
		stdin = stdin,
		stdout = stdout,
		pending = {},
		resources_cache = nil,
		buffer = "",
	}

	local env_table = nil
	if config.env then
		env_table = {}
		-- Inherit current env
		for k, v in pairs(vim.fn.environ()) do
			env_table[#env_table + 1] = k .. "=" .. v
		end
		for k, v in pairs(config.env) do
			env_table[#env_table + 1] = k .. "=" .. v
		end
	end

	local handle
	handle = uv.spawn(config.command, {
		args = config.args or {},
		stdio = { stdin, stdout, stderr },
		cwd = config.cwd or vim.fn.getcwd(),
		env = env_table,
	}, function(code)
		vim.schedule(function()
			M._servers[name] = nil
			if code ~= 0 then
				vim.notify("[dwight] MCP server '" .. name .. "' exited (code " .. code .. ")", vim.log.levels.WARN)
			end
		end)
		if stdin then
			stdin:close()
		end
		if stdout then
			stdout:close()
		end
		if stderr then
			stderr:close()
		end
		if handle then
			handle:close()
		end
	end)

	if not handle then
		vim.notify("[dwight] Failed to start MCP server '" .. name .. "'", vim.log.levels.ERROR)
		return nil
	end

	-- Parse JSON-RPC responses from stdout
	stdout:read_start(function(err, data)
		if err or not data then
			return
		end
		vim.schedule(function()
			server.buffer = server.buffer .. data
			M._process_buffer(server)
		end)
	end)

	stderr:read_start(function(err, data)
		if err or not data then
			return
		end
		-- Log stderr but don't error — MCP servers may log to stderr
	end)

	M._servers[name] = server

	-- Initialize
	send_request(server, "initialize", {
		protocolVersion = "2024-11-05",
		capabilities = {},
		clientInfo = { name = "dwight.nvim", version = "1.4.0" },
	}, function(result)
		if result then
			vim.notify("[dwight] MCP server '" .. name .. "' connected.", vim.log.levels.INFO)
			-- Send initialized notification
			local notif = { jsonrpc = "2.0", method = "notifications/initialized" }
			server.stdin:write(encode_message(notif))
		end
	end)

	return server
end

function M._process_buffer(server)
	while true do
		local header_end = server.buffer:find("\r\n\r\n")
		if not header_end then
			break
		end

		local header = server.buffer:sub(1, header_end - 1)
		local length = tonumber(header:match("Content%-Length:%s*(%d+)"))
		if not length then
			break
		end

		local body_start = header_end + 4
		local body_end = body_start + length - 1
		if #server.buffer < body_end then
			break
		end

		local body = server.buffer:sub(body_start, body_end)
		server.buffer = server.buffer:sub(body_end + 1)

		local ok, msg = pcall(vim.fn.json_decode, body)
		if ok and msg then
			if msg.id and server.pending[msg.id] then
				local cb = server.pending[msg.id]
				server.pending[msg.id] = nil
				cb(msg.result, msg.error)
			end
		end
	end
end

function M.stop_server(name)
	local server = M._servers[name]
	if not server then
		return
	end
	pcall(function()
		if server.stdin then
			server.stdin:close()
		end
		if server.stdout then
			server.stdout:close()
		end
	end)
	M._servers[name] = nil
end

function M.stop_all()
	for name in pairs(M._servers) do
		M.stop_server(name)
	end
end

--------------------------------------------------------------------
-- Resource queries
--------------------------------------------------------------------

function M.list_resources(name, callback)
	local server = M._servers[name]
	if not server then
		callback(nil, "Server not running")
		return
	end

	if server.resources_cache then
		callback(server.resources_cache)
		return
	end

	send_request(server, "resources/list", {}, function(result, err)
		if err then
			callback(nil, err)
			return
		end
		server.resources_cache = result and result.resources or {}
		callback(server.resources_cache)
	end)
end

function M.read_resource(name, uri, callback)
	local server = M._servers[name]
	if not server then
		callback(nil, "Server not running")
		return
	end

	send_request(server, "resources/read", { uri = uri }, function(result, err)
		if err then
			callback(nil, err)
			return
		end
		if result and result.contents and #result.contents > 0 then
			local text_parts = {}
			for _, c in ipairs(result.contents) do
				if c.text then
					text_parts[#text_parts + 1] = c.text
				end
			end
			callback(table.concat(text_parts, "\n"))
		else
			callback(nil, "Empty response")
		end
	end)
end

--- Query a resource synchronously (with timeout). For prompt injection.
function M.read_resource_sync(server_name, uri, timeout_ms)
	timeout_ms = timeout_ms or 5000
	local result, done = nil, false

	M.read_resource(server_name, uri, function(text, err)
		result = text
		done = true
	end)

	vim.wait(timeout_ms, function()
		return done
	end, 50)
	return result
end

--------------------------------------------------------------------
-- Prompt context: &server:resource token
--------------------------------------------------------------------

--- Resolve &server:resource tokens into context text.
function M.resolve_many(mcp_refs)
	local results = {}
	for _, ref in ipairs(mcp_refs or {}) do
		local server_name, resource_uri = ref:match("^([^:]+):(.+)$")
		if server_name and M._servers[server_name] then
			local text = M.read_resource_sync(server_name, resource_uri)
			if text then
				results[#results + 1] = {
					name = ref,
					content = text:sub(1, 8000), -- cap per-resource
				}
			end
		end
	end
	return results
end

--------------------------------------------------------------------
-- Setup: start servers from config
--------------------------------------------------------------------

function M.setup(config)
	for _, srv_config in ipairs(config.mcp_servers or {}) do
		if srv_config.name and srv_config.command then
			M.start_server(srv_config.name, srv_config)
		end
	end
end

--- List connected server names.
function M.server_names()
	local names = {}
	for k in pairs(M._servers) do
		names[#names + 1] = k
	end
	table.sort(names)
	return names
end

--- Show MCP server status.
function M.status()
	local names = M.server_names()
	if #names == 0 then
		vim.notify("[dwight] No MCP servers configured.", vim.log.levels.INFO)
		return
	end
	local lines = { "MCP Servers:" }
	for _, name in ipairs(names) do
		lines[#lines + 1] = "  🟢 " .. name
	end
	vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

return M
