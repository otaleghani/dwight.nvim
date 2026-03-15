---
title: Providers and Models
description: Configure backends, API providers, model switching, MCP servers, and OAuth authentication for AI operations.
---

# Providers and Models

Dwight separates **backends** (CLI tools that run agents) from **providers** (API services for single-shot operations). This page explains both systems and how to configure them.

---

## How It Works

1. **Backend** — a CLI agent (Claude Code, Codex, Gemini, OpenCode) that handles autonomous tasks like `:DwightAgent` and `:DwightAuto`. The backend manages its own authentication.
2. **Provider** — an API service (Anthropic, OpenAI, Gemini, OpenRouter, or custom) used for single-shot operations like `:DwightGenSkill`, `:DwightRefactor`, and inline modes. Requires an API key.
3. **Model** — the specific model within a provider. Switch at runtime with `:DwightSwitch`.

```vim
:DwightBackend claude_code    " Switch backend
:DwightSwitch opus            " Switch model
:DwightProviders              " Show current provider/model/key status
```

---

## Backends

The backend determines which CLI tool runs agentic tasks. Set it in `setup()` or switch at runtime.

| Backend | CLI | Auth |
|---------|-----|------|
| `claude_code` | [Claude Code](https://docs.anthropic.com/en/docs/claude-code) | `claude login` (OAuth) |
| `codex` | [OpenAI Codex](https://github.com/openai/codex) | `OPENAI_API_KEY` env var |
| `gemini` | [Gemini CLI](https://github.com/google-gemini/gemini-cli) | `gcloud auth` or `GOOGLE_API_KEY` |
| `opencode` | [OpenCode](https://github.com/opencode-ai/opencode) | Managed by opencode |

```lua
require("dwight").setup({
  backend = "claude_code",          -- default
  claude_code_bin = "claude",       -- path to binary
  claude_code_model = "sonnet",     -- or "opus", "haiku"
})
```

---

## Providers

Providers handle API calls for non-agentic operations. Dwight ships with five built-in presets:

| Provider | Key Env Var | Models |
|----------|-------------|--------|
| `anthropic` | `ANTHROPIC_API_KEY` | sonnet, haiku, opus |
| `anthropic_max` | OAuth (`:DwightAuthMax`) | sonnet, haiku, opus |
| `openai` | `OPENAI_API_KEY` | gpt4o, gpt4o-mini, o3, o4-mini, gpt5 |
| `gemini` | `GEMINI_API_KEY` | flash, pro |
| `openrouter` | `OPENROUTER_API_KEY` | sonnet, haiku, opus, gpt4o, flash |

Auto-detection: if no provider is set, Dwight checks environment variables and picks the first available.

---

## Switching Models

```vim
:DwightSwitch sonnet           " Switch to sonnet on current provider
:DwightSwitch openai:gpt4o     " Switch to GPT-4o via OpenAI
:DwightSwitch openrouter:opus  " Switch to Opus via OpenRouter
```

Tab completion shows only models available for your current backend. For `claude_code`, the options are `haiku`, `sonnet`, and `opus` — the CLI handles auth, no API key needed.

---

## Model Diversity

Use different models for test-writing vs implementation to reduce blind spots:

```lua
require("dwight").setup({
  test_model = "sonnet",       -- for /test, /stub modes
  implement_model = "opus",    -- for /code, /implement, /fix modes
})
```

When both are set, Dwight automatically routes to the correct model based on the mode. When unset, all modes use the default model.

---

## Adding Custom Providers

For self-hosted or third-party API-compatible services:

```vim
:DwightAddProvider
```

The wizard prompts for: name, API format (openai/anthropic/gemini/custom), base URL, endpoint, API key env var, default model, and model aliases.

Provider configs are stored globally in `~/.config/dwight/providers.json` and per-project in `.dwight/providers.json` (project overrides global).

---

## Anthropic Max (OAuth)

Use your Anthropic Pro/Max subscription instead of API credits:

```vim
:DwightAuthMax
```

This command:
1. Searches for existing Claude Code credentials (auto-import if found)
2. Falls back to manual token or API key entry
3. Stores the token securely in `~/.config/dwight/oauth_token.json` (chmod 600)
4. Switches the active provider to `anthropic_max`

Token refresh is automatic when a refresh token is available.

---

## MCP Servers

Connect external tools via the Model Context Protocol. MCP servers provide additional context to agents.

```lua
require("dwight").setup({
  mcp_servers = {
    { name = "sqlite", command = "mcp-server-sqlite", args = { "project.db" } },
    { name = "github", command = "mcp-server-github",
      env = { GITHUB_TOKEN = os.getenv("GITHUB_TOKEN") } },
  },
})
```

Check server status with:

```vim
:DwightMCP
```

MCP resources are referenced in prompts with `&server:resource_uri` and resolved synchronously at prompt build time.

---

## Tips

- **Use `claude_code` backend with `anthropic_max` provider.** The backend handles agent tasks via CLI auth; the provider handles single-shot calls against your subscription. No API credits needed for either.
- **Check `:DwightProviders` when something fails.** It shows the active backend, provider, model, and key status in one line.
- **Set model diversity for TDD workflows.** Different models catch different bugs — using one for tests and another for implementation improves coverage.
- **Custom providers work with any OpenAI-compatible API.** Local models via Ollama, LM Studio, or vLLM can be added through `:DwightAddProvider`.

---

## Commands

| Command | Args | Description |
|---------|------|-------------|
| `:DwightBackend` | `[claude_code\|codex\|gemini\|opencode]` | Get or set the CLI backend |
| `:DwightSwitch` | `<model>` | Switch model (filtered by backend) |
| `:DwightProviders` | | Show current provider, model, and key status |
| `:DwightAddProvider` | | Interactive wizard to add a custom provider |
| `:DwightAuthMax` | | Authenticate with Anthropic Pro/Max subscription |
| `:DwightMCP` | | Show MCP server status |

---

## See Also

- [[Configuration]] -- for all setup() options including backend and provider settings
- [[Core Concepts]] -- for how providers fit into the overall architecture
- [[Agent Mode]] -- uses the backend for autonomous tasks
- [[Inline Editing]] -- uses the provider for single-shot API calls
