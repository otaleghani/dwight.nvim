---
title: Templates
description: Save and reuse prompt templates for common operations like error handling, async conversion, and dependency injection.
---

# Templates

Templates are reusable prompt snippets for common coding tasks. Dwight ships with seven built-in templates and you can save your own.

---

## How It Works

1. **Pick a template** — `:DwightTemplate` opens a picker showing all available templates with previews.
2. **Use it** — selecting a template copies its prompt to your clipboard, ready to paste into `:DwightAgent`, `:DwightAuto`, or the `:DwightInvoke` prompt buffer.
3. **Save your own** — `:DwightSaveTemplate` saves a prompt you use frequently.

```vim
:DwightTemplate              " Pick from available templates
:DwightSaveTemplate          " Save a new template (prompted for name + text)
```

---

## Built-in Templates

| Template | Prompt |
|----------|--------|
| **Add Error Handling** | Wrap fallible operations in proper error handling |
| **Convert to Async** | Convert callbacks to async/await |
| **Add Types** | Add full type annotations |
| **Extract Function** | Extract logic into a helper function |
| **Add Logging** | Add structured logging at entry/exit/error |
| **Dependency Injection** | Refactor to use DI, extract interfaces |
| **Guard Clauses** | Convert nested conditionals to guard clauses |

---

## Saving Templates

```vim
:DwightSaveTemplate
:DwightSaveTemplate Refactor this to use the repository pattern
```

Without arguments, Dwight prompts for a name and prompt text. With an argument, the argument becomes the prompt text and you're prompted only for the name.

Templates are saved to `.dwight/templates/` as `.txt` files — one prompt per file.

---

## Tips

- **Templates complement skills.** Skills tell the AI *how* to write code (patterns, conventions). Templates tell the AI *what* to do (specific operations). Combine them: pick a template, then add `@skill-name` in the prompt buffer.
- **Save templates for project-specific operations.** If you frequently ask for the same refactoring, save it once and reuse it.
- **Built-in templates work across languages.** They describe the intent, not the syntax — the AI adapts to whatever language you're working in.

---

## Commands

| Command | Args | Description |
|---------|------|-------------|
| `:DwightTemplate` | | Pick a saved template (copies to clipboard) |
| `:DwightSaveTemplate` | `[prompt]` | Save a reusable prompt template |

---

## See Also

- [[Inline Editing]] -- where template prompts are used in the prompt buffer
- [[Skills and Marketplace]] -- for project-wide coding guidelines (complementary to templates)
- [[Whiteboard]] -- for one-off brainstorming instead of reusable templates
