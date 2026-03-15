---
title: Refactoring
description: Decompose large refactoring tasks into structured sub-tasks with importer analysis and Auto pipeline execution.
---

# Refactoring

`:DwightRefactor` handles large-scale refactoring that touches a feature and all its dependents. It finds every file that imports the feature, builds a comprehensive context, decomposes the refactoring into sub-tasks, and executes them through the Auto pipeline.

---

## How It Works

1. **Pick a feature** — `:DwightRefactor auth` selects the feature to refactor. Without arguments, a picker opens.
2. **Importer scan** — Dwight scans the entire project for files that import or reference the feature's files.
3. **Context assembly** — builds a context package: full source of feature files + signatures and import lines from dependent files.
4. **Decomposition** — the AI generates up to 8 ordered sub-tasks: structural changes first, then importer updates, then cleanup.
5. **Review** — the plan is shown for your approval before execution.
6. **Execution** — sub-tasks run through the Auto pipeline with verification gates and git checkpoints.

```vim
:DwightRefactor                          " Feature picker
:DwightRefactor auth                     " Refactor the auth feature
:DwightRefactor auth Extract JWT into a separate module
```

---

## Importer Analysis

Before refactoring, Dwight scans project files (`.go`, `.py`, `.js`, `.ts`, `.rs`, `.rb`, `.java`, `.lua`, and more) for import statements that reference the feature's files. This ensures the refactoring plan includes dependent code that needs updating.

The scan uses pattern matching on:
- `import "path"` and `from "path" import` (Python, JS/TS)
- `require("path")` (Lua, Node)
- Package-level imports (Go, Java)
- File basename matching

Importers appear in the context as signatures and usage lines — enough for the AI to understand the dependency without including full file contents.

---

## Sub-Task Ordering

The decomposition follows a strict order:
1. **Structural changes** — rename, extract, or restructure within the feature
2. **Importer updates** — update dependent files to match the new structure
3. **Cleanup** — remove dead code, update documentation, consolidate

Each sub-task is small enough for one agent session and specifies which files to create, edit, or delete.

---

## Tips

- **Include a prompt for better results.** `:DwightRefactor auth Extract the JWT logic into a separate module` gives the AI a clear goal. Without a prompt, it refactors based on code quality heuristics.
- **Review the decomposition carefully.** The plan preview shows every sub-task before execution. Remove or reorder tasks if needed.
- **Commit before refactoring.** The Auto pipeline creates git checkpoints, but a clean starting point means you can always roll back entirely.
- **Use for cross-cutting changes.** Renaming a shared type, changing an API signature, or splitting a module — these are cases where importer analysis matters.

---

## Commands

| Command | Args | Description |
|---------|------|-------------|
| `:DwightRefactor` | `[feature] [prompt]` | Refactor a feature with importer analysis and Auto execution |

---

## See Also

- [[Auto Mode]] -- executes the refactoring sub-tasks with verification gates
- [[Feature Management]] -- browse and preview features before refactoring
- [[Inline Editing]] -- the `/refactor` mode for smaller, scoped refactoring on a selection
