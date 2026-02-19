-- dwight/prompt.lua
-- Builds the full prompt for opencode.
-- Context layers: task + instructions + scope + skills + symbols + runner + LSP + code + format rules.

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

--- Comprehensive comment style detection (60+ filetypes).
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
-- Build Prompt
--------------------------------------------------------------------

function M.build(mode, selection, ctx, extra_instructions, skill_paths, resolved_symbols)
  local lsp = require("dwight.lsp")
  local project = require("dwight.project")
  local runner = require("dwight.runner")
  local cfg = get_config()
  local parts = {}
  local cs = comment_style(selection.filetype or ctx.language)

  -- 1. Task
  parts[#parts + 1] = mode.task

  -- 2. User instructions
  if extra_instructions and extra_instructions ~= "" then
    parts[#parts + 1] = "\nDeveloper's additional instructions:"
    parts[#parts + 1] = extra_instructions
  end

  -- 3. Project scope
  local scope = project.read_scope()
  if scope then
    parts[#parts + 1] = "\nProject context:"
    parts[#parts + 1] = scope
  end

  -- 4. Skills
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
    parts[#parts + 1] = "\nFollow these coding guidelines:"
    for _, path in ipairs(all_skill_paths) do
      local content = read_skill(path)
      if content then
        parts[#parts + 1] = string.format("\n--- %s ---", vim.fn.fnamemodify(path, ":t:r"))
        parts[#parts + 1] = content
      end
    end
  end

  -- 5. Symbols (cross-file context)
  resolved_symbols = resolved_symbols or {}
  if #resolved_symbols > 0 then
    parts[#parts + 1] = "\nHere are referenced symbols from other files (REUSE them, do NOT redefine or re-import them):"
    for _, sym in ipairs(resolved_symbols) do
      local rel_path = vim.fn.fnamemodify(sym.filepath, ":.")
      parts[#parts + 1] = string.format("\n── %s (%s, %s line %d) ──", sym.name, sym.kind, rel_path, sym.line)
      if sym.text then
        parts[#parts + 1] = "```" .. (ctx.language or "")
        parts[#parts + 1] = sym.text
        parts[#parts + 1] = "```"
      end
    end
  end

  -- 6. Build/test output
  local run_ctx = runner.last_run_context()
  if run_ctx and (mode.inject_run_output or (extra_instructions and extra_instructions:match("fix"))) then
    parts[#parts + 1] = "\nOutput from the last build/test run:"
    parts[#parts + 1] = run_ctx
    parts[#parts + 1] = "\nFix the code to resolve these errors."
  end

  -- 7. LSP context
  local ctx_text = lsp.format_context(ctx)
  if ctx_text and ctx_text ~= "" then
    parts[#parts + 1] = "\nEditor LSP context:"
    parts[#parts + 1] = ctx_text
  end

  -- 8. The code
  parts[#parts + 1] = string.format(
    "\nHere is the %s code (lines %d-%d of %s):",
    ctx.language, selection.start_line, selection.end_line,
    vim.fn.fnamemodify(selection.filepath or "", ":."))
  parts[#parts + 1] = "```" .. (ctx.language or "")
  parts[#parts + 1] = selection.text
  parts[#parts + 1] = "```"

  -- 9. Output format — STRICT rules
  parts[#parts + 1] = string.format([[

=== CRITICAL OUTPUT RULES ===
You MUST follow ALL of these rules. Violations will cause the output to be rejected.

1. RESPONSE FORMAT: Your ENTIRE response must be a SINGLE fenced code block:
   ```%s
   ... your code here ...
   ```
   Nothing else. No text before. No text after. No explanation. No "here is the code".
   No "I'll" or "Let me" or any thinking out loud. JUST the code block.

2. SCOPE: Only modify the code that was given to you. Specifically:
   - Do NOT add new imports, requires, or includes that weren't there.
   - Do NOT add new functions, classes, types, or modules that weren't asked for.
   - Do NOT remove or change code outside the scope of what was requested.
   - Do NOT add helper functions "for completeness" unless explicitly asked.
   - Do NOT restructure the file layout or move things around.
   - The output must be a DROP-IN REPLACEMENT for the input lines. Same boundaries.

3. COMMENTS: Use %q as the comment prefix (this is a %s file).

4. UNCHANGED: If you have no changes, return the original code exactly as-is in a code block.
]], ctx.language, cs.line, ctx.language)

  return table.concat(parts, "\n")
end

function M.build_freeform(user_text, selection, skill_paths, resolved_symbols)
  local lsp = require("dwight.lsp")
  local ctx = lsp.gather_context(selection)

  local custom_mode = {
    name = "Custom",
    task = string.format([[
Modify the code below exactly as requested:

%s

Do ONLY what was asked. Nothing more, nothing less. Do not add extra functions, imports, or helpers.
]], user_text),
  }

  return M.build(custom_mode, selection, ctx, nil, skill_paths, resolved_symbols)
end

return M
