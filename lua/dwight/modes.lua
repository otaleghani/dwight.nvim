-- dwight/modes.lua
-- Built-in operation modes. Each mode defines a task description.
-- The /fix mode auto-injects last build/test output for error-driven fixing.

local M = {}

M.registry = {
  document = {
    name = "Document", icon = "📝",
    description = "Add documentation and inline comments",
    task = [[
Add documentation to the code below:
- Doc-comments above functions, methods, classes, and modules.
- Short inline comments for non-obvious logic. Don't comment trivial lines.
- Keep original code exactly as-is — only add comments.
- Use the idiomatic doc style for this language.
- Comments explain WHY, not WHAT.
]],
  },

  refactor = {
    name = "Refactor", icon = "🔧",
    description = "Improve structure and readability",
    task = [[
Refactor the code below for better structure, readability, and maintainability:
- Improve naming, reduce nesting, extract helpers where beneficial.
- Preserve external behavior — same inputs and outputs.
- Don't add features or change the public API.
- Respect existing code style.
]],
  },

  optimize = {
    name = "Optimize", icon = "⚡",
    description = "Performance optimization",
    task = [[
Optimize the code below for better performance:
- Fix performance bottlenecks. Prefer algorithmic improvements.
- Preserve correctness — identical results required.
- If no meaningful optimization exists, return unchanged.
]],
  },

  fix_bugs = {
    name = "Fix Bugs", icon = "🐛",
    description = "Find and fix bugs",
    task = [[
Find and fix bugs in the code below:
- Fix every bug, edge case, and potential runtime error.
- Pay attention to LSP diagnostics in the context.
- Don't refactor or change style — only fix bugs.
- If no bugs found, return unchanged.
]],
  },

  security = {
    name = "Security", icon = "🔒",
    description = "Security audit and fixes",
    task = [[
Audit and fix security vulnerabilities:
- Check for injection, XSS, CSRF, path traversal, hardcoded secrets, race conditions.
- Fix every vulnerability found.
- Don't change functionality — only fix security issues.
- If none found, return unchanged.
]],
  },

  explain = {
    name = "Explain", icon = "💡",
    description = "Add explanatory comments",
    task = [[
Add detailed explanatory comments to the code below:
- Explain logic, patterns, and design decisions.
- Do NOT modify any code — only add comments.
- Reference design patterns and language idioms where relevant.
]],
  },

  brainstorm = {
    name = "Brainstorm", icon = "🧠",
    description = "Brainstorm ideas as comments",
    task = [[
Analyze the code and brainstorm improvements as comments. Do NOT change code.
Add comments like:
  // [idea] Could use a strategy pattern here
  // [idea] Consider caching this — called in a hot loop
  // [tradeoff] Recursion is cleaner but iterative handles deep trees better

Consider: architecture, performance, testability, error handling, alternatives.
Be specific. Reference the actual code. Return original code with comments added.
]],
  },

  code = {
    name = "Code", icon = "💻",
    description = "Implement stubs and TODOs",
    task = [[
Implement the code below. If it's a stub, signature, TODO, or incomplete — write the full working code.
- Follow existing signatures and types exactly.
- Match code style and conventions from the surrounding context.
- Handle edge cases and errors properly.
- Add brief comments for non-obvious logic.
]],
  },

  fix = {
    name = "Fix from Output", icon = "🔨",
    description = "Fix based on build/test output",
    inject_run_output = true,
    task = [[
The code below has errors from a build or test run. The output is included in the context.
- Read the error output carefully.
- Fix the code to resolve ALL errors shown in the output.
- Don't change unrelated code.
- If the errors are in tests, fix the source code, not the tests (unless the tests are selected).
]],
  },
}

function M.get(name)
  return M.registry[name]
end

function M.list()
  local names = {}
  for k in pairs(M.registry) do names[#names + 1] = k end
  table.sort(names)
  return names
end

function M.register(name, mode)
  assert(mode.task, "Mode must have a 'task' field")
  mode.name = mode.name or name
  mode.icon = mode.icon or "🔹"
  mode.description = mode.description or ""
  M.registry[name] = mode
end

return M
