-- tests/test_lessons.lua
-- Tests for the lesson quality system in agent.lua.

vim.opt.rtp:prepend(vim.fn.getcwd())

local T = _T

-- Set up temp directory for lesson storage
local test_dir = vim.fn.tempname()
vim.fn.mkdir(test_dir .. "/agent", "p")

-- Mock dwight.project so agent_dir() uses our temp dir
package.preload["dwight.project"] = function()
  return {
    is_initialized = function() return true end,
    dir = function() return test_dir end,
  }
end

local agent = require("dwight.agent")

io.write("── lessons: save/load ──\n")

T.test("save and load empty", function()
  agent._save_lessons({})
  local lessons = agent._load_lessons()
  T.len(0, lessons)
end)

T.test("save and load lessons", function()
  agent._save_lessons({
    { keywords = { "go", "test" }, text = "Use table-driven tests", timestamp = os.time(), reinforced = 1, use_count = 0 },
    { keywords = { "go", "mock" }, text = "Mock all interface methods", timestamp = os.time(), reinforced = 2, use_count = 3 },
  })
  local lessons = agent._load_lessons()
  T.len(2, lessons)
  T.eq("Use table-driven tests", lessons[1].text)
  T.eq(2, lessons[2].reinforced)
end)

io.write("── lessons: append with similarity dedup ──\n")

T.test("append truly new lesson", function()
  agent._save_lessons({
    { keywords = { "go", "test" }, text = "Existing lesson", timestamp = os.time(), reinforced = 1, use_count = 0 },
  })
  agent._append_lessons({
    { keywords = { "python", "flask" }, text = "Use pytest fixtures", timestamp = os.time() },
  })
  local all = agent._load_lessons()
  T.len(2, all, "should add new lesson")
  T.eq("Use pytest fixtures", all[2].text)
  T.eq(1, all[2].reinforced, "new lesson starts with reinforced=1")
  T.eq(0, all[2].use_count, "new lesson starts with use_count=0")
end)

T.test("merge similar lesson instead of duplicating", function()
  agent._save_lessons({
    { keywords = { "go", "test", "mock" }, text = "Old mock advice", timestamp = os.time() - 86400, reinforced = 1, use_count = 2 },
  })
  -- New lesson with same keywords should merge
  agent._append_lessons({
    { keywords = { "go", "test", "mock" }, text = "Better mock advice", timestamp = os.time() },
  })
  local all = agent._load_lessons()
  T.len(1, all, "should merge, not add")
  T.eq("Better mock advice", all[1].text, "should keep newer text")
  T.eq(2, all[1].reinforced, "should increment reinforced")
end)

T.test("partially overlapping keywords merge at threshold", function()
  agent._save_lessons({
    { keywords = { "go", "test", "sqlite" }, text = "Old advice", timestamp = os.time(), reinforced = 1, use_count = 0 },
  })
  -- 2/3 keyword overlap = 0.67 > 0.6 threshold
  agent._append_lessons({
    { keywords = { "go", "test" }, text = "New advice", timestamp = os.time() },
  })
  local all = agent._load_lessons()
  T.len(1, all, "should merge with 67% overlap")
end)

T.test("low overlap stays separate", function()
  agent._save_lessons({
    { keywords = { "go", "test", "sqlite" }, text = "Go advice", timestamp = os.time(), reinforced = 1, use_count = 0 },
  })
  -- 1/4 overlap = 0.25 < 0.6 threshold
  agent._append_lessons({
    { keywords = { "python", "flask", "test" }, text = "Python advice", timestamp = os.time() },
  })
  local all = agent._load_lessons()
  T.len(2, all, "should not merge with 25% overlap")
end)

io.write("── lessons: eviction ──\n")

T.test("evict removes lowest scored lessons", function()
  local lessons = {}
  for i = 1, 10 do
    lessons[i] = {
      keywords = { "kw" .. i },
      text = "Lesson " .. i,
      timestamp = os.time() - (i * 86400),  -- older = higher index
      reinforced = 1,
      use_count = 0,
    }
  end
  -- Make lesson 1 valuable (recent, high use)
  lessons[1].use_count = 10
  lessons[1].timestamp = os.time()
  lessons[1].reinforced = 3

  agent._evict_lessons(lessons, 5)
  T.len(5, lessons, "should evict down to 5")

  -- Lesson 1 should survive (high value)
  local found_lesson1 = false
  for _, l in ipairs(lessons) do
    if l.text == "Lesson 1" then found_lesson1 = true end
  end
  T.ok(found_lesson1, "most valuable lesson should survive eviction")
end)

io.write("── lessons: find relevant ──\n")

T.test("find relevant scores by keyword overlap", function()
  agent._save_lessons({
    { keywords = { "go", "test", "mock" }, text = "Mock lesson", timestamp = os.time(), reinforced = 1, use_count = 0 },
    { keywords = { "python", "flask" }, text = "Flask lesson", timestamp = os.time(), reinforced = 1, use_count = 0 },
    { keywords = { "go", "http", "handler" }, text = "Handler lesson", timestamp = os.time(), reinforced = 1, use_count = 0 },
  })

  local results = agent._find_relevant_lessons("write go test with mock")
  T.ok(#results >= 1, "should find at least 1 result")
  T.eq("Mock lesson", results[1].text, "best match should be the go/test/mock lesson")
end)

T.test("find relevant increments use_count", function()
  agent._save_lessons({
    { keywords = { "go", "test" }, text = "Test lesson", timestamp = os.time(), reinforced = 1, use_count = 0 },
  })

  agent._find_relevant_lessons("go test")
  local all = agent._load_lessons()
  T.eq(1, all[1].use_count, "use_count should be incremented")
end)

T.test("find relevant returns empty for no match", function()
  agent._save_lessons({
    { keywords = { "python", "django" }, text = "Django lesson", timestamp = os.time(), reinforced = 1, use_count = 0 },
  })
  local results = agent._find_relevant_lessons("rust cargo build")
  T.len(0, results, "no keyword overlap should return empty")
end)

io.write("── lessons: stats ──\n")

T.test("stats with mixed lessons", function()
  agent._save_lessons({
    { keywords = { "a" }, text = "Fresh used", timestamp = os.time(), reinforced = 2, use_count = 5 },
    { keywords = { "b" }, text = "Stale unused", timestamp = os.time() - 40 * 86400, reinforced = 1, use_count = 0 },
    { keywords = { "c" }, text = "Fresh unused", timestamp = os.time(), reinforced = 1, use_count = 0 },
  })
  local stats = agent._lesson_stats()
  T.eq(3, stats.total)
  T.eq(1, stats.stale, "one lesson is >30 days old")
  T.eq(2, stats.never_used, "two lessons have 0 use_count")
end)

-- Cleanup
vim.fn.delete(test_dir, "rf")
