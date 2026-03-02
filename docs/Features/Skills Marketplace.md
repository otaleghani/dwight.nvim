---
title: Skills & Marketplace
description: Coding skills guide AI behavior. The marketplace provides curated skill packs for popular project types.
---
# Skills & Marketplace

Skills are markdown files that tell the AI *how* to write code. The marketplace provides curated skill packs matched to your project type.

---

## Skills
A skill is a markdown file in `.dwight/skills/` with guidelines, code patterns, and anti-patterns. When an agent runs, relevant skills are included in its context.

### Creating Skills

**AI-generated:**
```vim
:DwightGenSkill
```
Enter a name (e.g., `react-hooks`), a description of what it should cover, and optionally specific rules. Dwight generates a complete skill file.

**From documentation:**
```vim
:DwightDocsFromURL
```
Provide a URL to a library's documentation and Dwight will generate a skill from it.

**Manual:** Create any `.md` file in `.dwight/skills/`. The format is:
```markdown
# Skill Name

## Overview
Brief description (2-3 sentences).

## Guidelines
1. Specific, actionable rules.
2. ...

## Patterns
` ` `language
// Good patterns with examples
` ` `

## Anti-Patterns
- What to avoid and why.
```

### Browsing Skills
```vim
:DwightSkills           " Telescope picker of all skills
:DwightInstallSkills    " Install built-in skills
```

---

## Marketplace
The marketplace detects your project type and recommends skill packs.

```vim
:DwightMarketplace              " Full marketplace browser
:DwightMarketplace suggest      " Auto-suggest based on project type
:DwightMarketplace install      " Pick a pack to install
:DwightMarketplace detect       " Show detected project types
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

### Project Type Detection
Dwight scans for 30+ manifest files and directories. For Node projects, it also reads `package.json` to detect frameworks (React, Vue, Next.js, Express). For Python projects, it checks `pyproject.toml` and `requirements.txt` for ML or web frameworks.

### Auto-Suggest on Init
When you run `:DwightInit`, the marketplace automatically suggests relevant packs based on your project type. You can install all recommended packs or pick individually.

---

## Sharing Skills

**Export** your skills as a shareable JSON bundle:
```vim
:DwightMarketplace export
```
Creates `.dwight/skills-bundle.json` containing all your skills with metadata.

**Import** skills from a bundle:
```vim
:DwightMarketplace import
```
Existing skills are never overwritten — only new skills are added.

Share bundles via git, gist, Slack, or any file transfer. The format is versioned (`dwight-skills-v1`) for forward compatibility.
