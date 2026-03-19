-- tests/test_providers.lua
-- Tests for providers.lua resolve_model and all_model_names.
-- Seeds _providers directly from presets to skip file I/O.

vim.opt.rtp:prepend(vim.fn.getcwd())

-- Clear any cached module to ensure fresh state
package.loaded["dwight.providers"] = nil

-- Stub dwight.project to avoid file I/O in providers.load()
package.loaded["dwight.project"] = {
	is_initialized = function()
		return false
	end,
	dir = function()
		return "/tmp/dwight-test-providers"
	end,
}

-- Stub dwight config
package.loaded["dwight"] = {
	config = {
		backend = "api",
		provider = nil,
		model = nil,
	},
}

local providers = require("dwight.providers")
local T = _T

-- Seed providers from presets (skip file I/O)
local function seed_providers()
	providers._providers = vim.deepcopy(providers.presets)
	providers._active_provider = "anthropic"
	providers._active_model = nil
end

--------------------------------------------------------------------
-- resolve_model
--------------------------------------------------------------------

io.write("── providers.resolve_model ──\n")

T.test("resolve_model: nil -> default (anthropic sonnet)", function()
	seed_providers()
	local resolved = providers.resolve_model(nil)
	T.eq("anthropic", resolved.provider_name)
	T.ok(resolved.model_id, "should have a model_id")
end)

T.test("resolve_model: empty string -> default", function()
	seed_providers()
	local resolved = providers.resolve_model("")
	T.eq("anthropic", resolved.provider_name)
end)

T.test("resolve_model: 'sonnet' -> full Anthropic ID", function()
	seed_providers()
	local resolved = providers.resolve_model("sonnet")
	T.eq("anthropic", resolved.provider_name)
	T.match("claude%-sonnet", resolved.model_id)
end)

T.test("resolve_model: 'openai:gpt-4o' -> provider:model split", function()
	seed_providers()
	local resolved = providers.resolve_model("openai:gpt-4o")
	T.eq("openai", resolved.provider_name)
	T.eq("gpt-4o", resolved.model_id)
end)

T.test("resolve_model: 'gpt-4o' -> alias found across providers", function()
	seed_providers()
	local resolved = providers.resolve_model("gpt-4o")
	-- Both openai and openrouter have gpt-4o; pairs() order is non-deterministic
	T.ok(
		resolved.provider_name == "openai" or resolved.provider_name == "openrouter",
		"should resolve to openai or openrouter, got: " .. resolved.provider_name
	)
	T.ok(resolved.model_id, "should have model_id")
end)

T.test("resolve_model: literal 'gpt-5' -> inferred openai", function()
	seed_providers()
	local resolved = providers.resolve_model("gpt-5")
	T.eq("openai", resolved.provider_name)
end)

T.test("resolve_model: literal 'claude-sonnet-4-foo' -> inferred anthropic", function()
	seed_providers()
	local resolved = providers.resolve_model("claude-sonnet-4-foo")
	T.eq("anthropic", resolved.provider_name)
	T.eq("claude-sonnet-4-foo", resolved.model_id)
end)

T.test("resolve_model: literal 'gemini-2.5-flash' -> inferred gemini", function()
	seed_providers()
	local resolved = providers.resolve_model("gemini-2.5-flash")
	T.eq("gemini", resolved.provider_name)
end)

T.test("resolve_model: unknown string -> fallback to active provider", function()
	seed_providers()
	local resolved = providers.resolve_model("totally-unknown-model")
	T.eq("anthropic", resolved.provider_name)
	T.eq("totally-unknown-model", resolved.model_id)
end)

--------------------------------------------------------------------
-- all_model_names
--------------------------------------------------------------------

io.write("── providers.all_model_names ──\n")

T.test("all_model_names: returns sorted list", function()
	seed_providers()
	local names = providers.all_model_names()
	T.ok(#names > 0, "should have model names")
	-- Verify sorted
	for i = 2, #names do
		T.ok(names[i] >= names[i - 1], "should be sorted: " .. names[i - 1] .. " <= " .. names[i])
	end
end)

T.test("all_model_names: contains both aliases and qualified names", function()
	seed_providers()
	local names = providers.all_model_names()
	local set = {}
	for _, n in ipairs(names) do
		set[n] = true
	end
	T.ok(set["sonnet"], "should contain alias 'sonnet'")
	T.ok(set["gpt-4o"], "should contain alias 'gpt-4o'")
	-- Should contain at least one qualified name
	local has_qualified = false
	for _, n in ipairs(names) do
		if n:match(":") then
			has_qualified = true
			break
		end
	end
	T.ok(has_qualified, "should contain qualified names like provider:alias")
end)
