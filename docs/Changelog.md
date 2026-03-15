---
title: Changelog
description: Version history and notable changes for Dwight.
---

# Changelog

---

## v2.0 — Module Refactoring and New Features

The v2 release is a major restructuring of Dwight's internals, splitting monolithic modules into focused subdirectories and adding several new feature areas.

### Architecture Changes

Monolithic modules have been split into subdirectories for maintainability:

| Old Module | New Location |
|-----------|-------------|
| `agent.lua` | `agent/` directory |
| `auto.lua` | `auto/` directory |
| `bootstrap.lua` | `bootstrap/` directory |
| `audit.lua` + `codebase_audit.lua` | `codebase_audit/` directory |
| `docs.lua` + `pubdocs.lua` | `pubdocs/` directory |
| `inline.lua` | `inline/` directory |
| `split.lua` | `split/` directory |
| `ui.lua` | `ui/` directory |
| `github.lua` | `github/` directory |
| `marketplace.lua` | `marketplace/` directory |
| `execute.lua` | Merged into `agent/` |
| `opencode.lua` | Merged into provider system |

### New Features

- **TDD Mode** — Test-driven development loop with `:DwightTDD` (run -> fix -> rerun)
- **Refactoring** — Feature-scoped refactoring with importer analysis via `:DwightRefactor`
- **Workspace** — Multi-repo workspace support with `:DwightWorkspace` commands
- **Git Operations** — Unified git workflow with `:DwightGit` subcommands (status, commit, stash, push, pull, cleanup, conflicts, resolve)
- **GitHub Integration** — Expanded with `:DwightNewIssue`, `:DwightPRReview`, and `:DwightCI --rerun`
- **Feature Management** — New commands for feature splitting and auditing
- **Library References** — Structured API reference system with `:DwightAddLib`
- **Commands module** — All user commands extracted into `commands.lua` for readability

### Documentation Changes

Documentation was reorganized to match the new module structure:

| Removed Page | Replacement |
|-------------|-------------|
| Audit and Heal | [[Codebase Audit and Heal]] |
| CICD and Github | [[Git Operations]] + [[GitHub Integration]] |
| Skills Marketplace | [[Skills and Marketplace]] |
| Telemetry | [[Telemetry and Stats]] |
| Whiteboard and Templates | [[Whiteboard]] + [[Templates]] |

New documentation pages added:
- [[Agent Mode]]
- [[Bootstrap and Coverage]]
- [[Feature Management]]
- [[Git Operations]]
- [[GitHub Integration]]
- [[Inline Editing]]
- [[Library References]]
- [[Providers and Models]]
- [[Refactoring]]
- [[TDD]]
- [[Templates]]
- [[Whiteboard]]
