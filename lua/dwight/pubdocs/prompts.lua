-- dwight/pubdocs/prompts.lua
-- Base prompt builder and page-type-specific prompt templates.

local M = {}

function M.base_prompt(page, adapter, docs_structure, project_ctx, specific_ctx, existing)
	local parts = {}

	parts[#parts + 1] = string.format("Generate documentation page: %s\n", page.path)
	parts[#parts + 1] = "FRONTMATTER: The system will add YAML frontmatter automatically. "
		.. "Do NOT include --- fences. Just write the content body.\n"
	parts[#parts + 1] = adapter.link_instructions() .. "\n"

	if docs_structure then
		parts[#parts + 1] = docs_structure .. "\n"
	end

	if project_ctx and project_ctx ~= "" then
		parts[#parts + 1] = "Project context:\n" .. project_ctx .. "\n"
	end

	if specific_ctx and specific_ctx ~= "" then
		parts[#parts + 1] = "Page-specific context:\n" .. specific_ctx .. "\n"
	end

	if existing then
		parts[#parts + 1] = "Current version (update it, preserve user edits):\n"
			.. "```markdown\n"
			.. existing
			.. "\n```\n"
	end

	return table.concat(parts, "\n")
end

M.PAGE_PROMPTS = {
	index = function(page, adapter, struct, proj, existing)
		return M.base_prompt(page, adapter, struct, proj, nil, existing)
			.. [=[
Create a project documentation index page. This is the main entry point.

Structure:
# Project Name
Brief overview (2-3 sentences from user's perspective).

## Quick Links
Links to the most important pages.

## Features
Brief list of features with links to detail pages.

## Getting Started
Brief teaser + link to Getting Started page.

Be welcoming, clear, concise. For END USERS, not developers.
Respond with ONLY the markdown content (no frontmatter, no fences).
]=]
	end,

	["getting-started"] = function(page, adapter, struct, proj, existing)
		return M.base_prompt(page, adapter, struct, proj, nil, existing)
			.. [=[
Create a "Getting Started" guide for new users.

Structure:
# Getting Started

## Prerequisites
What the user needs.

## Installation
Step-by-step.

## First Steps
Walk through basic usage (3-5 steps).

## Next Steps
Point to feature pages.

Be friendly, practical. Assume the user knows nothing.
Respond with ONLY the markdown content (no frontmatter, no fences).
]=]
	end,

	feature = function(page, adapter, struct, proj, existing)
		local helpers = require("dwight.pubdocs.helpers")
		local ctx = helpers.build_feature_context(page.feature_name)
		return M.base_prompt(page, adapter, struct, proj, ctx, existing)
			.. string.format(
				[=[
Create user-facing documentation for the "%s" feature.

Structure:
# %s
What this feature does (user's perspective).

## Overview
The problem it solves.

## Usage
How to use it with concrete examples.

## Configuration
Options, settings (if any).

## Examples
2-3 practical examples.

Write for END USERS. No implementation details.
Respond with ONLY the markdown content (no frontmatter, no fences).
]=],
				page.feature_name,
				page.title
			)
	end,

	reference = function(page, adapter, struct, proj, existing)
		local helpers = require("dwight.pubdocs.helpers")
		local ctx = helpers.build_route_context(page.docs_entries or {})
		return M.base_prompt(page, adapter, struct, proj, ctx, existing)
			.. [[
Create an API reference page. Be precise and compact.

For each function/method: signature, parameters, return type, description, example.
Include key types/interfaces.
Use code blocks for signatures and examples.
Respond with ONLY the markdown content (no frontmatter, no fences).
]]
	end,

	guide = function(page, adapter, struct, proj, existing)
		local helpers = require("dwight.pubdocs.helpers")
		local ctx = helpers.build_route_context(page.docs_entries or {})
		return M.base_prompt(page, adapter, struct, proj, ctx, existing)
			.. [[
Create a how-to guide. Focus on practical steps.

Structure: prerequisites -> numbered steps with code -> troubleshooting.
Be step-by-step. Show code at each step.
Respond with ONLY the markdown content (no frontmatter, no fences).
]]
	end,

	concept = function(page, adapter, struct, proj, existing)
		local helpers = require("dwight.pubdocs.helpers")
		local ctx = helpers.build_route_context(page.docs_entries or {})
		return M.base_prompt(page, adapter, struct, proj, ctx, existing)
			.. [[
Create a concept/explanation page. Help understand WHY, not just HOW.

Structure: what it is -> background -> how it works -> implications.
Be clear, educational. Use analogies if helpful.
Respond with ONLY the markdown content (no frontmatter, no fences).
]]
	end,

	generic = function(page, adapter, struct, proj, existing)
		local helpers = require("dwight.pubdocs.helpers")
		local ctx = helpers.build_route_context(page.docs_entries or {})
		return M.base_prompt(page, adapter, struct, proj, ctx, existing)
			.. [[
Create a documentation page based on the source context provided.
Infer the appropriate style. Be clear, user-focused, include examples.
Respond with ONLY the markdown content (no frontmatter, no fences).
]]
	end,
}

return M
