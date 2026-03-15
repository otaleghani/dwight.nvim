-- @feature:http-client
-- HTTP client module

local M = {}

local utils = require("utils")

function M.request(method, url, body, headers)
	headers = headers or {}
	if not headers["User-Agent"] then
		headers["User-Agent"] = "luakit/0.3.1"
	end

	local parsed = utils.parse_url(url)
	if not parsed then
		return nil, "invalid URL: " .. tostring(url)
	end

	local socket = require("socket")
	local conn = socket.tcp()
	conn:settimeout(30)

	local ok, err = conn:connect(parsed.host, parsed.port or 80)
	if not ok then
		return nil, "connection failed: " .. err
	end

	local req_line = method .. " " .. parsed.path .. " HTTP/1.1\r\n"
	local header_str = ""
	for k, v in pairs(headers) do
		header_str = header_str .. k .. ": " .. v .. "\r\n"
	end
	header_str = header_str .. "Host: " .. parsed.host .. "\r\n"

	if body then
		header_str = header_str .. "Content-Length: " .. #body .. "\r\n"
	end

	conn:send(req_line .. header_str .. "\r\n" .. (body or ""))

	local response = M.read_response(conn)
	conn:close()

	return response
end

function M.read_response(conn)
	local status_line = conn:receive("*l")
	local code = tonumber(status_line:match("HTTP/%d%.%d (%d+)"))

	local headers = {}
	while true do
		local line = conn:receive("*l")
		if not line or line == "" then
			break
		end
		local key, val = line:match("^(.-):%s*(.+)$")
		if key then
			headers[key:lower()] = val
		end
	end

	local body = ""
	local len = tonumber(headers["content-length"])
	if len then
		body = conn:receive(len)
	end

	return { status = code, headers = headers, body = body }
end

return M
