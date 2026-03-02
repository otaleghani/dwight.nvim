---
title: Session Replay
description: Step through past agent sessions event by event for debugging and learning.
---
# Session Replay

Replay lets you step through past agent sessions like a debugger — see every tool call, every thought, every result.

---

## Usage

```vim
:DwightReplay                    " Telescope picker of all sessions
:DwightReplay latest             " Jump to the most recent session
:DwightReplay 20250301           " Partial filename match
```

The picker shows each session's timestamp, event count, and task name. The Telescope preview pane displays the full event timeline.

---

## Navigation

| Key | Action |
|-----|--------|
| `j` / `→` / `l` / `Space` | Next step |
| `k` / `←` / `h` | Previous step |
| `J` | Jump to next tool call (skip thoughts/usage) |
| `K` | Jump to previous tool call |
| `gg` | First step |
| `G` | Last step |
| `v` | Toggle single/cumulative view |
| `q` / `Esc` | Close |

---

## Event Types
Each event is rendered with an icon and details:

| Icon | Event | Shows |
|------|-------|-------|
| 🚀 | Session start | Backend, task prompt |
| 🔧 | Bash command | `$ command` |
| 📖 | File read | File path |
| 📝 | File write | File path |
| ✏️ | File edit | File path |
| 🔍 | Search | Pattern |
| 📋 | Tool result | Output text |
| 🔴 | Tool error | Error message |
| 💭 | Agent thought | Reasoning text |
| 📊 | Token usage | Input/output counts |
| 💰 | Final cost | Total tokens + duration |
| ✅/❌ | Finish | Exit code, duration, output size |

Events show time offsets from session start (`+12s`, `+45s`).

---

## View Modes

**Single view** (default): Shows only the current event with a `▶` marker and running stats (tools used, thoughts, errors so far).

**Cumulative view** (toggle with `v`): Shows all events from session start up to the current position. Useful for seeing the full context of a tool call.

Both views include a progress bar at the top: `Step 5 / 32 [████████░░░░░░░░░░]`

---

## Data Source
Replay reads JSONL log files from `.dwight/agentic-logs/`. These are written automatically by the agentic module during every agent session. Each line is a JSON object with a `type` and `timestamp` field.

No configuration needed — if you've run any agent tasks, the logs exist.
