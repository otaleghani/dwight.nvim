#!/usr/bin/env lua
-- dwight/mcp_server.lua
-- Standalone stdio MCP server for structured progress reporting.
-- Spawned by Claude Code as a child process via --mcp-config.
-- Reads JSON-RPC 2.0 (Content-Length framed) from stdin, writes to stdout.
--
-- Environment variables:
--   DWIGHT_PLUGIN_DIR    — plugin root, for package.path
--   DWIGHT_PROGRESS_FILE — path to .dwight/progress.jsonl
--   DWIGHT_TASK_ID       — which agent task this server belongs to

-- Bootstrap package.path from env so we can find mcp_json
local plugin_dir = os.getenv("DWIGHT_PLUGIN_DIR")
if plugin_dir then
	package.path = plugin_dir .. "/lua/?.lua;" .. plugin_dir .. "/lua/?/init.lua;" .. package.path
end

local json = require("dwight.mcp_json")

local PROGRESS_FILE = os.getenv("DWIGHT_PROGRESS_FILE") or ".dwight/progress.jsonl"
local TASK_ID = os.getenv("DWIGHT_TASK_ID") or "unknown"
local SCRATCHPAD_FILE = os.getenv("DWIGHT_SCRATCHPAD_FILE") or ".dwight/scratchpad.jsonl"

--------------------------------------------------------------------
-- I/O helpers
--------------------------------------------------------------------

