-- dwight/mcp_json.lua
-- Pure Lua 5.1 JSON encoder/decoder for standalone MCP server use.
-- No vim dependency — must work with plain lua/luajit interpreters.

local M = {}

--------------------------------------------------------------------
-- Encoder
--------------------------------------------------------------------

local encode_value -- forward declaration

local escape_map = {
	['"'] = '\\"',
	["\\"] = "\\\\",
	["\b"] = "\\b",
	["\f"] = "\\f",
	["\n"] = "\\n",
	["\r"] = "\\r",
	["\t"] = "\\t",
}

local function encode_string(s)
	local escaped = s:gsub('[%z\1-\31\\"]', function(c)
		if escape_map[c] then
			return escape_map[c]
		end
		return string.format("\\u%04x", c:byte())
	end)
	return '"' .. escaped .. '"'
end

--- Check if a table is an array (sequential integer keys starting at 1).
local function is_array(t)
	if type(t) ~= "table" then
		return false
	end
	local n = #t
	if n == 0 then
		-- Empty table: check if it has any keys at all
		return next(t) == nil
	end
	for k in pairs(t) do
		if type(k) ~= "number" or k < 1 or k > n or k ~= math.floor(k) then
			return false
		end
	end
	return true
end

local function encode_array(t)
	local parts = {}
	for i = 1, #t do
		parts[i] = encode_value(t[i])
	end
	return "[" .. table.concat(parts, ",") .. "]"
end

