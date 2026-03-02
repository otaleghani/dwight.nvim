---
title: Documentation Generation
description: Auto-generate project documentation from source code with framework-aware output.
---
# Documentation Generation

Dwight generates documentation by reading your actual source code, not guessing from file names.

---

## Public Docs
Generate user-facing documentation:

```vim
:DwightDocs                  " Generate all doc pages (single-shot, per page)
:DwightDocs --agentic        " Agent reads source, builds all pages, verifies links
:DwightDocs getting-started  " Generate a specific page
:DwightDocsBrowse            " Browse generated docs
```

### How It Works
Dwight builds a plan from your features and pragmas, then generates pages for:
- **Index** — project overview and navigation
- **Getting Started** — installation and first use
- **Feature pages** — one per `@feature:`, based on actual source code
- **Reference** — API surface from treesitter signatures

The agentic mode (`--agentic`) is recommended for accuracy — the agent reads every source file in each feature, extracts real function signatures, and cross-references pages with correct relative links.

### Framework Detection
Dwight auto-detects your docs framework and adapts output format:
- **Docusaurus** — MDX frontmatter, sidebar config
- **MkDocs** — YAML frontmatter, nav structure
- **VitePress** — Vue-compatible markdown
- **Plain Markdown** — standard format (default)

### Existing Docs
Both modes read existing documentation to match style, tone, and formatting conventions. Pages are updated, not blindly overwritten.

---

## Developer Docs
Generate internal developer documentation:

```vim
:DwightDevDocs               " Generate internal docs
:DwightDevDocs --agentic     " Agent-powered (recommended)
:DwightDevDocsBrowse         " Browse developer docs
```

Developer docs focus on architecture, data flow, and implementation details rather than user-facing guides.
