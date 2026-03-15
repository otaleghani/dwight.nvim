-- @feature: luakit-core
-- LuaKit - A lightweight HTTP toolkit for Lua

local M = {}

M.VERSION = "0.3.1"

function M.setup(opts)
  M.config = require("config").load(opts)
  M.http = require("http")
  M.utils = require("utils")
  return M
end

function M.get(url, headers)
  return M.http.request("GET", url, nil, headers)
end

function M.post(url, body, headers)
  return M.http.request("POST", url, body, headers)
end

function M.put(url, body, headers)
  return M.http.request("PUT", url, body, headers)
end

function M.delete(url, headers)
  return M.http.request("DELETE", url, nil, headers)
end

return M
