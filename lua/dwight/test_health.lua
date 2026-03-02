-- tests/test_health.lua
-- Tests for the health check module.

vim.opt.rtp:prepend(vim.fn.getcwd())

local T = _T

-- Mock project module
package.preload["dwight.project"] = function()
  return {
    is_initialized = function() return true end,
    dir = function() return vim.fn.tempname() end,
  }
end

local health = require("dwight.health")

io.write("── health.check ──\n")

T.test("check returns a table of results", function()
  local results = health.check()
  T.assert(type(results) == "table", "should return a table")
  T.assert(#results > 0, "should have at least one check")
end)

T.test("each result has ok, name, detail", function()
  local results = health.check()
  for _, r in ipairs(results) do
    T.assert(type(r.ok) == "boolean", "result.ok should be boolean for: " .. (r.name or "?"))
    T.assert(type(r.name) == "string" and r.name ~= "", "result.name should be non-empty string")
    T.assert(type(r.detail) == "string" and r.detail ~= "", "result.detail should be non-empty string")
  end
end)

T.test("git check is included", function()
  local results = health.check()
  local found = false
  for _, r in ipairs(results) do
    if r.name == "Git repository" then found = true end
  end
  T.ok(found, "should include git repository check")
end)

T.test("backend check is included", function()
  local results = health.check()
  local found = false
  for _, r in ipairs(results) do
    if r.name:match("^Backend:") then found = true end
  end
  T.ok(found, "should include backend check")
end)

T.test("project check is included", function()
  local results = health.check()
  local found = false
  for _, r in ipairs(results) do
    if r.name == "Dwight project" then found = true end
  end
  T.ok(found, "should include project check")
end)

T.test("node check is included", function()
  local results = health.check()
  local found = false
  for _, r in ipairs(results) do
    if r.name == "Node.js" then found = true end
  end
  T.ok(found, "should include Node.js check")
end)
