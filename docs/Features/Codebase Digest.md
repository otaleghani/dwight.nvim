---
title: Codebase Digest 
description: ""
---

# Codebase Digest

A new module that pre-extracts function signatures, types, and exports from every source file in the project. The digest is injected into agent context automatically, so the LLM already knows the codebase structure without needing to read files via tool calls.

### Usage

```vim
:DwightDigest          " Build or refresh the digest
:DwightDigest --status " Show cache stats
:DwightDigest --clear  " Remove cached digest
:DwightDigest --force  " Full rebuild (ignore cache)
```

### How it works

1. Scans all source files in the project (respects standard skip lists for `node_modules`, `.git`, `build`, etc.)
1. For each file, extracts key signatures using **pure pattern matching** — no LLM call, no network
1. Caches results in `.dwight/digest.json` with per-file `mtime` tracking
1. On subsequent runs, only re-extracts files whose mtime changed (incremental)
1. Automatically injected into `gather_project_context()` in the agent module

### Language support

Go, TypeScript/JavaScript, Lua, Python, Rust, Ruby, Java/Kotlin/C#, C/C++, Swift, and a generic fallback. Each extractor pulls the most useful signatures for that language:

| Language | What's extracted |
|----------|-----------------|
| Go | Package, exported functions, type declarations, interfaces |
| TS/JS | Named exports, interfaces, type aliases |
| Lua | `M.*` module functions, significant local functions |
| Python | Key imports, classes, top-level functions |
| Rust | `pub fn`, `pub struct/enum/trait`, `impl` blocks |
| Ruby | Classes, modules, method definitions |
| Java/Kotlin/C# | Public classes, public methods |
| C/C++ | Typedef structs, non-static function declarations |
| Swift | Functions, classes, structs, protocols |

### Prioritization

Files are ranked for inclusion: `@feature`-tagged files first, then entry points (`main.*`, `index.*`, `cmd/`, etc.), then by file size (larger = likely more important modules).

### Staleness

The digest auto-refreshes when:

- Git HEAD changes (you committed or pulled)
- Cache is older than 1 hour

On first agent run with no digest, it builds silently in the background. The entire scan + extraction takes milliseconds since it's pure pattern matching.

### Prompt format

Injected as a `<codebase_digest>` XML block, capped at 12KB. Each file gets a compact entry:

```
### cmd/server/main.go [go]
package main
func Run(cfg *config.Config) error
func SetupRoutes(r *mux.Router, svc *service.Service)
```

The agent prompt tells the LLM to use the digest for understanding and only read files via tools when it needs full implementation details.

**Files:** `digest.lua` (new), `agent.lua`, `init.lua`
