---
title: Auto Mode
description: Multi-step task planning and autonomous execution with verification gates, git checkpoints, and session control.
---

# Auto Mode

Auto Mode is Dwight's most powerful feature. Give it a high-level task description and it will plan, execute, verify, and checkpoint the work autonomously — breaking complex tasks into 4-8 sub-tasks with full agent sessions, test verification, and git commits at every step.

---

## How It Works

1. **Describe the task** — pass a natural-language prompt or visually select text.
2. **Planning** — Dwight analyzes your project context and breaks the task into ordered sub-tasks.
3. **Baseline snapshot** — runs your test suite and records pre-existing failures.
4. **Execution** — each sub-task runs through a full agent session with tool use.
5. **Verification gates** — after each sub-task, runs the detected test command. If tests fail, the agent gets one retry with error context.
6. **Git checkpoints** — after each passing gate, creates a commit: `dwight: task 3/8 — Task list view page`.
7. **Learning** — extracts lessons from the session for future use.

```vim
:DwightAuto Create a web UI using template/html and HTMX
```

Example plan:
```
8 sub-tasks:
  1. HTTP server foundation and routing
  2. Template infrastructure
  3. Task list view page
  4. Create task with HTMX
  5. Delete and toggle task status
  6. Tag management
  7. Edit task inline
  8. Styling and polish
```

---

## Session Control

While Auto is running, you have full control:

```vim
:DwightPause          " Pause after the current sub-task finishes
:DwightContinue       " Resume a paused session (optional: override prompt)
:DwightAutoCancel     " Cancel the entire session
:DwightAutoSkip       " Skip the failed/next sub-task
:DwightAutoRetry      " Retry failed sub-task with error context
:DwightAutoResume     " Resume from next pending sub-task (optional: override prompt)
:DwightAutoReview     " Review the remaining plan before continuing
:DwightAutoStatus     " Show session progress
```

---

## Resumable Sessions

If a sub-task fails even after retry, the session pauses. The state is saved to `.dwight/auto/current.json`. Fix the issue manually, then resume:

```vim
:DwightAutoResume                        " Continue from next pending task
:DwightAutoResume Fix the auth endpoint  " Override the next task's prompt
```

Previously completed tasks are marked with a checkmark and skipped.

---

## Visual Range

Select text in any buffer and use it as the task description:

```vim
:'<,'>DwightAuto
```

The selected text becomes the prompt. Text arguments take precedence over visual selection if both are provided.

---

## Agent vs Auto

| | Agent | Auto |
|---|---|---|
| **Scope** | Single task | Multi-step decomposition |
| **Planning** | Optional (`--plan`) | Always plans first |
| **Verification** | None | Test gates after each step |
| **Git** | No automatic commits | Checkpoint after each step |
| **Resumable** | No | Yes, full state persistence |
| **Best for** | Focused fixes, single features | Large features, full implementations |

Use `:DwightAgent` for tasks that fit in one session. Use `:DwightAuto` when the work naturally breaks into multiple steps.

---

## Tips

- **Be specific about technology choices.** "Create a web UI" is vague. "Create a web UI using Go template/html and HTMX with task list, CRUD, and tag management" gives the planner better input.
- **Commit before starting.** Auto creates git checkpoints, but a clean starting point means you can always `git reset --hard` to undo everything.
- **Check your test command.** Verification gates depend on the detected test command. Run `:checkhealth dwight` to verify. Override with `languages` in setup if needed.
- **Review with replay.** After a session, `:DwightReplay latest` steps through every tool call and shows what the agent did.
- **Use `:DwightSquash` after.** Checkpoint commits are useful during execution but noisy in git history. Squash them before merging.

---

## Commands

| Command | Args | Description |
|---------|------|-------------|
| `:DwightAuto` | `[task]` | Plan and execute a multi-step task. Accepts visual range |
| `:DwightAutoStatus` | | Show session progress |
| `:DwightAutoCancel` | | Cancel the running session |
| `:DwightAutoRetry` | | Retry the last failed sub-task |
| `:DwightAutoResume` | `[override prompt]` | Resume from next pending sub-task |
| `:DwightAutoReview` | | Review the plan before continuing |
| `:DwightAutoSkip` | | Skip the current sub-task |
| `:DwightPause` | | Pause after current sub-task |
| `:DwightContinue` | `[override prompt]` | Resume a paused session |

---

## See Also

- [[Agent Mode]] -- for single-task execution without decomposition
- [[Git Operations]] -- `:DwightSquash` collapses checkpoint commits
- [[TDD]] -- uses a similar test-verify loop for individual test cases
- [[Session Replay]] -- step through Auto sessions event by event
