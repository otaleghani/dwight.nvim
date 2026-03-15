---
title: Commands
description: Complete reference for all 85+ Dwight commands, grouped by feature with args and descriptions.
---
# Command Reference

All commands are prefixed with `:Dwight`. Most accept optional arguments and provide tab completion.

---

## Inline Editing → [[Inline Editing]]

| Command | Args | Description |
|---------|------|-------------|
| `:DwightInvoke` | | Open prompt buffer for current selection or treesitter scope |
| `:DwightMode` | `<mode>` | Apply a built-in mode (tab-complete available) |
| `:DwightRepeat` | | Replay last operation on current selection |
| `:DwightMultiUndo` | | Undo last multi-file change set |
| `:DwightCancel` | `[all]` | Cancel nearest active job, or all jobs |
| `:DwightLintClear` | | Clear dwight lint diagnostics from buffer |

---

## Agent Mode → [[Agent Mode]]

| Command | Args | Description |
|---------|------|-------------|
| `:DwightAgent` | `[task] [--plan\|--jump]` | Run autonomous agent. Accepts visual range |
| `:DwightAgentStatus` | | Toggle live agent status buffer |
| `:DwightAgentLog` | | Browse past agent sessions (Telescope) |
| `:DwightDiffReview` | | Open full diff of recent agent changes |
| `:DwightLessons` | `[consolidate\|stats\|clear]` | View or manage learned lessons |
| `:DwightSessionLog` | | View persistent session log |

---

## Auto Mode → [[Auto Mode]]

| Command | Args | Description |
|---------|------|-------------|
| `:DwightAuto` | `[task]` | Plan and execute multi-step task. Accepts visual range |
| `:DwightAutoStatus` | | Show session progress |
| `:DwightAutoCancel` | | Cancel the running session |
| `:DwightAutoRetry` | | Retry last failed sub-task |
| `:DwightAutoResume` | `[override prompt]` | Resume from next pending sub-task |
| `:DwightAutoReview` | | Review plan before continuing |
| `:DwightAutoSkip` | | Skip current sub-task |
| `:DwightPause` | | Pause after current sub-task |
| `:DwightContinue` | `[override prompt]` | Resume paused session |

---

## Bootstrap and Coverage → [[Bootstrap and Coverage]]

| Command | Args | Description |
|---------|------|-------------|
| `:DwightInit` | | Initialize `.dwight/` directory |
| `:DwightBootstrap` | `[--quick\|--agentic] [--force\|--incremental]` | Add feature pragmas to source files |
| `:DwightCoverage` | | Show pragma coverage stats |
| `:DwightHealth` | | Run diagnostic health check |

---

## Feature Management → [[Feature Management]]

| Command | Args | Description |
|---------|------|-------------|
| `:DwightFeatures` | | Browse live features from pragmas |
| `:DwightFeaturePreview` | `[feature]` | Preview feature context (files, signatures, deps) |
| `:DwightProjectContext` | | Preview full JIT project context |
| `:DwightMinimap` | `[path]` | Treesitter signature map of file or directory |
| `:DwightSplitFeature` | `[feature] [--agentic]` | Split a large feature into sub-features |
| `:DwightSplitPreview` | `[feature]` | Preview a split without applying |
| `:DwightSplitAudit` | | Check which features need splitting |

---

## Refactoring → [[Refactoring]]

| Command | Args | Description |
|---------|------|-------------|
| `:DwightRefactor` | `[feature] [prompt]` | Refactor a feature with importer analysis |

---

## TDD → [[TDD]]

| Command | Args | Description |
|---------|------|-------------|
| `:DwightTDD` | `[description]` | Start a TDD session |
| `:DwightTDDStop` | | Stop the active TDD session |
| `:DwightTestRuns` | | Browse test run history |
| `:DwightRun` | `[cmd]` | Run a build/test command |
| `:DwightRunOutput` | | Show last run output |

---

## Git Operations → [[Git Operations]]

| Command | Args | Description |
|---------|------|-------------|
| `:DwightGit` | `[subcommand]` | Git workflow: status, commit, stash, pop, push, pull, cleanup, conflicts, resolve |
| `:DwightCommit` | | Generate commit message from staged changes |
| `:DwightSquash` | | Squash dwight checkpoint commits into one |
| `:DwightDiffReview` | | Open full diff of recent changes |
| `:DwightDiffToggle` | | Toggle diff preview |
| `:DwightGitToggle` | | Toggle git diff/blame in prompts |

---

## GitHub Integration → [[GitHub Integration]]

| Command | Args | Description |
|---------|------|-------------|
| `:DwightIssue` | `[number] [--agent\|--auto\|--analyze] [--label\|--assignee\|--milestone\|--repo]` | Browse and solve GitHub issues |
| `:DwightNewIssue` | `[title] [--label\|--milestone\|--repo]` | Create a new GitHub issue |
| `:DwightPR` | | Create PR for current branch |
| `:DwightPRReview` | `[number] [--repo]` | AI review of a pull request |
| `:DwightCI` | `[--fix [run_id]\|--rerun] [--repo]` | CI status, auto-fix, and re-run |

