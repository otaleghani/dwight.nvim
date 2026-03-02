-- dwight/audit.lua
-- ⚠️ RENAMED: This module has been renamed to dwight.review to avoid confusion
-- with codebase_audit.lua (which does deep per-feature analysis).
-- This shim forwards all calls to the new module for backwards compatibility.

return require("dwight.review")
