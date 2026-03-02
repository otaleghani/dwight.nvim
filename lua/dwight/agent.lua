-- dwight/agent.lua
-- Autonomous coding agent using agentic tool-use loop.
-- :DwightAgent generates and executes tasks via Claude Code / Codex / Gemini.
-- Session learning: extracts lessons from past runs to improve future ones.

local M = {}

local api = vim.api
local _flatten = require("dwight.util").flatten_lines
--------------------------------------------------------------------

local function agent_dir()
  local ok, project = pcall(require, "dwight.project")
  if ok and project.is_initialized() then
    return project.dir() .. "/agent"
  end
  return vim.fn.stdpath("data") .. "/dwight/agent"
end

--------------------------------------------------------------------
-- Project context gathering (used by plan generation and replanning)
--------------------------------------------------------------------

local function gather_project_context()
  local parts = {}

  -- Deep project manifest (go.mod, package.json, Cargo.toml, pyproject.toml)
  pcall(function()
    local context = require("dwight.context")
    local manifest = context.build_xml()
    if manifest then
      -- Trim long dependency lists — agent only needs project name + lang + main deps
      if #manifest > 1500 then
        manifest = manifest:sub(1, 1500) .. "\n... (deps truncated)"
      end
      parts[#parts + 1] = manifest
    end
  end)

  -- JIT pragmas (@project, @stack, @constraint, @convention, @feature)
  pcall(function()
    local features = require("dwight.features")
    local xml = features.build_project_context()
    if xml and xml ~= "" then
      parts[#parts + 1] = xml
    end

    local names = features.names()
    if #names > 0 then
      parts[#parts + 1] = "Features: " .. table.concat(names, ", ")
    end
  end)

  -- File tree (brief — just enough for the agent to know the structure)
  pcall(function()
    local bootstrap = require("dwight.bootstrap")
    local scan = bootstrap.scan()
    if scan.tree and #scan.tree > 0 then
      local tree = table.concat(scan.tree, "\n")
      -- Agent plans only need ~40 lines of tree (not 2000 chars)
      local lines = {}
      for line in tree:gmatch("[^\n]+") do
        lines[#lines + 1] = line
        if #lines >= 40 then break end
      end
      if #lines >= 40 then lines[#lines + 1] = "... (truncated)" end
      parts[#parts + 1] = "<project_tree>\n" .. table.concat(lines, "\n") .. "\n</project_tree>"
    end
    -- Entry snippets: max 4, max 500 chars each (agent needs patterns, not full code)
    if scan.entry_snippets then
      local count = 0
      for _, s in ipairs(scan.entry_snippets) do
        if count >= 4 then break end
        local content = s.content
        if #content > 500 then content = content:sub(1, 500) .. "\n// ... (truncated)" end
        parts[#parts + 1] = string.format("<file path=\"%s\">\n%s\n</file>", s.path, content)
        count = count + 1
      end
    end
  end)

  -- Skills, libs, and pragma instructions via integration module
  pcall(function()
    local integration = require("dwight.integration")
    local full_ctx = integration.build_full_context()
    if full_ctx then parts[#parts + 1] = full_ctx end
  end)

  if #parts == 0 then
    return "(no project context detected)"
  end
  return table.concat(parts, "\n\n")
end
--------------------------------------------------------------------
-- Session Learning: extract and store lessons from past sessions
--------------------------------------------------------------------

local LESSON_PROMPT = [=[
Analyze this agent session and extract 1-3 SHORT lessons that would help future similar tasks.

Request: %s
Outcome: %s

Step journal:
%s

For EACH lesson, output ONE line in this exact format:
LESSON: <2-5 keywords> | <one sentence lesson>

Examples:
LESSON: database CRUD migration | Always call AutoMigrate for new models in the Open/Init function
LESSON: CLI interface mock | Mock structs must implement ALL interface methods with exact signatures
LESSON: Go test SQLite | SQLite creates files even for invalid paths; check parent directory exists

Output ONLY LESSON lines. No other text.
]=]

--- Extract lessons from a completed session.
--- Returns a list of { keywords = {...}, text = "..." }.
function M._extract_lessons(session, journal, callback)
  local outcome = session.had_error and "FAILED at step " .. (session.failed_step or "?") or "SUCCESS"

  local journal_text = journal and #journal > 0
    and table.concat(journal, "\n")
    or "(no journal)"

  local prompt = string.format(LESSON_PROMPT, session.request, outcome, journal_text)

  require("dwight.skills")._run_llm(prompt, function(raw, code)
    if code ~= 0 or not raw then
      callback({})
      return
    end

    local lessons = {}
    for line in raw:gmatch("[^\n]+") do
      local kw_str, text = line:match("^LESSON:%s*(.-)%s*|%s*(.+)$")
      if kw_str and text then
        local keywords = {}
        for kw in kw_str:gmatch("%S+") do
          keywords[#keywords + 1] = kw:lower()
        end
        if #keywords > 0 then
          lessons[#lessons + 1] = {
            keywords = keywords,
            text = vim.trim(text),
            request = session.request,
            timestamp = session.timestamp or os.time(),
          }
        end
      end
    end

    callback(lessons)
  end)
end

--- Load lessons index from disk.
function M._load_lessons()
  local path = agent_dir() .. "/lessons.json"
  if vim.fn.filereadable(path) ~= 1 then return {} end

  local f = io.open(path, "r")
  if not f then return {} end
  local content = f:read("*a")
  f:close()

  local ok, data = pcall(vim.json.decode, content)
  if ok and type(data) == "table" then return data end
  return {}
end

--- Save lessons index to disk.
function M._save_lessons(lessons)
  pcall(function()
    local dir = agent_dir()
    vim.fn.mkdir(dir, "p")
    local path = dir .. "/lessons.json"
    local f = io.open(path, "w")
    if f then
      f:write(vim.json.encode(lessons))
      f:close()
    end
  end)
end

--- Find lessons relevant to a request.
--- Returns up to 5 lessons scored by keyword overlap, freshness, and reinforcement.
--- Increments use_count on returned lessons.
function M._find_relevant_lessons(request)
  local all_lessons = M._load_lessons()
  if #all_lessons == 0 then return {} end

  local now = os.time()

  -- Tokenize request
  local req_words = {}
  for word in request:lower():gmatch("%w+") do
    if #word > 2 then req_words[word] = true end
  end

  -- Score each lesson by keyword overlap + freshness + reinforcement
  local scored = {}
  for _, lesson in ipairs(all_lessons) do
    local keyword_score = 0
    local total_kw = #(lesson.keywords or {})
    for _, kw in ipairs(lesson.keywords or {}) do
      if req_words[kw] then keyword_score = keyword_score + 1 end
    end
    if keyword_score > 0 then
      -- Normalize keyword match (0-1)
      local match_ratio = total_kw > 0 and keyword_score / total_kw or 0

      -- Freshness bonus: recent lessons score higher (decays over 30 days)
      local age_days = (now - (lesson.timestamp or 0)) / 86400
      local freshness = math.max(0.1, 1 - age_days / 60)

      -- Reinforcement bonus: lessons seen multiple times are stronger
      local reinforcement = math.min((lesson.reinforced or 1) / 3, 1.5)

      -- Combined score
      local final_score = keyword_score * 2 + match_ratio + freshness * 0.5 + reinforcement * 0.3

      scored[#scored + 1] = { lesson = lesson, score = final_score }
    end
  end

  -- Sort by score descending
  table.sort(scored, function(a, b) return a.score > b.score end)

  -- Return top 5 and track usage
  local results = {}
  local dirty = false
  for i = 1, math.min(5, #scored) do
    local lesson = scored[i].lesson
    lesson.use_count = (lesson.use_count or 0) + 1
    dirty = true
    results[#results + 1] = lesson
  end

  -- Persist updated use counts
  if dirty then
    pcall(function() M._save_lessons(all_lessons) end)
  end

  return results
end

--- Append new lessons to the index with similarity-based deduplication.
--- Similar lessons (high keyword overlap) are merged rather than duplicated.
function M._append_lessons(new_lessons)
  if #new_lessons == 0 then return end

  local all = M._load_lessons()

  --- Compute similarity between two lessons based on keyword overlap.
  --- Returns 0.0 to 1.0 (Jaccard index).
  local function similarity(a, b)
    local set_a, set_b = {}, {}
    for _, kw in ipairs(a.keywords or {}) do set_a[kw] = true end
    for _, kw in ipairs(b.keywords or {}) do set_b[kw] = true end
    local intersection, union = 0, 0
    for k in pairs(set_a) do
      union = union + 1
      if set_b[k] then intersection = intersection + 1 end
    end
    for k in pairs(set_b) do
      if not set_a[k] then union = union + 1 end
    end
    if union == 0 then return 0 end
    return intersection / union
  end

  local added = 0
  for _, lesson in ipairs(new_lessons) do
    -- Find the most similar existing lesson
    local best_sim = 0
    local best_idx = nil
    for i, existing in ipairs(all) do
      local sim = similarity(lesson, existing)
      if sim > best_sim then
        best_sim = sim
        best_idx = i
      end
    end

    if best_sim >= 0.6 and best_idx then
      -- Merge: keep the newer text but combine keywords and boost reinforcement count
      local existing = all[best_idx]
      local merged_kw_set = {}
      for _, kw in ipairs(existing.keywords or {}) do merged_kw_set[kw] = true end
      for _, kw in ipairs(lesson.keywords or {}) do merged_kw_set[kw] = true end
      local merged_kw = {}
      for kw in pairs(merged_kw_set) do merged_kw[#merged_kw + 1] = kw end
      table.sort(merged_kw)

      existing.keywords = merged_kw
      existing.text = lesson.text  -- newer text is likely better
      existing.timestamp = lesson.timestamp or os.time()
      existing.reinforced = (existing.reinforced or 1) + 1
      -- Don't count as "added" since it's a merge
    else
      -- Truly new lesson
      lesson.reinforced = 1
      lesson.use_count = 0
      all[#all + 1] = lesson
      added = added + 1
    end
  end

  -- Evict: keep max 80 lessons. Remove stale + low-use first.
  if #all > 80 then
    M._evict_lessons(all, 80)
  end

  if added > 0 or #new_lessons > 0 then
    M._save_lessons(all)
    if added > 0 then
      vim.notify(string.format("[dwight] 📚 Learned %d lesson(s) from this session.", added), vim.log.levels.INFO)
    end
    local merged = #new_lessons - added
    if merged > 0 then
      vim.notify(string.format("[dwight] 📚 Merged %d lesson(s) with existing knowledge.", merged), vim.log.levels.INFO)
    end
  end
end

--- Evict lessons down to max_count. Priority: stale + low-use + low-reinforcement go first.
function M._evict_lessons(lessons, max_count)
  local now = os.time()
  local thirty_days = 30 * 24 * 3600

  -- Score each lesson: higher = more valuable = keep
  for _, l in ipairs(lessons) do
    local age_days = (now - (l.timestamp or 0)) / 86400
    local freshness = math.max(0, 1 - age_days / 60)  -- decays over 60 days
    local usage = math.min((l.use_count or 0) / 5, 1)  -- caps at 5 uses
    local reinforcement = math.min((l.reinforced or 1) / 3, 1)  -- caps at 3 reinforcements
    l._score = freshness * 0.3 + usage * 0.4 + reinforcement * 0.3
  end

  -- Sort by score ascending (worst first)
  table.sort(lessons, function(a, b) return a._score < b._score end)

  -- Remove excess from the front (lowest scored)
  while #lessons > max_count do
    table.remove(lessons, 1)
  end

  -- Clean up temp scores
  for _, l in ipairs(lessons) do l._score = nil end
end

--- Consolidate lessons: find groups of similar lessons and merge them via LLM.
--- This is the "lesson quality maintenance" operation — call periodically or manually.
--- callback(stats) where stats = { before, after, merged_groups }
function M._consolidate_lessons(callback)
  local all = M._load_lessons()
  if #all < 5 then
    if callback then callback({ before = #all, after = #all, merged_groups = 0 }) end
    return
  end

  --- Compute keyword Jaccard similarity.
  local function similarity(a, b)
    local set_a, set_b = {}, {}
    for _, kw in ipairs(a.keywords or {}) do set_a[kw] = true end
    for _, kw in ipairs(b.keywords or {}) do set_b[kw] = true end
    local intersection, union = 0, 0
    for k in pairs(set_a) do
      union = union + 1
      if set_b[k] then intersection = intersection + 1 end
    end
    for k in pairs(set_b) do
      if not set_a[k] then union = union + 1 end
    end
    if union == 0 then return 0 end
    return intersection / union
  end

  -- Find clusters of similar lessons (greedy clustering)
  local used = {}
  local clusters = {}
  for i = 1, #all do
    if not used[i] then
      local cluster = { i }
      used[i] = true
      for j = i + 1, #all do
        if not used[j] and similarity(all[i], all[j]) >= 0.5 then
          cluster[#cluster + 1] = j
          used[j] = true
        end
      end
      if #cluster >= 2 then
        clusters[#clusters + 1] = cluster
      end
    end
  end

  if #clusters == 0 then
    if callback then callback({ before = #all, after = #all, merged_groups = 0 }) end
    return
  end

  -- Build a prompt to merge each cluster
  local merge_parts = {}
  for ci, cluster in ipairs(clusters) do
    local group_parts = { string.format("Group %d:", ci) }
    for _, idx in ipairs(cluster) do
      local l = all[idx]
      group_parts[#group_parts + 1] = string.format("  - [%s] %s (used %dx, reinforced %dx)",
        table.concat(l.keywords or {}, " "), l.text or "?",
        l.use_count or 0, l.reinforced or 1)
    end
    merge_parts[#merge_parts + 1] = table.concat(group_parts, "\n")
  end

  local prompt = string.format([=[
You have %d groups of similar coding lessons that need to be consolidated.
For each group, produce ONE merged lesson that captures the best wisdom from all entries.

%s

For EACH group, output ONE line:
MERGED: <2-5 keywords> | <one sentence merged lesson>

Output ONLY MERGED lines. No other text.
]=], #clusters, table.concat(merge_parts, "\n\n"))

  require("dwight.skills")._run_llm(prompt, function(raw, code)
    if code ~= 0 or not raw then
      if callback then callback({ before = #all, after = #all, merged_groups = 0, error = "LLM call failed" }) end
      return
    end

    -- Parse merged lessons
    local merged_lessons = {}
    for line in raw:gmatch("[^\n]+") do
      local kw_str, text = line:match("^MERGED:%s*(.-)%s*|%s*(.+)$")
      if kw_str and text then
        local keywords = {}
        for kw in kw_str:gmatch("%S+") do keywords[#keywords + 1] = kw:lower() end
        if #keywords > 0 then
          merged_lessons[#merged_lessons + 1] = {
            keywords = keywords,
            text = vim.trim(text),
            timestamp = os.time(),
            reinforced = 0, -- will sum up below
            use_count = 0,
          }
        end
      end
    end

    -- Replace clustered lessons with merged ones
    -- First: collect indices to remove (from clusters that got merged)
    local remove_set = {}
    for ci, cluster in ipairs(clusters) do
      if merged_lessons[ci] then
        -- Sum up reinforcement and use counts from the cluster
        local total_reinforced = 0
        local total_use = 0
        for _, idx in ipairs(cluster) do
          total_reinforced = total_reinforced + (all[idx].reinforced or 1)
          total_use = total_use + (all[idx].use_count or 0)
          remove_set[idx] = true
        end
        merged_lessons[ci].reinforced = total_reinforced
        merged_lessons[ci].use_count = total_use
      end
    end

    -- Build new list: keep non-clustered + add merged
    local new_all = {}
    for i, l in ipairs(all) do
      if not remove_set[i] then
        new_all[#new_all + 1] = l
      end
    end
    for _, ml in ipairs(merged_lessons) do
      new_all[#new_all + 1] = ml
    end

    local before = #all
    M._save_lessons(new_all)

    local stats = {
      before = before,
      after = #new_all,
      merged_groups = #clusters,
      removed = before - #new_all,
    }

    if callback then callback(stats) end
  end)
end

--- Get lesson statistics for health check / display.
function M._lesson_stats()
  local all = M._load_lessons()
  if #all == 0 then return { total = 0 } end

  local now = os.time()
  local thirty_days = 30 * 24 * 3600
  local stale = 0
  local never_used = 0
  local total_uses = 0
  local total_reinforced = 0

  for _, l in ipairs(all) do
    if l.timestamp and (now - l.timestamp) > thirty_days then stale = stale + 1 end
    if (l.use_count or 0) == 0 then never_used = never_used + 1 end
    total_uses = total_uses + (l.use_count or 0)
    total_reinforced = total_reinforced + (l.reinforced or 1)
  end

  return {
    total = #all,
    stale = stale,
    never_used = never_used,
    avg_uses = total_uses / #all,
    avg_reinforced = total_reinforced / #all,
  }
end

--------------------------------------------------------------------
-- Agent run: agentic tool-use loop
--------------------------------------------------------------------

--- Run the agent on a request. This is the main entry point.
--- Uses agentic tool-use loop (Claude Code / Codex / Gemini CLI).
--------------------------------------------------------------------
-- Plan generation: quick single-shot LLM call before agent launch
--------------------------------------------------------------------

local PLAN_PROMPT = [=[
You are a senior engineer. Given the task below and the project context, produce a brief execution plan.

## Task
%s

## Project Context
%s

## Instructions
Respond ONLY with a JSON object (no markdown, no backticks):
{
  "summary": "1-sentence summary of what needs to happen",
  "complexity": "simple|medium|complex",
  "steps": [
    {"action": "read|write|edit|test|run", "target": "file or command", "description": "what and why"}
  ],
  "risks": ["potential risk or gotcha"],
  "estimated_files": 3,
  "recommend_auto": false
}

Keep it concise: 3-8 steps max. "recommend_auto" should be true ONLY if the task clearly needs multiple independent sub-tasks.
]=]

--- Generate an execution plan for a request.
--- callback(plan_table_or_nil, raw_text)
function M._generate_plan(request, callback)
  local context = gather_project_context()

  -- Inject feature context
  pcall(function()
    local integration = require("dwight.integration")
    local feature_ctx = integration.build_feature_context(request)
    if feature_ctx then context = context .. "\n\n" .. feature_ctx end
  end)

  local prompt = string.format(PLAN_PROMPT, request:sub(1, 3000), context:sub(1, 8000))

  require("dwight.skills")._run_llm(prompt, function(raw, code)
    if code ~= 0 or not raw or vim.trim(raw) == "" then
      callback(nil, raw)
      return
    end

    -- Parse JSON (strip markdown fences if present)
    local cleaned = raw:gsub("```json%s*", ""):gsub("```%s*", ""):match("(%{.+%})")
    if not cleaned then
      callback(nil, raw)
      return
    end

    local ok, plan = pcall(vim.json.decode, cleaned)
    if ok and type(plan) == "table" then
      plan._raw_context = context  -- carry context forward to agent
      callback(plan, raw)
    else
      callback(nil, raw)
    end
  end)
end

--- Show plan in a buffer with action keybindings.
--- on_action("run"|"auto"|"edit"|"cancel", plan, edited_request)
function M._show_plan_buffer(request, plan, on_action)
  local lines = {
    "╔══════════════════════════════════════════════════════════════╗",
    "║  DwightAgent Plan Preview                                   ║",
    "╚══════════════════════════════════════════════════════════════╝",
    "",
    "  📋 Task: " .. request:sub(1, 80),
    "",
  }

  if plan.summary then
    lines[#lines + 1] = "  📝 " .. plan.summary
    lines[#lines + 1] = ""
  end

  -- Complexity badge
  local complexity_icon = plan.complexity == "complex" and "🔴"
    or plan.complexity == "medium" and "🟡" or "🟢"
  lines[#lines + 1] = string.format("  Complexity: %s %s  │  Est. files: %d",
    complexity_icon, plan.complexity or "?", plan.estimated_files or 0)
  lines[#lines + 1] = ""

  -- Steps
  if plan.steps and #plan.steps > 0 then
    lines[#lines + 1] = "  ─── Execution Plan ───"
    lines[#lines + 1] = ""
    local action_icons = {
      read = "📖", write = "📝", edit = "✏️", test = "🧪", run = "🔧",
    }
    for i, step in ipairs(plan.steps) do
      local icon = action_icons[step.action] or "▸"
      lines[#lines + 1] = string.format("  %d. %s %s", i, icon, step.description or "")
      if step.target and step.target ~= "" then
        lines[#lines + 1] = string.format("     → %s", step.target)
      end
    end
    lines[#lines + 1] = ""
  end

  -- Risks
  if plan.risks and #plan.risks > 0 then
    lines[#lines + 1] = "  ─── Risks ───"
    for _, r in ipairs(plan.risks) do
      lines[#lines + 1] = "  ⚠️  " .. r
    end
    lines[#lines + 1] = ""
  end

  -- Recommend Auto?
  if plan.recommend_auto then
    lines[#lines + 1] = "  💡 This task looks complex — DwightAuto (multi-task) may work better."
    lines[#lines + 1] = ""
  end

  lines[#lines + 1] = "  ─── Actions ───"
  lines[#lines + 1] = "  <CR>  Execute plan with DwightAgent"
  lines[#lines + 1] = "  A     Switch to DwightAuto (multi-task)"
  lines[#lines + 1] = "  e     Edit request before running"
  lines[#lines + 1] = "  q     Cancel"

  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, _flatten(lines))
  vim.bo[buf].modifiable = false
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "dwight_plan"

  vim.cmd("botright split")
  local win = api.nvim_get_current_win()
  api.nvim_win_set_buf(win, buf)
  api.nvim_win_set_height(win, math.min(#lines + 2, math.floor(vim.o.lines * 0.45)))

  local function safe_close()
    local wins = api.nvim_tabpage_list_wins(0)
    if #wins <= 1 then vim.cmd("enew") else api.nvim_win_close(win, true) end
  end

  -- <CR>: Execute
  vim.keymap.set("n", "<CR>", function()
    safe_close()
    on_action("run", plan, request)
  end, { buffer = buf, desc = "Execute with DwightAgent" })

  -- A: Switch to Auto
  vim.keymap.set("n", "A", function()
    safe_close()
    on_action("auto", plan, request)
  end, { buffer = buf, desc = "Switch to DwightAuto" })

  -- e: Edit request
  vim.keymap.set("n", "e", function()
    safe_close()
    vim.ui.input({ prompt = "✏️  Edit request: ", default = request }, function(edited)
      if edited and vim.trim(edited) ~= "" then
        on_action("edit", plan, edited)
      end
    end)
  end, { buffer = buf, desc = "Edit request" })

  -- q: Cancel
  vim.keymap.set("n", "q", function()
    safe_close()
    on_action("cancel", plan, request)
  end, { buffer = buf, desc = "Cancel" })
end

--- Heuristic: is the request complex enough to benefit from planning?
local function request_is_complex(request)
  local word_count = 0
  for _ in request:gmatch("%S+") do word_count = word_count + 1 end

  -- Multiple files mentioned
  local file_refs = 0
  for _ in request:gmatch("[%w_%-/]+%.[%w]+") do file_refs = file_refs + 1 end

  -- Multiple action verbs
  local actions = 0
  for _, verb in ipairs({ "add", "create", "fix", "refactor", "update", "implement",
    "remove", "delete", "move", "rename", "change", "modify", "write", "build" }) do
    if request:lower():find(verb, 1, true) then actions = actions + 1 end
  end

  return word_count > 40 or file_refs > 2 or actions > 2
end

--------------------------------------------------------------------
-- Main entry point
--------------------------------------------------------------------

function M.run(request, opts)
  opts = opts or {}

  if not request or vim.trim(request) == "" then
    vim.ui.input({ prompt = "🧠 What should Dwight build? " }, function(input)
      if input and vim.trim(input) ~= "" then
        M.run(input, opts)
      end
    end)
    return
  end

  -- If caller explicitly set plan mode, respect it
  local plan_mode = opts.plan

  -- Auto-detect: suggest plan for complex requests (unless opts.plan == false)
  if plan_mode == nil and request_is_complex(request) then
    plan_mode = true
  end

  -- Skip planning: jump straight in
  if plan_mode == false or opts._skip_plan then
    M._run_agentic(request, opts)
    return
  end

  -- Plan mode: generate plan first, then show preview
  if plan_mode then
    vim.notify("[dwight] 📋 Generating execution plan…", vim.log.levels.INFO)

    M._generate_plan(request, function(plan, _raw)
      if not plan then
        -- Plan generation failed — fall back to direct execution
        vim.notify("[dwight] ⚠️  Plan generation failed — launching agent directly.", vim.log.levels.WARN)
        M._run_agentic(request, opts)
        return
      end

      M._show_plan_buffer(request, plan, function(action, plan_data, final_request)
        if action == "run" then
          -- Feed plan as additional context to the agent
          local plan_context = M._plan_to_context(plan_data)
          opts._plan_context = plan_context
          M._run_agentic(final_request, opts)
        elseif action == "auto" then
          require("dwight.auto").auto(final_request)
        elseif action == "edit" then
          -- Re-plan with edited request
          M.run(final_request, opts)
        end
        -- "cancel" → do nothing
      end)
    end)
    return
  end

  -- Default: offer mode choice for ambiguous complexity
  M._run_agentic(request, opts)
end

--- Convert a plan table to context string for the agent prompt.
function M._plan_to_context(plan)
  if not plan then return "" end

  local parts = { "\n## Execution Plan (pre-approved by user)" }
  if plan.summary then
    parts[#parts + 1] = "Summary: " .. plan.summary
  end
  if plan.steps and #plan.steps > 0 then
    parts[#parts + 1] = "Steps:"
    for i, step in ipairs(plan.steps) do
      local target = step.target and (" → " .. step.target) or ""
      parts[#parts + 1] = string.format("  %d. [%s] %s%s",
        i, step.action or "?", step.description or "", target)
    end
  end
  if plan.risks and #plan.risks > 0 then
    parts[#parts + 1] = "Known risks:"
    for _, r in ipairs(plan.risks) do
      parts[#parts + 1] = "  - " .. r
    end
  end
  parts[#parts + 1] = "Follow this plan but adapt if you discover something unexpected."
  return table.concat(parts, "\n")
end
--------------------------------------------------------------------
-- Agentic mode: tool-use loop (optional plan context injected by M.run)
--------------------------------------------------------------------

function M._run_agentic(request, opts)
  opts = opts or {}
  local agentic = require("dwight.agentic")
  local status_mod = require("dwight.agent_status")

  status_mod.start_session(request)
  if opts._plan_context then
    status_mod.append("🤖 Running with pre-approved plan")
  else
    status_mod.append("🤖 Running in agentic mode (tool-use loop)")
  end

  -- Pre-work git safety: warn about dirty state
  pcall(function()
    local status_out = vim.fn.system("git status --porcelain 2>/dev/null")
    if status_out and vim.trim(status_out) ~= "" then
      local count = 0
      for _ in status_out:gmatch("[^\n]+") do count = count + 1 end
      status_mod.append(string.format("⚠️  %d uncommitted change(s) in working tree", count))
      status_mod.append("   Tip: commit or stash first, or use :DwightGit stash")
    end
  end)

  -- Build project context
  local context = gather_project_context()

  -- Inject lessons
  local lessons = M._find_relevant_lessons(request)
  if #lessons > 0 then
    local parts = {}
    for _, l in ipairs(lessons) do
      parts[#parts + 1] = "- " .. l.text
    end
    context = context .. "\n\n## Lessons from Past Sessions\n" .. table.concat(parts, "\n")
  end

  -- Inject feature-scoped context if the request references specific features
  pcall(function()
    local integration = require("dwight.integration")
    local feature_ctx = integration.build_feature_context(request)
    if feature_ctx then context = context .. "\n\n" .. feature_ctx end
  end)

  -- Inject pre-approved plan if available
  if opts._plan_context then
    context = context .. "\n" .. opts._plan_context
  end

  local started = os.time()
  local session_id = os.date("%Y%m%d-%H%M%S")
  local safe_name = request:sub(1, 30):gsub("[^%w_%-]", "-"):gsub("%-+", "-")

  -- Track tool activity for richer status display
  local tool_counts = { read = 0, write = 0, edit = 0, run = 0 }
  local last_tool_type = nil

  -- Snapshot git HEAD before execution for post-session diff
  local pre_head = nil
  pcall(function()
    local out = vim.fn.system("git rev-parse HEAD 2>/dev/null")
    if vim.v.shell_error == 0 then pre_head = vim.trim(out) end
  end)

  agentic.run({
    task = request,
    context = context,

    on_status = function(text)
      status_mod.stop_spin()
      status_mod.append(text)
    end,

    on_tool = function(desc)
      -- Categorize and count tool usage
      local tool_type = desc:match("^📖") and "read"
        or desc:match("^📝") and "write"
        or desc:match("^✏️") and "edit"
        or desc:match("^🔧 run") and "run"
        or desc:match("^🔍") and "search"
        or desc:match("^📂") and "list"
        or desc:match("^✅") and "complete"
        or "other"

      if tool_counts[tool_type] then
        tool_counts[tool_type] = tool_counts[tool_type] + 1
      else
        tool_counts[tool_type] = 1
      end

      -- Persist significant tool actions as permanent status lines.
      -- Writes, edits, commands, and searches are always shown.
      -- Reads are shown every 5th to avoid flooding but show exploration progress.
      local should_persist = false
      if tool_type == "write" or tool_type == "edit" or tool_type == "run"
         or tool_type == "search" or tool_type == "complete" then
        should_persist = true
      elseif tool_type == "read" then
        should_persist = (tool_counts.read == 1) or (tool_counts.read % 5 == 0)
      end

      if should_persist and desc ~= last_tool_type then
        status_mod.stop_spin()
        status_mod.append(desc)
      end
      last_tool_type = desc

      -- Always update spinner with current activity
      status_mod.spin(desc)
    end,

    on_complete = function(success, data)
      local duration = os.time() - started
      status_mod.stop_spin()

      -- Show tool usage summary before final status
      local tool_parts = {}
      if tool_counts.read > 0 then tool_parts[#tool_parts + 1] = tool_counts.read .. " reads" end
      if tool_counts.write > 0 then tool_parts[#tool_parts + 1] = tool_counts.write .. " writes" end
      if tool_counts.edit > 0 then tool_parts[#tool_parts + 1] = tool_counts.edit .. " edits" end
      if tool_counts.run > 0 then tool_parts[#tool_parts + 1] = tool_counts.run .. " commands" end
      if (tool_counts.search or 0) > 0 then tool_parts[#tool_parts + 1] = tool_counts.search .. " searches" end
      if #tool_parts > 0 then
        status_mod.append("📊 Tool usage: " .. table.concat(tool_parts, ", "))
      end

      status_mod.end_session(success, duration)

      -- Post-session diff review: show what changed
      M._show_post_diff(status_mod, pre_head)

      -- Post-session integration (feature warnings, squash hint, PR hint)
      pcall(function()
        local integration = require("dwight.integration")
        integration.post_session(request, data.journal or {}, status_mod)
      end)

      -- Save session
      pcall(function()
        M._save_session({
          id = session_id,
          name = safe_name,
          request = request,
          had_error = not success,
          duration = duration,
          timestamp = started,
          journal = data.journal,
          cost = status_mod.session_cost and status_mod.session_cost() or 0,
          agentic = true,
          summary = data.summary,
        })
      end)

      -- Extract lessons
      pcall(function()
        M._extract_lessons({
          request = request,
          had_error = not success,
          timestamp = os.time(),
        }, data.journal or {}, function(lessons_out)
          if lessons_out and #lessons_out > 0 then
            M._append_lessons(lessons_out)
            status_mod.append(string.format("📚 Learned %d lesson(s)", #lessons_out))
          end
        end)
      end)

      if success then
        vim.notify(string.format("[dwight] 🤖 Agentic: done in %ds!", duration), vim.log.levels.INFO)
      else
        vim.notify("[dwight] 🤖 Agentic: execution had errors.", vim.log.levels.WARN)
      end

      -- Fire external on_complete callback (used by github.lua for PR flow)
      if opts.on_complete then
        pcall(opts.on_complete, success)
      end
    end,
  })
end

--------------------------------------------------------------------
-- Post-session diff review
--------------------------------------------------------------------

--- Show git diff summary after an agent session completes.
--- Appends a summary to the status buffer and populates quickfix with changed files.
function M._show_post_diff(status_mod, pre_head)
  if not pre_head then return end

  -- Determine diff range: committed changes or working tree
  local diff_ref = pre_head .. "..HEAD"
  local stat = vim.fn.system("git diff --stat " .. diff_ref .. " 2>/dev/null")
  local using_worktree = false
  if vim.v.shell_error ~= 0 or not stat or vim.trim(stat) == "" then
    diff_ref = "HEAD"
    stat = vim.fn.system("git diff --stat HEAD 2>/dev/null")
    using_worktree = true
  end

  -- Check for new untracked files early (git diff misses these)
  local untracked = vim.fn.system("git ls-files --others --exclude-standard 2>/dev/null")
  local untracked_files = {}
  if untracked and vim.trim(untracked) ~= "" then
    for fname in untracked:gmatch("[^\n]+") do
      fname = vim.trim(fname)
      if fname ~= "" and not fname:match("^%.dwight/") and not fname:match("%.db$") then
        untracked_files[#untracked_files + 1] = fname
      end
    end
  end

  local has_stat = stat and vim.trim(stat) ~= ""
  local has_new = #untracked_files > 0

  -- Nothing changed at all
  if not has_stat and not has_new then return end

  if using_worktree then
    status_mod.append("")
    status_mod.append("📋 Uncommitted changes:")
  else
    status_mod.append("")
    status_mod.append("📋 Changes since session start:")
  end

  -- Show compact diff stat (tracked changes)
  if has_stat then
    local line_count = 0
    for line in stat:gmatch("[^\n]+") do
      if line_count < 15 then
        status_mod.append("  " .. line)
      end
      line_count = line_count + 1
    end
    if line_count > 15 then
      status_mod.append(string.format("  ... and %d more files", line_count - 15))
    end
  end

  -- Show new untracked files
  if has_new then
    for i, fname in ipairs(untracked_files) do
      if i <= 10 then
        status_mod.append("  " .. fname .. " (new)")
      end
    end
    if #untracked_files > 10 then
      status_mod.append(string.format("  ... and %d more new files", #untracked_files - 10))
    end
  end

  -- Store for :DwightDiffReview
  M._last_pre_head = pre_head

  -- Build quickfix list from changed files with first-changed-line
  local qf_items = {}
  local cwd = vim.fn.getcwd()
  local numstat = vim.fn.system("git diff --numstat " .. diff_ref .. " 2>/dev/null")
  local name_lines = vim.fn.system("git diff --name-only " .. diff_ref .. " 2>/dev/null")

  if name_lines and vim.trim(name_lines) ~= "" then
    for fname in name_lines:gmatch("[^\n]+") do
      fname = vim.trim(fname)
      if fname ~= "" then
        -- Get first changed line number from unified diff
        local lnum = 1
        local file_diff = vim.fn.system(
          "git diff " .. diff_ref .. " -- " .. vim.fn.shellescape(fname) .. " 2>/dev/null")
        if file_diff then
          -- Parse first @@ hunk: @@ -old,count +new,count @@
          local new_start = file_diff:match("@@ %-%d+[,%d]* %+(%d+)")
          if new_start then lnum = tonumber(new_start) or 1 end
        end

        -- Count insertions/deletions from numstat
        local ins, del = nil, nil
        if numstat then
          local pattern = "(%d+)%s+(%d+)%s+" .. fname:gsub("[%(%)%.%%%+%-%*%?%[%^%$]", "%%%1")
          ins, del = numstat:match(pattern)
        end
        local stat_text = ""
        if ins and del then
          stat_text = string.format(" (+%s -%s)", ins, del)
        end

        qf_items[#qf_items + 1] = {
          filename = cwd .. "/" .. fname,
          lnum = lnum,
          col = 1,
          text = fname .. stat_text,
        }
      end
    end
  end

  -- Add untracked (new) files to quickfix — these are created by the agent
  for _, fname in ipairs(untracked_files) do
    qf_items[#qf_items + 1] = {
      filename = cwd .. "/" .. fname,
      lnum = 1,
      col = 1,
      text = fname .. " (new)",
    }
  end

  if #qf_items > 0 then
    vim.fn.setqflist(qf_items, "r")
    vim.fn.setqflist({}, "a", { title = "Dwight: " .. #qf_items .. " file(s) changed" })

    status_mod.append("")
    status_mod.append(string.format("📋 Quickfix: %d file(s) — :copen to review", #qf_items))
    status_mod.append("💡 :DwightDiffReview — full unified diff in a tab")

    -- Auto-open quickfix (non-blocking)
    vim.defer_fn(function() vim.cmd("botright copen") end, 300)
  end
end

--- Open a full diff buffer showing all changes from the last agent session.
function M.diff_review()
  local pre_head = M._last_pre_head

  -- Try committed changes first, then working tree
  local diff
  if pre_head then
    diff = vim.fn.system("git diff " .. pre_head .. "..HEAD 2>/dev/null")
    if vim.v.shell_error ~= 0 or vim.trim(diff or "") == "" then
      diff = nil
    end
  end
  if not diff then
    diff = vim.fn.system("git diff HEAD 2>/dev/null")
    if vim.v.shell_error ~= 0 or vim.trim(diff or "") == "" then
      vim.notify("[dwight] No changes to review.", vim.log.levels.INFO)
      return
    end
  end

  local buf = vim.api.nvim_create_buf(false, true)
  local lines = vim.split(diff, "\n", { plain = true })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, _flatten(lines))
  vim.bo[buf].filetype = "diff"
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  pcall(function() vim.api.nvim_buf_set_name(buf, "dwight://diff-review") end)

  vim.cmd("tab split")
  vim.api.nvim_win_set_buf(0, buf)
  vim.wo[0].number = true
  vim.wo[0].wrap = false
  vim.wo[0].foldenable = true
  vim.wo[0].foldmethod = "diff"

  -- Keymap: q to close
  vim.keymap.set("n", "q", function()
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end, { buffer = buf, desc = "Close diff review" })

  vim.notify("[dwight] 📋 Diff review open. q to close.", vim.log.levels.INFO)
end
--------------------------------------------------------------------
-- Session logging (plan + execution log)
--------------------------------------------------------------------

--- Save a full agent session (plan + all execution entries).
--- Also saves a resume file if the session had errors.
function M._save_session(session)
  pcall(function()
    local dir = agent_dir()
    vim.fn.mkdir(dir, "p")

    local path = string.format("%s/%s_%s.md", dir, session.id, session.name)

    local lines = {
      "# Agent Session",
      "",
      "**Request:** " .. session.request,
      string.format("**Time:** %s (%ds)", os.date("%Y-%m-%d %H:%M:%S", session.timestamp), session.duration),
      string.format("**Outcome:** %s", session.had_error and "❌ FAILED" or "✅ SUCCESS"),
      string.format("**Cost:** ~$%.4f", session.cost or 0),
    }

    -- Include failed step info for resume
    if session.failed_step then
      lines[#lines + 1] = string.format("**Failed at:** Step %d", session.failed_step)
    end

    lines[#lines + 1] = ""
    lines[#lines + 1] = "---"
    lines[#lines + 1] = ""
    lines[#lines + 1] = "## Plan"
    lines[#lines + 1] = ""
    lines[#lines + 1] = session.plan
    lines[#lines + 1] = ""
    lines[#lines + 1] = "---"
    lines[#lines + 1] = ""
    lines[#lines + 1] = "## Execution Log"
    lines[#lines + 1] = ""

    -- Append all quickfix entries as the execution log
    for i, entry in ipairs(session.entries or {}) do
      local icon = entry.type == "E" and "❌" or entry.type == "W" and "⚠️" or "✅"
      local file = entry.filename and (" `" .. vim.fn.fnamemodify(entry.filename, ":.") .. "`") or ""
      lines[#lines + 1] = string.format("%d. %s %s%s", i, icon, entry.text or "", file)
    end

    if #(session.entries or {}) == 0 then
      lines[#lines + 1] = "(no entries)"
    end

    -- Include step journal if available
    if session.journal and #session.journal > 0 then
      lines[#lines + 1] = ""
      lines[#lines + 1] = "---"
      lines[#lines + 1] = ""
      lines[#lines + 1] = "## Step Journal"
      lines[#lines + 1] = ""
      for _, entry in ipairs(session.journal) do
        lines[#lines + 1] = "- " .. entry
      end
    end

    local f = io.open(path, "w")
    if f then
      f:write(table.concat(lines, "\n"))
      f:close()
    end
  end)
end

--------------------------------------------------------------------
-- DwightAgentLog: browse saved sessions with Telescope
--------------------------------------------------------------------

--- List all saved agent sessions.
function M.list_sessions()
  local dir = agent_dir()
  if vim.fn.isdirectory(dir) ~= 1 then return {} end

  local uv = vim.loop or vim.uv
  local sessions = {}
  local handle = uv.fs_scandir(dir)
  if not handle then return {} end

  while true do
    local name, ftype = uv.fs_scandir_next(handle)
    if not name then break end
    if ftype == "file" and name:match("%.md$") then
      local path = dir .. "/" .. name

      -- Parse metadata from the first few lines
      local f = io.open(path, "r")
      if f then
        local content = f:read("*a")
        f:close()

        local request = content:match("%*%*Request:%*%* (.-)[\n]") or name
        local time_str = content:match("%*%*Time:%*%* (.-)[\n]") or ""
        local outcome = content:match("%*%*Outcome:%*%* (.-)[\n]") or ""

        sessions[#sessions + 1] = {
          name = name:gsub("%.md$", ""),
          path = path,
          request = request,
          time = time_str,
          outcome = outcome,
        }
      end
    end
  end

  -- Sort by name descending (newest first, since names start with timestamp)
  table.sort(sessions, function(a, b) return a.name > b.name end)
  return sessions
end

--- Open the agent log browser.
function M.show_log()
  local sessions = M.list_sessions()

  if #sessions == 0 then
    vim.notify("[dwight] No agent sessions found. Run :DwightAgent first.", vim.log.levels.INFO)
    return
  end

  -- Try Telescope
  local has_telescope, _ = pcall(require, "telescope")
  if has_telescope then
    M._show_log_telescope(sessions)
  else
    M._show_log_fallback(sessions)
  end
end

function M._show_log_telescope(sessions)
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local previewers = require("telescope.previewers")

  pickers.new({}, {
    prompt_title = "🧠 Agent Sessions",
    finder = finders.new_table({
      results = sessions,
      entry_maker = function(session)
        local icon = session.outcome:match("SUCCESS") and "✅" or "❌"
        return {
          value = session,
          display = string.format("%s %s — %s", icon, session.request:sub(1, 50), session.time),
          ordinal = session.name .. " " .. session.request,
          filename = session.path,
        }
      end,
    }),
    previewer = previewers.new_buffer_previewer({
      title = "Session Log",
      define_preview = function(self, entry)
        local path = entry.value.path
        if vim.fn.filereadable(path) == 1 then
          local lines = vim.fn.readfile(path)
          api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, _flatten(lines))
          vim.bo[self.state.bufnr].filetype = "markdown"
        end
      end,
    }),
    sorter = conf.generic_sorter({}),
    attach_mappings = function(prompt_bufnr, _map)
      actions.select_default:replace(function()
        local entry = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if entry and entry.value.path then
          vim.cmd("edit " .. vim.fn.fnameescape(entry.value.path))
        end
      end)
      return true
    end,
  }):find()
end

function M._show_log_fallback(sessions)
  local items = {}
  for _, s in ipairs(sessions) do
    local icon = s.outcome:match("SUCCESS") and "✅" or "❌"
    items[#items + 1] = string.format("%s %s — %s", icon, s.request:sub(1, 50), s.time)
  end

  require("dwight.select").pick(items, { prompt = "🧠 Agent Sessions:" }, function(_, idx)
    if idx and sessions[idx] then
      vim.cmd("edit " .. vim.fn.fnameescape(sessions[idx].path))
    end
  end)
end

return M
