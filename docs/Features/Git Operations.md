---
title: Git Operations
description: AI-powered git workflow with smart commits, checkpoint squashing, diff review, and nine git subcommands.
---

# Git Operations

Dwight wraps common git operations with AI assistance — smart commit messages from staged changes, checkpoint squashing after Auto sessions, and a unified `:DwightGit` command for daily workflow.

---

## How It Works

1. **Work normally** — write code with `:DwightAgent`, `:DwightAuto`, or manual edits.
2. **Commit** — `:DwightCommit` analyzes staged changes and generates a conventional commit message.
3. **Squash checkpoints** — after a `:DwightAuto` session, `:DwightSquash` collapses checkpoint commits into one clean commit.
4. **Review** — `:DwightDiffReview` opens all recent changes in a split buffer.

---

## DwightGit

A unified entry point for common git operations:

```vim
:DwightGit                   " Picker with all subcommands
:DwightGit status            " Show working tree status
:DwightGit commit            " Stage and commit with AI message
:DwightGit stash             " Stash working changes
:DwightGit pop               " Pop stashed changes
:DwightGit push              " Push current branch
:DwightGit pull              " Pull and rebase
:DwightGit cleanup           " Remove merged branches
:DwightGit conflicts         " List merge conflicts
:DwightGit resolve           " AI-assisted conflict resolution
```

All subcommands tab-complete.

---

## Smart Commits

```vim
:DwightCommit
```

Reads staged changes plus the AI context from the current session (what was requested, what modes were used) to generate a meaningful commit message. The message follows conventional commit format and explains *why* the change was made, not just what changed.

---

## Checkpoint Squashing

During `:DwightAuto`, each sub-task creates a checkpoint commit:

```
dwight: task 1/8 — HTTP server foundation
dwight: task 2/8 — Template infrastructure
dwight: task 3/8 — Task list view page
```

After the session completes, squash them into one clean commit:

```vim
:DwightSquash
```

Dwight identifies all consecutive `dwight:` checkpoint commits and squashes them with an AI-generated summary message.

---

## Diff Review

```vim
:DwightDiffReview
```

Opens a split buffer with the full diff of all changes from the most recent agent session. The diff includes every file modified, created, or deleted — the same format as `git diff`.

---

## Context Toggle

```vim
:DwightGitToggle
```

Toggles whether git diffs and blame information are included in AI prompts. When enabled (default), the AI sees what you recently changed and who last modified each line — helpful for understanding intent.

```vim
:DwightDiffToggle
```

Toggles the diff preview that appears before applying inline changes.

---

## Tips

- **Squash before merging.** Checkpoint commits are useful during development but noisy in the main branch history. Always `:DwightSquash` before creating a PR.
- **Use `:DwightCommit` after manual edits too.** It works with any staged changes, not just Dwight-generated code.
- **Keep git context on.** The diff and blame context helps the AI understand recent changes and avoid undoing your work.
- **Use `:DwightGit resolve` for conflicts.** The AI reads both sides of the conflict and the surrounding code to generate a sensible merge.

---

## Commands

| Command | Args | Description |
|---------|------|-------------|
| `:DwightGit` | `[subcommand]` | Git workflow: status, commit, stash, pop, push, pull, cleanup, conflicts, resolve |
| `:DwightCommit` | | Generate commit message from staged changes + AI context |
| `:DwightSquash` | | Squash dwight checkpoint commits into one |
| `:DwightDiffReview` | | Open full diff of recent agent changes |
| `:DwightDiffToggle` | | Toggle diff preview before applying changes |
| `:DwightGitToggle` | | Toggle git diff/blame in prompts |

---

## See Also

- [[Auto Mode]] -- creates checkpoint commits that `:DwightSquash` collapses
- [[GitHub Integration]] -- for PRs, issues, and CI after committing
- [[Agent Mode]] -- `:DwightDiffReview` shows what the agent changed
