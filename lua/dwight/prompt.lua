-- dwight/prompt.lua
-- Builds the full prompt. Optimized for minimal token usage.

local M = {}

local function get_config()
  return require("dwight").config
end

local function read_skill(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*a"); f:close()
  return content
end

local function comment_style(filetype)
  local overrides = get_config().comment_styles
  if overrides and overrides[filetype] then
    if type(overrides[filetype]) == "string" then return { line = overrides[filetype] } end
    return overrides[filetype]
  end

  local styles = {
    javascript      = { line = "// " }, typescript      = { line = "// " },
    typescriptreact = { line = "// " }, javascriptreact = { line = "// " },
    go = { line = "// " }, rust = { line = "// " }, c = { line = "// " },
    cpp = { line = "// " }, java = { line = "// " }, kotlin = { line = "// " },
    swift = { line = "// " }, scala = { line = "// " }, dart = { line = "// " },
    php = { line = "// " }, zig = { line = "// " }, v = { line = "// " },
    odin = { line = "// " }, proto = { line = "// " }, groovy = { line = "// " },
    scss = { line = "// " }, sass = { line = "// " },
    python = { line = "# " }, ruby = { line = "# " }, sh = { line = "# " },
    bash = { line = "# " }, zsh = { line = "# " }, fish = { line = "# " },
    yaml = { line = "# " }, toml = { line = "# " }, elixir = { line = "# " },
    perl = { line = "# " }, r = { line = "# " }, julia = { line = "# " },
    dockerfile = { line = "# " }, make = { line = "# " }, cmake = { line = "# " },
    conf = { line = "# " }, terraform = { line = "# " }, hcl = { line = "# " },
    nix = { line = "# " }, powershell = { line = "# " }, ps1 = { line = "# " },
    lua = { line = "-- " }, haskell = { line = "-- " }, sql = { line = "-- " },
    ada = { line = "-- " }, vhdl = { line = "-- " },
    vim = { line = '" ' },
    html = { line = "<!-- " }, xml = { line = "<!-- " }, svg = { line = "<!-- " },
    vue = { line = "// " }, svelte = { line = "// " },
    css = { line = "/* " },
    ocaml = { line = "(* " }, fsharp = { line = "// " },
    clojure = { line = ";; " }, lisp = { line = ";; " }, scheme = { line = ";; " },
    asm = { line = "; " }, nasm = { line = "; " }, ini = { line = "; " },
    erlang = { line = "% " }, latex = { line = "% " }, tex = { line = "% " },
    matlab = { line = "% " },
  }
  return styles[filetype] or { line = "// " }
end

--------------------------------------------------------------------
-- Build Prompt (token-optimized)
--------------------------------------------------------------------

function M.build(mode, selection, ctx, extra_instructions, skill_paths, resolved_symbols)
  local lsp = require("dwight.lsp")
  local project = require("dwight.project")
  local runner = require("dwight.runner")
  local cfg = get_config()
  local parts = {}
  local cs = comment_style(selection.filetype or ctx.language)

  -- Task (compact)
  parts[#parts + 1] = mode.task

  -- User instructions
  if extra_instructions and extra_instructions ~= "" then
    parts[#parts + 1] = "\nInstructions: " .. extra_instructions
  end

  -- Project scope (only if non-empty)
  local scope = project.read_scope()
  if scope then parts[#parts + 1] = "\nProject:\n" .. scope end

  -- Skills (only if requested)
  local all_skill_paths = skill_paths or {}
  for _, name in ipairs(cfg.default_skills) do
    local path = require("dwight.skills").resolve(name)
    if path then
      local found = false
      for _, p in ipairs(all_skill_paths) do if p == path then found = true; break end end
      if not found then all_skill_paths[#all_skill_paths + 1] = path end
    end
  end
  if #all_skill_paths > 0 then
    parts[#parts + 1] = "\nGuidelines:"
    for _, path in ipairs(all_skill_paths) do
      local content = read_skill(path)
      if content then parts[#parts + 1] = content end
    end
  end

  -- Symbols
  resolved_symbols = resolved_symbols or {}
  if #resolved_symbols > 0 then
    parts[#parts + 1] = "\nReuse these symbols (do NOT redefine):"
    for _, sym in ipairs(resolved_symbols) do
      parts[#parts + 1] = string.format("-- %s (%s, %s:%d)",
        sym.name, sym.kind, vim.fn.fnamemodify(sym.filepath, ":."), sym.line)
      if sym.text then parts[#parts + 1] = sym.text end
    end
  end

  -- Build/test output
  local run_ctx = runner.last_run_context()
  if run_ctx and mode.inject_run_output then
    parts[#parts + 1] = "\nBuild/test output:\n" .. run_ctx
  end

  -- LSP context (compact — only diagnostics and types, skip verbose refs)
  local ctx_text = lsp.format_context(ctx)
  if ctx_text and ctx_text ~= "" then
    parts[#parts + 1] = "\nLSP:\n" .. ctx_text
  end

  -- Code
  parts[#parts + 1] = string.format("\n%s (lines %d-%d of %s):",
    ctx.language, selection.start_line, selection.end_line,
    vim.fn.fnamemodify(selection.filepath or "", ":."))
  parts[#parts + 1] = "```" .. (ctx.language or "")
  parts[#parts + 1] = selection.text
  parts[#parts + 1] = "```"

  -- Output rules (compact — every word here costs tokens on EVERY request)
  parts[#parts + 1] = string.format([[

Rules:
1. Reply with ONLY a fenced code block (```%s ... ```). Nothing else.
2. Only modify the given code. No new imports, functions, or helpers unless asked.
3. Output is a drop-in replacement for the input lines.
4. Comment prefix: %s
5. If unchanged, return original code in a code block.]], ctx.language, cs.line)

  return table.concat(parts, "\n")
end

function M.build_freeform(user_text, selection, skill_paths, resolved_symbols)
  local lsp = require("dwight.lsp")
  local ctx = lsp.gather_context(selection)

  local custom_mode = {
    name = "Custom",
    task = "Do exactly what is asked, nothing more:\n" .. user_text,
  }

  return M.build(custom_mode, selection, ctx, nil, skill_paths, resolved_symbols)
end

return M
