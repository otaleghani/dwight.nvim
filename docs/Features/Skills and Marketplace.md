---
title: Skills and Marketplace
description: Coding skills guide AI behavior with project-specific patterns and conventions. The marketplace provides curated packs.
---

# Skills and Marketplace

Skills are markdown files that tell the AI *how* to write code for your project. They encode patterns, conventions, and anti-patterns. The marketplace provides curated skill packs matched to your project type.

---

## How It Works

1. **Create skills** — write them manually, generate with AI, or install from the marketplace.
2. **Reference in prompts** — use `@skill-name` in any prompt buffer to inject the skill's content.
3. **Automatic inclusion** — agents automatically include relevant skills based on the task and project context.

Skills live in `.dwight/skills/` as markdown files.

---

## Creating Skills

### AI-Generated

```vim
:DwightGenSkill
```

Enter a name (e.g., `react-hooks`), a description of what it should cover, and optionally specific rules. Dwight generates a complete skill file.

### From Documentation

```vim
:DwightDocsFromURL
```

Provide a URL to a library's documentation. Dwight fetches the page, extracts the content, and generates a practical coding guide focused on patterns and conventions.

### Manual

Create any `.md` file in `.dwight/skills/`:

```markdown
# Skill Name

## Overview
Brief description (2-3 sentences).

## Guidelines
1. Specific, actionable rules.

## Patterns
```language
// Good patterns with examples
```

## Anti-Patterns
- What to avoid and why.
```

---

## Browsing Skills

```vim
:DwightSkills              " Telescope picker with preview
:DwightInstallSkills       " Install built-in skills
```

Built-in skills (copied on `:DwightInit`): `clean-code`, `error-handling`, `performance`, `security`, `testing`.

---

## Marketplace

The marketplace detects your project type and recommends skill packs.

```vim
:DwightMarketplace             " Full marketplace browser
:DwightMarketplace suggest     " Auto-suggest based on project type
:DwightMarketplace install     " Pick a pack to install
:DwightMarketplace detect      " Show detected project types
```

### Available Packs

| Pack | Detected From | Skills |
|------|--------------|--------|
| **Go API Server** | `go.mod` | `@go-api-design`, `@go-concurrency` |
| **React Application** | `package.json` with react | `@react-components`, `@react-hooks` |
| **Python ML** | torch/tensorflow in requirements | `@ml-pipeline` |
| **Rust Application** | `Cargo.toml` | `@rust-patterns` |
| **TypeScript Backend** | `tsconfig.json` | `@ts-api-patterns` |
| **Docker & DevOps** | `Dockerfile` | `@docker-patterns` |
| **Neovim Plugin** | `lua/` directory | `@neovim-lua` |

Detection scans 30+ manifest files. For Node projects, reads `package.json` for frameworks. For Python, checks `pyproject.toml` and `requirements.txt`.

---

## Sharing Skills

```vim
:DwightMarketplace export     " Bundle .dwight/skills/ → skills-bundle.json
:DwightMarketplace import     " Import from a bundle file
```

Export creates a versioned JSON bundle (`dwight-skills-v1`). Import adds new skills without overwriting existing ones. Share bundles via git, gist, or any file transfer.

---

## Tips

- **Install marketplace packs on init.** When `:DwightInit` runs, the marketplace auto-suggests packs for your project type. Accept the recommendations to start with good defaults.
- **Write project-specific skills.** Generic skills are useful, but the biggest wins come from encoding *your* project's conventions — API patterns, error handling style, test structure.
- **Reference skills explicitly.** While agents auto-include skills, adding `@skill-name` in the prompt buffer ensures a specific skill is always in context.
- **Keep skills under 200 lines.** Long skills dilute the signal. Split into focused topics (e.g., `go-api-design` and `go-concurrency` instead of one `go-everything`).

---

## Commands

| Command | Args | Description |
|---------|------|-------------|
| `:DwightSkills` | | Browse project skills (Telescope) |
| `:DwightGenSkill` | | AI-generate a new skill |
| `:DwightInstallSkills` | | Install built-in skills |
| `:DwightDocsFromURL` | | Generate a skill from a documentation URL |
| `:DwightMarketplace` | `[install\|suggest\|export\|import\|detect]` | Browse and manage skill packs |

---

## See Also

- [[Library References]] -- API signatures for specific libraries (complementary to skills)
- [[Core Concepts]] -- how skills fit into the context system
- [[Templates]] -- reusable prompt snippets (complementary to skills)
- [[Inline Editing]] -- where `@skill-name` tokens are used in prompts
