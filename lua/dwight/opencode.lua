-- dwight/opencode.lua
-- ⚠️ RENAMED: This module has been renamed to dwight.inline to clarify its purpose.
-- It's the inline code generation engine (prompt → parse → apply to buffer),
-- not specific to the "opencode" CLI tool.
-- This shim forwards all calls for backwards compatibility.

return require("dwight.inline")
