-- dwight/budget.lua
-- Smart context budget management.
-- Prioritizes context by importance and trims to fit the model's context window.

local M = {}

-- Approximate token limits per model family (conservative, leaves room for response)
local MODEL_BUDGETS = {
  -- Anthropic
  haiku     = 150000,
  sonnet    = 150000,
  opus      = 150000,
  -- OpenAI
  ["gpt-4o"]        = 100000,
  ["gpt-4o-mini"]   = 100000,
  ["gpt-4-turbo"]   = 100000,
  ["gpt-4"]         = 6000,
  ["gpt-3.5-turbo"] = 12000,
  -- Gemini
  flash     = 800000,
  pro       = 800000,
  -- Default fallback
  default   = 100000,
}

--- Estimate tokens from text (1 token ≈ 4 chars).
local function estimate_tokens(text)
  if not text then return 0 end
  return math.ceil(#text / 4)
end

--- Get budget for current model.
function M.get_budget()
  local cfg = require("dwight").config
  local model = (cfg.model or ""):lower()

  for pattern, budget in pairs(MODEL_BUDGETS) do
    if model:find(pattern, 1, true) then return budget end
  end

  return MODEL_BUDGETS.default
end

--------------------------------------------------------------------
-- Context prioritization
--------------------------------------------------------------------

-- Priority order (higher = more important, kept first):
-- 1. User instructions (never trimmed)
-- 2. Selected code (never trimmed)
-- 3. Mode task prompt (never trimmed)
-- 4. LSP diagnostics
-- 5. Test context (TDD)
-- 6. Build/test output
-- 7. Feature specs
-- 8. Git context
-- 9. Library refs
-- 10. Skills
-- 11. Symbols (cross-file context)
-- 12. MCP resources
-- 13. Architecture.md

--- Trim a context section to fit within max_tokens.
local function trim_section(text, max_tokens)
  if not text then return nil end
  local tokens = estimate_tokens(text)
  if tokens <= max_tokens then return text end

  -- Trim from the end, keeping first part
  local max_chars = max_tokens * 4
  return text:sub(1, max_chars) .. "\n[... trimmed to fit context budget]"
end

--- Apply budget to optional context sections.
--- Takes a table of { priority, name, text } entries and a total budget.
--- Returns trimmed entries that fit.
function M.apply(sections, budget_tokens)
  if not sections or #sections == 0 then return {} end

  budget_tokens = budget_tokens or M.get_budget()

  -- Sort by priority (highest first = most important)
  table.sort(sections, function(a, b) return a.priority > b.priority end)

  local used = 0
  local result = {}

  for _, section in ipairs(sections) do
    local tokens = estimate_tokens(section.text)
    if tokens == 0 then goto continue end

    local remaining = budget_tokens - used

    if remaining <= 0 then
      -- Budget exhausted — skip lower-priority sections
      break
    elseif tokens <= remaining then
      -- Fits entirely
      result[#result + 1] = section
      used = used + tokens
    else
      -- Partial fit — trim to remaining budget (min 500 tokens to be useful)
      if remaining >= 500 then
        local trimmed = trim_section(section.text, remaining)
        result[#result + 1] = {
          priority = section.priority,
          name = section.name,
          text = trimmed,
        }
        used = used + remaining
      end
      break
    end

    ::continue::
  end

  return result
end

--- Convenience: build a section entry.
function M.section(priority, name, text)
  return { priority = priority, name = name, text = text }
end

-- Priority constants
M.PRIORITY = {
  LSP_DIAGNOSTICS = 90,
  TEST_CONTEXT    = 85,
  RUN_OUTPUT      = 80,
  FEATURES        = 70,
  GIT_CONTEXT     = 65,
  LIBS            = 60,
  SKILLS          = 50,
  SYMBOLS         = 40,
  MCP_RESOURCES   = 35,
  ARCHITECTURE    = 30,
}

return M