local function write_response(obj)
	local body = json.encode(obj)
	io.stdout:write("Content-Length: " .. #body .. "\r\n\r\n" .. body)
	io.stdout:flush()
end

local function read_request()
	-- Read headers until empty line
	local content_length = nil
	while true do
		local line = io.stdin:read("*l")
		if not line then
			return nil -- EOF
		end
		if line == "" or line == "\r" then
			break
		end
		local len = line:match("^Content%-Length:%s*(%d+)")
		if len then
			content_length = tonumber(len)
		end
	end
	if not content_length then
		return nil
	end
	local body = io.stdin:read(content_length)
	if not body then
		return nil
	end
	local ok, req = pcall(json.decode, body)
	if not ok then
		return nil
	end
	return req
end

--------------------------------------------------------------------
-- Tool: report_progress
--------------------------------------------------------------------

local TOOL_SCHEMA = {
	name = "report_progress",
	description = "Report structured progress for the current task. Call this periodically to update the Neovim status display with your current phase, completion percentage, and what you're working on.",
	inputSchema = {
		type = "object",
		properties = {
			phase = {
				type = "string",
				description = "Current phase: planning, coding, testing, debugging, reviewing, or done",
			},
			percent = {
				type = "number",
				description = "Estimated completion percentage (0-100)",
			},
			message = {
				type = "string",
				description = "Short human-readable status message",
			},
			files_touched = {
				type = "array",
				items = { type = "string" },
				description = "Files modified so far",
			},
			tokens_used = {
				type = "number",
				description = "Approximate tokens consumed so far",
			},
		},
		required = { "phase", "message" },
	},
}

--------------------------------------------------------------------
-- Tool: report_note / read_notes (cross-agent scratchpad)
--------------------------------------------------------------------

local REPORT_NOTE_SCHEMA = {
	name = "report_note",
	description = "Share a discovery or decision with sibling agents in this swarm session. "
		.. "Use this to coordinate: interface changes, file quirks, naming decisions, "
		.. "or anything another agent working in parallel should know.",
	inputSchema = {
		type = "object",
		properties = {
			key = {
				type = "string",
				description = "Short category tag, e.g. 'interface_change', 'naming', 'bug_found'",
			},
			value = {
				type = "string",
				description = "The note content — what you want siblings to know",
			},
		},
		required = { "key", "value" },
	},
}

local READ_NOTES_SCHEMA = {
	name = "read_notes",
	description = "Read notes left by sibling agents in this swarm session. "
		.. "Check this before starting work to see if other agents have shared "
		.. "discoveries, interface changes, or coordination signals.",
	inputSchema = {
		type = "object",
		properties = {
			key = {
				type = "string",
				description = "Optional: filter notes by this key. Omit to read all notes.",
			},
		},
	},
}

local function handle_report_note(args)
	local entry = {
		agent_id = TASK_ID,
		key = args.key,
		value = args.value,
		ts = os.time(),
	}

	local f = io.open(SCRATCHPAD_FILE, "a")
	if f then
		f:write(json.encode(entry) .. "\n")
		f:flush()
		f:close()
	end

	return {
		content = {
			{ type = "text", text = "Note shared: [" .. args.key .. "] " .. args.value },
		},
	}
end

local function handle_read_notes(args)
	local f = io.open(SCRATCHPAD_FILE, "r")
	if not f then
		return {
			content = {
				{ type = "text", text = "No notes yet." },
			},
		}
	end

	local data = f:read("*a")
	f:close()

	if not data or data == "" then
		return {
			content = {
				{ type = "text", text = "No notes yet." },
			},
		}
	end

	local notes = {}
	for line in data:gmatch("([^\n]+)") do
		local ok, entry = pcall(json.decode, line)
		if ok and type(entry) == "table" and entry.key then
			if not args.key or entry.key == args.key then
				notes[#notes + 1] = string.format(
					"[%s] (%s @ %s): %s",
					entry.key or "?",
					entry.agent_id or "?",
					tostring(entry.ts or "?"),
					entry.value or ""
				)
			end
		end
	end

	if #notes == 0 then
		local msg = args.key and ("No notes found for key: " .. args.key) or "No notes yet."
		return {
			content = {
				{ type = "text", text = msg },
			},
		}
	end

	return {
		content = {
			{ type = "text", text = table.concat(notes, "\n") },
		},
	}
end

local function handle_report_progress(args)
	local event = {
		task_id = TASK_ID,
		phase = args.phase or "unknown",
		message = args.message or "",
		timestamp = os.time(),
	}
	if args.percent then
		event.percent = args.percent
	end
	if args.files_touched then
		event.files_touched = args.files_touched
	end
	if args.tokens_used then
		event.tokens_used = args.tokens_used
	end

	-- Append to progress file (NDJSON)
	local f = io.open(PROGRESS_FILE, "a")
	if f then
		f:write(json.encode(event) .. "\n")
		f:flush()
		f:close()
	end

	return {
		content = {
			{ type = "text", text = "Progress reported: [" .. event.phase .. "] " .. event.message },
		},
	}
end

--------------------------------------------------------------------
-- JSON-RPC 2.0 dispatch
--------------------------------------------------------------------

local function handle_request(req)
	local method = req.method
	local id = req.id -- nil for notifications

	if method == "initialize" then
		write_response({
			jsonrpc = "2.0",
			id = id,
			result = {
				protocolVersion = "2024-11-05",
				capabilities = {
					tools = {},
				},
				serverInfo = {
					name = "dwight-progress",
					version = "1.0.0",
				},
			},
		})
	elseif method == "notifications/initialized" then
		-- No-op notification, no response needed
	elseif method == "tools/list" then
		write_response({
			jsonrpc = "2.0",
			id = id,
			result = {
				tools = { TOOL_SCHEMA, REPORT_NOTE_SCHEMA, READ_NOTES_SCHEMA },
			},
		})
	elseif method == "tools/call" then
		local params = req.params or {}
		local tool_name = params.name
		local args = params.arguments or {}

		if tool_name == "report_progress" then
			local result = handle_report_progress(args)
			write_response({
				jsonrpc = "2.0",
				id = id,
				result = result,
			})
		elseif tool_name == "report_note" then
			local result = handle_report_note(args)
			write_response({
				jsonrpc = "2.0",
				id = id,
				result = result,
			})
		elseif tool_name == "read_notes" then
			local result = handle_read_notes(args)
			write_response({
				jsonrpc = "2.0",
				id = id,
				result = result,
			})
		else
			write_response({
				jsonrpc = "2.0",
				id = id,
				error = {
					code = -32601,
					message = "Unknown tool: " .. tostring(tool_name),
				},
			})
		end
	elseif method == "ping" then
		write_response({
			jsonrpc = "2.0",
			id = id,
			result = {},
		})
	else
		-- Unknown method
		if id then
			write_response({
				jsonrpc = "2.0",
				id = id,
				error = {
					code = -32601,
					message = "Method not found: " .. tostring(method),
				},
			})
		end
		-- Ignore unknown notifications (no id)
	end
end

--------------------------------------------------------------------
-- Main loop
--------------------------------------------------------------------

local function main()
	while true do
		local req = read_request()
		if not req then
			break -- EOF or read error
		end
		local ok, err = pcall(handle_request, req)
		if not ok then
			io.stderr:write("dwight-mcp-server error: " .. tostring(err) .. "\n")
		end
	end
end

-- Run if executed directly (not required as a module)
if not pcall(debug.getlocal, 4, 1) then
	main()
end

return {
	_handle_request = handle_request,
	_handle_report_progress = handle_report_progress,
	_handle_report_note = handle_report_note,
	_handle_read_notes = handle_read_notes,
}
