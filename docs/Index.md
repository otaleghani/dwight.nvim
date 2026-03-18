---
title: An AI-powered development companion for Neovim
description: Dwight orchestrates AI agents to plan, build, test, and ship code inside Neovim. Feature pragmas scope context, autonomous agents handle multi-step tasks, and every session teaches the next one.
---
# Dwight: AI Development, Inside Neovim.

> **Scope. Plan. Build. Ship. Learn.**

**Dwight** turns your Neovim into an AI-powered development environment. It doesn't replace your editor — it makes it smarter. Feature pragmas in your source code scope context, autonomous agents plan and execute multi-step tasks with verification gates, and a learning system means every session improves the next one.

No context windows to manage. No copy-pasting into chat. Just describe what you want, and Dwight builds it — with git checkpoints at every step.

[Get Started](#installation) · [[Commands|Command Reference]] · [[Configuration]]

---

## Why Dwight?
AI coding tools either give you autocomplete or require you to leave your editor. Dwight does neither.

### Code-Scoped Context
Stop feeding entire codebases into AI. Dwight uses **pragma comments** in your source to define features, and treesitter to extract signatures. The AI sees exactly what it needs — nothing more.

```go
// User authentication and session management. @feature:auth
package auth
```

### Three Modes of Interaction
- **Inline Editing** — select code, pick a mode (`/refactor`, `/test`, `/fix`), get in-buffer edits
- **Agent Mode** — describe a task, the agent reads files, writes code, runs commands autonomously
- **Auto Mode** — describe a complex task, Dwight breaks it into sub-tasks with verification gates and git checkpoints

### Skill System
Skills are reusable markdown guides that encode your project's coding patterns:

```vim
:DwightGenSkill      " AI-generates a skill from a description
:DwightMarketplace   " Browse curated skill packs for Go, React, Rust, etc.
```

---

## Get Started in Seconds

### Installation

**lazy.nvim**:
```lua
{
  "otaleghani/dwight.nvim",
  dependencies = {
    "nvim-lua/plenary.nvim",
    "nvim-treesitter/nvim-treesitter",
  },
  config = function()
    require("dwight").setup({
      backend = "claude_code",     -- or "codex", "gemini", "opencode"
    })
  end,
}
```

### Prerequisites
- **Neovim 0.10+**
- **A CLI agent** — one of:
  - [Claude Code](https://docs.anthropic.com/en/docs/claude-code) (`npm i -g @anthropic-ai/claude-code`)
  - [OpenAI Codex](https://github.com/openai/codex) (`npm i -g @openai/codex`)
  - [Gemini CLI](https://github.com/google-gemini/gemini-cli) (`npm i -g @google/gemini-cli`)
- **Git** — Dwight uses git for checkpoints and rollbacks
- **An API key** (optional) — for skill generation and single-shot commands. Set `ANTHROPIC_API_KEY` or `OPENAI_API_KEY`.

See [[Getting Started]] for the full setup guide.

### First Use
```vim
:DwightInit                   " Initialize .dwight/ in your project
:DwightBootstrap              " Auto-add @feature pragmas to all files
:DwightAuto Create a REST API " Plan + execute a multi-step task
```

---

## Core Workflow

### 1. Scope → [[Core Concepts]]
Add pragma comments to define features: `// @feature:auth`, `// @feature:database`. Bootstrap does this automatically.

### 2. Edit → [[Inline Editing]]
Select code and use modes like `/refactor`, `/test`, `/fix` for focused in-buffer edits.

### 3. Build → [[Agent Mode]] / [[Auto Mode]]
`:DwightAgent` runs a single autonomous task. `:DwightAuto` decomposes complex tasks into sub-tasks with verification.

### 4. Review → [[Session Replay]]
Step through what the agent did with `:DwightReplay`. Check the diff with `:DwightDiffReview`.

### 5. Ship → [[Git Operations]] / [[GitHub Integration]]
`:DwightCommit` writes smart commits. `:DwightCI` auto-fixes CI failures. `:DwightPR` generates pull requests.

### 6. Learn → [[Core Concepts]]
Dwight extracts lessons from each session and applies them to future tasks automatically.

---

## Feature Overview

| Feature | Command | Description |
|---------|---------|-------------|
| **[[Inline Editing]]** | `:DwightInvoke` | Select code, pick a mode, get in-buffer edits |
| **[[Agent Mode]]** | `:DwightAgent` | Autonomous single-task with full tool use |
| **[[Auto Mode]]** | `:DwightAuto` | Multi-step planning, execution, and verification |
| **[[Swarm Mode]]** | `:DwightSwarm` | Parallel multi-agent waves across isolated worktrees |
| **[[Bootstrap and Coverage]]** | `:DwightBootstrap` | Auto-add feature pragmas to source files |
| **[[Feature Management]]** | `:DwightFeatures` | Browse, preview, and split features |
| **[[Refactoring]]** | `:DwightRefactor` | Decompose large refactoring with importer analysis |
| **[[TDD]]** | `:DwightTDD` | Test-driven development loop |
| **[[Git Operations]]** | `:DwightGit` | Smart commits, squash, diff review |
| **[[GitHub Integration]]** | `:DwightIssue` | Issues, PRs, CI auto-fix |
| **[[Skills and Marketplace]]** | `:DwightSkills` | Coding skills and curated packs |
| **[[Library References]]** | `:DwightAddLib` | Structured API references for dependencies |
| **[[Docs Generation]]** | `:DwightDocs` | Generate and update project documentation |
| **[[Codebase Audit and Heal]]** | `:DwightAudit` | Find and fix quality issues |
| **[[Codebase Digest]]** | `:DwightDigest` | Pre-extract signatures for agent context |
| **[[Session Replay]]** | `:DwightReplay` | Step through past sessions |
| **[[Whiteboard]]** | `:DwightWhiteboard` | AI brainstorming scratchpad |
| **[[Templates]]** | `:DwightTemplate` | Reusable prompt templates |
| **[[Workspace]]** | `:DwightWorkspace` | Multi-repo unified workspace |
| **[[Telemetry and Stats]]** | `:DwightStats` | Usage dashboard and cost tracking |
| **[[Providers and Models]]** | `:DwightProviders` | Backend, provider, and model configuration |

See the full [[Commands|command reference]] for all 85+ commands.

---

## Advanced Features

### Multi-Repo Workspaces
Work across multiple repositories as a single workspace:
```vim
:DwightWorkspaceAdd ../shared-lib
:DwightWorkspaceFeatures
```
See [[Workspace]] for setup and usage.

### MCP Server Integration
Connect external tools via the Model Context Protocol:
```lua
require("dwight").setup({
  mcp_servers = {
    { name = "db", command = "mcp-server-sqlite", args = { "project.db" } },
  },
})
```
See [[Providers and Models]] for MCP configuration.

### Custom Language Support
Extend Dwight with project-specific language definitions:
```lua
require("dwight").setup({
  languages = {
    java = { detect = {"pom.xml"}, test_cmd = "mvn test -q", build_cmd = "mvn compile -q" },
  },
})
```

---

## Guides

- [[Recipes|Workflow Recipes]] — end-to-end walkthroughs for common tasks
- [[FAQ]] — frequently asked questions
- [[Error Guide]] — common error messages and fixes
- [[Changelog]] — version history and notable changes

---

## Community & Contributing
Dwight is open source (MIT).

- **Found a bug?** [Open an issue on GitHub](https://github.com/otaleghani/dwight.nvim/issues).
- **Questions?** Check the [[FAQ]] or run `:checkhealth dwight` — it catches most setup problems.
