-- dwight/marketplace.lua
-- Skill marketplace: project templates, community skill registry, auto-suggest.
-- Bundles curated skills per project type; detects project type from manifest files.
--
-- :DwightMarketplace           — browse available skill packs
-- :DwightMarketplace install   — install a skill pack
-- :DwightMarketplace suggest   — auto-suggest skills for current project
-- :DwightMarketplace export    — export skills as shareable bundle
-- :DwightMarketplace import    — import skills from a bundle file or gist

local M = {}

local api = vim.api
local uv = vim.loop or vim.uv
local _flatten = require("dwight.util").flatten_lines

--------------------------------------------------------------------
-- Project Type Detection
--------------------------------------------------------------------

--- Map of manifest files → project type signals.
local DETECTORS = {
  -- Go
  { file = "go.mod",          type = "go",           lang = "Go" },
  { file = "go.sum",          type = "go",           lang = "Go" },
  -- Rust
  { file = "Cargo.toml",      type = "rust",         lang = "Rust" },
  -- Python
  { file = "pyproject.toml",  type = "python",       lang = "Python" },
  { file = "setup.py",        type = "python",       lang = "Python" },
  { file = "requirements.txt", type = "python",      lang = "Python" },
  { file = "Pipfile",         type = "python",       lang = "Python" },
  -- JavaScript/TypeScript
  { file = "package.json",    type = "node",         lang = "JS/TS" },
  { file = "tsconfig.json",   type = "typescript",   lang = "TypeScript" },
  { file = "deno.json",       type = "deno",         lang = "TypeScript" },
  -- React
  { dir = "src/components",   type = "react",        lang = "React" },
  -- Next.js
  { file = "next.config.js",  type = "nextjs",       lang = "Next.js" },
  { file = "next.config.mjs", type = "nextjs",       lang = "Next.js" },
  { file = "next.config.ts",  type = "nextjs",       lang = "Next.js" },
  -- Vue
  { file = "vue.config.js",   type = "vue",          lang = "Vue" },
  { file = "nuxt.config.ts",  type = "nuxt",         lang = "Nuxt" },
  -- Elixir
  { file = "mix.exs",         type = "elixir",       lang = "Elixir" },
  -- Ruby
  { file = "Gemfile",         type = "ruby",         lang = "Ruby" },
  { file = "Rakefile",        type = "ruby",         lang = "Ruby" },
  -- Java/Kotlin
  { file = "pom.xml",         type = "java",         lang = "Java" },
  { file = "build.gradle",    type = "java",         lang = "Java/Kotlin" },
  { file = "build.gradle.kts", type = "kotlin",      lang = "Kotlin" },
  -- C/C++
  { file = "CMakeLists.txt",  type = "cpp",          lang = "C/C++" },
  { file = "Makefile",        type = "c",            lang = "C" },
  -- Zig
  { file = "build.zig",       type = "zig",          lang = "Zig" },
  -- PHP
  { file = "composer.json",   type = "php",          lang = "PHP" },
  -- Dart/Flutter
  { file = "pubspec.yaml",    type = "dart",         lang = "Dart" },
  -- Nix
  { file = "flake.nix",       type = "nix",          lang = "Nix" },
  -- Lua/Neovim
  { dir = "lua",              type = "neovim-plugin", lang = "Lua" },
  -- Docker
  { file = "Dockerfile",      type = "docker",       lang = "Docker" },
  { file = "docker-compose.yml", type = "docker",    lang = "Docker" },
  { file = "docker-compose.yaml", type = "docker",   lang = "Docker" },
  -- Terraform
  { dir = "terraform",        type = "terraform",    lang = "Terraform" },
  -- ML/Data
  { dir = "notebooks",        type = "ml",           lang = "Python ML" },
}

