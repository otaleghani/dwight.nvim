---
title: GitHub Integration
description: Manage issues, create pull requests, review PRs with AI, and auto-fix CI failures from inside Neovim.
---

# GitHub Integration

Dwight integrates with GitHub through the `gh` CLI. Browse issues, solve them with agents, create pull requests, review PRs with AI analysis, and diagnose CI failures — all without leaving Neovim.

---

## How It Works

1. **Pick an issue** — `:DwightIssue` opens a Telescope picker of open issues. Select one to start working on it.
2. **Solve it** — choose to analyze the issue, send it to `:DwightAgent`, or decompose it with `:DwightAuto`.
3. **Create a PR** — `:DwightPR` generates a pull request from the current branch with an AI-written description.
4. **Fix CI** — if the pipeline fails, `:DwightCI --fix` reads the failure logs and applies a fix.

Requires [GitHub CLI](https://cli.github.com/) (`gh`) installed and authenticated.

---

## Issues

```vim
:DwightIssue                         " Telescope picker of open issues
:DwightIssue 42                      " Fetch issue #42 directly
:DwightIssue 42 --agent              " Send issue #42 to DwightAgent
:DwightIssue 42 --auto               " Decompose issue #42 with DwightAuto
:DwightIssue 42 --analyze            " AI analysis without code changes
:DwightIssue --label bug             " Filter by label
:DwightIssue --assignee @me          " Filter by assignee
:DwightIssue --milestone v2.0        " Filter by milestone
:DwightIssue --repo owner/repo       " Query a different repo
:DwightIssue owner/repo#42           " Cross-repo reference
```

When working on an issue, the issue description and comments are included in the agent's context.

---

## Creating Issues

```vim
:DwightNewIssue                              " Interactive issue creation
:DwightNewIssue Fix login timeout            " With a title
:DwightNewIssue --label bug --milestone v2   " With metadata
:DwightNewIssue --repo owner/repo            " On a different repo
```

Uses your repository's issue templates if available.

---

## Pull Requests

```vim
:DwightPR                    " Create PR for current branch
:DwightPRReview              " Pick a PR to review
:DwightPRReview 42           " Review PR #42
:DwightPRReview --repo org/repo  " Review on a different repo
```

`:DwightPR` generates the PR title and description from the branch's commit history and the original issue (if solving one). The description includes what changed and why.

`:DwightPRReview` runs an AI analysis of the PR diff — it reads every changed file, checks for bugs, style issues, and missing tests, and presents findings in a buffer.

---

## CI/CD

```vim
:DwightCI                    " Show CI status for current branch
:DwightCI --fix              " Auto-fix the first failed run
:DwightCI --fix 12345        " Fix a specific run ID
:DwightCI --rerun            " Re-run all failed jobs
:DwightCI --repo owner/repo  " Check a different repo
```

### Auto-Fix Workflow

1. `:DwightCI --fix` finds the first failed CI run
2. Downloads the failure logs
3. Sends logs + relevant source code to an agent
4. Agent diagnoses the root cause, applies a fix, and verifies locally
5. Changes are committed if the local test passes

---

## Tips

- **Use `--auto` for complex issues.** Simple bugs work well with `--agent`, but multi-file changes benefit from Auto's decomposition and verification gates.
- **Review PRs before merging.** `:DwightPRReview` catches issues that code review often misses — missing error handling, edge cases, and test gaps.
- **Fix CI before pushing again.** `:DwightCI --fix` is faster than reading logs and fixing manually. It often gets the fix right on the first try.
- **Cross-repo references work.** `owner/repo#42` lets you work on issues in any repo without switching directories.

---

## Commands

| Command | Args | Description |
|---------|------|-------------|
| `:DwightIssue` | `[number] [--agent\|--auto\|--analyze] [--label\|--assignee\|--milestone\|--repo]` | Browse and solve GitHub issues |
| `:DwightNewIssue` | `[title] [--label\|--milestone\|--repo]` | Create a new GitHub issue |
| `:DwightPR` | | Create PR for current branch |
| `:DwightPRReview` | `[number] [--repo]` | AI review of a pull request |
| `:DwightCI` | `[--fix [run_id]\|--rerun] [--repo]` | CI status, auto-fix, and re-run |

---

## See Also

- [[Git Operations]] -- for commits, squashing, and diff review
- [[Agent Mode]] -- used by `--agent` flag to solve issues
- [[Auto Mode]] -- used by `--auto` flag to decompose issues into sub-tasks
- [[Workspace]] -- for cross-repo issue tracking with `:DwightWorkspaceIssues`
