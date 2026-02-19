-- dwight/lsp.lua
-- Gathers rich context from active LSP servers.
-- Checks server capabilities before making requests to avoid errors.

local M = {}

local function get_config()
  return require("dwight").config
end

--- Get all active LSP clients for a buffer.
local function get_clients(bufnr)
  if vim.lsp.get_clients then
    return vim.lsp.get_clients({ bufnr = bufnr })
  end
  ---@diagnostic disable-next-line: deprecated
  return vim.lsp.buf_get_clients(bufnr)
end

--- Check if ANY client attached to this buffer supports a given method.
---@param bufnr number
---@param method string LSP method name
---@return boolean
local function server_supports(bufnr, method)
  local clients = get_clients(bufnr)
  -- Map method names to capability fields
  local cap_map = {
    ["textDocument/hover"]          = function(c) return c.server_capabilities.hoverProvider end,
    ["textDocument/typeDefinition"]  = function(c) return c.server_capabilities.typeDefinitionProvider end,
    ["textDocument/references"]      = function(c) return c.server_capabilities.referencesProvider end,
    ["textDocument/documentSymbol"]  = function(c) return c.server_capabilities.documentSymbolProvider end,
    ["textDocument/definition"]      = function(c) return c.server_capabilities.definitionProvider end,
  }
  local checker = cap_map[method]
  if not checker then return true end  -- unknown method: try anyway

  for _, client in ipairs(clients) do
    if checker(client) then return true end
  end
  return false
end

--- Synchronous LSP request with timeout. Returns nil if server doesn't support the method.
local function lsp_request_sync(bufnr, method, params, timeout_ms)
  if not server_supports(bufnr, method) then return nil end
  timeout_ms = timeout_ms or 3000
  local ok, results = pcall(vim.lsp.buf_request_sync, bufnr, method, params, timeout_ms)
  if not ok or not results then return nil end
  for _, res in pairs(results) do
    if res.result then
      return res.result
    end
  end
  return nil
end

