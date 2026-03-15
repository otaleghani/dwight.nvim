---
title: Error Guide
description: Common Dwight error messages with causes and fixes.
---

# Error Guide

This page documents common error messages you may encounter while using Dwight, along with their causes and fixes.

---

## Backend Errors

| Error | Cause | Fix |
|-------|-------|-----|
| `spawn failed: ENOENT` | CLI binary not found in PATH | Install the backend: `npm i -g @anthropic-ai/claude-code` (or equivalent). Restart Neovim. |
| `Backend exited with code 1` | CLI crashed or hit a fatal error | Check the backend's own logs. Run the CLI manually in a terminal to see the full error output. |
| `Backend timed out` | Task took longer than the configured timeout | Increase `agent_timeout` in your config, or break the task into smaller pieces. |
| `Backend exited with signal SIGTERM` | Process was killed (OOM, manual kill, or system) | Check system memory. Large codebases may need more RAM for the CLI process. |

---

## API and Authentication Errors

| Error | Cause | Fix |
|-------|-------|-----|
| `Unauthorized` / `401` | Invalid or expired API key | Re-export your API key env var, or run `claude login` for Claude Code. |
| `Rate limited` / `429` | Too many requests in a short period | Wait and retry. Consider switching to a model with higher rate limits, or reduce request frequency. |
| `Quota exhausted` / `402` | Billing limit reached | Check your API provider dashboard. Add credits or upgrade your plan. |
| `Token expired` | OAuth token needs refresh | Run `:DwightAuthMax` to re-authenticate, or `claude login` for CLI auth. |
| `Model not available` | Requested model doesn't exist or isn't enabled | Run `:DwightSwitch` to pick from available models. Check your API plan supports the model. |

---

## Context and Feature Errors

| Error | Cause | Fix |
|-------|-------|-----|
| `No features found` | No `@feature:` pragmas in source files | Run `:DwightBootstrap` to auto-add pragmas. |
| `Feature context too large` | Feature has too many files or too much code for the context window | Split the feature with `:DwightSplitFeature`. Or build a digest with `:DwightDigest` to use compressed signatures instead. |
| `Feature not found: <name>` | Pragma name doesn't match any detected feature | Check spelling. Run `:DwightFeatures` to see all detected feature names. |
| `Treesitter parser not available` | Missing parser for the file's language | Install it: `:TSInstall <language>`. |

---

## Digest Errors

| Error | Cause | Fix |
|-------|-------|-----|
| `Digest build failed` | Source files couldn't be parsed or directory is empty | Check that your project has source files and treesitter parsers are installed. |
| `Digest is stale` | Source files changed since last digest build | Rebuild with `:DwightDigest --force`. |
| `No digest available` | Digest hasn't been built yet | Run `:DwightDigest` to build one. |

---

## Git and Checkpoint Errors

| Error | Cause | Fix |
|-------|-------|-----|
| `Not a git repository` | Project root has no `.git/` directory | Run `git init` in your project root. |
| `Dirty working tree` | Uncommitted changes block the operation | Commit or stash changes first: `:DwightGit stash` or `:DwightGit commit`. |
| `Merge conflict during checkpoint` | Agent changes conflicted with concurrent edits | Resolve conflicts manually or with `:DwightGit resolve`, then `:DwightAutoResume`. |
| `Nothing to squash` | No dwight checkpoint commits found on current branch | `:DwightSquash` only works after Auto mode has created checkpoint commits. |
| `Cannot create checkpoint` | Git operation failed (permissions, disk space, lock file) | Check `git status` manually. Look for `.git/index.lock` (stale lock file). |

---

## MCP Server Errors

| Error | Cause | Fix |
|-------|-------|-----|
| `MCP server failed to start` | Server binary not found or crashed on startup | Verify the server command exists and runs standalone. Check the command and args in your config. |
| `MCP connection lost` | Server process exited unexpectedly | Check `:DwightMCP` for status. Restart with `:DwightAgent` (MCP reconnects automatically). |
| `MCP tool not found` | Server doesn't expose the expected tool | Verify the MCP server version matches what Dwight expects. Check server docs. |

---

## Auto Mode Errors

| Error | Cause | Fix |
|-------|-------|-----|
| `No active session` | Tried to resume/skip/retry with no session running | Start a new session with `:DwightAuto`. |
| `Session already active` | Tried to start a new session while one is running | Cancel the current session with `:DwightAutoCancel`, or wait for it to finish. |
| `Sub-task failed` | An individual agent step failed its verification | Use `:DwightAutoRetry` to retry with error context, `:DwightAutoSkip` to skip it, or `:DwightAutoResume` with an override prompt. |
| `All sub-tasks failed` | Multiple consecutive failures | Review the plan with `:DwightAutoReview`. The task may need to be broken down differently or approached manually. |

---

See [[Getting Started#Troubleshooting]] for setup-specific issues and `:checkhealth dwight` for automated diagnostics.
