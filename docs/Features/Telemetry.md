---
title: Telemetry & Stats
description: Track usage, costs, success rates, and per-feature statistics with a visual dashboard and export.
---
# Telemetry & Stats

Dwight tracks every AI invocation locally — no data leaves your machine. Use the dashboard to understand costs, success rates, and which features consume the most tokens.

---

## Quick Usage

```vim
:DwightUsage
```

Shows a compact floating window with lifetime and session stats: invocation count, tokens sent/received, estimated cost, and per-model breakdown.

---

## Full Dashboard

```vim
:DwightStats
```

Opens a full-width telemetry dashboard in a split buffer with:

### Overview Cards
Four at-a-glance metrics: total invocations, total cost, success rate, and total tokens.

### Session Summary
Current session duration, call count, cost, and token usage.

### Daily Trend
A 14-day sparkline chart showing daily cost, invocations, successes, and failures. Useful for spotting usage patterns or cost spikes.

### Per-Feature Breakdown
Which features consume the most tokens and cost. Sorted by cost descending.

```vim
:DwightStats features     " Feature-only view
```

### Per-Model Breakdown
Token usage and cost split by AI model (sonnet, opus, haiku, etc.).

### Mode Distribution
How invocations are distributed across operation modes (refactor, explain, agent, auto, etc.).

### Job Log Summary
Recent job success/failure counts from the session log.

---

## Export

Export telemetry data for external analysis:

```vim
:DwightStats export        " Export as JSON (default)
:DwightStats csv           " Export as CSV
:DwightStats json          " Export as JSON
```

Exports are saved to `.dwight/stats-export.{json|csv}` and include lifetime data, daily breakdown, per-feature stats, and per-model stats.

---

## Data Storage

All telemetry is stored in `.dwight/usage.json`. This file is local to your project and included in `.dwight/.gitignore` by default.

Data tracked per invocation:
- Timestamp and duration
- Model used
- Tokens sent and received
- Estimated cost (based on published model pricing)
- Success/failure status
- Feature name (if scoped)
- Operation mode

Session data resets when Neovim restarts. Lifetime data persists across sessions.

---

## Lessons

Related to telemetry, lessons track what Dwight learns from agent sessions:

```vim
:DwightLessons                 " View all lessons
:DwightLessons consolidate     " Merge similar/stale lessons
```

Lessons older than 30 days are flagged as stale in `:checkhealth dwight`. Consolidation merges overlapping lessons and removes outdated ones.

---

## Commands

| Command | Args | Description |
|---------|------|-------------|
| `:DwightUsage` | | Quick usage summary (floating window) |
| `:DwightStats` | `[features\|export\|csv\|json]` | Full telemetry dashboard |
| `:DwightLessons` | `[consolidate]` | View or manage learned lessons |