local function encode_object(t)
	local parts = {}
	for k, v in pairs(t) do
		if type(k) == "string" then
			parts[#parts + 1] = encode_string(k) .. ":" .. encode_value(v)
		end
	end
	return "{" .. table.concat(parts, ",") .. "}"
end

encode_value = function(val)
	local vtype = type(val)
	if val == nil then
		return "null"
	elseif vtype == "boolean" then
		return val and "true" or "false"
	elseif vtype == "number" then
		if val ~= val then
			return "null" -- NaN
		elseif val == 1 / 0 or val == -1 / 0 then
			return "null" -- Inf
		elseif val == math.floor(val) and math.abs(val) < 1e15 then
			return string.format("%d", val)
		else
			return string.format("%.14g", val)
		end
	elseif vtype == "string" then
		return encode_string(val)
	elseif vtype == "table" then
		if is_array(val) then
			return encode_array(val)
		else
			return encode_object(val)
		end
	else
		return "null"
	end
end

function M.encode(val)
	return encode_value(val)
end

--------------------------------------------------------------------
-- Decoder
--------------------------------------------------------------------

local decode_value -- forward declaration

local function skip_ws(str, pos)
	return str:match("^%s*()", pos)
end

local function decode_null(str, pos)
	if str:sub(pos, pos + 3) == "null" then
		return nil, pos + 4
	end
	error("expected null at position " .. pos)
end

local function decode_true(str, pos)
	if str:sub(pos, pos + 3) == "true" then
		return true, pos + 4
	end
	error("expected true at position " .. pos)
end

local function decode_false(str, pos)
	if str:sub(pos, pos + 4) == "false" then
		return false, pos + 5
	end
	error("expected false at position " .. pos)
end

local function decode_number(str, pos)
	local num_str = str:match("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", pos)
	if not num_str then
		error("invalid number at position " .. pos)
	end
	local val = tonumber(num_str)
	if not val then
		error("invalid number at position " .. pos)
	end
	return val, pos + #num_str
end

local unescape_map = {
	['"'] = '"',
	["\\"] = "\\",
	["/"] = "/",
	["b"] = "\b",
	["f"] = "\f",
	["n"] = "\n",
	["r"] = "\r",
	["t"] = "\t",
}

local function decode_string(str, pos)
	if str:byte(pos) ~= 34 then -- '"'
		error("expected string at position " .. pos)
	end
	pos = pos + 1
	local parts = {}
	while pos <= #str do
		local c = str:byte(pos)
		if c == 34 then -- closing '"'
			return table.concat(parts), pos + 1
		elseif c == 92 then -- '\'
			pos = pos + 1
			local esc = str:sub(pos, pos)
			if esc == "u" then
				local hex = str:sub(pos + 1, pos + 4)
				local code = tonumber(hex, 16)
				if not code then
					error("invalid unicode escape at position " .. pos)
				end
				if code < 0x80 then
					parts[#parts + 1] = string.char(code)
				elseif code < 0x800 then
					parts[#parts + 1] = string.char(0xC0 + math.floor(code / 64), 0x80 + (code % 64))
				else
					parts[#parts + 1] = string.char(
						0xE0 + math.floor(code / 4096),
						0x80 + math.floor((code % 4096) / 64),
						0x80 + (code % 64)
					)
				end
				pos = pos + 5
			elseif unescape_map[esc] then
				parts[#parts + 1] = unescape_map[esc]
				pos = pos + 1
			else
				error("invalid escape character at position " .. pos)
			end
		else
			-- Find next special char
			local next_special = str:find('[\\"]', pos)
			if next_special then
				parts[#parts + 1] = str:sub(pos, next_special - 1)
				pos = next_special
			else
				parts[#parts + 1] = str:sub(pos)
				pos = #str + 1
			end
		end
	end
	error("unterminated string at position " .. pos)
end

local function decode_array(str, pos)
	pos = pos + 1 -- skip '['
	pos = skip_ws(str, pos)
	local arr = {}
	if str:byte(pos) == 93 then -- ']'
		return arr, pos + 1
	end
	while true do
		local val
		val, pos = decode_value(str, pos)
		arr[#arr + 1] = val
		pos = skip_ws(str, pos)
		local c = str:byte(pos)
		if c == 93 then -- ']'
			return arr, pos + 1
		elseif c == 44 then -- ','
			pos = skip_ws(str, pos + 1)
		else
			error("expected ',' or ']' in array at position " .. pos)
		end
	end
end

local function decode_object(str, pos)
	pos = pos + 1 -- skip '{'
	pos = skip_ws(str, pos)
	local obj = {}
	if str:byte(pos) == 125 then -- '}'
		return obj, pos + 1
	end
	while true do
		local key
		key, pos = decode_string(str, pos)
		pos = skip_ws(str, pos)
		if str:byte(pos) ~= 58 then -- ':'
			error("expected ':' in object at position " .. pos)
		end
		pos = skip_ws(str, pos + 1)
		local val
		val, pos = decode_value(str, pos)
		obj[key] = val
		pos = skip_ws(str, pos)
		local c = str:byte(pos)
		if c == 125 then -- '}'
			return obj, pos + 1
		elseif c == 44 then -- ','
			pos = skip_ws(str, pos + 1)
		else
			error("expected ',' or '}' in object at position " .. pos)
		end
	end
end

decode_value = function(str, pos)
	pos = skip_ws(str, pos)
	local c = str:byte(pos)
	if c == 34 then -- '"'
		return decode_string(str, pos)
	elseif c == 123 then -- '{'
		return decode_object(str, pos)
	elseif c == 91 then -- '['
		return decode_array(str, pos)
	elseif c == 116 then -- 't'
		return decode_true(str, pos)
	elseif c == 102 then -- 'f'
		return decode_false(str, pos)
	elseif c == 110 then -- 'n'
		return decode_null(str, pos)
	elseif c == 45 or (c >= 48 and c <= 57) then -- '-' or digit
		return decode_number(str, pos)
	else
		error("unexpected character '" .. (str:sub(pos, pos)) .. "' at position " .. pos)
	end
end

function M.decode(str)
	if type(str) ~= "string" or str == "" then
		error("expected non-empty JSON string")
	end
	local val, pos = decode_value(str, 1)
	pos = skip_ws(str, pos)
	if pos <= #str then
		error("trailing content at position " .. pos)
	end
	return val
end

return M
