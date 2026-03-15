-- dwight/pubdocs/plan.lua
-- Build the full list of doc pages to generate.

local M = {}

--- Build the plan: all pages that should exist based on pragmas.
--- Returns { { path, title, page_type, description, ... } ... }
function M.build_plan()
	local features = require("dwight.features")
	local pages = {}

	-- 1. Always-generated pages
	pages[#pages + 1] = {
		path = "index.md",
		title = "Documentation",
		page_type = "index",
		description = "Project documentation home page",
	}
	pages[#pages + 1] = {
		path = "getting-started.md",
		title = "Getting Started",
		page_type = "getting-started",
		description = "Quick start guide for new users",
	}

	-- 2. Feature pages (excluding @feature-no-docs)
	local doc_features = features.documentable_features()
	for _, name in ipairs(doc_features) do
		local feat = features.build_feature(name)
		local title = feat and feat.description or name
		title = title:match("^([^%.]+)") or title
		if #title > 80 then
			title = title:sub(1, 77) .. "..."
		end
		pages[#pages + 1] = {
			path = "features/" .. name .. ".md",
			title = title,
			page_type = "feature",
			feature_name = name,
			description = feat and feat.description or "",
		}
	end

	-- 3. @docs:route pages (merged by route)
	local docs_pragmas = features.scan_docs()
	local route_groups = {}
	for _, dp in ipairs(docs_pragmas) do
		if not route_groups[dp.route] then
			route_groups[dp.route] = {}
		end
		route_groups[dp.route][#route_groups[dp.route] + 1] = dp
	end
	for route, entries in pairs(route_groups) do
		local page_type = "generic"
		if route:match("^reference/") then
			page_type = "reference"
		elseif route:match("^guides/") then
			page_type = "guide"
		elseif route:match("^concepts/") then
			page_type = "concept"
		end

		local title = entries[1].title
		if not title then
			local slug = route:match("[^/]+$") or route
			title = slug:gsub("%-", " "):gsub("^%l", string.upper):gsub(" %l", function(c)
				return c:upper()
			end)
		end

		pages[#pages + 1] = {
			path = route .. ".md",
			title = title,
			page_type = page_type,
			docs_entries = entries,
			description = "",
		}
	end

	return pages
end

return M
