---
title: Workflow Recipes
description: End-to-end walkthroughs for common development workflows with Dwight.
---

# Workflow Recipes

Step-by-step guides for common development workflows. Each recipe shows the full sequence of Dwight commands from start to finish.

---

## Build a REST API from scratch

Start with an empty project and use Auto mode to build a complete API.

### 1. Initialize
```vim
:DwightInit                           " Create .dwight/ directory
:DwightBootstrap --agentic            " Analyze codebase and add feature pragmas
```

### 2. Plan and execute
```vim
:DwightAuto Create a REST API for user management with CRUD endpoints, input validation, and error handling
```

Auto mode will:
- Plan 4-8 sub-tasks (models, handlers, routes, validation, tests)
- Execute each sub-task with a full agent session
- Run tests after each step
- Git commit after each passing step

### 3. Monitor progress
```vim
:DwightAutoStatus                     " Check which sub-task is running
:DwightPause                          " Pause after the current sub-task
:DwightAutoReview                     " Review the remaining plan
:DwightContinue                       " Resume execution
```

### 4. Review and ship
```vim
:DwightDiffReview                     " See the full diff
:DwightReplay                         " Step through what the agent did
:DwightSquash                         " Squash checkpoint commits into one
:DwightCommit                         " Generate a clean commit message
```

---

## Fix a GitHub issue

Pull an issue from GitHub, have the agent solve it, and submit a PR.

### 1. Browse and pick an issue
```vim
:DwightIssue                          " Browse open issues (Telescope picker)
:DwightIssue 42                       " Jump to a specific issue number
:DwightIssue --label bug              " Filter by label
```

### 2. Solve with agent
```vim
:DwightIssue 42 --agent               " Solve with a single agent session
:DwightIssue 42 --auto                 " Solve with full Auto mode (for larger issues)
:DwightIssue 42 --analyze              " Just analyze the issue without solving
```

### 3. Review the fix
```vim
:DwightDiffReview                     " Check the changes
:DwightReplay                         " Step through the agent's work
```

### 4. Submit a PR
```vim
:DwightPR                             " Create a PR linking back to the issue
```

---

## Refactor a large module

Use feature splitting and the refactor command to safely decompose a large module.

### 1. Identify what needs splitting
```vim
:DwightSplitAudit                     " Check which features are too large
:DwightFeaturePreview auth            " Preview what the 'auth' feature includes
```

### 2. Split into sub-features
```vim
:DwightSplitFeature auth --agentic    " AI-driven split based on code boundaries
:DwightSplitPreview auth              " Preview the split before applying
```

### 3. Refactor
```vim
:DwightRefactor auth Extract the JWT validation into a separate middleware module
```

The refactor command:
- Analyzes all files that import from the feature
- Plans changes to avoid breaking imports
- Executes with an agent session
- Runs tests to verify nothing broke

### 4. Verify
```vim
:DwightRun                            " Run your test suite
:DwightDiffReview                     " Review all changes
:DwightCoverage                       " Confirm pragmas are still correct
```

---

## Set up CI auto-fix

Use Dwight to automatically fix CI failures.

### 1. Check CI status
```vim
:DwightCI                             " Show CI status for current branch
```

### 2. Auto-fix failures
```vim
:DwightCI --fix                       " Find first failed run and fix it
:DwightCI --fix 12345                  " Fix a specific run by ID
```

The CI fix workflow:
- Downloads the failure log from GitHub Actions
- Sends it to the agent with your project context
- Agent makes the fix and runs tests locally
- You review and push

### 3. Re-run CI
```vim
:DwightCI --rerun                     " Re-trigger failed CI runs
```

### 4. Push the fix
```vim
:DwightCommit                         " Commit the fix
:DwightGit push                       " Push to remote
```

---

## Onboard to a new codebase

Use Dwight to quickly understand and navigate an unfamiliar project.

### 1. Initialize and scan
```vim
:DwightInit                           " Create .dwight/ directory
:DwightBootstrap --agentic            " AI analyzes the codebase and adds feature pragmas
```

The agentic bootstrap reads your source code to understand the architecture, so the feature names it generates are meaningful (e.g., `auth`, `database`, `api-routes` rather than just directory names).

### 2. Explore the architecture
```vim
:DwightFeatures                       " Browse all detected features
:DwightFeaturePreview api-routes      " See files, signatures, and deps for a feature
:DwightMinimap src/                   " Treesitter signature map of a directory
:DwightProjectContext                 " Preview the full project context
```

### 3. Build a digest
```vim
:DwightDigest                         " Pre-extract signatures for faster agent context
```

### 4. Ask questions with the agent
```vim
:DwightAgent Explain how the authentication flow works, from login to token refresh
:DwightAgent What are the main database models and their relationships?
```

### 5. Generate documentation
```vim
:DwightDevDocs architecture           " Generate architecture docs
:DwightDevDocs getting-started        " Generate a getting started guide
:DwightDevDocsBrowse                  " Browse the generated docs
```

---

See [[Commands]] for the full command reference and [[Configuration]] for all setup options.
