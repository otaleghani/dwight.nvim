---
title: Core Concepts
description: Understanding pragmas, features, skills, lessons, and the three interaction modes that power Dwight.
---
# Core Concepts

Dwight's architecture is built on four ideas: **pragmas** scope the work, **features** group the code, **skills** guide the AI, and **lessons** teach it from experience. Three **modes** of interaction — inline, agent, and auto — let you choose the right level of autonomy.

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

Pragmas are regular comments — they don't affect your code. The format is:

```
<optional description>. @feature:<name>
```

The description becomes part of the feature's context, helping the AI understand each file's purpose.

### Supported Pragma Types
- `@feature:name` — assigns the file to a feature group
- `@project` — marks project-wide files (main entry points, shared types)
- `@constraint` — marks files containing project constraints or rules

### Adding Pragmas
```vim
:DwightBootstrap              " Auto-add pragmas to all files
:DwightBootstrap --agentic    " AI reads code first (recommended)
```

See [[Bootstrap and Coverage]] for all modes and options.

---

## Features
A feature is a named group of files that work together. When you say `:DwightAgent "fix the auth bug"`, Dwight finds all files tagged `@feature:auth` and gives the agent exactly that context.

Features have:
- **Files** — every file with the matching `@feature:name` pragma
- **Description** — concatenated from pragma descriptions across all files
- **Signatures** — treesitter-extracted function/type/class signatures per file
- **Dependencies** — import statements per file

```vim
:DwightFeatures           " List all features with file counts
:DwightFeaturePreview     " Detailed view: files, signatures, deps
```

When features grow too large, split them with `:DwightSplitFeature`. See [[Feature Management]].

---

## Backends vs Providers

Dwight separates two systems:

- **Backend** — a CLI agent (Claude Code, Codex, Gemini, OpenCode) that runs autonomous tasks. The backend manages its own authentication.
- **Provider** — an API service (Anthropic, OpenAI, Gemini, OpenRouter) for single-shot operations like skill generation and inline modes. Requires an API key.

```vim
:DwightBackend claude_code    " Switch backend
:DwightSwitch opus            " Switch model
:DwightProviders              " Show current status
```

See [[Providers and Models]] for full configuration.

---

## Modes of Interaction

### Inline Editing
Select code and apply a transformation. The AI edits your buffer in place.

```vim
:'<,'>DwightMode refactor    " Improve structure
:'<,'>DwightMode test        " Generate tests
:'<,'>DwightMode fix         " Fix bugs
:DwightInvoke                " Open prompt buffer
```

18+ modes for code and prose. See [[Inline Editing]].

### Agent Mode
Autonomous task execution with full tool use — reads files, writes code, runs commands.

```vim
:DwightAgent Add input validation to user creation
```

See [[Agent Mode]].

### Auto Mode
Multi-step task decomposition with verification gates and git checkpoints.

```vim
:DwightAuto Create a web UI with HTMX
```

See [[Auto Mode]].

---

## Skills
Skills are markdown files in `.dwight/skills/` that tell the AI how to write code for your project. They encode patterns, conventions, and anti-patterns.

```vim
:DwightSkills              " Browse skills
:DwightGenSkill            " AI-generate a skill
:DwightMarketplace         " Install curated packs
```

Reference skills in prompts with `@skill-name`. See [[Skills and Marketplace]].

---

## Lessons
Dwight extracts lessons from every agent session — what worked, what failed, and what to do differently. Lessons are stored in `.dwight/lessons.json` and automatically included in future agent prompts.

```vim
:DwightLessons              " View all lessons
:DwightLessons consolidate  " Merge similar lessons
:DwightLessons stats        " Usage statistics
```

Lessons accumulate over time. If they get stale (30+ days old), `:checkhealth dwight` warns you to consolidate.

---

## Project Structure
After initialization, your project has:

```
your-project/
├── .dwight/
│   ├── project.md           # Project scope (auto-generated or manual)
│   ├── skills/              # Skill files (.md)
│   ├── libs/                # Library references (.xml)
│   ├── templates/           # Prompt templates (.txt)
│   ├── lessons.json         # Learned lessons from sessions
│   ├── usage.json           # Telemetry data
│   ├── session.log          # Persistent session log
│   ├── agentic-logs/        # JSONL logs for session replay
│   ├── digest.json          # Codebase digest cache
│   └── .gitignore           # Keeps .dwight/ out of version control
├── src/
│   ├── auth.go              # // Auth handlers. @feature:auth
│   ├── database.go          # // Database layer. @feature:database
│   └── ...
```

---

## Next Steps
- [[Getting Started]] — install and run your first task
- [[Inline Editing]] — in-buffer AI editing with modes
- [[Auto Mode]] — multi-step task planning
- [[Commands]] — full command reference
