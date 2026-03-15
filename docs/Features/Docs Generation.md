---
title: Docs Generation
description: Generate, update, and SEO-optimize project documentation from source code with framework-aware agents.
---

# Docs Generation

Dwight generates documentation by reading your actual source code — not guessing from file names. Four modes cover the full lifecycle: generate from scratch, generate with deep source reading, update stale pages, and optimize for SEO.

---

## How It Works

1. **Plan** — Dwight builds a documentation plan from your features and pragmas.
2. **Generate** — each page is written by an AI that reads source code and existing docs.
3. **Update** — stale pages are refreshed based on recent git changes.
4. **Optimize** — SEO audit flags issues and agents fix them per-page.

---

## Generate

```vim
:DwightDocs                  " Telescope picker for individual pages
:DwightDocs all              " Generate all pages (single-shot per page)
:DwightDocs auth             " Generate a specific feature page
```

Single-shot generation — fast but shallow. The AI works from feature descriptions and signatures, not full source code.

### Agentic Generate

```vim
:DwightDocs --agentic
```

The recommended mode. Shows an editable plan buffer, then runs a dedicated agent per page that reads source files, existing docs, and writes with verified code examples. Press `e` in the plan buffer to edit — remove lines to skip pages, reorder as needed.

---

## Update Stale Pages

```vim
:DwightDocs --update                 " Update all stale pages
:DwightDocs --update features/auth   " Update a specific page
```

Scans your docs directory, compares last-modified times against recent git commits, and identifies stale pages. Each agent reads the existing page, the source files that changed, and git diffs to update accurately.

---

## SEO Optimization

```vim
:DwightDocs --seo                    " Optimize all pages
:DwightDocs --seo features/auth      " Optimize a specific page
```

### Audit Checks
- Missing or short/long meta descriptions
- Short or truncated titles
- Missing H1 headings
- Low internal link count
- Thin content (under 300 words)

### Thin Content Expansion
Pages flagged as thin get expanded with real examples from your source code — no filler.

### Merge Candidates
Detects overlapping pages (same directory + thin content, overlapping headings) and suggests merges.

---

## Framework Detection

Dwight auto-detects your docs framework and adapts output:
- **Docusaurus** — MDX frontmatter, sidebar position, category metadata
- **MkDocs** — YAML frontmatter, nav snippets for `mkdocs.yml`
- **VitePress** — Vue-compatible markdown, sidebar snippets
- **Plain Markdown** — standard format (default)

---

## Developer Docs

For internal architecture documentation:

```vim
:DwightDevDocs               " Generate internal docs
:DwightDevDocs --agentic     " Agent-powered (recommended)
:DwightDevDocsBrowse         " Browse developer docs
```

Developer docs focus on architecture, data flow, and implementation details — complementary to public docs which focus on user-facing behavior.

---

## Tips

- **Use `--agentic` for initial generation.** It reads real source code, producing accurate examples instead of plausible-sounding fakes.
- **Run `--update` after each sprint.** Keep docs in sync with code changes automatically.
- **Run `--seo` before releases.** Search-optimized docs help users find answers without opening issues.
- **Edit the plan buffer.** Remove pages you don't need, reorder to control generation sequence.

---

## Commands

| Command | Args | Description |
|---------|------|-------------|
| `:DwightDocs` | `[target] [--agentic\|--update\|--seo]` | Generate, update, or optimize docs |
| `:DwightDocsBrowse` | | Browse generated public docs |
| `:DwightDevDocs` | `[target] [--agentic]` | Generate internal developer docs |
| `:DwightDevDocsBrowse` | | Browse developer docs |

---

## See Also

- [[Feature Management]] -- docs are generated per-feature based on pragmas
- [[Skills and Marketplace]] -- skills can guide documentation tone and style
- [[Codebase Digest]] -- the digest helps docs agents understand codebase structure
