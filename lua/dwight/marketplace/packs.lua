-- dwight/marketplace/packs.lua
-- Curated skill pack registry.

local M = {}

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
		},
	},
}

return M
