---
title: Bootstrap and Coverage
description: Auto-add feature pragmas to your codebase with quick, agentic, or incremental modes and track pragma coverage.
---

# Bootstrap and Coverage

Bootstrap scans your project and adds `@feature:` pragma comments to every source file. Coverage shows how many files are tagged vs untagged. Together they set up the feature-scoped context that makes Dwight's agents effective.

---

## How It Works

1. **Run bootstrap** — `:DwightBootstrap` analyzes your project structure and adds pragmas.
2. **Check coverage** — `:DwightCoverage` shows tagged vs untagged file counts.
3. **Iterate** — re-run with `--incremental` to tag only new files without touching existing pragmas.

```vim
:DwightBootstrap              " Default mode (prompts for quick/agentic)
:DwightBootstrap --quick      " Directory-based grouping, fast
:DwightBootstrap --agentic    " AI reads code for semantic grouping
:DwightBootstrap --force      " Re-tag all files, overwriting existing pragmas
:DwightBootstrap --incremental " Only tag files that don't have a pragma yet
```

---

## Modes

### Quick Mode

Groups files by directory structure. Fast (no LLM calls) but shallow — files in `auth/` get `@feature:auth`, files in `handlers/` get `@feature:handlers`.

Good for: getting started quickly, simple projects with clear directory layouts.

### Agentic Mode

The AI reads your source code, understands the architecture, and assigns pragmas based on semantic relationships — not just directory names. Files that work together get grouped into the same feature even if they live in different directories.

Good for: projects with complex structure, monoliths, codebases where directory names don't reflect domain concepts.

### Incremental Mode

Only processes files that don't already have a `@feature:` pragma. Existing pragmas are preserved. Combine with `--agentic` for best results on partially bootstrapped projects:

```vim
:DwightBootstrap --agentic --incremental
```

### Force Mode

Re-processes all files, overwriting existing pragmas. Use this to reset after manual pragma edits or to switch from quick to agentic grouping:

```vim
:DwightBootstrap --agentic --force
```

---

## Coverage

```vim
:DwightCoverage
```

Displays a report showing:
- Total source files in the project
- Files with `@feature:` pragmas (tagged)
- Files without pragmas (untagged)
- Coverage percentage
- List of untagged files

Aim for 90%+ coverage. Untagged files don't appear in feature context, so agents may miss them.

---

## Tips

- **Start with `--agentic` mode.** It takes longer but produces much better groupings than quick mode. The time investment pays off in every future agent session.
- **Run `--incremental` after adding new files.** New source files won't have pragmas. A quick incremental pass tags them without disturbing existing pragmas.
- **Check coverage after bootstrap.** Some files (configs, generated code, vendored deps) may be intentionally untagged. But source files should always have pragmas.
- **Use `:DwightFeatures` to verify.** After bootstrap, browse the feature list to confirm groupings make sense. Rename pragmas manually if needed.

---

## Commands

| Command | Args | Description |
|---------|------|-------------|
| `:DwightBootstrap` | `[--quick\|--agentic] [--force\|--incremental]` | Add feature pragmas to source files |
| `:DwightCoverage` | | Show pragma coverage stats |
| `:DwightInit` | | Initialize `.dwight/` directory (prerequisite) |

---

## See Also

- [[Core Concepts]] -- explains pragmas, features, and how context scoping works
- [[Feature Management]] -- for browsing, previewing, and splitting features after bootstrap
- [[Auto Mode]] -- uses feature context set up by bootstrap
