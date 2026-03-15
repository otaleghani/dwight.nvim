-- @feature: configuration
-- Configuration loading and validation

local M = {}

local DEFAULTS = {
  timeout = 30,
  max_redirects = 5,
  user_agent = "luakit/0.3.1",
  retry_count = 0,
  base_url = nil,
  headers = {},
}

function M.load(opts)
  opts = opts or {}
  local cfg = {}
  for k, v in pairs(DEFAULTS) do
    cfg[k] = opts[k] or v
  end
  M.validate(cfg)
  return cfg
end

function M.validate(cfg)
  assert(type(cfg.timeout) == "number" and cfg.timeout > 0,
    "timeout must be a positive number")
  assert(type(cfg.max_redirects) == "number" and cfg.max_redirects >= 0,
    "max_redirects must be non-negative")
  if cfg.base_url then
    assert(type(cfg.base_url) == "string", "base_url must be a string")
  end
end

function M.merge(base, overrides)
  local result = {}
  for k, v in pairs(base) do
    result[k] = v
  end
  for k, v in pairs(overrides or {}) do
    result[k] = v
  end
  return result
end

return M
