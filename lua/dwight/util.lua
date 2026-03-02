-- dwight/util.lua
-- Shared utilities used across Dwight modules.

local M = {}

local api = vim.api

--------------------------------------------------------------------
-- Safe buffer line operations
--------------------------------------------------------------------

--- Flatten a lines array so no element contains embedded newlines.
--- nvim_buf_set_lines will error if any string in the array has \n.
--- This is the root cause of a recurring crash pattern across Dwight.
---
--- @param lines string[] — array of strings, some may contain \n
--- @return string[] — flat array where every element is a single line
function M.flatten_lines(lines)
  local out = {}
  for _, line in ipairs(lines) do
    if type(line) ~= "string" then
      out[#out + 1] = tostring(line)
    elseif line:find("\n") then
      for sub in (line .. "\n"):gmatch("([^\n]*)\n") do
        out[#out + 1] = sub
      end
    else
      out[#out + 1] = line
    end
  end
  return out
end

--- Safe wrapper around nvim_buf_set_lines.
--- Automatically flattens any embedded newlines in the lines array.
--- Drop-in replacement: same signature as nvim_buf_set_lines.
---
--- @param bufnr integer
--- @param start integer — 0-indexed start line
--- @param end_ integer — 0-indexed end line (-1 for end of buffer)
--- @param strict boolean
--- @param lines string[]
function M.buf_set_lines(bufnr, start, end_, strict, lines)
  api.nvim_buf_set_lines(bufnr, start, end_, strict, M.flatten_lines(lines))
end

--- Sanitize a string for use in a single nvim_buf_set_lines element.
--- Replaces newlines with spaces. Useful for titles, labels, spinner text.
---
--- @param s string
--- @return string
function M.oneline(s)
  if not s then return "" end
  return tostring(s):gsub("\n", " "):gsub("\r", "")
end

return M
