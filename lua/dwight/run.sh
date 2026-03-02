#!/usr/bin/env bash
# tests/run.sh — Run dwight.nvim test suite.
#
# Usage:
#   ./tests/run.sh              # run all tests
#   ./tests/run.sh test_utf8    # run one test file
#
# Requires nvim for most tests. Pure-Lua tests (test_utf8) can fall back to lua/luajit.
# Exit code: 0 if all pass, 1 if any fail.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$PLUGIN_DIR"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BOLD='\033[1m'
NC='\033[0m'

# Find executables
NVIM=$(command -v nvim 2>/dev/null || true)
LUA=$(command -v luajit 2>/dev/null || command -v lua5.4 2>/dev/null || command -v lua5.1 2>/dev/null || command -v lua 2>/dev/null || true)

# Pure-Lua tests (no vim.* dependencies, can run with standalone lua)
PURE_LUA_TESTS="test_utf8"

# Discover test files
if [ $# -gt 0 ]; then
  TEST_FILES=()
  for arg in "$@"; do
    f="tests/${arg}.lua"
    [ -f "$f" ] || f="tests/test_${arg}.lua"
    [ -f "$f" ] || { echo "Test file not found: $arg"; exit 1; }
    TEST_FILES+=("$f")
  done
else
  TEST_FILES=(tests/test_*.lua)
fi

if [ -z "$NVIM" ] && [ -z "$LUA" ]; then
  echo "Error: neither nvim nor lua found in PATH."
  echo "Install neovim to run the full test suite."
  exit 1
fi

echo -e "${BOLD}dwight.nvim test suite${NC}"
[ -n "$NVIM" ] && echo "  nvim: $NVIM"
[ -n "$LUA" ]  && echo "  lua:  $LUA"
echo "─────────────────────────────────────"
echo ""

TOTAL_PASSED=0
TOTAL_FAILED=0
FAILED_FILES=()

for test_file in "${TEST_FILES[@]}"; do
  name="$(basename "$test_file" .lua)"
  echo -e "${BOLD}▶ ${name}${NC}"

  is_pure_lua=false
  for p in $PURE_LUA_TESTS; do
    [ "$name" = "$p" ] && is_pure_lua=true
  done

  set +e
  if [ -n "$NVIM" ]; then
    # Preferred: run in nvim --headless
    LUA_CMD="
      vim.opt.rtp:prepend('${PLUGIN_DIR}')
      package.preload['dwight'] = function()
        return {
          config = {
            backend = 'claude_code',
            claude_code_bin = 'claude',
            agentic_opts = {},
          },
        }
      end
      dofile('${PLUGIN_DIR}/tests/harness.lua')
      dofile('${PLUGIN_DIR}/${test_file}')
      _T.run()
      io.write('\\n')
      if _T.failed > 0 then
        vim.cmd('cquit 1')
      else
        vim.cmd('qall!')
      end
    "
    output=$("$NVIM" --headless -u NONE -c "lua $LUA_CMD" 2>&1)
    exit_code=$?
  elif [ "$is_pure_lua" = true ] && [ -n "$LUA" ]; then
    # Fallback: run pure-Lua tests with standalone lua
    output=$("$LUA" "${test_file}" 2>&1)
    exit_code=$?
  else
    echo "  ⏭️  Skipped (requires nvim)"
    echo ""
    continue
  fi
  set -e

  echo "$output"

  # Parse pass/fail counts from output
  passed=$(echo "$output" | grep -oP '(\d+) passed' | grep -oP '\d+' || echo "0")
  failed=$(echo "$output" | grep -oP '(\d+) failed' | grep -oP '\d+' || echo "0")

  TOTAL_PASSED=$((TOTAL_PASSED + passed))
  TOTAL_FAILED=$((TOTAL_FAILED + failed))

  if [ "$exit_code" -ne 0 ]; then
    FAILED_FILES+=("$name")
  fi

  echo ""
done

# Summary
echo "═══════════════════════════════════════"
if [ "$TOTAL_FAILED" -eq 0 ]; then
  echo -e "${GREEN}${BOLD}✅ ALL TESTS PASSED${NC} (${TOTAL_PASSED} tests)"
  exit 0
else
  echo -e "${RED}${BOLD}❌ ${TOTAL_FAILED} FAILED${NC}, ${TOTAL_PASSED} passed"
  echo -e "   Failed files: ${FAILED_FILES[*]}"
  exit 1
fi
