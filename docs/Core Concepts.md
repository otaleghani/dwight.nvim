---
title: Core Concepts
description: Understanding pragmas, features, skills, and the learning system that powers Dwight.
---
# Core Concepts

Dwight's architecture is built on four ideas: **pragmas** scope the work, **features** group the code, **skills** guide the AI, and **lessons** teach it from experience.

---

## Pragmas
A pragma is a comment in your source code that tells Dwight what the file is about:

```go
// User authentication and JWT handling. @feature:auth
package auth
```

```python
# Task CRUD operations and validation. @feature:tasks
class TaskService:
```

```lua
-- Telescope picker integration. @feature:ui @project
local M = {}
```

Pragmas are regular comments — they don't affect your code. Dwight scans for them using pattern matching across all files in the project. The format is:

```
<optional description>. @feature:<name>
```

The description becomes part of the feature's context, helping the AI understand each file's purpose.

### Supported Pragma Types
- `@feature:name` — assigns the file to a feature group
- `@project` — marks files that are project-wide (main entry points, shared types)
- `@constraint` — marks files containing project constraints or rules

### Adding Pragmas
You can add pragmas manually or let Dwight do it:

```vim
:DwightBootstrap              " Auto-add pragmas to all files
:DwightBootstrap --agentic    " AI reads code first (recommended)
```

Bootstrap detects your project type, groups files by directory and import patterns, and adds pragmas with meaningful descriptions. Check coverage with `:DwightCoverage`.

---

## Features
A feature is a named group of files that work together. When you say `:DwightAgent "fix the auth bug"`, Dwight finds all files tagged `@feature:auth` and gives the agent exactly that context.

Features have:
- **Files** — every file with the matching `@feature:name` pragma
- **Description** — concatenated from pragma descriptions across all files
- **Signatures** — treesitter-extracted function/type/class signatures per file
- **Dependencies** — import statements per file

### Viewing Features
```vim
:DwightFeatures           " List all features with file counts
:DwightFeaturePreview     " Detailed view: files, signatures, deps
:DwightMinimap            " Treesitter signature map of current file
```

### Splitting Features
When a feature grows too large (many files, many symbols), the AI loses effectiveness. Dwight detects this and suggests splitting:

```vim
:DwightSplitAudit         " Check which features are too large
:DwightSplitFeature auth  " Propose a split for $auth
:DwightSplitFeature auth --agentic  " AI reads code and applies the split
```

A split reassigns `@feature:auth` pragmas to more specific names like `@feature:auth-handlers`, `@feature:auth-store`, and `@feature:auth-middleware`.

---

## Skills
Skills are markdown files in `.dwight/skills/` that tell the AI how to write code for your project. They encode patterns, conventions, and anti-patterns.

Example skill (`go-api-design.md`):
```markdown
# Go API Design

## Guidelines
1. Use `http.Handler` interface — keep handlers as methods on a server struct.
2. Middleware chain: logging → recovery → auth → rate-limit → handler.
3. Always return structured errors with `{ "error": "message", "code": "NOT_FOUND" }`.

## Patterns
...code examples...

## Anti-Patterns
- Don't use global variables for database connections.
- Don't put business logic in handlers.
```

### Built-in Skills
Dwight ships with five general skills that are copied on `:DwightInit`:
- `clean-code` — readability and maintainability
- `error-handling` — consistent error patterns
- `performance` — avoiding common bottlenecks
- `security` — input validation, secrets, injection prevention
- `testing` — test structure, mocking, coverage

### Creating Skills
```vim
:DwightGenSkill             " AI generates a skill from your description
:DwightDocsFromURL          " Generate a skill from a documentation URL
```

### Marketplace
The marketplace offers curated skill packs matched to your project type:

```vim
:DwightMarketplace          " Browse available packs
:DwightMarketplace suggest  " Auto-detect project type and recommend packs
:DwightMarketplace install  " Install a specific pack
```

Available packs include Go API, React, Python ML, Rust, TypeScript Backend, Docker, and Neovim Plugin. See [[Skills & Marketplace]] for details.

### Sharing Skills
Export your skills as a JSON bundle and share with your team:

```vim
:DwightMarketplace export   " Bundle .dwight/skills/ → skills-bundle.json
:DwightMarketplace import   " Import from a bundle file
```

---

## Lessons
Dwight extracts lessons from every agent session — what worked, what failed, and what to do differently. Lessons are stored in `.dwight/lessons.json` and automatically included in future agent prompts.

```vim
:DwightLessons              " View all lessons
:DwightLessons consolidate  " Merge similar lessons
```

Lessons accumulate over time. If they get stale (30+ days old), `:checkhealth dwight` will warn you to consolidate.

---

## Project Structure
After initialization, your project has:

```
your-project/
├── .dwight/
│   ├── project.md           # Project scope (auto-generated or manual)
│   ├── skills/              # Skill files (.md)
│   │   ├── clean-code.md
│   │   ├── testing.md
│   │   └── ...
│   ├── lessons.json         # Learned lessons from sessions
│   ├── usage.json           # Telemetry data
│   ├── session.log          # Persistent session log
│   ├── agentic-logs/        # JSONL logs for session replay
│   └── .gitignore           # Keeps .dwight/ out of version control
├── src/
│   ├── auth.go              # // Auth handlers. @feature:auth
│   ├── database.go          # // Database layer. @feature:database
│   └── ...
```

---

## Next Steps
- [[Getting Started]] — install and run your first task
- [[Auto Mode]] — multi-step task planning
- [[Commands]] — full command reference
