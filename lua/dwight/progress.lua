-- dwight/progress.lua
-- Neovim-side watcher for structured progress events from MCP servers.
-- Also generates per-task MCP config files for Claude Code agents.

local M = {}

local uv = vim.loop or vim.uv

--------------------------------------------------------------------
-- State
--------------------------------------------------------------------

M._watcher = nil -- uv.fs_event handle
M._poll_timer = nil -- fallback poll timer
M._callbacks = {} -- task_id → callback(event)
M._file_path = nil -- path to progress.jsonl
M._file_offset = 0 -- byte offset for incremental reads

--------------------------------------------------------------------
-- Watcher API
--------------------------------------------------------------------

--- Start watching a progress.jsonl file for new events.
--- Idempotent — truncates the file on first call for a fresh session.
--- @param progress_path string  Path to the NDJSON progress file
function M.start(progress_path)
	if M._watcher then
		return -- already watching
	end

	M._file_path = progress_path
	M._file_offset = 0

	-- Truncate for fresh session
	local f = io.open(progress_path, "w")
	if f then
		f:close()
	end

	-- Watch with uv.fs_event (inotify on Linux)
	M._watcher = uv.new_fs_event()
	if M._watcher then
		M._watcher:start(
			progress_path,
			{},
			vim.schedule_wrap(function(err)
				if not err then
					M._poll()
				end
			end)
		)
	end

	-- Fallback poll timer: 500ms to catch coalesced inotify events
	M._poll_timer = uv.new_timer()
	M._poll_timer:start(
		500,
		500,
		vim.schedule_wrap(function()
			M._poll()
		end)
	)
end

--- Stop the watcher and clean up.
function M.stop()
	if M._watcher then
		pcall(function()
			M._watcher:stop()
			M._watcher:close()
		end)
		M._watcher = nil
	end
	if M._poll_timer then
		pcall(function()
			M._poll_timer:stop()
			M._poll_timer:close()
		end)
		M._poll_timer = nil
	end
	M._callbacks = {}
	M._file_path = nil
	M._file_offset = 0
end

--- Register a callback for progress events from a specific task.
--- @param task_id string
--- @param callback function  Called with (event_table) for each progress event
function M.register(task_id, callback)
	M._callbacks[task_id] = callback
end

--- Remove a callback for a specific task.
--- @param task_id string
function M.unregister(task_id)
	M._callbacks[task_id] = nil
end

--- Check if any callbacks are still active.
--- @return boolean
function M.has_registrations()
	return next(M._callbacks) ~= nil
end

--- Read new lines from the progress file and dispatch to callbacks.
function M._poll()
	if not M._file_path then
		return
	end

	local f = io.open(M._file_path, "r")
	if not f then
		return
	end

	-- Seek to where we left off
	f:seek("set", M._file_offset)
	local data = f:read("*a")
	local new_offset = f:seek("cur")
	f:close()

	if not data or data == "" then
		return
	end

	M._file_offset = new_offset

	-- Parse each line as JSON and dispatch
	for line in data:gmatch("([^\n]+)") do
		local ok, event = pcall(vim.json.decode, line)
		if ok and type(event) == "table" and event.task_id then
			local cb = M._callbacks[event.task_id]
			if cb then
				pcall(cb, event)
			end
		end
	end
end

--------------------------------------------------------------------
-- MCP Config Generation
--------------------------------------------------------------------

--- Try to find a suitable Lua binary on PATH.
--- Checks luajit, lua5.1, lua in order.
--- @return string|nil  Binary name or nil if not found
function M.detect_lua_binary()
	local candidates = { "luajit", "lua5.1", "lua" }
	for _, bin in ipairs(candidates) do
		local handle = io.popen("command -v " .. bin .. " 2>/dev/null")
		if handle then
			local result = handle:read("*l")
			handle:close()
			if result and result ~= "" then
				return bin
			end
		end
	end
	return nil
end

--- Resolve the plugin root directory from the module source path.
--- @return string
function M._resolve_plugin_dir()
	local info = debug.getinfo(1, "S")
	if info and info.source then
		local path = info.source:gsub("^@", "")
		-- path is .../lua/dwight/progress.lua → go up 3 levels
		local dir = vim.fn.fnamemodify(path, ":h:h:h")
		return dir
	end
	-- Fallback: search rtp
	local rtp = vim.api.nvim_list_runtime_paths()
	for _, p in ipairs(rtp) do
		if vim.fn.filereadable(p .. "/lua/dwight/mcp_server.lua") == 1 then
			return p
		end
	end
	return vim.fn.getcwd()
end

--- Generate a per-task MCP config file for Claude Code.
--- Writes .dwight/mcp-config-{task_id}.json and returns the path,
--- or nil if no Lua interpreter is available.
--- @param task_id string
--- @return string|nil  Path to the config file, or nil
function M.inject_mcp_config(task_id)
	local lua_bin = M.detect_lua_binary()
	if not lua_bin then
		return nil
	end

	local project = require("dwight.project")
	if not project.is_initialized() then
		return nil
	end

	local dwight_dir = project.dir()
	local plugin_dir = M._resolve_plugin_dir()
	local progress_file = dwight_dir .. "/progress.jsonl"
	local server_script = plugin_dir .. "/lua/dwight/mcp_server.lua"

	-- Verify the server script exists
	if vim.fn.filereadable(server_script) ~= 1 then
		return nil
	end

	local config = {
		mcpServers = {
			["dwight-progress"] = {
				command = lua_bin,
				args = { server_script },
				env = {
					DWIGHT_PLUGIN_DIR = plugin_dir,
					DWIGHT_PROGRESS_FILE = progress_file,
					DWIGHT_TASK_ID = task_id,
					DWIGHT_SCRATCHPAD_FILE = dwight_dir .. "/scratchpad.jsonl",
				},
			},
		},
	}

	local config_path = dwight_dir .. "/mcp-config-" .. task_id .. ".json"
	local f = io.open(config_path, "w")
	if not f then
		return nil
	end
	f:write(vim.json.encode(config))
	f:close()

	return config_path
end

return M
