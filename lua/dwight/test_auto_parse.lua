-- tests/test_auto_parse.lua
-- Tests for auto.lua task parsing functions.

-- Add plugin to runtime path so require("dwight.*") works
vim.opt.rtp:prepend(vim.fn.getcwd())

local auto = require("dwight.auto")
local T = _T

io.write("── auto._parse_tasks (XML) ──\n")

T.test("parse XML tasks", function()
  local raw = [[
<task order="1" title="Install dependencies">
  Run go get to install the required packages.
</task>
<task order="2" title="Create models">
  Create the data models for the TUI.
</task>
  ]]
  local tasks = auto._parse_tasks(raw)
  T.len(2, tasks, "should parse 2 tasks")
  T.eq(1, tasks[1].order)
  T.eq("Install dependencies", tasks[1].title)
  T.match("go get", tasks[1].description)
  T.eq(2, tasks[2].order)
  T.eq("Create models", tasks[2].title)
end)

T.test("parse XML with code fences", function()
  local raw = [[```xml
<task order="1" title="First task">Do something</task>
```]]
  local tasks = auto._parse_tasks(raw)
  T.len(1, tasks, "should strip code fences")
  T.eq("First task", tasks[1].title)
end)

T.test("parse XML with depends_on", function()
  local raw = [[<task order="2" title="Build" depends_on="1">Compile the project.</task>]]
  local tasks = auto._parse_tasks(raw)
  T.len(1, tasks)
  T.eq("1", tasks[1].depends_on)
end)

T.test("parse XML with single quotes", function()
  local raw = [[<task order='1' title='Single quoted'>Body text</task>]]
  local tasks = auto._parse_tasks(raw)
  T.len(1, tasks)
  T.eq("Single quoted", tasks[1].title)
end)

io.write("── auto._parse_tasks (Markdown) ──\n")

T.test("parse markdown ## Task N: Title", function()
  local raw = [[
## Task 1: Install deps
Run npm install.

## Task 2: Create component
Build the React component.
  ]]
  local tasks = auto._parse_tasks(raw)
  T.len(2, tasks, "should parse 2 markdown tasks")
  T.eq("Install deps", tasks[1].title)
  T.eq("Create component", tasks[2].title)
  T.match("npm install", tasks[1].description)
end)

T.test("parse markdown ### Step N: Title", function()
  local raw = [[
### Step 1: First step
Do the first thing.

### Step 2: Second step
Do the second thing.
  ]]
  local tasks = auto._parse_tasks(raw)
  T.len(2, tasks)
  T.eq("First step", tasks[1].title)
  T.eq("Second step", tasks[2].title)
end)

T.test("parse markdown ## N: Title (number only)", function()
  local raw = [[
## 1: Setup
Initialize.

## 2: Implement
Write code.
  ]]
  local tasks = auto._parse_tasks(raw)
  T.len(2, tasks)
  T.eq("Setup", tasks[1].title)
  T.eq("Implement", tasks[2].title)
end)

T.test("parse markdown with dash separator", function()
  local raw = [[
## Task 1 - Install packages
Run go get.

## Task 2 - Create structs
Define types.
  ]]
  local tasks = auto._parse_tasks(raw)
  T.len(2, tasks)
  T.eq("Install packages", tasks[1].title)
end)

io.write("── auto._parse_tasks (Numbered list) ──\n")

T.test("parse numbered list", function()
  local raw = [[
1. **Install deps**: Run npm install to add required packages
2. **Create models**: Define the data structures
3. **Write tests**: Add unit tests for the models
  ]]
  local tasks = auto._parse_tasks(raw)
  T.len(3, tasks)
  T.eq("Install deps", tasks[1].title)
  T.eq("Create models", tasks[2].title)
  T.eq("Write tests", tasks[3].title)
end)

io.write("── auto._parse_tasks (Edge cases) ──\n")

T.test("empty input", function()
  T.len(0, auto._parse_tasks(""))
end)

T.test("no valid tasks", function()
  T.len(0, auto._parse_tasks("just some random text"))
end)

T.test("tasks are sorted by order", function()
  local raw = [[
<task order="3" title="Third">C</task>
<task order="1" title="First">A</task>
<task order="2" title="Second">B</task>
  ]]
  local tasks = auto._parse_tasks(raw)
  T.len(3, tasks)
  T.eq("First", tasks[1].title)
  T.eq("Second", tasks[2].title)
  T.eq("Third", tasks[3].title)
end)

io.write("── auto._parse_buffer_tasks ──\n")

T.test("parse buffer format", function()
  local text = [[
<!-- header comment -->

## Task 1: Install deps

Run npm install.

---

## Task 2: Create models

Define the structs.

---
  ]]
  local tasks = auto._parse_buffer_tasks(text)
  T.len(2, tasks)
  T.eq(1, tasks[1].order)
  T.eq("Install deps", tasks[1].title)
  T.match("npm install", tasks[1].description)
  T.eq(2, tasks[2].order)
  T.eq("Create models", tasks[2].title)
end)

T.test("buffer format preserves multi-line descriptions", function()
  local text = [[
## Task 1: Complex task

Line one of the description.
Line two with more detail.
Some code: `go build ./...`
  ]]
  local tasks = auto._parse_buffer_tasks(text)
  T.len(1, tasks)
  T.match("Line one", tasks[1].description)
  T.match("Line two", tasks[1].description)
  T.match("go build", tasks[1].description)
end)

T.test("buffer format skips comments and separators", function()
  local text = [[
<!-- This is a comment -->
## Task 1: Only task

Description here.

---
  ]]
  local tasks = auto._parse_buffer_tasks(text)
  T.len(1, tasks)
  T.eq(false, tasks[1].description:find("<!%-%-") ~= nil, "should skip comments")
  T.eq(false, tasks[1].description:find("%-%-%-") ~= nil, "should skip separators")
end)
