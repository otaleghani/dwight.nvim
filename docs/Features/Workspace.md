---
title: Workspace
description: Manage multiple repositories as a unified workspace with cross-repo features and consolidated issue tracking.
---

# Workspace

Dwight can manage multiple repositories as a single workspace. Features span repo boundaries, agents have cross-repo context, and issues are tracked across the entire workspace from one view.

---

## How It Works

1. **Add repos** — `:DwightWorkspaceAdd ../shared-lib` registers repositories.
2. **View status** — `:DwightWorkspace` shows all repos with branch, feature count, and init status.
3. **Browse features** — `:DwightWorkspaceFeatures` lists features across all repos.
4. **Track issues** — `:DwightWorkspaceIssues` shows GitHub issues from all repos in one picker.

---

## Setting Up

### Add Repos Manually

```vim
:DwightWorkspaceAdd ../shared-lib
:DwightWorkspaceAdd ../api-server
:DwightWorkspaceAdd ../frontend
```

Each repo is added by path. Configuration is stored in `.dwight/workspace.json` in your primary project.

### Scan from Monorepo

```vim
:DwightWorkspaceInit
```

Scans sub-directories for git repos or package manifests and adds them automatically.

### Remove Repos

```vim
:DwightWorkspaceRemove
```

Opens a picker to select which repo to remove.

---

## Cross-Repo Features

Features defined with `@feature:` pragmas work across repo boundaries. If `shared-lib` and `api-server` both have files tagged `@feature:auth`, Dwight treats them as one feature.

```vim
:DwightWorkspaceFeatures
```

Shows all features with file counts per repo. When an agent works on a cross-repo feature, it sees files from all contributing repos.

---

## Unified Issue Tracking

```vim
:DwightWorkspaceIssues                       " All open issues
:DwightWorkspaceIssues --label bug           " Filter by label
:DwightWorkspaceIssues --assignee @me        " Filter by assignee
:DwightWorkspaceIssues --milestone v2.0      " Filter by milestone
```

Issues are fetched from all repos in parallel and displayed in a Telescope picker with repo name, issue number, title, and labels. Selecting an issue opens it with `:DwightIssue`.

Requires GitHub CLI (`gh`) authenticated for each repo.

---

## Tips

- **Initialize each repo with Dwight.** Run `:DwightInit` in each repo before adding to the workspace. Cross-repo features require pragmas in all repos.
- **Use workspace for microservices.** If your services share domain concepts, workspace features give agents the full picture across service boundaries.
- **Filter issues by milestone.** `--milestone` is the fastest way to focus on what matters for the current sprint across all repos.

---

## Commands

| Command | Args | Description |
|---------|------|-------------|
| `:DwightWorkspace` | | Show workspace status |
| `:DwightWorkspaceAdd` | `[path]` | Add a repo by path |
| `:DwightWorkspaceRemove` | `[name]` | Remove a repo |
| `:DwightWorkspaceInit` | | Auto-scan monorepo sub-directories |
| `:DwightWorkspaceFeatures` | | List features across all repos |
| `:DwightWorkspaceIssues` | `[--label\|--assignee\|--milestone]` | Unified issue view |

---

## See Also

- [[GitHub Integration]] -- single-repo issue and PR management
- [[Feature Management]] -- browse and preview features within one repo
- [[Core Concepts]] -- how pragmas and features work
