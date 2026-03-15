---
title: Getting Started
description: Install Dwight, configure a backend, initialize your project, and run your first AI-assisted task.
---
# Getting Started

This guide takes you from zero to running your first AI-assisted task in under five minutes.

---

## Prerequisites

### Neovim 0.10+
Dwight uses modern Neovim APIs (vim.uv, vim.health, native LSP). Check with `:version`.

### A CLI Agent Backend
Dwight delegates agentic tasks to a CLI tool. You need at least one installed and authenticated:

**Claude Code** (default, recommended):
```bash
npm install -g @anthropic-ai/claude-code
claude login
```

**OpenAI Codex**:
```bash
npm install -g @openai/codex
# Set OPENAI_API_KEY in your environment
```

**Gemini CLI**:
```bash
npm install -g @google/gemini-cli
# Authenticate via gcloud or set GOOGLE_API_KEY
```

See [[Providers and Models]] for all backend options including OpenCode.

### Git
Dwight uses git for checkpoints during multi-step tasks and for diff review. Your project must be a git repository.

### API Key (optional)
An API key is only needed for single-shot commands like `:DwightGenSkill` and inline modes. If you only use `:DwightAuto` and `:DwightAgent`, the CLI backend handles authentication.

Set one of: `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, or `GOOGLE_API_KEY`.

---

## Installation

### lazy.nvim
```lua
{
  "otaleghani/dwight.nvim",
  dependencies = {
    "nvim-lua/plenary.nvim",
    "nvim-treesitter/nvim-treesitter",
  },
  config = function()
    require("dwight").setup({
      backend = "claude_code",
    })
  end,
}
```

### packer.nvim
```lua
use {
  "otaleghani/dwight.nvim",
  requires = {
    "nvim-lua/plenary.nvim",
    "nvim-treesitter/nvim-treesitter",
  },
  config = function()
    require("dwight").setup({
      backend = "claude_code",
    })
  end,
}
```

### Optional Dependencies
These aren't required but significantly improve the experience:
- **telescope.nvim** — better pickers for skills, features, sessions (falls back to `vim.ui.select`)
- **nvim-treesitter** — signature extraction for feature context (highly recommended)

---

## Verify Your Setup
After installing, run the health check:
```vim
:checkhealth dwight
```

This validates your backend, API keys, git status, project initialization, and test command detection. Fix any errors before proceeding.

![Health check output](assets/health.gif)

---

## Initialize Your Project
Navigate to your project root and run:
```vim
:DwightInit
```

This creates the `.dwight/` directory with built-in coding skills. Add `.dwight/` to your `.gitignore` (Dwight creates one automatically inside `.dwight/`).

### Bootstrap Pragmas
Next, let Dwight analyze your codebase and add feature pragmas:
```vim
:DwightBootstrap --agentic
```

Agentic mode reads your source code to understand the architecture and adds meaningful `@feature:` comments. Quick mode (`--quick`) uses directory scanning and is faster but shallower.

After bootstrapping, your files will have pragma comments:
```go
// HTTP server and routing for the web interface. @feature:web-server
package web
```

### Verify Features
```vim
:DwightFeatures    " List all detected features
:DwightCoverage    " See how many files are tagged
```

See [[Bootstrap and Coverage]] for all bootstrap modes and options.

---

## Your First Task

### Inline Editing
The quickest way to start — select code and apply a mode:
```vim
:'<,'>DwightMode refactor    " Refactor selected code
:'<,'>DwightMode test        " Generate tests for selected code
:'<,'>DwightMode fix         " Fix bugs in selected code
```

Or open the full prompt buffer:
```vim
:DwightInvoke                " Opens prompt with @skill and %lib support
```

See [[Inline Editing]] for all 18+ modes and prompt syntax.

### Agent Task
For autonomous tasks with full tool use:
```vim
:DwightAgent Add input validation to the user creation endpoint
```

The agent reads files, writes code, runs commands, and self-corrects. See [[Agent Mode]].

### Auto Task
For larger work, use Auto mode:
```vim
:DwightAuto Create a REST API for user management with CRUD endpoints
```

Dwight will plan sub-tasks, execute each through an agent, run tests after each step, and git commit after each passing step. See [[Auto Mode]].

### Review What Changed
```vim
:DwightDiffReview   " See the full diff in a split buffer
:DwightReplay       " Step through the session event by event
```

---

## Troubleshooting

Common issues and how to fix them. For a full list of error messages, see [[Error Guide]].

### Backend won't start

**Symptom:** `:DwightAgent` or `:DwightAuto` fails immediately with "command not found" or "spawn failed".

**Fix:**
1. Verify the CLI is installed: `which claude` (or `codex`, `gemini`)
2. If missing, install it: `npm install -g @anthropic-ai/claude-code`
3. Make sure your `$PATH` includes the npm global bin directory — run `npm bin -g` to check
4. Restart Neovim after installing (shell PATH changes don't propagate to running sessions)

### Authentication failures

**Symptom:** "Unauthorized", "invalid API key", or "token expired" errors.

**Fix:**
- **Claude Code:** Run `claude login` in your terminal to re-authenticate
- **API key backends:** Verify your env var is set: `echo $ANTHROPIC_API_KEY` (or `OPENAI_API_KEY`, `GOOGLE_API_KEY`)
- **OAuth tokens:** These expire — run `:DwightAuthMax` to re-authenticate with Anthropic Pro/Max
- Check `:DwightProviders` to see current key/auth status

### `:checkhealth` errors

Run `:checkhealth dwight` and look for `ERROR` lines:

| Error | Meaning | Fix |
|-------|---------|-----|
| Backend not found | CLI binary missing from PATH | Install the CLI (see above) |
| No API key | Env var not set | Export `ANTHROPIC_API_KEY` or equivalent |
| Git not available | `git` not in PATH | Install git |
| Not a git repo | Project root has no `.git/` | Run `git init` |
| Treesitter not available | `nvim-treesitter` not installed | Add it to your plugin manager |
| No parsers installed | Language parsers missing | `:TSInstall <language>` |

### Git errors

**"Not a git repository"** — Dwight requires git for checkpoints. Run `git init` in your project root.

**"Dirty working tree"** — Some commands (like `:DwightSquash`) need a clean tree. Commit or stash your changes first: `:DwightGit stash`.

**"Merge conflict"** — If a checkpoint fails mid-apply, resolve conflicts manually or use `:DwightGit resolve`.

### No features detected

**Symptom:** `:DwightFeatures` shows nothing, or agent context is empty.

**Fix:** Run `:DwightBootstrap` (or `:DwightBootstrap --agentic` for smarter analysis). This scans your source files and adds `@feature:` pragma comments. Check coverage with `:DwightCoverage`.

### Treesitter missing

**Symptom:** Feature context shows file paths but no function signatures.

**Fix:** Install treesitter parsers for your language:
```vim
:TSInstall go lua python javascript typescript
```
Dwight uses treesitter to extract function/type signatures for feature context. Without it, the AI gets less precise context.

---

## Next Steps
- [[Core Concepts]] — understand pragmas, features, skills, and lessons
- [[Inline Editing]] — in-buffer AI editing with modes
- [[Agent Mode]] — autonomous single-task execution
- [[Auto Mode]] — multi-step task planning and execution
- [[Skills and Marketplace]] — project-specific coding guidelines
- [[Recipes|Workflow Recipes]] — end-to-end walkthroughs for common tasks
- [[FAQ]] — frequently asked questions
- [[Error Guide]] — common error messages and fixes
- [[Commands]] — full command reference
- [[Configuration]] — all setup options
