-- tests/test_utf8.lua
-- Tests for the UTF-8 byte-level sanitizer.
-- Can run standalone: lua tests/test_utf8.lua (from project root)
-- Or via nvim: nvim --headless -c "lua ..."

-- Bootstrap: load harness if not already loaded
if not _T then
  dofile("tests/harness.lua")
end

-- Load utf8 module (works with both nvim require and standalone)
local utf8
if vim and vim.opt then
  vim.opt.rtp:prepend(vim.fn.getcwd())
  utf8 = require("dwight.utf8")
else
  -- Standalone Lua: add path manually
  package.path = "lua/?.lua;lua/?/init.lua;" .. package.path
  utf8 = require("dwight.utf8")
end

local T = _T

io.write("── utf8.sanitize ──\n")

-- Valid ASCII passthrough
T.test("ascii passthrough", function()
  T.eq("hello world", utf8.sanitize("hello world"))
end)

T.test("empty string", function()
  T.eq("", utf8.sanitize(""))
end)

T.test("printable ascii", function()
  local s = "The quick brown fox jumps over the lazy dog. 0123456789!@#$%^&*()"
  T.eq(s, utf8.sanitize(s))
end)

-- Valid multi-byte sequences
T.test("valid 2-byte: é (C3 A9)", function()
  T.eq("café", utf8.sanitize("café"))
end)

T.test("valid 3-byte: ✓ (E2 9C 93)", function()
  T.eq("✓", utf8.sanitize("✓"))
end)

T.test("valid 4-byte: 😀 (F0 9F 98 80)", function()
  T.eq("😀", utf8.sanitize("😀"))
end)

T.test("mixed valid multi-byte", function()
  local s = "Ünïcödé ✓ 日本語 😀🎉"
  T.eq(s, utf8.sanitize(s))
end)

-- Surrogates (the main bug that started it all)
T.test("surrogate high: ED A0 80 (U+D800)", function()
  local s = string.char(0xED, 0xA0, 0x80)
  local result = utf8.sanitize(s)
  -- Should NOT contain the original bytes
  T.eq(false, result:find(string.char(0xED), 1, true) ~= nil,
    "surrogate byte should be replaced")
end)

T.test("surrogate low: ED B0 80 (U+DC00)", function()
  local s = string.char(0xED, 0xB0, 0x80)
  local result = utf8.sanitize(s)
  T.eq(false, result:find(string.char(0xED), 1, true) ~= nil,
    "surrogate byte should be replaced")
end)

T.test("surrogate pair: ED A0 80 ED B0 80", function()
  local s = string.char(0xED, 0xA0, 0x80, 0xED, 0xB0, 0x80)
  local result = utf8.sanitize(s)
  -- All 6 bytes should be replaced
  for i = 1, #result do
    local b = result:byte(i)
    T.assert(b ~= 0xED, "no ED bytes should remain")
  end
end)

T.test("surrogate embedded in text", function()
  local s = "before" .. string.char(0xED, 0xA0, 0x80) .. "after"
  local result = utf8.sanitize(s)
  T.match("before", result)
  T.match("after", result)
end)

-- Overlong encodings
T.test("overlong 2-byte: C0 80 (overlong NUL)", function()
  local s = string.char(0xC0, 0x80)
  local result = utf8.sanitize(s)
  T.assert(result:byte(1) ~= 0xC0, "C0 should be replaced")
end)

T.test("overlong 2-byte: C1 BF", function()
  local s = string.char(0xC1, 0xBF)
  local result = utf8.sanitize(s)
  T.assert(result:byte(1) ~= 0xC1, "C1 should be replaced")
end)

T.test("overlong 3-byte: E0 80 80", function()
  local s = string.char(0xE0, 0x80, 0x80)
  local result = utf8.sanitize(s)
  T.assert(result:byte(1) ~= 0xE0, "overlong E0 should be replaced")
end)

T.test("overlong 4-byte: F0 80 80 80", function()
  local s = string.char(0xF0, 0x80, 0x80, 0x80)
  local result = utf8.sanitize(s)
  T.assert(result:byte(1) ~= 0xF0, "overlong F0 should be replaced")
end)

