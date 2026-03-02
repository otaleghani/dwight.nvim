---
title: Commands
description: Complete reference for all Dwight commands, grouped by category.
---
# Command Reference

All commands are prefixed with `:Dwight`. Most accept optional arguments and provide tab completion.

---

## Project Setup

| Command | Args | Description |
|---------|------|-------------|
| `:DwightInit` | | Initialize `.dwight/` directory with skills and project scope |
| `:DwightBootstrap` | `[--agentic]` | Auto-add `@feature:` pragmas to source files. `--agentic` reads code for better results |
| `:DwightHealth` | | Diagnostic report: backend, keys, project status |

Run `:checkhealth dwight` for the Neovim-native health check.

---

## Autonomous Execution

| Command | Args | Description |
|---------|------|-------------|
| `:DwightAuto` | `<task>` | Plan and execute a multi-step task with sub-tasks, verification gates, and git checkpoints |
| `:DwightAutoStatus` | | Show current Auto session progress |
| `:DwightAutoCancel` | | Cancel the running Auto session |
| `:DwightAutoRetry` | | Retry the last failed sub-task |
| `:DwightAutoResume` | | Resume from the next pending sub-task |
| `:DwightAutoSkip` | | Skip the current sub-task and continue |
| `:DwightAutoReview` | | Review the Auto plan before continuing |
| `:DwightPause` | | Pause after the current sub-task finishes |
| `:DwightContinue` | | Resume a paused session |
| `:DwightAgent` | `<task>` | Run a single agentic task (no sub-task planning) |
| `:DwightAgentStatus` | | Show agent execution buffer |
| `:DwightAgentLog` | | View agent execution history |

---

## Code Operations

| Command | Args | Description |
|---------|------|-------------|
| `:DwightRefactor` | | AI-assisted refactoring of current selection or file |
| `:DwightExecute` | | Execute an inline AI instruction (comment-driven) |
| `:DwightRun` | `<cmd>` | Run a shell command and capture output |
| `:DwightRunOutput` | | Show the last command output |
| `:DwightCommit` | | Generate a conventional commit message from staged changes |
| `:DwightRepeat` | | Re-run the last Dwight operation |

---

## Features & Context

| Command | Args | Description |
|---------|------|-------------|
| `:DwightFeatures` | | List all detected features with file counts |
| `:DwightFeaturePreview` | `[feature]` | Detailed view of a feature: files, signatures, dependencies |
| `:DwightCoverage` | | Show pragma coverage stats (tagged vs untagged files) |
| `:DwightMinimap` | | Treesitter signature map of the current buffer |
| `:DwightProjectContext` | | Show the full context that would be sent to an agent |
| `:DwightSplitFeature` | `[feature] [--agentic]` | Split a large feature into sub-features |
| `:DwightSplitPreview` | `[feature]` | Preview a split without applying |
| `:DwightSplitAudit` | | Check which features are too large and should be split |

---

## Skills & Marketplace

| Command | Args | Description |
|---------|------|-------------|
| `:DwightSkills` | | Browse project skills (Telescope picker) |
| `:DwightGenSkill` | | AI-generate a new skill from a description |
| `:DwightInstallSkills` | | Install built-in skills |
| `:DwightDocsFromURL` | | Generate a skill from a documentation URL |
| `:DwightMarketplace` | `[action]` | Browse skill packs. Actions: `install`, `suggest`, `export`, `import`, `detect` |
| `:DwightAddLib` | | Add a library API reference |
| `:DwightLibs` | | Browse library references |

---

## Documentation

| Command | Args | Description |
|---------|------|-------------|
| `:DwightDocs` | `[target] [--agentic]` | Generate public docs. `--agentic` reads source code for accuracy |
| `:DwightDocsBrowse` | | Browse generated documentation |
| `:DwightDevDocs` | `[target] [--agentic]` | Generate internal developer docs |
| `:DwightDevDocsBrowse` | | Browse developer documentation |

---

## Testing & CI

