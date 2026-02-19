# dwight.nvim

*"I'm not superstitious, but I am a little stitious."*

**A developer-centered AI coding assistant for Neovim.**

You stay in control. The LLM follows your instructions with precise context.

## Philosophy

Most coding agents take the steering wheel. **dwight.nvim** keeps you in the driver's seat:

- **You select the code.** The LLM only sees what you give it.
- **You type instructions inline.** `@skill` for guidelines, `/mode` for operation, `#symbol` for cross-file context.
- **LSP provides the context.** Types, diagnostics, references — gathered automatically.
- **Skills are project-local.** They live in `.dwight/skills/` alongside your code.
- **`:DwightInit` creates your project scope** with AI assistance — describe your project and get a ready-to-edit `project.md`.
- **`:DwightRun` bridges dev and testing.** Run your tests, then use `/fix` to feed errors directly to the AI.

## Requirements

- **Neovim** 0.11+
- **One of:**
  - `ANTHROPIC_API_KEY` env var (for direct API mode — **recommended**, lean and predictable)
  - [opencode](https://github.com/opencode-ai/opencode) CLI (agent mode, higher token usage)
- `curl` (for direct API mode)
- An LSP server for your language (optional but recommended)
- [Telescope](https://github.com/nvim-telescope/telescope.nvim) (optional, enhances pickers)

## Install

```lua
-- lazy.nvim, minimal configuration
return {
  dir = "otaleghani/dwight.nvim",
  opts = {},
}
```

```lua
-- lazy.nvim, configuration with keybindings
return {
  "otaleghani/dwight.nvim",
  opts = {},
  version = "*",
  keys = {
    -- Visual mode mappings
    { "<leader>ai", "<cmd>DwightInvoke<CR>",           mode = "v", desc = "Dwight: prompt" },
    { "<leader>ad", "<cmd>DwightMode document<CR>",    mode = "v", desc = "Dwight: document" },
    { "<leader>ar", "<cmd>DwightMode refactor<CR>",    mode = "v", desc = "Dwight: refactor" },
    { "<leader>ao", "<cmd>DwightMode optimize<CR>",    mode = "v", desc = "Dwight: optimize" },
    { "<leader>af", "<cmd>DwightMode fix_bugs<CR>",    mode = "v", desc = "Dwight: fix bugs" },
    { "<leader>as", "<cmd>DwightMode security<CR>",    mode = "v", desc = "Dwight: security" },
    { "<leader>ae", "<cmd>DwightMode explain<CR>",     mode = "v", desc = "Dwight: explain" },
    { "<leader>ab", "<cmd>DwightMode brainstorm<CR>",  mode = "v", desc = "Dwight: brainstorm" },
    { "<leader>ac", "<cmd>DwightMode code<CR>",        mode = "v", desc = "Dwight: code" },
    { "<leader>aF", "<cmd>DwightMode fix<CR>",         mode = "v", desc = "Dwight: fix from output" },

    -- Normal mode mapping
    { "<leader>ax", "<cmd>DwightCancel<CR>",           mode = "n", desc = "Dwight: cancel" },
  },
}
```

## Quick Start

```
:DwightInit              -- Set up .dwight/, AI generates project.md from your description
-- Select code in visual mode, then:
:DwightInvoke            -- Open prompt: type instructions with @skills /modes #symbols
:DwightMode refactor     -- Quick refactor
:DwightMode fix          -- Fix from last test/build output
```

Or set up keymaps (see [Keymaps](#keymaps) below) for faster access.

## The Prompt

The prompt is a proper scratch buffer — full vim editing, undo, paste. Help is always visible below the divider.

```
┌──────────────── dwight ────────────────┐
│ /refactor @clean-code                  │
│ extract the validation                 │
│ logic #validateUser                    │
│                                        │
│                                        │
│                                        │
│─── 15 lines · main.ts ────────────────│
│  @skill    load coding guidelines      │
│  /mode     refactor · fix · code …     │
│  #symbol   include from other files    │
│  <CR> submit   <Esc> normal   q quit   │
└────────────────────────────────────────┘
```

| Token | What it does |
|-------|-------------|
| `@skill-name` | Loads a skill file (coding guidelines) |
| `/mode-name` | Sets the operation mode |
| `#symbol-name` | Includes a function/type from another file via LSP |

`<CR>` submits. `<Esc>` goes to normal mode. `q` closes. `<Tab>` triggers/cycles completion.

Completion is fuzzy — just keep typing after `@`, `/`, or `#` to filter.

## Modes

| Mode | What it does |
|------|-------------|
| `/document` | Adds docstrings and inline comments |
| `/refactor` | Improves structure and readability |
| `/optimize` | Performance improvements |
| `/fix_bugs` | Finds and fixes bugs |
| `/security` | Security vulnerability audit |
| `/explain` | Adds explanatory comments |
| `/brainstorm` | Adds `[idea]` and `[tradeoff]` comments |
| `/code` | Implements stubs, fills in TODOs |
| `/fix` | Fixes code based on last build/test output |

Use modes inline in the prompt (`/refactor extract the validation`) or directly via `:DwightMode refactor`.

## Symbols

Type `#functionName` in the prompt to pull in source code from other files via LSP workspace symbols. This gives the AI cross-file context to write DRY code.

```
/refactor #validateUser #UserSchema
extract validation into a shared helper using the existing validator
```

The AI sees the source of `validateUser` and `UserSchema` from wherever they're defined — and can reuse them instead of reinventing.

## Build & Test Integration

```
:DwightRun npm test       -- Run tests, capture output
:DwightRun make           -- Or any command
:DwightRunOutput          -- Review last output
```

Then select code and use `/fix` — the test/build errors are automatically injected into the prompt:

```
:DwightMode fix           -- or type /fix in the prompt
```

`:DwightRun` auto-detects your runner (package.json → `npm test`, Cargo.toml → `cargo test`, etc.).

## Skills

### Built-in Skills

`:DwightInit` copies these into your project:

| Skill | What it enforces |
|-------|-----------------|
| `@clean-code` | Single responsibility, guard clauses, naming, no magic numbers |
| `@error-handling` | Context in errors, boundary validation, fail fast |
| `@testing` | AAA structure, behavior over implementation, edge cases |
| `@security` | Parameterized queries, no hardcoded secrets, output escaping |
| `@performance` | Right data structures, batch queries, no N+1, streaming |

Edit or delete any. `:DwightInstallSkills` adds new ones after a plugin update.

### Create Your Own

```bash
vim .dwight/skills/my-rules.md            # Manual
:DwightGenSkill                            # AI-generated
:DwightDocs                                # From a documentation URL
```

## Job Log

```
:DwightLog
```

Every job (code, skill gen, docs gen, project init, test runs) is logged with full prompt and response. Prompts are saved to tmp files for later review.

In Telescope: **Enter** → jump to code, **Ctrl-k** → kill running job, **Ctrl-o** → open prompt file.

## Commands

| Command | Description |
|---------|-------------|
| `:DwightInit` | Initialize project (AI-generated `project.md`) |
| `:DwightInvoke` | Open prompt for visual selection |
| `:DwightMode {mode}` | Run a mode directly |
| `:DwightSkills` | Browse project skills |
| `:DwightGenSkill` | AI-generate a skill |
| `:DwightInstallSkills` | Install/update built-in skills |
| `:DwightDocs` | Generate skill from docs URL |
| `:DwightRun [cmd]` | Run build/test, capture output |
| `:DwightRunOutput` | Show last run output |
| `:DwightLog` | Job log (Telescope or native) |
| `:DwightCancel [all]` | Cancel nearest or all jobs |
| `:DwightUsage` | Usage statistics |
| `:DwightStatus` | Full status overview |

## Configuration

```lua
require("dwight").setup({
  -- Backend: "api" (recommended) or "opencode"
  backend = "api",

  -- Direct API (backend = "api") — lean, one request per invocation
  -- Set ANTHROPIC_API_KEY env var, or:
  api_key = nil,
  model = "claude-sonnet-4-20250514",
  max_tokens = 4096,
  api_base_url = nil,           -- defaults to https://api.anthropic.com

  -- opencode CLI (backend = "opencode") — agent mode, higher token usage
  opencode_bin = "opencode",
  opencode_flags = {},

  -- Shared
  default_skills = {},
  lsp_context_lines = 80,
  timeout = 120000,
})
```

### Why direct API?

With `backend = "api"`, dwight sends exactly **one request** to Claude per invocation. Your prompt, the code, LSP context — that's it. Typical usage is **1000–2000 input tokens** per request.

With `backend = "opencode"`, the opencode CLI adds its own system prompt, tool definitions, and may run multi-step agent loops behind the scenes. This can result in **10–50x higher token usage** for the same task, plus background requests you didn't initiate. If you've seen unexpected API charges, this is likely why.

**If you want to use opencode**, you can reduce its overhead:
- Set `OPENCODE_AUTO_COMPACT=false` to disable automatic context compaction
- Use `--no-tools` flag if supported by your version
- Check `~/.config/opencode/config.yaml` for background features like auto-save or indexing
- Consider running `opencode` with `--verbose` once to see what requests it makes

## Keymaps

dwight.nvim does not set any keymaps by default — you wire them up yourself. Here's a suggested setup:

```lua
local dwight = require("dwight")

-- Open the prompt (visual mode)
vim.keymap.set("v", "<leader>ai", dwight.invoke, { desc = "Dwight: prompt" })

-- Quick modes (visual mode)
vim.keymap.set("v", "<leader>ad", function() dwight.invoke_mode("document") end, { desc = "Dwight: document" })
vim.keymap.set("v", "<leader>ar", function() dwight.invoke_mode("refactor") end, { desc = "Dwight: refactor" })
vim.keymap.set("v", "<leader>ao", function() dwight.invoke_mode("optimize") end, { desc = "Dwight: optimize" })
vim.keymap.set("v", "<leader>af", function() dwight.invoke_mode("fix_bugs") end, { desc = "Dwight: fix bugs" })
vim.keymap.set("v", "<leader>as", function() dwight.invoke_mode("security") end, { desc = "Dwight: security" })
vim.keymap.set("v", "<leader>ae", function() dwight.invoke_mode("explain") end,  { desc = "Dwight: explain" })
vim.keymap.set("v", "<leader>ab", function() dwight.invoke_mode("brainstorm") end, { desc = "Dwight: brainstorm" })
vim.keymap.set("v", "<leader>ac", function() dwight.invoke_mode("code") end,     { desc = "Dwight: code" })
vim.keymap.set("v", "<leader>aF", function() dwight.invoke_mode("fix") end,      { desc = "Dwight: fix from output" })

-- Cancel (normal mode)
vim.keymap.set("n", "<leader>ax", dwight.cancel, { desc = "Dwight: cancel" })
```

| Keymap | Mode | What it does |
|--------|------|-------------|
| `<leader>ai` | prompt | Opens the inline prompt |
| `<leader>ad` | `/document` | Adds docstrings and inline comments |
| `<leader>ar` | `/refactor` | Improves structure and readability |
| `<leader>ao` | `/optimize` | Performance improvements |
| `<leader>af` | `/fix_bugs` | Finds and fixes bugs |
| `<leader>as` | `/security` | Security vulnerability audit |
| `<leader>ae` | `/explain` | Adds explanatory comments |
| `<leader>ab` | `/brainstorm` | Adds `[idea]` and `[tradeoff]` comments |
| `<leader>ac` | `/code` | Implements stubs, fills in TODOs |
| `<leader>aF` | `/fix` | Fixes code based on last build/test output |
| `<leader>ax` | cancel | Cancels nearest running job |

## Architecture

```
lua/dwight/
├── init.lua       Setup, config, commands
├── project.lua    .dwight/ directory, AI-generated project.md
├── modes.lua      Built-in + custom modes (incl. /fix)
├── skills.lua     Skill management, AI generation (logged)
├── symbols.lua    LSP workspace symbol resolution for #refs
├── lsp.lua        LSP context (with capability checks)
├── prompt.lua     Prompt assembly (all 9 context layers)
├── opencode.lua   CLI integration, parallel jobs, output parsing
├── runner.lua     Build/test runner, output capture for /fix
├── ui.lua         Minimal prompt, fuzzy completion, per-job indicators
├── tracker.lua    Usage tracking
├── docs.lua       URL → skill generator (logged)
├── log.lua        Job log, prompt files, Telescope browser
└── builtin/       Built-in skill templates (copied on init)
```
