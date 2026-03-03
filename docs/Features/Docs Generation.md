---
title: Documentation Generation
description: Generate, update, and optimize project documentation from source code with framework-aware output.
---
# Documentation Generation

Dwight generates documentation by reading your actual source code, not guessing from file names. Four modes cover the full lifecycle: generate from scratch, generate with deep source reading, update stale pages, and optimize for SEO.

---

## Generate Docs

```vim
:DwightDocs                  " Telescope picker to generate individual pages
:DwightDocs all              " Generate all pages (single-shot LLM per page)
:DwightDocs auth             " Generate a specific feature page
```

Builds a plan from your features and pragmas, then generates pages using a single LLM call per page. Fast but shallow — the LLM works from feature descriptions and signatures, not full source code.

Good for: quick first draft, small projects, regenerating a single page.

---

## Agentic Generate

```vim
:DwightDocs --agentic
```

The recommended mode for comprehensive documentation. Shows an editable plan buffer, then runs a dedicated agent per page that reads source files, existing docs, and writes with real code examples.

Each agent:
1. Reads the actual source files for that feature
2. Reads existing docs for style and tone
3. Writes one focused page with verified code examples
4. Uses correct cross-references to other pages

After all pages: generates navigation metadata and verifies all internal links. Results appear in the quickfix list.

Press `e` in the plan buffer to edit — remove lines to skip pages, reorder as needed.

Good for: initial documentation, full rewrites, projects without existing docs.

---

## Update Stale Pages

```vim
:DwightDocs --update                 " Update all stale pages
:DwightDocs --update features/auth   " Update a specific page
```

For projects that already have documentation. Scans your docs directory, compares each page's last-modified time against recent git commits, and identifies which pages are stale.

Shows a plan buffer listing every stale page with:
- How many days since the page was last updated
- How many source files changed since then
- Which files changed

Each agent:
1. Reads the existing documentation page
2. Reads the source files that changed since the last update
3. Reads git diffs to understand what changed
4. Updates the page — adds new content, fixes outdated info, removes stale sections

If all pages are up to date, Dwight tells you and exits.

Good for: keeping docs in sync after a sprint, updating docs before a release.

---

## SEO Optimization

```vim
:DwightDocs --seo                    " Optimize all pages
:DwightDocs --seo features/auth      " Optimize a specific page
```

Runs a full SEO audit on your documentation, then optimizes each page with a focused agent call. Works on any existing docs directory.

### Audit Checks
The audit flags issues per page before you run anything:
- Missing or short/long meta descriptions
- Short or truncated titles
- Missing H1 headings
- Low internal link count
- **Thin content** — pages under 300 words that hurt SEO ranking

### Thin Content Expansion
Pages flagged as thin get special treatment. The agent reads your actual source code to find content worth documenting, then expands the page with real examples, usage workflows, and FAQ-style sections. No filler — every sentence must add value.

### Merge Candidates
The audit detects pages that overlap and could be combined:
- Same directory + both thin content
- Overlapping headings between pages
- Significant title word overlap

When a merge makes sense, the agent reads the candidate page, incorporates its useful content, and deletes the redundant file. The plan buffer shows all merge candidates before you confirm.

### Per-Page Agent
Each agent:
1. Reads the existing page
2. Optimizes title and meta description for search (50-60 char titles, 120-155 char descriptions)
3. Improves headings to match what users actually search for
4. Adds internal links to related pages with descriptive anchor text
5. Tightens content: leads with WHAT, not HOW or WHY
6. Expands thin pages by reading source code
7. Merges overlapping pages where appropriate

Good for: open-source projects, product docs, any docs that users find via search.

---

## Framework Detection

Dwight auto-detects your docs framework and adapts output:
- **Docusaurus** — MDX frontmatter, sidebar position, category metadata
- **MkDocs** — YAML frontmatter, nav snippets for `mkdocs.yml`
- **VitePress** — Vue-compatible markdown, sidebar snippets
- **Plain Markdown** — standard format (default)

Override detection in your Dwight manifest if needed.

---

## Developer Docs

For internal architecture documentation:

```vim
:DwightDevDocs               " Generate internal docs
:DwightDevDocs --agentic     " Agent-powered (recommended)
:DwightDevDocsBrowse         " Browse developer docs
```

Developer docs focus on architecture, data flow, and implementation details — the opposite of public docs which focus on what the software does from the user's perspective.

---

## Commands

| Command | Description |
|---------|-------------|
| `:DwightDocs` | Telescope picker for individual pages |
| `:DwightDocs all` | Generate all pages (quick, single-shot) |
| `:DwightDocs --agentic` | Full agentic generation with plan review |
| `:DwightDocs --update` | Update all stale pages based on recent changes |
| `:DwightDocs --update {page}` | Update a specific stale page |
| `:DwightDocs --seo` | SEO audit + optimize all pages |
| `:DwightDocs --seo {page}` | SEO optimize a specific page |
| `:DwightDocs {page}` | Generate a specific page |
| `:DwightDocsBrowse` | Browse generated docs |
| `:DwightDevDocs` | Generate internal developer docs |
| `:DwightDevDocsBrowse` | Browse developer docs |
