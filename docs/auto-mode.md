---
title: Auto Mode
description: Multi-step task planning and autonomous execution with verification gates and git checkpoints.
---
# Auto Mode

Auto Mode is Dwight's most powerful feature. Give it a high-level task description and it will plan, execute, verify, and checkpoint the work autonomously.

---

## How It Works

```vim
:DwightAuto Create a web UI for this app using template/html and HTMX
```

### 1. Planning
Dwight analyzes your project context (features, file structure, existing code) and breaks the task into 4-8 sub-tasks. Each sub-task is scoped, ordered by dependency, and small enough for an agent to complete in one session.

Example plan:
```
📋 8 sub-tasks:
  1. HTTP server foundation and routing
  2. Template infrastructure
  3. Task list view page
  4. Create task with HTMX
  5. Delete and toggle task status
  6. Tag management
  7. Edit task inline
  8. Styling and polish
```

### 2. Baseline Test Snapshot
Before starting, Dwight runs your test suite and records any pre-existing failures. These won't count against verification gates later.

### 3. Sub-Task Execution
Each sub-task runs through an agent session with full tool use (read, write, edit, run commands, search). The agent has access to project context, skills, and lessons from past sessions.

### 4. Verification Gates
After each sub-task, Dwight runs the detected test command (e.g., `go test ./...`, `pytest`, `npm test`). If tests pass, it proceeds. If they fail, the agent gets one retry with the error output as context.

### 5. Git Checkpoints
After each passing verification gate, Dwight creates a git commit:
```
dwight: task 3/8 — Task list view page
```
This means you can always roll back to any intermediate state.

### 6. Learning
After the full session completes, Dwight extracts lessons from what happened — patterns that worked, errors that occurred, and fixes that were applied. These lessons are used in future sessions.

---

## Session Control
While Auto is running, you have full control:

```vim
:DwightPause          " Pause after the current sub-task finishes
:DwightContinue       " Resume a paused session
:DwightAutoCancel     " Cancel the entire session
:DwightAutoSkip       " Skip the current failing sub-task
:DwightAutoRetry      " Retry the last failed sub-task
:DwightAutoResume     " Resume from the next pending sub-task
:DwightAutoReview     " Review the remaining plan
:DwightAutoStatus     " Show session progress
```

---

## Resumable Sessions
If a sub-task fails even after retry, the session pauses. The state is saved to `.dwight/auto/current.json`. When you fix the issue manually, run `:DwightAutoResume` to continue from where it stopped. Previously completed tasks are marked with ✅ and skipped.

---

## Tips

**Be specific about technology choices.** "Create a web UI" is vague. "Create a web UI using Go template/html and HTMX with a task list, create/edit/delete operations, and tag management" gives the planner enough to create good sub-tasks.

**Commit before starting.** Auto creates git checkpoints, but having a clean starting point means you can always `git reset --hard` to undo everything.

**Check your test command.** Verification gates depend on your test command being correct. Run `:checkhealth dwight` to see what command Dwight detected. If it's wrong, configure it via `languages` in setup.

**Review with replay.** After a session, `:DwightReplay latest` lets you step through every tool call and see exactly what the agent did.
