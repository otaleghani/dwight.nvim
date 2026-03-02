-- tests/harness.lua
-- Minimal test framework for nvim --headless testing.
-- Usage: nvim --headless -u NONE -c "lua dofile('tests/harness.lua')" -c "lua dofile('tests/test_foo.lua')" -c "lua _T.report()"

_T = _T or {}
_T.tests = {}
_T.passed = 0
_T.failed = 0
_T.errors = {}

--- Register a test.
function _T.test(name, fn)
  _T.tests[#_T.tests + 1] = { name = name, fn = fn }
end

--- Assert a condition is truthy.
function _T.assert(condition, message)
  if not condition then
    error(message or "assertion failed", 2)
  end
end

--- Assert two values are equal.
function _T.eq(expected, actual, message)
  if expected ~= actual then
    local msg = string.format(
      "%s\n  expected: %s\n  actual:   %s",
      message or "values not equal",
      tostring(expected), tostring(actual))
    error(msg, 2)
  end
end

--- Assert a string matches a pattern.
function _T.match(pattern, str, message)
  if not str:match(pattern) then
    error(string.format("%s\n  pattern: %s\n  string:  %s",
      message or "pattern not found", pattern, str:sub(1, 200)), 2)
  end
end

--- Assert a value is truthy.
function _T.ok(value, message)
  if not value then
    error(message or "expected truthy value, got: " .. tostring(value), 2)
  end
end

--- Assert a value is nil.
function _T.is_nil(value, message)
  if value ~= nil then
    error(message or "expected nil, got: " .. tostring(value), 2)
  end
end

--- Assert a table has a specific length.
function _T.len(expected, tbl, message)
  local actual = #tbl
  if expected ~= actual then
    error(string.format("%s\n  expected length: %d\n  actual length:   %d",
      message or "wrong length", expected, actual), 2)
  end
end

--- Run all registered tests and print results.
function _T.run()
  for _, t in ipairs(_T.tests) do
    local ok, err = pcall(t.fn)
    if ok then
      _T.passed = _T.passed + 1
      io.write(string.format("  ✅ %s\n", t.name))
    else
      _T.failed = _T.failed + 1
      _T.errors[#_T.errors + 1] = { name = t.name, error = err }
      io.write(string.format("  ❌ %s\n     %s\n", t.name, tostring(err)))
    end
  end
end

--- Print final report and exit with appropriate code.
function _T.report()
  _T.run()
  io.write(string.format("\n%d passed, %d failed\n", _T.passed, _T.failed))
  if vim and vim.cmd then
    -- Running inside nvim --headless
    if _T.failed > 0 then
      vim.cmd("cquit 1")
    else
      vim.cmd("qall!")
    end
  else
    -- Running in standalone Lua
    os.exit(_T.failed > 0 and 1 or 0)
  end
end

--- Reset state (for running multiple test files in sequence).
function _T.reset()
  _T.tests = {}
end
