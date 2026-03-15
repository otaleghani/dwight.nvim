-- dwight/pubdocs/init.lua
-- Re-exports the exact same public API as the original pubdocs.lua module.

local M = {}

-- adapters.lua
function M.detect_framework(...)
	return require("dwight.pubdocs.adapters").detect_framework(...)
end

function M.get_adapter(...)
	return require("dwight.pubdocs.adapters").get_adapter(...)
end

function M._relative_link(...)
	return require("dwight.pubdocs.adapters")._relative_link(...)
end

-- plan.lua
function M.build_plan(...)
	return require("dwight.pubdocs.plan").build_plan(...)
end

-- generate.lua
function M.generate_page(...)
	return require("dwight.pubdocs.generate").generate_page(...)
end

function M.generate(...)
	return require("dwight.pubdocs.generate").generate(...)
end

function M._generate_many(...)
	return require("dwight.pubdocs.generate")._generate_many(...)
end

function M.browse(...)
	return require("dwight.pubdocs.generate").browse(...)
end

-- scan.lua
function M.scan_existing_docs(...)
	return require("dwight.pubdocs.scan").scan_existing_docs(...)
end

function M.detect_link_style(...)
	return require("dwight.pubdocs.scan").detect_link_style(...)
end

function M._detect_stale_pages(...)
	return require("dwight.pubdocs.scan")._detect_stale_pages(...)
end

-- agentic.lua
function M.generate_agentic(...)
	return require("dwight.pubdocs.agentic").generate_agentic(...)
end

function M._run_docs_pipeline(...)
	return require("dwight.pubdocs.agentic")._run_docs_pipeline(...)
end

function M._docs_post_generate(...)
	return require("dwight.pubdocs.agentic")._docs_post_generate(...)
end

-- update.lua
function M.update_docs(...)
	return require("dwight.pubdocs.update").update_docs(...)
end

function M._run_update_pipeline(...)
	return require("dwight.pubdocs.update")._run_update_pipeline(...)
end

-- seo.lua
function M._seo_audit(...)
	return require("dwight.pubdocs.seo")._seo_audit(...)
end

function M.seo_optimize(...)
	return require("dwight.pubdocs.seo").seo_optimize(...)
end

function M._run_seo_pipeline(...)
	return require("dwight.pubdocs.seo")._run_seo_pipeline(...)
end

return M
