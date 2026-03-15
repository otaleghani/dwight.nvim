---
title: Session Replay
description: Step through past agent sessions event by event — see every tool call, thought, and result like a debugger.
---

# Session Replay

Replay lets you step through past agent sessions like a debugger — see every tool call, every thought, every result. Useful for understanding what happened, debugging unexpected changes, and learning from agent behavior.

---

## How It Works

1. **Pick a session** — `:DwightReplay` opens a Telescope picker of all past sessions.
2. **Navigate** — step forward and backward through events with `j`/`k`.
3. **Jump** — skip between tool calls with `J`/`K` to focus on actions, not reasoning.
4. **Toggle view** — switch between single-event and cumulative view with `v`.

```vim
:DwightReplay                " Telescope picker of all sessions
:DwightReplay latest         " Jump to the most recent session
:DwightReplay 20250314       " Partial filename match
```

The picker shows each session's timestamp, event count, and task name. The Telescope preview displays the full event timeline.

---

## Navigation

| Key | Action |
|-----|--------|
| `j` / `l` / `Space` | Next step |
| `k` / `h` | Previous step |
| `J` | Jump to next tool call |
| `K` | Jump to previous tool call |
| `gg` | First step |
| `G` | Last step |
| `v` | Toggle single/cumulative view |
| `q` / `Esc` | Close |

---

## Event Types

Each event is rendered with an icon and contextual details:

| Icon | Event | Shows |
|------|-------|-------|
| Launch | Session start | Backend, task prompt |
| Tool | Bash command | `$ command` |
| Read | File read | File path |
| Write | File write | File path |
| Edit | File edit | File path |
| Search | Search | Pattern |
| Result | Tool result | Output text |
| Error | Tool error | Error message |
| Thought | Agent thought | Reasoning text |
| Usage | Token usage | Input/output counts |
| Cost | Final cost | Total tokens + duration |
| Status | Finish | Exit code, duration, output size |

Events show time offsets from session start (`+12s`, `+45s`).

---

## View Modes

**Single view** (default): Shows only the current event with a marker and running stats (tools used, thoughts, errors so far).

**Cumulative view** (toggle with `v`): Shows all events from session start up to the current position. Useful for seeing the full context leading to a tool call.

Both views include a progress bar: `Step 5 / 32 [===========-------]`

---

## Data Source

Replay reads JSONL log files from `.dwight/agentic-logs/`. These are written automatically during every agent session (`:DwightAgent`, `:DwightAuto`, etc.). Each line is a JSON object with a `type` and `timestamp` field.

No configuration needed — if you've run any agent tasks, the logs exist.

---

## Tips

- **Replay after every Auto session.** Even if the result looks correct, stepping through the session reveals the agent's decision-making process and potential issues.
- **Use cumulative view for debugging.** When something went wrong, cumulative view shows the full context up to the failure point.
- **Jump between tool calls with `J`/`K`.** Agent thoughts are informative but verbose — jumping between actions gives you the executive summary.
- **Share replays for team debugging.** The JSONL files in `.dwight/agentic-logs/` are portable. Share a log file and the teammate can replay it locally.

---

## Commands

| Command | Args | Description |
|---------|------|-------------|
| `:DwightReplay` | `[session]` | Step through a session. Args: `latest`, filename, or blank for picker |
| `:DwightSessionLog` | | View the persistent session log |
| `:DwightLog` | | View the job log (all operations) |

---

## See Also

- [[Agent Mode]] -- sessions that Replay visualizes
- [[Auto Mode]] -- multi-step sessions with checkpoint commits
- [[Telemetry and Stats]] -- aggregate metrics across sessions