| Command | Args | Description |
|---------|------|-------------|
| `:DwightTDD` | `[description]` | Start a TDD loop: write test → run → fix → rerun |
| `:DwightTDDStop` | | Stop the active TDD session |
| `:DwightCI` | `[url]` | Auto-fix CI failures from a pipeline URL or latest run |
| `:DwightTestRuns` | | View recent test run history |

---

## Git & GitHub

| Command | Args | Description |
|---------|------|-------------|
| `:DwightGit` | `<subcmd>` | Git operations: `stash`, `unstash`, `status`, `log` |
| `:DwightGitToggle` | | Toggle git context inclusion in prompts |
| `:DwightSquash` | | Squash Dwight checkpoint commits into one |
| `:DwightDiffReview` | | Open a full diff of the last session's changes |
| `:DwightDiffToggle` | | Toggle diff preview mode |
| `:DwightPR` | `[title]` | Create a pull request from current changes |
| `:DwightPRReview` | `[number]` | AI review of a pull request |
| `:DwightIssue` | `[number]` | Work on a GitHub issue |
| `:DwightNewIssue` | | Create a new GitHub issue |

---

## Session & Replay

| Command | Args | Description |
|---------|------|-------------|
| `:DwightReplay` | `[session]` | Interactive session replay. Args: `latest`, filename, or blank for picker |
| `:DwightSessionLog` | | View the persistent session log |
| `:DwightLog` | | View the job log (all operations) |

### Replay Keybindings
Inside the replay buffer:

| Key | Action |
|-----|--------|
| `j` / `→` / `Space` | Next step |
| `k` / `←` | Previous step |
| `J` | Jump to next tool call |
| `K` | Jump to previous tool call |
| `gg` | First step |
| `G` | Last step |
| `v` | Toggle single/cumulative view |
| `q` / `Esc` | Close |

---

## Telemetry & Stats

| Command | Args | Description |
|---------|------|-------------|
| `:DwightUsage` | | Quick usage summary in a floating window |
| `:DwightStats` | `[target]` | Full telemetry dashboard. Targets: `features`, `export` |
| `:DwightLessons` | `[action]` | View or manage learned lessons. Actions: `consolidate` |

---

## Configuration & Backend

| Command | Args | Description |
|---------|------|-------------|
| `:DwightBackend` | `[name]` | Switch backend: `claude_code`, `codex`, `gemini` |
| `:DwightSwitch` | `[model]` | Switch AI model |
| `:DwightMode` | `[mode]` | Switch operation mode |
| `:DwightStreamToggle` | | Toggle streaming output |
| `:DwightProviders` | | List configured providers |
| `:DwightAddProvider` | | Add a new provider |
| `:DwightMCP` | | Manage MCP server connections |

---

## Multi-Repo Workspace

| Command | Args | Description |
|---------|------|-------------|
| `:DwightWorkspace` | | Show workspace status |
| `:DwightWorkspaceAdd` | `[path]` | Add a repository to the workspace |
| `:DwightWorkspaceRemove` | | Remove a repository from the workspace |
| `:DwightWorkspaceInit` | | Initialize all repos in the workspace |
| `:DwightWorkspaceFeatures` | | List features across all workspace repos |
| `:DwightWorkspaceIssues` | | List issues across workspace repos |

---

## Other

| Command | Args | Description |
|---------|------|-------------|
| `:DwightWhiteboard` | | Open a scratchpad for brainstorming with AI |
| `:DwightWhiteboardSave` | | Save whiteboard contents |
| `:DwightBrainstorms` | | Browse saved brainstorm sessions |
| `:DwightTemplate` | `[name]` | Apply a project template |
| `:DwightSaveTemplate` | | Save current project as a template |
| `:DwightAudit` | | Run a codebase quality audit |
| `:DwightHeal` | `[target]` | Auto-fix codebase issues found by audit |
| `:DwightLintClear` | | Clear inline lint diagnostics |
| `:DwightInvoke` | `<function>` | Call a specific Lua function (advanced) |
| `:DwightCancel` | | Cancel any running operation |
| `:DwightMultiUndo` | | Undo across multiple files |