--- Extract text from a Location or LocationLink.
local function location_to_text(loc, max_lines)
  max_lines = max_lines or 5
  local uri = loc.uri or loc.targetUri
  if not uri then return nil end
  local path = vim.uri_to_fname(uri)
  local range = loc.range or loc.targetSelectionRange or loc.targetRange
  if not range then return nil end

  local ok, lines = pcall(function()
    local f = io.open(path, "r")
    if not f then return nil end
    local all = {}
    for line in f:lines() do
      all[#all + 1] = line
    end
    f:close()
    return all
  end)
  if not ok or not lines then return nil end

  local start_line = range.start.line + 1
  local end_line = math.min(range["end"].line + 1, start_line + max_lines - 1)
  end_line = math.min(end_line, #lines)

  local extracted = {}
  for i = start_line, end_line do
    extracted[#extracted + 1] = lines[i]
  end

  return {
    path  = vim.fn.fnamemodify(path, ":."),
    line  = start_line,
    text  = table.concat(extracted, "\n"),
  }
end

--------------------------------------------------------------------
-- Context Gathering
--------------------------------------------------------------------

--- Gather full context for a selection.
function M.gather_context(selection)
  local cfg = get_config()
  local bufnr = selection.bufnr
  local clients = get_clients(bufnr)
  local has_lsp = #clients > 0

  local ctx = {
    language    = selection.filetype or vim.bo[bufnr].filetype or "unknown",
    filepath    = selection.filepath or vim.api.nvim_buf_get_name(bufnr),
    diagnostics = {},
    hover_info  = {},
    type_defs   = {},
    references  = {},
    symbols     = {},
    surrounding = "",
  }

  if has_lsp then
    if cfg.include_diagnostics then
      ctx.diagnostics = M._get_diagnostics(bufnr, selection.start_line, selection.end_line)
    end
    if cfg.include_type_info then
      ctx.hover_info = M._get_hover_info(bufnr, selection)
      ctx.type_defs = M._get_type_definitions(bufnr, selection)
    end
    if cfg.include_references then
      ctx.references = M._get_references(bufnr, selection, cfg.max_references)
    end
    ctx.symbols = M._get_document_symbols(bufnr)
  end

  -- Always gather surrounding code
  ctx.surrounding = M._get_surrounding(bufnr, selection, cfg.lsp_context_lines)

  return ctx
end

--- Get diagnostics in the selection range.
function M._get_diagnostics(bufnr, start_line, end_line)
  local all = vim.diagnostic.get(bufnr)
  local relevant = {}
  for _, d in ipairs(all) do
    if d.lnum >= (start_line - 1) and d.lnum <= (end_line - 1) then
      relevant[#relevant + 1] = {
        line     = d.lnum + 1,
        severity = vim.diagnostic.severity[d.severity] or "HINT",
        message  = d.message,
        source   = d.source or "",
      }
    end
  end
  return relevant
end

--- Get hover information for key positions.
function M._get_hover_info(bufnr, selection)
  local results = {}
  local positions = {
    { selection.start_line - 1, selection.start_col or 0 },
  }
  if selection.end_line - selection.start_line > 2 then
    local mid = math.floor((selection.start_line + selection.end_line) / 2) - 1
    positions[#positions + 1] = { mid, 0 }
  end

  local seen = {}
  for _, pos in ipairs(positions) do
    local params = {
      textDocument = vim.lsp.util.make_text_document_params(bufnr),
      position     = { line = pos[1], character = pos[2] },
    }
    local result = lsp_request_sync(bufnr, "textDocument/hover", params, 2000)
    if result and result.contents then
      local text = ""
      if type(result.contents) == "string" then
        text = result.contents
      elseif result.contents.value then
        text = result.contents.value
      elseif vim.islist(result.contents) then
        local parts = {}
        for _, c in ipairs(result.contents) do
          parts[#parts + 1] = type(c) == "string" and c or (c.value or "")
        end
        text = table.concat(parts, "\n")
      end
      if text ~= "" and not seen[text] then
        seen[text] = true
        results[#results + 1] = { line = pos[1] + 1, info = text }
      end
    end
  end
  return results
end

--- Get type definitions (only if server supports it).
function M._get_type_definitions(bufnr, selection)
  local results = {}
  local params = {
    textDocument = vim.lsp.util.make_text_document_params(bufnr),
    position     = { line = selection.start_line - 1, character = selection.start_col or 0 },
  }
  local result = lsp_request_sync(bufnr, "textDocument/typeDefinition", params, 2000)
  if result then
    local locs = vim.islist(result) and result or { result }
    for _, loc in ipairs(locs) do
      local info = location_to_text(loc, 10)
      if info then results[#results + 1] = info end
    end
  end
  return results
end

--- Get references (only if server supports it).
function M._get_references(bufnr, selection, max_refs)
  local results = {}
  local params = {
    textDocument = vim.lsp.util.make_text_document_params(bufnr),
    position     = { line = selection.start_line - 1, character = selection.start_col or 0 },
    context      = { includeDeclaration = false },
  }
  local result = lsp_request_sync(bufnr, "textDocument/references", params, 3000)
  if result then
    local count = 0
    for _, loc in ipairs(result) do
      if count >= max_refs then break end
      local info = location_to_text(loc, 3)
      if info then
        results[#results + 1] = info
        count = count + 1
      end
    end
  end
  return results
end

--- Get document symbols (only if server supports it).
function M._get_document_symbols(bufnr)
  local params = {
    textDocument = vim.lsp.util.make_text_document_params(bufnr),
  }
  local result = lsp_request_sync(bufnr, "textDocument/documentSymbol", params, 3000)
  if not result then return {} end

  local symbols = {}
  local function flatten(items, depth)
    depth = depth or 0
    for _, item in ipairs(items) do
      local kind = vim.lsp.protocol.SymbolKind[item.kind] or "Unknown"
      symbols[#symbols + 1] = {
        name  = item.name,
        kind  = kind,
        depth = depth,
        line  = item.range and item.range.start.line + 1 or nil,
      }
      if item.children then flatten(item.children, depth + 1) end
    end
  end
  flatten(result)
  return symbols
end

--- Get surrounding code.
function M._get_surrounding(bufnr, selection, context_lines)
  local half = math.floor(context_lines / 2)
  local total_lines = vim.api.nvim_buf_line_count(bufnr)

  local before_start = math.max(1, selection.start_line - half)
  local after_end = math.min(total_lines, selection.end_line + half)

  -- Lines before selection
  local before = {}
  if before_start < selection.start_line then
    before = vim.api.nvim_buf_get_lines(bufnr, before_start - 1, selection.start_line - 1, false)
  end

  -- Lines after selection
  local after = {}
  if selection.end_line < after_end then
    after = vim.api.nvim_buf_get_lines(bufnr, selection.end_line, after_end, false)
  end

  local parts = {}
  if #before > 0 then
    parts[#parts + 1] = string.format("-- Lines %d-%d (before selection):", before_start, selection.start_line - 1)
    parts[#parts + 1] = table.concat(before, "\n")
  end
  if #after > 0 then
    parts[#parts + 1] = string.format("-- Lines %d-%d (after selection):", selection.end_line + 1, after_end)
    parts[#parts + 1] = table.concat(after, "\n")
  end

  return table.concat(parts, "\n")
end

--------------------------------------------------------------------
-- Format context for inclusion in prompt
--------------------------------------------------------------------

function M.format_context(ctx)
  local parts = {}

  parts[#parts + 1] = "LANGUAGE: " .. ctx.language
  parts[#parts + 1] = "FILE: " .. vim.fn.fnamemodify(ctx.filepath, ":.")

  -- Diagnostics
  if #ctx.diagnostics > 0 then
    parts[#parts + 1] = "\n── LSP DIAGNOSTICS ──"
    for _, d in ipairs(ctx.diagnostics) do
      parts[#parts + 1] = string.format("  Line %d [%s] (%s): %s",
        d.line, d.severity, d.source, d.message)
    end
  end

  -- Hover info
  if #ctx.hover_info > 0 then
    parts[#parts + 1] = "\n── TYPE INFORMATION ──"
    for _, h in ipairs(ctx.hover_info) do
      parts[#parts + 1] = string.format("  Line %d:\n  %s", h.line, h.info)
    end
  end

  -- Type definitions
  if #ctx.type_defs > 0 then
    parts[#parts + 1] = "\n── TYPE DEFINITIONS ──"
    for _, td in ipairs(ctx.type_defs) do
      parts[#parts + 1] = string.format("  %s (line %d):\n  %s", td.path, td.line, td.text)
    end
  end

  -- Symbols
  if #ctx.symbols > 0 then
    parts[#parts + 1] = "\n── FILE STRUCTURE ──"
    for _, s in ipairs(ctx.symbols) do
      local indent = string.rep("  ", s.depth)
      parts[#parts + 1] = string.format("  %s%s: %s%s",
        indent, s.kind, s.name, s.line and (" (line " .. s.line .. ")") or "")
    end
  end

  -- References
  if #ctx.references > 0 then
    parts[#parts + 1] = "\n── REFERENCES (callers / usages) ──"
    for _, r in ipairs(ctx.references) do
      parts[#parts + 1] = string.format("  %s (line %d):\n    %s", r.path, r.line, r.text)
    end
  end

  -- Surrounding code
  if ctx.surrounding and ctx.surrounding ~= "" then
    parts[#parts + 1] = "\n── SURROUNDING CODE ──"
    parts[#parts + 1] = ctx.surrounding
  end

  return table.concat(parts, "\n")
end

return M
