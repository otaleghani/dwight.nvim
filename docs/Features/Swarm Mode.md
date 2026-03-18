---
title: Swarm Mode
description: Parallel multi-agent task execution across isolated git worktrees with wave-based decomposition, automatic merging, and conflict resolution.
---

# Swarm Mode

Swarm Mode decomposes a task into independent subtasks and runs them **in parallel** across isolated git worktrees. Where [[Auto Mode]] executes sub-tasks sequentially, Swarm dispatches entire waves of agents simultaneously — completing large features in a fraction of the time.

---

## How It Works

1. **Describe the task** — pass a natural-language prompt or visually select text.
2. **Decomposition** — the LLM breaks the task into waves of parallel subtasks, each with an explicit file scope.
3. **Preview the plan** — an editable markdown buffer shows all waves and tasks. Approve with `<CR>` or cancel with `q`.
4. **Pre-flight checkpoint** — dirty working-tree state is committed and the base SHA is saved for rollback.
5. **Wave execution** — each wave's tasks run in parallel, one agent per worktree. Waves execute sequentially.
6. **Merge and verify** — completed tasks merge back sequentially (fewest overlaps first), gate checks run, and failures trigger rollback.
7. **Session complete** — summary with per-wave breakdown, cost report, and a session log written to `.dwight/swarm-logs/`.

---

## Decomposition

The LLM splits your request into **waves** of parallel tasks. Tasks within the same wave must not edit the same files — this guarantees conflict-free parallel execution within a wave.

**Limits:**

| | Max |
|---|---|
| Waves | 4 |
| Tasks per wave | 4 |
| Total tasks | 12 |

Foundational work (types, interfaces) is placed in early waves. Implementation goes in middle waves. Wiring and integration come last. Each task includes a `<files>` list so Dwight can validate that no two tasks in the same wave touch the same path.

---

## Preview Buffer

After decomposition, a markdown buffer opens with the full plan:

```
# Wave 1 (3 parallel tasks)

## Task 1: Database schema and migrations
**Files:** db/schema.sql, db/migrate.go

Create the initial schema...

---

## Task 2: Auth middleware
**Files:** middleware/auth.go, middleware/auth_test.go

Implement JWT auth middleware...
```

- **`<CR>`** — approve and start execution
- **`q`** — cancel

You can edit task titles, descriptions, file lists, and wave ordering before approving.

---

## Wave Execution

Each task in a wave runs in its own git worktree on a branch named `dwight-swarm/wave-N-task-M`. Agents execute in parallel, capped by `max_parallel` (default 3). Per-task spinners in the status buffer show live progress.

Waves execute sequentially — wave 2 starts only after wave 1's tasks are merged. Previous wave results are passed as context to the next wave's agents.

```vim
:DwightSwarmStatus    " See current wave, task progress, and errors
```

---

## Merge and Conflict Resolution

After all tasks in a wave complete, Dwight merges them back into the main branch:

1. **Overlap detection** — files touched by multiple tasks are flagged.
2. **Merge ordering** — tasks with the fewest overlaps merge first, minimizing conflicts.
3. **Merge** — each task branch merges with `--no-ff` to preserve history.
4. **Conflict resolution** — if conflicts arise, an LLM-based resolver reads the conflict markers and produces a clean merge (up to 3 retries).
5. **Gate check** — verification gates run after the wave merge. If gates fail, the entire wave is rolled back to the pre-merge SHA.

If auto-resolution fails after retries, the session pauses with a diagnostic showing which tasks modified which files.

---

## Session Control

Swarm sessions are fully controllable while running:

```vim
:DwightSwarmPause     " Pause before the next wave starts
:DwightSwarmResume    " Resume from a paused or failed wave
:DwightSwarmCancel    " Cancel the session and cleanup all worktrees
:DwightSwarmStatus    " Show wave progress, task status, and errors
```

State is persisted to `.dwight/swarm/current.json` after each wave, so you can resume even after restarting Neovim.

---

## Swarm vs Auto

| | Auto | Swarm |
|---|---|---|
| **Execution** | Sequential sub-tasks | Parallel waves of agents |
| **Isolation** | Single branch | One worktree per task |
| **Speed** | One task at a time | Up to `max_parallel` simultaneous agents |
| **Merging** | Direct commits | Branch merge with conflict resolution |
| **File scope** | Unrestricted | Tasks in a wave must not overlap files |
| **Resumable** | Yes | Yes |
| **Best for** | Ordered, dependent steps | Large features with independent parts |

Use `:DwightAuto` when tasks depend on each other. Use `:DwightSwarm` when the work can be parallelized across independent file scopes.

---

## Configuration

```lua
require("dwight").setup({
  swarm_opts = {
    max_parallel = 3,              -- max agents per wave (caps worktree count)
    on_partial_failure = "continue", -- "continue" = merge successes, mark failures for retry
    cleanup_worktrees = true,      -- remove worktrees after each wave merge
  },
})
```

| Option | Default | Description |
|--------|---------|-------------|
| `max_parallel` | `3` | Maximum agents running simultaneously per wave |
| `on_partial_failure` | `"continue"` | Merge successful tasks and mark failures for retry |
| `cleanup_worktrees` | `true` | Remove worktrees after merging each wave |

---

## Tips

- **Keep tasks independent.** Swarm works best when subtasks don't share files. If the LLM puts too many tasks in one wave, edit the preview to split them across waves.
- **Commit before starting.** Swarm saves a pre-flight checkpoint, but a clean working tree makes rollbacks cleaner.
- **Watch `max_parallel`.** Each parallel agent is a full CLI session. On machines with limited CPU/memory, lower this to 2.
- **Review the preview.** The editable plan buffer is your chance to reorder, remove, or refine tasks before any work begins.
- **Use `:DwightSquash` after.** Swarm creates merge commits per task. Squash them into a clean history before pushing.
- **Check session logs.** After completion, `.dwight/swarm-logs/` contains a markdown summary with per-task durations and errors.

---

## Commands

| Command | Args | Description |
|---------|------|-------------|
| `:DwightSwarm` | `[task]` | Decompose and execute in parallel waves. Accepts visual range |
| `:DwightSwarmResume` | | Resume from a failed or paused wave |
| `:DwightSwarmCancel` | | Cancel active session and cleanup worktrees |
| `:DwightSwarmStatus` | | Show wave progress and task status |
| `:DwightSwarmPause` | | Pause after current wave completes |

---

## See Also

- [[Auto Mode]] -- for sequential multi-step execution
- [[Agent Mode]] -- for single-task autonomous execution
- [[Git Operations]] -- `:DwightSquash` collapses checkpoint and merge commits
