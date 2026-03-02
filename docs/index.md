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

The `@feature:auth` pragma tells Dwight which files belong together. When an agent works on auth, it only sees auth files. This keeps context tight and results accurate.

### Autonomous Multi-Step Execution
Give Dwight a task like "Create a web UI with HTMX" and it will:
1. **Plan** — break it into 4-8 sub-tasks automatically
2. **Execute** — run each sub-task through an AI agent with tool use
3. **Verify** — run `go test ./...` (or your test command) after each step
4. **Checkpoint** — git commit after each passing step
5. **Learn** — extract lessons for future sessions

If a step fails, it retries with the error context. If it still fails, it pauses so you can intervene.

### Skill System
Skills are reusable markdown guides that tell the AI *how* to write code for your project. They encode patterns, anti-patterns, and conventions:

```vim
:DwightGenSkill      " AI-generates a skill from a description
:DwightMarketplace   " Browse curated skill packs for Go, React, Rust, etc.
```

Skills are stored in `.dwight/skills/` and automatically included in agent context.

### Session Replay
Step through past agent sessions like a debugger. See every tool call, every thought, every result:

```vim
:DwightReplay latest    " Step through the most recent session
```

Navigate with `j`/`k`, jump between tool calls with `J`/`K`, toggle cumulative view with `v`.

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
      backend = "claude_code",     -- or "codex", "gemini"
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

### 2. Plan → [[Auto Mode]]
`:DwightAuto <task>` breaks work into sub-tasks, each scoped to relevant features with verification gates.

### 3. Build → [[Auto Mode]]
Agents execute each sub-task: reading files, writing code, running commands, and self-correcting.

### 4. Review → [[Session Replay]]
Step through what the agent did with `:DwightReplay`. Check the diff with `:DwightDiffReview`.

### 5. Ship → [[CI/CD & GitHub]]
`:DwightCI` auto-fixes CI failures. `:DwightPR` generates pull requests. `:DwightCommit` writes conventional commits.

### 6. Learn → [[Core Concepts]]
Dwight extracts lessons from each session and applies them to future tasks automatically.

---

## Feature Overview

| Feature | Command | Description |
|---------|---------|-------------|
| **Auto Mode** | `:DwightAuto` | Multi-step task planning and execution |
| **Agent** | `:DwightAgent` | Single agentic task with tool use |
| **Skills** | `:DwightSkills` | Browse and manage coding skills |
| **Marketplace** | `:DwightMarketplace` | Install curated skill packs |
| **Replay** | `:DwightReplay` | Step through past sessions |
| **Bootstrap** | `:DwightBootstrap` | Auto-add feature pragmas |
| **Split** | `:DwightSplitFeature` | Break large features into smaller ones |
| **Docs** | `:DwightDocs` | Generate project documentation |
| **TDD** | `:DwightTDD` | Test-driven development loop |
| **CI/CD** | `:DwightCI` | Auto-fix CI pipeline failures |
| **GitHub** | `:DwightPR` / `:DwightIssue` | PR and issue management |
| **Stats** | `:DwightStats` | Telemetry dashboard |
| **Health** | `:checkhealth dwight` | Validate your setup |

See the full [[Commands|command reference]] for all 80+ commands.

---

## Advanced Features

### Multi-Repo Workspaces
Work across multiple repositories as a single workspace. Features can span repos, agents have cross-repo context.
```vim
:DwightWorkspaceAdd ../shared-lib
:DwightWorkspaceFeatures
```

### MCP Server Integration
Connect external tools via the Model Context Protocol:
```lua
require("dwight").setup({
  mcp_servers = {
    { name = "db", command = "mcp-server-sqlite", args = { "project.db" } },
  },
})
```

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

## Community & Contributing
Dwight is open source (MIT).

- **Found a bug?** [Open an issue on GitHub](https://github.com/otaleghani/dwight.nvim/issues).
- **Questions?** Check `:checkhealth dwight` first — it catches most setup problems.