--- Detect the project type(s) from the current directory.
--- Returns { primary_type, types = { "go", "docker", ... }, langs = { "Go", "Docker", ... } }
function M.detect_project_type()
  local root = vim.fn.getcwd()
  local types = {}
  local langs = {}
  local type_set = {}

  for _, d in ipairs(DETECTORS) do
    local found = false
    if d.file then
      found = vim.fn.filereadable(root .. "/" .. d.file) == 1
    elseif d.dir then
      found = vim.fn.isdirectory(root .. "/" .. d.dir) == 1
    end
    if found and not type_set[d.type] then
      type_set[d.type] = true
      types[#types + 1] = d.type
      langs[#langs + 1] = d.lang
    end
  end

  -- Refine: check package.json for frameworks
  if type_set["node"] then
    local f = io.open(root .. "/package.json", "r")
    if f then
      local content = f:read("*a"); f:close()
      if content:match('"react"') and not type_set["react"] then
        types[#types + 1] = "react"; langs[#langs + 1] = "React"; type_set["react"] = true
      end
      if content:match('"vue"') and not type_set["vue"] then
        types[#types + 1] = "vue"; langs[#langs + 1] = "Vue"; type_set["vue"] = true
      end
      if content:match('"next"') and not type_set["nextjs"] then
        types[#types + 1] = "nextjs"; langs[#langs + 1] = "Next.js"; type_set["nextjs"] = true
      end
      if content:match('"express"') then
        types[#types + 1] = "express"; langs[#langs + 1] = "Express"; type_set["express"] = true
      end
      if content:match('"fastify"') then
        types[#types + 1] = "fastify"; langs[#langs + 1] = "Fastify"; type_set["fastify"] = true
      end
    end
  end

  -- Check pyproject.toml for ML frameworks
  if type_set["python"] then
    local f = io.open(root .. "/pyproject.toml", "r") or io.open(root .. "/requirements.txt", "r")
    if f then
      local content = f:read("*a"); f:close()
      if content:match("torch") or content:match("tensorflow") or content:match("sklearn")
        or content:match("transformers") or content:match("jax") then
        if not type_set["ml"] then
          types[#types + 1] = "ml"; langs[#langs + 1] = "Python ML"; type_set["ml"] = true
        end
      end
      if content:match("fastapi") or content:match("flask") or content:match("django") then
        types[#types + 1] = "python-web"; langs[#langs + 1] = "Python Web"; type_set["python-web"] = true
      end
    end
  end

  return {
    primary = types[1] or "generic",
    types = types,
    langs = langs,
  }
end

--------------------------------------------------------------------
-- Skill Pack Registry
--------------------------------------------------------------------

--- Each pack: { name, description, project_types, skills = { { name, content }, ... } }
--- Skills are embedded as strings so no external downloads needed.
M.PACKS = {

  ----------------------------------------------------------------
  -- Go API
  ----------------------------------------------------------------
  {
    name = "go-api",
    display = "Go API Server",
    description = "REST/gRPC API server patterns for Go",
    project_types = { "go" },
    skills = {
      { name = "go-api-design", content = [[
# Go API Design

## Overview
Guidelines for building production Go APIs: HTTP handlers, middleware, error handling, and project layout.

## Guidelines
1. Use `http.Handler` interface — keep handlers as methods on a server struct that holds dependencies.
2. Middleware chain: logging → recovery → auth → rate-limit → handler.
3. Always return structured errors with `{ "error": "message", "code": "NOT_FOUND" }`.
4. Use `context.Context` for cancellation, deadlines, and request-scoped values — never store business data in context.
5. Validate input at the handler boundary, not in business logic.
6. Return appropriate HTTP status codes: 400 for bad input, 401 for unauthed, 403 for forbidden, 404 for not found, 500 for internal errors.
7. Use `encoding/json` for simple cases; `json.NewEncoder(w).Encode()` for streaming.
8. Group routes by domain: `/api/v1/users/`, `/api/v1/orders/`.

## Patterns
```go
// Handler method on server struct
func (s *Server) GetUser(w http.ResponseWriter, r *http.Request) {
    id := chi.URLParam(r, "id")
    user, err := s.userStore.Get(r.Context(), id)
    if errors.Is(err, store.ErrNotFound) {
        httpError(w, http.StatusNotFound, "USER_NOT_FOUND", "user not found")
        return
    }
    if err != nil {
        httpError(w, http.StatusInternalServerError, "INTERNAL", "internal error")
        return
    }
    json.NewEncoder(w).Encode(user)
}
```

## Anti-Patterns
- Don't use global variables for database connections — inject via struct fields.
- Don't panic in handlers — use error returns and middleware recovery.
- Don't put business logic in handlers — handlers should only parse input, call services, format output.
]] },
      { name = "go-concurrency", content = [[
# Go Concurrency

## Overview
Safe concurrency patterns for Go: goroutines, channels, sync primitives, and common pitfalls.

## Guidelines
1. Always use `sync.WaitGroup` or `errgroup.Group` to wait for goroutines.
2. Use `context.Context` for cancellation — pass it as the first parameter.
3. Prefer `sync.Mutex` over channels for protecting shared state.
4. Use `chan struct{}` for signaling, not `chan bool`.
5. Always handle the done/cancel case in select statements.
6. Use `sync.Once` for one-time initialization, not manual flags.
7. Buffer channels when the producer shouldn't block: `make(chan T, bufSize)`.
8. Close channels from the sender side only — never from the receiver.

## Patterns
```go
// errgroup for concurrent operations with error propagation
g, ctx := errgroup.WithContext(ctx)
for _, item := range items {
    item := item // capture loop variable
    g.Go(func() error {
        return process(ctx, item)
    })
}
if err := g.Wait(); err != nil {
    return fmt.Errorf("processing failed: %w", err)
}
```

## Anti-Patterns
- Don't launch goroutines without a way to wait for them or cancel them.
- Don't use `time.Sleep` for synchronization — use channels or sync primitives.
- Don't read and write a map concurrently without a mutex.
]] },
    },
  },

  ----------------------------------------------------------------
  -- React App
  ----------------------------------------------------------------
  {
    name = "react-app",
    display = "React Application",
    description = "React component patterns, hooks, state management, and testing",
    project_types = { "react", "nextjs", "node" },
    skills = {
      { name = "react-components", content = [[
# React Component Patterns

## Overview
Guidelines for building maintainable React components: composition, hooks, props, and rendering.

## Guidelines
1. Default to functional components with hooks — never class components in new code.
2. Extract custom hooks when logic is reused across 2+ components.
3. Keep components under 150 lines — split into smaller components if larger.
4. Props interface: define with TypeScript types, use destructuring in params.
5. Use `React.memo()` only when you measure a performance problem, not preemptively.
6. Colocate state with the component that needs it — lift state only when siblings share it.
7. Use composition (children, render props) over inheritance.
8. Name event handlers as `onAction` (props) and `handleAction` (internal).

## Patterns
```tsx
// Good: small, focused component with typed props
interface UserCardProps {
  user: User;
  onSelect: (id: string) => void;
}

export function UserCard({ user, onSelect }: UserCardProps) {
  const handleClick = () => onSelect(user.id);
  return (
    <div onClick={handleClick} role="button" tabIndex={0}>
      <Avatar src={user.avatar} alt={user.name} />
      <span>{user.name}</span>
    </div>
  );
}
```

## Anti-Patterns
- Don't use `useEffect` for derived state — compute during render instead.
- Don't spread all props with `{...props}` — be explicit about what you pass.
- Don't use index as key in lists that can reorder.
]] },
      { name = "react-hooks", content = [[
# React Hooks

## Overview
Patterns for custom hooks, effect management, and state in React applications.

## Guidelines
1. Custom hooks start with `use` and encapsulate a single concern.
2. `useEffect` cleanup: always return a cleanup function for subscriptions, timers, abort controllers.
3. `useMemo` / `useCallback`: use only when passing to memoized children or expensive computations.
4. `useState` for simple values; `useReducer` for complex state with multiple sub-values.
5. Fetch data with `useEffect` + AbortController, or use a data-fetching library (SWR, React Query).
6. Never call hooks conditionally — always at the top level of the component.
7. Keep effect dependency arrays accurate — don't suppress the exhaustive-deps lint.

## Patterns
```tsx
// Custom hook for async data with loading/error states
function useAsync<T>(asyncFn: () => Promise<T>, deps: unknown[]) {
  const [state, setState] = useState<{ data?: T; error?: Error; loading: boolean }>({ loading: true });
  useEffect(() => {
    const controller = new AbortController();
    setState(s => ({ ...s, loading: true }));
    asyncFn()
      .then(data => { if (!controller.signal.aborted) setState({ data, loading: false }); })
      .catch(error => { if (!controller.signal.aborted) setState({ error, loading: false }); });
    return () => controller.abort();
  }, deps);
  return state;
}
```

## Anti-Patterns
- Don't fetch data in useEffect without an abort controller — causes race conditions.
- Don't use useRef to hold mutable state that should trigger re-renders.
- Don't create new objects/arrays in render that are passed as effect dependencies.
]] },
    },
  },

  ----------------------------------------------------------------
  -- Python ML
  ----------------------------------------------------------------
  {
    name = "python-ml",
    display = "Python Machine Learning",
    description = "ML pipeline patterns: data loading, training, evaluation, and deployment",
    project_types = { "python", "ml" },
    skills = {
      { name = "ml-pipeline", content = [[
# ML Pipeline Patterns

## Overview
Guidelines for building reproducible ML pipelines: data processing, training, evaluation, and experiment tracking.

## Guidelines
1. Separate data loading, preprocessing, model definition, training, and evaluation into distinct modules.
2. Use config files (YAML/TOML) for hyperparameters — never hardcode in training scripts.
3. Set random seeds everywhere: `torch.manual_seed()`, `np.random.seed()`, `random.seed()`.
4. Log all experiments with metrics, hyperparams, and git hash — use MLflow, W&B, or at minimum a JSON log.
5. Validate data shapes at pipeline boundaries with assertions.
6. Use `pathlib.Path` for all file paths — never string concatenation.
7. Type-hint all function signatures, especially tensor shapes in comments.
8. Keep training loops clean: extract loss computation, metric logging, and checkpointing.

## Patterns
```python
# Config-driven training
@dataclass
class TrainConfig:
    lr: float = 1e-4
    batch_size: int = 32
    epochs: int = 100
    seed: int = 42
    checkpoint_dir: Path = Path("checkpoints")

def train(config: TrainConfig, model: nn.Module, dataloader: DataLoader) -> dict:
    optimizer = AdamW(model.parameters(), lr=config.lr)
    best_loss = float("inf")
    for epoch in range(config.epochs):
        metrics = train_epoch(model, dataloader, optimizer)
        if metrics["val_loss"] < best_loss:
            best_loss = metrics["val_loss"]
            save_checkpoint(model, config.checkpoint_dir / f"best.pt")
    return metrics
```

## Anti-Patterns
- Don't load entire datasets into memory without checking size first.
- Don't skip validation splits — always evaluate on held-out data.
- Don't train without logging — you will forget what you tried.
]] },
    },
  },

  ----------------------------------------------------------------
  -- Rust CLI/Library
  ----------------------------------------------------------------
  {
    name = "rust-app",
    display = "Rust Application",
    description = "Rust patterns: error handling, ownership, traits, and async",
    project_types = { "rust" },
    skills = {
      { name = "rust-patterns", content = [[
# Rust Patterns

## Overview
Idiomatic Rust patterns: error handling, ownership, trait design, and project structure.

## Guidelines
1. Use `thiserror` for library errors, `anyhow` for application errors.
2. Prefer `&str` over `String` in function parameters; return `String` when needed.
3. Use `impl Trait` for return types to hide concrete types.
4. Derive `Debug`, `Clone`, `PartialEq` on all public types unless there's a reason not to.
5. Use `clippy` with `--deny warnings` in CI.
6. Prefer `Option::map`/`and_then`/`unwrap_or` over manual match for simple transformations.
7. Use `#[must_use]` on functions whose return value shouldn't be ignored.
8. Keep `unsafe` blocks minimal and document the safety invariant with `// SAFETY:` comments.

## Patterns
```rust
// Custom error type with thiserror
#[derive(Debug, thiserror::Error)]
pub enum AppError {
    #[error("not found: {0}")]
    NotFound(String),
    #[error("database error")]
    Database(#[from] sqlx::Error),
    #[error("invalid input: {0}")]
    Validation(String),
}

type Result<T> = std::result::Result<T, AppError>;
```

## Anti-Patterns
- Don't use `.unwrap()` in production code — use `?` or handle the error.
- Don't clone to satisfy the borrow checker without understanding why — fix the ownership.
- Don't use `String` where `&str` suffices.
]] },
    },
  },

  ----------------------------------------------------------------
  -- TypeScript API
  ----------------------------------------------------------------
  {
    name = "typescript-api",
    display = "TypeScript Backend",
    description = "Node.js/TypeScript API patterns: Express/Fastify, validation, error handling",
    project_types = { "typescript", "node", "express", "fastify" },
    skills = {
      { name = "ts-api-patterns", content = [[
# TypeScript API Patterns

## Overview
Guidelines for building type-safe Node.js APIs: request validation, error handling, middleware, and project structure.

## Guidelines
1. Validate all request input at the boundary with Zod or io-ts — never trust raw `req.body`.
2. Define error types as discriminated unions: `{ type: "NOT_FOUND", message: string }`.
3. Use dependency injection: pass services to route handlers, don't import singletons.
4. Keep route handlers thin: parse input → call service → format response.
5. Use `async/await` everywhere — never raw callbacks or `.then()` chains.
6. Define response types explicitly — don't rely on `any` or implicit typing.
7. Use `strict: true` in tsconfig — no exceptions.
8. Centralize error handling in middleware, not in each handler.

## Patterns
```typescript
// Zod validation + typed handler
const CreateUserSchema = z.object({
  email: z.string().email(),
  name: z.string().min(1).max(100),
});

type CreateUserInput = z.infer<typeof CreateUserSchema>;

async function createUser(req: Request, res: Response, next: NextFunction) {
  const result = CreateUserSchema.safeParse(req.body);
  if (!result.success) {
    return res.status(400).json({ error: result.error.flatten() });
  }
  const user = await userService.create(result.data);
  res.status(201).json(user);
}
```

## Anti-Patterns
- Don't use `any` to bypass type errors — fix the types.
- Don't catch errors silently — always log or re-throw.
- Don't put database queries directly in route handlers.
]] },
    },
  },

  ----------------------------------------------------------------
  -- Docker/DevOps
  ----------------------------------------------------------------
  {
    name = "docker-devops",
    display = "Docker & DevOps",
    description = "Container patterns, multi-stage builds, compose, and CI/CD",
    project_types = { "docker" },
    skills = {
      { name = "docker-patterns", content = [[
# Docker Patterns

## Overview
Guidelines for Dockerfiles, multi-stage builds, compose, and container best practices.

## Guidelines
1. Use multi-stage builds: builder stage for compilation, runtime stage with minimal image.
2. Pin base image versions: `FROM node:20.11-alpine` not `FROM node:latest`.
3. Order Dockerfile layers by change frequency: dependencies first, source code last.
4. Use `.dockerignore` to exclude `node_modules`, `.git`, test files, docs.
5. Run as non-root: `USER 1001` in the final stage.
6. Use HEALTHCHECK for production containers.
7. Keep images small: prefer `alpine` or `distroless` base images.
8. Use build args for configuration, not runtime secrets.

## Patterns
```dockerfile
# Multi-stage build
FROM node:20-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci --production=false
COPY . .
RUN npm run build

FROM node:20-alpine
WORKDIR /app
RUN addgroup -g 1001 app && adduser -u 1001 -G app -s /bin/sh -D app
COPY --from=builder /app/dist ./dist
COPY --from=builder /app/node_modules ./node_modules
USER 1001
HEALTHCHECK CMD wget -q -O /dev/null http://localhost:3000/health
CMD ["node", "dist/main.js"]
```

## Anti-Patterns
- Don't use `latest` tag — pin versions for reproducibility.
- Don't run as root in production containers.
- Don't copy node_modules into the image — install in the build stage.
]] },
    },
  },

  ----------------------------------------------------------------
  -- Neovim Plugin
  ----------------------------------------------------------------
  {
    name = "neovim-plugin",
    display = "Neovim Plugin (Lua)",
    description = "Neovim plugin patterns: API usage, buffer management, async, and testing",
    project_types = { "neovim-plugin" },
    skills = {
      { name = "neovim-lua", content = [[
# Neovim Plugin Patterns (Lua)

## Overview
Guidelines for building Neovim plugins: API usage, buffer/window management, async patterns, and user experience.

## Guidelines
1. Use `vim.api.nvim_*` for buffer/window operations — avoid legacy Vim functions.
2. Async work: use `vim.loop` (libuv) for IO, `vim.schedule()` to safely modify buffers from callbacks.
3. User commands: register with `vim.api.nvim_create_user_command()`, provide completions.
4. Config: accept a `setup(opts)` function, merge with defaults using `vim.tbl_deep_extend`.
5. Lazy-load modules: `require("plugin.module")` only when needed, not at startup.
6. Use `vim.notify()` for user messages — respect notification plugins.
7. Keymaps: use `vim.keymap.set()` with `desc` for which-key support.
8. Buffer options: set `buftype`, `bufhidden`, `modifiable`, `swapfile` on scratch buffers.

## Patterns
```lua
-- Lazy module loading pattern
local M = {}
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.defaults, opts or {})
  vim.api.nvim_create_user_command("MyCommand", function(o)
    require("myplugin.core").run(o.args)
  end, { nargs = "?", desc = "My plugin command" })
end
return M
```

## Anti-Patterns
- Don't modify buffers outside `vim.schedule()` from async callbacks.
- Don't use `vim.cmd` for things that have direct API equivalents.
- Don't block the UI with synchronous operations — use async IO.
]] },
    },
  },
}

--------------------------------------------------------------------
-- Matching: project types → recommended packs
--------------------------------------------------------------------

--- Find packs matching the detected project types.
--- Returns { { pack, match_score }, ... } sorted by relevance.
function M.suggest_packs()
  local detected = M.detect_project_type()
  local type_set = {}
  for _, t in ipairs(detected.types) do type_set[t] = true end

  local matches = {}
  for _, pack in ipairs(M.PACKS) do
    local score = 0
    for _, pt in ipairs(pack.project_types) do
      if type_set[pt] then score = score + 1 end
    end
    if score > 0 then
      matches[#matches + 1] = { pack = pack, score = score }
    end
  end

  table.sort(matches, function(a, b) return a.score > b.score end)
  return matches, detected
end

--- Get skills already installed.
local function installed_skills()
  local ok, skills = pcall(function()
    return require("dwight.skills").names()
  end)
  return ok and skills or {}
end

--------------------------------------------------------------------
-- Install / Uninstall
--------------------------------------------------------------------

--- Install a skill pack: writes each skill .md to .dwight/skills/.
--- Returns list of installed skill names.
function M.install_pack(pack_name)
  local project = require("dwight.project")
  if not project.is_initialized() then
    vim.notify("[dwight] Run :DwightInit first.", vim.log.levels.WARN)
    return {}
  end

  -- Find the pack
  local pack
  for _, p in ipairs(M.PACKS) do
    if p.name == pack_name then pack = p; break end
  end
  if not pack then
    vim.notify("[dwight] Pack not found: " .. pack_name, vim.log.levels.ERROR)
    return {}
  end

  local skills_dir = project.skills_dir()
  vim.fn.mkdir(skills_dir, "p")
  local installed = {}

  for _, skill in ipairs(pack.skills) do
    local path = skills_dir .. "/" .. skill.name .. ".md"
    if vim.fn.filereadable(path) == 1 then
      -- Don't overwrite existing
      vim.notify("[dwight] Skill '@" .. skill.name .. "' already exists, skipping.", vim.log.levels.INFO)
    else
      local f = io.open(path, "w")
      if f then
        f:write(skill.content)
        f:close()
        installed[#installed + 1] = skill.name
      end
    end
  end

  if #installed > 0 then
    vim.notify(string.format("[dwight] ✅ Installed pack '%s': %s",
      pack.display,
      table.concat(vim.tbl_map(function(n) return "@" .. n end, installed), ", ")),
      vim.log.levels.INFO)
  end

  return installed
end

--------------------------------------------------------------------
-- Export / Import (share skills)
--------------------------------------------------------------------

--- Export current skills as a shareable JSON bundle.
--- Returns the output path.
function M.export_skills()
  local project = require("dwight.project")
  if not project.is_initialized() then
    vim.notify("[dwight] Run :DwightInit first.", vim.log.levels.WARN)
    return nil
  end

  local skills = require("dwight.skills").list()
  if #skills == 0 then
    vim.notify("[dwight] No skills to export.", vim.log.levels.INFO)
    return nil
  end

  local bundle = {
    format = "dwight-skills-v1",
    exported_at = os.date("%Y-%m-%dT%H:%M:%S"),
    project = vim.fn.getcwd():match("([^/]+)$") or "unknown",
    skills = {},
  }

  for _, skill in ipairs(skills) do
    local f = io.open(skill.path, "r")
    if f then
      local content = f:read("*a"); f:close()
      bundle.skills[#bundle.skills + 1] = {
        name = skill.name,
        content = content,
      }
    end
  end

  local path = project.dir() .. "/skills-bundle.json"
  local ok, json = pcall(vim.json.encode, bundle)
  if ok then
    local f = io.open(path, "w")
    if f then
      f:write(json .. "\n"); f:close()
      vim.notify(string.format("[dwight] ✅ Exported %d skills to %s",
        #bundle.skills, path), vim.log.levels.INFO)
      return path
    end
  end

  vim.notify("[dwight] Export failed.", vim.log.levels.ERROR)
  return nil
end

--- Import skills from a JSON bundle file.
function M.import_skills(path)
  local project = require("dwight.project")
  if not project.is_initialized() then
    vim.notify("[dwight] Run :DwightInit first.", vim.log.levels.WARN)
    return
  end

  local f = io.open(path, "r")
  if not f then
    vim.notify("[dwight] File not found: " .. path, vim.log.levels.ERROR)
    return
  end
  local raw = f:read("*a"); f:close()

  local ok, bundle = pcall(vim.json.decode, raw)
  if not ok or type(bundle) ~= "table" or bundle.format ~= "dwight-skills-v1" then
    vim.notify("[dwight] Invalid skill bundle format.", vim.log.levels.ERROR)
    return
  end

  local skills_dir = project.skills_dir()
  vim.fn.mkdir(skills_dir, "p")
  local imported = {}
  local skipped = {}

  for _, skill in ipairs(bundle.skills or {}) do
    local dest = skills_dir .. "/" .. skill.name .. ".md"
    if vim.fn.filereadable(dest) == 1 then
      skipped[#skipped + 1] = skill.name
    else
      local out = io.open(dest, "w")
      if out then
        out:write(skill.content); out:close()
        imported[#imported + 1] = skill.name
      end
    end
  end

  local msg = string.format("[dwight] ✅ Imported %d skills", #imported)
  if #imported > 0 then
    msg = msg .. ": " .. table.concat(vim.tbl_map(function(n) return "@" .. n end, imported), ", ")
  end
  if #skipped > 0 then
    msg = msg .. string.format("\n  Skipped %d (already exist): %s",
      #skipped, table.concat(skipped, ", "))
  end
  vim.notify(msg, vim.log.levels.INFO)
end

--------------------------------------------------------------------
-- Auto-suggest on init
--------------------------------------------------------------------

--- Suggest and optionally install packs for the current project.
--- Called after :DwightInit to recommend relevant skills.
function M.auto_suggest()
  local matches, detected = M.suggest_packs()
  if #matches == 0 then return end

  local already = installed_skills()
  local already_set = {}
  for _, n in ipairs(already) do already_set[n] = true end

  -- Filter to packs that have at least one new skill
  local new_matches = {}
  for _, m in ipairs(matches) do
    local has_new = false
    for _, skill in ipairs(m.pack.skills) do
      if not already_set[skill.name] then has_new = true; break end
    end
    if has_new then new_matches[#new_matches + 1] = m end
  end

  if #new_matches == 0 then return end

  -- Build suggestion
  local parts = { string.format("[dwight] 💡 Detected: %s",
    table.concat(detected.langs, ", ")) }
  parts[#parts + 1] = "  Recommended skill packs:"
  local items = {}
  for _, m in ipairs(new_matches) do
    local skill_names = {}
    for _, s in ipairs(m.pack.skills) do
      local tag = already_set[s.name] and " (installed)" or ""
      skill_names[#skill_names + 1] = "@" .. s.name .. tag
    end
    parts[#parts + 1] = string.format("    📦 %s — %s", m.pack.display, table.concat(skill_names, ", "))
    items[#items + 1] = string.format("📦 %s — %s", m.pack.display, m.pack.description)
  end

  vim.notify(table.concat(parts, "\n"), vim.log.levels.INFO)

  -- Offer to install
  items[#items + 1] = "Install all recommended"
  items[#items + 1] = "Skip"

  vim.defer_fn(function()
    require("dwight.select").pick(items, {
      prompt = "Install recommended skill packs?",
    }, function(choice, idx)
      if not choice or choice == "Skip" then return end
      if choice == "Install all recommended" then
        for _, m in ipairs(new_matches) do
          M.install_pack(m.pack.name)
        end
      elseif idx and idx <= #new_matches then
        M.install_pack(new_matches[idx].pack.name)
      end
    end)
  end, 500)
end

--------------------------------------------------------------------
-- Interactive UI
--------------------------------------------------------------------

--- Main marketplace browser.
function M.browse()
  local detected = M.detect_project_type()
  local already = installed_skills()
  local already_set = {}
  for _, n in ipairs(already) do already_set[n] = true end

  local lines = {
    "╔══════════════════════════════════════════════════════════════╗",
    "║                  Dwight Skill Marketplace                    ║",
    "╚══════════════════════════════════════════════════════════════╝",
    "",
    string.format("  Detected: %s", #detected.langs > 0 and table.concat(detected.langs, ", ") or "(unknown)"),
    string.format("  Installed: %d skills", #already),
    "",
  }

  -- Recommended first
  local matches = M.suggest_packs()
  if #matches > 0 then
    lines[#lines + 1] = "── 💡 Recommended for Your Project ────────────────────────────────"
    for _, m in ipairs(matches) do
      local pack = m.pack
      local skill_status = {}
      local all_installed = true
      for _, s in ipairs(pack.skills) do
        if already_set[s.name] then
          skill_status[#skill_status + 1] = "  ✅ @" .. s.name .. " (installed)"
        else
          skill_status[#skill_status + 1] = "  📥 @" .. s.name
          all_installed = false
        end
      end
      local marker = all_installed and "✅" or "📦"
      lines[#lines + 1] = string.format("  %s %s — %s", marker, pack.display, pack.description)
      for _, ss in ipairs(skill_status) do lines[#lines + 1] = "    " .. ss end
      lines[#lines + 1] = ""
    end
  end

  -- All packs
  lines[#lines + 1] = "── 📚 All Skill Packs ─────────────────────────────────────────────"
  for _, pack in ipairs(M.PACKS) do
    local skill_count = #pack.skills
    local installed_count = 0
    for _, s in ipairs(pack.skills) do
      if already_set[s.name] then installed_count = installed_count + 1 end
    end
    local status = installed_count == skill_count and "✅" or
      installed_count > 0 and "🔶" or "📦"
    lines[#lines + 1] = string.format("  %s %-25s %d skills  (%d installed)  [%s]",
      status, pack.display, skill_count, installed_count,
      table.concat(pack.project_types, ", "))
  end
  lines[#lines + 1] = ""

  -- Actions
  lines[#lines + 1] = "── Actions ─────────────────────────────────────────────────────────"
  lines[#lines + 1] = "  i — Install a pack     e — Export skills     m — Import skills"
  lines[#lines + 1] = "  s — Suggest for project g — Generate custom   q — Close"

  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, _flatten(lines))
  vim.bo[buf].modifiable = false
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "dwight_marketplace"

  vim.cmd("botright split")
  local win = api.nvim_get_current_win()
  api.nvim_win_set_buf(win, buf)
  api.nvim_win_set_height(win, math.min(#lines + 2, math.floor(vim.o.lines * 0.6)))

  -- Highlights
  pcall(function()
    api.nvim_buf_call(buf, function()
      vim.cmd([[
        syntax match DwightMktHeader /^[╔╚║].*$/
        syntax match DwightMktSection /^──.*──$/
        syntax match DwightMktInstalled /✅/
        syntax match DwightMktAvailable /📦/
        syntax match DwightMktPartial /🔶/
        syntax match DwightMktSkill /@[a-z][a-z0-9_-]*/
      ]])
    end)
  end)

  local hl = api.nvim_set_hl
  hl(0, "DwightMktHeader",    { fg = "#bb9af7", bold = true, default = true })
  hl(0, "DwightMktSection",   { fg = "#7aa2f7", bold = true, default = true })
  hl(0, "DwightMktInstalled", { fg = "#9ece6a", default = true })
  hl(0, "DwightMktSkill",     { fg = "#7dcfff", default = true })

  local function close() pcall(api.nvim_win_close, win, true) end

  vim.keymap.set("n", "q",   close, { buffer = buf })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf })

  vim.keymap.set("n", "i", function()
    close()
    M.install_interactive()
  end, { buffer = buf, desc = "Install pack" })

  vim.keymap.set("n", "e", function()
    close()
    M.export_skills()
  end, { buffer = buf, desc = "Export skills" })

  vim.keymap.set("n", "m", function()
    close()
    vim.ui.input({ prompt = "Path to skill bundle JSON: ", completion = "file" }, function(path)
      if path and path ~= "" then M.import_skills(path) end
    end)
  end, { buffer = buf, desc = "Import skills" })

  vim.keymap.set("n", "s", function()
    close()
    M.auto_suggest()
  end, { buffer = buf, desc = "Suggest for project" })

  vim.keymap.set("n", "g", function()
    close()
    require("dwight.skills").generate()
  end, { buffer = buf, desc = "Generate custom skill" })
end

--- Interactive pack installer.
function M.install_interactive()
  local items = {}
  local already = installed_skills()
  local already_set = {}
  for _, n in ipairs(already) do already_set[n] = true end

  for _, pack in ipairs(M.PACKS) do
    local new_count = 0
    for _, s in ipairs(pack.skills) do
      if not already_set[s.name] then new_count = new_count + 1 end
    end
    local status = new_count == 0 and "✅ " or "📦 "
    items[#items + 1] = string.format("%s%s — %s (%d new)",
      status, pack.display, pack.description, new_count)
  end

  require("dwight.select").pick(items, {
    prompt = "Install which skill pack?",
  }, function(_, idx)
    if idx then M.install_pack(M.PACKS[idx].name) end
  end)
end

--------------------------------------------------------------------
-- Main entry point
--------------------------------------------------------------------

function M.run(target)
  if target == "install" then
    M.install_interactive()
  elseif target == "suggest" then
    M.auto_suggest()
  elseif target == "export" then
    M.export_skills()
  elseif target == "import" then
    vim.ui.input({ prompt = "Path to skill bundle JSON: ", completion = "file" }, function(path)
      if path and path ~= "" then M.import_skills(path) end
    end)
  elseif target == "detect" then
    local detected = M.detect_project_type()
    vim.notify(string.format("[dwight] Detected: %s\n  Types: %s\n  Langs: %s",
      detected.primary,
      table.concat(detected.types, ", "),
      table.concat(detected.langs, ", ")),
      vim.log.levels.INFO)
  else
    M.browse()
  end
end

return M
