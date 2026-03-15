---
title: Agent Mode
description: Run autonomous AI agents with full tool use — read files, write code, execute commands, and self-correct.
---

# Agent Mode

Agent Mode runs an autonomous AI agent that can read files, write code, run shell commands, and iterate until the task is done. Unlike [[Inline Editing]] which replaces selected code, Agent Mode operates on your entire project with full tool access.

---

## How It Works

1. **Describe the task** — pass a natural-language prompt or visually select text and run `:DwightAgent`.
2. **Planning** — by default the agent creates a plan first. Use `--jump` to skip planning, or `--plan` to force it.
3. **Execution** — the agent reads files, writes code, runs tests, and iterates. Each tool call appears in the status buffer.
4. **Lessons** — after completion, Dwight extracts lessons (patterns that worked, errors and fixes) for future sessions.
5. **Review** — check the diff with `:DwightDiffReview` or step through the session with `:DwightReplay latest`.

```vim
:DwightAgent Add input validation to the user creation endpoint
:DwightAgent --plan Refactor the auth module to use JWT
:DwightAgent --jump Fix the failing test in test_users.py
```

---

## Planning

By default, the agent creates a brief plan before writing code. The plan appears in the status buffer so you can see the approach before execution begins.

- `--plan` — always create a plan first (useful for complex tasks)
- `--jump` — skip planning and start executing immediately (useful for simple fixes)
- No flag — agent decides based on task complexity

---

## Visual Range

Select text in any buffer and use it as the prompt:

```vim
:'<,'>DwightAgent
```

The selected text becomes the task description. This works well with the [[Whiteboard]] — write your thoughts, select the relevant paragraph, and fire it to the agent.

---

## Agent Status Buffer

While the agent runs, `:DwightAgentStatus` toggles a live status buffer showing:

- Current tool call (file read, write, bash command)
- Agent reasoning and decisions
- Progress through the plan
- Errors and retries

The buffer updates in real-time. Close it with `q` or toggle it off.

---

## Diff Review

After the agent finishes, review all changes in one view:

```vim
:DwightDiffReview
```

Opens a split buffer with the full diff of every file the agent modified. This is the same diff format as `git diff` — familiar and easy to scan.

---

## Lessons

Dwight extracts lessons from every agent session — what worked, what failed, what to do differently. Lessons are stored in `.dwight/lessons.json` and automatically included in future agent prompts.

```vim
:DwightLessons                " View all lessons with metadata
:DwightLessons stats          " Summary: total, stale, usage counts
:DwightLessons consolidate    " Merge similar lessons
:DwightLessons clear          " Remove all lessons
```

Each lesson tracks:
- **Keywords** for matching to future tasks
- **Reinforcement count** — how many times the same lesson was learned
- **Use count** — how many times it was injected into a prompt
- **Staleness** — lessons older than 30 days are flagged in `:checkhealth dwight`

---

## Session Logs

Every agent session is logged to `.dwight/agentic-logs/` as JSONL. Browse past sessions:

```vim
:DwightAgentLog              " Telescope picker of past sessions
:DwightSessionLog            " View the persistent session log
```

See [[Session Replay]] for stepping through sessions event by event.

---

## Tips

- **Start with `--plan` for unfamiliar tasks.** The plan shows you what the agent intends to do before it writes code. Cancel early if the approach is wrong.
- **Use visual range from the Whiteboard.** Write detailed requirements on the whiteboard, select the relevant section, and fire with `:'<,'>DwightAgent`.
- **Review lessons periodically.** Run `:DwightLessons consolidate` to merge duplicates and keep the lesson set focused.
- **Check the diff before committing.** `:DwightDiffReview` after every agent run catches unexpected changes.

---

## Commands

| Command | Args | Description |
|---------|------|-------------|
| `:DwightAgent` | `[task] [--plan\|--jump]` | Run autonomous agent. Accepts visual range |
| `:DwightAgentStatus` | | Toggle live agent status buffer |
| `:DwightAgentLog` | | Browse past agent sessions (Telescope) |
| `:DwightDiffReview` | | Open full diff of recent agent changes |
| `:DwightLessons` | `[consolidate\|stats\|clear]` | View or manage learned lessons |
| `:DwightSessionLog` | | View persistent session log |
| `:DwightCancel` | `[all]` | Cancel running agent |

---

## See Also

- [[Auto Mode]] -- for multi-step tasks that run multiple agent sessions sequentially
- [[Inline Editing]] -- for scoped, in-buffer edits instead of autonomous agents
- [[Session Replay]] -- to step through agent sessions event by event
- [[Whiteboard]] -- to draft prompts and fire them to the agent
