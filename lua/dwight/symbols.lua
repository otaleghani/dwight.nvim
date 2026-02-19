-- dwight/symbols.lua
-- Resolve workspace symbols via LSP for cross-file context.
-- Type #symbol-name in the prompt to include a function/type/class from another file.

local M = {}

--------------------------------------------------------------------
-- Workspace Symbol Search
--------------------------------------------------------------------

--- Search workspace symbols matching a query string.
---@param query string
---@param max_results number|nil
---@return table[] List of { name, kind, filepath, line, text }
function M.search(query, max_results)
  max_results = max_results or 20
  local bufnr = vim.api.nvim_get_current_buf()

  local clients
  if vim.lsp.get_clients then
    clients = vim.lsp.get_clients({ bufnr = bufnr })
  else
    clients = vim.lsp.buf_get_clients(bufnr)
  end

  -- Check if any client supports workspace symbols
  local has_support = false
  for _, client in ipairs(clients) do
    if client.server_capabilities.workspaceSymbolProvider then
      has_support = true
      break
    end
  end
  if not has_support then return {} end

  local params = { query = query }
  local results_raw = vim.lsp.buf_request_sync(bufnr, "workspace/symbol", params, 5000)
  if not results_raw then return {} end

  local symbols = {}
  local seen = {}

  for _, client_result in pairs(results_raw) do
    if client_result.result then
      for _, sym in ipairs(client_result.result) do
        local name = sym.name
        if not seen[name] then
          seen[name] = true
          local loc = sym.location
          if loc and loc.uri then
            local kind_name = vim.lsp.protocol.SymbolKind[sym.kind] or "Unknown"
            symbols[#symbols + 1] = {
              name     = name,
              kind     = kind_name,
              filepath = vim.uri_to_fname(loc.uri),
              line     = loc.range and (loc.range.start.line + 1) or 1,
            }
          end
        end
        if #symbols >= max_results then break end
      end
    end
  end

  return symbols
end

--- Get all symbol names for fuzzy completion.
---@param query string
---@return string[]
function M.complete(query)
  local results = M.search(query, 30)
  local names = {}
  for _, s in ipairs(results) do
    names[#names + 1] = s.name
  end
  return names
end

--------------------------------------------------------------------
-- Symbol Resolution (get source code)
--------------------------------------------------------------------

--- Resolve a symbol name to its source code.
--- Returns the function/type/class body from the file where it's defined.
---@param name string Symbol name
---@return table|nil { name, kind, filepath, line, text }
function M.resolve(name)
  local results = M.search(name, 5)

  -- Find exact match first, then prefix match
  local best = nil
  for _, sym in ipairs(results) do
    if sym.name == name then
      best = sym
      break
    end
  end
  if not best and #results > 0 then
    best = results[1]
  end
  if not best then return nil end

  -- Read source code around the symbol
  local text = M._read_symbol_source(best.filepath, best.line)
  if text then
    best.text = text
  end

  return best
end

--- Resolve multiple symbol names.
---@param names string[]
---@return table[] Resolved symbols with source
function M.resolve_many(names)
  local resolved = {}
  for _, name in ipairs(names) do
    local sym = M.resolve(name)
    if sym then
      resolved[#resolved + 1] = sym
    else
      vim.notify(
        string.format("[dwight] Symbol '%s' not found via LSP workspace search.", name),
        vim.log.levels.WARN
      )
    end
  end
  return resolved
end

--- Read source code for a symbol from its file.
--- Tries to extract the full body (function/class/type).
---@param filepath string
---@param start_line number
---@return string|nil
function M._read_symbol_source(filepath, start_line)
  local ok, lines = pcall(function()
    local f = io.open(filepath, "r")
    if not f then return nil end
    local all = {}
    for line in f:lines() do
      all[#all + 1] = line
    end
    f:close()
    return all
  end)
  if not ok or not lines then return nil end

  -- Extract a reasonable chunk: from start_line, scan for the end of the block.
  -- Heuristic: track brace/indent depth, or just grab up to 50 lines.
  local max_lines = 50
  local end_line = math.min(start_line + max_lines - 1, #lines)

  -- Try to find the end of the block by tracking braces
  local depth = 0
  local found_open = false
  for i = start_line, math.min(start_line + max_lines - 1, #lines) do
    local line = lines[i]
    for c in line:gmatch("[{}]") do
      if c == "{" then depth = depth + 1; found_open = true end
      if c == "}" then depth = depth - 1 end
    end
    -- Also check for end/do blocks (Lua, Ruby, Elixir)
    if line:match("^%s*end%s*$") or line:match("^%s*end%)") or line:match("^%s*end,") then
      if found_open or i > start_line + 1 then
        end_line = i
        break
      end
    end
    if found_open and depth <= 0 then
      end_line = i
      break
    end
  end

  local extracted = {}
  for i = start_line, end_line do
    if lines[i] then
      extracted[#extracted + 1] = lines[i]
    end
  end

  if #extracted == 0 then return nil end
  return table.concat(extracted, "\n")
end

return M
