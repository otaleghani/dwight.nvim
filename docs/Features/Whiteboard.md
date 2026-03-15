---
title: Whiteboard
description: A persistent scratchpad for brainstorming with AI, with keymaps to fire ideas directly to Agent or Auto mode.
---

# Whiteboard

The Whiteboard is a persistent scratch buffer for thinking with AI. Unlike Agent Mode which executes tasks, the Whiteboard is for exploration — sketching ideas, working through design decisions, and drafting prompts before committing to execution.

---

## How It Works

1. **Open** — `:DwightWhiteboard` opens the scratch buffer (persisted at `.dwight/whiteboard.md`).
2. **Write** — type freely. The buffer has markdown filetype with full syntax highlighting.
3. **Fire** — visually select text and use keymaps to send it to Agent or Auto mode.
4. **Save** — `:DwightWhiteboardSave` archives the content to `.dwight/brainstorm/` for later reference.

```vim
:DwightWhiteboard
```

---

## Keymaps

These keymaps are available only inside the whiteboard buffer:

| Keymap | Action |
|--------|--------|
| `<leader>da` | Fire selection to `:DwightAgent` (execute immediately) |
| `<leader>dp` | Fire selection to `:DwightAgent --plan` (plan first) |
| `<leader>dA` | Fire selection to `:DwightAuto` (decompose into sub-tasks) |

The selection is cleaned before sending — markdown headings and `---` dividers are stripped so only the substance reaches the agent. A notification previews the first 60 characters of the prompt.

A one-time hint shows the keymaps when you first open the whiteboard.

---

## Saving Brainstorms

```vim
:DwightWhiteboardSave                " Save entire buffer
:DwightWhiteboardSave api-design     " Save with a specific name
:'<,'>DwightWhiteboardSave           " Save visual selection only
```

Brainstorms are saved to `~/.dwight/brainstorm/` with a timestamp and optional name. Filenames are auto-generated from the first line of content (e.g., `20250314-1030-api-design.md`).

---

## Browsing Brainstorms

```vim
:DwightBrainstorms
```

Opens a Telescope picker (or fallback list) of all saved brainstorms. Select one to open it in a buffer.

---

## Tips

- **Draft complex prompts on the whiteboard first.** Writing requirements in full prose before firing to Agent produces better results than one-line commands.
- **Use `<leader>dp` for uncertain tasks.** The plan flag lets the agent show its approach before writing code — review and refine on the whiteboard, then fire with `<leader>da`.
- **Save before clearing.** The whiteboard persists across sessions, but saving snapshots to brainstorms creates a timeline of your thinking.

---

## Commands

| Command | Args | Description |
|---------|------|-------------|
| `:DwightWhiteboard` | | Open the brainstorming scratchpad |
| `:DwightWhiteboardSave` | `[name]` | Save whiteboard (supports visual range) |
| `:DwightBrainstorms` | | Browse saved brainstorm sessions |

---

## See Also

- [[Agent Mode]] -- where whiteboard prompts get executed
- [[Auto Mode]] -- for multi-step task execution from whiteboard drafts
- [[Templates]] -- for saving reusable prompts instead of one-off brainstorms