---

## Skills and Marketplace → [[Skills and Marketplace]]

| Command | Args | Description |
|---------|------|-------------|
| `:DwightSkills` | | Browse project skills (Telescope) |
| `:DwightGenSkill` | | AI-generate a new skill |
| `:DwightInstallSkills` | | Install built-in skills |
| `:DwightMarketplace` | `[install\|suggest\|export\|import\|detect]` | Browse and manage skill packs |

---

## Library References → [[Library References]]

| Command | Args | Description |
|---------|------|-------------|
| `:DwightAddLib` | | Add a library API reference |
| `:DwightLibs` | | Browse library references |
| `:DwightDocsFromURL` | | Generate a skill from a documentation URL |

---

## Docs Generation → [[Docs Generation]]

| Command | Args | Description |
|---------|------|-------------|
| `:DwightDocs` | `[target] [--agentic\|--update\|--seo]` | Generate, update, or optimize docs |
| `:DwightDocsBrowse` | | Browse generated public docs |
| `:DwightDevDocs` | `[target] [--agentic]` | Generate internal developer docs |
| `:DwightDevDocsBrowse` | | Browse developer docs |

---

## Codebase Audit and Heal → [[Codebase Audit and Heal]]

| Command | Args | Description |
|---------|------|-------------|
| `:DwightAudit` | `[feature] [--deep]` | Run codebase audit |
| `:DwightHeal` | `[feature]` | Rehabilitate: char tests, plan, execute |

---

## Codebase Digest → [[Codebase Digest]]

| Command | Args | Description |
|---------|------|-------------|
| `:DwightDigest` | `[--status\|--clear\|--force]` | Build, inspect, or rebuild codebase digest |

---

## Session Replay → [[Session Replay]]

| Command | Args | Description |
|---------|------|-------------|
| `:DwightReplay` | `[session]` | Step through a past session |
| `:DwightSessionLog` | | View persistent session log |
| `:DwightLog` | | View job log (all operations) |

### Replay Keybindings

| Key | Action |
|-----|--------|
| `j` / `l` / `Space` | Next step |
| `k` / `h` | Previous step |
| `J` | Jump to next tool call |
| `K` | Jump to previous tool call |
| `gg` / `G` | First / last step |
| `v` | Toggle single/cumulative view |
| `q` / `Esc` | Close |

---

## Whiteboard → [[Whiteboard]]

| Command | Args | Description |
|---------|------|-------------|
| `:DwightWhiteboard` | | Open brainstorming scratchpad |
| `:DwightWhiteboardSave` | `[name]` | Save whiteboard (supports visual range) |
| `:DwightBrainstorms` | | Browse saved brainstorms |

---

## Templates → [[Templates]]

| Command | Args | Description |
|---------|------|-------------|
| `:DwightTemplate` | | Pick a saved template (copies to clipboard) |
| `:DwightSaveTemplate` | `[prompt]` | Save a reusable prompt template |

---

## Workspace → [[Workspace]]

| Command | Args | Description |
|---------|------|-------------|
| `:DwightWorkspace` | | Show workspace status |
| `:DwightWorkspaceAdd` | `[path]` | Add a repo by path |
| `:DwightWorkspaceRemove` | `[name]` | Remove a repo |
| `:DwightWorkspaceInit` | | Auto-scan monorepo sub-directories |
| `:DwightWorkspaceFeatures` | | List features across all repos |
| `:DwightWorkspaceIssues` | `[--label\|--assignee\|--milestone]` | Unified issue view |

---

## Telemetry and Stats → [[Telemetry and Stats]]

| Command | Args | Description |
|---------|------|-------------|
| `:DwightUsage` | | Quick usage summary (floating window) |
| `:DwightStats` | `[features\|export\|csv\|json]` | Full telemetry dashboard |
| `:DwightLessons` | `[consolidate\|stats\|clear]` | View or manage learned lessons |

---

## Providers and Models → [[Providers and Models]]

| Command | Args | Description |
|---------|------|-------------|
| `:DwightBackend` | `[claude_code\|codex\|gemini\|opencode]` | Get or set the CLI backend |
| `:DwightSwitch` | `<model>` | Switch model (filtered by backend) |
| `:DwightProviders` | | Show current provider/model/key status |
| `:DwightAddProvider` | | Add a custom API provider |
| `:DwightAuthMax` | | Authenticate with Anthropic Pro/Max |
| `:DwightMCP` | | Show MCP server status |
| `:DwightStreamToggle` | | Toggle streaming output |

---

## Status and Health

| Command | Args | Description |
|---------|------|-------------|
| `:DwightStatus` | | Full status overview |
| `:DwightHealth` | | Run health check |
