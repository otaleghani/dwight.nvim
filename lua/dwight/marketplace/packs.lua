-- dwight/marketplace/packs.lua
-- Curated skill pack registry.

local M = {}

--- Each pack: { name, description, project_types, skills = { { name, content }, ... } }
--- Optional kit fields: mcp_servers, agent_instructions, urls.
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
			{
				name = "go-api-design",
				content = [[
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
]],
			},
			{
				name = "go-concurrency",
				content = [[
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
]],
			},
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
			{
				name = "react-components",
				content = [[
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
]],
			},
			{
				name = "react-hooks",
				content = [[
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
]],
			},
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
			{
				name = "ml-pipeline",
				content = [[
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
]],
			},
			{
				name = "model-evaluation",
				content = [[
# Model Evaluation

## Overview
Guidelines for evaluating ML models: train/val/test splits, metrics selection, cross-validation, and detecting overfitting.

## Guidelines
1. Always hold out a test set that is never used during training or hyperparameter tuning.
2. Use stratified splits for imbalanced datasets to preserve class distribution.
3. Choose metrics that align with business goals: precision for low-FP needs, recall for low-FN needs.
4. Use k-fold cross-validation (k=5 or 10) for small datasets to get robust performance estimates.
5. Track both training and validation metrics per epoch to detect overfitting early.
6. Report confidence intervals or standard deviations, not just point estimates.
7. Compare against a simple baseline (majority class, mean prediction) before celebrating results.
8. Log all evaluation runs with dataset version, split seed, and hyperparameters.

## Patterns
```python
from sklearn.model_selection import StratifiedKFold, cross_validate

def evaluate_model(model, X, y, cv=5):
    skf = StratifiedKFold(n_splits=cv, shuffle=True, random_state=42)
    scores = cross_validate(
        model, X, y, cv=skf,
        scoring=["accuracy", "f1_weighted", "roc_auc_ovr"],
        return_train_score=True,
    )
    for metric in ["accuracy", "f1_weighted", "roc_auc_ovr"]:
        train = scores[f"train_{metric}"]
        test = scores[f"test_{metric}"]
        print(f"{metric}: train={train.mean():.3f}±{train.std():.3f} "
              f"test={test.mean():.3f}±{test.std():.3f}")
    return scores
```

## Anti-Patterns
- Don't tune hyperparameters on the test set — use a validation set or cross-validation.
- Don't report accuracy alone on imbalanced datasets — use F1, AUC, or precision/recall.
- Don't ignore the gap between train and validation metrics — a large gap signals overfitting.
]],
			},
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
			{
				name = "rust-patterns",
				content = [[
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
]],
			},
			{
				name = "rust-async",
				content = [[
# Rust Async Patterns

## Overview
Async Rust with Tokio: async fn, Pin/Future, select!, spawning tasks, and cancellation safety.

## Guidelines
1. Use `#[tokio::main]` for the entry point; `#[tokio::test]` for async tests.
2. Prefer `tokio::spawn` for independent tasks; `tokio::join!` for concurrent dependent work.
3. Use `tokio::select!` for racing futures — ensure branches are cancellation-safe.
4. Avoid holding `MutexGuard` across `.await` points — use `tokio::sync::Mutex` if you must.
5. Use `tokio::sync::mpsc` for channels, `broadcast` for pub/sub, `oneshot` for single responses.
6. Set timeouts with `tokio::time::timeout` — never let network calls hang indefinitely.
7. Use `Pin<Box<dyn Future>>` only when you need trait objects; prefer generics otherwise.
8. Graceful shutdown: listen for `tokio::signal::ctrl_c()` and propagate via `CancellationToken`.

## Patterns
```rust
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

async fn worker(mut rx: mpsc::Receiver<Job>, cancel: CancellationToken) {
    loop {
        tokio::select! {
            Some(job) = rx.recv() => {
                if let Err(e) = process(job).await {
                    tracing::error!(?e, "job failed");
                }
            }
            _ = cancel.cancelled() => {
                tracing::info!("shutting down worker");
                break;
            }
        }
    }
}
```

## Anti-Patterns
- Don't use `std::sync::Mutex` in async code — it blocks the executor thread.
- Don't spawn unbounded tasks without back-pressure — use semaphores or bounded channels.
- Don't ignore cancellation — always handle graceful shutdown in long-running services.
]],
			},
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
			{
				name = "ts-api-patterns",
				content = [[
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
]],
			},
			{
				name = "ts-testing-patterns",
				content = [[
# TypeScript Testing Patterns

## Overview
Testing strategies for TypeScript APIs: AAA pattern, mocking, integration tests with supertest, and test organization.

## Guidelines
1. Follow the AAA pattern: Arrange (setup), Act (execute), Assert (verify) — clearly separated.
2. Name tests as `should <expected behavior> when <condition>`.
3. Use `vitest` or `jest` with `ts-jest`; prefer `vitest` for new projects.
4. Mock external dependencies (databases, APIs) at the boundary — not internal modules.
5. Write integration tests with `supertest` that hit real routes with an in-memory database.
6. Use factory functions for test data — avoid copy-pasting fixtures.
7. Test error paths explicitly: invalid input, missing auth, not found, rate limits.
8. Keep tests fast: mock network calls, use in-memory stores, parallelize where safe.

## Patterns
```typescript
import request from "supertest";
import { createApp } from "../app";
import { createTestDb } from "./helpers/db";

describe("POST /users", () => {
  const db = createTestDb();
  const app = createApp({ db });

  it("should create user when input is valid", async () => {
    const input = { email: "test@example.com", name: "Test User" };
    const res = await request(app).post("/users").send(input);
    expect(res.status).toBe(201);
    expect(res.body).toMatchObject({ email: input.email });
  });

  it("should return 400 when email is invalid", async () => {
    const res = await request(app).post("/users").send({ email: "bad", name: "X" });
    expect(res.status).toBe(400);
  });
});
```

## Anti-Patterns
- Don't test implementation details (private methods, internal state) — test behavior.
- Don't share mutable state between tests — each test should set up its own data.
- Don't skip error-path tests — they catch the bugs that matter most in production.
]],
			},
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
			{
				name = "docker-patterns",
				content = [[
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
]],
			},
			{
				name = "ci-cd-patterns",
				content = [[
# CI/CD Patterns

## Overview
Pipeline design for continuous integration and deployment: stages, caching, secrets management, matrix builds, and deployment strategies.

## Guidelines
1. Pipeline stages: lint → test → build → security scan → deploy. Fail fast on early stages.
2. Cache dependencies between runs: `node_modules`, Go module cache, pip cache, Docker layers.
3. Use matrix builds to test across multiple OS/runtime versions in parallel.
4. Never hardcode secrets — use the CI platform's secret store and inject as environment variables.
5. Pin action/image versions with SHA hashes, not mutable tags.
6. Run security scanning (SAST, dependency audit) on every PR, not just main.
7. Use deployment gates: require manual approval for production, auto-deploy to staging.
8. Keep pipeline config DRY: use reusable workflows/templates for shared steps.

## Patterns
```yaml
# GitHub Actions example
jobs:
  test:
    strategy:
      matrix:
        node: [18, 20, 22]
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: ${{ matrix.node }}
          cache: npm
      - run: npm ci
      - run: npm test
  deploy:
    needs: test
    if: github.ref == 'refs/heads/main'
    environment: production
    steps:
      - run: ./deploy.sh
```

## Anti-Patterns
- Don't skip CI for "small changes" — all changes go through the pipeline.
- Don't store secrets in repo files or environment variable definitions in YAML.
- Don't deploy without automated tests passing — no manual overrides for production.
]],
			},
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
			{
				name = "neovim-lua",
				content = [[
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
]],
			},
			{
				name = "neovim-testing",
				content = [[
# Neovim Plugin Testing

## Overview
Testing patterns for Neovim plugins: headless testing, test harnesses, mocking vim APIs, and CI integration.

## Guidelines
1. Run tests headless: `nvim --headless -u NONE -c "lua dofile('test.lua')"`.
2. Use a minimal test harness with `assert`-based checks and a report function.
3. Mock `vim.fn`, `vim.api`, and `vim.notify` when testing pure logic without a running editor.
4. Test buffer operations by creating scratch buffers: `vim.api.nvim_create_buf(false, true)`.
5. Isolate tests: reset module state with `package.loaded["module"] = nil` between test files.
6. Test user commands by invoking them with `vim.cmd` and checking side effects.
7. Use `vim.schedule_wrap` to test async code in headless mode.
8. Run tests in CI with a pinned Neovim version (nightly or stable).

## Patterns
```lua
-- Minimal test harness
_T = { pass = 0, fail = 0 }
function _T.check(label, condition)
  if condition then
    _T.pass = _T.pass + 1
  else
    _T.fail = _T.fail + 1
    io.stderr:write("FAIL: " .. label .. "\n")
  end
end
function _T.report()
  print(string.format("%d passed, %d failed", _T.pass, _T.fail))
  os.exit(_T.fail > 0 and 1 or 0)
end

-- Test example
local M = require("myplugin.core")
_T.check("parse returns table", type(M.parse("input")) == "table")
_T.report()
```

## Anti-Patterns
- Don't require a full Neovim config for tests — use `-u NONE` for isolation.
- Don't test by visual inspection — automate all assertions.
- Don't skip CI — headless tests catch regressions that manual testing misses.
]],
			},
		},
	},

	----------------------------------------------------------------
	-- UI Design Workflow (Kit)
	----------------------------------------------------------------
	{
		name = "ui-design",
		display = "UI Design Workflow",
		description = "Design references, UI components, and UX guidelines",
		project_types = { "react", "nextjs", "vue" },
		skills = {
			{
				name = "ui-ux-guidelines",
				content = [[
# UI/UX Guidelines

## Overview
Design principles and component patterns for building consistent, accessible user interfaces.

## Guidelines
1. Follow a design system: consistent spacing (4/8px grid), typography scale, and color palette.
2. Accessibility first: semantic HTML, ARIA labels, keyboard navigation, color contrast (WCAG 2.1 AA).
3. Mobile-first responsive: design for smallest viewport, then add breakpoints.
4. Component composition: small, reusable primitives (`Button`, `Input`, `Card`) composed into layouts.
5. Use design tokens (CSS custom properties) for colors, spacing, and typography.
6. Loading states: skeleton screens over spinners, optimistic updates where safe.
7. Error states: clear messages with recovery actions, not generic "Something went wrong".
8. Animations: 200-300ms transitions, respect `prefers-reduced-motion`.

## Patterns
- Group related form fields with `<fieldset>` and `<legend>`.
- Use `<dialog>` for modals — handles focus trap and backdrop.
- Toast notifications: auto-dismiss info, persist errors.
- Empty states: helpful illustration + call to action.

## Anti-Patterns
- Don't disable buttons without explaining why (use tooltips).
- Don't rely on color alone to convey meaning — add icons or text.
- Don't use `div` soup — use semantic elements (`nav`, `main`, `section`, `article`).
]],
			},
			{
				name = "accessibility-checklist",
				content = [[
# Accessibility Checklist

## Overview
WCAG 2.1 compliance patterns: semantic HTML, ARIA attributes, keyboard navigation, color contrast, and screen reader support.

## Guidelines
1. Use semantic HTML elements: `<button>`, `<nav>`, `<main>`, `<form>`, `<label>` — not `<div onClick>`.
2. All interactive elements must be keyboard-accessible: Tab to focus, Enter/Space to activate, Escape to dismiss.
3. Color contrast: minimum 4.5:1 for normal text, 3:1 for large text (WCAG AA).
4. Provide `alt` text for all images; use `alt=""` for decorative images.
5. Use ARIA attributes only when native HTML semantics are insufficient: `aria-label`, `aria-expanded`, `aria-live`.
6. Focus management: move focus to modals when opened, return focus when closed.
7. Form inputs must have associated `<label>` elements — use `htmlFor`/`for` attribute.
8. Test with screen readers (VoiceOver, NVDA) and keyboard-only navigation.

## Patterns
- Use `<dialog>` for modals — provides built-in focus trapping and Escape handling.
- Use `aria-live="polite"` for dynamic content updates (notifications, loading states).
- Use `role="alert"` for error messages that need immediate attention.
- Use `prefers-reduced-motion` media query to disable animations for sensitive users.

## Anti-Patterns
- Don't use `tabindex > 0` — it creates a confusing tab order. Use 0 or -1 only.
- Don't hide content with `display: none` if screen readers should read it — use `sr-only` class.
- Don't rely on hover states for essential information — they are inaccessible on touch devices.
]],
			},
		},
		mcp_servers = {
			{
				name = "21st-dev",
				command = "npx",
				args = { "-y", "21st-dev-mcp@latest" },
				env = { "TWENTY_FIRST_API_KEY" },
			},
		},
		agent_instructions = [[When building UI components, prefer querying the 21st.dev MCP server for component examples and design tokens before writing markup from scratch. Use the design system's spacing and color tokens. Always include aria-labels for interactive elements and test with keyboard-only navigation.]],
		urls = {
			{ name = "material-design", url = "https://m3.material.io/develop/web" },
		},
	},

	----------------------------------------------------------------
	-- API Backend (Kit)
	----------------------------------------------------------------
	{
		name = "api-backend",
		display = "API Backend Workflow",
		description = "API design patterns, security, and schema-first development",
		project_types = { "node", "typescript", "express", "fastify", "go", "python" },
		skills = {
			{
				name = "api-security",
				content = [[
# API Security

## Overview
Security patterns for backend APIs: authentication, authorization, input validation, and common vulnerabilities.

## Guidelines
1. Validate and sanitize all input at the API boundary — never trust client data.
2. Use parameterized queries for all database operations — no string interpolation.
3. Rate-limit endpoints: 100 req/min for auth, 1000 req/min for reads, 60 req/min for writes.
4. JWT: short expiry (15min access, 7d refresh), rotate signing keys, validate `iss` and `aud`.
5. CORS: explicit origin allowlist, never `*` in production.
6. Secrets: environment variables only — never in code, config files, or logs.
7. Logging: log auth events and errors, never log tokens, passwords, or PII.
8. Headers: set `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, `Strict-Transport-Security`.

## Anti-Patterns
- Don't roll your own crypto or auth — use well-tested libraries.
- Don't return stack traces in production error responses.
- Don't store passwords in plain text — use bcrypt/argon2 with cost factor >= 12.
]],
			},
			{
				name = "api-versioning",
				content = [[
# API Versioning

## Overview
Strategies for versioning APIs: URL-based vs header-based, deprecation policies, migration guides, and backward compatibility.

## Guidelines
1. Choose one versioning strategy and be consistent: URL path (`/v1/users`) or header (`Accept: application/vnd.api+json;version=1`).
2. URL versioning is simpler and more discoverable; header versioning is more RESTful.
3. Never break existing clients: additive changes (new fields, new endpoints) don't need a new version.
4. Breaking changes require a new version: removing fields, changing types, altering semantics.
5. Deprecate before removing: announce deprecation with `Sunset` header and a timeline (minimum 6 months).
6. Maintain at most 2 active versions — sunset older versions aggressively.
7. Document migration guides between versions with concrete before/after examples.
8. Use feature flags internally to serve multiple versions from the same codebase.

## Patterns
- Add `Deprecation: true` and `Sunset: <date>` headers to deprecated endpoints.
- Return `Link` header pointing to the new version of deprecated endpoints.
- Use API gateway routing to direct traffic to version-specific handlers.
- Version response schemas independently from endpoint paths when possible.

## Anti-Patterns
- Don't version every minor change — only version on breaking changes.
- Don't maintain more than 2 major versions simultaneously — the maintenance cost is too high.
- Don't remove fields without a deprecation period — clients will break silently.
]],
			},
		},
		agent_instructions = [[Follow a schema-first API design approach: define the API contract (OpenAPI/Swagger or GraphQL schema) before implementing handlers. Validate all request bodies against the schema. Use proper HTTP status codes (201 for creation, 204 for deletion, 422 for validation errors). Always include request ID in responses for tracing.]],
	},

	----------------------------------------------------------------
	-- Data Pipeline (Kit)
	----------------------------------------------------------------
	{
		name = "data-pipeline",
		display = "Data Pipeline Workflow",
		description = "Data pipeline patterns, quality checks, and processing best practices",
		project_types = { "python", "ml" },
		skills = {
			{
				name = "data-pipeline-patterns",
				content = [[
# Data Pipeline Patterns

## Overview
Guidelines for building reliable data pipelines: ingestion, transformation, validation, and observability.

## Guidelines
1. Idempotent operations: re-running a pipeline with the same input produces the same output.
2. Schema validation at ingestion: reject malformed records early with clear error messages.
3. Partition data by date/source for efficient reprocessing and backfills.
4. Log row counts at each stage: input, filtered, transformed, output — detect data loss early.
5. Use checksums or hashes to detect duplicate records.
6. Handle nulls explicitly: define default values or rejection rules per field.
7. Separate extraction, transformation, and loading into distinct stages (ETL or ELT).
8. Store raw data immutably — only transform copies.

## Patterns
```python
# Validation at ingestion
def validate_record(record: dict) -> tuple[bool, str]:
    required = ["id", "timestamp", "value"]
    for field in required:
        if field not in record:
            return False, f"Missing required field: {field}"
    if not isinstance(record["value"], (int, float)):
        return False, f"Invalid value type: {type(record['value'])}"
    return True, ""
```

## Anti-Patterns
- Don't silently drop invalid records — log them to a dead-letter queue.
- Don't modify raw source data — keep an immutable copy.
- Don't run pipelines without monitoring: alert on row count drops > 10%.
]],
			},
			{
				name = "data-observability",
				content = [[
# Data Observability

## Overview
Monitoring data pipelines: metrics collection, schema drift detection, alerting, data lineage, and freshness tracking.

## Guidelines
1. Track freshness: alert when a table hasn't been updated within its expected SLA.
2. Monitor volume: compare row counts against historical baselines — flag drops > 10% or spikes > 200%.
3. Detect schema drift: compare column names, types, and nullable constraints against a registered schema.
4. Track data lineage: record which upstream tables and transforms produce each downstream table.
5. Set up tiered alerting: page for critical pipelines, Slack for warnings, email for informational.
6. Log distribution metrics for key columns: null rate, distinct count, min/max, percentiles.
7. Store observability metadata alongside data: pipeline run ID, timestamp, source version.
8. Build dashboards showing pipeline health, freshness, and data quality scores over time.

## Patterns
```python
def check_freshness(table_name: str, max_age_hours: int) -> bool:
    last_updated = get_table_metadata(table_name).last_modified
    age = (datetime.utcnow() - last_updated).total_seconds() / 3600
    if age > max_age_hours:
        alert(f"{table_name} is stale: {age:.1f}h old (SLA: {max_age_hours}h)")
        return False
    return True

def check_volume(table_name: str, expected_min: int) -> bool:
    count = get_row_count(table_name)
    if count < expected_min:
        alert(f"{table_name} has {count} rows (expected >= {expected_min})")
        return False
    return True
```

## Anti-Patterns
- Don't monitor only pipeline success/failure — a successful run can produce bad data.
- Don't set alerts without baselines — you need historical context to define thresholds.
- Don't skip lineage tracking — when something breaks, you need to trace the impact.
]],
			},
		},
		agent_instructions = [[When building data pipelines, always add data quality checks between stages: validate schemas, check for null rates, compare row counts. Log metrics at each pipeline stage. Use idempotent writes (upsert) so pipelines can be safely re-run. Include a dead-letter queue or error table for records that fail validation.]],
	},

	----------------------------------------------------------------
	-- Java/Spring
	----------------------------------------------------------------
	{
		name = "java-spring",
		display = "Java Spring Boot",
		description = "Spring Boot patterns, dependency injection, and Java testing",
		project_types = { "java", "kotlin" },
		skills = {
			{
				name = "spring-boot-patterns",
				content = [[
# Spring Boot Patterns

## Overview
Guidelines for building Spring Boot applications: project structure, dependency injection, configuration, and REST controllers.

## Guidelines
1. Use constructor injection exclusively — never field injection with `@Autowired`.
2. Layer architecture: Controller → Service → Repository. Controllers handle HTTP, services hold logic, repositories do data access.
3. Use `@ConfigurationProperties` for type-safe configuration — not `@Value` for groups of related settings.
4. Return `ResponseEntity<T>` from controllers for explicit status codes and headers.
5. Use `@RestControllerAdvice` for centralized exception handling — map exceptions to HTTP responses.
6. Profile-specific config: `application-dev.yml`, `application-prod.yml` — never hardcode environment-specific values.
7. Use `@Transactional` at the service layer, not the repository or controller layer.
8. Prefer records for DTOs and value objects in Java 17+.

## Patterns
```java
@RestController
@RequestMapping("/api/v1/users")
public class UserController {
    private final UserService userService;

    public UserController(UserService userService) {
        this.userService = userService;
    }

    @GetMapping("/{id}")
    public ResponseEntity<UserDto> getUser(@PathVariable Long id) {
        return userService.findById(id)
            .map(ResponseEntity::ok)
            .orElse(ResponseEntity.notFound().build());
    }
}
```

## Anti-Patterns
- Don't put business logic in controllers — keep them thin.
- Don't use `@Autowired` on fields — it makes testing harder and hides dependencies.
- Don't catch exceptions in every controller method — use `@RestControllerAdvice`.
]],
			},
			{
				name = "java-testing",
				content = [[
# Java Testing Patterns

## Overview
Testing strategies for Java applications: JUnit 5, Mockito, integration tests with Spring Boot Test, and test organization.

## Guidelines
1. Use JUnit 5 (`@Test`, `@BeforeEach`, `@DisplayName`) — never JUnit 4 in new code.
2. Use Mockito for unit tests: `@Mock` for dependencies, `@InjectMocks` for the class under test.
3. Use `@SpringBootTest` sparingly — prefer `@WebMvcTest` for controller tests, `@DataJpaTest` for repository tests.
4. Name tests with `@DisplayName` describing the behavior: "should return 404 when user not found".
5. Follow AAA pattern: Arrange (given), Act (when), Assert (then) — use BDDMockito for readability.
6. Use Testcontainers for integration tests with real databases — not H2 for production Postgres.
7. Use `@ParameterizedTest` with `@CsvSource` or `@MethodSource` for data-driven tests.
8. Assert with AssertJ for fluent, readable assertions.

## Patterns
```java
@ExtendWith(MockitoExtension.class)
class UserServiceTest {
    @Mock UserRepository userRepository;
    @InjectMocks UserService userService;

    @Test
    @DisplayName("should return user when found")
    void findById_found() {
        var user = new User(1L, "Alice");
        given(userRepository.findById(1L)).willReturn(Optional.of(user));

        var result = userService.findById(1L);

        assertThat(result).isPresent().contains(user);
    }
}
```

## Anti-Patterns
- Don't use `@SpringBootTest` for unit tests — it loads the entire context and is slow.
- Don't test private methods — test through public API.
- Don't use `Thread.sleep` in tests — use Awaitility for async assertions.
]],
			},
		},
	},

	----------------------------------------------------------------
	-- Python Web
	----------------------------------------------------------------
	{
		name = "python-web",
		display = "Python Web Frameworks",
		description = "FastAPI and Django patterns for web applications",
		project_types = { "python", "python-web" },
		skills = {
			{
				name = "fastapi-patterns",
				content = [[
# FastAPI Patterns

## Overview
Guidelines for building FastAPI applications: route design, dependency injection, validation, and async patterns.

## Guidelines
1. Use Pydantic models for all request/response schemas — never raw dicts.
2. Use `Depends()` for dependency injection: database sessions, auth, config.
3. Use `async def` for I/O-bound endpoints; plain `def` for CPU-bound (runs in threadpool).
4. Group routes with `APIRouter` — one router per domain (users, orders, auth).
5. Use `HTTPException` for error responses with appropriate status codes.
6. Use `BackgroundTasks` for fire-and-forget work (email, logging) — not for critical operations.
7. Use `lifespan` context manager for startup/shutdown (DB connections, caches).
8. Set `response_model` on endpoints to control serialization and auto-generate OpenAPI docs.

## Patterns
```python
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, EmailStr

router = APIRouter(prefix="/users", tags=["users"])

class CreateUser(BaseModel):
    email: EmailStr
    name: str

@router.post("/", response_model=UserOut, status_code=201)
async def create_user(data: CreateUser, db: Session = Depends(get_db)):
    if await db.get_user_by_email(data.email):
        raise HTTPException(409, "Email already registered")
    user = await db.create_user(data)
    return user
```

## Anti-Patterns
- Don't use `@app.on_event` — use `lifespan` context manager instead (deprecated since 0.93).
- Don't mix sync and async DB calls — pick one and be consistent.
- Don't skip Pydantic validation by accepting raw dicts — you lose type safety and docs.
]],
			},
			{
				name = "django-patterns",
				content = [[
# Django Patterns

## Overview
Django best practices: project structure, views, models, ORM queries, and security.

## Guidelines
1. Use class-based views for CRUD, function views for custom logic — be consistent per app.
2. Fat models, thin views: put business logic in model methods or service modules, not views.
3. Use `select_related` and `prefetch_related` to avoid N+1 queries — profile with Django Debug Toolbar.
4. Use Django forms or serializers for validation — never validate in views manually.
5. Use migrations for all schema changes — never modify the database directly.
6. Use `get_object_or_404` for detail views — don't catch `DoesNotExist` manually.
7. Use `django.conf.settings` for configuration — keep secrets in environment variables.
8. Use `reverse()` for URL generation — never hardcode URL paths.

## Patterns
```python
# Service layer pattern
class OrderService:
    @staticmethod
    def create_order(user, items):
        with transaction.atomic():
            order = Order.objects.create(user=user, status="pending")
            for item in items:
                OrderItem.objects.create(order=order, **item)
            order.total = sum(i.price * i.quantity for i in order.items.all())
            order.save()
        return order

# View using service
class OrderCreateView(LoginRequiredMixin, CreateView):
    def form_valid(self, form):
        order = OrderService.create_order(self.request.user, form.cleaned_data["items"])
        return redirect("order-detail", pk=order.pk)
```

## Anti-Patterns
- Don't put queries in templates — compute data in views and pass via context.
- Don't use raw SQL unless the ORM genuinely can't express the query.
- Don't skip migrations — they are your database schema's source of truth.
]],
			},
		},
	},

	----------------------------------------------------------------
	-- Testing Fundamentals
	----------------------------------------------------------------
	{
		name = "testing-fundamentals",
		display = "Testing Fundamentals",
		description = "Cross-language testing strategy, mocking patterns, and test architecture",
		project_types = { "node", "typescript", "python", "go", "rust", "java" },
		skills = {
			{
				name = "test-strategy",
				content = [[
# Test Strategy

## Overview
Guidelines for building a testing strategy: the test pyramid, what to test at each level, and balancing coverage with speed.

## Guidelines
1. Follow the test pyramid: many unit tests, fewer integration tests, minimal E2E tests.
2. Unit tests: test a single function/class in isolation, fast (< 10ms each), no I/O.
3. Integration tests: test module boundaries (API routes, database queries, service interactions).
4. E2E tests: test critical user flows only — login, purchase, signup. Keep under 20.
5. Test behavior, not implementation: assert what the code does, not how it does it.
6. Coverage target: 80% line coverage is a good baseline — don't chase 100%.
7. Tests are documentation: a new developer should understand the system by reading tests.
8. Fix flaky tests immediately — a test suite with intermittent failures is worse than no tests.

## Patterns
- Use test fixtures/factories for data setup — avoid test interdependence.
- Use `beforeEach`/`setUp` for common setup, not shared mutable state.
- Organize tests to mirror source structure: `src/users/service.ts` → `tests/users/service.test.ts`.
- Run fast unit tests on every save; integration tests in CI.

## Anti-Patterns
- Don't write tests that pass when the code is broken (tautological tests).
- Don't test framework behavior (e.g., "does Express route to my handler?") — test your logic.
- Don't mock everything — over-mocking makes tests pass but misses real bugs.
]],
			},
			{
				name = "mocking-patterns",
				content = [[
# Mocking Patterns

## Overview
When and how to use mocks, stubs, and fakes: boundary mocking, avoiding over-mocking, and keeping tests maintainable.

## Guidelines
1. Mock at boundaries: external APIs, databases, file systems, clocks — not internal modules.
2. Use stubs for simple return values, mocks when you need to verify interactions.
3. Prefer fakes (in-memory implementations) over mocks for complex dependencies like databases.
4. Mock the interface, not the implementation — depend on abstractions.
5. Verify mock interactions sparingly: assert outcomes, not that specific methods were called.
6. Reset mocks between tests to prevent state leakage.
7. Use dependency injection to make code testable — don't monkey-patch modules.
8. If you need more than 3 mocks in a test, the code under test may have too many dependencies.

## Patterns
```python
# Fake over mock: in-memory repository
class FakeUserRepo:
    def __init__(self):
        self._users = {}
        self._next_id = 1

    def create(self, data):
        user = User(id=self._next_id, **data)
        self._users[self._next_id] = user
        self._next_id += 1
        return user

    def get(self, user_id):
        return self._users.get(user_id)

def test_create_user():
    repo = FakeUserRepo()
    service = UserService(repo)
    user = service.create({"name": "Alice", "email": "alice@example.com"})
    assert user.name == "Alice"
    assert repo.get(user.id) == user
```

## Anti-Patterns
- Don't mock what you don't own — wrap third-party libraries in your own interface first.
- Don't assert on mock call counts unless the number of calls is the actual behavior being tested.
- Don't use mocks to test private/internal methods — test through the public API.
]],
			},
		},
	},

	----------------------------------------------------------------
	-- DevOps/Infrastructure
	----------------------------------------------------------------
	{
		name = "devops-infra",
		display = "DevOps Infrastructure",
		description = "Kubernetes and Terraform patterns for infrastructure management",
		project_types = { "docker", "terraform" },
		skills = {
			{
				name = "kubernetes-patterns",
				content = [[
# Kubernetes Patterns

## Overview
Patterns for deploying and managing applications on Kubernetes: resource definitions, health checks, scaling, and security.

## Guidelines
1. Always set resource requests and limits: prevents noisy-neighbor issues and enables autoscaling.
2. Use liveness probes for deadlock detection, readiness probes for traffic routing — they serve different purposes.
3. Use Deployments for stateless workloads, StatefulSets for databases, DaemonSets for node-level agents.
4. Store configuration in ConfigMaps, secrets in Secrets (encrypted at rest with KMS).
5. Use namespaces to isolate environments (dev, staging, prod) or teams.
6. Set `PodDisruptionBudget` for critical services to ensure availability during node drains.
7. Use `NetworkPolicy` to restrict pod-to-pod communication — default-deny, explicit-allow.
8. Pin image tags to digests in production — never use `latest`.

## Patterns
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
spec:
  replicas: 3
  selector:
    matchLabels:
      app: api
  template:
    spec:
      containers:
        - name: api
          image: myapp/api@sha256:abc123
          resources:
            requests: { cpu: 100m, memory: 128Mi }
            limits: { cpu: 500m, memory: 256Mi }
          readinessProbe:
            httpGet: { path: /health, port: 8080 }
            periodSeconds: 5
          livenessProbe:
            httpGet: { path: /health, port: 8080 }
            initialDelaySeconds: 15
```

## Anti-Patterns
- Don't run containers as root — set `securityContext.runAsNonRoot: true`.
- Don't skip resource limits — unbounded pods can starve the node.
- Don't use `hostNetwork` or `hostPort` unless absolutely necessary.
]],
			},
			{
				name = "terraform-patterns",
				content = [[
# Terraform Patterns

## Overview
Infrastructure as code with Terraform: module design, state management, variables, and team workflows.

## Guidelines
1. Use modules for reusable infrastructure components — one module per logical resource group.
2. Store state remotely (S3 + DynamoDB, GCS, Terraform Cloud) — never commit `.tfstate` to git.
3. Use `terraform plan` in CI and require approval before `terraform apply`.
4. Pin provider versions: `required_providers` with exact version constraints.
5. Use variables with descriptions and validation rules — never hardcode values.
6. Use `data` sources to reference existing resources — don't import and manage everything.
7. Tag all resources with `environment`, `team`, `managed-by=terraform` for cost tracking and auditing.
8. Use workspaces or directory structure to separate environments — not variable toggling.

## Patterns
```hcl
# Module structure
module "vpc" {
  source = "./modules/vpc"

  cidr_block  = var.vpc_cidr
  environment = var.environment
  tags        = local.common_tags
}

# Variable with validation
variable "environment" {
  type        = string
  description = "Deployment environment"
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be dev, staging, or prod."
  }
}
```

## Anti-Patterns
- Don't use `terraform apply -auto-approve` in production — always review the plan.
- Don't store secrets in Terraform variables — use a secrets manager and `data` sources.
- Don't create one giant root module — break infrastructure into composable modules.
]],
			},
		},
	},
}

return M
