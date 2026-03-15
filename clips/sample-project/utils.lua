-- @feature: utils
-- String and URL utility functions

local M = {}

function M.parse_url(url)
  if type(url) ~= "string" then return nil end
  local protocol, host, port, path =
    url:match("^(https?)://([^:/]+):?(%d*)(.*)$")
  if not host then return nil end
  return {
    protocol = protocol,
    host = host,
    port = port ~= "" and tonumber(port) or (protocol == "https" and 443 or 80),
    path = path ~= "" and path or "/",
  }
end

function M.encode_query(params)
  local parts = {}
  for k, v in pairs(params) do
    table.insert(parts, M.url_encode(tostring(k)) .. "=" .. M.url_encode(tostring(v)))
  end
  table.sort(parts)
  return table.concat(parts, "&")
end

function M.url_encode(str)
  return str:gsub("([^%w%-%.%_%~])", function(c)
    return string.format("%%%02X", string.byte(c))
  end)
end

function M.url_decode(str)
  return str:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end)
end

function M.trim(str)
  return str:match("^%s*(.-)%s*$")
end

function M.split(str, sep)
  local parts = {}
  for part in str:gmatch("[^" .. sep .. "]+") do
    table.insert(parts, part)
  end
  return parts
end

return M