-- Truncated sequences
T.test("truncated 2-byte: C3 (missing continuation)", function()
  local s = string.char(0xC3)
  local result = utf8.sanitize(s)
  T.assert(#result > 0, "should produce output")
  T.assert(result:byte(1) ~= 0xC3, "truncated leader should be replaced")
end)

T.test("truncated 3-byte: E2 9C (missing last byte)", function()
  local s = string.char(0xE2, 0x9C)
  local result = utf8.sanitize(s)
  T.assert(#result > 0, "should produce output")
end)

T.test("truncated 4-byte: F0 9F 98 (missing last byte)", function()
  local s = string.char(0xF0, 0x9F, 0x98)
  local result = utf8.sanitize(s)
  T.assert(#result > 0, "should produce output")
end)

-- Invalid leader bytes
T.test("invalid byte FE", function()
  local s = string.char(0xFE)
  local result = utf8.sanitize(s)
  T.assert(result:byte(1) ~= 0xFE, "FE should be replaced")
end)

T.test("invalid byte FF", function()
  local s = string.char(0xFF)
  local result = utf8.sanitize(s)
  T.assert(result:byte(1) ~= 0xFF, "FF should be replaced")
end)

-- Lone continuation bytes
T.test("lone continuation byte 80", function()
  local s = string.char(0x80)
  local result = utf8.sanitize(s)
  T.assert(result:byte(1) ~= 0x80, "lone continuation should be replaced")
end)

T.test("lone continuation byte BF", function()
  local s = string.char(0xBF)
  local result = utf8.sanitize(s)
  T.assert(result:byte(1) ~= 0xBF, "lone continuation should be replaced")
end)

-- Above U+10FFFF
T.test("above max: F4 90 80 80 (U+110000)", function()
  local s = string.char(0xF4, 0x90, 0x80, 0x80)
  local result = utf8.sanitize(s)
  -- F4 with second byte >= 90 is above max
  T.assert(not (result:byte(1) == 0xF4 and #result >= 2 and result:byte(2) == 0x90),
    "above U+10FFFF should be replaced")
end)

T.test("invalid leader F5", function()
  local s = string.char(0xF5, 0x80, 0x80, 0x80)
  local result = utf8.sanitize(s)
  T.assert(result:byte(1) ~= 0xF5, "F5 leader should be replaced")
end)

-- Null bytes
T.test("null byte replaced", function()
  local s = "hello\0world"
  local result = utf8.sanitize(s)
  T.eq(false, result:find("\0", 1, true) ~= nil, "null bytes should be replaced")
  T.match("hello", result)
  T.match("world", result)
end)

-- Realistic: valid UTF-8 with embedded surrogates (the actual bug)
T.test("realistic: Go source with embedded surrogate", function()
  local code = 'func main() {\n\tfmt.Println("hello ' ..
    string.char(0xED, 0xA0, 0x80) .. '")\n}'
  local result = utf8.sanitize(code)
  T.match("func main", result)
  T.match("fmt.Println", result)
  -- Surrogate bytes gone
  for i = 1, #result do
    T.assert(result:byte(i) ~= 0xED or
      (i + 1 <= #result and result:byte(i + 1) < 0xA0),
      "surrogate should be cleaned at position " .. i)
  end
end)

-- Idempotence
T.test("idempotent: sanitize(sanitize(x)) == sanitize(x)", function()
  local dirty = "abc" .. string.char(0xED, 0xA0, 0x80, 0xC0, 0x80, 0xFF) .. "def"
  local once = utf8.sanitize(dirty)
  local twice = utf8.sanitize(once)
  T.eq(once, twice, "double sanitize should be same as single")
end)

-- Large input performance (should not hang)
T.test("large input: 100KB of valid ASCII", function()
  local big = string.rep("hello world\n", 10000)  -- ~120KB
  local result = utf8.sanitize(big)
  T.eq(#big, #result, "valid ASCII should pass through unchanged")
end)

T.test("large input: 100KB with scattered invalids", function()
  local parts = {}
  for i = 1, 1000 do
    parts[#parts + 1] = "line " .. i .. ": some code here;\n"
    if i % 100 == 0 then
      parts[#parts + 1] = string.char(0xED, 0xA0, 0x80)  -- surrogate every 100 lines
    end
  end
  local big = table.concat(parts)
  local result = utf8.sanitize(big)
  T.assert(#result > 0, "should produce output")
  T.match("line 1:", result)
  T.match("line 1000:", result)
end)

-- Self-run when executed directly (not via run.sh)
if arg and arg[0] and arg[0]:match("test_utf8") then
  _T.report()
end
