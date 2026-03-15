---
title: FAQ
description: Frequently asked questions about Dwight — modes, costs, debugging, backends, and more.
---

# Frequently Asked Questions

---

## Agent vs Auto — when should I use which?

**Agent Mode** (`:DwightAgent`) runs a single autonomous task. Use it for focused work: fix a bug, add a function, write tests for a module.

**Auto Mode** (`:DwightAuto`) decomposes a high-level request into 4-8 sub-tasks, each executed as a separate agent session with test verification and git checkpoints between steps. Use it for larger work: build a feature end-to-end, refactor a subsystem, implement a full API.

Rule of thumb: if you can describe the task in one sentence and it touches fewer than 5 files, use Agent. If it needs planning or has multiple distinct steps, use Auto.

See [[Agent Mode]] and [[Auto Mode]] for details.

---

## How do I reduce token costs?

1. **Switch to a cheaper model** — `:DwightSwitch` lets you pick a smaller model for simple tasks. Use the expensive model only when you need it.
2. **Scope features tightly** — Smaller features mean less context sent to the AI. Use `:DwightSplitFeature` to break large features into sub-features.
3. **Build a digest** — `:DwightDigest` pre-extracts signatures so the agent doesn't need to read every file. This significantly reduces token usage for large codebases.
4. **Use inline modes for small edits** — `:DwightMode refactor` on a selection is much cheaper than launching a full agent session.
5. **Check usage** — `:DwightUsage` shows a quick summary, `:DwightStats` gives a full dashboard with per-feature breakdowns.

---

## Why did my agent task fail?

Common failure modes:

- **Test command not detected** — Dwight needs to know how to run tests. Check `:DwightHealth` or set `test_cmd` in your config.
- **Task too broad** — If the agent tries to do too much, it may run out of context or make conflicting changes. Break the task into smaller pieces or use Auto mode.
- **Missing context** — The agent only sees files tagged with `@feature:` pragmas. Run `:DwightBootstrap` if your project isn't fully tagged.
- **External dependency** — The agent can't install packages, access databases, or call external services. Handle those steps manually.

To debug: run `:DwightReplay` to step through exactly what the agent did, or check `:DwightLog` for the raw job log.

---

## Can I use multiple backends?

Yes. Switch backends at any time with `:DwightBackend`:

```vim
:DwightBackend claude_code    " Switch to Claude Code
:DwightBackend codex          " Switch to OpenAI Codex
:DwightBackend gemini         " Switch to Gemini CLI
```

Each backend has its own model selection (`:DwightSwitch`). Your skills, features, and project configuration are shared across all backends.

See [[Providers and Models]] for full configuration.

---

## What gets sent to the AI?

Dwight sends only what's relevant to your task:

- **Feature context** — files and signatures tagged with `@feature:` pragmas related to your request
- **Skills** — any coding skills referenced in your prompt (with `@skill`)
- **Library references** — API docs added with `:DwightAddLib` (referenced with `%lib`)
- **Digest** — pre-extracted signatures if you've built one with `:DwightDigest`
- **Your prompt** — the task description you provide

Dwight does **not** send your entire codebase, environment variables, git history, or any files outside the feature scope. Use `:DwightProjectContext` to preview exactly what the AI will see.

---

## How do I undo agent changes?

Dwight creates git checkpoints during Auto mode, so you can always roll back:

- **Undo the last auto session** — the checkpoint commits are on your current branch. Use `git reset` or `git revert` to roll back.
- **Squash checkpoint commits** — `:DwightSquash` combines all dwight checkpoint commits into a single clean commit.
- **Review before deciding** — `:DwightDiffReview` opens the full diff of recent changes in a split buffer.
- **Undo multi-file inline edits** — `:DwightMultiUndo` reverts the last multi-file change set.

---

## Does Dwight work offline?

No. Dwight requires a connection to an AI backend (Claude Code, Codex, or Gemini CLI), which in turn calls cloud APIs. There is no local/offline mode.

The CLI backends handle all API communication. Dwight itself doesn't make direct API calls for agent/auto tasks — it delegates to the CLI tool you've configured.

---

## How do skills differ from templates?

**Skills** (`:DwightSkills`) are structured markdown guides that encode your project's coding conventions — things like "always use structured errors", "prefer table-driven tests", or "use dependency injection for services". They're referenced in prompts with `@skill` and become part of the AI's instructions.

**Templates** (`:DwightTemplate`) are reusable prompt snippets — saved text you can quickly paste into any prompt. They're convenience shortcuts, not coding instructions.

Think of skills as "how to write code" and templates as "what to ask for".

See [[Skills and Marketplace]] and [[Templates]] for details.
