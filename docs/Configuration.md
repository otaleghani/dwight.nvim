---
title: Configuration
description: All configuration options for Dwight, including backends, providers, agent tuning, model diversity, and language support.
---

# Configuration

Dwight is configured through the `setup()` function. All options have sensible defaults — you only need to set what you want to change.

---

## Minimal Setup
```lua
require("dwight").setup({
  backend = "claude_code",
})
```

This is enough to use `:DwightAuto`, `:DwightAgent`, and all agentic features.

---

## Full Reference

### Backend
The backend determines which CLI tool runs agentic tasks.

```lua
require("dwight").setup({
  -- Which CLI agent runs agentic tasks.
  -- "claude_code" (default) | "codex" | "gemini" | "opencode"
  backend = "claude_code",

  -- Claude Code settings
  claude_code_bin = "claude",      -- path to claude binary
  claude_code_model = nil,         -- nil = default, or "sonnet", "opus", "haiku"

  -- OpenAI Codex settings
  codex_bin = "codex",             -- path to codex binary
  codex_model = nil,               -- nil = default

  -- Gemini CLI settings
  gemini_bin = "gemini",           -- path to gemini binary
  gemini_model = nil,              -- nil = default

  -- OpenCode settings
  opencode_bin = "opencode",       -- path to opencode binary
  opencode_flags = {},             -- additional CLI flags
})
```

See [[Providers and Models]] for details on each backend.

### Provider (for Skills API)
The provider handles single-shot API calls used by `:DwightGenSkill`, `:DwightRefactor`, and other non-agentic commands. This is separate from the backend.

```lua
require("dwight").setup({
  provider = nil,       -- nil = auto-detect from env vars
                        -- "anthropic" | "openai" | "gemini" | "openrouter"
  model = nil,          -- nil = provider default
                        -- or: "sonnet", "opus", "openai:gpt-4o"
  api_key = nil,        -- override; or set ANTHROPIC_API_KEY env var
  max_tokens = 4096,    -- max output tokens for single-shot calls
})
```

### Model Diversity
Use different models for test-writing vs implementation to reduce blind spots:

```lua
require("dwight").setup({
  test_model = nil,        -- model for /test, /stub modes (e.g., "sonnet")
  implement_model = nil,   -- model for /code, /fix modes (e.g., "opus")
})
```

When both are set, Dwight routes to the correct model based on the mode. See [[Providers and Models]].

### Agent Tuning
Fine-tune the agentic execution loop.

```lua
require("dwight").setup({
  agentic_opts = {
    max_output_tokens = 64000,  -- per-response token budget (Claude Code)
    cli_timeout = 600,          -- seconds before killing a session (10 min)
  },
  timeout = 120000,             -- ms, for non-agentic operations
  parallel_steps = true,        -- parallel step execution for independent steps
})
```

### Context Settings
Control what context is included in AI prompts.

```lua
require("dwight").setup({
  lsp_context_lines = 80,       -- lines of LSP context to include
  include_diagnostics = true,   -- include LSP diagnostics
  include_type_info = true,     -- include type information
  include_references = true,    -- include symbol references
  max_references = 10,          -- max references per symbol
  git_context = true,           -- include git diffs and blame
  default_skills = {},          -- skill names to always include
})
```

### UI Settings
```lua
require("dwight").setup({
  indicator_style = "both",     -- "sign" | "virtual" | "both"
  indicator_sign = "⟳",         -- sign column indicator
  indicator_hl = "DwightProcessing",  -- highlight group
  border = "rounded",           -- float border style
  diff_preview = false,         -- show diff before applying changes
  streaming = false,            -- stream AI output in real-time
})
```

### MCP Servers
Connect external tools via the Model Context Protocol.

```lua
require("dwight").setup({
  mcp_servers = {
    {
      name = "sqlite",
      command = "mcp-server-sqlite",
      args = { "project.db" },
    },
    {
      name = "github",
      command = "mcp-server-github",
      env = { GITHUB_TOKEN = os.getenv("GITHUB_TOKEN") },
    },
  },
})
```

See [[Providers and Models]] for MCP details.

### Language Overrides
Add or override language detection, test commands, and build commands.

```lua
require("dwight").setup({
  languages = {
    java = {
      detect = { "pom.xml", "build.gradle" },
      test_cmd = "mvn test -q",
      build_cmd = "mvn compile -q",
      lint_cmd = "checkstyle",
    },
    elixir = {
      detect = { "mix.exs" },
      test_cmd = "mix test",
      build_cmd = "mix compile",
    },
  },
})
```

Dwight auto-detects Go, Python, Rust, JavaScript, TypeScript, Lua, Ruby, Java, Kotlin, C#, C, C++, Swift, Dart, Elixir, Scala, Haskell, Zig, OCaml, Clojure, R, PHP, and Shell. Use this to override defaults or add languages Dwight doesn't know about.

### Custom Modes
Register project-specific modes that appear alongside built-in modes.

```lua
require("dwight").setup({
  modes = {
    deploy = {
      task = "Generate a deployment script for the current project",
      context = "code",     -- "code" | "prose" | "both" (default: "both")
      description = "Generate deployment scripts",
    },
    review = {
      task = "Review this code for correctness and clarity",
      context = "code",
    },
  },
})
```

Each mode must have a `task` field (the instruction sent to the AI). Optional fields: `context`, `description`, `icon`, `name`. Custom modes are invoked the same way as built-in modes: `:DwightMode deploy` or `/deploy` in the prompt buffer.

### Comment Styles
Override how Dwight writes pragma comments for specific file extensions.

```lua
require("dwight").setup({
  comment_styles = {
    [".xyz"] = "// %s",        -- C-style
    [".abc"] = "# %s",         -- hash-style
    [".custom"] = "-- %s",     -- lua-style
  },
})
```

---

## Runtime Configuration
Some settings can be toggled at runtime:

```vim
:DwightGitToggle        " Toggle git context on/off
:DwightBackend codex    " Switch backend
:DwightSwitch opus      " Switch model
```

---

## Highlight Groups
Dwight defines these highlight groups (all have `default = true` so your colorscheme takes priority):

| Group | Default | Used For |
|-------|---------|----------|
| `DwightProcessing` | orange, bold, italic | Active operation indicator |
| `DwightSkill` | cyan, bold, underline | Valid `@skill` references |
| `DwightSkillInvalid` | red, bold, strikethrough | Invalid `@skill` references |
| `DwightMode` | orange, bold | Mode indicators |
| `DwightSymbol` | purple, bold, underline | Symbol highlights |
| `DwightModel` | green, bold, italic | Model name display |
| `DwightFeature` | orange, bold, underline | Feature name highlights |
| `DwightThink` | red, bold | Thinking indicator |
| `DwightLib` | green, bold, underline | Library references |
| `DwightMcp` | green, bold, italic, underline | MCP references |
| `DwightFile` | blue-white, bold, underline | File path highlights |
| `DwightAudit` | red, bold, italic | Audit findings |
| `DwightHeal` | green, bold, italic | Heal operations |
| `DwightAuto` | orange, bold, italic | Auto mode status |
| `DwightGithub` | blue, bold, italic | GitHub elements |
| `DwightReplace` | green, italic | Replacement text |
| `DwightBorder` | blue | Float borders |
| `DwightTitle` | purple, bold | Float titles |
| `DwightHelpHint` | blue, italic | Help text |
