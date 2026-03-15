---
title: Codebase Audit and Heal
description: Static analysis and AI-powered review to find quality issues, then automated rehabilitation with char tests and git checkpoints.
---

# Codebase Audit and Heal

Audit finds quality issues in your code. Heal fixes them. Together they form a rehabilitation loop that systematically improves your codebase feature by feature — with characterization tests to prevent regressions.

---

## How It Works

1. **Audit** — run static analysis and optional AI review on a feature.
2. **Review** — examine findings in a buffer with severity levels and file locations.
3. **Heal** — generate characterization tests, create an improvement plan, and execute fixes with verification.

```vim
:DwightAudit auth              " Audit a specific feature
:DwightAudit auth --deep       " Static analysis + AI review
:DwightHeal auth               " Rehabilitate the feature
```

---

## Audit

```vim
:DwightAudit                   " Feature picker
:DwightAudit auth              " Audit a specific feature
:DwightAudit auth --deep       " Add AI review to static analysis
```

### Static Analysis

The default audit checks every file in the feature for:
- **Code complexity** — functions too long, deeply nested, too many parameters
- **Error handling** — unchecked errors, empty catch blocks, swallowed exceptions
- **Naming conventions** — inconsistent patterns, unclear names
- **Dead code** — unused imports, unreachable branches
- **Security patterns** — hardcoded secrets, SQL injection risks, missing input validation
- **Test coverage gaps** — source files without corresponding test files

Results display in a buffer with severity levels and links to exact lines.

### Deep Review (--deep)

Adding `--deep` (or `--agentic`) sends the static analysis results plus actual source code to an AI for deeper review. The AI identifies architectural issues, logic errors, edge cases, and refactoring opportunities that static analysis misses.

### Audit Reports

Results are saved to `.dwight/audits/` with timestamps, finding counts by severity, and the full finding list. Track improvement over time by comparing reports.

---

## Heal

```vim
:DwightHeal                    " Feature picker
:DwightHeal auth               " Heal a specific feature
```

Heal is a three-step rehabilitation process:

### 1. Characterization Tests

Before changing anything, Heal generates tests that capture the current behavior. These "char tests" ensure fixes don't break existing functionality.

### 2. Improvement Plan

Based on audit findings (or a fresh analysis if no audit exists), Heal generates a prioritized plan. The plan appears in a buffer for your review before execution.

### 3. Execution

The plan runs through an agentic loop. Each improvement is applied, tests are run, and changes are checkpointed with git. If a change breaks tests, it's rolled back.

---

## Workflow

The typical workflow is:

1. `:DwightAudit auth --deep` — understand the feature's health
2. Review findings in the report buffer
3. `:DwightHeal auth` — fix issues with char tests as safety net
4. Review the improvement plan before it executes
5. `:DwightDiffReview` — verify the changes

Run audit across all features to find which ones need the most attention, then heal them one at a time.

---

## Tips

- **Start with `--deep` audit.** Static analysis catches surface issues, but AI review finds the architectural problems that matter most.
- **Review the char tests.** Heal generates tests before making changes. If the tests don't cover a critical path, add your own before proceeding.
- **Heal one feature at a time.** Each heal session creates git checkpoints, so you can roll back individual features without affecting others.
- **Re-audit after healing.** Run another audit to confirm that findings were addressed and no new issues were introduced.

---

## Commands

| Command | Args | Description |
|---------|------|-------------|
| `:DwightAudit` | `[feature] [--deep]` | Run codebase audit. `--deep` adds AI review |
| `:DwightHeal` | `[feature]` | Rehabilitate: char tests, plan, execute |

---

## See Also

- [[Feature Management]] -- browse and preview features before auditing
- [[Auto Mode]] -- Heal uses the Auto pipeline for execution
- [[Refactoring]] -- for targeted refactoring with importer analysis
- [[Telemetry and Stats]] -- track improvement trends across audit runs
