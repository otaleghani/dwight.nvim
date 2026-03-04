---
title: Multi-Repo Workspace
description: Work across multiple repositories as a unified workspace with cross-repo features and unified issue tracking.
---

# Multi-Repo Workspace

Dwight can manage multiple repositories as a single workspace. Features can span repos, agents have cross-repo context, and issues are tracked across the entire workspace.

---

## Setting Up a Workspace

### Add Repos Manually
```vim
:DwightWorkspaceAdd ../shared-lib
:DwightWorkspaceAdd ../api-server
:DwightWorkspaceAdd ../frontend
```

Each repo is added by path. Dwight stores the workspace configuration in `.dwight/workspace.json` in your primary project.

### Scan from Monorepo
If your project is a monorepo with sub-directories that are independent packages:
```vim
:DwightWorkspaceInit
```

This scans sub-directories for git repos or package manifests and adds them automatically.

### Remove Repos
```vim
:DwightWorkspaceRemove
```

Opens a picker to select which repo to remove from the workspace.

---

## Cross-Repo Features

Features defined with `@feature:` pragmas work across repo boundaries. If `shared-lib` and `api-server` both have files tagged `@feature:auth`, Dwight treats them as one feature.

```vim
:DwightWorkspaceFeatures
```

Shows all features across the workspace with file counts per repo. This is useful for understanding how domain concepts are distributed across your codebase.

When an agent works on a cross-repo feature, it sees files from all repos that contribute to that feature.

---

## Unified Issue Tracking

View GitHub issues across all workspace repos in a single view:

```vim
:DwightWorkspaceIssues
:DwightWorkspaceIssues --label bug
:DwightWorkspaceIssues --assignee @me
:DwightWorkspaceIssues --milestone v2.0
```

Issues are fetched from all repos in parallel and displayed in a Telescope picker (or fallback list) with the repo name, issue number, title, and labels. Selecting an issue opens it for work with `:DwightIssue`.

Requires GitHub CLI (`gh`) to be installed and authenticated for each repo.

---

## Workspace Status

```vim
:DwightWorkspace
```

Shows a status overview of the workspace: each repo with its path, branch, feature count, and whether it has been initialized with Dwight.

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
