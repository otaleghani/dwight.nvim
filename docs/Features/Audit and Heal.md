---
title: Codebase Audit & Heal
description: Static analysis and AI-powered review to find quality issues, then automated rehabilitation to fix them.
---
# Codebase Audit & Heal

Audit finds quality issues in your code. Heal fixes them. Together they form a rehabilitation loop that systematically improves your codebase feature by feature.

---

## Audit

```vim
:DwightAudit                   " Audit with feature picker
:DwightAudit auth              " Audit a specific feature
:DwightAudit auth --deep       " Static analysis + AI review
```

### Static Analysis
The default audit runs static analysis on every file in the feature. It checks for:

- **Code complexity** — functions that are too long, deeply nested, or have too many parameters
- **Error handling** — unchecked errors, empty catch blocks, swallowed exceptions
- **Naming conventions** — inconsistent patterns, unclear names
- **Dead code** — unused imports, unreachable branches
- **Security patterns** — hardcoded secrets, SQL injection risks, missing input validation
- **Test coverage gaps** — source files without corresponding test files

Results are displayed in a buffer with severity levels and file locations. Each finding links to the exact line.

### Deep Review (--deep / --agentic)
Adding `--deep` or `--agentic` runs the static analysis first, then sends the results along with the actual source code to an AI for deeper review. The AI identifies:

- Architectural issues that static analysis misses
- Logic errors and edge cases
- Opportunities for refactoring
- Missing abstractions or violated design patterns

### Audit Reports
Audit results are saved to `.dwight/audits/` so you can track improvement over time. Each report includes a timestamp, findings count by severity, and the full finding list.

```vim
:DwightAudit auth    " Run audit, results saved automatically
```

---

## Heal

```vim
:DwightHeal                    " Heal with feature picker
:DwightHeal auth               " Heal a specific feature
```

Heal is a three-step rehabilitation process:

### Step 1: Characterization Tests
Before changing anything, Heal generates tests that capture the current behavior of the feature. These "characterization tests" ensure that fixes don't break existing functionality.

### Step 2: Improvement Plan
Based on the audit findings (or a fresh analysis if no audit exists), Heal generates a prioritized plan of improvements. The plan is shown in a buffer for your review before execution.

### Step 3: Execution
The plan is executed through an agentic loop. Each improvement is applied, tests are run, and changes are checkpointed with git. If a change breaks tests, it's rolled back.

---

## Workflow

The typical workflow is:

1. **Audit** a feature to understand its health: `:DwightAudit auth --deep`
2. **Review** the findings in the report buffer
3. **Heal** the feature to fix issues: `:DwightHeal auth`
4. **Review** the characterization tests and improvement plan
5. **Verify** the changes with `:DwightDiffReview`

You can also run audit across all features to find which ones need the most attention, then heal them one at a time.

---

## Commands

| Command | Args | Description |
|---------|------|-------------|
| `:DwightAudit` | `[feature] [--deep]` | Run codebase audit. `--deep` adds AI review |
| `:DwightHeal` | `[feature]` | Rehabilitate a feature: char tests → plan → execute |
