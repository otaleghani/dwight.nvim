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

### Git
Dwight uses git for checkpoints during multi-step tasks and for diff review. Your project must be a git repository.

### API Key (optional)
An API key is only needed for single-shot commands like `:DwightGenSkill` and `:DwightRefactor`. If you only use `:DwightAuto` and `:DwightAgent`, the CLI backend handles authentication.

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
:DwightBootstrap
```

Choose **Agentic** mode (recommended) — it reads your source code to understand the architecture and adds meaningful `@feature:` comments. Quick mode uses directory scanning and is faster but shallower.

After bootstrapping, your files will have pragma comments like:
```go
// HTTP server and routing for the web interface. @feature:web-server
package web
```

```python
# Database models and ORM configuration. @feature:database
from sqlalchemy import create_engine
```

### Verify Features
Check that pragmas were added correctly:
```vim
:DwightFeatures    " List all detected features
:DwightCoverage    " See how many files are tagged
```

---

## Your First Task

### Single Agent Task
Try a focused task on one feature:
```vim
:DwightAgent Add input validation to the user creation endpoint
```

The agent will read relevant files, make changes, and verify the result. You'll see a live status buffer with tool calls and progress.

### Multi-Step Auto Task
For larger work, use Auto mode:
```vim
:DwightAuto Create a REST API for user management with CRUD endpoints
```

Dwight will:
1. Break this into sub-tasks (e.g., "Create user model", "Add list endpoint", "Write tests")
2. Execute each sub-task through an agent
3. Run your test command after each step
4. Git commit after each passing step
5. Show a summary when done

### Review What Changed
After a task completes:
```vim
:DwightDiffReview   " See the full diff in a split buffer
:DwightReplay       " Step through the session event by event
:copen              " QuickFix list of all changed files
```

---

## Next Steps
- Read [[Core Concepts]] to understand pragmas, features, and skills
- Explore [[Auto Mode]] for multi-step task execution
- Set up [[Skills & Marketplace]] for project-specific coding guidelines
- Check the [[Commands|command reference]] for all available commands
- Review [[Configuration]] for all setup options
