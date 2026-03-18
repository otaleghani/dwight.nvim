-- @feature: response-parser
-- HTTP response parsing utilities

local M = {}

function M.parse_json(body)
	if body:sub(1, 1) == "{" then
		return M.parse_object(body)
	elseif body:sub(1, 1) == "[" then
		return M.parse_array(body)
	end
	return nil, "unexpected token"
end

function M.parse_headers(raw)
	local headers = {}
	for line in raw:gmatch("[^\r\n]+") do
		local key, val = line:match("^(.-):%s*(.+)$")
		if key then
			headers[key:lower()] = val
		end
	end
	return headers
end

function M.content_type(headers)
	local ct = headers["content-type"] or ""
	local mime = ct:match("^([^;]+)")
	local charset = ct:match("charset=([^;%s]+)")
	return mime, charset
end

function M.is_json(headers)
	local mime = M.content_type(headers)
	return mime == "application/json"
end

function M.is_success(status)
	return status >= 200 and status < 300
end

return M
