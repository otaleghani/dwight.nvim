-- dwight/codebase_audit/constants.lua
-- Severity levels, thresholds, pattern tables, language detection.

local M = {}

--------------------------------------------------------------------
-- Severity levels
--------------------------------------------------------------------

M.SEV = {
	CRITICAL = { icon = "🔴", label = "CRITICAL", sort = 1 },
	WARN = { icon = "🟡", label = "WARN", sort = 2 },
	INFO = { icon = "🔵", label = "INFO", sort = 3 },
}

--------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------

M.MAX_FUNCTION_LINES = 40 -- lines before flagging
M.MAX_NESTING_DEPTH = 4 -- nesting levels before flagging
M.MAX_PARAMS = 5 -- params before flagging
M.MIN_DUPLICATION_LEN = 8 -- min consecutive matching lines

-- Lines to skip entirely when checking duplication (structural noise)
M.DUPLICATION_SKIP_PATTERNS = {
	"^package ", -- Go package declarations
	"^import ", -- single-line imports
	"^import%s*%(", -- multi-line import block opener
	"^from ", -- Python imports
	"^require%(", -- Lua/JS require
	"^use ", -- Rust use
	"^#?include ", -- C/C++ includes
	"^@feature:", -- Dwight pragmas
	"^@project", -- Dwight pragmas
	"^@constraint", -- Dwight pragmas
	"^@stack", -- Dwight pragmas
	"^@convention", -- Dwight pragmas
	"^//", -- Comment-only lines
	"^#", -- Comment-only lines
	"^%-%-", -- Lua comments
	"^/%*", -- Block comment openers
	"^%*", -- Block comment continuations
	"^if%s+err%s*!=%s*nil", -- Go idiomatic error check
	"^t%.Fatal", -- Go test assertions
	"^t%.Error", -- Go test assertions
	"^assert", -- Generic assertions
	"^expect%(", -- JS test assertions
	"^return ", -- Simple returns
	"^}$", -- Lone closing braces
	"^{$", -- Lone opening braces
	"^%)$", -- Lone closing parens
	"^end$", -- Lua/Ruby block ends
}

-- Patterns that suggest hardcoded secrets
M.SECRET_PATTERNS = {
	{ pat = "['\"]%w*password['\"]%s*[:=]%s*['\"][^'\"]+['\"]", label = "hardcoded password" },
	{ pat = "['\"]%w*secret['\"]%s*[:=]%s*['\"][^'\"]+['\"]", label = "hardcoded secret" },
	{ pat = "['\"]%w*api_?key['\"]%s*[:=]%s*['\"][^'\"]+['\"]", label = "hardcoded API key" },
	{ pat = "['\"]%w*token['\"]%s*[:=]%s*['\"][^'\"]+['\"]", label = "hardcoded token" },
	{ pat = "-----BEGIN [A-Z]+ PRIVATE KEY-----", label = "embedded private key" },
	{ pat = "sk%-[a-zA-Z0-9]{20,}", label = "possible API key literal" },
	{ pat = "ghp_[a-zA-Z0-9]{36}", label = "GitHub personal access token" },
}

-- Patterns that suggest swallowed errors
M.SWALLOWED_ERROR_PATTERNS = {
	-- Go: if err != nil { } (empty or just return)
	{ lang = "go", pat = "if%s+err%s*!=%s*nil%s*{%s*}", label = "empty error check" },
	-- JS/TS: catch (e) {} or catch {}
	{ lang = "js", pat = "catch%s*%(?[^)]*%)?%s*{%s*}", label = "empty catch block" },
	-- Python: except: pass
	{ lang = "python", pat = "except[^:]*:%s*\n%s*pass", label = "bare except: pass" },
	-- Lua: pcall without checking return
	{ lang = "lua", pat = "pcall%(", label = "unchecked pcall (verify ok checked)" },
	-- Generic: _ = err
	{ lang = "go", pat = "_%s*=%s*err", label = "discarded error" },
}

-- Language detection from file extension
M.EXT_TO_LANG = {
	[".go"] = "go",
	[".js"] = "js",
	[".ts"] = "js",
	[".jsx"] = "js",
	[".tsx"] = "js",
	[".py"] = "python",
	[".lua"] = "lua",
	[".rs"] = "rust",
	[".rb"] = "ruby",
	[".java"] = "java",
	[".kt"] = "kotlin",
	[".cs"] = "csharp",
}

function M.detect_lang(filepath)
	local ext = filepath:match("(%.[^.]+)$") or ""
	return M.EXT_TO_LANG[ext] or "unknown"
end

return M
