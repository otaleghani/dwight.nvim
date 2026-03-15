---
title: TDD
description: Automated test-driven development loop that writes tests, runs them, implements code, and iterates until green.
---

# TDD

Dwight's TDD mode automates the red-green-refactor cycle. Describe a feature, and Dwight writes a failing test, implements the minimum code to pass, runs the test, and repeats until the feature is complete.

---

## How It Works

1. **Start a session** — `:DwightTDD "user validation"` begins the loop.
2. **Write test** — the agent writes a failing test based on your description.
3. **Run test** — Dwight runs the detected test command and confirms the test fails (red).
4. **Implement** — the agent writes the minimum code to make the test pass.
5. **Verify** — Dwight runs tests again and confirms they pass (green).
6. **Iterate** — the loop continues with the next test until the feature is complete or you stop it.

```vim
:DwightTDD "user validation"     " Start TDD for a feature
:DwightTDDStop                   " Stop the loop
```

---

## Test Command Detection

Dwight auto-detects the test command based on your project type:

| Language | Test Command |
|----------|-------------|
| Go | `go test ./...` |
| JavaScript/TypeScript | `npm test` or `npx jest` |
| Python | `pytest` or `python -m pytest` |
| Rust | `cargo test` |
| Ruby | `bundle exec rspec` or `rake test` |
| Java | `mvn test -q` or `gradle test` |
| Lua | detected from project config |

Override detection with the `languages` config or pass a command directly:

```vim
:DwightTDD "user validation"
" Or with a custom test command via setup:
" languages = { python = { test_cmd = "pytest -x" } }
```

---

## Test File Discovery

When injecting test context into prompts, Dwight finds the test file for the current source file using language-specific patterns:

| Language | Patterns |
|----------|----------|
| JavaScript/TypeScript | `file.test.ts`, `file.spec.ts`, `__tests__/file.ts` |
| Python | `test_file.py`, `file_test.py`, `tests/test_file.py` |
| Go | `file_test.go` (same directory) |
| Rust | `file_test.rs`, `tests/file.rs` |
| Ruby | `file_spec.rb`, `spec/file_spec.rb` |
| Java/Kotlin | `FileTest.java`, `FileTest.kt` |
| Lua | `file_spec.lua`, `file_test.lua` |

---

## Test Run History

Every test run is recorded with its output, pass/fail counts, and timestamp:

```vim
:DwightTestRuns              " Browse test run history (Telescope)
```

The picker shows each run with a pass/fail indicator, timestamp, and the command that was run. Select a run to view its full output.

---

## Tips

- **Be specific about the feature.** "user validation" is better than "validation" — it scopes the tests and implementation to a clear area.
- **Check your test command first.** Run `:checkhealth dwight` to see which test command Dwight detected. If it's wrong, configure it via `languages` in setup.
- **Use TDD for new features.** The red-green cycle ensures every piece of new code has test coverage from the start.
- **Stop early if needed.** `:DwightTDDStop` cleanly exits the loop. All code written so far is preserved.

---

## Commands

| Command | Args | Description |
|---------|------|-------------|
| `:DwightTDD` | `[description]` | Start a TDD session |
| `:DwightTDDStop` | | Stop the active TDD session |
| `:DwightTestRuns` | | Browse test run history |
| `:DwightRun` | `[cmd]` | Run a build/test command manually |
| `:DwightRunOutput` | | Show last run output |

---

## See Also

- [[Agent Mode]] -- TDD uses the agent loop internally for test writing and implementation
- [[Auto Mode]] -- also runs verification gates after each sub-task
- [[Inline Editing]] -- the `/test` mode generates tests for selected code without the full TDD loop
