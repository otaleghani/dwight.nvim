---
title: Inline Editing
description: Select code, pick a mode, and apply AI-powered edits directly in your buffer with diff preview and multi-file output.
---

# Inline Editing

Inline Editing is Dwight's core interaction model. Select code (or let treesitter pick the scope), choose a mode like `/refactor` or `/test`, and the AI edits your buffer in place. No context switching, no copy-pasting.

---

## How It Works

1. **Select code** — visual selection, or just place your cursor inside a function (treesitter auto-selects the enclosing scope).
2. **Invoke** — `:DwightInvoke` opens a prompt buffer. Type your instruction and reference skills with `@skill-name`, libraries with `%lib-name`, or features with `$feature-name`.
3. **AI generates** — Dwight sends the selection, LSP context (types, diagnostics, references), and your instruction to the AI.
4. **Review** — if `diff_preview = true`, a side-by-side diff opens before applying. Otherwise changes are applied directly.
5. **Undo** — standard `u` for single-file changes, `:DwightMultiUndo` for multi-file edits.

```vim
" Visual select a function, then invoke
:'<,'>DwightInvoke

" Or use a mode directly
:'<,'>DwightMode refactor
```

![Invoke prompt flow](../assets/invoke-prompt.gif)

---

## Modes

Modes are pre-built instructions for common tasks. Each mode constrains the AI's scope so it stays focused.

### Code Modes

| Mode | Description |
|------|-------------|
| `document` | Add idiomatic doc comments (JSDoc, docstrings, godoc, EmmyLua) |
| `refactor` | Improve structure and readability, preserve behavior |
| `optimize` | Performance optimization, prefer algorithmic improvements |
| `fix` | Fix bugs and broken logic |
| `security` | Audit and harden: input validation, injection prevention, secrets |
| `test` | Generate tests using the project's framework |
| `stub` | Generate function signatures and type stubs (multi-file) |
| `code` | Implement stubs, TODOs, and incomplete code (multi-file) |
| `lint` | AI-powered linting with severity and line numbers |
| `macro` | Generate Neovim commands and macros |
| `explain` | Add explanatory comments without modifying code |

### Prose Modes

| Mode | Description |
|------|-------------|
| `brainstorm` | Generate ideas and approaches from selected text |
| `plan` | Create a structured implementation plan with `@dwight:action` steps |
| `refine` | Improve clarity, fix grammar, make text more actionable |
| `docs` | Generate user-facing or developer documentation |

### Custom Modes

You can register project-specific modes in `setup()`. See [[Configuration]] for details.

---

## Multi-File Output

Modes marked as multi-file (`stub`, `code`) can create, edit, or delete multiple files in one operation. The AI outputs changes in a structured XML format:

```xml
<changes>
<file path="src/auth.ts" action="create">
...file content...
</file>
<file path="src/handler.ts" action="edit" lines="15-30">
...replacement...
</file>
</changes>
```

Use `:DwightMultiUndo` to revert all files from a multi-file operation at once.

---

## Dot-Repeat

After any inline operation, `:DwightRepeat` replays the same mode and instruction on a new selection. Select different code, run `:DwightRepeat`, and the last operation is applied to the new scope.

```vim
:'<,'>DwightMode refactor    " Refactor first function
" Select another function
:'<,'>DwightRepeat            " Same refactor on the new selection
```

---

## Prompt Buffer Syntax

The prompt buffer opened by `:DwightInvoke` supports special tokens:

| Token | Example | Resolves To |
|-------|---------|-------------|
| `@name` | `@go-api-design` | Skill from `.dwight/skills/` |
| `%name` | `%htmx` | Library reference from `.dwight/libs/` |
| `$name` | `$auth` | Feature context (files, signatures) |
| `!model` | `!opus` | Override the model for this call |
| `/mode` | `/refactor` | Apply a built-in mode |

---

## Tips

- **Let treesitter pick the scope.** In normal mode, `:DwightInvoke` auto-selects the enclosing function/class. No need to visually select unless you want a specific range.
- **Use `/lint` before `/fix`.** Lint gives you a diagnostic overview; fix acts on it. Running lint first lets you decide which issues are worth fixing.
- **Combine modes with skills.** `/refactor @go-api-design` applies your project's conventions during the refactor instead of generic rules.
- **Enable diff preview for destructive modes.** Set `diff_preview = true` in config, or toggle at runtime with `:DwightDiffToggle`.

---

## Commands

| Command | Args | Description |
|---------|------|-------------|
| `:DwightInvoke` | | Open prompt buffer for current selection or treesitter scope |
| `:DwightMode` | `<mode>` | Apply a mode directly (tab-complete available) |
| `:DwightRepeat` | | Replay last operation on current selection |
| `:DwightMultiUndo` | | Undo last multi-file change set |
| `:DwightCancel` | `[all]` | Cancel nearest active job, or all jobs |
| `:DwightDiffToggle` | | Toggle diff preview before applying |
| `:DwightStreamToggle` | | Toggle streaming output |
| `:DwightLintClear` | | Clear dwight lint diagnostics from buffer |

---

## See Also

- [[Agent Mode]] -- for autonomous multi-tool tasks instead of inline edits
- [[Auto Mode]] -- for multi-step task planning that uses inline modes internally
- [[Providers and Models]] -- to change which model handles inline operations
- [[Skills and Marketplace]] -- to create `@skill` references for the prompt buffer
