---
title: Feature Management
description: Browse live features from pragma comments, preview AI context, inspect the treesitter minimap, and split large features.
---

# Feature Management

Features are groups of files defined by `@feature:` pragma comments in your source code. This page covers browsing features, previewing what the AI sees, and splitting features that grow too large.

---

## How It Works

1. **Browse** — `:DwightFeatures` lists all detected features with file counts.
2. **Preview** — `:DwightFeaturePreview auth` shows exactly what context an agent receives for that feature: files, signatures, and dependencies.
3. **Split** — when a feature gets too large, `:DwightSplitFeature` breaks it into focused sub-features.

---

## Browsing Features

```vim
:DwightFeatures
```

Opens a Telescope picker (or fallback list) of all features detected from `@feature:` pragmas across the project. Each entry shows the feature name, file count, and concatenated description.

---

## Previewing Context

```vim
:DwightFeaturePreview              " Picker, then preview
:DwightFeaturePreview auth         " Preview a specific feature
:DwightProjectContext              " Preview the full JIT project context
```

The preview shows what an agent would see:
- **Files** — every file tagged with the feature
- **Signatures** — treesitter-extracted functions, types, classes per file
- **Dependencies** — import statements per file
- **Description** — concatenated pragma descriptions

`:DwightProjectContext` shows the broader project-level context that wraps feature context — project scope, skills, lessons, and the codebase digest.

---

## Treesitter Minimap

```vim
:DwightMinimap                     " Current file
:DwightMinimap src/auth/           " Entire directory
```

Opens a split buffer with a compact signature map — every function, type, and class extracted by treesitter. Useful for understanding file structure at a glance without reading implementation details.

---

## Splitting Features

When a feature grows too large (many files, many symbols), agents lose effectiveness because the context is too broad. Dwight detects this and helps you split.

### Audit

```vim
:DwightSplitAudit
```

Checks all features and reports which ones are candidates for splitting based on file count, symbol count, and internal cohesion.

### Preview

```vim
:DwightSplitPreview auth
```

Shows how a feature would be split without applying any changes. Reviews the proposed sub-features and their file assignments.

### Split

```vim
:DwightSplitFeature auth           " Interactive split
:DwightSplitFeature auth --agentic " AI reads code to find natural boundaries
```

The default split groups files by directory and naming patterns. The `--agentic` flag reads the actual source code to find semantic boundaries — functions that work together, shared types, call patterns.

After splitting, pragmas are updated in place: `@feature:auth` becomes `@feature:auth-handlers`, `@feature:auth-store`, `@feature:auth-middleware`, etc.

---

## Tips

- **Preview before sending complex tasks.** `:DwightFeaturePreview $auth` shows you what the agent will see. If critical files are missing, check their pragma tags.
- **Split proactively.** Features with more than 15 files or 100 symbols should be split. The agent works better with focused, cohesive context.
- **Use `--agentic` for splits.** Directory-based splits are fast but miss semantic groupings. The AI finds better boundaries by reading the code.
- **Run `:DwightSplitAudit` monthly.** As your codebase grows, features that were fine last month may need splitting now.

---

## Commands

| Command | Args | Description |
|---------|------|-------------|
| `:DwightFeatures` | | Browse live features from pragmas |
| `:DwightFeaturePreview` | `[feature]` | Preview feature context (files, signatures, deps) |
| `:DwightProjectContext` | | Preview full JIT project context |
| `:DwightMinimap` | `[path]` | Treesitter signature map of file or directory |
| `:DwightSplitFeature` | `[feature] [--agentic]` | Split a large feature into sub-features |
| `:DwightSplitPreview` | `[feature]` | Preview a split without applying |
| `:DwightSplitAudit` | | Check which features need splitting |

---

## See Also

- [[Bootstrap and Coverage]] -- how features get created via pragma comments
- [[Core Concepts]] -- explains pragmas, features, and context scoping
- [[Auto Mode]] -- uses feature context during task execution
- [[Codebase Audit and Heal]] -- audits features for quality issues
