---
title: CI/CD & GitHub 
description: Auto-fix CI failures, generate pull requests, and manage issues from Neovim.
---

# CI/CD & GitHub

Dwight integrates with your CI pipeline and GitHub workflow.

______________________________________________________________________

## CI Auto-Fix

When your CI pipeline fails, Dwight can diagnose and fix the issue:

```vim
:DwightCI                    " Auto-fix from latest CI run
:DwightCI <url>              " Fix a specific pipeline run
```

The agent reads the failure output, identifies the root cause, applies a fix, and verifies it passes locally before committing.

______________________________________________________________________

## Git Operations

```vim
:DwightCommit                " Generate a conventional commit from staged changes
:DwightSquash                " Squash Dwight checkpoint commits into one clean commit
:DwightGit stash             " Stash working changes
:DwightGit unstash           " Pop stashed changes
:DwightDiffReview            " Full diff of the last session's changes in a split buffer
```

### Checkpoint Commits

During `:DwightAuto`, each sub-task creates a checkpoint commit:

```
dwight: task 1/8 — HTTP server foundation
dwight: task 2/8 — Template infrastructure
...
```

Use `:DwightSquash` to collapse these into a single commit before merging.

______________________________________________________________________

## GitHub Integration

Requires [GitHub CLI](https://cli.github.com/) (`gh`) to be installed and authenticated.

### Pull Requests

```vim
:DwightPR                    " Create a PR from current branch
:DwightPR "Add user auth"    " Create with a specific title
:DwightPRReview              " AI review of a PR (yours or someone else's)
:DwightPRReview 42           " Review PR #42
```

### Issues

```vim
:DwightIssue 15              " Read issue #15 and start working on it
:DwightNewIssue              " Create a new issue
```

When working on an issue, Dwight includes the issue description and comments in the agent's context.

______________________________________________________________________

## TDD Mode

A test-driven development loop:

```vim
:DwightTDD "user validation"   " Start TDD for a feature
:DwightTDDStop                 " Stop the TDD loop
```

The loop:

1. Agent writes a failing test based on your description
1. Runs the test to confirm it fails
1. Agent implements the minimum code to pass
1. Runs the test to confirm it passes
1. Optionally refactors

This continues until the feature is complete or you stop it.
