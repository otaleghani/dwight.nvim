---
title: Codebase Digest
description: Pre-extract function signatures and types from every source file so agents understand your codebase without reading files.
---

# Codebase Digest

The Codebase Digest pre-extracts function signatures, types, and exports from every source file in your project. The digest is injected into agent context automatically, so the AI already knows the codebase structure without reading files via tool calls — saving tokens and reducing latency.

---

## How It Works

1. **Scan** — Dwight walks all source files (skipping `node_modules`, `.git`, `build`, etc.).
2. **Extract** — for each file, extracts key signatures using pure pattern matching — no LLM call, no network.
3. **Cache** — results are cached in `.dwight/digest.json` with per-file `mtime` tracking.
4. **Inject** — the digest is automatically included in agent context as a `<codebase_digest>` XML block, capped at 12KB.

```vim
:DwightDigest              " Build or refresh the digest
:DwightDigest --status     " Show cache stats
:DwightDigest --clear      " Remove cached digest
:DwightDigest --force      " Full rebuild (ignore cache)
```

---

## Language Support

Each language has a specialized extractor that pulls the most useful signatures:

| Language | What's Extracted |
|----------|-----------------|
| Go | Package, exported functions, type declarations, interfaces |
| TypeScript/JavaScript | Named exports, interfaces, type aliases |
| Lua | `M.*` module functions, significant local functions |
| Python | Key imports, classes, top-level functions |
| Rust | `pub fn`, `pub struct/enum/trait`, `impl` blocks |
| Ruby | Classes, modules, method definitions |
| Java/Kotlin/C# | Public classes, public methods |
| C/C++ | Typedef structs, non-static function declarations |
| Swift | Functions, classes, structs, protocols |

A generic fallback handles unlisted languages by extracting function-like patterns.

---

## Prioritization

Files are ranked for inclusion in the digest:
1. `@feature:`-tagged files first
2. Entry points (`main.*`, `index.*`, `cmd/`) next
3. Remaining files by size (larger files = likely more important modules)

The 12KB cap ensures the digest fits within agent context budgets.

---

## Staleness and Auto-Refresh

The digest auto-refreshes when:
- Git HEAD changes (you committed or pulled)
- Cache is older than 1 hour

On first agent run with no digest, it builds silently in the background. The entire scan takes milliseconds since it's pure pattern matching with no network calls.

---

## Prompt Format

Injected as a compact entry per file:

```
### cmd/server/main.go [go]
package main
func Run(cfg *config.Config) error
func SetupRoutes(r *mux.Router, svc *service.Service)
```

The agent prompt instructs the LLM to use the digest for understanding the codebase structure and only read files via tools when it needs full implementation details.

---

## Tips

- **Build the digest before large tasks.** Run `:DwightDigest` before `:DwightAuto` to ensure the agent has a complete picture of your codebase from the start.
- **Use `--force` after major refactoring.** Renaming files or moving modules may confuse the cache — a full rebuild ensures accuracy.
- **Check `--status` to monitor size.** If the digest is hitting the 12KB cap, it means some files are excluded. Consider splitting large features to keep the most important signatures visible.

---

## Commands

| Command | Args | Description |
|---------|------|-------------|
| `:DwightDigest` | `[--status\|--clear\|--force]` | Build, inspect, clear, or force-rebuild the codebase digest |

---

## See Also

- [[Feature Management]] -- `:DwightMinimap` provides a similar signature view for individual files
- [[Core Concepts]] -- how the digest fits into the overall context system
- [[Auto Mode]] -- agents use the digest automatically during execution
